@IsTest
private class AttorneyApiServiceTest {

    private static final String CORRELATION = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
    private static final String CASE_UUID = '11111111-2222-4333-8444-555555555555';
    private static final String PROSE = 'Patient Jane Doe has a spinal injury';

    // ---- a configurable, request-capturing HttpCalloutMock -----------------
    // (Apex forbids static methods on inner classes; factories live on the outer class.)
    private class Mock implements HttpCalloutMock {
        private Integer status;
        private String body;
        private Boolean throwCallout = false;
        public Boolean wasCalled = false;
        public HttpRequest captured;
        private Mock(Integer status, String body) { this.status = status; this.body = body; }
        public HttpResponse respond(HttpRequest req) {
            wasCalled = true;
            captured = req;
            if (throwCallout) { throw new System.CalloutException('Read timed out'); }
            HttpResponse r = new HttpResponse();
            r.setStatusCode(status);
            r.setHeader('Content-Type', 'application/json');
            if (body != null) { r.setBody(body); }
            return r;
        }
    }
    private static Mock mockOf(Integer status, String body) { return new Mock(status, body); }
    private static Mock mockThrowing() { Mock m = new Mock(0, null); m.throwCallout = true; return m; }

    // ---- fixtures ----------------------------------------------------------

    private static AttorneyReferralRequest request() {
        AttorneyReferralRequest r = new AttorneyReferralRequest();
        r.correlationId = CORRELATION;
        r.careConnectReferralId = 'a01000000000001AAA';
        r.referralType = 'Personal Injury';
        r.client = new AttorneyReferralRequest.ClientInfo();
        r.client.careConnectContactId = '003000000000001AAA';
        r.client.fullName = 'Jane Doe';
        r.client.email = 'jane@example.com';
        r.client.phone = '555-0100';
        r.client.dateOfBirth = '1985-04-12';
        return r;
    }

    private static String successBodyWith(Map<String, Object> overrides) {
        Map<String, Object> body = new Map<String, Object>{
            'correlationId' => CORRELATION, 'success' => true, 'attorneyCaseId' => CASE_UUID,
            'attorneyCaseRecordId' => 'a00000000000001AAA', 'status' => 'Open', 'errorCode' => null
        };
        body.putAll(overrides);
        return JSON.serialize(body);
    }
    private static String successBody(String correlationId) {
        return successBodyWith(new Map<String, Object>{ 'correlationId' => correlationId });
    }

    private static AttorneyApiService.CalloutOutcome send(Mock m, AttorneyReferralRequest req) {
        Test.setMock(HttpCalloutMock.class, m);
        return AttorneyApiService.sendReferral(req);
    }
    private static AttorneyApiService.CalloutOutcome sendWith(Mock m) { return send(m, request()); }

    // ---- success -----------------------------------------------------------

    @IsTest
    static void success201ExtractsIdentifiers() {
        AttorneyApiService.CalloutOutcome o = sendWith(mockOf(201, successBody(CORRELATION)));
        System.assertEquals(AttorneyApiService.Disposition.SUCCESS, o.disposition);
        System.assertEquals(201, o.statusCode);
        System.assertEquals(null, o.errorCode);
        System.assertEquals(CASE_UUID, o.attorneyCaseId);
        System.assertEquals('a00000000000001AAA', o.attorneyCaseRecordId);
        System.assertNotEquals(null, o.executionTimeMs);
    }

    @IsTest
    static void success200IsAlsoSuccess() {
        System.assertEquals(AttorneyApiService.Disposition.SUCCESS,
            sendWith(mockOf(200, successBody(CORRELATION))).disposition);
    }

    // ---- 2xx but response fails validation ---------------------------------

    @IsTest
    static void correlationMismatchIsInvalidResponse() {
        AttorneyApiService.CalloutOutcome o = sendWith(mockOf(200, successBody('99999999-8888-4777-8666-555555555555')));
        System.assertEquals(AttorneyApiService.Disposition.TRANSIENT_FAILURE, o.disposition);
        System.assertEquals(AttorneyReferralResponseValidator.INVALID_RESPONSE, o.errorCode);
        System.assertEquals('correlationId', o.failedCheck);
    }

