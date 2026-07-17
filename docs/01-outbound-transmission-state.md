# Outbound Transmission State — Specification

> **Purpose** Define one durable record representing one logical transmission from Care Connect to another system, and the exact rules for moving it between states.
> **Audience** Salesforce developers building or maintaining Care Connect outbound.
> **Status** **Specification + object metadata only. No Apex exists yet.** This document is the approval gate for the callout code.
> **Last verified against** `Integration_Transmission__c` deployed to the `careconnect` org — **17/17 fields**, 7 identity fields confirmed `required` by `describe` **and** by a live insert returning `REQUIRED_FIELD_MISSING`; defaults (`Status=Pending`, `Retry_Count=0`) proven by live insert; picklist API-name behaviour proven by live insert. Layout: 18/18 fields `Readonly`. **No Apex in this org yet.**
> **Owner** Care Connect integration team.
> **Related** `force-app/main/default/objects/Integration_Transmission__c/`, `permissionsets/Integration_Transmission_Support` (read-only), `permissionsets/Integration_Transmission_Runtime` (execution path). `Integration_Admin` deliberately does **not** cover this object.

## Why this object exists

`Integration_Log__c` records **individual attempts**. It must **never** be the source of truth for
whether a referral still needs sending — deriving "outstanding work" from a log means reconstructing
state from history, which is fragile and unqueryable.

| Question | Answered by |
|---|---|
| *Does this referral still need sending to Attorney?* | **`Integration_Transmission__c`** (one row, current state) |
| *What happened on attempt 3?* | `Integration_Log__c` (one row per attempt) |

Attorney-specific fields on `Referral__c` were rejected: Care Connect will send to **both** Attorney
and Provider, and `Target_System__c` keeps one object serving both.

## Object

`Integration_Transmission__c` · Name: Auto Number `TRN-{00000}`

| Field | Type | Ext ID | Unique | Req | Purpose |
|---|---|:--:|:--:|:--:|---|
| `Referral__c` | Lookup(`Referral__c`) | | | ✅ | Source referral. **`deleteConstraint = Restrict`** |
| `Target_System__c` | Picklist *restricted* | | | ✅ | API names `ATTORNEY`, `PROVIDER` (labels: Attorney, Provider) |
| `Operation__c` | Picklist *restricted* | | | ✅ | API name `CREATE_REFERRAL` (label: Create Referral) |
| `Transmission_Key__c` | Text(255) | ✅ | ✅ | ✅ | Prevents duplicate logical transmissions |
| `Correlation_Id__c` | Text(36) | ✅ | ✅ | ✅ | v4 UUID, **one per transmission**, reused across every attempt |
| `Status__c` | Picklist *restricted*, default `Pending` | | | ✅ | `Pending`, `Processing`, `Retry Scheduled`, `Succeeded`, `Failed` |
| `Retry_Count__c` | Number(3,0), default `0` | | | ✅ | Retries performed (attempts = `Retry_Count + 1`) |
| `Next_Retry_At__c` | Date/Time | | | | When another attempt becomes eligible |
| `Last_Attempt_At__c` | Date/Time | | | | Most recent attempted callout |
| `Processing_Started_At__c` | Date/Time | | | | Detects abandoned claims |
| `Claim_Token__c` | Text(36) | | | | v4 UUID, **new per attempt** |
| `Last_Status_Code__c` | Number(3,0) | | | | Most recent HTTP status |
| `Last_Error_Code__c` | Text(80) | | | | **Controlled vocabulary only** |
| `External_Record_Id__c` | Text(36) | | | | The remote system's durable id (Attorney: a v4 UUID) |
| `External_Record_Key__c` | Text(80) | ✅ | ✅ | | `TARGET_CODE\|EXTERNAL_RECORD_ID` — namespaced uniqueness |
| `External_Salesforce_Id__c` | Text(18) | | | | Foreign org record Id — **diagnostics only** |
| `Succeeded_At__c` | Date/Time | | | | Final successful completion |

**Never on this object:** raw error messages, request payloads, responses. Attempts belong in
`Integration_Log__c`, sanitized.

### Identity fields are required at the database

