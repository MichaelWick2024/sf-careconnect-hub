@IsTest
private class ReferralTriggerHandlerTest {

    private static Referral__c newReferral(Boolean ready) {
        return new Referral__c(Status__c = 'New', Ready_For_Attorney__c = ready);
    }

    private static Integer transmissionCount() {
        return [SELECT COUNT() FROM Integration_Transmission__c];
    }

    // ---- eligibility: create ------------------------------------------------

    @IsTest
    static void insertReadyCreatesOneAttorneyTransmissionAndEnqueuesOneRoot() {
        Referral__c r = newReferral(true);

        insert r; // fires the trigger

        System.assertEquals(1, transmissionCount(), 'a ready referral gets exactly one transmission');
        System.assertEquals(1, Limits.getQueueableJobs(), 'exactly one root dispatcher enqueued');

        Integration_Transmission__c t = [
            SELECT Referral__c, Target_System__c, Operation__c, Status__c
            FROM Integration_Transmission__c LIMIT 1
        ];
        System.assertEquals(r.Id, t.Referral__c);
        System.assertEquals('ATTORNEY', t.Target_System__c);
        System.assertEquals('CREATE_REFERRAL', t.Operation__c);
        System.assertEquals('Pending', t.Status__c);
    }

    @IsTest
    static void falseToTrueUpdateCreatesTransmission() {
        Referral__c r = newReferral(false);
        insert r; // not eligible
        System.assertEquals(0, transmissionCount(), 'an unready insert creates nothing');

        r.Ready_For_Attorney__c = true;
        update r; // false -> true: now eligible

        System.assertEquals(1, transmissionCount(), 'the false->true transition creates the transmission');
        System.assertEquals(1, Limits.getQueueableJobs(), 'one root enqueued on the transition');
    }

    @IsTest
    static void unreadyInsertCreatesNothing() {
        insert newReferral(false);

        System.assertEquals(0, transmissionCount());
        System.assertEquals(0, Limits.getQueueableJobs(), 'no root enqueued for an unready referral');
    }

    // ---- the key rule: re-checking is NOT a resubmission --------------------

    // An update to an ALREADY-ready referral must not restart submission. Proven by deleting the
    // transmission after the first submission, then updating the (still-ready) referral: if the update
    // were eligible, createReferralTransmissions would re-create the row — it must not.
    @IsTest
    static void updateToAlreadyReadyReferralDoesNotResubmit() {
        Referral__c r = newReferral(true);
        insert r; // eligible -> 1 transmission
        System.assertEquals(1, transmissionCount());

        delete [SELECT Id FROM Integration_Transmission__c]; // remove the evidence
        System.assertEquals(0, transmissionCount());

        r.Status__c = 'Sent to Attorney'; // an unrelated change; Ready stays true
        update r;

        System.assertEquals(0, transmissionCount(),
            'an update to an already-ready referral is NOT eligible and creates no transmission');
    }

    // ---- bulk safety --------------------------------------------------------

    @IsTest
    static void bulkInsertOfReadyReferralsIsSafe() {
        List<Referral__c> refs = new List<Referral__c>();
        for (Integer i = 0; i < 200; i++) {
            refs.add(newReferral(true));
        }

        Test.startTest();
        insert refs; // one firing, 200 qualifying
        System.assertEquals(200, transmissionCount(), 'every eligible referral gets a transmission in bulk');
        System.assertEquals(1, Limits.getQueueableJobs(), 'still exactly one root, no Queueable limit failure');
        Test.stopTest(); // runs the enqueued root (counter resets after this, so assert before)
    }

    // ---- the transaction-static guards only the ENQUEUE ---------------------

    // Even when a root has already been enqueued this transaction, a firing must still CREATE the
    // transmissions for its qualifying referrals (they wait Pending for the sweep) — the guard is not
    // allowed to suppress transmission creation.
    @IsTest
    static void eligibleReferralStillGetsTransmissionWhenGuardAlreadySet() {
        ReferralTriggerHandler.rootEnqueued = true; // simulate a root already enqueued this transaction

        insert newReferral(true);

        System.assertEquals(1, transmissionCount(), 'transmission is still created even with the guard set');
        System.assertEquals(0, Limits.getQueueableJobs(), 'but no second root is enqueued');
    }

    @IsTest
    static void twoFiringsInOneTransactionEnqueueAtMostOneRoot() {
        insert newReferral(true); // firing 1 -> transmission + one root, guard set
        insert newReferral(true); // firing 2 -> transmission created, but NO second root

        System.assertEquals(2, transmissionCount(), 'both firings create their transmissions');
        System.assertEquals(1, Limits.getQueueableJobs(), 'at most one root per transaction');
    }
}
