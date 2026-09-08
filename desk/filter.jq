# THIS IS A POSITIVE PROJECTION, NOT A BLOCKLIST. The raw snapshot deliberately
# contains fields no ordinary viewer may receive; a newly added raw key must
# stay absent until lib/visibility.sh explicitly grants its path.
#
# SESSION SIGHT IS DECIDED ONCE IN SHELL. The sight map carries that decision
# here; memberOf only selects entity/project metadata and must never manufacture
# session authorization. readAll wins over the shell sight classification, but
# still selects the owner allowlist rather than exposing the raw row.
#
# projectFields recursively walks dotted paths through objects and arrays so a
# nested allowlist grants only the named leaves. Copying a containing object
# wholesale would make every future child field public by accident.
def projectFields($paths):
  if type == "array" then map(projectFields($paths))
  else . as $row
    | reduce ($paths | group_by(.[0]))[] as $group
        ({}; $group[0][0] as $key
             | .[$key] = (if any($group[]; length == 1) then $row[$key]
                           else $row[$key] | projectFields($group | map(.[1:]))
                           end))
  end;

def isMember($x): $x != null and (($memberOf | index($x)) != null);
def isVisibleEntity($id; $managerOf):
  $id != null and (isMember($id) or isMember($managerOf[$id]));

# keepAsset - ONE asset of ONE session, decided in two steps.
#
# STEP ONE IS NOT DECIDED HERE. $ownerAxes and $memberAxes come from
# lib/visibility.sh's visibility_asset_axes, which is the product's only
# statement of which MCP axes each sight class may carry: the account axis to
# the owner (and to read-all) alone, the two org axes to a member as well. An
# axis on neither list - a vocabulary the policy cannot interpret - matches
# nothing and is dropped even from an owner's document, so schema growth is
# never an implicit grant.
#
# STEP TWO IS THE ENTITY RULE, THE ONE THIS DOCUMENT ALREADY APPLIES. An asset
# an org node granted travels exactly as far as that node does, so an
# entity-axis asset asks isVisibleEntity of its source and a project-axis asset
# asks it of the source project's parent. That is the same isVisibleEntity
# entities[] and projects[] use two rules below, not a second copy of the axis
# policy - and it can only ever narrow the axis table, never widen it.
#
# THE SURFACE CARRIES ONE ROW PER GRANT, AND THE DEDUP HAPPENS AFTER THIS.
# It used to carry one row per asset, named after the level that granted it
# first - so an asset declared on BOTH a managing team and the entity it
# manages arrived named after the manager alone, and a member of the managed
# entity, who is not a member of its manager, lost an asset their own entity
# had explicitly granted them. SCHEMA.md promises the opposite. Now every
# granting level has its own row, this rule decides each one, and the survivors
# are deduplicated below by id - so a viewer keeps the closest source they can
# actually see, and the document still carries one entry per asset.
def keepAsset($sight; $own; $parentOf; $managerOf):
  # THE AXIS IS BOUND BEFORE THE LOOKUP. `index(.axis)` reads `.` as the axis
  # ARRAY the pipe just handed it, not as this asset - jq raises "cannot index
  # array with string" and every viewer's file fails to write.
  .axis as $ax
  | (((if $sight == "owner" then $ownerAxes else $memberAxes end) | index($ax)) != null)
  and (if   .axis == "account" then true
       elif .axis == "entity"  then ($readAll or $own or isVisibleEntity(.source; $managerOf))
       else ($readAll or $own or
             (.source != null and isVisibleEntity($parentOf[.source]; $managerOf)))
       end);

([( .entities // [])[] | {key: .id, value: .managedBy}] | from_entries) as $managerOf
| ([( .projects // [])[] | {key: .id, value: .parent}] | from_entries) as $parentOf
| [ (.sessions // [])[]
    | .sight = (if $readAll then "owner" else (.sight[$viewer] // "none") end)
    | select(.sight == "owner" or .sight == "member")
    | .mine = (.owner == $viewer)
    | .sight as $sight
    | .mine as $own
    # DEDUP AFTER THE RULE, NEVER BEFORE IT. `group_by` sorts, which would
    # lose the closest-first order the surface emits, so the first surviving
    # row per id is picked by walking the list once and keeping what is new.
    | .mcp = ([(.mcp // [])[] | select(keepAsset($sight; $own; $parentOf; $managerOf))]
              | reduce .[] as $a ([]; if any(.[]; .id == $a.id) then . else . + [$a] end))
    | projectFields((if .sight == "owner" then $ownerFields else $memberFields end) | map(split(".")))
  ] as $sessions
| {schemaVersion: 1, host, generatedAt, registryRevision,
   viewer: $viewer, readAll: $readAll,
   entities: [(.entities // [])[]
     | select($readAll or isVisibleEntity(.id; $managerOf))
     | {id, name, managedBy, members, member: isMember(.id)}],
   # A PROJECT TRAVELS WITH ITS ENTITY, or because the VIEWER'S OWN session
   # works on it - never because a colleague's does. The session clause exists
   # so a person's own session page has no 404 behind its `project` link, and
   # that argument reaches exactly as far as their own row. Widened to every
   # visible session, the clause hands over a project's `name` and its `parent`
   # - and `parent` can name an entity the entity rule above deliberately
   # withheld from this viewer, which is the withheld thing recovered from the
   # disclosed one, one level up from the doctrine docs/client-spec.md states
   # for `hidden`.
   projects: [(.projects // [])[]
     | .id as $id
     | select($readAll or isVisibleEntity(.parent; $managerOf)
              or any($sessions[]; .project == $id and .mine))
     | {id, name, parent}],
   sessions: $sessions}