**A unique constraint does not imply presence.** Salesforce permits many rows holding NULL in a
unique field, so uniqueness alone would still allow rows that identify no logical transmission at
all — a null target, operation, key and correlation id, with `Status` merely defaulting to Pending.

Every field that forms a transmission's identity is therefore `required` at the database, not only in
prose. Verified in the org:

```
insert new Integration_Transmission__c(Referral__c = r.Id);   // everything else null
-> REQUIRED_FIELD_MISSING: [Correlation_Id__c, Transmission_Key__c, Operation__c, Target_System__c...]

insert (Status and Retry_Count omitted)
-> Status__c = Pending    Retry_Count__c = 0     // defaults applied
```

This was enforced pre-production, while the object holds no data — the only cheap moment to do it.

### Lookup, not Master-Detail — and why the platform agreed

Master-Detail would cascade-delete integration history with its parent, couple ownership, and **lock
the parent `Referral__c` on every attempt update** (a retry storm would serialize on the referral).

A **required Lookup** forces a delete-semantics decision that Master-Detail makes silently for you.
Salesforce rejected the deploy until one was declared:

```
field integrity exception: must specify either cascade delete or restrict delete
for required lookup foreign key
```

`Cascade` is ruled out by the very reason we avoided MD. So: **`Restrict`** — a referral with
transmissions cannot be deleted. **You cannot accidentally erase the audit trail.**

### External ids are namespaced, not globally unique

This object is deliberately generic across Attorney, Provider, and future systems. **An external id
is only meaningful inside its target system's namespace** — two systems may legitimately issue the
same identifier string, and a globally unique `External_Record_Id__c` would impose false uniqueness
across unrelated systems.

So uniqueness lives on a namespaced key:

```
External_Record_Key__c = <target code> | <external record id>

ATTORNEY|550e8400-e29b-41d4-a716-446655440000
PROVIDER|550e8400-e29b-41d4-a716-446655440000     ← legitimately coexists
```

That still prevents **one Attorney record being claimed by two transmissions** — which would mean
remote idempotency is broken, and should surface loudly at the database — without inventing a
constraint between systems that have nothing to do with each other.

`External_Record_Id__c` remains queryable for humans and reports; `External_Record_Key__c` carries
the constraint.

### The state machine is the only writer

The invariants above (immutable correlation id, defined transitions only, tokens belonging to active
attempts, Succeeded terminal) are worthless if a person can edit the fields by hand. Record-level
access must not casually bypass them:

| Control | Setting |
|---|---|
| Page layout | **Every field `Readonly`** — including universally required ones (Salesforce permits this; verified) |
| `Integration_Admin` | **No longer covers this object at all** |
| `Integration_Transmission_Support` | Read-only. For investigation. Cannot create, edit **or delete**. |
| `Integration_Transmission_Runtime` | Create/read/edit for the execution path only. **No delete. No Modify All.** |

**Delete is granted to nobody.** `Restrict` on the parent lookup stops a referral cascading its
history away — that protection is void if a human can delete the child directly. The transmission
*is* the operational history.

**Manual retry is not field editing.** Transition #9 must be a controlled action performing the
transition atomically. Editing `Status__c` by hand is not a supported path — and with the layout
read-only and support access read-only, it is not an available one either.

> A Setup administrator can always change metadata deliberately. That is a different threat from
> ordinary record editing quietly corrupting state, which is what these controls close.

**Deployment consequence — do not skip this.** Because `Integration_Admin` no longer covers this
object, one of the scoped permission sets **must** be assigned or the object is inaccessible:

```bash
sf org assign permset -n Integration_Transmission_Runtime -o careconnect   # execution path
sf org assign permset -n Integration_Transmission_Support -o careconnect   # humans
```

The failure mode is deceptive: **without FLS, the Salesforce API reports a field as absent, not as
forbidden.** After the split, `describe` showed only the 7 required fields (which need no FLS) and
silently omitted the other 10 — they looked deleted. They were not. If a field "disappears", check
permission-set assignment before you suspect the deploy.

## Uniqueness — forever, never status-dependent

```
Transmission_Key__c = <18-char Referral Id> | <target code> | <operation code>

a0B5g0000012345EAA|ATTORNEY|CREATE_REFERRAL
```

