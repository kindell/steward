# Where a session's name is decided

**Status:** open. Needs a decision from the estate's operator, because it is a
naming-policy question before it is a code question.

## The measurement

A session asked to be registered. The hub judged the requested slug wrong and
wrote the row under a different one. The row is correct; the session is mute.

    request     namn=acme-acme-alice
    row written SLUG="acme-ledger-claude-alice-acme"
    activation  no key '/home/<owner>/.ssh/id_busrelay_acme-ledger-claude-alice-acme'

The key was minted under the name the REQUESTER chose, before the hub chose
another. Nothing links the two.

## Why the existing pairing did not help

`linux/hub/enroll` writes `SLUG="$NAMN"` (line 743) and prints
`--activate $ID $NAMN` (line 913), where `$NAMN` is the requested name. Inside
the enrolment flow the row's slug and the key's slug are therefore ALWAYS the
same, and activation always finds the key. The carried pairing is sound.

The break was that the hub never ran that flow: it wrote the row by hand with
`registry session add`, which mints no key and knows no reservation — and says
so when it runs.

**So this is not a hole in the pairing. It is that the hub has no supported way
to assign a slug other than the requested one.** When the estate's naming scheme
disagrees with the request, the only path is a hand-written row outside the flow
where the key lives.

## Why it is not one fix

1. `linux/hub/enroll` should REFUSE a slug that does not match the estate's
   scheme and name the correct form, instead of the hub quietly writing a
   different row. That keeps the decision where the key is minted.
2. But then the requester must be ABLE to mint under that form, and it cannot:
   `linux/session-new.sh:553` builds `NAMN="${DOMAN}-${PROJEKT}-${PERSON}"` —
   three parts, no runtime, and the person derived from the unix account rather
   than from the login slug. The estate's scheme
   (`{entity}-{project}-{runtime}-{login}`, the project omitted when the row
   targets the entity) has five, and there is no flag that reaches them.

Part 2 is the precondition for part 1, not the smaller half of it.

## What needs deciding first

Whether the requester proposes a name that the hub may overrule, or whether the
scheme is enforced at the point of request. Both are defensible; they lead to
different code. Naming is the operator's decision, and this document exists so
the code does not quietly settle it.

## Also open, smaller

A discarded request leaves its reservation and its key behind. After a request
the hub declines or supersedes, `enroll-<slug>.pending` and
`id_busrelay_<slug>` stay in the requester's home and accumulate. Reported by
the session that made this request, which is keeping both on purpose until the
row has a real key.
