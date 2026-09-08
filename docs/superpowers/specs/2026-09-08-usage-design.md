# Usage - what a subscription window has left, who sees it, and what a turn does when it is empty

**Status:** draft 1, 2026-09-08. Written by the hub session of the first estate on
the operator's relayed decisions of 2026-09-08 (09:15Z, 11:2xZ) and the advisor
review of 10:2xZ. Estate specs (desk, ping, ledger, api resources) stay in their
estates and link here; this is the product's spec.

## The problem, measured

An advisor session died mid-task at 08:5xZ when its OpenAI workspace reached the
five-hour window (100 %, `workspace_owner_credits_depleted`; the weekly window
stood at 16 %). Nobody had a number to look at beforehand, and the failure looked
like a broken session rather than an empty budget. The operator asked for a
measurement of "how many tokens we have left", then decided what a turn does
when there are none: **not wait - run where there is capacity, and say so.**

Both providers can be measured today, and one estate already does it
(`tools/usage-<estate>.sh`, 09:07Z): the Codex daemon answers
`account/rateLimits/read` (used percent, window length, reset time, per window)
over a websocket probe; Claude Code answers `claude -p /usage` non-interactively
per login directory, as text. Four homes take four seconds in parallel.

## The one rule

**Usage is a measurement the estate makes and the product projects.** The product
never talks to a provider; it runs the estate's seam, reads rows, and decides
from them. The same shape as liveness (`lib/liveness.sh`): one command, one
call per run, rows keyed by a name the registry knows, absence means `unknown`.

Three consequences that the rest follows from:

1. **A window is a login's, not a session's.** Several sessions run on one login
   and drain the same window. Rows are keyed by the login slug (`logins.d`), and
   every projection groups by login.
2. **A percentage is private.** How far a person has drained their own plan is a
   work pattern. It reaches that person's own view only. A teammate, a manager
   and a read-all operator see an operational STATE, never the number.
3. **A switch is never silent, and never on a guess.** A turn moves to a reserve
   only on CONFIRMED exhaustion, every answer names the model that gave it, and
   every crossing of a threshold is announced once.

## Part 1 - the seam and the rows

### `STEWARD_USAGE_CMD`

Resolved exactly like the liveness seam, in this order: process environment,
the operator config, the estate file's `USAGE_CMD` row (an optional field with
its own reader, no schema bump - `registry_usage_cmd`, distinguishing "absent"
rc 0 from "invalid" rc 78). Same guards, same reasons: absolute path, never a
bare name, executable, an outer timeout that fails a hung shim, the shim's
stderr kept as evidence. Unset is a normal state and reports `unknown` with the
reason `seam-not-configured`.

### The row contract

`usage_rows` - one TSV row per window the command ANSWERED ABOUT, on stdout:

```
login<TAB>provider<TAB>window<TAB>used_percent<TAB>resets_at<TAB>measured_at<TAB>budget_id<TAB>note
```

| field | meaning |
|-------|---------|
| `login` | the `logins.d` slug the window belongs to. Rows for a login the registry does not know are dropped and counted, never shown. |
| `provider` | the login register's closed vocabulary (`claude-max`, `claude-team`, `opencode-chatgpt`, `codex-openai`), plus `openai-api` for the pay-as-you-go source the api-resources work adds later. |
| `window` | `5h`, `week`, `week-<model>`, `month`. Free-form after the known prefixes; the desk shows every window it gets. |
| `used_percent` | integer 0-100, or `unknown`. **A parse failure is `unknown`, never 0 and never 100** - the Claude source is text parsing and the shim must verify its own parse separately. |
| `resets_at` | ISO 8601 UTC, or empty when unknown. |
| `measured_at` | ISO 8601 UTC. The desk shows measurement AGE beside every number; a stale number is worse than none. |
| `budget_id` | the VERIFIED budget identity: the account id from the Codex rate-limit answer, the organisation from Claude. Empty when the shim cannot verify one. Two logins with the same `budget_id` share one plan; identical numbers prove nothing and are never used to infer sharing. |
| `note` | free text from the shim (the raw reason for `unknown`, the plan type). |

`usage_for <login> <window>` answers from the rows loaded by the one call; a
window not mentioned is `unknown`.

### The login on a session (owner field)

The session contract (`desk/SCHEMA.md`, `sessions[]`) gains `login`:

```
login: { slug, provider, label } | null
```

- `claude-code` rows: `LOGIN` from the row; `label` is the login's `ACCOUNT`
  shown as a label, never used as a key (it is an e-mail address).
- `codex` rows: the machine account's one Codex login; `provider` is `codex-openai`,
  `label` is the plan type from the last rate-limit row when one exists.
- `opencode` rows: `provider` is the provider half of `MODEL`; `slug` is the row's
  `LOGIN` when set.

**Owner field.** `login` is present when `mine` is true or the viewer reads
everything; otherwise `null`. Which account a colleague pays with is theirs.

## Part 2 - the desk

Per viewer file, `usage[]`, grouped by login, **only for logins whose PRINCIPAL
is the viewer**:

```
usage[]: { login, provider, label, budgetId,
           windows[]: { name, usedPercent, resetsAt, measuredAt, ageSeconds } }
```

The index shows one line per login above the sessions running on it -
`5h 63 % - resets 09:49` - red past the threshold, every window listed, the age
of the measurement beside it.

