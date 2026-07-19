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

    // ---- #4–#8: apply a send outcome ---------------------------------------
    //
    // These produce REAL CalloutOutcomes via AttorneyApiService.sendReferral + a mock — never a
    // fabricated one (its constructor is private on purpose). A mock callout still counts as a callout
    // and cannot follow DML, so every test produces its outcome(s) FIRST, then does its DML.

    private static final String CASE_UUID = '11111111-2222-4333-8444-555555555555';
    private static final String CASE_RECORD_ID = 'a00000000000001AAA';
    private static final String CORRELATION = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

    private class Mock implements HttpCalloutMock {
        private Integer status; private String body;
        private Mock(Integer status, String body) { this.status = status; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(status);
            r.setHeader('Content-Type', 'application/json');
            if (body != null) { r.setBody(body); }
            return r;
        }
    }

    private static AttorneyReferralRequest validRequest() {
        AttorneyReferralRequest r = new AttorneyReferralRequest();
        r.correlationId = CORRELATION;
        r.careConnectReferralId = 'a01000000000001AAA';
        r.referralType = 'Personal Injury';
        r.client = new AttorneyReferralRequest.ClientInfo();
        r.client.careConnectContactId = '003000000000001AAA';
        r.client.fullName = 'Jane Doe';
        return r;
    }

    private static AttorneyApiService.CalloutOutcome outcome(Integer status, String body) {
        Test.setMock(HttpCalloutMock.class, new Mock(status, body));
        return AttorneyApiService.sendReferral(validRequest());
    }
    private static AttorneyApiService.CalloutOutcome successOutcome() {
        return outcome(200, JSON.serialize(new Map<String, Object>{
            'correlationId' => CORRELATION, 'success' => true, 'attorneyCaseId' => CASE_UUID,
            'attorneyCaseRecordId' => CASE_RECORD_ID, 'status' => 'Open', 'errorCode' => null
        }));
    }
    private static AttorneyApiService.CalloutOutcome transientOutcome() { return outcome(500, '{}'); } // SERVER_ERROR
    private static AttorneyApiService.CalloutOutcome permanentOutcome() { return outcome(400, '{}'); } // VALIDATION_REJECTED

    // A persisted Processing row with a given Retry_Count and an in-flight claim, one minute in.
    private static Integration_Transmission__c processing(Integer retryCount) {
        Referral__c r = insertReferrals(1)[0];
        Datetime aMinuteAgo = Datetime.now().addMinutes(-1);
        Integration_Transmission__c t = new Integration_Transmission__c(
            Referral__c = r.Id, Target_System__c = 'ATTORNEY', Operation__c = 'CREATE_REFERRAL',
            Transmission_Key__c = String.valueOf(r.Id) + '|ATTORNEY|CREATE_REFERRAL',
            Correlation_Id__c = Uuid.v4(), Status__c = 'Processing', Retry_Count__c = retryCount,
            Claim_Token__c = 'cccccccc-dddd-4eee-8fff-999999999999',
            Processing_Started_At__c = aMinuteAgo, Last_Attempt_At__c = aMinuteAgo
        );
        insert t;
        return t;
    }

    private static Integration_Transmission__c reload(Id id) {
        return [
            SELECT Status__c, Retry_Count__c, Next_Retry_At__c, Last_Attempt_At__c, Processing_Started_At__c,
                   Claim_Token__c, Last_Status_Code__c, Last_Error_Code__c, External_Record_Id__c,
                   External_Record_Key__c, External_Salesforce_Id__c, Succeeded_At__c
            FROM Integration_Transmission__c WHERE Id = :id
        ];
    }

    @IsTest
    static void successAppliesTransition4() {
        AttorneyApiService.CalloutOutcome o = successOutcome(); // callout FIRST (before DML)
        System.assertEquals(AttorneyApiService.Disposition.SUCCESS, o.disposition);

        Integration_Transmission__c t = processing(0);
        AttorneyTransmissionService.applySendOutcome(t, o);
        update t;

        Integration_Transmission__c after = reload(t.Id);
        System.assertEquals('Succeeded', after.Status__c);
        System.assertEquals(CASE_UUID, after.External_Record_Id__c);
        System.assertEquals('ATTORNEY|' + CASE_UUID, after.External_Record_Key__c);
        System.assertEquals(CASE_RECORD_ID, after.External_Salesforce_Id__c);
        System.assertEquals(200, after.Last_Status_Code__c);
        System.assertNotEquals(null, after.Succeeded_At__c);
        System.assertEquals(null, after.Claim_Token__c);
        System.assertEquals(null, after.Processing_Started_At__c);
        System.assertEquals(null, after.Next_Retry_At__c);
        System.assertEquals(null, after.Last_Error_Code__c);
        System.assertNotEquals(null, after.Last_Attempt_At__c, 'Last_Attempt_At is durable, never cleared');
    }

    @IsTest
    static void transientWithBudgetAppliesTransition5() {
        AttorneyApiService.CalloutOutcome o = transientOutcome();
        System.assertEquals(AttorneyApiService.Disposition.TRANSIENT_FAILURE, o.disposition);

        Integration_Transmission__c t = processing(1); // one retry performed; budget remains
        AttorneyTransmissionService.applySendOutcome(t, o);
        update t;

        Integration_Transmission__c after = reload(t.Id);
        System.assertEquals('Retry Scheduled', after.Status__c);
        System.assertEquals('SERVER_ERROR', after.Last_Error_Code__c);
        System.assertEquals(1, after.Retry_Count__c, 'applySendOutcome never touches Retry_Count (the CLAIM does)');
        System.assertNotEquals(null, after.Next_Retry_At__c);
        System.assert(after.Next_Retry_At__c > after.Last_Attempt_At__c, 'retry is scheduled in the future');
        System.assertEquals(null, after.Claim_Token__c);
        System.assertEquals(null, after.Processing_Started_At__c);
    }

    @IsTest
    static void transientNoBudgetAppliesTransition6() {
        AttorneyApiService.CalloutOutcome o = transientOutcome();

        Integration_Transmission__c t = processing(3); // MAX_RETRIES retries performed; budget spent
        AttorneyTransmissionService.applySendOutcome(t, o);
        update t;

        Integration_Transmission__c after = reload(t.Id);
        System.assertEquals('Failed', after.Status__c);
        System.assertEquals('RETRY_BUDGET_EXHAUSTED', after.Last_Error_Code__c);
        System.assertEquals(null, after.Next_Retry_At__c);
        System.assertEquals(null, after.Claim_Token__c);
        System.assertEquals(null, after.Processing_Started_At__c);
    }

    @IsTest
    static void permanentAppliesTransition7() {
        AttorneyApiService.CalloutOutcome o = permanentOutcome();
        System.assertEquals(AttorneyApiService.Disposition.PERMANENT_FAILURE, o.disposition);

        Integration_Transmission__c t = processing(0);
        AttorneyTransmissionService.applySendOutcome(t, o);
        update t;

        Integration_Transmission__c after = reload(t.Id);
        System.assertEquals('Failed', after.Status__c);
        System.assertEquals('VALIDATION_REJECTED', after.Last_Error_Code__c, 'the outcome error code, not a budget code');
        System.assertEquals(400, after.Last_Status_Code__c);
        System.assertEquals(null, after.Next_Retry_At__c);
        System.assertEquals(null, after.Claim_Token__c);
    }

    @IsTest
    static void backoffGrowsWithRetryCount() {
        // Both callouts first (no DML between a callout and the next), then the DML rows.
        AttorneyApiService.CalloutOutcome o0 = transientOutcome();
        AttorneyApiService.CalloutOutcome o2 = transientOutcome();

        Integration_Transmission__c t0 = processing(0);
        AttorneyTransmissionService.applySendOutcome(t0, o0);
        System.assertEquals(t0.Last_Attempt_At__c.addMinutes(1), t0.Next_Retry_At__c, 'Retry_Count 0 -> +1 min');

        Integration_Transmission__c t2 = processing(2);
        AttorneyTransmissionService.applySendOutcome(t2, o2);
        System.assertEquals(t2.Last_Attempt_At__c.addMinutes(4), t2.Next_Retry_At__c, 'Retry_Count 2 -> +4 min');
    }

    @IsTest
    static void externalConflictAppliesTransition7b() {
        Integration_Transmission__c t = processing(0);
        // a success moment: external identifiers populated, about to be persisted...
        t.Status__c = 'Succeeded';
        t.External_Record_Id__c = CASE_UUID;
        t.External_Record_Key__c = 'ATTORNEY|' + CASE_UUID;
        t.External_Salesforce_Id__c = CASE_RECORD_ID;
        // ...but the unique-key write collided; the caller reclassifies:
        AttorneyTransmissionService.applyExternalConflict(t);
        update t;

        Integration_Transmission__c after = reload(t.Id);
        System.assertEquals('Failed', after.Status__c);
        System.assertEquals('EXTERNAL_RECORD_CONFLICT', after.Last_Error_Code__c);
        System.assertEquals(null, after.External_Record_Id__c, 'conflicting identifiers must NOT be persisted');
        System.assertEquals(null, after.External_Record_Key__c);
        System.assertEquals(null, after.External_Salesforce_Id__c);
        System.assertEquals(null, after.Succeeded_At__c);
        System.assertEquals(null, after.Claim_Token__c);
        System.assertEquals(null, after.Next_Retry_At__c);
    }

    @IsTest
    static void staleWithBudgetAppliesTransition8a() {
        Integration_Transmission__c t = processing(1);
        AttorneyTransmissionService.applyStaleRecovery(t);
        update t;

        Integration_Transmission__c after = reload(t.Id);
        System.assertEquals('Retry Scheduled', after.Status__c);
        System.assertEquals('STALE_CLAIM_RECOVERED', after.Last_Error_Code__c);
        System.assertNotEquals(null, after.Next_Retry_At__c, 'recovered row is immediately eligible');
        System.assertEquals(null, after.Claim_Token__c);
        System.assertEquals(null, after.Processing_Started_At__c);
    }

    @IsTest
    static void staleNoBudgetAppliesTransition8b() {
        Integration_Transmission__c t = processing(3);
        AttorneyTransmissionService.applyStaleRecovery(t);
        update t;

        Integration_Transmission__c after = reload(t.Id);
        System.assertEquals('Failed', after.Status__c);
        System.assertEquals('RETRY_BUDGET_EXHAUSTED', after.Last_Error_Code__c,
            'a repeatedly-dying sender terminates once the budget is spent');
        System.assertEquals(null, after.Next_Retry_At__c);
        System.assertEquals(null, after.Claim_Token__c);
    }
}
