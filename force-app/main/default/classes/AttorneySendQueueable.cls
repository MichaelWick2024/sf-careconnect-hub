/**
 * The sender half of the serial send chain. For a claimed group (transmissionId → the claim token the
 * dispatcher won), it makes EVERY callout first, then persists — the platform forbids a callout after
 * DML, and batching means we cannot call → save → call again.
 *
 * Sequence (one transaction):
 *   1. SOQL: reload the claimed rows with their Referral/Contact fields (to build requests).
 *   2. Callouts: build each request via AttorneyReferralRequestMapper and call AttorneyApiService.
 *      Up to MAX_CLAIM_BATCH callouts, bounded by the 120 s cumulative callout budget (3 * 30 s).
 *   3. SOQL FOR UPDATE: re-lock the rows — this is the AUTHORITATIVE state check. A callout can run up
 *      to the timeout, and during it the sweep may have re-claimed a row with a new token.
 *   4. DML: applySendOutcome(row, outcome, expectedToken) writes ONLY authorized rows (the token gate
 *      lives in the service). A #4 success may collide on the unique External_Record_Key__c → reclassify
 *      that row as #7b. Then write exactly one Integration_Log__c per attempt.
 *   5. Enqueue one next dispatcher for the leftover candidates, if any.
 *
 * At-least-once delivery: a refused (stale) row was still delivered to Attorney; its request is not
 * un-sent. Attorney's idempotency (keyed on the Care Connect referral id) absorbs the duplicate. The
 * token gate only protects LOCAL state from a stale overwrite.
 */
