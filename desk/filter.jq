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

([( .entities // [])[] | {key: .id, value: .managedBy}] | from_entries) as $managerOf
| [ (.sessions // [])[]
    | .sight = (if $readAll then "owner" else (.sight[$viewer] // "none") end)
    | select(.sight == "owner" or .sight == "member")
    | .mine = (.owner == $viewer)
    # Account, entity and project are the complete known MCP-axis vocabulary.
    # Unknown axes are dropped even for owners/readAll: permitting an axis the
    # policy cannot interpret would turn schema growth into an implicit grant.
    | .mcp = [(.mcp // [])[] | select(.axis == "account" or .axis == "entity" or .axis == "project")]
    | projectFields((if .sight == "owner" then $ownerFields else $memberFields end) | map(split(".")))
  ] as $sessions
| {schemaVersion: 1, host, generatedAt, registryRevision,
   viewer: $viewer, readAll: $readAll,
   entities: [(.entities // [])[]
     | select($readAll or isVisibleEntity(.id; $managerOf))
     | {id, name, managedBy, members, member: isMember(.id)}],
   projects: [(.projects // [])[]
     | .id as $id
     | select($readAll or isVisibleEntity(.parent; $managerOf)
              or any($sessions[]; .project == $id))
     | {id, name, parent}],
   sessions: $sessions}
