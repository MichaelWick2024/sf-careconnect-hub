# Live Authentication & Sandbox-to-Sandbox E2E Runbook

> **Scope.** How to wire the live Care Connect → Attorney connection and prove it end to end in sandboxes,
> then (only afterward) schedule the recovery sweep. This is **operational configuration + verification**,
> not application code — no behavior changes here.
>
> **Integration-specific names, fields, routes, state transitions, and application behavior below are
> verified against the three repositories** (`sf-careconnect-hub`, `sf-attorney-cms`, `sf-provider-med`).
> **Salesforce platform configuration and security guidance is based on current Salesforce documentation**
> and must be rechecked when platform releases or org settings change. Placeholders you must supply per
> environment are written like `<attorney-sandbox-my-domain>`. **Never commit or paste secrets** (consumer
> key/secret, tokens, certificates, real usernames, real My Domain hostnames) into source, logs, or this file.
>
> **Order is deliberate.** Do **not** schedule the hourly sweep until connectivity and permissions are
> proven — otherwise the sweep repeatedly reprocesses records while credentials are still being corrected.

---

## 1. Verified integration contract

Sourced directly from the code — do not deviate from these names.

**Care Connect (calling org — `sf-careconnect-hub`)**

- Callout constant (`AttorneyApiService.ENDPOINT`): `callout:Attorney_API/services/apexrest/v1/referrals`
- HTTP method: **POST** · timeout: **30 s** (`AttorneyApiService.TIMEOUT_MS = 30000`) · header: `Content-Type: application/json`
- **The Named Credential developer name must be exactly `Attorney_API`** — Apex references `callout:Attorney_API`, so any other name breaks the callout with no compile error.

**Attorney (target org — `sf-attorney-cms`)**

- REST route: **`POST /services/apexrest/v1/referrals`** — class `ReferralRestResource` (`@RestResource(urlMapping='/v1/referrals')`, `@HttpPost`).
- Receiver objects the endpoint writes: **`Client__c`**, **`Case__c`** (label *Legal Case*), and one sanitized **`Integration_Log__c`** per call.
- Response fields (`ReferralResponse`): `correlationId`, `success` (Boolean), `attorneyCaseId` (UUID — the contract id, from `Case__c.Attorney_Case_External_Id__c`), `attorneyCaseRecordId` (Salesforce record Id — diagnostics only), `clientRecordId`, `status` (from `Case__c.Status__c`), `message`, `errorCode`.
- **Receiver idempotency keys:** `Case__c.Care_Connect_Referral_Id__c` and `Client__c.Care_Connect_Contact_Id__c` — the endpoint upserts on the Care Connect ids, which is what makes duplicate delivery safe.