public with sharing class AttorneySendQueueable implements Queueable, Database.AllowsCallouts {

    private final Map<Id, String> claimTokenById;
    private final List<Id> leftover;

    public AttorneySendQueueable(Map<Id, String> claimTokenById, List<Id> leftover) {
        this.claimTokenById = claimTokenById == null ? new Map<Id, String>() : claimTokenById;
        this.leftover = leftover == null ? new List<Id>() : leftover;
    }

    public void execute(QueueableContext ctx) {
        Set<Id> ids = claimTokenById.keySet();

        if (!ids.isEmpty()) {
            // 1. Reload with the fields the mapper needs (before any callout).
            Map<Id, Integration_Transmission__c> forRequest = new Map<Id, Integration_Transmission__c>([
                SELECT Id, Correlation_Id__c, Referral__c, Retry_Count__c,
                       Referral__r.Referral_Type__c, Referral__r.Contact__c,
                       Referral__r.Contact__r.Id, Referral__r.Contact__r.Name, Referral__r.Contact__r.Email,
                       Referral__r.Contact__r.Phone, Referral__r.Contact__r.Birthdate
                FROM Integration_Transmission__c WHERE Id IN :ids
            ]);

            // 2. ALL callouts first, holding each outcome.
            Map<Id, AttorneyApiService.CalloutOutcome> outcomeById =
                new Map<Id, AttorneyApiService.CalloutOutcome>();
            for (Id id : ids) {
                Integration_Transmission__c t = forRequest.get(id);
                if (t == null) {
                    continue;
                }
                AttorneyReferralRequest request = AttorneyReferralRequestMapper.fromTransmission(t);
                outcomeById.put(id, AttorneyApiService.sendReferral(request));
            }

            // 3. Re-lock — the authoritative post-callout state, and the row we actually persist.
            Map<Id, Integration_Transmission__c> locked = new Map<Id, Integration_Transmission__c>([
                SELECT Id, Status__c, Claim_Token__c, Retry_Count__c, Last_Attempt_At__c
                FROM Integration_Transmission__c WHERE Id IN :ids
                FOR UPDATE
            ]);

            // 4. Apply outcomes (token-gated) and build one log per attempt.
            List<Integration_Transmission__c> toUpdate = new List<Integration_Transmission__c>();
            List<Integration_Log__c> logs = new List<Integration_Log__c>();
            for (Id id : ids) {
                AttorneyApiService.CalloutOutcome o = outcomeById.get(id);
                Integration_Transmission__c row = locked.get(id);
                if (o == null || row == null) {
                    continue;
                }
                AttorneyTransmissionService.ApplyResult ar =
                    AttorneyTransmissionService.applySendOutcome(row, o, claimTokenById.get(id));
                if (ar.applied) {
                    toUpdate.add(row);
                }
                // Log the attempt regardless of authorization: the callout WAS made. Stable identity
                // (correlation id, referral, retry count) comes from the request-time row.
                logs.add(buildLog(forRequest.get(id), o));
            }

            persistWithConflictHandling(toUpdate);
            if (!logs.isEmpty()) {
                insert logs;
            }
        }

        // 5. Keep the chain draining. Chaining a Queueable throws in test context (platform guard), so
        // the enqueue is skipped there; tests drive execute() directly.
        if (!leftover.isEmpty() && !Test.isRunningTest()) {
            System.enqueueJob(new AttorneyDispatchQueueable(leftover));
        }
    }

    // Persists the authorized rows. Only transition #4 (Succeeded) writes a unique field
    // (External_Record_Key__c) — #5/#6/#7 touch nothing unique — so a DUPLICATE_VALUE on a Succeeded
    // row is UNAMBIGUOUSLY the #7b external-record collision. That row-status signal is used instead of
    // parsing the error: getFields() is empty for a unique-index violation and the message text is
    // context-dependent (verified in-org). Reclassify #7b rows to Failed without their conflicting
    // identifiers and persist again; any other failure is unexpected and surfaces loudly.
    private static void persistWithConflictHandling(List<Integration_Transmission__c> rows) {
        if (rows.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.update(rows, false);
        List<Integration_Transmission__c> conflicts = new List<Integration_Transmission__c>();
        List<String> hardFailures = new List<String>();
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                continue;
            }
            if (rows[i].Status__c == 'Succeeded' && anyDuplicateValue(results[i].getErrors())) {
                AttorneyTransmissionService.applyExternalConflict(rows[i]); // #7b
                conflicts.add(rows[i]);
            } else {
                hardFailures.add(String.valueOf(rows[i].Id) + ' -> ' + errorCodes(results[i].getErrors()));
            }
        }
        if (!conflicts.isEmpty()) {
            update conflicts; // keys cleared, Failed — cannot collide again
        }
        if (!hardFailures.isEmpty()) {
            throw new SendException('Unexpected transmission update failure: ' + String.join(hardFailures, '; '));
        }
    }

    private static Boolean anyDuplicateValue(List<Database.Error> errors) {
        if (errors == null) {
            return false;
        }
        for (Database.Error e : errors) {
            if (e.getStatusCode() == StatusCode.DUPLICATE_VALUE) {
                return true;
            }
        }
        return false;
    }

    private static String errorCodes(List<Database.Error> errors) {
        if (errors == null || errors.isEmpty()) {
            return 'UNKNOWN';
        }
        List<String> codes = new List<String>();
        for (Database.Error e : errors) {
            codes.add(String.valueOf(e.getStatusCode()));
        }
        return String.join(codes, ',');
    }

    // One attempt log, from the already value-safe CalloutOutcome. sanitizedRequest/sanitizedResponse
    // are the outcome's allowlisted payloads (no PII, no raw body); Error_Message holds only the
    // controlled error code, never a remote or platform message.
    private static Integration_Log__c buildLog(Integration_Transmission__c t, AttorneyApiService.CalloutOutcome o) {
        return new Integration_Log__c(
            Direction__c = 'Outbound',
            External_System__c = 'Attorney',
            Operation__c = 'CREATE_REFERRAL',
            Http_Method__c = 'POST',
            Endpoint__c = AttorneyApiService.ENDPOINT,
            Correlation_Id__c = t == null ? null : t.Correlation_Id__c,
            Referral__c = t == null ? null : t.Referral__c,
            Retry_Count__c = t == null ? null : t.Retry_Count__c,
            Status_Code__c = o.statusCode,
            Success__c = (o.disposition == AttorneyApiService.Disposition.SUCCESS),
            Execution_Time_Ms__c = o.executionTimeMs,
            Sanitized_Request_JSON__c = o.sanitizedRequest,
            Sanitized_Response_JSON__c = o.sanitizedResponse,
            Error_Message__c = o.errorCode, // controlled vocabulary only; null on success
            Timestamp__c = Datetime.now()
        );
    }

    public class SendException extends Exception {}
}
