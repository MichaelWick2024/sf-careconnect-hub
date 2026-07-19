@IsTest
private class AttorneyTransmissionServiceTest {

    private static final Pattern UUID_V4 = Pattern.compile(
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
    );

    private static List<Referral__c> insertReferrals(Integer n) {
        List<Referral__c> refs = new List<Referral__c>();
        for (Integer i = 0; i < n; i++) {
            refs.add(new Referral__c(Status__c = 'New'));
        }
        insert refs;
        return refs;
    }

    private static Set<Id> ids(List<SObject> records) {
        return new Map<Id, SObject>(records).keySet();
    }

    // ---- metadata contract (drift guard) -----------------------------------

    private static Set<String> activeValues(Schema.DescribeFieldResult field) {
        Set<String> values = new Set<String>();
        for (Schema.PicklistEntry e : field.getPicklistValues()) {
            if (e.isActive()) {
                values.add(e.getValue());
            }
        }
        return values;
    }

    /**
     * The service depends on exact picklist API values (Target/Operation/Status). A metadata change
     * must fail HERE with a focused diagnostic, not surface as an unrelated create/claim failure — a
     * label rename stays harmless, but removing/renaming an API value breaks the build.
     *
     * Target/Operation use CONTAINMENT so future additive values (e.g. Provider operations) don't
     * break it. Status uses EXACT equality: an added state expands the state machine and must be
     * deliberate code + specification work, not a silent metadata edit.
     */
    @IsTest
    static void picklistApiNamesTheServiceDependsOnStillExist() {
        Set<String> targets = activeValues(Schema.SObjectType.Integration_Transmission__c.fields.Target_System__c);
        System.assert(targets.containsAll(new Set<String>{ 'ATTORNEY', 'PROVIDER' }),
            'Target_System__c must retain ATTORNEY and PROVIDER; found ' + targets);
        System.assert(targets.contains(AttorneyTransmissionService.TARGET),
            'the service TARGET must be a valid Target_System__c API value');

        Set<String> operations = activeValues(Schema.SObjectType.Integration_Transmission__c.fields.Operation__c);
        System.assert(operations.contains(AttorneyTransmissionService.OPERATION),
            'the service OPERATION must be a valid Operation__c API value; found ' + operations);

        Set<String> statuses = activeValues(Schema.SObjectType.Integration_Transmission__c.fields.Status__c);
        System.assertEquals(
            new Set<String>{ 'Pending', 'Processing', 'Retry Scheduled', 'Succeeded', 'Failed' },
            statuses,
            'Status__c API values must match the state machine exactly — an added state needs deliberate '
            + 'code + specification work, not a silent metadata edit');
    }

    // ---- #1 create-or-get --------------------------------------------------

    @IsTest
    static void createsOnePendingTransmissionPerReferral() {
        List<Referral__c> refs = insertReferrals(3);

        Test.startTest();
        List<Integration_Transmission__c> created = AttorneyTransmissionService.createReferralTransmissions(ids(refs));
        Test.stopTest();

        System.assertEquals(3, created.size());
        System.assertEquals(3, [SELECT COUNT() FROM Integration_Transmission__c]);
        for (Integration_Transmission__c t : [
            SELECT Status__c, Retry_Count__c, Correlation_Id__c, Transmission_Key__c, Target_System__c,
                   Operation__c, Referral__c
            FROM Integration_Transmission__c
        ]) {
            System.assertEquals('Pending', t.Status__c);
            System.assertEquals(0, t.Retry_Count__c);
            System.assertEquals('ATTORNEY', t.Target_System__c);
            System.assertEquals('CREATE_REFERRAL', t.Operation__c);
            System.assert(UUID_V4.matcher(t.Correlation_Id__c).matches(), 'correlation id must be v4: ' + t.Correlation_Id__c);
            System.assertEquals(String.valueOf(t.Referral__c) + '|ATTORNEY|CREATE_REFERRAL', t.Transmission_Key__c);
        }
    }

