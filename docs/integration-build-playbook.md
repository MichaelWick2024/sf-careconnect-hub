# Salesforce Integration Build Playbook

> **Companion to [`docs/integration-checklist.md`](integration-checklist.md).**
> The **checklist** describes *what must be considered* — the controls, failure modes, and tiers. This
> **playbook** describes *the order in which the work should be performed* — the phases, the decision
> gates between them, and what "done" means at each step.
>
> **This is iterative, not a rigid waterfall.** You will loop back: a limit discovered in Phase 5 can
> reopen the pattern chosen in Phase 4; a contract ambiguity found while building DTOs in Phase 10 sends
> you back to Phase 6. The phases are an ordering of *first attempts*, not a one-way street.
>
> **Four activities run throughout the whole build, not in a single phase:** **testing** (you write
> tests as you build each layer, not only in Phase 19), **security** (least privilege and sensitive-data
> safety inform the data model, the DTOs, and the logging), **documentation** (capture decisions when you
> make them, not at the end), and **platform verification** (probe a limit or behavior the moment you
> depend on it — Checklist §16 — Platform-behavior verification — not once at the start).
>
> **How to use the gates.** Seven gates punctuate the phases. A gate is a checkpoint where specific
> decisions and deliverables must be resolved and approved. **Do not proceed past a gate while any of its
> required decisions or deliverables is unresolved** — an unresolved contract or an unverified limit does
> not get cheaper to fix later; it gets more expensive because more code has been built on the guess.
>
> Each phase lists its **objective, questions to answer, exact actions, deliverables, Definition of Done,
> common mistakes, the tiers that require it,** and a **Care Connect example** where useful. It
> cross-references the checklist section (`§N — Title`) rather than repeating its checkboxes.
>
> **Care Connect examples are architectural, not status.** They illustrate a pattern, not what is
> currently built. For the live Care Connect implementation status (completed / in an open PR / planned /
> not done), see the *Care Connect current status* section of
> [`docs/integration-checklist.md`](integration-checklist.md) or the active project tracker.

---

## Phase 1 — Define the business outcome

**Objective.** State, in one or two sentences, the real-world result the integration must produce.

**Questions to answer.** What event starts it? What must be true in the other system afterward? Is it
real-time, near-real-time, or scheduled? What does a user see on success and on failure?

**Exact actions.** Write the outcome as a single sentence. Sketch the end-to-end flow as
`event → system A → system B → stored result`. Name the success signal and the failure signal a human
will observe.

**Deliverables.** A one-paragraph outcome statement and a flow sketch.

**Definition of Done.** A non-engineer stakeholder agrees the sentence describes the intended result.

