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
#   $visible   session ids lib/visibility.sh session_visible_to has already
#              said yes to for this viewer, as a JSON array of strings. The
#              SHELL decides who may see which SESSION (owner, group grant,
#              `private`, the one entity/manager hop - all of it, once, in
#              desk/snapshot.sh); this file only projects the fields of the
#              ones it is handed. Entities, projects and mcp assets are not
#              decided this way yet - they still ask isVisibleEntity below.

# isMember - membership of the viewer in an entity id. NULL IS NOT A MATCH: a
# session with no owning entity, or an entity with no manager, must never come
# out as "everybody is a member of it" because two absent values compared equal.
# Every lookup below inherits that property, because every one of them can be
# handed the null a registry row leaves behind when a relation is absent.
def isMember($x): $x != null and (($memberOf | index($x)) != null);

# isVisibleEntity - ONE RULE, AND EVERY PLACE AN ENTITY DECIDES VISIBILITY ASKS
# IT. An entity is visible to the viewer when the viewer is a member of it, or a
# member of the entity that manages it - one hop, no chain.
#
# THIS FILE ONCE HAD TWO RULES AND THE SECOND ONE WAS THE BUG. The entity list
# widened through the manager while everything hanging under an entity - its
# projects, its sessions, its project-axis grants - asked only about direct
# membership. Measured on a real estate: a viewer saw the client their team
# manages and not the delivery their own colleagues were running for it, so the
# desk answered "this client exists" and "that project does not". An entity is
# either the viewer's business or it is not, and what hangs under it follows the
# entity; anything else is two different answers to one question.
def isVisibleEntity($id; $managerOf): $id != null and (isMember($id) or isMember($managerOf[$id]));

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
#
# THE TWO ORG AXES ASK isVisibleEntity, not isMember: an asset the entity level
# granted travels exactly as far as the entity itself does.
#
# THE `source` THIS RULE READS IS ONE HOP, NOT THE WHOLE CHAIN THAT GRANTED IT.
# registry_session_mcp_surface attributes an entity-axis asset to the level it
# found it at, and it looks at the session's own entity and its manager - so an
# asset declared on BOTH a manager and the entity it manages arrives here named
# after the manager alone. A member of the managed entity is then not a member
# of the source, and the asset is dropped. That only ever DENIES: the viewer
# sees fewer assets than the estate granted, never more, and the missing row is
# one a member of the manager can see. Worth fixing in the surface, where the
# attribution is decided; nothing here can fix it, because the second granting
# level never reaches this file.
def keepAsset($own; $parentOf; $managerOf):
  if   .axis == "account" then ($readAll or $own)
  elif .axis == "entity"  then ($readAll or $own or isVisibleEntity(.source; $managerOf))
  elif .axis == "project" then ($readAll or $own or
                                 (.source != null and isVisibleEntity($parentOf[.source]; $managerOf)))
  else false
  end;

# ownsSessionOn - the viewer runs a session whose target is this project. A
# person always sees the project their own session works on, whoever the
# project hangs under: the alternative is a session page whose `project` link is
# a 404 for the very person sitting in that session.
def ownsSessionOn($id; $ownProjects): $id != null and (($ownProjects | index($id)) != null);

# THREE MAPS, BUILT ONCE FROM THE RAW DOCUMENT so no rule needs a second pass:
# project -> parent entity, entity -> its manager, and the projects the viewer's
# own sessions work on.
( [ (.projects // [])[] | { key: .id, value: .parent } ] | from_entries ) as $parentOf
| ( [ (.entities // [])[] | { key: .id, value: .managedBy } ] | from_entries ) as $managerOf
| ( [ (.sessions // [])[] | select(.owner == $viewer) | .project | select(. != null) ] ) as $ownProjects
| { schemaVersion: 1,
    host, generatedAt, registryRevision,
    viewer: $viewer,
    readAll: $readAll,

    # An entity travels when it is visible - the one rule above. `member` says
    # which of the two halves of that rule let it through, so a view can tell
    # "my team" from "a team my team works for" without a second file.
    entities: [ (.entities // [])[]
                | select($readAll or isVisibleEntity(.id; $managerOf))
                | { id, name, managedBy, members, member: isMember(.id) } ],

    # A project travels when the entity it hangs under is visible, or when the
    # viewer's own session works on it.
    projects: [ (.projects // [])[]
                | select($readAll or isVisibleEntity(.parent; $managerOf)
                         or ownsSessionOn(.id; $ownProjects))
                | { id, name, parent } ],

    # THE SHELL DECIDED; THIS ONLY PROJECTS. `$visible` is the list
    # lib/visibility.sh session_visible_to already answered yes to, one call
    # per session, in desk/snapshot.sh - owner, group grant, `private`
    # withdrawal, and the one entity/manager hop are all decided there, once,
    # in the product's one rule. This file no longer re-derives any of that
    # for sessions: a session travels here when its id is in $visible, or
    # when the viewer reads everything.
    #
    # `.id AS $sid` BEFORE THE PIPE INTO `$visible`, NOT `index(.id)` INLINE.
    # `index()` is a $-parameter builtin, and jq desugars `f(.id)` by binding
    # "." to whatever the input is WHERE `.id` is evaluated inside
    # index's own body - which, after `$visible | index(...)`, is `$visible`
    # itself, an array with no `id` key. Measured: `index(.id)` written where
    # `$visible` is already the input fails every call with "Cannot index
    # array with string \"id\"", never reaching a single viewer's file. The
    # session's id has to be captured as a value BEFORE the context changes.
    sessions: [ (.sessions // [])[]
                | select(.id as $sid | $readAll or (($visible | index($sid)) != null))
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
                           | select(keepAsset($own; $parentOf; $managerOf))
                           | { id, name, axis, source } ] } ] }