    @IsTest
    static void creationIsIdempotentAndKeepsCorrelationId() {
        List<Referral__c> refs = insertReferrals(2);
        List<Integration_Transmission__c> first = AttorneyTransmissionService.createReferralTransmissions(ids(refs));
        Map<Id, String> correlationByTransmission = new Map<Id, String>();
        for (Integration_Transmission__c t : first) { correlationByTransmission.put(t.Id, t.Correlation_Id__c); }

        Test.startTest();
        List<Integration_Transmission__c> second = AttorneyTransmissionService.createReferralTransmissions(ids(refs));
        Test.stopTest();

        System.assertEquals(2, [SELECT COUNT() FROM Integration_Transmission__c], 'no duplicates on re-run');
        for (Integration_Transmission__c t : second) {
            System.assertEquals(correlationByTransmission.get(t.Id), t.Correlation_Id__c, 'correlation id is stable');
        }
    }

    @IsTest
    static void concurrentDuplicateIsIgnoredAndExistingKept() {
        Referral__c r = insertReferrals(1)[0];
        String key = String.valueOf(r.Id) + '|ATTORNEY|CREATE_REFERRAL';
        insert new Integration_Transmission__c(Referral__c = r.Id, Target_System__c = 'ATTORNEY',
            Operation__c = 'CREATE_REFERRAL', Transmission_Key__c = key,
            Correlation_Id__c = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', Status__c = 'Pending', Retry_Count__c = 0);

        Test.startTest();
        List<Integration_Transmission__c> result =
            AttorneyTransmissionService.createReferralTransmissions(new Set<Id>{ r.Id });
        Test.stopTest();

        System.assertEquals(1, [SELECT COUNT() FROM Integration_Transmission__c], 'no duplicate created');
        System.assertEquals(1, result.size());
        System.assertEquals('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', result[0].Correlation_Id__c,
            'the existing row and its correlation id are kept');
    }

    /**
     * A genuine NON-duplicate DML failure must surface as a controlled TransmissionException, never
     * be mistaken for an idempotent duplicate. An Account Id in the Referral__c lookup yields
     * FIELD_INTEGRITY_EXCEPTION (verified against the org) via partial-success SaveResults.
     */
    @IsTest
    static void nonDuplicateFailureThrows() {
        Account a = new Account(Name = 'not a referral');
        insert a;

        Boolean thrown = false;
        Test.startTest();
        try {
            AttorneyTransmissionService.createReferralTransmissions(new Set<Id>{ a.Id });
        } catch (AttorneyTransmissionService.TransmissionException e) {
            thrown = true;
            System.assert(e.getMessage().contains('FIELD_INTEGRITY_EXCEPTION'),
                'exception carries the controlled status code: ' + e.getMessage());
            System.assert(!e.getMessage().contains('not a referral'), 'no field values are leaked into the message');
        }
        Test.stopTest();

        System.assertEquals(true, thrown, 'a non-duplicate failure must throw, not be swallowed as a duplicate');
        System.assertEquals(0, [SELECT COUNT() FROM Integration_Transmission__c], 'nothing was created');
    }

    @IsTest
    static void emptyOrNullReferralSetIsNoOp() {
        System.assertEquals(0, AttorneyTransmissionService.createReferralTransmissions(new Set<Id>()).size());
        System.assertEquals(0, AttorneyTransmissionService.createReferralTransmissions(null).size());
    }

    // ---- #2 claim Pending --------------------------------------------------

    private static Integration_Transmission__c onePending() {
        Referral__c r = insertReferrals(1)[0];
        return AttorneyTransmissionService.createReferralTransmissions(new Set<Id>{ r.Id })[0];
    }

    @IsTest
    static void claimsPendingToProcessing() {
        Integration_Transmission__c t = onePending();

        Test.startTest();
        AttorneyTransmissionService.ClaimResult cr = AttorneyTransmissionService.claim(t.Id);
        Test.stopTest();

        System.assertEquals(true, cr.claimed);
        System.assert(UUID_V4.matcher(cr.claimToken).matches(), 'claim token must be v4');

        Integration_Transmission__c after = [
            SELECT Status__c, Claim_Token__c, Processing_Started_At__c, Last_Attempt_At__c, Retry_Count__c
            FROM Integration_Transmission__c WHERE Id = :t.Id
        ];
        System.assertEquals('Processing', after.Status__c);
        System.assertEquals(cr.claimToken, after.Claim_Token__c);
        System.assertNotEquals(null, after.Processing_Started_At__c);
        System.assertNotEquals(null, after.Last_Attempt_At__c);
        System.assertEquals(0, after.Retry_Count__c, 'a first attempt (from Pending) does NOT increment Retry_Count');
    }

    @IsTest
    static void eachClaimGetsADistinctToken() {
        Integration_Transmission__c a = onePending();
        Integration_Transmission__c b = onePending();

        AttorneyTransmissionService.ClaimResult ca = AttorneyTransmissionService.claim(a.Id);
        AttorneyTransmissionService.ClaimResult cb = AttorneyTransmissionService.claim(b.Id);

        System.assertEquals(true, ca.claimed);
        System.assertEquals(true, cb.claimed);
        System.assertNotEquals(ca.claimToken, cb.claimToken, 'each attempt gets its own claim token');
    }

    @IsTest
    static void nullIdReturnsNotFound() {
        System.assertEquals('not-found', AttorneyTransmissionService.claim((Id) null).reason);
    }

    @IsTest
    static void validButNonexistentIdReturnsNotFound() {
        Integration_Transmission__c t = onePending();
        Id id = t.Id;
        delete t; // a well-formed id that no longer resolves to a row
        AttorneyTransmissionService.ClaimResult cr = AttorneyTransmissionService.claim(id);
        System.assertEquals(false, cr.claimed);
        System.assertEquals('not-found', cr.reason);
    }

    // ---- #3 claim due Retry Scheduled (increments + clears retry time) -----

    private static Integration_Transmission__c retryScheduled(Datetime nextRetry, Integer retryCount) {
        Integration_Transmission__c t = onePending();
        t.Status__c = 'Retry Scheduled';
        t.Next_Retry_At__c = nextRetry;
        t.Retry_Count__c = retryCount;
        update t;
        return t;
    }

    @IsTest
    static void claimsDueRetryScheduledIncrementsAndClearsRetryTime() {
        Integration_Transmission__c t = retryScheduled(Datetime.now().addMinutes(-1), 1);

        Test.startTest();
        AttorneyTransmissionService.ClaimResult cr = AttorneyTransmissionService.claim(t.Id);
        Test.stopTest();

        System.assertEquals(true, cr.claimed);
        Integration_Transmission__c after = [
            SELECT Status__c, Retry_Count__c, Next_Retry_At__c FROM Integration_Transmission__c WHERE Id = :t.Id
        ];
        System.assertEquals('Processing', after.Status__c);
        System.assertEquals(2, after.Retry_Count__c, 'a retry claim increments Retry_Count');
        System.assertEquals(null, after.Next_Retry_At__c, 'the retry time is cleared once the row leaves Retry Scheduled');
    }

    @IsTest
    static void doesNotClaimRetryNotYetDue() {
        Integration_Transmission__c t = retryScheduled(Datetime.now().addMinutes(30), 1);
        AttorneyTransmissionService.ClaimResult cr = AttorneyTransmissionService.claim(t.Id);
        System.assertEquals(false, cr.claimed);
        System.assertEquals('not-eligible', cr.reason);
    }

    @IsTest
    static void doesNotClaimRetryAtCeiling() {
        Integration_Transmission__c t = retryScheduled(Datetime.now().addMinutes(-1), AttorneyTransmissionService.MAX_RETRIES);
        AttorneyTransmissionService.ClaimResult cr = AttorneyTransmissionService.claim(t.Id);
        System.assertEquals(false, cr.claimed);
        System.assertEquals('not-eligible', cr.reason);
    }

    @IsTest
    static void doesNotClaimTerminalOrProcessingStates() {
        for (String state : new List<String>{ 'Processing', 'Succeeded', 'Failed' }) {
            Integration_Transmission__c t = onePending();
            t.Status__c = state;
            update t;
            AttorneyTransmissionService.ClaimResult cr = AttorneyTransmissionService.claim(t.Id);
            System.assertEquals(false, cr.claimed, state + ' must not be claimable');
            System.assertEquals('not-eligible', cr.reason);
        }
    }

    // The hard-failure formatter is reached only when a row failed but Salesforce reports no usable
    // error list. That state can't be manufactured from a real SaveResult (no public constructor), so
    // this proves the formatter itself fails closed rather than pretending to reproduce the DML path.
    @IsTest
    static void errorCodesFailsClosedOnNullOrEmpty() {
        System.assertEquals('UNKNOWN', AttorneyTransmissionService.errorCodes(null));
        System.assertEquals(
            'UNKNOWN',
            AttorneyTransmissionService.errorCodes(new List<Database.Error>())
        );
    }
}