    @IsTest
    static void successFalseInBodyIsInvalidResponse() {
        AttorneyApiService.CalloutOutcome o = sendWith(mockOf(200, successBodyWith(new Map<String, Object>{ 'success' => false })));
        System.assertEquals(AttorneyApiService.Disposition.TRANSIENT_FAILURE, o.disposition);
        System.assertEquals('success', o.failedCheck);
    }

    @IsTest
    static void unparseableBodyIsInvalidResponse() {
        AttorneyApiService.CalloutOutcome o = sendWith(mockOf(200, '{ not valid json '));
        System.assertEquals(AttorneyApiService.Disposition.TRANSIENT_FAILURE, o.disposition);
        System.assertEquals(AttorneyReferralResponseValidator.INVALID_RESPONSE, o.errorCode);
        System.assertEquals('responseBody', o.failedCheck, 'parse failure reports the controlled responseBody check');
    }

    @IsTest
    static void blankBodyIsInvalidResponse() {
        AttorneyApiService.CalloutOutcome o = sendWith(mockOf(200, '   '));
        System.assertEquals(AttorneyApiService.Disposition.TRANSIENT_FAILURE, o.disposition);
        System.assertEquals(AttorneyReferralResponseValidator.INVALID_RESPONSE, o.errorCode);
        System.assertEquals('responseBody', o.failedCheck);
    }

    /**
     * A 2xx body larger than the contract ceiling is refused BEFORE deserialization (the heap risk),
     * and none of its content is inspected or exposed — even though it is a "valid" JSON shape.
     */
    @IsTest
    static void oversizedBodyIsRefusedBeforeParsingAndNotExposed() {
        String huge = '{"correlationId":"' + CORRELATION + '","filler":"' + 'x'.repeat(9000)
            + '","leak":"Patient has a spinal injury"}'; // > 8192 chars, contains prose
        AttorneyApiService.CalloutOutcome o = sendWith(mockOf(200, huge));
        System.assertEquals(AttorneyApiService.Disposition.TRANSIENT_FAILURE, o.disposition);
        System.assertEquals(AttorneyReferralResponseValidator.INVALID_RESPONSE, o.errorCode);
        System.assertEquals('responseBody', o.failedCheck);
        System.assert(!JSON.serialize(o).contains('spinal injury'), 'oversized body content must never be exposed');
    }

    // ---- HTTP classification ----------------------------------------------

    @IsTest
    static void transientStatuses() {
        Map<Integer, String> cases = new Map<Integer, String>{
            429 => AttorneyApiService.RATE_LIMITED, 408 => AttorneyApiService.TIMEOUT,
            500 => AttorneyApiService.SERVER_ERROR, 502 => AttorneyApiService.SERVER_ERROR,
            503 => AttorneyApiService.SERVER_ERROR, 504 => AttorneyApiService.SERVER_ERROR,
            418 => AttorneyApiService.UNKNOWN
        };
        for (Integer code : cases.keySet()) {
            AttorneyApiService.CalloutOutcome o = sendWith(mockOf(code, '{"err":true}'));
            System.assertEquals(AttorneyApiService.Disposition.TRANSIENT_FAILURE, o.disposition, 'status ' + code);
            System.assertEquals(cases.get(code), o.errorCode, 'status ' + code);
        }
    }

    @IsTest
    static void permanentStatuses() {
        Map<Integer, String> cases = new Map<Integer, String>{
            400 => AttorneyApiService.VALIDATION_REJECTED, 401 => AttorneyApiService.UNAUTHORIZED,
            403 => AttorneyApiService.UNAUTHORIZED, 404 => AttorneyApiService.NOT_FOUND,
            409 => AttorneyApiService.CONFLICT
        };
        for (Integer code : cases.keySet()) {
            AttorneyApiService.CalloutOutcome o = sendWith(mockOf(code, '{"err":true}'));
            System.assertEquals(AttorneyApiService.Disposition.PERMANENT_FAILURE, o.disposition, 'status ' + code);
            System.assertEquals(cases.get(code), o.errorCode, 'status ' + code);
        }
    }

