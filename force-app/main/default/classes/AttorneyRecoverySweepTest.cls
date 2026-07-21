@IsTest
private class AttorneyRecoverySweepTest {

    // Builds one transmission in a given state. The referral defaults Ready_For_Attorney__c = false, so
    // the ReferralTrigger is a no-op — the transmission here is created explicitly.
    private static Integration_Transmission__c make(
        String status, Integer retryCount, Datetime processingStarted, Datetime nextRetry, String target
    ) {
        Referral__c r = new Referral__c(Status__c = 'New');
        insert r;
        Integration_Transmission__c t = new Integration_Transmission__c(
            Referral__c = r.Id, Target_System__c = target, Operation__c = 'CREATE_REFERRAL',
            Transmission_Key__c = String.valueOf(r.Id) + '|' + target + '|CREATE_REFERRAL',
            Correlation_Id__c = Uuid.v4(), Status__c = status, Retry_Count__c = retryCount,
            Processing_Started_At__c = processingStarted, Next_Retry_At__c = nextRetry,
            Claim_Token__c = (status == 'Processing' ? 'cccccccc-dddd-4eee-8fff-999999999999' : null));
        insert t;
        return t;
    }

    private static Integration_Transmission__c reload(Id id) {
        return [
            SELECT Status__c, Last_Error_Code__c, Next_Retry_At__c, Claim_Token__c, Processing_Started_At__c
            FROM Integration_Transmission__c WHERE Id = :id
        ];
    }

    private static Datetime minutesAgo(Integer m) { return Datetime.now().addMinutes(-m); }

    // ---- stale Processing recovery -----------------------------------------

    @IsTest
    static void staleWithBudgetIsRecoveredToRetryScheduledAndEnqueued() {
        Integration_Transmission__c t = make('Processing', 1, minutesAgo(20), null, 'ATTORNEY');

        AttorneyRecoverySweep.run();

        Integration_Transmission__c after = reload(t.Id);
        System.assertEquals('Retry Scheduled', after.Status__c, 'stale + budget -> #8a');
        System.assertEquals('STALE_CLAIM_RECOVERED', after.Last_Error_Code__c);
        System.assertEquals(null, after.Claim_Token__c);
        System.assertEquals(1, Limits.getQueueableJobs(), 'the recovered row is dispatched via one root');
        System.assertEquals(0, [SELECT COUNT() FROM Integration_Log__c], 'the sweep writes NO attempt log');
    }

    @IsTest
    static void staleWithoutBudgetIsFailedAndNotEnqueued() {
        Integration_Transmission__c t = make('Processing', 3, minutesAgo(20), null, 'ATTORNEY');

        AttorneyRecoverySweep.run();

        Integration_Transmission__c after = reload(t.Id);
        System.assertEquals('Failed', after.Status__c, 'stale + budget spent -> #8b');
        System.assertEquals('RETRY_BUDGET_EXHAUSTED', after.Last_Error_Code__c);
        System.assertEquals(0, Limits.getQueueableJobs(), 'a terminal row is not enqueued');
    }

    @IsTest
    static void processingNotYetStaleIsLeftAlone() {
        Integration_Transmission__c t = make('Processing', 1, minutesAgo(5), null, 'ATTORNEY'); // < 15m cutoff

        AttorneyRecoverySweep.run();

        System.assertEquals('Processing', reload(t.Id).Status__c, 'a not-yet-stale row is untouched');
        System.assertEquals(0, Limits.getQueueableJobs());
    }

    // ---- #11 exhausted-retry repair ----------------------------------------

    @IsTest
    static void dueRetryScheduledAtCeilingIsRepairedAndNotEnqueued() {
        Integration_Transmission__c t = make('Retry Scheduled', 3, null, minutesAgo(1), 'ATTORNEY');

        AttorneyRecoverySweep.run();

        Integration_Transmission__c after = reload(t.Id);
        System.assertEquals('Failed', after.Status__c, 'due at the ceiling -> #11 repair');
        System.assertEquals('RETRY_BUDGET_EXHAUSTED', after.Last_Error_Code__c);
        System.assertEquals(null, after.Next_Retry_At__c);
        System.assertEquals(0, Limits.getQueueableJobs(), 'a repaired terminal row is not enqueued');
    }

