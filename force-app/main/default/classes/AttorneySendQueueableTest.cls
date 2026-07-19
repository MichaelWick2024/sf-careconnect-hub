@IsTest
private class AttorneySendQueueableTest {

    private static final String SUCCESS_UUID = '11111111-2222-4333-8444-555555555555';
    private static final String CONFLICT_UUID = '22222222-3333-4444-8555-666666666666';
    private static final String CASE_RECORD_ID = 'a00000000000001AAA';

    // A success mock that ECHOES the request's correlationId, so it validates against whatever
    // Correlation_Id__c createReferralTransmissions generated (a v4 UUID unknown at authoring time).
    private class EchoSuccessMock implements HttpCalloutMock {
        private String attorneyCaseId;
        private EchoSuccessMock(String caseId) { this.attorneyCaseId = caseId; }
        public HttpResponse respond(HttpRequest req) {
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
            HttpResponse r = new HttpResponse();
            r.setStatusCode(200);
            r.setHeader('Content-Type', 'application/json');
            r.setBody(JSON.serialize(new Map<String, Object>{
                'correlationId' => body.get('correlationId'), 'success' => true,
                'attorneyCaseId' => attorneyCaseId, 'attorneyCaseRecordId' => CASE_RECORD_ID,
                'status' => 'Open', 'errorCode' => null
            }));
            return r;
        }
    }
    private class StatusMock implements HttpCalloutMock {
        private Integer status;
        private StatusMock(Integer status) { this.status = status; }
        public HttpResponse respond(HttpRequest req) {
            HttpResponse r = new HttpResponse();
            r.setStatusCode(status);
            r.setBody('{}');
            return r;
        }
    }

    // Committed setup: the callout in each test then follows only SOQL, never uncommitted DML.
    @TestSetup
    static void setup() {
        Contact c = new Contact(FirstName = 'Jane', LastName = 'Doe', Email = 'jane@example.com',
            Phone = '555-0100', Birthdate = Date.newInstance(1985, 4, 12));
        insert c;

        // Primary: a real Pending transmission, then claimed -> Processing with a token.
        Referral__c r1 = new Referral__c(Status__c = 'New', Referral_Type__c = 'Personal Injury', Contact__c = c.Id);
        insert r1;
        Integration_Transmission__c t1 = AttorneyTransmissionService.createReferralTransmissions(new Set<Id>{ r1.Id })[0];
        AttorneyTransmissionService.claim(t1.Id);

        // Blocker: already owns the External_Record_Key the #7b test's success will try to write. Its
        // key uses CONFLICT_UUID, distinct from the success tests' SUCCESS_UUID, so it is inert for them.
        Referral__c r2 = new Referral__c(Status__c = 'New', Referral_Type__c = 'General', Contact__c = c.Id);
        insert r2;
        insert new Integration_Transmission__c(
            Referral__c = r2.Id, Target_System__c = 'ATTORNEY', Operation__c = 'CREATE_REFERRAL',
            Transmission_Key__c = String.valueOf(r2.Id) + '|ATTORNEY|CREATE_REFERRAL',
            Correlation_Id__c = Uuid.v4(), Status__c = 'Succeeded', Retry_Count__c = 0,
            External_Record_Id__c = CONFLICT_UUID, External_Record_Key__c = 'ATTORNEY|' + CONFLICT_UUID);
    }

    private static Integration_Transmission__c primary() {
        return [
            SELECT Id, Claim_Token__c, Correlation_Id__c, Referral__c
            FROM Integration_Transmission__c WHERE Status__c = 'Processing' LIMIT 1
        ];
    }

    private static Map<Id, String> claimOf(Integration_Transmission__c t, String token) {
        return new Map<Id, String>{ t.Id => token };
    }

    @IsTest
    static void senderBatchFitsCalloutBudget() {
        System.assertEquals(30000, AttorneyApiService.TIMEOUT_MS);
        System.assertEquals(3, AttorneyDispatchQueueable.MAX_CLAIM_BATCH);
        System.assert(
            AttorneyDispatchQueueable.MAX_CLAIM_BATCH * AttorneyApiService.TIMEOUT_MS <= 90000,
            'The sender must reserve >= 30 s beneath the 120 s cumulative callout limit.'
        );
    }

