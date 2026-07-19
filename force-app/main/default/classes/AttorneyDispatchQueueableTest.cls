@IsTest
private class AttorneyDispatchQueueableTest {

    // n Pending transmissions; returns their ids. The dispatcher makes no callouts, so ordinary DML
    // setup in the test method is fine (no callout-after-DML concern).
    private static List<Id> pendingTransmissionIds(Integer n) {
        List<Referral__c> refs = new List<Referral__c>();
        for (Integer i = 0; i < n; i++) {
            refs.add(new Referral__c(Status__c = 'New'));
        }
        insert refs;
        List<Id> ids = new List<Id>();
        for (Integration_Transmission__c t :
                AttorneyTransmissionService.createReferralTransmissions(new Map<Id, SObject>(refs).keySet())) {
            ids.add(t.Id);
        }
        return ids;
    }

    private static Integer countByStatus(String status) {
        return [SELECT COUNT() FROM Integration_Transmission__c WHERE Status__c = :status];
    }

    @IsTest
    static void claimsUpToBatchAndLeavesTheRest() {
        List<Id> ids = pendingTransmissionIds(5);

        Test.startTest();
        new AttorneyDispatchQueueable(ids).execute(null);
        Test.stopTest();

        System.assertEquals(3, countByStatus('Processing'), 'claims exactly MAX_CLAIM_BATCH');
        System.assertEquals(2, countByStatus('Pending'), 'the leftover is not claimed by this dispatcher');
    }

    @IsTest
    static void claimsAllWhenUnderBatch() {
        List<Id> ids = pendingTransmissionIds(2);

        Test.startTest();
        new AttorneyDispatchQueueable(ids).execute(null);
        Test.stopTest();

        System.assertEquals(2, countByStatus('Processing'));
        System.assertEquals(0, countByStatus('Pending'));
    }

    @IsTest
    static void skipsNonClaimableCandidates() {
        List<Id> ids = pendingTransmissionIds(2);
        Integration_Transmission__c done = [SELECT Id, Status__c FROM Integration_Transmission__c WHERE Id = :ids[0]];
        done.Status__c = 'Succeeded';
        update done;

        Test.startTest();
        new AttorneyDispatchQueueable(ids).execute(null);
        Test.stopTest();

        System.assertEquals(1, countByStatus('Processing'), 'only the claimable candidate is claimed');
        System.assertEquals(1, countByStatus('Succeeded'), 'the terminal candidate is left alone');
    }

    // The batch claims nothing (all non-claimable) but candidates remain — the dispatcher must still
    // keep the chain alive by carrying the leftover onward (rather than enqueuing a sender with no work).
    @IsTest
    static void carriesLeftoverWhenBatchClaimsNothing() {
        List<Id> ids = pendingTransmissionIds(4);
        // Make the FIRST three (the batch) non-claimable; the 4th stays Pending as leftover.
        List<Integration_Transmission__c> firstThree = new List<Integration_Transmission__c>();
        for (Integer i = 0; i < 3; i++) {
            firstThree.add(new Integration_Transmission__c(Id = ids[i], Status__c = 'Succeeded'));
        }
        update firstThree;

        Test.startTest();
        new AttorneyDispatchQueueable(ids).execute(null);
        Test.stopTest();

        System.assertEquals(0, countByStatus('Processing'), 'nothing in the batch was claimable');
        System.assertEquals(3, countByStatus('Succeeded'));
        System.assertEquals(1, countByStatus('Pending'), 'the leftover candidate is carried, not claimed here');
    }

    @IsTest
    static void emptyCandidatesIsNoOp() {
        new AttorneyDispatchQueueable(new List<Id>()).execute(null);
        System.assertEquals(0, countByStatus('Processing'));
    }

    @IsTest
    static void nullCandidatesIsNoOp() {
        new AttorneyDispatchQueueable(null).execute(null);
        System.assertEquals(0, [SELECT COUNT() FROM Integration_Transmission__c]);
    }
}