**One referral has exactly one logical Attorney-create transmission — permanently.** Retries and
manual resubmissions **reuse that record and its correlation ID**. They never create another.

> ⚠️ **`Status__c` must never be part of the key.** With status in the key, flipping to `Succeeded`
> or `Failed` frees the old slot and a duplicate row for the same business operation slips in
> through the back door. That would be a duplicate achieved *accidentally*.

**If multiple independent transmissions are ever genuinely needed** for the same operation, add an
explicit `Source_Event_Id__c` or generation number to the key. Make it deliberate and visible —
never a side effect of status.

### The key is built directly from picklist API names

Picklist values carry a **label** and an **API name**, and they are independent. The key is built
from the **stored value**, which is always the API name:

| Field | API name (stored, used in the key) | Label (display only) |
|---|---|---|
| `Target_System__c` | `ATTORNEY` | Attorney |
| `Target_System__c` | `PROVIDER` | Provider |
| `Operation__c` | `CREATE_REFERRAL` | Create Referral |

```apex
key = referralId + '|' + t.Target_System__c + '|' + t.Operation__c;
// -> a01000000000001AAA|ATTORNEY|CREATE_REFERRAL
```

**An admin may rename the label to `Attorney Firm`; the API name, the stored value and the key are
unaffected.** No Apex mapping layer is needed — and an Apex value→code map would be *worse*, because
it adds a second place to drift.

**Verified against this org, not assumed:**

| Test | Result |
|---|---|
| Insert with the **label** `'Create Referral'` (API name `CREATE_REFERRAL`) | **`INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST`** — the label is not a valid value |
| Insert with lowercase `'attorney'` | Stored as **`ATTORNEY`** — matching is case-insensitive, storage is normalized to the API name |
| Key built from the stored value | `a01000000000001AAA\|ATTORNEY\|CREATE_REFERRAL` |

> **Note:** a picklist value's `fullName` cannot be changed in place by a deploy — Salesforce adds a
> new value and rejects the duplicate label. Changing an API name means dropping and recreating the
> field, which is only safe before any data exists.

**Controls — enforced now vs planned.** These are different things and the distinction matters:

| Control | Status |
|---|---|
| Uppercase, stable picklist **API names** in the metadata | ✅ **Enforced now** — deployed and verified |
| `Transmission_Key__c` **Unique + External ID** at the database | ✅ **Enforced now** — deployed and verified |
| **Protect picklist API names** from casual modification (org setting) | ⏳ **Planned** — not yet configured |
| Test asserting the expected API names still exist | ⏳ **Planned** — no Apex in this org yet |

Nothing in this repository *enforces* the planned rows today. This PR contains zero Apex, so any
claim of a test-based control would be a promise, not a control.

## State machine

```
      Pending
         │ claim
         ▼
    Processing ──── valid successful response ────► Succeeded (terminal)
         │
         ├──────── transient failure (budget left) ─► Retry Scheduled
         ├──────── transient failure (budget gone) ─► Failed
         ├──────── permanent failure ───────────────► Failed
         │
         └──────── abandoned/stale claim ──────────► Retry Scheduled

  Retry Scheduled ── due time reached and claimed ─► Processing

  Failed ────────── manual retry ───────────────────► Retry Scheduled
                                          (same Correlation_Id__c)
```

### Transition table — the normative rules

