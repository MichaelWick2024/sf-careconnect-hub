/**
 * Owns the synchronous transition rules for the Attorney outbound state machine:
 *
 *   #1      create-or-get                       (createReferralTransmissions — does its own DML)
 *   #2–#3   claim                               (claim — FOR UPDATE, does its own DML)
 *   #4–#7   apply a controlled callout outcome  (applySendOutcome)
 *   #7b     external-record conflict            (applyExternalConflict)
 *   #8a–#8b stale-claim recovery                (applyStaleRecovery)
 *
 * Creation and claim perform their own DML. The outcome/recovery methods mutate a record IN MEMORY;
 * their callers own locking and persistence (a sender does every callout before any DML). This class
 * performs NO callouts.
 *
 * The status-and-token authorization PREDICATE is enforced HERE rather than duplicated in Queueable
 * code — but the caller remains responsible for passing a freshly-locked row (requery FOR UPDATE after
 * the callouts) so the predicate is evaluated against CURRENT database state; this class cannot prove
 * that on its own. A callout can run up to the per-attempt timeout, and during it the recovery sweep
 * may declare the claim stale and re-claim the row with a NEW token — so the pre-callout token check is
 * only an early-exit optimization; the authoritative check is AFTER the callouts, before the write:
 *   - applySendOutcome requires the sender's expected claim token and refuses to write a row that is
 *     no longer Processing or whose token has rotated;
 *   - applyStaleRecovery refuses a row that is not genuinely still stale.
 * Both return a controlled ApplyResult{applied, reason} rather than throwing or mutating on a mismatch.
 * The caller MUST pass a freshly-locked row (requery FOR UPDATE after the callouts) so the check runs
 * against current database state — see the spec's "Transaction 2 — send".
 *
 * Inbound ADRs walked and applied here (earned once, must not be re-lost):
 *   - Creation is idempotent via the unique Transmission_Key__c + partial-success DML; a concurrent
 *     duplicate resolves by requery, any non-duplicate failure surfaces loudly (ADR-010).
 *   - The claim locks with FOR UPDATE; UNABLE_TO_LOCK_ROW means "someone else is claiming" (a NORMAL
 *     outcome), returned as `locked`, never thrown.
 *   - Correlation_Id__c is one v4 UUID per transmission, reused across attempts; Claim_Token__c is a
 *     new v4 UUID per attempt and is the authority for who may write outcome state.
 *
 * Attorney-specific creation (Target/Operation + External_Record_Key target code); the claim is
 * target-agnostic. Provider gets its own creation/outcome entry points later.
 */
