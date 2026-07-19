/**
 * Transitions #1–#3 of the outbound state machine, in one focused layer:
 *
 *   #1  create-or-get  — a referral becomes eligible → a Pending Integration_Transmission__c
 *   #2  claim Pending           → Processing  (attempt 1; Retry_Count unchanged)
 *   #3  claim due Retry Scheduled → Processing  (a retry; Retry_Count++)
 *
 * It does NOT make the callout or apply the result transitions (#4–#8) — the send Queueable does.
 *
 * Inbound ADRs walked and applied here (they were earned once already and must not be re-lost):
 *   - Creation is idempotent via the unique Transmission_Key__c and uses partial-success DML
 *     (Database.insert(..., false)); a concurrent duplicate is resolved by the requery, and any
 *     non-duplicate failure surfaces loudly (ADR-010).
 *   - The claim locks rows with FOR UPDATE; UNABLE_TO_LOCK_ROW means "someone else is claiming" —
 *     a NORMAL outcome, not an error — and returns `locked`, never a thrown failure.
 *   - Correlation_Id__c is a v4 UUID generated ONCE at creation and reused across every attempt;
 *     Claim_Token__c is a NEW v4 UUID per attempt.
 *
 * Attorney-specific creation (Target/Operation constants); the claim is target-agnostic. Provider
 * gets its own creation entry point later; the claim can be shared then.
 */
public with sharing class AttorneyTransmissionService {

    @TestVisible private static final String TARGET = 'ATTORNEY';
    @TestVisible private static final String OPERATION = 'CREATE_REFERRAL';
    public static final Integer MAX_RETRIES = 3;

    // Status API values (restricted picklist).
    private static final String PENDING = 'Pending';
    private static final String PROCESSING = 'Processing';
    private static final String RETRY_SCHEDULED = 'Retry Scheduled';

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
        Datetime now = Datetime.now();

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

        Integration_Transmission__c t = locked[0];
        if (!isClaimable(t, now)) {
            return new ClaimResult(t.Id, false, null, 'not-eligible');
        }

        Boolean fromRetry = (t.Status__c == RETRY_SCHEDULED); // capture BEFORE mutating Status
        String token = Uuid.v4();                             // new per attempt
        t.Status__c = PROCESSING;
        t.Claim_Token__c = token;
        t.Processing_Started_At__c = now;
        t.Last_Attempt_At__c = now;
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

    // ---- helpers -----------------------------------------------------------

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

    private static String errorCodes(List<Database.Error> errors) {
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
