# desk/filter.jq - the viewer's slice of a raw snapshot.
#
# POSITIVE ALLOWLIST, AND THAT IS THE WHOLE DESIGN. A key that is not named in
# this file does not exist in the output, whatever the raw document carried.
# The alternative - copying the raw row and deleting what must not travel - is
# a blocklist, and a blocklist is only ever as current as the last field
# somebody remembered to add to it. The raw document deliberately carries more
# than any viewer may see (a session's `mcpReason`, for one); nothing here
# names it, so nothing here can leak it.
#
# ONE FILE, ONE PLACE TO READ THE RULE. The producer decides WHICH viewers get
# a file; this decides WHAT is in it. A reviewer who wants to know what a
# colleague can see about a session reads this file and nothing else.
#
# Arguments, all required:
#   $viewer    the principal id this slice belongs to ("_operator" for the
#              unfiltered operator file)
#   $readAll   true when this viewer's row carries DESK_READ_ALL
#   $memberOf  the entity ids this viewer is a MEMBER of, as a JSON array

# isMember - membership of the viewer in an entity id. NULL IS NOT A MATCH: a
# session with no owning entity, or an entity with no manager, must never come
# out as "everybody is a member of it" because two absent values compared equal.
def isMember($x): $x != null and (($memberOf | index($x)) != null);

# keepAsset - the axis rule, applied to ONE asset of ONE session.
#
# THE AXES ARE NOT INTERCHANGEABLE. An account-axis asset is a person's own
# credential - a mail account, a note store - and it belongs to the human
# sitting in the session, not to the org node above them. So it travels to the
# owner and to a read-all viewer and to nobody else, ever. An entity-axis asset
# travels to a member of the entity that granted it; a project-axis asset to a
# member of the entity the project hangs under. An axis this file does not know
# is dropped, not passed through: a new axis must be granted deliberately here,
# never inherited by an `else`.
def keepAsset($own; $parentOf):
  if   .axis == "account" then ($readAll or $own)
  elif .axis == "entity"  then ($readAll or $own or isMember(.source))
  elif .axis == "project" then ($readAll or $own or isMember($parentOf[.source]))
  else false
  end;

# The project -> parent-entity map, built once from the raw document, so the
# project axis can be resolved without a second pass per asset.
( [ (.projects // [])[] | { key: .id, value: .parent } ] | from_entries ) as $parentOf
| { schemaVersion: 1,
    host, generatedAt, registryRevision,
    viewer: $viewer,
    readAll: $readAll,

    # An entity travels when the viewer is a member of it, or a member of the
    # team that manages it. `member` says which of the two it was, so a view
    # can tell "my team" from "a team my team works for" without a second file.
    entities: [ (.entities // [])[]
                | select($readAll or isMember(.id) or isMember(.managedBy))
                | { id, name, managedBy, members, member: isMember(.id) } ],

    projects: [ (.projects // [])[]
                | select($readAll or isMember(.parent))
                | { id, name, parent } ],

    sessions: [ (.sessions // [])[]
                | select(.owner == $viewer or isMember(.domain) or $readAll)
                | (.owner == $viewer) as $own
                | { id, slug, label, owner,
                    mine: $own,
                    domain, project, runtime, host, repo,
                    # THREE FIELDS, NOT THE WHOLE LIVENESS ROW. The producer's
                    # raw row carries the launch manager, the multiplexer and
                    # the model as well; a desk answers "is this alive and how
                    # fresh is the answer", and the rest is the supervisor's
                    # business.
                    liveness: { state: .liveness.state,
                                measuredAt: .liveness.measuredAt,
                                ageSeconds: .liveness.ageSeconds },
                    mcp: [ (.mcp // [])[]
                           | select(keepAsset($own; $parentOf))
                           | { id, name, axis, source } ] } ] }