    @IsTest
    static void calloutExceptionIsTransientCalloutFailed() {
        AttorneyApiService.CalloutOutcome o = sendWith(mockThrowing());
        System.assertEquals(AttorneyApiService.Disposition.TRANSIENT_FAILURE, o.disposition);
        System.assertEquals(AttorneyApiService.CALLOUT_FAILED, o.errorCode);
        System.assertEquals(0, o.statusCode);
    }

    // ---- outbound request validation (no callout on a locally invalid request) --

    @IsTest
    static void invalidRequestMakesNoCalloutAndLogsNoValues() {
        AttorneyReferralRequest bad = request();
        bad.correlationId = 'not-a-uuid';
        Mock m = mockOf(201, successBody(CORRELATION));
        AttorneyApiService.CalloutOutcome o = send(m, bad);

        System.assertEquals(AttorneyApiService.Disposition.PERMANENT_FAILURE, o.disposition);
        System.assertEquals(AttorneyReferralRequestValidator.INVALID_REQUEST, o.errorCode);
        System.assertEquals('correlationId', o.failedCheck);
        System.assertEquals(0, o.statusCode);
        System.assertEquals(false, m.wasCalled, 'a locally invalid request must not make a callout');
        System.assert(!o.sanitizedRequest.contains('not-a-uuid'), 'the bad value must not be logged');
        System.assert(!o.sanitizedRequest.contains('a01000000000001AAA'), 'no request values are logged on invalid');
        System.assert(o.sanitizedRequest.contains('correlationId'), 'the failed check name is recorded');
    }

    @IsTest
    static void nullRequestIsInvalidRequestNoNpe() {
        Mock m = mockOf(201, successBody(CORRELATION));
        AttorneyApiService.CalloutOutcome o = send(m, null); // must not NPE
        System.assertEquals(AttorneyApiService.Disposition.PERMANENT_FAILURE, o.disposition);
        System.assertEquals(AttorneyReferralRequestValidator.INVALID_REQUEST, o.errorCode);
        System.assertEquals('request', o.failedCheck);
        System.assertEquals(false, m.wasCalled);
    }

    @IsTest
    static void nullClientIsInvalidRequest() {
        AttorneyReferralRequest r = request();
        r.client = null;
        AttorneyApiService.CalloutOutcome o = send(mockOf(201, successBody(CORRELATION)), r);
        System.assertEquals(AttorneyApiService.Disposition.PERMANENT_FAILURE, o.disposition);
        System.assertEquals('client', o.failedCheck);
    }

    // ---- the actual HTTP request is built to contract ----------------------

    @IsTest
    static void httpRequestIsBuiltToContract() {
        AttorneyReferralRequest r = request();
        r.client.email = null;        // optionals null -> must be omitted from the wire body
        r.client.phone = null;
        r.client.dateOfBirth = null;

        Mock m = mockOf(201, successBody(CORRELATION));
        send(m, r);

        System.assertEquals(true, m.wasCalled);
        System.assertEquals('callout:Attorney_API/services/apexrest/v1/referrals', m.captured.getEndpoint());
        System.assertEquals('POST', m.captured.getMethod());
        System.assertEquals('application/json', m.captured.getHeader('Content-Type'));
        // NOTE: Apex HttpRequest exposes setTimeout() but NO getTimeout(), so the 120000ms timeout
        // cannot be asserted off the captured request. It is set in AttorneyApiService.doCallout().

        Map<String, Object> body = (Map<String, Object>) JSON.deserializeUntyped(m.captured.getBody());
        System.assertEquals(new Set<String>{'correlationId', 'careConnectReferralId', 'referralType', 'client'},
            body.keySet(), 'wire body must carry exactly the contract top-level keys');
        Map<String, Object> client = (Map<String, Object>) body.get('client');
        System.assertEquals(new Set<String>{'careConnectContactId', 'fullName'}, client.keySet(),
            'null optional fields must be omitted (suppressApexObjectNulls) through the real service path');
    }

    // ---- value safety: neither PII nor prose in modeled fields reaches the log --

