# Salesforce Integration Checklist

> **Purpose** A practical, reusable checklist for building a Salesforce integration — inbound or
> outbound, real-time or scheduled. It is organized so you can lift it into a new project, not only
> this one.
>
> **How to read it** Each section has a checkbox list, *why it matters*, *common failure modes*, and a
> **Tier** telling you whether it is essential for nearly every integration or an advanced protection
> to add based on risk, volume, and complexity. The [Implementation tiers](#implementation-tiers)
> section at the end bundles the protections into three delivery levels, and
> [Care Connect current status](#care-connect-current-status) records where this specific project
> stands.
>
> **Bias of this document** It front-loads the contract and the failure model, because the expensive
> mistakes are almost never in the happy-path callout — they are in what happens on the second attempt,
> the duplicate, the malformed response, and the row that two jobs both grabbed. Several items here are
> written from mistakes this project actually made; those are called out as **Hard-won**.

---

## 1. Business discovery and system ownership

- [ ] What real-world **event** starts the integration, and is it real-time, near-real-time, or scheduled?
- [ ] Which system **sends**, which **receives**, and what business outcome must occur?
- [ ] For each field, which system is the **source of truth**? Can both sides update it? How are conflicts resolved?
- [ ] Is the flow one-way or bidirectional?
- [ ] Who is allowed to **initiate a resend or correction**, and what should a user see on success and failure?

**Why it matters.** Ownership and directionality decide the entire data model and conflict strategy. If
you skip this, you discover halfway through that both systems "own" a field and you have no rule for
who wins.

**Common failure modes.** Bidirectional sync with no conflict rule (last-writer-wins by accident);
treating a downstream system's value as authoritative and overwriting the real source; no defined
human-visible outcome, so failures are invisible until someone asks "did that send?".

**Tier:** Essential — every integration. This is analysis, not code, and it is the cheapest step to get right.

---

## 2. Integration-pattern selection

- [ ] Choose the mechanism: REST callout, inbound Apex REST, Platform Events, Change Data Capture, scheduled sync, Salesforce Connect, or middleware (e.g. MuleSoft).
- [ ] Decide **synchronous vs asynchronous**, **single vs bulk**, and whether the caller needs an immediate response.
- [ ] Can the process tolerate **delayed** delivery? If yes, prefer async and a durable queue over a synchronous call.
- [ ] **Discover the platform limits that constrain the topology _before_ choosing it** (see §16). On Salesforce these routinely *dictate* the design, not merely tune it.

**Why it matters.** The pattern is hard to change later; it is baked into every class you write next.

**Common failure modes.** Choosing a synchronous callout for something that should be a durable queued
job, then discovering you cannot retry cleanly; fanning out one async job per record and hitting the
"one child enqueue per asynchronous transaction" limit on the second record.

> **Hard-won (lesson 5): governor and async limits shape the topology.** On this project the limits were
> the architecture, not tuning knobs:
> - **Cumulative callout timeout is 120 s per transaction** → a batching sender's batch size is bounded by
>   `batch × per-callout-timeout ≤ 120 s`, which is what set our batch of 3 at a 30 s timeout, *not* the
>   100-callout limit.
> - **A running Queueable may enqueue only one child** → you cannot fan out; you build a serial chain.
> - **Chained-Queueable depth is capped (5 in Developer/Trial orgs)** → a long chain needs an explicit
>   `AsyncOptions.MaximumQueueableStackDepth`, and an enqueue past the ceiling throws *after* your DML,
>   rolling it back — so check depth *before* enqueuing.
> - **A Scheduled Apex job runs at most once per hour** → a "retry in 1 minute" backoff can never be
>   honored by an hourly sweep; size the backoff to the scheduler.
>
> Decide these before you draw the boxes. Retrofitting them means redrawing the boxes.

**Tier:** Essential — every integration picks a pattern. The limit-discovery discipline is **essential for
async/bulk** and can be light for a single synchronous call.

---

## 3. API contract

- [ ] Endpoint, HTTP method, headers, and **API versioning** approach.
- [ ] Required vs optional fields; field **types and maximum lengths**; **allowed values**; date/time and identifier **formats**.
- [ ] The **success** response shape and every **error** response shape.
- [ ] A **stable idempotency key** in the request (see §9) — decide it here, in the contract.
- [ ] If the contract is **shared across two orgs you control**, treat the wire keys as a coupling: renaming a DTO field silently breaks both sides with no compile error.

**Why it matters.** The contract is the one artifact both teams agree on. Everything downstream —
DTOs, validators, mapping, tests — is derived from it.

**Common failure modes.** Undocumented max lengths that truncate or reject in production; a date format
mismatch that only fails for certain locales; "we'll define errors later," so the caller cannot
distinguish retryable from permanent.

> **Hard-won: pin the contract with a test when both sides are yours.** If your outbound DTO's Apex field
> names *are* the JSON keys the receiver reads, a rename compiles cleanly and breaks the integration at
> runtime. A shape test that asserts the exact key set turns that into a failed build. Add a **drift guard**
> for anything duplicated across orgs (field-name sets, picklist API values, error vocabularies).

**Tier:** Essential — every integration. The drift-guard tests are **advanced**, warranted when you own both ends.

---

## 4. Authentication and security

- [ ] Use a **Named Credential** (+ External Credential); **never hardcode secrets** in Apex.
- [ ] Pick an auth method deliberately (OAuth client-credentials, JWT, etc.); confirm TLS/HTTPS is enforced.
- [ ] Grant **least privilege**; decide who can view integration records and errors.
- [ ] Credentials must be **rotatable**; sandbox and production use **separate** configuration.
- [ ] Know where the config lives on **each** side (e.g. the Connected App in the target org, the Named/External Credential in the calling org) — this split is easy to get backwards.

**Why it matters.** Auth is the most common thing that "works in the demo" and fails on deploy, because
the live credential config is a separate, environment-specific task from the code.

**Common failure modes.** Secrets in Apex or in committed metadata; one credential shared across
sandbox and prod; a callout that passes mocked tests but was never exercised against a real token.

**Tier:** Essential — every integration. Named Credentials and no-hardcoded-secrets are non-negotiable
even for Tier 1.

---

## 5. Data model and state management

- [ ] Which business records participate, and where is the **external system's id** stored (External Id field)?
- [ ] Do you need a **transmission / delivery-state record** distinct from the business record?
- [ ] Do you need **per-attempt logs** distinct from current state?
- [ ] What **prevents duplicate** logical work at the database (a unique constraint), not just in code?
- [ ] For a **required lookup**, choose delete semantics deliberately (`Restrict` vs `Cascade`) so you cannot erase the audit trail.
- [ ] If **one object serves multiple integrations** (e.g. a shared transmission object for several targets), carry a **target/operation** discriminator on the row.

**Why it matters.** State is what makes an integration operable: it answers "what still needs sending?"
and "what happened on attempt 3?" — two different questions that need two different records.

**Common failure modes.** Deriving "outstanding work" by reconstructing it from log history (fragile and
unqueryable); a unique field that permits NULLs, so uniqueness silently allows identity-less rows;
Master-Detail that cascade-deletes integration history with its parent and locks the parent on every
attempt update.

> **Hard-won (lesson 3): the state record is the source of truth for outstanding work; logs are history
> only.** Never ask a log table "what still needs sending?" A single current-state row per logical
> transmission answers that with a query; attempt logs answer "what happened, when, and why," and must
> never be load-bearing for control flow.
>
> **Hard-won (lesson 6): authorize target and operation when an object is shared across integrations.** A
> deliberately generic transmission object (one object, many targets) means every consumer must *prove*
> the row it picked up is actually its own. Without it, a Provider row can be claimed and sent to the
> Attorney endpoint. Enforce it in **two** places: a **query filter** (`WHERE Target = 'ATTORNEY' AND
> Operation = 'CREATE_REFERRAL'`) so foreign rows never consume your batch budget, *and* a **route check
> against the freshly-locked row** before you mutate or call out, as defense in depth.

**Tier:** A state record and idempotency constraint are **essential** for anything with retries. Separate
attempt logs are **Tier 2**. Multi-target route authorization is **advanced** — add it the moment a second
integration shares the object or framework.

---

## 6. DTOs, mapping, and validation

- [ ] Define explicit **request and response DTOs**; do not serialize a whole SObject onto the wire.
- [ ] Keep **mapping** (SObject → DTO) separate from callout logic and from validation.
- [ ] Send **only the fields the receiver needs**. For each optional field, **define whether it should be omitted or explicitly sent as null** — follow the API contract, because omission and null can carry different meanings.
- [ ] Validate **before** the callout: required values present, ids valid, strings within contract limits, picklist values supported, dates in the expected format, related records exist.
- [ ] An invalid request must make **no callout** and surface a controlled error.
- [ ] Format wire values **explicitly** where the platform default is locale-dependent or ambiguous.

**Why it matters.** A pre-callout validator is your last safety net before you spend a callout on a
request that is guaranteed to fail — and it keeps a request you built wrong from ever leaving.

**Common failure modes.** Leaking internal fields by serializing the record; UI-only validation that a
system-context path bypasses; locale-dependent date formatting that produces the wrong string on some
users' records.

**Tier:** Essential — every integration. DTOs, a mapper, and a pre-callout validator are Tier 1.

---

## 7. HTTP implementation

- [ ] Correct endpoint, method, headers, and JSON serialization.
- [ ] A **deliberate timeout** (sized to the topology — see §2/§16, not just "the max").
- [ ] **No DML before a callout** in the same transaction; if batching, all callouts first, then all DML.
- [ ] Controlled exception handling that classifies rather than leaks (see §10).
- [ ] Clear separation between HTTP logic and database logic; the callout function returns a controlled outcome, it does not write state.

**Why it matters.** The "callout cannot follow DML" rule and the "all callouts before DML" batching
constraint decide the shape of your sender; getting them wrong produces `You have uncommitted work
pending` at runtime, not compile time.

**Common failure modes.** A callout after an incidental DML (even a log insert) throwing at runtime; the
maximum 120 s timeout chosen by default, which in a batch consumes the whole cumulative callout budget on
one hung call.

**Tier:** Essential — every integration.

---

## 8. Response validation

- [ ] **A 2xx proves HTTP-level success or acceptance, but the response must still satisfy the API contract.** When the contract includes a response body, validate its required fields and consistency. A valid `204` may intentionally have **no body**.
- [ ] Where the contract has a body: it is valid JSON; required fields present; success flag consistent; **request/response linkage** (e.g. a correlation id) matches — *where the contract defines these*.
- [ ] Returned identifiers have valid **formats**; returned status is a **supported** value.
- [ ] Bound the body size **before** parsing (heap protection); an oversized or unparseable body is a controlled failure, not a crash.
- [ ] Contradictory responses (e.g. `success:true` with a missing id) are **rejected**.

**Why it matters.** A response is untrusted input — including from a system you wrote. A retry after a
malformed response is safe *only if* the receiver is idempotent, which ties this to §9.

**Common failure modes.** Persisting a remote id from a 200 that was actually a partial failure; an
unbounded `JSON.deserialize` on a huge body blowing the heap; treating a nonblank-but-meaningless status
string as validated.

**Tier:** Essential to check `success` + ids; **advanced** to fully harden (size bounds, contradiction
rejection) — add for external or high-volume endpoints.

---

## 9. Idempotency and delivery guarantees

- [ ] The request carries a **stable idempotency key** (e.g. the source record id or a correlation id reused across retries).
- [ ] The key is **specific enough**: it may need to combine **source record + target system + operation + generation/version**. A source record id alone is insufficient when the same record can legitimately be transmitted more than once.
- [ ] The **receiver enforces idempotency** using a unique key, upsert, idempotency table, or equivalent mechanism, and returns a **consistent result for duplicate delivery**.
- [ ] The **sender** prevents duplicate logical transmissions with a **database unique constraint**, not a pre-query dedup.
- [ ] Be explicit in writing about **which delivery guarantee** you provide and **where** each part is enforced.

**Why it matters.** Retries and at-least-once delivery are only safe if the same request twice is
harmless. Idempotency is the property that makes every other reliability mechanism safe to use. This
section applies to **state-changing operations that may be retried**; a read-only `GET` is naturally
idempotent and does not need the same machinery.

**Common failure modes.** "Check if it exists, then insert" — a race window that creates duplicates under
concurrency; assuming your local claim logic prevents duplicate *delivery* (it cannot — see below).

> **Hard-won (lesson 4): name the guarantee and locate its enforcement.** This kind of design is
> **at-least-once, not exactly-once.** A claim token or local lock protects *local state* from a stale
> overwrite; it **cannot un-send an HTTP request already in flight.** The thing that prevents duplicate
> *business records* is the **receiver's** idempotency, keyed on the id you send. Write this down: "delivery
> is at-least-once; duplicate delivery is expected and safe because the receiver is idempotent." Also prefer
> a **DB unique constraint** as the single source of truth over a pre-query dedup — it removes the
> check-then-insert race entirely, and a post-insert requery *proves* idempotency rather than assuming it.

**Tier:** Essential — every integration with retries. The unique-constraint-as-authority refinement is
Tier 2.

---

## 10. Failure classification and retries

- [ ] Split failures into **transient** (timeout, 429, 500/502/503, network) and **permanent** (400, 401/403, invalid request, unsupported op, record conflict, missing config).
- [ ] Define **max retry count**, a **backoff schedule**, and a **next-retry time**; retry **only** transient failures.
- [ ] Preserve the **correlation id** across retries; ensure retries are idempotent.
- [ ] Define what happens when the **retry budget is exhausted** (a terminal Failed state), and provide a **controlled manual retry** as a separate, audited action.
- [ ] Use a **controlled internal error vocabulary** — never a raw remote or platform message — so an unclassified condition degrades to `UNKNOWN` rather than failing the write that records the failure.

> **Classification is per-endpoint and documented — not inferred from the status code alone.** Common
> defaults, to be confirmed against each endpoint's contract:
> - `429` and most `5xx` are **commonly transient** (safe to retry).
> - `400` is **commonly permanent** until the request itself changes.
> - `401`/`403` normally require **credential or permission correction**, but their handling depends on the
>   authentication design (e.g. a token-refresh path may make a `401` transient).
> - `404` and `409` can be **permanent, transient, an idempotent duplicate, or an expected business result**
>   depending on the endpoint contract.
>
> Document the transient/permanent mapping for **each endpoint** rather than assuming a status code's meaning.

**Why it matters.** Retrying a permanent failure wastes callouts and never succeeds; not retrying a
transient one drops deliverable work. The classification is the difference.

**Common failure modes.** Retrying a 400 forever; a backoff sized to a scheduler that cannot honor it
(see §16); a "manual retry" that is actually an ad-hoc field edit with no audit and no idempotency.

> **Hard-won: match the backoff to the scheduler.** Exponential backoff of 1/2/4 minutes is meaningless if
> the sweep that picks up due work runs hourly — the row becomes "due" but nothing looks at it for up to an
> hour. Size `BASE` to the scheduler (e.g. 60/120/240 minutes for an hourly sweep) and make the cap exceed
> the largest scheduled backoff, or the schedule flattens.

**Tier:** Classification + transient/permanent split is **essential**. Backoff + budget + a scheduled
retry path is **Tier 2**. A controlled, audited manual-retry action is **Tier 2–3**.

---

## 11. Concurrency and async processing

- [ ] Can two jobs process the same record? Do you need `FOR UPDATE` row locks and a `Processing` state?
- [ ] Do you need a **per-attempt claim token** so a stale job cannot overwrite a newer attempt's result?
- [ ] Is the concurrency check **authoritative at the right moment** — i.e. re-checked *after* the callout, against freshly-locked state, not only before?
- [ ] Prefer **singular** row locking in a loop over a batch `FOR UPDATE`, so one contested row does not fail the whole group.
- [ ] For chained async work, enforce a **maximum stack depth** and check it *before* enqueuing.

**Why it matters.** Under concurrency, "it worked in testing" is not evidence; two jobs, a re-claim
mid-callout, and a stale job returning late are the cases that corrupt state.

**Common failure modes.** A stale sender writing its result over a newer attempt and clearing that
attempt's token; a batch `FOR UPDATE` where one contested row throws `UNABLE_TO_LOCK_ROW` and takes the
whole batch's committed results down with it; an async chain that hits the depth ceiling and rolls back a
completed transaction on the failed enqueue.

> **Hard-won: the pre-callout authorization check is only an optimization; the authoritative check is
> after the callout.** A callout can run up to its timeout, and during it a recovery job can re-claim the
> row with a new token. So the sender must **re-lock (`FOR UPDATE`) and re-verify status + token
> immediately before writing**, and refuse if the token rotated. Use a **case-sensitive** comparison for
> tokens (Apex `==` on `String` is case-insensitive — use `.equals()`), and *test that property* so a future
> edit cannot silently weaken it.

**Tier:** **Advanced.** For lower-volume integrations, a `Processing` status check plus receiver
idempotency is often enough. Add claim tokens, authoritative post-callout re-checks, singular locking, and
depth policies as **Tier 3** — when concurrency and volume justify the complexity.

---

## 12. Logging, monitoring, and sensitive-data safety

- [ ] Each attempt log answers: what operation, which system, which record, which correlation id, when, success?, controlled error code, HTTP status, is another retry scheduled?
- [ ] **Never persist** raw request/response bodies, access tokens, stack traces with private data, or unrestricted exception messages.
- [ ] Identify **PII / PHI / financial / confidential** data explicitly and keep it out of logs.
- [ ] Log-writing must be **best-effort**: it must never roll back the business transaction — *and* it must **inspect** its results, not silently discard them.

**Why it matters.** Logs are the operator's only window, and simultaneously the easiest place to leak
sensitive data or to accidentally couple logging failures to business failures.

**Common failure modes.** A rejected log row rolling back the state it was recording; a "best-effort"
insert whose `SaveResult[]` is ignored, so failures vanish; logging a field just because you allowlisted
its name.

> **Hard-won (lesson 1): validate logged _values_, not just allowlisted _keys_.** Key-safety ("don't log
> the raw body") is not enough. A *modeled, allowlisted* field can still carry free text — a merely-nonblank
> `status`, a "notes"-shaped field. Log only values that have been **structurally validated** into an
> opaque or controlled form (a checksum-valid id, a controlled enum), turn PII into **presence booleans**
> (`emailProvided: true`), and never log a value merely because you named the key.
>
> **Hard-won (lesson 2): partial DML is incomplete unless every result is inspected.** `Database.insert(list,
> false)` preserves the good rows *only if* you (a) do not throw or use all-or-none DML afterward — an
> uncaught exception rolls back the whole transaction including the rows that succeeded — *and* (b) walk
> **every** `SaveResult`, surfacing failures as controlled status codes. "Do not throw" and "inspect the
> results" are one rule, not two. This applies to *every* partial DML in the flow (state updates,
> conflict re-writes, and log inserts), not just logging.

**Tier:** Sanitized, value-safe logging is **essential**. The full value-level discipline (presence
booleans, structural validation of every logged value) is **Tier 2–3** and scales with data sensitivity.
Best-effort-plus-inspection is **essential** wherever you use partial DML at all.

---

## 13. Operational recovery

- [ ] How does support **find** failed and stuck transmissions, and which fields **explain** the failure?
- [ ] Who corrects the **source data**, and how is a **manual retry** initiated and **audited**?
- [ ] Does a retry **reuse** the existing transmission (preserving the correlation id) rather than create a new one?
- [ ] How are **stuck `Processing`** records (a job that died mid-flight) recovered — and is that recovery **bounded** and **budget-aware** so a repeatedly-dying job eventually terminates?
- [ ] The recovery job **re-locks and re-evaluates** state before acting; its finding query is only a snapshot.
- [ ] Recovery that performs no new send attempt must **not** synthesize an attempt log.
- [ ] Who is **alerted** when failures accumulate?

**Why it matters.** Every integration fails in production; the difference between a good and bad one is
whether an operator can see it, understand it, and recover it without a developer.

**Common failure modes.** A row stranded in `Processing` forever because nothing reclaims it; a stale-row
recovery that never checks the budget, so a job that dies every time is retried forever; a recovery job
that fabricates a "success" log for a send it never made.

**Tier:** A way to *find and understand* failures is **essential**. Automated stale-work recovery, budget
bounding, and re-lock discipline are **Tier 2–3**.

---

## 14. Testing, including live end-to-end testing

- [ ] Unit-test with `HttpCalloutMock`: success, valid response, invalid local request, malformed JSON, correlation mismatch, 400/401/403/429/500/503, callout exception, duplicate request, retry scheduling, budget exhaustion, bulk processing.
- [ ] Test that **logging failure does not break processing** and that **no sensitive data is persisted**.
- [ ] Test the **concurrency invariants** you built — **covering stale-token refusal and route authorization** (and partial-DML isolation) — recognizing that ordinary Apex unit tests prove the state-transition protections but do **not** reproduce true simultaneous production execution. Add a **regression test for every production defect**.
- [ ] **End-to-end against a real sandbox**, with a **production-like user and permission set**:
  - The two orgs actually exchange the request and response.
  - Returned ids are stored correctly; a duplicate submission creates no duplicates.
  - Transient errors retry; permanent errors become visible to support.
  - Authentication works with the real credential (not a mock).
  - Volume/permission testing reflects expected traffic and the real deployment model.

**Why it matters.** Mocks prove your *logic*; they do **not** prove the two systems can talk. A green
mocked suite and a broken Named Credential look identical until the first real call.

**Common failure modes.** Shipping on 100% mocked coverage and discovering in production that the auth
config, endpoint, or field contract was never exercised against the live peer; testing as an admin and
missing that the runtime user lacks FLS on a field the integration writes.

> **Hard-won: `HttpCalloutMock` is necessary but not sufficient.** It cannot fail on a wrong endpoint, a
> misconfigured credential, a real 401, or a contract the peer actually rejects. Treat "passes mocked
> tests" and "the integration works" as two different claims.

**Tier:** Mocked unit tests are **essential**. A real sandbox-to-sandbox end-to-end run is **essential
before production** — it is the single most common thing teams defer and regret.

---

## 15. Documentation, deployment, and production monitoring

- [ ] Docs: architecture diagram, request/response examples, field mapping, auth setup, **error-code catalog**, retry behavior, source-of-truth rules, a **support runbook**, deployment steps, known limitations.
- [ ] Deploy metadata; configure the **production** Named Credential; assign permission sets; run a **smoke test**.
- [ ] Confirm **monitoring** is live; watch early failures; review API usage and **rate limits**.
- [ ] Confirm **support** knows the recovery process before you need it.

**Why it matters.** The runbook and the error-code catalog are what let someone who is not you operate
the integration at 2 a.m.

**Common failure modes.** A perfect codebase with no runbook, so every incident escalates to the author;
production credential never configured because it was assumed to be "the same as sandbox."

**Tier:** A runbook + error catalog + smoke test is **essential**. Dashboards and proactive alerting are
**Tier 2–3**.

---

## 16. Platform-behavior verification

- [ ] **Verify Salesforce behavior empirically** — a focused test or Anonymous Apex — instead of relying on memory or documentation you half-remember.
- [ ] Confirm the **governor and async limits** that constrain your topology (§2) against the actual org and API version.
- [ ] Confirm **error shapes** you branch on (which `StatusCode`, whether `getFields()` is populated, exact message text) before you match on them.
- [ ] Confirm **comparison and formatting** semantics you depend on (string case-sensitivity, date formatting, null handling).

**Why it matters.** A surprising amount of integration logic branches on platform behavior that is easy to
misremember; a wrong assumption here produces code that compiles, passes a shallow test, and is subtly
wrong.

> **Hard-won (lesson 7): probe, don't assume.** Real examples from this project where memory was wrong and
> a 60-second Anonymous Apex probe was right:
> - `Database.Error.getFields()` is **empty** for a unique-index `DUPLICATE_VALUE`; the field name is only
>   in the message — and the message text is **context-dependent** (differs between anonymous and test
>   context). We switched to a structural signal (only one transition writes the unique field) instead of
>   parsing it.
> - Apex `==` on `String` is **case-insensitive**; an authorization token comparison must use `.equals()`.
> - `String.valueOf(Date)` **is** `yyyy-MM-dd` (only `Date.format()` is locale-dependent) — the project
>   initially assumed otherwise until the behavior was verified.
> - An oversized string **fails** DML (`STRING_TOO_LONG`); it does **not** silently truncate.
> - `System.AsyncInfo` methods **throw outside a Queueable context**, which changes how you test them.
>
> The rule: when logic branches on a platform behavior, prove the behavior in the target org first, and
> pin the load-bearing ones with a test so a future edit cannot silently break the assumption.

**Tier:** **Essential discipline** on any integration that branches on platform-specific behavior — which
is nearly all of them. It costs minutes and prevents a class of subtle, review-surviving bugs.

### Platform limits referenced in this document

> **Last verified** July 2026 against a Developer Edition org on Apex **API v62.0**. These are
> Salesforce-documented limits, but values and behavior can change by **release, edition, and API
> version** — **recheck them for your target org** (§16), do not treat this note as current.
>
> - **120 s cumulative callout timeout per transaction** — *Apex Developer Guide → “Execution Governors
>   and Limits”* (Per-Transaction Apex Limits: “Maximum cumulative timeout for all callouts … in a
>   transaction”).
> - **One child `System.enqueueJob` from an executing Queueable** — *Apex Developer Guide → “Queueable
>   Apex”* (chaining jobs) and *“Asynchronous Apex” → async limits*.
> - **Chained-Queueable stack depth (default 5 in Developer/Trial orgs) and overriding it** — *Apex
>   Reference Guide → System namespace → “AsyncOptions Class”* (`MaximumQueueableStackDepth`) and *“Queueable
>   Apex”*. (`System.AsyncInfo` depth accessors and acceptance of an explicit maximum were verified in-org
>   on v62.0.)
> - **Scheduled Apex minimum frequency (a scheduled job runs at most hourly)** — *Apex Developer Guide →
>   “Apex Scheduler.”*

---

## Implementation tiers

Not every integration needs every protection. Match the tier to the **risk, volume, and complexity** —
adding Tier 3 machinery to a low-volume, low-risk contract is over-engineering, and shipping only Tier 1
protections for a high-volume PHI integration is insufficient.

### Rules that override tier placement

Three protections are not governed by the tier ladder — they are triggered by a condition, at any tier:

- **If `allOrNone = false` partial DML is used at all, inspecting every `SaveResult` is mandatory.** The
  partial-DML *technique* is optional; using it *without inspection* is never acceptable, because it silently
  discards failures.
- **Multi-target route authorization is optional for a single-target integration but becomes essential the
  moment an object or processing framework is shared by more than one target.**
- **Value-level logging validation is essential whenever PII, PHI, financial, or other sensitive data is
  involved — regardless of volume or organization size.** It is a data-sensitivity rule, not a scale rule.

### Tier 1 — minimum viable production integration

The floor. Do not ship without these.

- Named Credential; **no hardcoded secrets**; TLS enforced.
- Explicit **request/response DTOs** and a **mapper** (no whole-SObject serialization).
- **Pre-callout request validation** (invalid request → no callout).
- **Response validation** beyond the HTTP status: validate all contract-required success indicators, identifiers, and request/response linkage fields, **where applicable**.
- **Idempotency**: a stable key in the request + receiver-enforced idempotency.
- **Failure classification** (transient vs permanent) with controlled error codes.
- **Value-safe logging** (no raw bodies, no tokens, no unrestricted messages).
- **No DML before callout**; HTTP logic separate from DB logic.
- **`HttpCalloutMock` unit tests** for success, invalid request, error statuses, and a duplicate.
- **At least one real sandbox-to-sandbox end-to-end test** — proving the two systems actually communicate.
- **Authentication verified using the actual runtime user** (not an admin, not a mock).
- **A production deployment smoke test.**
- **A minimal support runbook and error-code reference.**

### Tier 2 — reliable production integration

Add when the integration must survive real-world failure without manual babysitting.

- A **transmission/state record** as the source of truth for outstanding work; **attempt logs** for history.
- **Retries** with a backoff schedule sized to the scheduler, a retry budget, and a terminal Failed state.
- **Partial DML with full `SaveResult` inspection** everywhere (state and logs), best-effort logging that never rolls back state.
- **Operational recovery**: support can find, understand, and manually (audited) retry failures; a **scheduled sweep** reclaims stuck work, bounded and budget-aware.
- **Idempotency via a DB unique constraint** (not pre-query dedup), proven by requery.
- **Contract drift guards** when you own both ends.
- **Repeatable, automated end-to-end testing** and broader **failure-path** testing beyond the Tier 1 smoke test.
- **Dashboards and ongoing monitoring.**

### Tier 3 — high-risk or enterprise integration

Add for high volume, strong concurrency, or sensitive data (PII/PHI/financial).

- **Claim tokens** per attempt with an **authoritative post-callout re-lock and re-verify**.
- **Singular row locking** in a loop (not batch `FOR UPDATE`); **serial Queueable chains** with an explicit **stack-depth policy** and a shared root-enqueue.
- **Stale-work recovery** with re-lock, staleness re-evaluation, and budget bounding; a defensive **ceiling repair** for rows no normal path terminates.
- **Multi-target route authorization** (query filter + freshly-locked route check) when one object/framework serves several integrations.
- **Value-level sensitive-data proofs**: presence booleans, structural validation of every logged value, tests asserting sensitive strings are refused.
- **Volume/chaos testing**, proactive **alerting** on failure accumulation, and rate-limit monitoring.

---

## Care Connect current status

Where this project stands against the checklist. The core Care Connect → Attorney dispatch-and-send path
implements several **Tier 3** code-level protections. Remaining work includes **orchestration and
recovery logic, live authentication configuration, end-to-end verification, operational documentation,
and production monitoring**.

### Completed

- Business discovery, system ownership, and the **API contract** (with drift guards).
- **DTOs, mapper, pre-callout request validator, response validator** (2xx-is-not-success, correlation match, id formats, body-size bound).
- **HTTP layer** with controlled error classification; no-DML-before-callout; all-callouts-before-DML batching.
- **Idempotency** via a unique `Transmission_Key__c` + the receiver's referral-id idempotency; **at-least-once** delivery documented with its enforcement located.
- **Transmission state model** as the source of truth; **attempt logs** as history, value-safe.
- **Send chain** (dispatcher → sender) applying transitions #4–#7b, with **claim tokens**, **authoritative post-callout re-lock**, **singular locking**, **serial chain + depth policy**, **partial-DML-plus-inspection**, and **best-effort logging**.
- **Multi-target route authorization** (query scope + freshly-locked route check) and the **exhausted-retry ceiling repair** (#11).
- **Backoff** sized to the hourly sweep (60/120/240).
- Extensive **`HttpCalloutMock` unit tests**, including concurrency, route, and partial-DML isolation, plus regression tests for discovered defects.

### Partially completed

- **Operational recovery** — the transmission fields and repair transitions exist and are unit-tested; the **scheduled hourly sweep** and the **trigger** that starts the chain are **planned for future PRs**, not yet built.
- **Documentation** — the normative state spec and this checklist exist; a support **runbook** and an error-code **catalog** page are not yet written.
- **Permissions/layout** — the eligibility field and permission sets exist; the full production deployment model has not been exercised.

### Not yet completed — and the two that matter most

- ⚠️ **Live authentication configuration.** The Connected App (Attorney org) and the External/Named Credential (Care Connect org) are **not wired up**. All callouts run against `HttpCalloutMock`.
- ⚠️ **A real Care Connect → Attorney sandbox end-to-end test.** Nothing has proven the two orgs actually communicate — that the endpoint, the live credential, and the field contract work against a real peer. **`HttpCalloutMock` cannot prove this**; a green test suite and a broken integration are indistinguishable until the first real call.
- Transition **#9 manual retry** — specified, deliberately **deferred** to a later hardening phase (a controlled admin action, not a checkbox toggle).
- Production **deployment, monitoring, and alerting**.

These two ⚠️ items are the largest remaining risk. Everything else is logic we can verify with tests;
these are the parts tests structurally *cannot* verify, and they are exactly where integrations that "pass
all tests" still fail in production.