**Read-all sees state, not numbers.** A `DESK_READ_ALL` viewer gets, per login
in the fleet, `usageState`: `ok`, `near` (past the threshold), `exhausted` (a
window at 100 or a confirmed rate limit), `unknown`. No percentages, no reset
times, unless a separate mandate is written later. This is the one place where
read-all does not win: it reads the estate, and a person's drain rate is not the
estate's.

The operator file (`_operator`) carries `usage[]` in full - it is the estate's
own record, readable by the machine account alone.

## Part 3 - the alarm

The watch alerts **once per window per reset** when a window crosses the
threshold (`STEWARD_USAGE_ALERT_PERCENT`, default 90) and again when it reaches
100 or a turn met a confirmed rate limit. Delivery is a `DRIFT` on the bus to
the login's principal and to the hub: `tokens exhausted for <login> (<provider>),
resets <time>; turns run on <reserve>` - or `no reserve on the row` when there is
none. Dedup key: `budget_id` (falling back to the login slug) + window + `resets_at`,
so a shared plan alarms once, not once per login, and a new window alarms afresh.
Same mechanism as the unacked-mail dedup in `watch/lib.mjs`.

`unknown` never alarms and never clears an alarm; a seam that stopped answering
is its own alert (`seam-*` reasons), as for liveness.

## Part 4 - the turn: reserve, not pause

**Operator, 09:15Z:** "I do not want a job lying and waiting; queue it where
there are tokens instead, plus a notice that tokens are out."

The session row gains `FALLBACK_MODEL` - a space-separated list in `MODEL`'s
grammar (`provider/model`), tried in order. Empty means no reserve. For an
`opencode` row a reserve is typically another provider's model behind another
login; for a `codex` row there is no reserve via an API key in v1 (one Codex
login per account and machine; the api-resources work may add one later).

Before a turn the adapter (`runtime/codex-session.sh`, `runtime/opencode-session.sh`)
calls the seam for the row's login. Then:

| measured | action |
|----------|--------|
| below threshold | run on `MODEL`. |
| past threshold, below 100 | run on `MODEL`; the alarm in part 3 says so. **A percentage does not predict the size of the next turn** (advisor), so it is not a reason to switch. |
| 100 with a fresh measurement (age under the window's own resolution, one minute), OR the provider answered the previous turn with a rate limit | take the first entry of `FALLBACK_MODEL` whose own login's window is not exhausted; run there. |
| nothing has capacity | leave the letter STAGED - neither acknowledged nor requeued - log `PAUSED until <earliest resets_at>`, exit 75. Not a failed turn. Resume after that time with jitter and a NEW measurement; a rate-limit `retry-after` wins over the reset time when both exist. |
| `unknown` | run on `MODEL`. The seam being blind is not a reason to move a person's work to another bill. |

**Every answer is stamped** with the model that gave it: the last line of the
reply and the ledger entry. A switch that nobody can see afterwards is a switch
that never happened.

**Reserve is chosen per TURN** (ruling; the advisor left it open between turn
and round). One fresh measurement per turn is cheap, and a round that started on
the reserve should come back to the primary the moment its window resets - the
primary is always the subscription, the reserve is never first choice.

**An interrupted turn is reconciled before any retry.** Tools may already have
run. The Codex adapter has this in its thread-read path; the opencode adapter
needs the equivalent before it may retry on a reserve.

**`claude-code` rows have no adapter**: the person in the pane gets the notice
(part 3) and changes model with their own hands. Nothing else.

**Ping, liveness and the queue work with zero model budget.** They never call a
model; usage never gates them.

## Shared plans

Two logins with one `budget_id` drain one plan. The desk shows the same numbers
under both (each owner sees their own), the alarm fires once. Whether the hub
should have a plan of its own is a cost decision for the operator, never an
automatic action - the product only makes the sharing visible.

## Non-goals

- Buying capacity, rotating keys, or any provider-side action.
- Money. Cost in currency is the api-resources work (an estate spec): its
  monthly `openai-api` rows fit this contract as a fourth source and inherit
  the alarm and the desk projection unchanged.
- Predicting whether the next turn fits.
- Reserve for `claude-code` rows.

## Build order, one task each, each with a fixture

1. **The seam and the rows.** `lib/usage.sh` (`usage_rows`, `usage_for`,
   `registry_usage_cmd`), with a stubbed shim in the fixture: known logins,
   an unknown login (dropped and counted), a malformed percent (`unknown`),
   a missing seam, a hung shim (timeout), a relative path (refused).
2. **The login on the session and the desk projection.** `login` as an owner
   field; `usage[]` for the viewer's own logins only; `usageState` for read-all;
   the operator file in full. The fixture asserts a member sees neither the
   login nor a number, a manager sees neither, read-all sees state only.
3. **The alarm.** Threshold and 100 crossings, once per window per reset, dedup
   on `budget_id`, `unknown` inert, delivery as `DRIFT` to principal and hub.
4. **The turn.** `FALLBACK_MODEL` in the registry grammar; the adapters' table
   above with a stubbed seam and a stubbed rate-limit answer; the stamp on the
   reply and in the ledger; exit 75 leaves the letter staged (asserted: not
   acknowledged, not duplicated); the opencode reconcile-before-retry path.

Each task is a product change: English, ASCII, no estate or person names, tests
that never touch a real provider, a real socket or a real home.
