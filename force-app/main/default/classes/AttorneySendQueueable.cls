/**
 * The sender half of the serial send chain. For a claimed group (transmissionId → the claim token the
 * dispatcher won), it makes EVERY callout first, then persists — the platform forbids a callout after
 * DML, and batching means we cannot call → save → call again.
 *
 * Sequence (one transaction):
 *   1. Reload the claimed rows with their auth fields + Referral/Contact fields.
 *   2. PRE-callout authorization (optimization): skip rows already detectably stale (not Processing, or
 *      the token has already rotated) — no callout, no log, because no attempt is made.
 *   3. Callouts: build each request and call AttorneyApiService. Up to MAX_CLAIM_BATCH, bounded by the
 *      120 s cumulative callout budget (3 * 30 s).
 *   4. Per row, SINGULAR FOR UPDATE re-lock — the AUTHORITATIVE post-callout check, and singular so one
 *      contested row does not fail the others. applySendOutcome is token-gated (a token that rotated
 *      DURING the callout is refused). Persist with genuine partial success and reclassify a #4 success
 *      that collides on External_Record_Key__c as #7b — NEVER throwing, so one bad row cannot roll back
 *      the others' committed results.
 *   5. Write one attempt log per callout, BEST-EFFORT (Database.insert(..., false)) — a rejected log must
 *      never roll back the state machine — with the log's classification taken AFTER local persistence.
 *   6. Enqueue one next dispatcher for the leftover candidates.
 *
 * At-least-once delivery: a refused (stale) row was still delivered to Attorney; its request is not
 * un-sent. Attorney's idempotency (keyed on the Care Connect referral id) absorbs the duplicate. The
 * token gate only protects LOCAL state from a stale overwrite.
 */