public with sharing class AttorneyTransmissionService {

    @TestVisible private static final String TARGET = 'ATTORNEY';
    @TestVisible private static final String OPERATION = 'CREATE_REFERRAL';
    public static final Integer MAX_RETRIES = 3;

    // Namespaces the External_Record_Key (TARGET_CODE|external id) so uniqueness is per target system.
    // Attorney's code; when Provider send lands, its outcome application passes 'PROVIDER'.
    private static final String TARGET_CODE = TARGET; // 'ATTORNEY'

    // Backoff (transition #5): Next_Retry_At = Last_Attempt_At + BASE * 2^Retry_Count, capped.
    // BASE = 60 min -> retries become DUE at ~+1h, +2h, +4h. This is sized to the recovery sweep, which
    // is scheduled HOURLY (a single Scheduled Apex job cannot run more than once per hour), so a shorter
    // base could only mark a row due sooner than the sweep can ever pick it up. The cap must exceed the
    // largest scheduled backoff (60 * 2^(MAX_RETRIES-1) = 240) or it would flatten the schedule.
    @TestVisible private static final Integer BASE_BACKOFF_MINUTES = 60;
    @TestVisible private static final Integer MAX_BACKOFF_MINUTES = 240;

    // Status API values (restricted picklist).
    private static final String PENDING = 'Pending';
    private static final String PROCESSING = 'Processing';
    private static final String RETRY_SCHEDULED = 'Retry Scheduled';
    private static final String SUCCEEDED = 'Succeeded';
    private static final String FAILED = 'Failed';

    // Controlled internal error codes this layer WRITES. The callout-derived codes (RATE_LIMITED,
    // SERVER_ERROR, VALIDATION_REJECTED, ...) arrive already-classified on the CalloutOutcome; these
    // three are the ones the STATE MACHINE originates, never a remote value. (Last_Error_Code__c is
    // Text(80), controlled vocabulary only — never a remote or platform message.)
    @TestVisible private static final String RETRY_BUDGET_EXHAUSTED = 'RETRY_BUDGET_EXHAUSTED';
    @TestVisible private static final String EXTERNAL_RECORD_CONFLICT = 'EXTERNAL_RECORD_CONFLICT';
    @TestVisible private static final String STALE_CLAIM_RECOVERED = 'STALE_CLAIM_RECOVERED';

    // ---- #1: create-or-get -------------------------------------------------

    /**
     * Ensures a Pending Attorney "Create Referral" transmission exists for each referral.
     * Idempotent: a referral that already has one keeps it (and its correlation id). Returns every
     * transmission for the given referrals (pre-existing + newly created).
     */
    public static List<Integration_Transmission__c> createReferralTransmissions(Set<Id> referralIds) {
        if (referralIds == null || referralIds.isEmpty()) {
            return new List<Integration_Transmission__c>();
        }
        Map<String, Id> referralByKey = new Map<String, Id>();
        for (Id referralId : referralIds) {
            referralByKey.put(keyFor(referralId), referralId);
        }

        // Attempt one per referral. The unique Transmission_Key__c IS the idempotency mechanism —
        // a referral that already has a transmission (from a prior run or a concurrent trigger)
        // fails with DUPLICATE_VALUE, which we ignore, and the requery below RESOLVES (and proves)
        // idempotency. No pre-query dedup: the DB constraint is the single source of truth, so there
        // is no window between "check" and "insert" to race on.
        List<Integration_Transmission__c> toCreate = new List<Integration_Transmission__c>();
        List<String> orderedKeys = new List<String>();
        for (String key : referralByKey.keySet()) {
            orderedKeys.add(key);
            toCreate.add(new Integration_Transmission__c(
                Referral__c = referralByKey.get(key),
                Target_System__c = TARGET,
                Operation__c = OPERATION,
                Transmission_Key__c = key,
                Correlation_Id__c = Uuid.v4(),   // once, per genuinely-new row; reused across attempts
                Status__c = PENDING,
                Retry_Count__c = 0
            ));
        }

        List<Database.SaveResult> results = Database.insert(toCreate, false); // partial success
        List<String> hardFailures = new List<String>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            // A row is an acceptable duplicate ONLY if EVERY one of its errors is DUPLICATE_VALUE.
            // A non-duplicate error — alone or alongside a duplicate — is a hard failure, never
            // swallowed. (This object has multiple unique fields, and getErrors() may return several.)
            if (!allDuplicate(results[i].getErrors())) {
                hardFailures.add(orderedKeys[i] + ' -> ' + errorCodes(results[i].getErrors()));
            }
        }
        if (!hardFailures.isEmpty()) {
            throw new TransmissionException('Transmission create failed for: ' + String.join(hardFailures, '; '));
        }

        // The requery is the PROOF of idempotency, not the ignored DUPLICATE_VALUE: every requested
        // key must resolve to exactly one row (Transmission_Key__c is unique, so "resolved" implies
        // "exactly one"). A key ignored as a "duplicate" that does not actually exist is caught here
        // rather than silently returned as a short list.
        Map<String, Integration_Transmission__c> byKey = new Map<String, Integration_Transmission__c>();
        for (Integration_Transmission__c t : [
            SELECT Id, Referral__c, Transmission_Key__c, Correlation_Id__c, Status__c, Retry_Count__c
            FROM Integration_Transmission__c
            WHERE Transmission_Key__c IN :referralByKey.keySet()
        ]) {
            byKey.put(t.Transmission_Key__c, t);
        }
        Integer unresolved = 0;
        for (String key : referralByKey.keySet()) {
            if (!byKey.containsKey(key)) {
                unresolved++;
            }
        }
        if (unresolved > 0) {
            throw new TransmissionException(unresolved + ' transmission key(s) could not be resolved after create.');
        }
        return byKey.values();
    }

    // ---- #2 / #3: claim ----------------------------------------------------

    public class ClaimResult {
        public Id transmissionId { get; private set; }
        public Boolean claimed { get; private set; }
        public String claimToken { get; private set; } // set only when claimed
        public String reason { get; private set; }     // when not claimed: 'not-eligible' | 'locked' | 'not-found'
        private ClaimResult(Id transmissionId, Boolean claimed, String claimToken, String reason) {
            this.transmissionId = transmissionId;
            this.claimed = claimed;
            this.claimToken = claimToken;
            this.reason = reason;
        }
    }

    /**
     * Claims ONE transmission with a row lock. A successful claim moves it to Processing, assigns a
     * fresh Claim_Token__c, and (from Retry Scheduled) increments Retry_Count__c and clears
     * Next_Retry_At__c. Returns `locked` if another transaction holds the row (a normal concurrency
     * outcome), `not-eligible` if its state disallows it, `not-found` if it does not exist. Only the
     * returned claim token authorizes the subsequent send.
     *
     * Claim is deliberately SINGULAR (matching the normative spec's `WHERE Id = :id FOR UPDATE`), so
     * a lock-failure result is confined to the contested row. NOTE: the dispatcher loops this within
     * ONE transaction, so a contested row can still DELAY the dispatcher while Salesforce waits for
     * the lock (up to ~10s before UNABLE_TO_LOCK_ROW), and locks already acquired in that transaction
     * stay held until it ends. Singular claiming bounds the blast radius of a lock failure; it does
     * not make contention free. The dispatcher must therefore loop a BOUNDED batch.
     */
    public static ClaimResult claim(Id transmissionId) {
        if (transmissionId == null) {
            return new ClaimResult(null, false, null, 'not-found');
        }

        List<Integration_Transmission__c> locked;
        try {
            locked = [
                SELECT Id, Status__c, Next_Retry_At__c, Retry_Count__c
                FROM Integration_Transmission__c
                WHERE Id = :transmissionId
                FOR UPDATE
            ];
        } catch (System.QueryException qe) {
            // FOR UPDATE lock contention -> UNABLE_TO_LOCK_ROW. Someone else is claiming this row;
            // a normal concurrency outcome, confined to this row. Report `locked`, never throw.
            if (isUnableToLock(qe)) {
                return new ClaimResult(transmissionId, false, null, 'locked');
            }
            throw qe;
        }
        if (locked.isEmpty()) {
            return new ClaimResult(transmissionId, false, null, 'not-found');
        }

        // Capture the time AFTER the row is acquired, not before the (possibly delayed) lock wait —
        // so the timestamps and the due-check reflect the successful claim, not the lock request.
        Datetime claimTime = Datetime.now();
        Integration_Transmission__c t = locked[0];
        if (!isClaimable(t, claimTime)) {
            return new ClaimResult(t.Id, false, null, 'not-eligible');
        }

        Boolean fromRetry = (t.Status__c == RETRY_SCHEDULED); // capture BEFORE mutating Status
        String token = Uuid.v4();                             // new per attempt
        t.Status__c = PROCESSING;
        t.Claim_Token__c = token;
        t.Processing_Started_At__c = claimTime;
        t.Last_Attempt_At__c = claimTime;
        if (fromRetry) {
            t.Retry_Count__c = retryCount(t) + 1; // transition #3 increments
            t.Next_Retry_At__c = null;            // ...and clears the now-meaningless retry time
        }
        update t;
        return new ClaimResult(t.Id, true, token, null);
    }

    // ---- eligibility -------------------------------------------------------

    private static Boolean isClaimable(Integration_Transmission__c t, Datetime now) {
        if (t.Status__c == PENDING) {
            return true;
        }
        if (t.Status__c == RETRY_SCHEDULED) {
            return t.Next_Retry_At__c != null
                && t.Next_Retry_At__c <= now
                && retryCount(t) < MAX_RETRIES;
        }
        return false; // Processing / Succeeded / Failed are not claimable
    }

    // ---- #4–#7b: apply a send outcome to a claimed row (in memory) ----------

    /** Whether a guarded transition applied, and if not, the controlled reason it was refused. */
    public class ApplyResult {
        public Boolean applied { get; private set; }
        public String reason { get; private set; } // null when applied
        private ApplyResult(Boolean applied, String reason) {
            this.applied = applied;
            this.reason = reason;
        }
    }

    /**
     * Applies the callout result to a claimed transmission IN MEMORY — the caller owns the DML (all
     * callouts must precede any DML in the sender). Dispatches on disposition and budget:
     *   #4  SUCCESS             → Succeeded (external ids, Succeeded_At; clears in-flight + retry state)
     *   #5  TRANSIENT, budget   → Retry Scheduled (Last_Error_Code, backoff Next_Retry_At)
     *   #6  TRANSIENT, no budget → Failed (RETRY_BUDGET_EXHAUSTED)
     *   #7  PERMANENT           → Failed (the outcome's own error code)
     *
     * AUTHORIZATION. Writes ONLY when the row is still Processing AND its Claim_Token__c matches the
     * sender's expected token — the row `t` must be freshly locked (requeried FOR UPDATE after the
     * callouts). Otherwise the sender is stale: a recovery re-claimed the row with a new token while
     * this attempt was in flight, and overwriting would clobber the newer attempt and clear its token.
     * On refusal the row is left UNTOUCHED and ApplyResult.reason is 'stale-claim' (token mismatch or
     * no longer Processing) or 'no-expected-token' (a caller programming error). An authorization
     * refusal returns ApplyResult rather than throwing; a null transmission or outcome is a programming
     * error that may still throw.
     *
     * Retry_Count is NOT incremented here — it increments on the next CLAIM (#3). This only READS it
     * to decide whether the budget is spent.
     *
     * A #4 write sets the unique External_Record_Key__c; if the caller's DML reports DUPLICATE_VALUE
     * on it, the caller reclassifies that row via applyExternalConflict (#7b) — this method cannot,
     * because the collision is only visible at DML time.
     */
    public static ApplyResult applySendOutcome(
        Integration_Transmission__c t,
        AttorneyApiService.CalloutOutcome o,
        String expectedClaimToken
    ) {
        if (String.isBlank(expectedClaimToken)) {
            return new ApplyResult(false, 'no-expected-token');
        }
        // .equals (case-sensitive) — an authorization value must not match on Apex ==’s case-insensitivity.
        if (t.Status__c != PROCESSING || !expectedClaimToken.equals(t.Claim_Token__c)) {
            return new ApplyResult(false, 'stale-claim');
        }

        Datetime now = Datetime.now();
        t.Last_Status_Code__c = o.statusCode; // most recent HTTP status (0 when there was no response)

        if (o.disposition == AttorneyApiService.Disposition.SUCCESS) {
            t.Status__c = SUCCEEDED;
            t.External_Record_Id__c = o.attorneyCaseId;                     // validated v4
            t.External_Record_Key__c = TARGET_CODE + '|' + o.attorneyCaseId;
            t.External_Salesforce_Id__c = o.attorneyCaseRecordId;           // may be null; diagnostics only
            t.Succeeded_At__c = now;
            t.Last_Error_Code__c = null;
            clearInFlight(t);
            t.Next_Retry_At__c = null;
            return new ApplyResult(true, null);
        }

        if (o.disposition == AttorneyApiService.Disposition.PERMANENT_FAILURE) {
            t.Status__c = FAILED;
            t.Last_Error_Code__c = o.errorCode;
            clearInFlight(t);
            t.Next_Retry_At__c = null;
            return new ApplyResult(true, null);
        }

        // TRANSIENT_FAILURE — schedule a retry only if the budget is not already spent.
        if (retryCount(t) < MAX_RETRIES) {
            t.Status__c = RETRY_SCHEDULED;
            t.Last_Error_Code__c = o.errorCode;
            t.Next_Retry_At__c = backoff(t, now);
            clearInFlight(t);
        } else {
            t.Status__c = FAILED;
            t.Last_Error_Code__c = RETRY_BUDGET_EXHAUSTED;
            clearInFlight(t);
            t.Next_Retry_At__c = null;
        }
        return new ApplyResult(true, null);
    }

    /**
     * Transition #7b — the unique External_Record_Key__c write collided (a DUPLICATE_VALUE the caller
     * caught at DML). Two transmissions claim the same target business record: a defect that needs a
     * human, never a retry. Move to Failed and DO NOT persist the conflicting external identifiers.
     *
     * PRECONDITION: this is an internal continuation of an already-AUTHORIZED success application —
     * it runs only on a row that applySendOutcome just took to #4 (returned applied=true) and whose
     * DML then collided. It carries no token check of its own because that authorization has already
     * happened; calling it on an unauthorized row is a caller bug. Last_Status_Code__c is left intact
     * so the successful HTTP status stays available for diagnostics.
     *
     * This is the one place a DUPLICATE_VALUE means the OPPOSITE of what it means on the claim/create
     * path: there it means "someone else won, resolve to their row" (normal); here it means "two rows
     * disagree about reality" (a defect). Same status code, opposite handling.
     */
    public static void applyExternalConflict(Integration_Transmission__c t) {
        t.Status__c = FAILED;
        t.Last_Error_Code__c = EXTERNAL_RECORD_CONFLICT;
        t.External_Record_Id__c = null;      // do NOT persist the conflicting identifiers
        t.External_Record_Key__c = null;
        t.External_Salesforce_Id__c = null;
        t.Succeeded_At__c = null;
        clearInFlight(t);
        t.Next_Retry_At__c = null;
    }

    /**
     * Transitions #8a / #8b — the recovery sweep found this row stranded in Processing past the stale
     * cutoff (a sender that died after claiming). Recover to Retry Scheduled if the budget is not spent
     * (#8a), else fail it (#8b). The budget check is what BOUNDS a repeatedly-dying sender: without it,
     * a row that goes stale on every attempt would be recovered forever.
     *
     * AUTHORIZATION. Writes ONLY when the row is still Processing AND still genuinely stale
     * (Processing_Started_At__c < staleCutoff) — the row `t` must be freshly locked (requeried FOR
     * UPDATE), because the sweep's earlier SELECT is a stale snapshot: a live sender may have completed
     * the row, or claimed it more recently, between that SELECT and this write. On refusal the row is
     * left UNTOUCHED and ApplyResult.reason is 'not-processing' or 'not-stale'. A refusal returns
     * ApplyResult rather than throwing.
     */
    public static ApplyResult applyStaleRecovery(Integration_Transmission__c t, Datetime staleCutoff) {
        if (t.Status__c != PROCESSING) {
            return new ApplyResult(false, 'not-processing');
        }
        if (t.Processing_Started_At__c == null || t.Processing_Started_At__c >= staleCutoff) {
            return new ApplyResult(false, 'not-stale');
        }
        if (retryCount(t) < MAX_RETRIES) {
            t.Status__c = RETRY_SCHEDULED;
            t.Last_Error_Code__c = STALE_CLAIM_RECOVERED;
            t.Next_Retry_At__c = Datetime.now(); // immediately eligible; the next claim applies #3
            clearInFlight(t);
        } else {
            t.Status__c = FAILED;
            t.Last_Error_Code__c = RETRY_BUDGET_EXHAUSTED;
            clearInFlight(t);
            t.Next_Retry_At__c = null;
        }
        return new ApplyResult(true, null);
    }

    /**
     * Defensive invariant repair — NOT a send attempt, and not a stale recovery. A due Retry Scheduled
     * row whose Retry_Count has reached MAX_RETRIES can never be claimed (claim() refuses it at the
     * ceiling), yet no send transition moves it to Failed — so without this it would sit Retry Scheduled
     * forever. The recovery sweep calls this on a freshly-locked row to close that gap.
     *
     * AUTHORIZATION: writes ONLY a row still Retry Scheduled AND at/over the retry ceiling; otherwise the
     * row is left UNTOUCHED and ApplyResult.reason is 'not-eligible'. It makes no callout and writes no
     * attempt log (the sweep never manufactures a send result that did not happen).
     */
    public static ApplyResult applyExhaustedRetryRepair(Integration_Transmission__c t) {
        if (t.Status__c != RETRY_SCHEDULED || retryCount(t) < MAX_RETRIES) {
            return new ApplyResult(false, 'not-eligible');
        }
        t.Status__c = FAILED;
        t.Last_Error_Code__c = RETRY_BUDGET_EXHAUSTED;
        t.Next_Retry_At__c = null;
        clearInFlight(t);
        return new ApplyResult(true, null);
    }

    // ---- helpers -----------------------------------------------------------

    // Clears the per-attempt in-flight markers. Last_Attempt_At__c is deliberately NOT cleared — it is
    // the durable record of when the last attempt began. Next_Retry_At__c is handled per transition
    // (set by #5/#8a, cleared by every terminal/success path).
    private static void clearInFlight(Integration_Transmission__c t) {
        t.Claim_Token__c = null;
        t.Processing_Started_At__c = null;
    }

    private static Datetime backoff(Integration_Transmission__c t, Datetime now) {
        Datetime base = t.Last_Attempt_At__c != null ? t.Last_Attempt_At__c : now;
        Integer minutes = BASE_BACKOFF_MINUTES * (Integer) Math.pow(2, retryCount(t));
        return base.addMinutes(Math.min(minutes, MAX_BACKOFF_MINUTES));
    }

    private static String keyFor(Id referralId) {
        return String.valueOf(referralId) + '|' + TARGET + '|' + OPERATION;
    }

    private static Integer retryCount(Integration_Transmission__c t) {
        return t.Retry_Count__c == null ? 0 : Integer.valueOf(t.Retry_Count__c);
    }

    /**
     * True only when EVERY error on the row is DUPLICATE_VALUE — i.e. the row failed solely because
     * it already exists, so ignoring it and resolving via requery is safe. A single non-duplicate
     * error makes the whole row a hard failure. (An INSERT colliding on the unique Transmission_Key__c
     * yields DUPLICATE_VALUE — verified against the org — not DUPLICATE_EXTERNAL_ID, which is an
     * upsert-by-external-id outcome this insert path never produces.)
     */
    private static Boolean allDuplicate(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return false; // a failed row with no reported error -> treat as a hard failure
        }
        for (Database.Error e : errors) {
            if (e.getStatusCode() != StatusCode.DUPLICATE_VALUE) {
                return false;
            }
        }
        return true;
    }

    @TestVisible
    private static String errorCodes(List<Database.Error> errors) {
        // Fails closed: the caller reaches here for a hard failure, so a null/empty error list must
        // still yield a controlled code, never an NPE or a blank diagnostic.
        if (errors == null || errors.isEmpty()) {
            return 'UNKNOWN';
        }
        List<String> codes = new List<String>();
        for (Database.Error e : errors) {
            codes.add(String.valueOf(e.getStatusCode()));
        }
        return String.join(codes, ',');
    }

    private static Boolean isUnableToLock(Exception e) {
        // No status-code API exists for a FOR UPDATE lock failure; message match is the only signal.
        return e.getMessage() != null && e.getMessage().contains('UNABLE_TO_LOCK_ROW');
    }

    public class TransmissionException extends Exception {}
}