**Common mistakes.** Describing the *mechanism* ("call the REST API") instead of the *outcome* ("the
attorney has a case for this referral"); no defined human-visible failure signal.

**Tiers.** All tiers. (Checklist §1 — Business discovery and system ownership.)

**Care Connect.** *"A referral marked ready is sent to the Attorney org, which creates or updates a case;
Care Connect stores the returned Attorney case id and reflects delivery state."*

---

## Phase 2 — Identify systems and data ownership

**Objective.** Establish who owns each field and which way data flows.

**Questions to answer.** Which system is the source of truth for each field? Can both update the same
data? How are conflicts resolved? One-way or bidirectional? Who may initiate a resend or correction?

**Exact actions.** Build a field-ownership table (field → owning system → who may write). Mark the flow
direction. Decide the conflict rule for any field both sides can touch.

**Deliverables.** A field-ownership table and a stated conflict-resolution rule.

**Definition of Done.** Every shared field has exactly one owner or an explicit conflict rule.

**Common mistakes.** Two systems both "owning" a field with no rule; treating a downstream value as
authoritative and overwriting the real source.

**Tiers.** All tiers. (Checklist §1 — Business discovery and system ownership.)

**Care Connect.** Care Connect owns referral details; the Attorney org owns Attorney case status. The
flow is one-way (Care Connect → Attorney) with an id returned.

---

## Phase 3 — Gather volume, timing, security, and support requirements

**Objective.** Capture the non-functional requirements that will decide the tier and pattern.

**Questions to answer.** Expected and peak volume? Bulk or single-record? Latency tolerance (immediate
response vs delayed delivery acceptable)? What data is PII/PHI/financial/confidential? Who operates and
supports it, and what is the required recovery experience?

**Exact actions.** Record expected/peak throughput, a latency budget, a data-sensitivity classification,
and the support/ownership model.

**Deliverables.** A short non-functional-requirements note.

**Definition of Done.** Volume, latency, data-sensitivity, and support expectations are written and
agreed.

**Common mistakes.** Skipping data classification (it drives logging rules regardless of volume);
designing for demo volume instead of peak.

**Tiers.** All tiers — and this phase is what *determines* the tier. (Checklist §1 — Business discovery
and system ownership; §3 — API contract; §4 — Authentication and security.)

### 🚦 Gate 1 — Business and ownership approved

Proceed only when the outcome, the field-ownership/flow model, and the volume/timing/security/support
requirements are written and approved. **Do not design a pattern or contract on an unowned field or an
unknown data-sensitivity level.**

---

## Phase 4 — Select the integration pattern and implementation tier

**Objective.** Choose the mechanism and the target reliability tier.

**Questions to answer.** REST callout, inbound Apex REST, Platform Events, CDC, scheduled sync,
Salesforce Connect, or middleware? Synchronous or asynchronous? Single or bulk? Does the caller need an
immediate response? Given Phase 3, is this a Tier 1, 2, or 3 build?

**Exact actions.** Pick the pattern. Pick the tier (checklist → *Implementation tiers*). Note which
tier-triggered rules apply now (partial-DML inspection, multi-target route auth, sensitive-data value
logging).

**Deliverables.** A one-line pattern + tier decision with a one-sentence rationale.

**Definition of Done.** The pattern and tier are chosen and justified against Phase 3's requirements.

**Common mistakes.** A synchronous callout for work that should be a durable queued job; jumping to Tier
3 machinery for a low-volume, low-risk contract, or shipping Tier 1 for high-volume sensitive data.

**Tiers.** All tiers make this decision. (Checklist §2 — Integration-pattern selection, and
*Implementation tiers*.)

**Care Connect.** Outbound REST, **asynchronous**, **bulk-capable**, **Tier 3** (concurrency + at-least-once
delivery) — chosen deliberately as a training exercise; a low-volume version would sit at Tier 1–2.

---

## Phase 5 — Verify Salesforce limits and platform assumptions

**Objective.** Confirm the governor/async limits and platform behaviors your pattern depends on —
**before** the topology is baked in.

**Questions to answer.** What limits constrain this pattern (callout timeout budget, enqueue rules,
chained-depth cap, scheduler frequency)? Which platform behaviors will your code branch on (error
shapes, comparison/formatting semantics)?

**Exact actions.** Confirm the limits against the target org, edition, and API version — Anonymous Apex
or a focused test (Checklist §16 — Platform-behavior verification). Record each with its source and
verified value. Re-open Phase 4 if a limit rules the pattern out.

**Deliverables.** A short "verified limits/behaviors" note with sources and values.

**Definition of Done.** Every limit the topology relies on has been confirmed in the target org, not
assumed from memory.

**Common mistakes.** Designing the topology, then discovering the cumulative-callout budget or the
one-child-enqueue rule breaks it; matching on an error shape that differs in the target org.

**Tiers.** Essential for any async/bulk build; light for a single synchronous call. (Checklist §16 —
Platform-behavior verification; §2 — Integration-pattern selection.)

**Care Connect.** The 120 s cumulative callout budget set the batch size (3 × 30 s), "one child enqueue"
forced a serial chain, the chained-depth cap forced an explicit `MaximumQueueableStackDepth`, and the
hourly scheduler set the 60/120/240 backoff — each verified in-org.

---

## Phase 6 — Define and approve the API contract

**Objective.** Agree the exact request/response contract with the other side.

**Questions to answer.** Endpoint, method, headers, versioning? Required/optional fields, types, max
lengths, allowed values, formats? The success shape and every error shape? For a state-changing
operation that may be retried, what is the stable idempotency key?

**Exact actions.** Write the contract with concrete request/response examples and an error catalog.
Decide the idempotency key here **where the operation requires one** (state-changing, retryable). If you
own both ends, plan a drift-guard test for the shared wire keys.

**Deliverables.** A written contract, request/response examples, and an error-response catalog.

**Definition of Done.** Both sides agree; success and error shapes are fixed, and the idempotency key is
fixed **where applicable**.

**Common mistakes.** "We'll define errors later" (the caller then can't classify failures); undocumented
max lengths; a locale-ambiguous date format.

**Tiers.** All tiers; drift-guard tests are advanced (own-both-ends). (Checklist §3 — API contract; §9 —
Idempotency and delivery guarantees.)

**Care Connect.** `correlationId`, `careConnectReferralId` (18-char id, the idempotency key), `referralType`,
`client{…}`; a shape test pins the JSON key set because the Apex field names *are* the wire keys.

### 🚦 Gate 2 — Pattern and contract approved

Proceed to security and data-model design only when the pattern, tier, verified limits, and the
**approved contract** (including the error catalog, and the idempotency key **where applicable**) are
settled. **Do not build DTOs against an unapproved contract.**

---

## Phase 7 — Design authentication and integration-user permissions

**Objective.** Decide how the two systems authenticate and what the runtime identity may do.

**Questions to answer.** Which auth method (OAuth client-credentials, JWT, …)? Where does each half of
the config live (Connected App vs Named/External Credential)? Which runtime user/permission set, at
least privilege? How are credentials rotated, and how do sandbox and production differ?

**Exact actions.**
- **Outbound (Salesforce calls out):** design the External / Named Credential in Salesforce and the
  target system's authentication configuration (the app/account it authenticates to).
- **Inbound (Salesforce is called):** design the Connected App / OAuth configuration, the Salesforce
  integration user, the scopes, the profiles / permission sets, and the external caller's credential
  handling.
- Either way: least privilege, FLS only on the fields the integration touches; document the config split
  across the two systems. *(Wiring the live credential is Phase 20; this phase is the design.)*

**Deliverables.** An auth design and a permission-set definition.

**Definition of Done.** The method, credential topology, runtime identity, and rotation story are
documented and agreed.

**Common mistakes.** Hardcoding secrets; one credential shared across sandbox/prod; designing as an admin
and missing that the runtime/integration user lacks FLS on a written field.

**Tiers.** All tiers. Secure credential management and least privilege are non-negotiable;
Named / External Credentials are the standard Salesforce mechanism **when Salesforce makes an outbound
callout**. (Checklist §4 — Authentication and security.)

**Care Connect.** OAuth client-credentials; the Connected App lives in the Attorney org and the
External / Named Credential in Care Connect — the config is deliberately split across the two orgs.

---

## Phase 8 — Design the Salesforce data and state model

**Objective.** Model the records that carry the integration's identity and current state.

**Questions to answer.** Which business records participate, and where is the external id stored? Is a
separate delivery-state record needed? Separate attempt logs? What unique constraint prevents duplicate
logical work at the database? For a required lookup, `Restrict` or `Cascade`? If one object serves
multiple targets, what carries the target/operation discriminator?

**Exact actions.** Design the state object (identity fields required at the DB, a unique key, restricted
delete). Design the log object as history. Add the target/operation discriminator if shared.

**Deliverables.** Object/field definitions with required, unique, and delete-semantics decisions.

**Definition of Done.** The state record answers "what still needs sending?" with a query; the unique
constraint exists; delete semantics are chosen deliberately.

**Common mistakes.** Deriving outstanding work from log history; a unique field that allows NULLs;
Master-Detail that cascade-deletes history and locks the parent on every update.

**Tiers.** State record + unique constraint essential with retries; separate logs Tier 2; multi-target
discriminator essential once shared. (Checklist §5 — Data model and state management.)

**Care Connect.** `Integration_Transmission__c` (current state, unique `Transmission_Key__c`, `Restrict`
delete, `Target_System__c`/`Operation__c` discriminator); `Integration_Log__c` (history).

---

## Phase 9 — Define idempotency and delivery guarantees

**Objective.** For a state-changing operation that may be retried, decide what happens when the same
request is sent twice, and name the guarantee. *(A read-only `GET` is naturally idempotent — this phase
is lightweight for it.)*

**Questions to answer.** Is this a state-changing operation (needs a key) or a naturally-idempotent read?
What is the stable idempotency key, and is it specific enough (source + target + operation + generation)?
How does the receiver enforce idempotency? Which delivery guarantee do you provide (at-least-once vs
exactly-once), and where is each part enforced?

**Exact actions.** For a state-changing operation: fix the idempotency key (from the contract); specify
the receiver's enforcement (unique key / upsert / idempotency table); write down the guarantee and its
enforcement location.

**Deliverables.** A written idempotency + delivery-guarantee statement (for state-changing operations).

**Definition of Done.** For a state-changing operation, "same request twice is harmless" is true and
documented, with the guarantee named. For a read-only operation, the natural idempotency is noted.

**Common mistakes.** Check-then-insert races; assuming local claim logic prevents duplicate *delivery* (it
cannot); a key that a legitimately-repeated transmission would collide on.

**Tiers.** Essential for state-changing operations with retries; DB-unique-constraint-as-authority is
Tier 2. (Checklist §9 — Idempotency and delivery guarantees.)

**Care Connect.** **At-least-once**, not exactly-once. Claim tokens protect *local state*; the Attorney
org's idempotency (keyed on the referral id) prevents duplicate *business records*. Duplicate delivery is
expected and safe.

### 🚦 Gate 3 — Security and data model approved

Proceed to build only when the auth design, permission model, data/state model, and idempotency/delivery
guarantee are approved. **Do not start coding the callout on an unsettled state model or — for a
state-changing operation — an undefined idempotency key.**

---

## Phase 10 — Build DTOs and mapping

**Objective.** Build the request/response DTOs and the SObject→DTO mapper.

**Questions to answer.** Which fields does the receiver actually need? For each optional field, omit or
explicit-null (per contract)? Any values needing explicit (non-locale) formatting?

**Exact actions.** Define request/response DTOs. Build a mapper separate from callout and validation
logic. Send only needed fields; format ambiguous values explicitly.

**Deliverables.** DTO classes and a mapper, with a shape test if you own both ends.

**Definition of Done.** The mapper produces a contract-shaped request from a business record; no whole
SObject is serialized.

**Common mistakes.** Serializing an entire record; mixing mapping into the callout; locale-dependent date
formatting.

**Tiers.** All tiers (Tier 1). (Checklist §6 — DTOs, mapping, and validation.)

**Care Connect.** `AttorneyReferralRequest`/`AttorneyReferralResponse` DTOs; `AttorneyReferralRequestMapper`;
`dateOfBirth` formatted explicitly as `yyyy-MM-dd`.

---

## Phase 11 — Build request validation

**Objective.** Reject a request you built wrong *before* spending a callout.

**Questions to answer.** Which required values, id formats, string limits, picklist values, date formats,
and related-record checks must hold? What controlled error does an invalid request produce?

**Exact actions.** Build a pre-callout validator. An invalid request → no callout + a controlled error.

**Deliverables.** A request validator with tests for each failure.

**Definition of Done.** An invalid request never reaches the wire and surfaces a controlled code.

**Common mistakes.** UI-only validation a system path bypasses; validating after the callout.

**Tiers.** All tiers (Tier 1). (Checklist §6 — DTOs, mapping, and validation.)

**Care Connect.** `AttorneyReferralRequestValidator` → `INVALID_REQUEST` with only the failed check name;
a contactless referral is rejected with no HTTP call.

---

## Phase 12 — Build the HTTP client or inbound REST endpoint

**Objective.** Implement the transport, correctly ordered against DML.

**Questions to answer.** Correct endpoint/method/headers/serialization? A deliberate timeout (sized to
the topology, not "the max")? When the transaction performs outbound callouts, is all DML kept *after*
them?

**Exact actions.**
- **Outbound:** the HTTP client serializes and sends the request, then returns a **controlled outcome**
  without writing business state itself. Keep every callout before any DML; for batches, all callouts
  first. (The callout-before-DML ordering applies whenever the transaction performs outbound callouts.)
- **Inbound:** a thin `@RestResource` parses the request, invokes validation and an application service,
  and maps the controlled result into an HTTP response. It may **delegate state changes** to the
  application service — it is not required to "write no state," only to keep transport thin and separate
  from business logic.

**Deliverables.** An HTTP client / endpoint returning (or producing) a controlled outcome, with a mocked
success test.

**Definition of Done.** A mocked happy-path call succeeds; transport (HTTP) logic is separate from
business/DB logic; when the transaction calls out, no callout follows DML.

**Common mistakes.** A callout after an incidental DML (even a log insert); the default 120 s timeout
eating the batch budget.

**Tiers.** All tiers (Tier 1). (Checklist §7 — HTTP implementation.)

**Care Connect.** `AttorneyApiService.sendReferral` via `callout:Attorney_API`, 30 s timeout, returns a
`CalloutOutcome`; all callouts precede DML in the batching sender.

---

## Phase 13 — Build response validation and happy-path orchestration

**Objective.** Validate the remote response, coordinate the complete attempt, and persist successful
state only after validation.

**Questions to answer.** Does the contract include a body (or is a bodyless 204 valid)? Which required
fields, linkage (correlation) matches, id formats, and status values must hold? How is the body bounded
before parsing? Which service owns loading records, running the pieces in order, and applying the
successful state transition?

**Exact actions.**
- **Outbound orchestration** — build the application service (or sender) that:
  - loads the required Salesforce records → maps them into the DTO → runs request validation →
    invokes the HTTP client → runs response validation (validate the body per contract, bound size
    before parsing, reject contradictory responses) → persists external identifiers and successful state
    **only after** validation → returns or records a controlled outcome.
- **Inbound orchestration** — build the application service the endpoint invokes:
  - request DTO → request validation → idempotency enforcement → application service → persisted result
    → controlled response DTO / status. *(An inbound-only integration may have **no remote response body
    to validate** — its "response validation" is producing a correct, contract-shaped reply.)*
- Keep transport logic separate from database / state-transition logic.
- Ensure all callouts occur before any post-callout DML (when the transaction calls out).

**Deliverables.** For outbound: a response validator + a happy-path orchestration layer. For inbound: the
request-validated, idempotent application service behind the endpoint. Either way, a mocked end-to-end
happy-path test.

**Definition of Done.** A mocked happy path completes end to end — outbound: from Salesforce record
through persisted successful state with no unvalidated remote value stored; inbound: from received
request through idempotent persistence and a controlled response.

**Common mistakes.** Persisting an id from a 200 that was a partial failure; unbounded deserialize; a
nonblank-but-meaningless status treated as valid; orchestration that writes state before validating, or
mixes transport with the state transition; an inbound endpoint that skips idempotency enforcement.

**Tiers.** Essential to validate all contract-required success indicators, identifiers, linkage fields,
and response semantics, and to have an orchestration layer (Tier 1); response hardening (size bounds,
contradiction rejection) advanced. (Checklist §8 — Response validation.)

**Care Connect.** `AttorneyReferralResponseValidator` (success flag, correlation match, v4 id, null-or-18
record id, nonblank status) with an 8 KB body bound before parse; the sender orchestrates
reload → map → validate → call → validate → persist as one controlled attempt.

### 🚦 Gate 4 — Happy path works with mocks

Proceed only when a mocked end-to-end happy path passes — **outbound:** the orchestration layer taking a
Salesforce record through map → validate request → call → validate response → **persist successful
state**; **or inbound:** the endpoint taking a request through validate → enforce idempotency →
application service → **persist** → controlled response. **Do not layer failure handling and concurrency
onto a happy path that does not yet work.**

---

## Phase 14 — Add failure classification

**Objective.** Turn raw errors into controlled transient/permanent codes.

**Questions to answer.** Which conditions are transient vs permanent *for each endpoint*? What controlled
vocabulary do you record? How does an unclassified condition degrade?

**Exact actions.** Map HTTP statuses and exceptions to a controlled internal vocabulary, documented per
endpoint. Default the unknown to `UNKNOWN`.

**Deliverables.** A documented error-code mapping and classification logic with tests.

**Definition of Done.** Every handled failure yields a controlled code; classification is documented
per endpoint, not inferred from status alone.

**Common mistakes.** Treating status codes as universally meaning the same thing; logging a raw remote
message; letting an unclassified condition fail the write that records the failure.

**Tiers.** Transient/permanent split essential (Tier 1). (Checklist §10 — Failure classification and
retries.)

**Care Connect.** `RATE_LIMITED`/`SERVER_ERROR`/`TIMEOUT` transient; `VALIDATION_REJECTED` (400)/`UNAUTHORIZED`/
`NOT_FOUND`/`CONFLICT` permanent; unknown → `UNKNOWN`.

---

## Phase 15 — Add asynchronous execution and durable retries where required

**Objective.** When the chosen pattern requires it, move execution to an appropriate asynchronous
mechanism and add durable retry behavior for transient failures. **For a synchronous integration with no
automated retries, this phase is not applicable (or lightweight)** — note that and move on.

**Questions to answer.** Does the pattern require async at all (initiating context, latency, limits)? If
so: what is the async topology (respecting the Phase 5 limits)? Max retries, backoff schedule (sized to
the scheduler), next-retry time? What happens when the budget is exhausted?

**Exact actions.** Build the async execution (Queueable/Batch/scheduled) per the verified topology. Add
backoff + budget + a terminal Failed state. Retry only transient failures; preserve the correlation id.

**Deliverables.** Async execution + retry/backoff logic with tests (scheduling, budget exhaustion).

**Definition of Done.** Transient failures retry on schedule and terminate at the budget; permanent
failures do not retry.

**Common mistakes.** Retrying a 400 forever; a backoff finer than the scheduler can honor; losing the
correlation id across retries.

**Tiers.** Asynchronous execution is **pattern-dependent and may be required at any tier** (initiating
context, latency, user experience, or Salesforce transaction limits). Durable retry scheduling, backoff,
retry budgets, and recovery are **generally Tier 2**. (Checklist §10 — Failure classification and
retries; §11 — Concurrency and async processing.)

**Care Connect.** Serial dispatcher → sender Queueable chain; 60/120/240 backoff sized to the hourly
sweep; budget = `MAX_RETRIES`, exhaustion → `RETRY_BUDGET_EXHAUSTED`.

---

## Phase 16 — Add concurrency protections when justified

**Objective.** Prevent two jobs, or a stale job, from corrupting state — **when volume/risk justify it.**

**Questions to answer.** Can two jobs process the same record? Is a `Processing` state + `FOR UPDATE`
enough, or do you need per-attempt claim tokens? Is the authority check *after* the callout? Singular vs
batch locking? A chained-depth policy?

**Exact actions.** If justified: add row locking + a `Processing` state; per-attempt claim tokens with an
**authoritative post-callout re-lock and re-verify**; singular locking in a loop; a depth policy checked
before enqueuing; multi-target route authorization if the object is shared.

**Deliverables.** Concurrency-safe claim/apply logic with tests for the invariants (stale-token refusal,
route refusal).

**Definition of Done.** A stale job cannot overwrite a newer attempt; one contested row does not fail the
batch; a foreign-target row cannot be processed.

**Common mistakes.** Only checking authorization *before* the callout; batch `FOR UPDATE` that fails the
whole group; a shared object with no route authorization.

**Tiers.** **Advanced (Tier 3).** For lower volume, a `Processing` check + receiver idempotency is often
enough. (Checklist §11 — Concurrency and async processing.)

**Care Connect.** Claim tokens (case-sensitive), post-callout `FOR UPDATE` re-lock + re-verify, singular
locking, `MaximumQueueableStackDepth`, and `claim(id, target, operation)` route authorization.

---

## Phase 17 — Add sanitized logging and monitoring

**Objective.** Record each attempt safely — never leaking sensitive data, never breaking the business
transaction.

**Questions to answer.** What does each attempt log need to answer? What must never be persisted (raw
bodies, tokens, unrestricted messages)? Which fields are PII/PHI? Is logging best-effort *and* inspected?

**Exact actions.** Log the controlled attempt fields. Validate logged **values** (not just allowlisted
keys) — presence booleans for PII, structural validation for ids. Make log writes best-effort partial DML
**and inspect every `SaveResult`**.

**Deliverables.** A log writer with value-safe payloads and inspected partial DML, plus tests (no
sensitive data persisted; a bad log row neither throws nor rolls back state).

**Definition of Done.** No prohibited, raw, or unvalidated sensitive value is logged — any retained
identifiers or operational values are explicitly approved, bounded, and structurally validated; a
rejected log row cannot roll back state; log failures are surfaced as controlled codes.

**Common mistakes.** Logging a field because you allowlisted its key; ignoring the `SaveResult[]` on a
best-effort insert; a log insert rolling back the state it records.

**Tiers.** Value-safe logging essential (Tier 1); value-level discipline scales with sensitivity;
partial-DML inspection mandatory whenever `allOrNone=false` is used. (Checklist §12 — Logging,
monitoring, and sensitive-data safety.)

**Care Connect.** One `Integration_Log__c` per attempt from the outcome's allowlisted payloads;
best-effort `Database.insert(logs, false)` with per-`SaveResult` inspection.

---

## Phase 18 — Add operational recovery and manual retry where applicable

**Objective.** Make failures findable and recoverable — with the depth of automation matched to the tier.

**Questions to answer.** How does support find failed/stuck rows and read *why*? What is the documented
correction/recovery procedure? Can failed work disappear silently? *(Tier 2–3)* Do stuck `Processing`
rows need automated recovery, a retry budget, an audited manual-retry action, and a shared enqueue entry
point?

**Exact actions.**
- **Essential at every tier:** ensure support can **find and understand** failures (queryable state +
  controlled error codes); write a **documented correction / recovery procedure**; ensure **failed work
  cannot disappear silently** (a terminal Failed state is visible, not swallowed).
- **Tier 2–3, when applicable:** build a **scheduled stale-work recovery** sweep (re-lock, re-evaluate
  staleness, bounded, **retry-budget enforced**); a **controlled, audited manual-retry** action reusing
  the existing record; and a **shared root enqueue** entry point. Recovery that performs **no HTTP send**
  must **not** create a send-attempt log — but it **may** create a separate operational or audit event
  when the project requires recovery actions to be audited.

**Deliverables.** *(Tier 1)* a way to find/understand failures and a written recovery procedure.
*(Tier 2–3)* a recovery sweep and manual-retry path, with tests (stale recovery commits, budget
exhaustion terminates, one failed recovery does not roll back others).

**Definition of Done.** *(Tier 1)* support can find, understand, and manually correct a failure, and no
failure is silently lost. *(Tier 2–3)* a stuck row is eventually recovered or terminated, and recovery
never fabricates a send-attempt log.

**Common mistakes.** No documented recovery path at all (Tier 1); a row stranded in `Processing` forever
(Tier 2–3); stale recovery with no budget check; a recovery job that synthesizes a "success" send log for
a send it never made.

**Tiers.** Find/understand + a documented procedure are **essential**; automated recovery, budgets,
audited manual retry, and shared enqueueing are **Tier 2–3**. (Checklist §13 — Operational recovery.)

**Care Connect.** `applyStaleRecovery` (#8) and `applyExhaustedRetryRepair` (#11) are the Tier 3 recovery
transitions; a scheduled sweep re-locks and applies them, and recovery writes no send-attempt log.

---

## Phase 19 — Complete the unit and regression test matrix

**Objective.** Close any coverage gaps and run the *complete* mocked suite across success, failure, and
concurrency paths. **Tests accompany each layer as it is built** (see the introduction) — this phase
ensures the matrix is complete and green, not that testing starts here.

**Questions to answer.** Are all the failure paths, the duplicate, bulk, retry scheduling, budget
exhaustion, logging-failure isolation, and no-sensitive-data-persisted cases covered? Is there a
regression test for every defect found?

**Exact actions.** Fill any gaps against the Checklist §14 — Testing, including live end-to-end testing
unit matrix with `HttpCalloutMock`. Confirm the
concurrency invariants you built (stale-token refusal, route authorization, partial-DML isolation) are
tested, noting that unit tests prove state-transition logic but not true simultaneous execution. Ensure a
regression test exists for every defect.

**Deliverables.** A complete, passing unit suite meeting the coverage bar, with named concurrency and
sensitive-data tests.

**Definition of Done.** The full mocked matrix passes with no coverage gaps; every discovered defect has a
guarding test.

**Common mistakes.** Treating this as the first time tests are written; testing only the happy path;
asserting a nonblank string instead of a controlled code; no regression test after a fix.

**Tiers.** Mocked unit tests essential (Tier 1). (Checklist §14 — Testing, including live end-to-end
testing.)

**Care Connect.** Tests across the transmission service, API service, mapper, dispatcher, and sender cover
concurrency, route authorization, and partial-DML isolation, plus regressions for defects found in review.

### 🚦 Gate 5 — Failure and retry behavior works

Proceed to live wiring when all failure, retry, logging, recovery, and concurrency protections **required
by the chosen pattern and tier** are proven, and the mocked test matrix passes. **Do not connect real
systems while the required failure handling is unproven — you would be debugging logic and connectivity at
once. But do not let an optional Tier 3 protection block a Tier 1 integration from reaching live
testing.**

---

## Phase 20 — Configure live authentication

**Objective.** Wire the real credential so the two orgs can actually authenticate.

**Questions to answer.** Is the Connected App (target org) created with the right OAuth flow and scopes?
Are the External/Named Credential (calling org) configured to match? Is the runtime user's permission set
assigned? Are sandbox and production configured separately?

**Exact actions.**
- **Outbound:** configure the Salesforce External / Named Credential and the target-side auth
  application / account it authenticates to.
- **Inbound:** configure Salesforce's Connected App / integration user and the external client's OAuth
  setup.
- Either way: assign the permission set; confirm TLS; keep secrets out of source and metadata.

**Deliverables.** A working live credential in the sandbox (and a documented production procedure).

**Definition of Done.** An authenticated call reaches the peer (even if the business call is not yet
exercised) — auth is no longer mocked.

**Common mistakes.** The per-org config split done backwards; secrets committed; sandbox and prod sharing
one credential.

**Tiers.** Essential — every integration before production. (Checklist §4 — Authentication and security;
§15 — Documentation, deployment, and production monitoring.)

**Care Connect.** Care Connect uses OAuth client credentials: the Attorney org owns the target-side
Connected App, while Care Connect owns the External / Named Credential used for the outbound callout.

---

## Phase 21 — Run a real sandbox-to-sandbox end-to-end test

**Objective.** Prove the two systems actually communicate — the thing mocks cannot prove.

**Questions to answer.** Do the orgs exchange the real request/response? Are ids stored correctly? Does a
duplicate submission create no duplicates? Does auth work with the **real runtime user and permission
set**? Where the peer or a test hook supports it, do transient errors retry and permanent errors surface?

**Exact actions.** From a Care-Connect-like sandbox, send to an Attorney-like sandbox with the live
credential and the runtime user. Verify creation, id storage, and duplicate safety against the real peer.
**Exercise controlled failure paths where the peer system or a dedicated test mechanism supports them** —
do not manufacture every 429, timeout, or 500 against a live sandbox that provides no safe test hook.

**Deliverables.** A recorded end-to-end run (request, response, stored result) and any defects filed.

**Definition of Done.** A real referral is delivered end to end, its id stored, and a duplicate confirmed
harmless — against the live peer, not a mock; failure paths verified as far as the peer safely allows.

**Common mistakes.** Shipping on mocked coverage alone; testing as an admin and missing a runtime-user
FLS gap; never exercising the real endpoint/credential/contract together.

**Tiers.** Essential before production — the single most-deferred, most-regretted step. (Checklist §14 —
Testing, including live end-to-end testing.)

**Care Connect.** A Care-Connect-like sandbox sends to an Attorney-like sandbox using the live credential
and the runtime user; success, id storage, and duplicate safety are the mandatory checks.

### 🚦 Gate 6 — Live sandbox integration works

Proceed only when the required live success path, runtime-user authentication, identifier persistence,
and duplicate-safety checks pass, along with controlled failure paths **where the peer safely supports
them**. **Do not deploy to production on mocks alone.**

---

## Phase 22 — Complete documentation and the support runbook

**Objective.** Make the integration operable by someone who is not the author.

**Questions to answer.** Are the architecture, request/response examples, field mapping, auth setup,
**error-code catalog**, retry behavior, source-of-truth rules, deployment steps, and known limitations
written? Is there a **support runbook** for finding and recovering failures?

**Exact actions.** Write/complete the docs and the runbook. Cross-reference the normative spec and this
playbook rather than duplicating.

**Deliverables.** Operator documentation and a support runbook.

**Definition of Done.** A support engineer could find, understand, and recover a failure at 2 a.m. from
the docs alone.

**Common mistakes.** A perfect codebase with no runbook, so every incident escalates to the author.

**Tiers.** Runbook + error catalog essential before production. (Checklist §15 — Documentation,
deployment, and production monitoring.)

**Care Connect.** Operator docs cross-reference the normative state specification and this playbook rather
than duplicating them; the error catalog derives from the controlled `Last_Error_Code__c` vocabulary.

---

### 🚦 Gate 7 — Production readiness approved

Proceed to the production deploy only when Gates 1–6 are closed **and** the operator documentation,
runbook, production auth procedure, and monitoring plan are ready and approved. **Do not deploy to
production with an unresolved gate, missing runbook, or no monitoring.**

---

## Phase 23 — Deploy, smoke-test, and monitor production

**Objective.** Ship to production and confirm it works there.

**Questions to answer.** Is the metadata deployed and the **production** Named Credential configured? Are
permission sets assigned? What **production-safe smoke transaction** (or non-destructive verification) is
approved, and what is its rollback/cleanup? What monitoring signal confirms success? Is monitoring live
and are rate limits understood? Does support know the recovery process?

**Exact actions.** Deploy; configure the production credential; assign permission sets. **Before
deployment, agree the smoke-test record, its rollback / cleanup procedure, and the expected monitoring
signal.** Run the approved smoke transaction (or non-destructive verification); confirm
monitoring/alerting; watch early traffic.

**Deliverables.** A deployed, smoke-tested integration with live monitoring and an agreed smoke-test /
cleanup procedure.

**Definition of Done.** An approved production-safe smoke transaction succeeds end to end, **or** an
approved non-destructive verification is completed when production business writes cannot safely be
generated; monitoring shows the expected signal; support is ready.

**Common mistakes.** Assuming production config equals sandbox; no smoke test; generating an unsafe or
un-cleaned-up production write; no monitoring on day one.

**Tiers.** Smoke test / non-destructive verification essential; dashboards/alerting Tier 2–3. (Checklist
§15 — Documentation, deployment, and production monitoring.)

---

## Phase 24 — Review production failures and improve the integration

**Objective.** Close the loop: learn from real failures and harden.

**Questions to answer.** What is failing in production and why? Are failures classified correctly? Is a
protection missing (a defer-until-volume item now justified)? Does each defect have a regression test?

**Exact actions.** Review failure logs and rates. File and fix defects with regression tests. Promote a
deferred protection (e.g. concurrency, dashboards) when real volume/risk now justifies it. Update the
runbook.

**Deliverables.** Defect fixes with regression tests; updated docs; a tier-up decision where warranted.

**Definition of Done.** Known production failure modes are understood, guarded, and documented.

**Common mistakes.** No feedback loop; adding machinery speculatively instead of in response to observed
need; fixing a defect without a regression test.

**Tiers.** All tiers operate this loop. (Checklist §13 — Operational recovery; §14 — Testing, including
live end-to-end testing.)

---

## Condensed workflow

**Discover → Design → Build the happy path → Add defensive protections → Test with mocks → Connect the
real systems → Test end to end → Deploy and monitor.**

- **Discover** = Phases 1–3 (Gate 1)
- **Design** = Phases 4–9 (Gates 2–3)
- **Build the happy path** = Phases 10–13 (Gate 4)
- **Add defensive protections** = Phases 14–18
- **Test with mocks** = Phase 19 (Gate 5)
- **Connect the real systems** = Phase 20
- **Test end to end** = Phase 21 (Gate 6)
- **Deploy and monitor** = Phases 22–24 (Gate 7)

---

## Small contract version

For a **low-volume, low-risk** integration, do **not** automatically add Tier 3 concurrency machinery. The
minimum reasonable sequence:

1. **Business outcome + ownership** (Phases 1–2) — always.
2. **Pattern + Tier 1/2 decision** (Phase 4) and a quick **limits check** for the callout timeout and
   whether async is needed (Phase 5).
3. **Approved contract**, plus an **idempotency key for a state-changing operation that may be retried**
   (Phases 6, 9) — idempotency is cheap insurance where it applies; a read-only `GET` is naturally
   idempotent and needs no key.
4. **Auth via Named Credential + least-privilege user** (Phase 7) — always.
5. **A simple state/log record** if retries are needed; otherwise just the business record + external id
   (Phase 8, lightweight).
6. **DTOs, mapper, request validation, HTTP client, response validation + happy-path orchestration**
   (Phases 10–13) — always.
7. **Async execution if the initiating context, latency, UX, or transaction limits require it** — this
   can be true even at Tier 1 — plus **failure classification** (Phase 14) and **simple retries** if
   delivery must survive a transient failure (Phase 15). Durable retry scheduling / budgets are the
   Tier 2 part; a `Processing` status check plus receiver idempotency usually replaces claim tokens.
8. **Sanitized, value-safe logging** (Phase 17) — always; value-level rigor scales with data sensitivity.
9. **A findable/understandable failure path and a documented recovery procedure** (Phase 18, Tier 1
   depth) — always, even without an automated sweep.
10. **Complete mocked tests** (Phase 19), **live auth** (Phase 20), **one real sandbox end-to-end test**
    (Phase 21), a **minimal runbook** (Phase 22), and a **production-safe smoke test** (Phase 23) — all
    always.

**Skip until justified:** claim tokens and post-callout re-lock, singular-locking chains and depth
policies, multi-target route authorization (until an object is shared), scheduled stale-recovery sweeps,
audited automated manual-retry, and dashboards/alerting. Add them via Phase 24 when real volume or risk
appears.

**Still non-negotiable at any size:** Named Credentials (no hardcoded secrets), pre-callout validation,
response validation, an idempotency key **for state-changing retryable operations**, controlled error
classification, value-safe logging, a documented recovery path, mocked tests, **and one real
sandbox-to-sandbox end-to-end test before production.**

---

## Project tracker template

Copy per integration. One row per phase; mark the gate rows to enforce "no proceeding past an unresolved
gate."

| Phase | Owner | Status | Deliverable / link | Blocker | Approval | Notes |
|---|---|---|---|---|---|---|
| 1. Business outcome |  |  |  |  |  |  |
| 2. Systems & ownership |  |  |  |  |  |  |
| 3. Volume/timing/security/support |  |  |  |  |  |  |
| **Gate 1 — Business & ownership approved** |  |  |  |  |  |  |
| 4. Pattern & tier |  |  |  |  |  |  |
| 5. Verify limits & platform |  |  |  |  |  |  |
| 6. API contract |  |  |  |  |  |  |
| **Gate 2 — Pattern & contract approved** |  |  |  |  |  |  |
| 7. Auth & permissions design |  |  |  |  |  |  |
| 8. Data & state model |  |  |  |  |  |  |
| 9. Idempotency & delivery guarantee |  |  |  |  |  |  |
| **Gate 3 — Security & data model approved** |  |  |  |  |  |  |
| 10. DTOs & mapping |  |  |  |  |  |  |
| 11. Request validation |  |  |  |  |  |  |
| 12. HTTP client / inbound endpoint |  |  |  |  |  |  |
| 13. Response validation & happy-path orchestration |  |  |  |  |  |  |
| **Gate 4 — Happy path works with mocks** |  |  |  |  |  |  |
| 14. Failure classification |  |  |  |  |  |  |
| 15. Async execution & durable retries (where required) |  |  |  |  |  |  |
| 16. Concurrency protections (if justified) |  |  |  |  |  |  |
| 17. Sanitized logging & monitoring |  |  |  |  |  |  |
| 18. Operational recovery & manual retry where applicable |  |  |  |  |  |  |
| 19. Complete unit & regression test matrix |  |  |  |  |  |  |
| **Gate 5 — Failure & retry behavior works** |  |  |  |  |  |  |
| 20. Configure live authentication |  |  |  |  |  |  |
| 21. Sandbox-to-sandbox end-to-end test |  |  |  |  |  |  |
| **Gate 6 — Live sandbox integration works** |  |  |  |  |  |  |
| 22. Documentation & support runbook |  |  |  |  |  |  |
| **Gate 7 — Production readiness approved** |  |  |  |  |  |  |
| 23. Deploy, smoke-test, monitor |  |  |  |  |  |  |
| 24. Review failures & improve |  |  |  |  |  |  |

**Status** values: `Not started` · `In progress` · `Blocked` · `Done`. **Approval** records who signed off
a gate. A gate row must be `Done` and approved before any later phase moves past `Not started`.