| # | From | Event | To | Field writes |
|---|---|---|---|---|
| 1 | *(none)* | Referral becomes eligible | **Pending** | `Correlation_Id = Uuid.v4()` **once**; `Transmission_Key = key`; `Retry_Count = 0` |
| 2 | Pending | claimed | **Processing** | `Claim_Token = Uuid.v4()`; `Processing_Started_At = now`; `Last_Attempt_At = now`. **`Retry_Count` unchanged** — this is attempt 1, not a retry |
| 3 | Retry Scheduled *(`Next_Retry_At <= now` **and `Retry_Count < MAX_RETRIES`**)* | claimed | **Processing** | **`Retry_Count++`**; `Claim_Token = Uuid.v4()`; `Processing_Started_At = now`; `Last_Attempt_At = now` |
| 4 | Processing | **valid** success response | **Succeeded** | `External_Record_Id`, **`External_Record_Key = <target code>\|<external id>`**, `External_Salesforce_Id`, `Last_Status_Code`, `Succeeded_At = now`; **clear `Claim_Token`, `Processing_Started_At`, `Next_Retry_At`, `Last_Error_Code`** |
| 5 | Processing | transient failure, `Retry_Count < MAX_RETRIES` | **Retry Scheduled** | `Last_Status_Code`, `Last_Error_Code`, `Next_Retry_At = backoff`; clear `Claim_Token`, `Processing_Started_At` |
| 6 | Processing | transient failure, `Retry_Count >= MAX_RETRIES` | **Failed** | `Last_Status_Code`, `Last_Error_Code = RETRY_BUDGET_EXHAUSTED`; **clear `Claim_Token`, `Processing_Started_At`, `Next_Retry_At`** |
| 7 | Processing | permanent failure | **Failed** | `Last_Status_Code`, `Last_Error_Code`; **clear `Claim_Token`, `Processing_Started_At`, `Next_Retry_At`** |
| 7b | Processing | **`External_Record_Key__c` collision** (`DUPLICATE_VALUE` on the unique key) | **Failed** | `Last_Error_Code = EXTERNAL_RECORD_CONFLICT`; **do NOT persist the conflicting external identifiers**; clear `Claim_Token`, `Processing_Started_At`, `Next_Retry_At`. **Never retried.** |
| 8a | Processing *(stale: `Processing_Started_At < now - STALE_AFTER`)* **and `Retry_Count < MAX_RETRIES`** | recovery sweep | **Retry Scheduled** | `Last_Error_Code = STALE_CLAIM_RECOVERED`; `Next_Retry_At = now`; clear `Claim_Token`, `Processing_Started_At` |
| 8b | Processing *(stale)* **and `Retry_Count >= MAX_RETRIES`** | recovery sweep | **Failed** | `Last_Error_Code = RETRY_BUDGET_EXHAUSTED`; clear `Claim_Token`, `Processing_Started_At`, `Next_Retry_At`. **Not returned to the loop.** |
| 9 | Failed | manual retry | **Retry Scheduled** | `Retry_Count = 0`; `Next_Retry_At = now`; clear `Last_Error_Code`. **`Correlation_Id` unchanged** |
| 10 | Succeeded | — | *terminal* | No transition out. Ever. |

### Invariants

1. `Correlation_Id__c` is **immutable** after insert — including on manual retry.
2. `Transmission_Key__c` is **immutable** after insert.
3. **Succeeded is terminal.**
4. Only **Pending** or **Retry Scheduled** (and due) are claim-eligible.
5. `Claim_Token__c` is non-null **only** while `Status = Processing`.
6. `Retry_Count__c` increments **only** on transition #3.
7. `Next_Retry_At__c` is meaningful **only** in Retry Scheduled — every terminal transition clears it, along with `Processing_Started_At__c` and `Claim_Token__c`. `Last_Attempt_At__c` is never cleared: it is the durable record of when the last attempt began.
8. `External_Record_Id__c` / `External_Record_Key__c` are written **only** on transition #4, and only after validation.
9. **Delivery is at-least-once.** Duplicate delivery is prevented by the receiver's idempotency, never by this object.

### `Retry_Count__c` — exact semantics

`Retry_Count` counts **retries**, not attempts. Attempts = `Retry_Count + 1`.

With `MAX_RETRIES = 3`:

| Attempt | Claimed from | `Retry_Count` after claim | Transient failure → |
|---|---|---|---|
| 1 | Pending | 0 | `0 >= 3`? No → Retry Scheduled |
| 2 | Retry Scheduled | 1 | `1 >= 3`? No → Retry Scheduled |
| 3 | Retry Scheduled | 2 | `2 >= 3`? No → Retry Scheduled |
| 4 | Retry Scheduled | 3 | `3 >= 3`? **Yes → Failed** |

Total: 4 attempts = 1 initial + 3 retries.

### The budget must be *enforced* on the stale path, not merely counted

