@IsTest
private class AttorneySendQueueableTest {

    private static final String SUCCESS_UUID = '11111111-2222-4333-8444-555555555555';
    private static final String CONFLICT_UUID = '22222222-3333-4444-8555-666666666666';
    private static final String CASE_RECORD_ID = 'a00000000000001AAA';
    private static final String PRIMARY_TYPE = 'Personal Injury';

    // ---- mocks -------------------------------------------------------------

    // Echoes the request's correlationId (the transmission's Correlation_Id__c is a runtime UUID) and
    // records whether it was called at all (to prove the pre-callout skip makes no call).
    private class EchoSuccessMock implements HttpCalloutMock {
        private String attorneyCaseId;
        public Boolean wasCalled = false;
        private EchoSuccessMock(String caseId) { this.attorneyCaseId = caseId; }
        public HttpResponse respond(HttpRequest req) {
            wasCalled = true;
            return successFor(req, attorneyCaseId);
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

    // Deletes the row WHILE the callout is in flight (system-context maintenance can do this), so the
    // post-callout re-lock finds nothing.
    private class DeleteRowMock implements HttpCalloutMock {
        private Id transmissionId;
        private DeleteRowMock(Id id) { this.transmissionId = id; }
        public HttpResponse respond(HttpRequest req) {
            delete new Integration_Transmission__c(Id = transmissionId);
            return successFor(req, SUCCESS_UUID);
        }
    }

    // Per-row status keyed by correlationId — the three-row batch mock. 200 → success echo; else status.
    private class MultiMock implements HttpCalloutMock {
        private Map<String, Integer> statusByCorrelation;
        public Integer totalCalls = 0;
        private MultiMock(Map<String, Integer> m) { this.statusByCorrelation = m; }
        public HttpResponse respond(HttpRequest req) {
            totalCalls++;
            Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(req.getBody());
            Integer status = statusByCorrelation.get((String) body.get('correlationId'));
            if (status == 200) {
                return successFor(req, SUCCESS_UUID);
            }
            HttpResponse r = new HttpResponse();
            r.setStatusCode(status);
            r.setBody('{}');
            return r;
        }
    }

    // Simulates a concurrent re-claim WHILE the callout is in flight: it rotates the row's claim token,
    // so the post-callout re-lock sees a token that no longer matches this sender's expected one.
    private class RotateTokenMock implements HttpCalloutMock {
        private Id transmissionId;
        private RotateTokenMock(Id id) { this.transmissionId = id; }
        public HttpResponse respond(HttpRequest req) {
            update new Integration_Transmission__c(
                Id = transmissionId, Claim_Token__c = 'eeeeeeee-ffff-4aaa-8bbb-cccccccccccc');
            return successFor(req, SUCCESS_UUID);
        }
    }

    private static HttpResponse successFor(HttpRequest req, String attorneyCaseId) {
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

    // ---- committed setup ---------------------------------------------------
    // @TestSetup commits, so each test's callout follows only SOQL (never uncommitted DML). Rows are
    // distinguished by Referral_Type so single-row tests (Personal Injury) and the batch test (the other
    // three types) coexist without interfering.

    @TestSetup
    static void setup() {
        Contact c = new Contact(FirstName = 'Jane', LastName = 'Doe', Email = 'jane@example.com',
            Phone = '555-0100', Birthdate = Date.newInstance(1985, 4, 12));
        insert c;

        claimNew(c.Id, PRIMARY_TYPE);
        claimNew(c.Id, 'Workers Compensation');
        claimNew(c.Id, 'Medical Malpractice');
        claimNew(c.Id, 'General');

        // A claimed row whose referral has NO contact — the mapper produces a request the validator
        // rejects locally (INVALID_REQUEST), so the sender never makes an HTTP call. Selected by the
        // null contact, so it is invisible to rowOfType (which requires a contact).
        claimNew(null, 'General');

        // Blocker owning the External_Record_Key the #7b test's success collides with (CONFLICT_UUID,
        // distinct from SUCCESS_UUID so it is inert for every other test).
        Referral__c rb = new Referral__c(Status__c = 'New', Referral_Type__c = 'General', Contact__c = c.Id);
        insert rb;
        insert new Integration_Transmission__c(
            Referral__c = rb.Id, Target_System__c = 'ATTORNEY', Operation__c = 'CREATE_REFERRAL',
            Transmission_Key__c = String.valueOf(rb.Id) + '|ATTORNEY|CREATE_REFERRAL',
            Correlation_Id__c = Uuid.v4(), Status__c = 'Succeeded', Retry_Count__c = 0,
            External_Record_Id__c = CONFLICT_UUID, External_Record_Key__c = 'ATTORNEY|' + CONFLICT_UUID);
    }

    private static void claimNew(Id contactId, String referralType) {
        Referral__c r = new Referral__c(Status__c = 'New', Referral_Type__c = referralType, Contact__c = contactId);
        insert r;
        Integration_Transmission__c t = AttorneyTransmissionService.createReferralTransmissions(new Set<Id>{ r.Id })[0];
        AttorneyTransmissionService.claim(t.Id);
    }

    private static Integration_Transmission__c rowOfType(String referralType) {
        return [
            SELECT Id, Claim_Token__c, Correlation_Id__c, Referral__c
            FROM Integration_Transmission__c
            WHERE Status__c = 'Processing' AND Referral__r.Referral_Type__c = :referralType
              AND Referral__r.Contact__c != null LIMIT 1
        ];
    }

    private static Integration_Transmission__c contactlessRow() {
        return [
            SELECT Id, Claim_Token__c, Correlation_Id__c, Referral__c
            FROM Integration_Transmission__c
            WHERE Status__c = 'Processing' AND Referral__r.Contact__c = null LIMIT 1
        ];
    }

    private static Map<Id, String> mapOf(Integration_Transmission__c t, String token) {
        return new Map<Id, String>{ t.Id => token };
    }

    // ---- tests -------------------------------------------------------------

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
        Integration_Transmission__c t = rowOfType(PRIMARY_TYPE);
        Test.setMock(HttpCalloutMock.class, new EchoSuccessMock(SUCCESS_UUID));

        Test.startTest();
        new AttorneySendQueueable(mapOf(t, t.Claim_Token__c), new List<Id>()).execute(null);
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

        List<Integration_Log__c> logs = logsForReferral(t.Referral__c);
        System.assertEquals(1, logs.size(), 'exactly one attempt log');
        Integration_Log__c log = logs[0];
        System.assertEquals(true, log.Success__c);
        System.assertEquals(200, log.Status_Code__c);
        System.assertEquals('Outbound', log.Direction__c);
        System.assertEquals('Attorney', log.External_System__c);
        System.assertEquals('POST', log.Http_Method__c);
        System.assertEquals(t.Correlation_Id__c, log.Correlation_Id__c);
        System.assertNotEquals(null, log.Sanitized_Request_JSON__c);
        System.assertNotEquals(null, log.Sanitized_Response_JSON__c);
        System.assertEquals(null, log.Error_Message__c, 'no error code on success');
    }

    @IsTest
    static void transientSchedulesRetryAndLogsFailure() {
        Integration_Transmission__c t = rowOfType(PRIMARY_TYPE);
        Test.setMock(HttpCalloutMock.class, new StatusMock(500));

        Test.startTest();
        new AttorneySendQueueable(mapOf(t, t.Claim_Token__c), new List<Id>()).execute(null);
        Test.stopTest();

        Integration_Transmission__c after = [
            SELECT Status__c, Last_Error_Code__c, Next_Retry_At__c, Claim_Token__c
            FROM Integration_Transmission__c WHERE Id = :t.Id
        ];
        System.assertEquals('Retry Scheduled', after.Status__c);
        System.assertEquals('SERVER_ERROR', after.Last_Error_Code__c);
        System.assertNotEquals(null, after.Next_Retry_At__c);
        System.assertEquals(null, after.Claim_Token__c);

        Integration_Log__c log = logsForReferral(t.Referral__c)[0];
        System.assertEquals(false, log.Success__c);
        System.assertEquals(500, log.Status_Code__c);
        System.assertEquals('SERVER_ERROR', log.Error_Message__c);
    }

    // Pre-callout authorization: a token already stale at reload -> NO callout, NO log, NO mutation,
    // because no transmission attempt is made.
    @IsTest
    static void knownStaleTokenMakesNoCalloutAndNoLog() {
        Integration_Transmission__c t = rowOfType(PRIMARY_TYPE);
        EchoSuccessMock mock = new EchoSuccessMock(SUCCESS_UUID);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new AttorneySendQueueable(mapOf(t, 'dddddddd-eeee-4fff-8000-111111111111'), new List<Id>()).execute(null);
        Test.stopTest();

        System.assertEquals(false, mock.wasCalled, 'a detectably-stale row must not be called out');
        Integration_Transmission__c after = [
            SELECT Status__c, Claim_Token__c FROM Integration_Transmission__c WHERE Id = :t.Id
        ];
        System.assertEquals('Processing', after.Status__c, 'the row is untouched');
        System.assertEquals(t.Claim_Token__c, after.Claim_Token__c);
        System.assertEquals(0, [SELECT COUNT() FROM Integration_Log__c], 'no attempt, no log');
    }

    // The genuinely mid-flight race: the token is valid at reload (so the callout happens) but rotates
    // DURING the callout. The post-callout re-lock catches it -> no state change, but the attempt is
    // logged because the callout DID occur.
    @IsTest
    static void postCalloutRotationRefusesButLogs() {
        Integration_Transmission__c t = rowOfType(PRIMARY_TYPE);
        Test.setMock(HttpCalloutMock.class, new RotateTokenMock(t.Id));

        Test.startTest();
        new AttorneySendQueueable(mapOf(t, t.Claim_Token__c), new List<Id>()).execute(null);
        Test.stopTest();

        Integration_Transmission__c after = [
            SELECT Status__c, Claim_Token__c, External_Record_Key__c
            FROM Integration_Transmission__c WHERE Id = :t.Id
        ];
        System.assertEquals('Processing', after.Status__c, 'the mid-flight sender must not advance the row');
        System.assertEquals('eeeeeeee-ffff-4aaa-8bbb-cccccccccccc', after.Claim_Token__c, 'the newer token stands');
        System.assertEquals(null, after.External_Record_Key__c);

        Integration_Log__c log = logsForReferral(t.Referral__c)[0];
        System.assertEquals(false, log.Success__c);
        System.assertEquals('STALE_CLAIM', log.Error_Message__c, 'the attempt is logged as a stale claim');
    }

    @IsTest
    static void externalKeyCollisionBecomesConflict() {
        Integration_Transmission__c t = rowOfType(PRIMARY_TYPE);
        Test.setMock(HttpCalloutMock.class, new EchoSuccessMock(CONFLICT_UUID)); // collides with the blocker

        Test.startTest();
        new AttorneySendQueueable(mapOf(t, t.Claim_Token__c), new List<Id>()).execute(null);
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

        // The log must record the LOCAL result, not the raw 200: the earlier bug logged success=true.
        Integration_Log__c log = logsForReferral(t.Referral__c)[0];
        System.assertEquals(false, log.Success__c, 'a #7b is not a success locally');
        System.assertEquals(200, log.Status_Code__c, 'the useful HTTP status is retained');
        System.assertEquals('EXTERNAL_RECORD_CONFLICT', log.Error_Message__c);
    }

    // The defining case: three rows in ONE transaction reach three independent states, each logged, and
    // one row's failure does not roll back the others.
    @IsTest
    static void threeRowBatchEachReachesItsOwnState() {
        Integration_Transmission__c wc = rowOfType('Workers Compensation');  // -> 200 success
        Integration_Transmission__c mm = rowOfType('Medical Malpractice');   // -> 500 transient
        Integration_Transmission__c gn = rowOfType('General');               // -> 400 permanent

        Map<Id, String> claim = new Map<Id, String>{
            wc.Id => wc.Claim_Token__c, mm.Id => mm.Claim_Token__c, gn.Id => gn.Claim_Token__c
        };
        MultiMock mock = new MultiMock(new Map<String, Integer>{
            wc.Correlation_Id__c => 200, mm.Correlation_Id__c => 500, gn.Correlation_Id__c => 400
        });
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new AttorneySendQueueable(claim, new List<Id>()).execute(null);
        Test.stopTest();

        System.assertEquals(3, mock.totalCalls, 'exactly three requests were sent');
        System.assertEquals('Succeeded', reload(wc.Id).Status__c);
        System.assertEquals('Retry Scheduled', reload(mm.Id).Status__c);
        System.assertEquals('Failed', reload(gn.Id).Status__c);
        System.assertEquals('VALIDATION_REJECTED', reload(gn.Id).Last_Error_Code__c);

        System.assertEquals(3, [SELECT COUNT() FROM Integration_Log__c], 'one log per row');
        System.assertEquals(true, logsForReferral(wc.Referral__c)[0].Success__c);
        System.assertEquals(false, logsForReferral(mm.Referral__c)[0].Success__c);
        System.assertEquals('SERVER_ERROR', logsForReferral(mm.Referral__c)[0].Error_Message__c);
        System.assertEquals('VALIDATION_REJECTED', logsForReferral(gn.Referral__c)[0].Error_Message__c);
    }

    // A row deleted after its callout must not abort the batch: it gets a controlled NOT_FOUND log and
    // the other rows (here, none) are unaffected — proving lockOne isolates a missing row.
    @IsTest
    static void missingRowAfterCalloutIsIsolatedNotFatal() {
        Integration_Transmission__c t = rowOfType(PRIMARY_TYPE);
        Id referralId = t.Referral__c;
        Test.setMock(HttpCalloutMock.class, new DeleteRowMock(t.Id));

        Test.startTest();
        new AttorneySendQueueable(mapOf(t, t.Claim_Token__c), new List<Id>()).execute(null);
        Test.stopTest();

        System.assertEquals(0, [SELECT COUNT() FROM Integration_Transmission__c WHERE Id = :t.Id],
            'the row was deleted mid-callout');
        Integration_Log__c log = logsForReferral(referralId)[0];
        System.assertEquals(false, log.Success__c);
        System.assertEquals('NOT_FOUND', log.Error_Message__c, 'the attempt is logged, the batch not aborted');
    }

    // A request the mapper builds that the validator rejects LOCALLY (no contact -> invalid
    // careConnectContactId): the API service returns INVALID_REQUEST WITHOUT an HTTP call, but the row
    // still becomes Failed and still gets one controlled attempt log with status code 0 — and no raw
    // field value leaks into the log.
    @IsTest
    static void locallyInvalidRequestFailsWithoutCalloutButLogs() {
        Integration_Transmission__c t = contactlessRow();
        EchoSuccessMock mock = new EchoSuccessMock(SUCCESS_UUID);
        Test.setMock(HttpCalloutMock.class, mock);

        Test.startTest();
        new AttorneySendQueueable(mapOf(t, t.Claim_Token__c), new List<Id>()).execute(null);
        Test.stopTest();

        System.assertEquals(false, mock.wasCalled, 'a locally-invalid request makes no HTTP callout');

        Integration_Transmission__c after = [
            SELECT Status__c, Last_Error_Code__c, Last_Status_Code__c
            FROM Integration_Transmission__c WHERE Id = :t.Id
        ];
        System.assertEquals('Failed', after.Status__c);
        System.assertEquals('INVALID_REQUEST', after.Last_Error_Code__c);

        Integration_Log__c log = logsForReferral(t.Referral__c)[0];
        System.assertEquals(false, log.Success__c);
        System.assertEquals(0, log.Status_Code__c, 'no HTTP response -> status code 0');
        System.assertEquals('INVALID_REQUEST', log.Error_Message__c);
        System.assert(log.Sanitized_Request_JSON__c.contains('invalidRequest'),
            'the request log records only the failed check, no values: ' + log.Sanitized_Request_JSON__c);
    }

    // Best-effort logging must INSPECT, not ignore: one bad log row does not throw and does not take the
    // valid rows down with it, and its failure surfaces as a CONTROLLED status code (never the raw value).
    @IsTest
    static void logInsertFailureIsInspectedNotSwallowed() {
        String goodCorrelation = 'abababab-cdcd-4ede-8f0f-121212121212';
        Integration_Log__c good = new Integration_Log__c(
            Direction__c = 'Outbound', External_System__c = 'Attorney', Http_Method__c = 'POST',
            Correlation_Id__c = goodCorrelation, Status_Code__c = 200, Success__c = true);
        Integration_Log__c bad = new Integration_Log__c(
            Direction__c = 'Bogus', // restricted picklist -> rejected
            External_System__c = 'Attorney', Http_Method__c = 'POST', Status_Code__c = 200);

        List<String> failures = AttorneySendQueueable.writeLogsBestEffort(
            new List<Integration_Log__c>{ good, bad });

        System.assertEquals(1, failures.size(), 'the one bad row is inspected, not discarded');
        System.assertEquals('INVALID_OR_NULL_FOR_RESTRICTED_PICKLIST', failures[0], 'controlled status code only');
        System.assertEquals(false, failures[0].contains('Bogus'), 'the rejected value never appears in the diagnostic');
        System.assertEquals(1, [SELECT COUNT() FROM Integration_Log__c WHERE Correlation_Id__c = :goodCorrelation],
            'the valid row survives the bad one');
    }

    private static Integration_Transmission__c reload(Id id) {
        return [SELECT Status__c, Last_Error_Code__c FROM Integration_Transmission__c WHERE Id = :id];
    }

    private static List<Integration_Log__c> logsForReferral(Id referralId) {
        return [
            SELECT Success__c, Status_Code__c, Error_Message__c, Direction__c, External_System__c,
                   Http_Method__c, Correlation_Id__c, Sanitized_Request_JSON__c, Sanitized_Response_JSON__c
            FROM Integration_Log__c WHERE Referral__c = :referralId
        ];
    }
}