    @IsTest
    static void successAppliesAndWritesOneLog() {
        Integration_Transmission__c t = primary();
        Test.setMock(HttpCalloutMock.class, new EchoSuccessMock(SUCCESS_UUID));

        Test.startTest();
        new AttorneySendQueueable(claimOf(t, t.Claim_Token__c), new List<Id>()).execute(null);
        Test.stopTest();

        Integration_Transmission__c after = [
            SELECT Status__c, External_Record_Id__c, External_Record_Key__c, External_Salesforce_Id__c,
                   Claim_Token__c, Succeeded_At__c
            FROM Integration_Transmission__c WHERE Id = :t.Id
        ];
        System.assertEquals('Succeeded', after.Status__c);
        System.assertEquals(SUCCESS_UUID, after.External_Record_Id__c);
        System.assertEquals('ATTORNEY|' + SUCCESS_UUID, after.External_Record_Key__c);
        System.assertEquals(CASE_RECORD_ID, after.External_Salesforce_Id__c);
        System.assertNotEquals(null, after.Succeeded_At__c);
        System.assertEquals(null, after.Claim_Token__c);

        List<Integration_Log__c> logs = [
            SELECT Success__c, Status_Code__c, Direction__c, External_System__c, Http_Method__c,
                   Correlation_Id__c, Referral__c, Sanitized_Request_JSON__c, Sanitized_Response_JSON__c,
                   Error_Message__c
            FROM Integration_Log__c
        ];
        System.assertEquals(1, logs.size(), 'exactly one attempt log');
        Integration_Log__c log = logs[0];
        System.assertEquals(true, log.Success__c);
        System.assertEquals(200, log.Status_Code__c);
        System.assertEquals('Outbound', log.Direction__c);
        System.assertEquals('Attorney', log.External_System__c);
        System.assertEquals('POST', log.Http_Method__c);
        System.assertEquals(t.Correlation_Id__c, log.Correlation_Id__c);
        System.assertEquals(t.Referral__c, log.Referral__c);
        System.assertNotEquals(null, log.Sanitized_Request_JSON__c);
        System.assertNotEquals(null, log.Sanitized_Response_JSON__c);
        System.assertEquals(null, log.Error_Message__c, 'no error code on success');
    }

    @IsTest
    static void transientSchedulesRetryAndLogsFailure() {
        Integration_Transmission__c t = primary();
        Test.setMock(HttpCalloutMock.class, new StatusMock(500));

        Test.startTest();
        new AttorneySendQueueable(claimOf(t, t.Claim_Token__c), new List<Id>()).execute(null);
        Test.stopTest();

        Integration_Transmission__c after = [
            SELECT Status__c, Last_Error_Code__c, Next_Retry_At__c, Claim_Token__c
            FROM Integration_Transmission__c WHERE Id = :t.Id
        ];
        System.assertEquals('Retry Scheduled', after.Status__c);
        System.assertEquals('SERVER_ERROR', after.Last_Error_Code__c);
        System.assertNotEquals(null, after.Next_Retry_At__c);
        System.assertEquals(null, after.Claim_Token__c);

        Integration_Log__c log = [SELECT Success__c, Status_Code__c, Error_Message__c FROM Integration_Log__c LIMIT 1];
        System.assertEquals(false, log.Success__c);
        System.assertEquals(500, log.Status_Code__c);
        System.assertEquals('SERVER_ERROR', log.Error_Message__c);
    }

    // The load-bearing race: a sender presenting a token that no longer matches (the row was re-claimed
    // mid-callout) must NOT advance local state — but the callout it already made is still logged.
    @IsTest
    static void staleTokenDoesNotOverwriteButStillLogs() {
        Integration_Transmission__c t = primary();
        Test.setMock(HttpCalloutMock.class, new EchoSuccessMock(SUCCESS_UUID));

        Test.startTest();
        new AttorneySendQueueable(claimOf(t, 'dddddddd-eeee-4fff-8000-111111111111'), new List<Id>()).execute(null);
        Test.stopTest();

        Integration_Transmission__c after = [
            SELECT Status__c, Claim_Token__c, External_Record_Key__c
            FROM Integration_Transmission__c WHERE Id = :t.Id
        ];
        System.assertEquals('Processing', after.Status__c, 'a stale sender must not advance the row');
        System.assertEquals(t.Claim_Token__c, after.Claim_Token__c, 'the real token is left intact');
        System.assertEquals(null, after.External_Record_Key__c);
        System.assertEquals(1, [SELECT COUNT() FROM Integration_Log__c], 'the attempt is still recorded');
    }

    @IsTest
    static void externalKeyCollisionBecomesConflict() {
        Integration_Transmission__c t = primary();
        Test.setMock(HttpCalloutMock.class, new EchoSuccessMock(CONFLICT_UUID)); // collides with the blocker

        Test.startTest();
        new AttorneySendQueueable(claimOf(t, t.Claim_Token__c), new List<Id>()).execute(null);
        Test.stopTest();

        Integration_Transmission__c after = [
            SELECT Status__c, Last_Error_Code__c, External_Record_Id__c, External_Record_Key__c,
                   External_Salesforce_Id__c, Succeeded_At__c, Claim_Token__c
            FROM Integration_Transmission__c WHERE Id = :t.Id
        ];
        System.assertEquals('Failed', after.Status__c);
        System.assertEquals('EXTERNAL_RECORD_CONFLICT', after.Last_Error_Code__c);
        System.assertEquals(null, after.External_Record_Key__c, 'the conflicting key is not persisted');
        System.assertEquals(null, after.External_Record_Id__c);
        System.assertEquals(null, after.External_Salesforce_Id__c);
        System.assertEquals(null, after.Succeeded_At__c);
        System.assertEquals(null, after.Claim_Token__c);
    }
}