public with sharing class AttorneySendQueueable implements Queueable, Database.AllowsCallouts {

    private static final String PROCESSING = 'Processing';
    private static final String SUCCEEDED = 'Succeeded';

    // Log-only dispositions (Error_Message__c). Controlled vocabulary; never a remote or platform message.
    private static final String STALE_CLAIM = 'STALE_CLAIM';
    private static final String LOCKED = 'LOCKED';
    private static final String HARD_DML_FAILURE = 'HARD_DML_FAILURE';
    private static final String EXTERNAL_RECORD_CONFLICT = 'EXTERNAL_RECORD_CONFLICT';

    private final Map<Id, String> claimTokenById;
    private final List<Id> leftover;

    public AttorneySendQueueable(Map<Id, String> claimTokenById, List<Id> leftover) {
        this.claimTokenById = claimTokenById == null ? new Map<Id, String>() : claimTokenById;
        this.leftover = leftover == null ? new List<Id>() : leftover;
    }

    public void execute(QueueableContext ctx) {
        List<Integration_Log__c> logs = new List<Integration_Log__c>();
        if (!claimTokenById.isEmpty()) {
            processClaimedGroup(logs);
        }
        writeLogsBestEffort(logs); // must never roll back the transmission state written above
        enqueueNextDispatcher();
    }

    private void processClaimedGroup(List<Integration_Log__c> logs) {
        Set<Id> ids = claimTokenById.keySet();

        // 1. Reload with the pre-callout auth fields (Status/Claim_Token) and the mapper's fields.
        Map<Id, Integration_Transmission__c> ctxById = new Map<Id, Integration_Transmission__c>([
            SELECT Id, Status__c, Claim_Token__c, Correlation_Id__c, Referral__c, Retry_Count__c,
                   Referral__r.Referral_Type__c, Referral__r.Contact__c,
                   Referral__r.Contact__r.Id, Referral__r.Contact__r.Name, Referral__r.Contact__r.Email,
                   Referral__r.Contact__r.Phone, Referral__r.Contact__r.Birthdate
            FROM Integration_Transmission__c WHERE Id IN :ids
        ]);

        // 2 + 3. Pre-callout authorization, then ALL callouts (before any DML). A row already stale at
        // reload gets no callout and no log — no attempt was made.
        Map<Id, AttorneyApiService.CalloutOutcome> outcomeById =
            new Map<Id, AttorneyApiService.CalloutOutcome>();
        for (Id id : ids) {
            Integration_Transmission__c t = ctxById.get(id);
            if (t == null) {
                continue;
            }
            String expected = claimTokenById.get(id);
            if (t.Status__c != PROCESSING || String.isBlank(expected) || !expected.equals(t.Claim_Token__c)) {
                continue; // detectably stale before sending — do not call out
            }
            outcomeById.put(id, AttorneyApiService.sendReferral(AttorneyReferralRequestMapper.fromTransmission(t)));
        }

        // 4. Per row: SINGULAR re-lock (authoritative, and isolated so one contested row spares the
        // others), token-gated apply. A refused or unlockable row keeps its log (the callout happened)
        // but no state change — stale recovery handles the still-Processing row.
        List<Integration_Transmission__c> toUpdate = new List<Integration_Transmission__c>();
        for (Id id : outcomeById.keySet()) {
            AttorneyApiService.CalloutOutcome o = outcomeById.get(id);
            Integration_Transmission__c row = lockOne(id);
            if (row == null) {
                logs.add(logRow(ctxById.get(id), o, false, LOCKED));
                continue;
            }
            AttorneyTransmissionService.ApplyResult ar =
                AttorneyTransmissionService.applySendOutcome(row, o, claimTokenById.get(id));
            if (!ar.applied) {
                logs.add(logRow(ctxById.get(id), o, false, STALE_CLAIM));
                continue;
            }
            toUpdate.add(row);
        }

        persistAndLog(toUpdate, outcomeById, ctxById, logs);
    }

    // Singular FOR UPDATE. Returns null (not throwing) when the row is contested — UNABLE_TO_LOCK_ROW is
    // a normal concurrency outcome confined to this one row.
    private static Integration_Transmission__c lockOne(Id id) {
        try {
            return [
                SELECT Id, Status__c, Claim_Token__c, Retry_Count__c, Last_Attempt_At__c
                FROM Integration_Transmission__c WHERE Id = :id
                FOR UPDATE
            ];
        } catch (System.QueryException qe) {
            if (isUnableToLock(qe)) {
                return null;
            }
            throw qe;
        }
    }

    // Persists the authorized rows with GENUINE partial success — no throw, no all-or-none DML — so a
    // failure on one row never rolls back the others' committed transitions or logs. Only transition #4
    // (Succeeded) writes a unique field (External_Record_Key__c), so a row that ends Succeeded and whose
    // errors are ALL DUPLICATE_VALUE is the #7b collision (row-status signal; getFields() is empty for a
    // unique index and the message text is context-dependent — both verified in-org). Any other failure
    // leaves the row Processing for the recovery sweep and logs only safe status-code diagnostics.
    private static void persistAndLog(
        List<Integration_Transmission__c> toUpdate,
        Map<Id, AttorneyApiService.CalloutOutcome> outcomeById,
        Map<Id, Integration_Transmission__c> ctxById,
        List<Integration_Log__c> logs
    ) {
        if (toUpdate.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.update(toUpdate, false);
        List<Integration_Transmission__c> conflicts = new List<Integration_Transmission__c>();
        for (Integer i = 0; i < results.size(); i++) {
            Integration_Transmission__c row = toUpdate[i];
            AttorneyApiService.CalloutOutcome o = outcomeById.get(row.Id);
            Integration_Transmission__c logCtx = ctxById.get(row.Id);
            if (results[i].isSuccess()) {
                // The applied row IS the classification: #4 -> success, null error; #5/#6/#7 -> the
                // applied Last_Error_Code. Status code stays the real HTTP status from the outcome.
                Boolean succeeded = (o.disposition == AttorneyApiService.Disposition.SUCCESS);
                logs.add(logRow(logCtx, o, succeeded, row.Last_Error_Code__c));
            } else if (row.Status__c == SUCCEEDED && allDuplicateValue(results[i].getErrors())) {
                AttorneyTransmissionService.applyExternalConflict(row); // #7b, persisted below
                conflicts.add(row);
            } else {
                // Unexpected hard failure — leave the row Processing for recovery; log safe codes only.
                logs.add(logRow(logCtx, o, false, HARD_DML_FAILURE + ':' + dmlCodes(results[i].getErrors())));
            }
        }
        if (!conflicts.isEmpty()) {
            Database.update(conflicts, false); // keys cleared -> cannot re-collide; still partial, no throw
            for (Integration_Transmission__c row : conflicts) {
                // Attorney returned 200, but the LOCAL result is a conflict: success=false, keep the
                // useful HTTP status, record the controlled conflict code.
                logs.add(logRow(ctxById.get(row.Id), outcomeById.get(row.Id), false, EXTERNAL_RECORD_CONFLICT));
            }
        }
    }

    private static void writeLogsBestEffort(List<Integration_Log__c> logs) {
        if (logs.isEmpty()) {
            return;
        }
        // Best-effort: a rejected attempt log must NEVER roll back committed transmission state (the
        // lesson the Attorney inbound logging service already encodes). Partial insert, never throw.
        Database.insert(logs, false);
    }

    private void enqueueNextDispatcher() {
        // Chaining a Queueable throws in test context (platform guard), so the enqueue is skipped there;
        // tests drive execute() directly.
        if (!leftover.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new AttorneyDispatchQueueable(leftover));
        }
    }

    // One attempt log, from the already value-safe CalloutOutcome. sanitizedRequest/sanitizedResponse
    // are the outcome's allowlisted payloads (no PII, no raw body); errorCode is a controlled token.
    private static Integration_Log__c logRow(
        Integration_Transmission__c ctx, AttorneyApiService.CalloutOutcome o, Boolean success, String errorCode
    ) {
        return new Integration_Log__c(
            Direction__c = 'Outbound',
            External_System__c = 'Attorney',
            Operation__c = 'CREATE_REFERRAL',
            Http_Method__c = 'POST',
            Endpoint__c = AttorneyApiService.ENDPOINT,
            Correlation_Id__c = ctx == null ? null : ctx.Correlation_Id__c,
            Referral__c = ctx == null ? null : ctx.Referral__c,
            Retry_Count__c = ctx == null ? null : ctx.Retry_Count__c,
            Status_Code__c = o.statusCode,
            Success__c = success,
            Execution_Time_Ms__c = o.executionTimeMs,
            Sanitized_Request_JSON__c = o.sanitizedRequest,
            Sanitized_Response_JSON__c = o.sanitizedResponse,
            Error_Message__c = errorCode, // controlled vocabulary only; null on success
            Timestamp__c = Datetime.now()
        );
    }

    // True only when EVERY error is DUPLICATE_VALUE — a mix with a hard error is NOT a clean #7b and must
    // not swallow the hard error (the same rule the create path uses).
    private static Boolean allDuplicateValue(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return false;
        }
        for (Database.Error e : errors) {
            if (e.getStatusCode() != StatusCode.DUPLICATE_VALUE) {
                return false;
            }
        }
        return true;
    }

    private static String dmlCodes(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return 'UNKNOWN';
        }
        List<String> codes = new List<String>();
        for (Database.Error e : errors) {
            codes.add(String.valueOf(e.getStatusCode())); // enum name only — safe, no PII
        }
        return String.join(codes, ',');
    }

    private static Boolean isUnableToLock(Exception e) {
        return e.getMessage() != null && e.getMessage().contains('UNABLE_TO_LOCK_ROW');
    }
}
