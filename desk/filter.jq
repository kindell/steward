# The shell decides session sight; lib/visibility.sh's positive field lists
# are authoritative. New raw keys never travel without an explicit grant.
# memberOf governs entity/project metadata only, not session authorization.
# readAll selects the owner projection, never bypasses the field allowlist.
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
    # Account, entity and project assets travel only in the owner projection.
    # Unknown axes are dropped even for owners/readAll; new axes need policy.
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