    // The re-lock bound keeps SOQL safe: with more at-ceiling rows than the per-sweep cap, only the cap
    // is repaired and the overflow waits for the next sweep.
    @IsTest
    static void ceilingRepairsAreBoundedPerSweep() {
        Integer n = 41; // one more than MAX_CEILING_REPAIRS_PER_SWEEP (40)
        List<Referral__c> refs = new List<Referral__c>();
        for (Integer i = 0; i < n; i++) {
            refs.add(new Referral__c(Status__c = 'New'));
        }
        insert refs;
        List<Integration_Transmission__c> ts = new List<Integration_Transmission__c>();
        for (Referral__c r : refs) {
            ts.add(new Integration_Transmission__c(
                Referral__c = r.Id, Target_System__c = 'ATTORNEY', Operation__c = 'CREATE_REFERRAL',
                Transmission_Key__c = String.valueOf(r.Id) + '|ATTORNEY|CREATE_REFERRAL',
                Correlation_Id__c = Uuid.v4(), Status__c = 'Retry Scheduled', Retry_Count__c = 3,
                Next_Retry_At__c = minutesAgo(1))); // due, at the ceiling
        }
        insert ts;

        AttorneyRecoverySweep.run();

        System.assertEquals(40, [SELECT COUNT() FROM Integration_Transmission__c WHERE Status__c = 'Failed'],
            'ceiling repairs are bounded to MAX_CEILING_REPAIRS_PER_SWEEP per sweep');
        System.assertEquals(1, [SELECT COUNT() FROM Integration_Transmission__c WHERE Status__c = 'Retry Scheduled'],
            'the overflow row waits for the next sweep');
        System.assertEquals(0, Limits.getQueueableJobs(), 'ceiling rows are not dispatched');
    }

    // ---- dispatchable work --------------------------------------------------

    @IsTest
    static void pendingAndDueBelowCeilingAreEnqueuedUntouched() {
        Integration_Transmission__c pending = make('Pending', 0, null, null, 'ATTORNEY');
        Integration_Transmission__c dueRetry = make('Retry Scheduled', 1, null, minutesAgo(1), 'ATTORNEY');

        AttorneyRecoverySweep.run();

        // The sweep only DISPATCHES these — the dispatcher's claim (not run here) does the state change.
        System.assertEquals('Pending', reload(pending.Id).Status__c);
        System.assertEquals('Retry Scheduled', reload(dueRetry.Id).Status__c);
        System.assertEquals(1, Limits.getQueueableJobs(), 'both dispatchable rows go into one root');
    }

    // ---- route scope --------------------------------------------------------

    @IsTest
    static void providerRowsAreIgnored() {
        Integration_Transmission__c provider = make('Pending', 0, null, null, 'PROVIDER');
        Integration_Transmission__c staleProvider = make('Processing', 1, minutesAgo(20), null, 'PROVIDER');

        AttorneyRecoverySweep.run();

        System.assertEquals('Pending', reload(provider.Id).Status__c, 'Provider Pending untouched');
        System.assertEquals('Processing', reload(staleProvider.Id).Status__c, 'Provider stale untouched');
        System.assertEquals(0, Limits.getQueueableJobs(), 'no Attorney candidates -> no root');
    }

    // ---- schedulable wiring -------------------------------------------------

    @IsTest
    static void isSchedulableAndExecuteRuns() {
        make('Pending', 0, null, null, 'ATTORNEY');

        Test.startTest();
        Id jobId = System.schedule('AttorneyRecoverySweep test', '0 0 1 * * ?', new AttorneyRecoverySweep());
        Test.stopTest(); // fires execute() -> run()

        System.assertNotEquals(null, jobId);
        System.assertEquals(1, [SELECT COUNT() FROM CronTrigger WHERE Id = :jobId], 'the sweep is schedulable');
    }
}