    @IsTest
    static void requestPiiBecomesPresenceBooleans() {
        String sr = sendWith(mockOf(201, successBody(CORRELATION))).sanitizedRequest;
        System.assert(!sr.contains('Jane Doe'), 'name value must not be logged');
        System.assert(!sr.contains('jane@example.com'), 'email value must not be logged');
        System.assert(!sr.contains('555-0100'), 'phone value must not be logged');
        System.assert(!sr.contains('1985-04-12'), 'DOB value must not be logged');
        System.assert(sr.contains('emailProvided'), 'presence flag retained');
        System.assert(sr.contains('a01000000000001AAA'), 'validated opaque referral id retained');
    }

    /** A merely-nonblank `status` passes validation but is arbitrary text — it must NOT be logged. */
    @IsTest
    static void nonblankStatusValueNeverReachesTheLog() {
        AttorneyApiService.CalloutOutcome o =
            sendWith(mockOf(200, successBodyWith(new Map<String, Object>{ 'status' => PROSE })));
        System.assertEquals(AttorneyApiService.Disposition.SUCCESS, o.disposition, 'nonblank status passes validation');
        String whole = JSON.serialize(o);
        System.assert(!whole.contains('spinal injury'), 'the raw status value must never appear in the outcome');
        System.assert(o.sanitizedResponse.contains('statusProvided'), 'status is logged as a presence flag only');
    }

    /** A 2xx whose modeled field carries prose that FAILS validation logs only status + check. */
    @IsTest
    static void invalidModeledValueIsNotExposed() {
        AttorneyApiService.CalloutOutcome o =
            sendWith(mockOf(200, successBodyWith(new Map<String, Object>{ 'attorneyCaseId' => PROSE })));
        System.assertEquals(AttorneyApiService.Disposition.TRANSIENT_FAILURE, o.disposition);
        System.assertEquals('attorneyCaseId', o.failedCheck);
        System.assert(!JSON.serialize(o).contains('spinal injury'), 'the failing modeled value must not be exposed');
        System.assert(o.sanitizedResponse.contains('failedCheck'), 'only the failed check is recorded');
    }

    @IsTest
    static void unmodeledResponseFieldsAreNotExposedByOutcome() {
        String body = successBodyWith(new Map<String, Object>{
            'message' => 'Patient Jane Doe diagnosed with a spinal injury', // unmodeled, PHI-like
            'clientRecordId' => 'a01000000000009AAA',                        // unmodeled
            'serverNote' => 'internal-secret-token-xyz'                      // unmodeled
        });
        AttorneyApiService.CalloutOutcome o = sendWith(mockOf(201, body));
        System.assertEquals(AttorneyApiService.Disposition.SUCCESS, o.disposition);
        String whole = JSON.serialize(o);
        System.assert(!whole.contains('spinal injury'), 'unmodeled message must never appear');
        System.assert(!whole.contains('internal-secret-token'), 'unmodeled server note must never appear');
        System.assert(!whole.contains('a01000000000009AAA'), 'unmodeled clientRecordId must never appear');
        System.assert(o.sanitizedResponse.contains(CASE_UUID), 'validated attorneyCaseId is logged');
    }

    @IsTest
    static void errorResponseBodyIsNotExposedByOutcome() {
        String errBody = JSON.serialize(new Map<String, Object>{
            'success' => false, 'errorCode' => 'VALIDATION_ERROR',
            'message' => 'careConnectReferralId rejected: SECRET-VALUE-123'});
        AttorneyApiService.CalloutOutcome o = sendWith(mockOf(400, errBody));
        System.assertEquals(AttorneyApiService.Disposition.PERMANENT_FAILURE, o.disposition);
        System.assert(!o.sanitizedResponse.contains('SECRET-VALUE-123'), 'non-2xx body content must not be exposed');
        System.assert(o.sanitizedResponse.contains('400'), 'only the controlled status is recorded');
    }

    @IsTest
    static void immutableOutcomeContract() {
        AttorneyApiService.CalloutOutcome o = sendWith(mockOf(201, successBody(CORRELATION)));
        System.assertNotEquals(null, o.disposition);
        System.assertNotEquals(null, o.sanitizedRequest);
        System.assertNotEquals(null, o.sanitizedResponse);
    }
}