**Care Connect stores, on a validated success (transition #4):** `External_Record_Id__c = attorneyCaseId`,
`External_Record_Key__c = 'ATTORNEY|' + attorneyCaseId`, `External_Salesforce_Id__c = attorneyCaseRecordId`
(diagnostics only), `Last_Status_Code__c = 200`, `Succeeded_At__c`, `Status__c = 'Succeeded'`.

---

## 2. Manual configuration vs source-controlled metadata

The current repositories do not yet contain the live Named Credential or External Credential definitions,
so this runbook configures them manually for now. Salesforce supports source-controlling their **non-secret**
metadata (`NamedCredential` / `ExternalCredential` — the parameters and linkage, not the principal secrets);
credential-principal secrets remain environment-specific and are populated separately. The dedicated Attorney
integration **permission-set definition** must be source-controlled, while its **assignment** to the
integration user remains manual.

**Source-controlled metadata (deploy, do not re-create by hand):**

- Already in the repos: the Apex classes and `ReferralTrigger`; the objects and fields
  (`Integration_Transmission__c`, `Referral__c.Ready_For_Attorney__c`, Attorney `Client__c` / `Case__c` /
  `Integration_Log__c`); the existing permission sets (`Integration_Admin`,
  `Integration_Transmission_Runtime`, `Integration_Transmission_Support` in Care Connect; `Integration_Admin`
  in Attorney); the request/response DTOs.
- **Prerequisite to this runbook:** the dedicated **Attorney least-privilege integration permission-set
  definition** (§3.2). The `Integration_Admin` gap (no `ReferralRestResource` class access, no **API Enabled**)
  should be closed by a **permission-set metadata PR in `sf-attorney-cms`**, not recreated by hand in every
  environment. This documentation PR stays documentation-only; that permission-set PR is a separate,
  identified prerequisite.
- Optionally source-controllable: the **non-secret** `NamedCredential` (`Attorney_API`) and
  `ExternalCredential` definitions — their parameters and linkage, with sensitive principal values populated
  manually (never as plaintext metadata).

**Manual environment configuration (NOT in source; per-org, per-environment):**

- The dedicated Attorney **integration user** and the **assignment** of its permission set to that user.
- The **External Client App** and its **consumer secret**.
- The **populated credential-principal** secrets/tokens on the External Credential.
- The **principal-access** assignments (Care Connect).
- The **hourly schedule** for `AttorneyRecoverySweep` (see §10 — last).

**Never commit:** consumer key, consumer secret, access/refresh tokens, certificates, real usernames, or
real My Domain hostnames.

---

## 3. Attorney-org setup (target)

### 3.1 Dedicated integration user

Create a user solely for this integration (not a person's account). Record the username in your secure
runbook store, **not here**.

### 3.2 Least-privilege permission set for the integration user

The Attorney `Integration_Admin` permission set already grants create/edit on `Client__c`, `Case__c`, and
`Integration_Log__c`. **Gap:** it does **not** grant `ReferralRestResource` Apex-class access or the
**API Enabled** system permission. Create a dedicated permission-set **definition** (source-controlled, per §2)
assigned to the integration user that adds the following.

**Enforcement mode — read this before treating the object/field grants as the runtime requirement.** The
receiver (`ReferralRestResource` → `ReferralIntakeService`) is declared `with sharing`, and it does **not**
use `WITH USER_MODE` / `WITH SECURITY_ENFORCED` / `Security.stripInaccessible`. So **record-level sharing is
enforced, but object CRUD and field-level security are not enforced in user mode** — the DML/SOQL run in the
Apex default system mode for CRUD/FLS. Two consequences: (1) the grants that are a **hard** gate to invoking
the endpoint are **API Enabled** and **Apex-class access**; (2) the object/field grants below are
**least-privilege hygiene**, not the mechanism that makes the DML succeed. Granting them is still correct — it
keeps the permission set honest if the code later moves to user-mode enforcement (a noted hardening item) —
but the runbook does not silently present them as an FLS gate that the current code enforces.

> **Version boundary.** This enforcement description is verified for the repository's current API version,
> **v62.0**. Salesforce changed the default in **API version 67.0**: classes at **v67.0 and later default
> Apex database operations to _user mode_** (CRUD/FLS enforced), while **v66.0 and earlier default to system
> mode**. Before raising these classes' API version to 67.0+, **re-evaluate this permission set** and add
> explicit `WITH USER_MODE` / `WITH SYSTEM_MODE` (or `AccessLevel`) declarations so the enforcement is
> deliberate rather than a side effect of the version bump.

**CRUD/FLS is not record visibility.** The object/field grants below control *what kinds* of records and
fields the user may touch; they do **not** grant *visibility of specific rows*. Record visibility is a
separate axis — ownership, org-wide defaults, role hierarchy, and sharing rules. Because the receiver runs
`with sharing` and **re-queries existing `Client__c` and `Case__c` records** during idempotent processing,
confirm the integration user can actually **see every record it may need to update** — this especially matters
for records created historically or by another user. Design that visibility intentionally (ownership / sharing);
**avoid broad `View All` / `Modify All`** unless a business requirement justifies it.

- **System permission: API Enabled** — a system permission granted through a permission set or profile
  (it is what lets the user make/authenticate API calls at all). *Hard requirement.*
- **Apex class access:** `ReferralRestResource`. *Hard requirement.*
- **Object permissions** — the endpoint **re-queries existing `Client__c` and `Case__c`** during idempotent
  processing (`ReferralIntakeService` reads both to resolve prior records), so **Read** is genuinely part of
  the runtime shape, alongside create/edit:
  - `Client__c`: **Read + Create + Edit**
  - `Case__c`: **Read + Create + Edit**
  - `Integration_Log__c`: **Create**
- **Field access** (readable, and writable where the endpoint assigns) on the fields it touches —
  - `Client__c`: `Care_Connect_Contact_Id__c`, `Date_of_Birth__c`, `Email__c`, `Phone__c`, and the standard
    **`Name`** (a **Text** name — the endpoint assigns `Name = fullName`, so it is an ordinary, FLS-controlled field).
  - `Case__c`: `Attorney_Case_External_Id__c`, `Care_Connect_Referral_Id__c`, `Case_Type__c`, `Client__c`,
    `Date_Opened__c`, `Status__c`.
  - **Not** an FLS grant: `Case__c` **Name** is an **Auto Number** (`CASE-{00000}`), system-generated and
    never assigned by the endpoint — do not list it as a writable/FLS field.

You may model the object/field grants on the existing `Integration_Admin` set (adding **Read** on `Client__c`
and `Case__c`) and add API Enabled + the class access, or build the dedicated set from scratch — either way,
assign it **only** to the integration user.

### 3.3 External Client App (OAuth Client Credentials Flow)

For a new 2026 integration, prefer an **External Client App** (the newer framework); fall back to a
Connected App only if External Client Apps are unavailable in the org. Configure:

- **OAuth enabled.**
- Scope: **Manage user data via APIs (`api`)**.
- **Client Credentials Flow enabled**, with the **dedicated integration user selected as the Run As user**
  (Salesforce authenticates the *app* and executes requests as that user — correct for server-to-server
  with no interactive login per call).
- Record the **consumer key** and **consumer secret** in your secure store (never in source).

---

## 4. Care Connect setup (calling)

Use the **enhanced** External / Named Credential framework.

### 4.1 External Credential

- Developer name: **any descriptive name** (e.g. `Attorney_Sandbox_ExtCred`) — it does **not** need to be
  `Attorney_API`; it only needs to be **linked** to the Named Credential below.
- Authentication protocol: **OAuth 2.0**, flow **Client Credentials with Client Secret Flow**.
- **Named Principal** carrying the authentication parameters:
  - `client_id` = the Attorney External Client App **consumer key** (placeholder `<consumer-key>`)
  - `client_secret` = the Attorney External Client App **consumer secret** (placeholder `<consumer-secret>`)
  - Token endpoint: `https://<attorney-sandbox-my-domain>/services/oauth2/token`
- The request uses `grant_type=client_credentials`. **Secrets live only in this credential configuration.**

### 4.2 Named Credential — developer name **`Attorney_API`** (exact)

- Developer name: **`Attorney_API`** (must match the Apex `callout:Attorney_API` reference exactly).
- URL / base: `https://<attorney-sandbox-my-domain>` (the Attorney **sandbox** My Domain).
- Linked to the External Credential from §4.1.
- Generate the auth-header from the linked External Credential (standard enhanced-Named-Credential setup).

### 4.3 Principal access

Grant **access to the External Credential principal** to the user context that runs the outbound chain.
The callout is made by the async **sender Queueable**, which runs in two entry paths:

- **trigger-enqueued** (the user who saves a `Ready_For_Attorney__c` referral), and
- **sweep-enqueued** (the identity that runs `AttorneyRecoverySweep`).

Ensure both of those identities (or a shared permission set assigned to them) have principal access, plus
the existing Care Connect permission sets: **`Integration_Transmission_Runtime`** (transmission CRUD +
fields) and **`Integration_Admin`** (`Referral__c` read, `Integration_Log__c` write).

---

## 5. Authentication-only smoke test

Prove auth **before** any referral or state-machine involvement.

### 5.1 Validate client credentials against the Attorney token endpoint

From a secure shell. First load the secret into environment variables via your **approved
secret-management method** (a secret manager / vault read into the shell, not typed inline and not committed);
this keeps the secret out of the command and out of shell history. Prefer a shell configured to not persist
these commands to history at all.

```bash
# Populate from your secret store (values never typed inline, never committed):
#   export ATTORNEY_CLIENT_ID=...      export ATTORNEY_CLIENT_SECRET=...

curl --fail-with-body --silent --show-error \
  --write-out '\nHTTP_STATUS=%{http_code}\n' \
  --request POST \
  "https://<attorney-sandbox-my-domain>/services/oauth2/token" \
  --data-urlencode "grant_type=client_credentials" \
  --data-urlencode "client_id=${ATTORNEY_CLIENT_ID}" \
  --data-urlencode "client_secret=${ATTORNEY_CLIENT_SECRET}"

# Immediately clear the secret from the environment:
unset ATTORNEY_CLIENT_ID ATTORNEY_CLIENT_SECRET
```

`--fail-with-body` makes curl exit non-zero on an HTTP error (so a failure is not mistaken for success),
`--write-out` prints the status code explicitly, `--data-urlencode` encodes the values, and the variables
avoid substituting the secret directly into the command line. **Unset the variables immediately afterward.**

**Success evidence:** `HTTP_STATUS=200` with a JSON body containing `access_token` (and `token_type: Bearer`).
Do not store or paste the returned token.

### 5.2 Validate the Care Connect Named Credential WITHOUT the custom endpoint

Call a harmless **standard** Salesforce REST resource through the Named Credential — this proves the
**credential definition**, token exchange, base URL, and principal all work, without touching
`ReferralRestResource`. Run as anonymous Apex in the **Care Connect** sandbox, **as an authorized admin or
deployment user**:

```apex
HttpRequest req = new HttpRequest();
req.setEndpoint('callout:Attorney_API/services/data/v62.0/limits'); // v62.0 = the repo's API version
req.setMethod('GET');
HttpResponse res = new Http().send(req);
System.debug('STATUS=' + res.getStatusCode()); // status is the evidence; do not log the body/token
```

**Success evidence:** `STATUS=200`. This confirms the credential chain (token exchange + base URL + the
admin's principal access) without exercising business logic.

**Do NOT run this smoke test as ordinary referral or integration users to "prove" their principal access.**
Execute Anonymous requires **API Enabled + Author Apex**, and a Named-Credential callout from Anonymous Apex
now also requires **Customize Application** — broad administrative permissions that must **not** be temporarily
granted to business or integration users just to run a test. Instead, prove each runtime identity's principal
access through the path it actually uses:

1. **Trigger-enqueued identity** — prove it with the **real §6 end-to-end referral**, executed as a
   **representative user who can set `Ready_For_Attorney__c`** (the ordinary save path, no elevated
   permissions). A `Succeeded` transmission demonstrates that user's principal access end to end.
2. **Sweep-owner identity** — prove it with **one controlled sweep execution initiated by the intended
   scheduled-job owner** (run `AttorneyRecoverySweep` once as that user) **before** creating the recurring
   schedule (§10). That owner must **already legitimately hold** the permissions needed to schedule/execute
   Apex — do **not** grant them merely for this test.
3. Only run the §5.2 Anonymous Apex *as* a runtime identity if that identity **already legitimately holds**
   API Enabled + Author Apex + Customize Application — never grant them for the test.

**Record for the config-only smoke test and each identity proof:** the username, the assigned principal-access
permission set, the timestamp, and the outcome (HTTP status for §5.2; transmission state for the §6 / sweep
proofs). **Never** record the access token or response body.

**Interpreting failures:** see the troubleshooting matrix (§8). If §5.1 fails, the problem is in the External
Client App / consumer key / secret / token URL. If §5.1 succeeds but §5.2 (admin) fails, the problem is in the
Care Connect External Credential / Named Credential configuration. If §5.2 passes for the admin but a runtime
identity's real path (§6 or the sweep) fails on auth, that identity is missing **principal access** (grant it,
per §4.3).

---

## 6. Full sandbox-to-sandbox referral test

Only after §5 passes.

### 6.1 Setup data and trigger the referral **as the representative referral user**

This E2E run doubles as the **trigger-identity principal-access proof** (§5.2), so the state change that
starts the chain must be performed **by the representative referral user through the normal UI** — *not* via
Anonymous Apex. Anonymous Apex runs the trigger and Queueable chain as *the person executing the script*
(typically an admin), which would prove the admin's principal access, not the referral user's.

**Sequence:**

1. **An authorized admin** creates the fabricated `Contact` and a **not-ready** `Referral__c`
   (`Ready_For_Attorney__c = false`, so the trigger does **not** fire yet):

   ```apex
   Contact c = new Contact(
       FirstName = 'Jordan', LastName = 'Rivera-E2E',
       Email = 'jordan.e2e@example.com', Phone = '555-0100',
       Birthdate = Date.newInstance(1990, 5, 12));
   insert c;

   Referral__c r = new Referral__c(
       Status__c = 'New',
       Referral_Type__c = 'General',            // a verified restricted value
       Contact__c = c.Id,
       Ready_For_Attorney__c = false);          // NOT ready yet — trigger stays quiet
   insert r;
   System.debug('Referral=' + r.Id + '  Contact=' + c.Id);
   ```

2. **Log in as the representative referral user** (a user who legitimately can edit referrals — no elevated
   Apex permissions).
3. Open that `Referral__c` through the **normal UI**.
4. Change `Ready_For_Attorney__c` from **false → true** and **save**.
5. **Record** that user's username and assigned principal-access permission set (the trigger-identity
   evidence for §5.2 / §10).
6. Poll the transmission (per the bounded-poll procedure below).

The false→true UI save fires `ReferralTrigger` → creates one transmission → `enqueueRoot` → the
dispatcher/sender chain runs **asynchronously**, enqueued **under the referral user's identity**, and makes
the **real** callout to the Attorney sandbox — which is exactly what proves that user's principal access end
to end.

> **Optional admin functional test (not an identity proof).** The all-in-one Anonymous Apex form — insert the
> Contact and a `Ready_For_Attorney__c = true` Referral in one script — is a convenient *functional* smoke
> test, but it runs the chain as the executing admin. It is **not sufficient to prove the ordinary trigger
> user's principal access**; use the UI sequence above for that.

**Wait with a bounded poll, not a fixed sleep.** Because the send is asynchronous, re-run the Care Connect
transmission query (§6.5) **every 5–10 seconds for up to ~2 minutes**, until the transmission reaches a
**terminal or retry state** — `Succeeded`, `Failed`, or `Retry Scheduled`. If it has **not** left `Pending` /
`Processing` within that window, inspect: (a) `AsyncApexJob` for the dispatcher/sender classes (see the query
in §8), (b) the transmission's own error fields (`Last_Error_Code__c`, `Last_Status_Code__c`), and (c) the
Care Connect `Integration_Log__c` rows for the referral. Do not assume success from elapsed time alone.

```apex
// Optional poll helper (anonymous Apex): report the current state once.
Integration_Transmission__c t = [
    SELECT Status__c, Last_Error_Code__c, Last_Status_Code__c
    FROM Integration_Transmission__c WHERE Referral__c = '<referral-id>' LIMIT 1];
System.debug('STATE=' + t.Status__c + ' err=' + t.Last_Error_Code__c + ' http=' + t.Last_Status_Code__c);
```

### 6.2 Expected `Integration_Transmission__c` lifecycle (Care Connect)

`Pending` → `Processing` (claimed) → **`Succeeded`**.

### 6.3 Expected Attorney records (Attorney sandbox)

- One **`Client__c`** with `Care_Connect_Contact_Id__c` = the Care Connect Contact Id.
- One **`Case__c`** (*Legal Case*) with `Care_Connect_Referral_Id__c` = the Care Connect Referral Id,
  `Attorney_Case_External_Id__c` = a v4 UUID, and a `Status__c`.
- One sanitized **`Integration_Log__c`** with the matching `Correlation_Id__c`.

### 6.4 Expected values stored in Care Connect (on the transmission)

- `Status__c = 'Succeeded'`
- `External_Record_Id__c` = the Attorney `attorneyCaseId` (v4 UUID)
- `External_Record_Key__c` = `ATTORNEY|<attorneyCaseId>`
- `External_Salesforce_Id__c` = the Attorney `attorneyCaseRecordId` (diagnostics only)
- `Last_Status_Code__c = 200`, `Succeeded_At__c` populated
- Exactly one Care Connect `Integration_Log__c` with `Success__c = true` and sanitized payloads.

### 6.5 Evidence to capture

**Care Connect:**

```apex
SELECT Id, Status__c, Correlation_Id__c, External_Record_Id__c, External_Record_Key__c,
       External_Salesforce_Id__c, Last_Status_Code__c, Succeeded_At__c
FROM Integration_Transmission__c WHERE Referral__c = '<referral-id>'
```
```apex
SELECT Id, Success__c, Status_Code__c, Correlation_Id__c
FROM Integration_Log__c WHERE Referral__c = '<referral-id>'
```

**Attorney:**

```apex
SELECT Id, Attorney_Case_External_Id__c, Care_Connect_Referral_Id__c, Status__c, Client__c
FROM Case__c WHERE Care_Connect_Referral_Id__c = '<referral-id>'
```
```apex
SELECT Id, Care_Connect_Contact_Id__c FROM Client__c WHERE Care_Connect_Contact_Id__c = '<contact-id>'
```
```apex
// The Attorney-side receiver log — confirms the inbound call landed and its correlation id matches
// the Care Connect log's correlation id. Fields verified against sf-attorney-cms Integration_Log__c.
SELECT Id, Correlation_Id__c, Success__c, Status_Code__c, Direction__c, Timestamp__c, CreatedDate
FROM Integration_Log__c WHERE Correlation_Id__c = '<correlation-id>' ORDER BY CreatedDate DESC
```

Record: the transmission's final state + stored ids, the Attorney Case/Client ids, the Attorney log's
`Success__c`/`Status_Code__c`, and that the **same** `correlationId` appears on the Care Connect log, the
Attorney log, and the response — i.e. the two logs correlate across orgs.

---

## 7. Additional test cases

### 7.1 Duplicate delivery / idempotency (receiver upsert)

Care Connect will **not** create a second logical transmission for the same referral (the unique
`Transmission_Key__c` prevents it), so duplicate *delivery* is exercised via the at-least-once path: the same
request reaches Attorney a second time. **A genuine resend legitimately writes a genuine attempt log** — this
test proves the *receiver* deduplicates the business record; it does **not** assert log counts (that is the
separate §7.7 test, which uses a no-dispatch path). Run this in an isolated sandbox with no other outbound
traffic.

1. Start from a **successfully delivered** transmission (a completed §6 run). Record the Attorney **Case
   record Id**, the **Case count** for that `Care_Connect_Referral_Id__c` (expected **1**), and the **Client
   count** for that `Care_Connect_Contact_Id__c` (expected **1**).
2. Recreate the at-least-once condition in the sandbox: strand the already-delivered row back into stale
   `Processing` (as if the local success-write had been lost), using §7.5's stranding snippet on that
   transmission id.
3. Run the sweep (`new AttorneyRecoverySweep().execute(null);`). A **below-ceiling** stale row recovers to
   `Retry Scheduled` and is **re-dispatched**, so the sender re-sends the same referral to Attorney.
4. Wait for the resend to finish (bounded poll, per §6).

**Expected:** Attorney upserts rather than duplicates — the **same** Attorney Case record is retained, the
**Case count stays 1**, and the **Client count stays 1** (`Case__c` upserts on `Care_Connect_Referral_Id__c`,
`Client__c` on `Care_Connect_Contact_Id__c`). One **additional genuine** Care Connect attempt log and one
additional Attorney receiver log are **expected and allowed** — the resend really happened.

### 7.2 Invalid request / non-retryable validation failure

Create a referral that fails **local** request validation before any HTTP call — e.g. a referral with **no
Contact** (the mapper then produces an invalid `careConnectContactId`).
**Expected:** no callout; transmission → `Failed`; `Last_Error_Code__c = INVALID_REQUEST`;
`Last_Status_Code__c = 0`; the attempt log records only the failed check name (no values).

### 7.3 Retryable HTTP failure

A transient failure (timeout / 429 / 5xx) drives `Retry Scheduled` with a backoff (`SERVER_ERROR` etc.).
Against a live sandbox this is only reproducible **where the peer or a dedicated test hook can return such
a status** — do not manufacture it if the Attorney sandbox provides no safe hook. Where reproducible,
confirm the transmission → `Retry Scheduled` with a future `Next_Retry_At__c`.

### 7.4 Authentication failure (isolated, evidence-based — not a required gate)

**Important:** the intuitive expectation ("bad secret → `UNAUTHORIZED` → `Failed`") is **not** what the code
does. `UNAUTHORIZED → PERMANENT_FAILURE → Failed` is produced **only** by an actual HTTP **401/403 from an
authenticated call** ([`AttorneyApiService.classifyErrorStatus`](../force-app/main/default/classes/AttorneyApiService.cls)).
A **bad External Credential secret fails during the OAuth token exchange, before any target HTTP response
exists** — Apex receives a `System.CalloutException`, which the service classifies as **`CALLOUT_FAILED` /
`TRANSIENT_FAILURE` (statusCode 0)** → the transmission goes to **`Retry Scheduled`**, not `Failed`. So do
not assert `UNAUTHORIZED` from credential corruption.

Because it perturbs a shared credential, treat this as **optional and evidence-based**, never a required
production-readiness gate:

- Run **only in an isolated sandbox with no concurrent outbound traffic.**
- First test an **invalid secret directly against the token endpoint** (the §5.1 curl with a wrong secret):
  confirm the **token request itself** returns a non-200 — this is the real, contained signal.
- If you do drive a referral through a broken credential, **document the actual Apex outcome you observe**
  (expected: `CALLOUT_FAILED` / `Retry Scheduled`, from the Named Credential token-exchange exception) rather
  than asserting a predetermined `UNAUTHORIZED`.
- For genuine **target-endpoint 401/403 → `UNAUTHORIZED` → `Failed`** classification, **rely on the existing
  unit tests**, which exercise that path deterministically — unless the Attorney sandbox offers a **safe hook**
  that returns 401/403 *after* a successful authentication.
- **Restore the correct credential immediately** afterward.

### 7.5 Stale `Processing` recovery (sweep)

Manually strand a row (Care Connect, anonymous Apex), then run the sweep once:

```apex
// Make an Attorney transmission look stale (Processing, started > 15 min ago). Use a real transmission id.
update new Integration_Transmission__c(
    Id = '<transmission-id>', Status__c = 'Processing',
    Processing_Started_At__c = Datetime.now().addMinutes(-20),
    Claim_Token__c = 'cccccccc-dddd-4eee-8fff-999999999999');

new AttorneyRecoverySweep().execute(null); // runs the sweep once
```

**Expected:** budget left → `Retry Scheduled` (`Last_Error_Code__c = STALE_CLAIM_RECOVERED`) and dispatched;
budget spent → `Failed` (`RETRY_BUDGET_EXHAUSTED`).

### 7.6 Exhausted-retry repair (sweep)

Strand a due `Retry Scheduled` row at the ceiling (`Retry_Count__c = 3`, `Next_Retry_At__c` in the past),
run `new AttorneyRecoverySweep().execute(null);`.
**Expected:** transmission → `Failed`, `Last_Error_Code__c = RETRY_BUDGET_EXHAUSTED`, not dispatched.

### 7.7 Sweep creates no synthetic attempt log (terminal, no-dispatch path only)

This test asserts the sweep itself never fabricates an attempt log. It must use a **terminal path that
performs no dispatch** — otherwise a genuine resend's log would be miscounted as a "synthetic" log. Do **not**
use a below-ceiling stale recovery here: that re-dispatches and legitimately writes a real log (that is §7.1).

Use **one** of the no-dispatch terminal paths:

- an **at-ceiling due `Retry Scheduled`** row → `#11` repair to `Failed` (§7.6), or
- a **stale `Processing` row whose retry budget is already exhausted** → `#8b` to `Failed` (the
  budget-spent branch of §7.5).

Procedure: capture the `Integration_Log__c` count for that correlation id **before** the sweep, run
`new AttorneyRecoverySweep().execute(null);`, wait for completion (per §6), then re-count:

```apex
SELECT COUNT() FROM Integration_Log__c WHERE Correlation_Id__c = '<the-repaired-transmission-correlation-id>'
```

**Expected:** the count is **unchanged** — a terminal repair changes only transmission *state* and performs
no send, so it writes no log. (Only genuine send attempts write logs; that is what §7.1 confirms separately.)

---

## 8. Troubleshooting matrix

| Symptom | Likely cause | Where to inspect | Corrective action |
|---|---|---|---|
| **Token request fails** (§5.1 non-200) | External Client App misconfig; wrong consumer key/secret; wrong token URL; Client Credentials Flow not enabled / no Run As user | Attorney: External Client App OAuth settings, Run As user | Fix the app config / Run As user; re-copy consumer key/secret |
| **Named Credential call fails** (§5.2 non-200 while §5.1 is 200) | External Credential / Named Credential misconfig; missing principal access; Named Credential not named `Attorney_API` | Care Connect: External Credential principal, Named Credential name + linkage, principal-access assignment | Correct the credential; confirm dev name `Attorney_API`; grant principal access |
| **OAuth/token-exchange callout exception** (no target HTTP response; Care Connect classifies `CALLOUT_FAILED` / `Retry Scheduled`, `Last_Status_Code__c = 0`) | External Credential secret/token URL wrong, or token exchange otherwise failing before the endpoint is reached | Care Connect: External Credential principal secret + token endpoint; §5.1 direct token test | Fix the External Credential secret / token URL; re-run §5.1 to confirm a 200 before retrying |
| **Missing External Credential principal access** (§5.2 admin `limits` passes, but a runtime identity's real path — the §6 E2E run or the controlled sweep — fails on auth) | The runtime identity (trigger user or sweep owner) lacks principal access | Care Connect: principal-access assignment for that user (§4.3) | Grant principal access to that identity (or a shared permission set assigned to it) |
| **401 from the target after a successful token exchange** (real HTTP 401 → `UNAUTHORIZED` → `Failed`) | The bearer token was rejected, expired, or revoked; token/instance mismatch. *Wrong secret / disabled app / token-URL errors are **token-exchange** failures — see the token-request and OAuth/token-exchange rows above, not here.* | Named Credential callout logs; Attorney authentication logs | Confirm §5.1 succeeds; confirm the Named Credential points to the **same Attorney instance** that issued the token; then reauthorize or repair the credential |
| **403** | Integration-user permission gap (**API Enabled** or **`ReferralRestResource` class access**), or app policy. *Not an object/field-FLS gap — the receiver runs CRUD/FLS in system mode (§3.2), so missing FLS does not 403.* | Attorney: the integration user's permission set; External Client App policies | Add API Enabled + `ReferralRestResource` class access (object/field grants are least-privilege hygiene per §3.2, not the 403 cause) |
| **404 NOT_FOUND** | Wrong base URL or REST path | Care Connect: Named Credential base URL; the `/services/apexrest/v1/referrals` path | Fix base URL / confirm the Attorney route is deployed |
| **400 VALIDATION_REJECTED** | Payload/contract mismatch at the Attorney validator | Care Connect log `Sanitized_Request_JSON__c`; Attorney request validator | Fix the mapped request / contract |
| **429 RATE_LIMITED (transient)** | Attorney throttling the caller | Attorney logs; Care Connect `Last_Error_Code__c = RATE_LIMITED` | Retry is automatic (backoff); reduce send rate if persistent |
| **5xx SERVER_ERROR (transient)** | Attorney-side error | Attorney logs | Retry is automatic; investigate the Attorney error |
| **Transmission never leaves `Pending` / `Processing`** | Queueable chain never ran, died, or the depth guard stopped it; scheduled job failed | Care Connect: `AsyncApexJob` (query below); transmission error fields | Inspect/abort the job; let the sweep resurface the row; check depth-guard/capacity |

Query to inspect the async chain / scheduled job state during any of the above:

```apex
SELECT Id, ApexClass.Name, JobType, Status, ExtendedStatus, NumberOfErrors, CompletedDate
FROM AsyncApexJob
WHERE ApexClass.Name IN ('AttorneyDispatchQueueable','AttorneySendQueueable','AttorneyRecoverySweep')
ORDER BY CreatedDate DESC LIMIT 50
```

---

## 9. Credential rotation & rollback

- **Rotate without touching the Named Credential reference.** Generate a new consumer secret in the
  Attorney External Client App, then update the **External Credential** principal's `client_secret`. The
  Named Credential developer name stays **`Attorney_API`**, so **no Apex change and no redeploy** are
  needed.
- **Revoke a compromised credential.** Rotate the External Client App consumer secret **immediately** to
  prevent new token issuance with the compromised secret, and disable the app when appropriate to block new
  authentication. **Separately revoke active OAuth sessions/tokens** through Salesforce **OAuth Usage** —
  either the affected token or all tokens associated with the External Client App (or use the OAuth revocation
  endpoint). Rotating or disabling the app must **not** be treated as proof that every previously issued token
  has already been invalidated. Update the External Credential afterward.
- **Stop additional work from being started (not a true circuit breaker).** Deactivate `ReferralTrigger`
  (set its status to Inactive via metadata deploy) to stop **new** trigger-created transmissions, and
  unschedule `AttorneyRecoverySweep` (abort its `CronTrigger`) to stop **future** recovery dispatches. **These
  steps do not cancel already-queued or executing Queueables.** Specifically, they do **not** stop:
  Queueables already enqueued, a currently executing sender, a previously started dispatcher/sender chain, or
  transmissions already in `Processing`.
  - Inspect **`AsyncApexJob`** for the dispatcher/sender classes (`AttorneyDispatchQueueable`,
    `AttorneySendQueueable`) — see the query in §8 — to see what remains queued or running.
  - **Abort** jobs that are in an abortable queued state (`System.abortJob(jobId)`) when appropriate.
  - Understand that a **callout already in flight may still complete** — you cannot interrupt it mid-flight.
  - **Record any rows left in `Processing`** so the sweep can recover them later once it is re-enabled.
  - **Do not deliberately invalidate credentials as a pause mechanism.** Once auth is broken, an in-flight
    or budget-limited chain can classify failures and convert durable `Pending`/`Retry Scheduled` work into
    permanent `Failed` rows — the opposite of a safe pause.
- **Preserve `Pending` / due `Retry Scheduled` transmissions.** These are durable state — do **not** delete
  them. When the connection is restored, they are resumed by the **sweep** (re-enabled/rescheduled), **not**
  by reactivating the trigger — the trigger only starts *new* referrals. Attorney idempotency makes any
  redelivery safe.

> **Known limitation (future hardening):** there is **no true runtime circuit breaker** — no switch that
> halts in-flight sends and prevents an executing chain from advancing. Deactivating the trigger and
> unscheduling the sweep only stops *new* work from starting. A real kill-switch (e.g. a custom-setting flag
> the dispatcher/sender check before each send) is a recommended future enhancement.

---

## 10. Production-readiness checklist

Complete **in order**; the last item is gated on all the others.

- [ ] **Authentication proven** — §5.1 token success; §5.2 `limits` success as an authorized admin/deployment
      user (credential definition proven); the **trigger identity** proven via the real §6 E2E run and the
      **sweep-owner identity** via one controlled sweep execution (§5.2) — no broad admin permissions granted
      for testing; evidence recorded (username, principal-access set, timestamp, outcome — no token/body).
- [ ] **E2E referral passed** — §6: transmission `Succeeded`, ids stored, Attorney `Case__c`/`Client__c`
      created, correlation ids match across orgs.
- [ ] **Negative + duplicate tests passed** — §7: invalid-request (`INVALID_REQUEST`, no callout);
      duplicate delivery retains a single Attorney `Case__c` (§7.1, genuine resend log allowed); stale
      recovery + ceiling repair behave; and the no-dispatch terminal path writes **no** attempt log (§7.7).
- [ ] **Conditional live-failure tests (only with a safe isolated mechanism)** — §7.3 live 5xx/429 and §7.4
      live authentication failure are **optional**, run only in an isolated sandbox and only where a safe
      hook exists; the token endpoint's own non-200 (§5.1) and the existing unit tests are the primary
      evidence for these paths. Not a hard gate.
- [ ] **Permissions reviewed** — integration user is least-privilege (hard: API Enabled +
      `ReferralRestResource` class access; plus **Read**+Create+Edit on `Client__c`/`Case__c` and Create on
      `Integration_Log__c`, and only the required fields); the Attorney permission-set **definition** is
      source-controlled (prerequisite PR, §2); Care Connect principal access covers both trigger- and
      sweep-enqueued contexts.
- [ ] **Secrets stored only in credential configuration** — nothing in source, logs, or this file.
- [ ] **Hourly recovery sweep scheduled — ONLY after everything above passes:**

```apex
// Confirm the name/cron against your deployment conventions before running.
System.schedule('Attorney Recovery Sweep - Hourly', '0 0 * * * ?', new AttorneyRecoverySweep());
```

> Do not perform this last step while credentials or permissions are still being corrected — a scheduled
> sweep would repeatedly reprocess records against a broken connection.