**Counting an attempt is not the same as enforcing the ceiling.** This is the subtle failure. The
transient-failure path (#5/#6) checks `Retry_Count` against `MAX_RETRIES`. A sender that *dies* never
returns a classifiable failure — it goes stale and is recovered by the sweep. If recovery
unconditionally returned the row to Retry Scheduled, a sender that dies every time would loop
**forever**, incrementing but never failing:

| Attempt | Claim | Outcome | If #8 has no budget check |
|---|---|---|---|
| 1 | count → 0 | sender **dies** | stale → Retry Scheduled |
| 2 | count → 1 | sender **dies** | stale → Retry Scheduled |
| 4 | count → 3 | sender **dies** | stale → Retry Scheduled → **attempt 5, 6, …** ✗ |

So the ceiling is enforced in **both** places a row can leave Processing:

- **Transient failure:** #5 (budget left) vs #6 (`RETRY_BUDGET_EXHAUSTED` → Failed).
- **Stale recovery:** #8a (budget left) vs #8b (`RETRY_BUDGET_EXHAUSTED` → Failed).

And the claim itself (#3) refuses a due row already at the ceiling (`Retry_Count < MAX_RETRIES`) — a
defensive backstop so that even a row left in Retry Scheduled at the ceiling by some future bug
cannot authorize another sender.

With that, a sender that dies every time terminates at exactly **1 initial attempt + `MAX_RETRIES`
retries → Failed**, whether the deaths are classifiable failures or stale-outs, or any mix.

## `Processing` cannot be the lock

This is **unsafe** and must not be written:

```apex
if (transmission.Status__c == 'Pending') {   // two jobs can both read Pending
    transmission.Status__c = 'Processing';   // before either commits
    update transmission;
    performCallout();                        // ...and both send
}
```

### Two-transaction claim design

**Transaction 1 — claim** (`ClaimAttorneyTransmissionQueueable`, **no callout**)

1. `SELECT ... FROM Integration_Transmission__c WHERE Id = :id FOR UPDATE` — the row lock makes only
   one job capable of claiming.
2. Verify `Status = Pending`, or `Status = Retry Scheduled AND Next_Retry_At <= now AND
   Retry_Count < MAX_RETRIES`. Otherwise **exit silently** — someone else won, or the budget is
   already spent; both are normal outcomes, not errors. (A due row at the ceiling is not claimed
   here; the sweep's #8b path fails it instead.)
3. `Status = Processing`; `Claim_Token = Uuid.v4()`; `Processing_Started_At = now`;
   `Last_Attempt_At = now`; increment `Retry_Count` if claiming from Retry Scheduled.
4. Enqueue the callout job with **transmission Id + claim token**.

> **`FOR UPDATE` can throw `UNABLE_TO_LOCK_ROW`** when another transaction holds the lock. That means
> *"someone else is claiming it"* — a **normal outcome**. Catch it and exit cleanly. Do **not** let it
> surface as a 500 or a failed transmission.

**Transaction 2 — send** (`SendReferralToAttorneyQueueable`)

1. Reload the transmission.
2. Confirm `Status = Processing` **and** the supplied claim token **matches**. Otherwise **exit
   without sending** — this job is stale or duplicate.
3. Build the request → **callout** → validate the response.
4. Update transmission state → write **exactly one** attempt log.

This also satisfies the platform rule that a callout cannot follow DML in the same transaction: T1
does the DML, T2 does SOQL → callout → DML.

### Delivery guarantee: at-least-once, not exactly-once

**This is the most important limitation in this document.**

The claim token protects **local state authority**. It cannot guarantee exactly-once **remote
delivery**, because it cannot retract an HTTP request that has already left:

```
Sender A            claims, sends request ──────────────────────►  Attorney
                              │ (still in flight)
Recovery sweep      declares the claim stale
Sender B            re-claims, sends request ──────────────────►  Attorney
                                                                   ↑
                                              BOTH requests arrive
```

Sender A's now-stale token stops it **overwriting Care Connect state** when it finally returns. It
does **not** un-send its request.

> **Normative statement.** Delivery is **at-least-once**. Claim tokens prevent stale *state updates*;
> the **Attorney API's idempotency** (keyed on the Care Connect referral Id) is what prevents
> duplicate *business records*. There is no mechanism here that makes delivery exactly-once, and none
> is planned — the correct place for that guarantee is the receiver, and it already exists there.

**Consequences that must not be forgotten:**

- Every operation Care Connect sends **must** be idempotent at the receiver. `Create Referral` is.
  A future non-idempotent operation cannot use this design as-is.
- `STALE_AFTER` **must exceed the callout timeout** (a Salesforce callout may run up to 120s). A
  shorter window would manufacture the overlap above on healthy traffic rather than only on genuinely
  dead jobs. Recommend ≥ 15 minutes.
- Duplicate delivery is **expected and safe**, not an incident. Two Attorney log rows with one
  correlation id are normal.

### The three identifiers, and why each exists

| | Scope | Purpose |
|---|---|---|
| `Correlation_Id__c` | One per **logical transmission** | End-to-end tracing across both orgs. Reused by every attempt. |
| `Claim_Token__c` | One per **attempt** | Local concurrency safety. Proves a job is the *currently authorized* attempt. |
| `Retry_Count__c` | Per transmission | Operational: which attempt is this, and is the budget spent? |

Tracing and concurrency safety are different problems. One identifier cannot do both: a correlation
id that changed per attempt would destroy tracing; a claim token reused across attempts would not
stop a stale job.

## Response validation — 2xx is not success

**An HTTP 2xx alone does not mean the transmission succeeded.** Before persisting any Attorney
identifier, **all** must hold:

| Check | On failure |
|---|---|
| `response.success == true` | treat as failure |
| `response.correlationId == transmission.Correlation_Id__c` | `INVALID_RESPONSE` |
| `response.attorneyCaseId` is a valid **v4 UUID** | `INVALID_RESPONSE` |
| `response.attorneyCaseRecordId` is null **or** a valid 18-char Salesforce Id | `INVALID_RESPONSE` |
| required status fields present | `INVALID_RESPONSE` |

**Do not validate the key prefix of `attorneyCaseRecordId`.** It belongs to a **foreign** Salesforce
org, and custom key prefixes are assigned per-org. Asserting one would couple us to a value Attorney
never promised. *(Same reasoning the Attorney org applies to our referral Ids, in the other
direction.)*

**A malformed response or a correlation mismatch → `Retry Scheduled`, `Last_Error_Code = INVALID_RESPONSE`.**
Retrying is safe: Attorney inbound is idempotent by Care Connect referral Id, so a retry cannot
create a duplicate case. The retry budget bounds a persistently malformed contract.

> **This is Phase 3's lesson applied symmetrically.** We spent five review rounds making Attorney
> refuse untrusted input from Care Connect. A response is untrusted input too — including from a
> system we wrote.

### External record collision — a permanent condition, never a retry

Transition #4 writes the unique `External_Record_Key__c`. If that write collides, the naive path is
an **infinite loop**, not a transient failure:

```
Attorney returns success
        ↓
response passes validation
        ↓
External_Record_Key__c update violates uniqueness
        ↓
transaction rolls back  →  transmission stays Processing
        ↓
sweeper recovers it and re-sends
        ↓
same success, same DML failure, forever
```

Nothing about waiting fixes it. A collision means **two Care Connect transmissions claim the same
target-system business record** — which means either remote idempotency is broken or our own keying
is wrong. Both need a human.

**Rule (transition #7b).** Catch the `DUPLICATE_VALUE` on `External_Record_Key__c` specifically.
**Do not persist the conflicting external identifiers.** Move to **Failed** with
`Last_Error_Code = EXTERNAL_RECORD_CONFLICT`, write one controlled log row, and **never enter the
retry loop.** Classification is **permanent / requires investigation** — the one error code that
means *stop and look*, not *try again*.

Note this is the one place a `DUPLICATE_VALUE` must **not** be treated the way the claim path treats
it. On the claim path a duplicate means "someone else won, resolve to their row" — a normal outcome.
Here it means "two rows disagree about reality" — a defect. Same status code, opposite meaning.

## Failure classification

`Last_Error_Code__c` holds a **controlled internal vocabulary only** — never a remote message, never
a platform exception message. An unrecognised condition maps to `UNKNOWN`.

| Code | Trigger | Class |
|---|---|---|
| `RATE_LIMITED` | 429 | **transient** |
| `SERVER_ERROR` | 500, 502, 503, 504 | **transient** |
| `TIMEOUT` | 408 / callout timeout | **transient** |
| `CALLOUT_FAILED` | `CalloutException` | **transient** |
| `INVALID_RESPONSE` | failed response validation | **transient** |
| `VALIDATION_REJECTED` | 400 | **permanent** |
| `UNAUTHORIZED` | 401, 403 | **permanent** |
| `NOT_FOUND` | 404 | **permanent** |
| `CONFLICT` | 409 | **permanent** |
| `EXTERNAL_RECORD_CONFLICT` | `External_Record_Key__c` collision on transition #4 | **permanent — requires investigation.** Never retried. |
| `RETRY_BUDGET_EXHAUSTED` | transient failure with no budget left | **terminal** |
| `STALE_CLAIM_RECOVERED` | recovery sweep | *(returns to Retry Scheduled)* |
| `UNKNOWN` | anything unclassified | **transient** |

**400 is permanent, deliberately.** The Attorney API rejects on a field-level rule; retrying an
unchanged request is *guaranteed* to fail identically. **500 is transient and safe to retry**
precisely because Attorney inbound is idempotent.

`Last_Error_Code__c` is `Text(80)` rather than a restricted picklist on purpose: an unclassified
condition must degrade to `UNKNOWN`, not fail the DML that is trying to record a failure.

## Async topology — normative

Two separate platform limits constrain this, and **both** must be respected:

| Limit | Value | Breaks |
|---|---|---|
| `System.enqueueJob` per **synchronous** transaction | **50** | A trigger enqueuing one job per referral → `LimitException` on a 200-record insert, **and the referral insert itself fails** |
| `System.enqueueJob` per **asynchronous** transaction (chaining) | **1** | A dispatcher fanning out one sender per transmission → fails on the second enqueue |

The second limit is the one that bites: solving the trigger problem with "one dispatcher that fans
out" **does not work**, because an executing Queueable may enqueue only **one** child. The topology
must be a **serial chain**, not a fan-out.

```
Trigger transaction  (synchronous)
    │  enqueue ONCE  — guarded by a transaction-level static
    ▼
Dispatcher / claimant  (async)
    │  FOR UPDATE a bounded group; claim rows; assign a token to each
    │  enqueue EXACTLY ONE job
    ▼
Sender  (async)
    │  ALL callouts first  ──► then persist results + logs
    │  enqueue ONE next dispatcher when work remains
    ▼
Dispatcher / claimant  …
```

### Normative rules

1. **The trigger enqueues at most one dispatcher per transaction**, guarded by a **transaction-level
   static boolean**. A trigger can fire several times in one transaction (multiple DML statements,
   workflow field updates); without the guard, each firing enqueues another dispatcher.

2. **A dispatcher enqueues exactly one sender.** Never one per transmission.

3. **A sender performs every callout before any DML.** A callout may not follow DML in the same
   transaction, so a batched sender cannot call out → save → call out again. Either:
   - **(a)** perform all callouts for the claimed group, holding results in memory, then persist once
     — bounded by the 100-callout limit (use ~50 for headroom); or
   - **(b)** process exactly one transmission per sender transaction.

   **(a)** is more efficient; **(b)** has a smaller blast radius if the transaction dies after the
   callouts but before the DML. Under (a) that strands the whole claimed group in `Processing`, and
   every one of them has *already been delivered* — recovery will re-send them all. Attorney's
   idempotency absorbs it (see *Delivery guarantee*), but the tradeoff should be a deliberate choice.

4. **A sender enqueues at most one next dispatcher**, only when work remains — this is the chain.

The scheduled sweeper is the safety net and the uniform path for retries and stale recovery.

## Recovery sweep

A scheduled job — **not** a chained Queueable — drives:

```sql
SELECT Id, Status__c, Retry_Count__c FROM Integration_Transmission__c
WHERE (Status__c = 'Pending')
   OR (Status__c = 'Retry Scheduled' AND Next_Retry_At__c <= :now)
   OR (Status__c = 'Processing'      AND Processing_Started_At__c < :staleCutoff)
```

The sweep only *finds* candidates; the claim transaction (with `FOR UPDATE`) applies the precise
rules. In particular, `Retry_Count__c` is selected so each candidate can be routed:

- **Pending** → claim (#2).
- **Retry Scheduled**, due → claim if `Retry_Count < MAX_RETRIES` (#3), else it is a budget-spent row
  that should already be Failed; treat defensively.
- **Processing**, stale → **#8a** if `Retry_Count < MAX_RETRIES`, else **#8b** (`Failed`,
  `RETRY_BUDGET_EXHAUSTED`). **This budget check is what bounds a repeatedly-dying sender.**

Scheduled Apex rather than chained Queueables because it (a) is not bound by the Queueable delay cap,
so real exponential backoff is possible, and (b) reclaims stranded `Processing` rows. Chained
Queueables can do neither — and a Queueable that dies from an uncatchable limit exception leaves a row
stranded in `Processing`: without #8b it would be recovered forever; with #8b it fails after the
budget is spent.

## Backoff

`Next_Retry_At = Last_Attempt_At + BASE * 2^Retry_Count`, capped at `MAX_BACKOFF`.
With `BASE = 1 min`: retries at ~+1m, +2m, +4m. Constants live in one place; custom metadata later.

## Not yet built

**Status: Planned for Phase 4** — nothing below exists, and this document does not describe it:

`Uuid.cls` copy into Care Connect · transmission creation/claim service · `AttorneyReferralRequest` ·
`AttorneyReferralResponse` · response validation · `AttorneyApiService` · claim Queueable · callout
Queueable · trigger + handler eligibility · retry and stale-processing recovery · Named Credential /
Connected App · `HttpCalloutMock` tests.

**No callout code may be written until this specification is approved.**

## Tests this specification demands

| Test | Asserts |
|---|---|
| Duplicate claim prevention | Two claims on one transmission → exactly one sends |
| Stale claim token | A job with an outdated token exits without sending |
| Stale processing recovery (budget left) | `Processing` past the cutoff with `Retry_Count < MAX` → Retry Scheduled (#8a) |
| **Repeatedly-dying sender is bounded** | A sender that dies (goes stale) on **every** attempt produces **exactly 1 initial attempt + `MAX_RETRIES` retries**, ends in **Failed** (`RETRY_BUDGET_EXHAUSTED` via #8b), and **never authorizes another sender** afterward |
| Ceiling row is never claimed | A due Retry Scheduled row at `Retry_Count = MAX_RETRIES` is not claimed by #3 |
| Correlation reuse | Every attempt of one transmission shares one `Correlation_Id__c` |
| Claim token rotation | Each attempt gets a **new** `Claim_Token__c` |
| Response validation | Correlation mismatch / non-v4 id / `success:false` → `INVALID_RESPONSE`, nothing persisted |
| Retry budget | Exactly `MAX_RETRIES` retries, then Failed |
| Transient vs permanent | 400 → Failed immediately; 500 → Retry Scheduled |
| Duplicate transmission | Same (referral, target, operation) → `DUPLICATE_VALUE`, resolved to the existing row |
| Bulk trigger | 200 referrals inserted → no `LimitException` |
| **Label rename is harmless** | Renaming a picklist *label* leaves the API name present and the generated key **unchanged** — the test must **pass**, because this is supported behaviour, not a fault |
| **API-name drift is caught** | Removing or changing a picklist *API name* **fails** the drift guard |
| External record collision | A `DUPLICATE_VALUE` on `External_Record_Key__c` → Failed with `EXTERNAL_RECORD_CONFLICT`, identifiers not persisted, **no retry** |
| Terminal cleanup | Succeeded and Failed both leave `Claim_Token`, `Processing_Started_At` and `Next_Retry_At` null; `Last_Attempt_At` survives |
| Required identity fields | Inserting a transmission without target/operation/key/correlation id fails with `REQUIRED_FIELD_MISSING` |
| No delete | Neither permission set can delete a transmission |
