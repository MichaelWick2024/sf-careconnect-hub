/**
 * The scheduled safety net for the Attorney outbound chain. It is NOT a chained Queueable — it runs
 * hourly (a Scheduled Apex job runs at most once per hour, which is what the 60/120/240 backoff is sized
 * to) and does the two things the chain cannot do for itself: it reclaims transmissions stranded in
 * Processing (a sender that died), and it re-dispatches Pending and due Retry Scheduled work.
 *
 * `without sharing`: a system recovery job must see every stale/pending transmission regardless of
 * record-level sharing.
 *
 * It performs NO callout and NO send, so it writes NO Integration_Log__c attempt row — a stale row cannot
 * prove whether its earlier request left Salesforce, so the sweep only changes transmission STATE.
 *
 * Discipline carried from the send chain: Attorney-scoped queries (never touches Provider rows); SINGULAR
 * `FOR UPDATE` re-lock before applying a recovery transition (the finding query is only a snapshot);
 * partial DML with every SaveResult inspected and never a throw-rollback. SOQL is bounded well under 100
 * per run (one query per finder plus one re-lock per recovered/repaired row) so it is safe regardless of
 * the scheduled context's exact limit; far larger volumes would move to Batch Apex.
 */
public without sharing class AttorneyRecoverySweep implements Schedulable {

    @TestVisible private static final Integer STALE_AFTER_MINUTES = 15;
    // Re-lock caps — one SOQL each — keep total queries well under the synchronous SOQL ceiling.
    @TestVisible private static final Integer MAX_STALE_RECOVERIES_PER_SWEEP = 50;
    @TestVisible private static final Integer MAX_CEILING_REPAIRS_PER_SWEEP = 40;

    private static final String TARGET = AttorneyTransmissionService.TARGET;       // 'ATTORNEY'
    private static final String OPERATION = AttorneyTransmissionService.OPERATION; // 'CREATE_REFERRAL'
    private static final String PROCESSING = 'Processing';
    private static final String PENDING = 'Pending';
    private static final String RETRY_SCHEDULED = 'Retry Scheduled';

    public void execute(SchedulableContext ctx) {
        run();
    }

    @TestVisible
    private static void run() {
        Datetime sweepTime = Datetime.now();
        Datetime staleCutoff = sweepTime.addMinutes(-STALE_AFTER_MINUTES);

        List<Id> rootCandidates = new List<Id>();
        recoverStaleProcessing(staleCutoff, rootCandidates);          // #8a / #8b
        collectDispatchableAndRepairCeiling(sweepTime, rootCandidates); // dispatch, or #11 repair

        // One root for everything that should be dispatched (enqueueRoot dedups + caps + sets the depth).
        AttorneyDispatchQueueable.enqueueRoot(rootCandidates);
    }

    // Stale Processing rows: re-lock singularly, applyStaleRecovery (#8a Retry Scheduled / #8b Failed).
    // A committed #8a row becomes immediately-due Retry Scheduled -> a dispatch candidate; #8b is terminal.
    private static void recoverStaleProcessing(Datetime staleCutoff, List<Id> rootCandidates) {
        List<Integration_Transmission__c> stale = [
            SELECT Id FROM Integration_Transmission__c
            WHERE Target_System__c = :TARGET AND Operation__c = :OPERATION
              AND Status__c = :PROCESSING AND Processing_Started_At__c < :staleCutoff
            LIMIT :MAX_STALE_RECOVERIES_PER_SWEEP
        ];
        List<Integration_Transmission__c> toUpdate = new List<Integration_Transmission__c>();
        for (Integration_Transmission__c snap : stale) {
            Integration_Transmission__c row = lockOne(snap.Id);
            if (row == null) {
                continue; // contested or vanished — leave for the next sweep
            }
            if (AttorneyTransmissionService.applyStaleRecovery(row, staleCutoff).applied) {
                toUpdate.add(row);
            }
        }
        if (toUpdate.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.update(toUpdate, false); // partial, inspected, no throw
        for (Integer i = 0; i < results.size(); i++) {
            if (results[i].isSuccess()) {
                if (toUpdate[i].Status__c == RETRY_SCHEDULED) {
                    rootCandidates.add(toUpdate[i].Id); // #8a -> claimable now
                }
            } else {
                System.debug(LoggingLevel.ERROR,
                    'Stale recovery update failed: ' + dmlCodes(results[i].getErrors())); // safe codes only
            }
        }
    }

    // Pending + due Retry Scheduled: a below-ceiling row is a dispatch candidate (the dispatcher's claim
    // handles it); an at-ceiling due Retry Scheduled row is repaired to Failed (#11), re-locked first, and
    // NOT dispatched. Ceiling repairs are bounded (they are a rare, defensive condition).
    private static void collectDispatchableAndRepairCeiling(Datetime sweepTime, List<Id> rootCandidates) {
        List<Integration_Transmission__c> candidates = [
            SELECT Id, Status__c, Retry_Count__c FROM Integration_Transmission__c
            WHERE Target_System__c = :TARGET AND Operation__c = :OPERATION
              AND ( Status__c = :PENDING
                 OR (Status__c = :RETRY_SCHEDULED AND Next_Retry_At__c <= :sweepTime) )
            LIMIT :AttorneyDispatchQueueable.MAX_ROOT_CANDIDATES
        ];
        List<Integration_Transmission__c> ceilingRepairs = new List<Integration_Transmission__c>();
        Integer ceilingLocks = 0;
        for (Integration_Transmission__c snap : candidates) {
            Boolean atCeiling = snap.Status__c == RETRY_SCHEDULED
                && snap.Retry_Count__c != null
                && snap.Retry_Count__c >= AttorneyTransmissionService.MAX_RETRIES;
            if (!atCeiling) {
                rootCandidates.add(snap.Id); // Pending or below-ceiling due Retry Scheduled -> dispatch
                continue;
            }
            if (ceilingLocks >= MAX_CEILING_REPAIRS_PER_SWEEP) {
                continue; // bound the re-locks; remaining at-ceiling rows repair on the next sweep
            }
            ceilingLocks++;
            Integration_Transmission__c row = lockOne(snap.Id);
            if (row == null) {
                continue;
            }
            if (AttorneyTransmissionService.applyExhaustedRetryRepair(row, sweepTime).applied) {
                ceilingRepairs.add(row);
            }
        }
        if (ceilingRepairs.isEmpty()) {
            return;
        }
        List<Database.SaveResult> results = Database.update(ceilingRepairs, false);
        for (Integer i = 0; i < results.size(); i++) {
            if (!results[i].isSuccess()) {
                System.debug(LoggingLevel.ERROR,
                    'Ceiling repair update failed: ' + dmlCodes(results[i].getErrors()));
            }
        }
    }

    // Singular FOR UPDATE. Returns null (not throwing) for a contested row or one deleted after the
    // finding query — both confined to the one row, never aborting the sweep. Selects the fields the
    // recovery transitions read.
    private static Integration_Transmission__c lockOne(Id id) {
        List<Integration_Transmission__c> rows;
        try {
            rows = [
                SELECT Id, Status__c, Retry_Count__c, Next_Retry_At__c, Processing_Started_At__c
                FROM Integration_Transmission__c WHERE Id = :id
                FOR UPDATE
            ];
        } catch (System.QueryException qe) {
            if (isUnableToLock(qe)) {
                return null;
            }
            throw qe;
        }
        return rows.isEmpty() ? null : rows[0];
    }

    private static Boolean isUnableToLock(Exception e) {
        return e.getMessage() != null && e.getMessage().contains('UNABLE_TO_LOCK_ROW');
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
}
