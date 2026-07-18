/**
 * Owns the outbound callout to the Attorney inbound endpoint: pre-callout request validation,
 * serialization, the HTTP send via a Named Credential, response parsing, response validation
 * (delegated to AttorneyReferralResponseValidator), and HTTP → controlled-error classification.
 *
 * Returns a controlled CalloutOutcome. It does NOT write Integration_Transmission__c or
 * Integration_Log__c — the callout Queueable / state machine consumes the outcome and persists.
 *
 * VALUE SAFETY, not just key safety — the whole point of the logging discipline here:
 *   - Nothing derived from the request or response reaches `sanitizedRequest`/`sanitizedResponse`
 *     until it has been STRUCTURALLY VALIDATED into an opaque/controlled form. Allowlisting field
 *     names is not enough; a modeled field can still carry prose (e.g. a merely-nonblank `status`).
 *   - Request: validated locally FIRST. Only then are its opaque ids / controlled type logged, and
 *     PII becomes presence booleans. An invalid request logs only the failed check name — no values.
 *   - Response: the raw body is touched once, only to deserialize. On success we log only the
 *     validated opaque ids + `statusProvided` (a presence boolean, because `status` is only
 *     nonblank-validated). On an invalid 2xx we log the status + failed check — never a remote value.
 *     A non-2xx / unparseable / callout failure logs the controlled HTTP status only.
 *
 * Live auth configuration is split across orgs:
 *   - The Connected App (OAuth Client Credentials) lives in the ATTORNEY (target) org.
 *   - The External Credential + Named Credential `Attorney_API` live in THIS (Care Connect, calling)
 *     org and define the endpoint + auth used by Apex here.
 * Both are config prerequisites, not part of this class. Tests use HttpCalloutMock; no live credential.
 */
public with sharing class AttorneyApiService {

    private static final String ENDPOINT = 'callout:Attorney_API/services/apexrest/v1/referrals';
    private static final Integer TIMEOUT_MS = 120000; // max; must stay below the sweep's STALE_AFTER

    // Ceiling on the response body we will parse. A Queueable can receive up to 12 MB and both the
    // request and response count against heap; the legal Attorney response is a few hundred chars
    // (ids + status + errorCode + keys), so 8192 is generous headroom while refusing anything that
    // could only be abuse or a bug. Enforced BEFORE deserialization — that is the heap risk.
    private static final Integer MAX_RESPONSE_BODY_CHARS = 8192;

    // Controlled error vocabulary (transmission spec). INVALID_REQUEST / INVALID_RESPONSE are owned
    // by their validators.
    public static final String RATE_LIMITED = 'RATE_LIMITED';
    public static final String SERVER_ERROR = 'SERVER_ERROR';
    public static final String TIMEOUT = 'TIMEOUT';
    public static final String CALLOUT_FAILED = 'CALLOUT_FAILED';
    public static final String VALIDATION_REJECTED = 'VALIDATION_REJECTED';
    public static final String UNAUTHORIZED = 'UNAUTHORIZED';
    public static final String NOT_FOUND = 'NOT_FOUND';
    public static final String CONFLICT = 'CONFLICT';
    public static final String UNKNOWN = 'UNKNOWN';

    public enum Disposition { SUCCESS, TRANSIENT_FAILURE, PERMANENT_FAILURE }

    /** Immutable result — only sendReferral() can produce one. */
    public class CalloutOutcome {
        public Disposition disposition { get; private set; }
        public Integer statusCode { get; private set; }            // 0 if no HTTP response
        public String errorCode { get; private set; }              // null on SUCCESS
        public String failedCheck { get; private set; }            // set on INVALID_REQUEST / INVALID_RESPONSE
        public String attorneyCaseId { get; private set; }         // SUCCESS only; validated v4
        public String attorneyCaseRecordId { get; private set; }   // SUCCESS only; validated null-or-18
        public String sanitizedRequest { get; private set; }       // value-safe; safe to log
        public String sanitizedResponse { get; private set; }      // value-safe; never the raw body
        public Integer executionTimeMs { get; private set; }
        private CalloutOutcome() {}
    }

    public static CalloutOutcome sendReferral(AttorneyReferralRequest request) {
        Long start = System.currentTimeMillis();
        CalloutOutcome o = new CalloutOutcome();

        // 1. Validate locally BEFORE anything is sent or logged. A request we built wrong is a
        //    permanent programming error — no callout, and no values reach the log.
        AttorneyReferralRequestValidator.Result rv = AttorneyReferralRequestValidator.validate(request);
        if (!rv.isValid) {
            o.disposition = Disposition.PERMANENT_FAILURE;
            o.errorCode = rv.errorCode; // INVALID_REQUEST
            o.failedCheck = rv.failedCheck;
            o.statusCode = 0;
            o.sanitizedRequest = invalidRequestLog(rv.failedCheck); // failed check only; no values
            o.sanitizedResponse = statusOnly(0);
            o.executionTimeMs = elapsed(start);
            return o;
        }

        // Request is valid -> its opaque ids / controlled type are safe to log; PII -> presence flags.
        o.sanitizedRequest = validRequestLog(request);

        HttpResponse response;
        try {
            response = doCallout(request);
        } catch (System.CalloutException ce) {
            o.disposition = Disposition.TRANSIENT_FAILURE;
            o.errorCode = CALLOUT_FAILED;       // any thrown CalloutException, incl. client-side timeout
            o.statusCode = 0;
            o.sanitizedResponse = statusOnly(0);
            o.executionTimeMs = elapsed(start);
            return o;
        }

        o.statusCode = response.getStatusCode();
        if (o.statusCode >= 200 && o.statusCode < 300) {
            classifyTwoXx(o, request, response);
        } else {
            classifyErrorStatus(o);
            o.sanitizedResponse = statusOnly(o.statusCode); // raw body never inspected or logged
        }
        o.executionTimeMs = elapsed(start);
        return o;
    }

    // ---- callout -----------------------------------------------------------

    private static HttpResponse doCallout(AttorneyReferralRequest request) {
        HttpRequest req = new HttpRequest();
        req.setEndpoint(ENDPOINT);
        req.setMethod('POST');
        req.setHeader('Content-Type', 'application/json');
        req.setTimeout(TIMEOUT_MS);
        // suppressApexObjectNulls = true -> optional fields omitted rather than sent as null
        req.setBody(JSON.serialize(request, true));
        return new Http().send(req);
    }

    // ---- classification ----------------------------------------------------

    private static void classifyTwoXx(CalloutOutcome o, AttorneyReferralRequest request, HttpResponse response) {
        String body = response.getBody();

        // Bound the body BEFORE parsing (the heap risk). Blank or oversized -> INVALID_RESPONSE.
        if (String.isBlank(body) || body.length() > MAX_RESPONSE_BODY_CHARS) {
            failInvalidResponse(o, 'responseBody'); // no body content is inspected or logged
            return;
        }

        AttorneyReferralResponse parsed;
        try {
            // The ONLY place the raw body is touched. Only the typed object survives.
            parsed = (AttorneyReferralResponse) JSON.deserialize(body, AttorneyReferralResponse.class);
        } catch (Exception parseError) {
            failInvalidResponse(o, 'responseBody'); // unparseable -> nothing derived is logged
            return;
        }

        AttorneyReferralResponseValidator.Result v =
            AttorneyReferralResponseValidator.validate(parsed, request.correlationId);

        if (!v.isValid) {
            // No remote values — only the controlled status and which check failed.
            failInvalidResponse(o, v.failedCheck);
            return;
        }

        o.disposition = Disposition.SUCCESS;
        o.attorneyCaseId = parsed.attorneyCaseId;             // validated v4
        o.attorneyCaseRecordId = parsed.attorneyCaseRecordId; // validated null-or-18
        o.sanitizedResponse = successResponseLog(parsed);     // only validated opaque values + presence
    }

    private static void classifyErrorStatus(CalloutOutcome o) {
        Integer s = o.statusCode;
        if (s == 429) {
            o.errorCode = RATE_LIMITED;        o.disposition = Disposition.TRANSIENT_FAILURE;
        } else if (s == 408) {
            o.errorCode = TIMEOUT;             o.disposition = Disposition.TRANSIENT_FAILURE;
        } else if (s == 500 || s == 502 || s == 503 || s == 504) {
            o.errorCode = SERVER_ERROR;        o.disposition = Disposition.TRANSIENT_FAILURE;
        } else if (s == 400) {
            o.errorCode = VALIDATION_REJECTED; o.disposition = Disposition.PERMANENT_FAILURE;
        } else if (s == 401 || s == 403) {
            o.errorCode = UNAUTHORIZED;        o.disposition = Disposition.PERMANENT_FAILURE;
        } else if (s == 404) {
            o.errorCode = NOT_FOUND;           o.disposition = Disposition.PERMANENT_FAILURE;
        } else if (s == 409) {
            o.errorCode = CONFLICT;            o.disposition = Disposition.PERMANENT_FAILURE;
        } else {
            o.errorCode = UNKNOWN;             o.disposition = Disposition.TRANSIENT_FAILURE;
        }
    }

    private static void failInvalidResponse(CalloutOutcome o, String failedCheck) {
        o.disposition = Disposition.TRANSIENT_FAILURE; // INVALID_RESPONSE is safe to retry
        o.errorCode = AttorneyReferralResponseValidator.INVALID_RESPONSE;
        o.failedCheck = failedCheck;
        o.sanitizedResponse = invalidResponseLog(o.statusCode, failedCheck);
    }

    // ---- value-safe log payloads -------------------------------------------
    // Only structurally-validated (opaque / controlled) values ever appear here. PII and any
    // merely-nonblank remote text become presence booleans; nothing is a raw remote value.

    private static String validRequestLog(AttorneyReferralRequest r) {
        Map<String, Object> safe = new Map<String, Object>{
            'correlationId' => r.correlationId,                 // validated v4
            'careConnectReferralId' => r.careConnectReferralId, // validated 18-char
            'referralType' => r.referralType                    // validated controlled vocabulary
        };
        safe.put('client', new Map<String, Object>{
            'careConnectContactId' => r.client.careConnectContactId, // validated 18-char 003
            'fullNameProvided' => String.isNotBlank(r.client.fullName),
            'emailProvided' => String.isNotBlank(r.client.email),
            'phoneProvided' => String.isNotBlank(r.client.phone),
            'dateOfBirthProvided' => String.isNotBlank(r.client.dateOfBirth)
        });
        return JSON.serialize(safe);
    }

    private static String invalidRequestLog(String failedCheck) {
        return JSON.serialize(new Map<String, Object>{ 'invalidRequest' => failedCheck });
    }

    private static String successResponseLog(AttorneyReferralResponse r) {
        return JSON.serialize(new Map<String, Object>{
            'correlationId' => r.correlationId,               // validated == our transmission id
            'success' => r.success,                           // validated true
            'attorneyCaseId' => r.attorneyCaseId,             // validated v4
            'attorneyCaseRecordId' => r.attorneyCaseRecordId, // validated null-or-18
            'statusProvided' => String.isNotBlank(r.status)   // presence only — status is merely nonblank
            // NB: the remote `errorCode` and the raw `status` value are deliberately NOT logged.
        });
    }

    private static String invalidResponseLog(Integer status, String failedCheck) {
        return JSON.serialize(new Map<String, Object>{ 'httpStatus' => status, 'failedCheck' => failedCheck });
    }

    private static String statusOnly(Integer status) {
        return JSON.serialize(new Map<String, Object>{ 'httpStatus' => status, 'note' => 'raw body not logged' });
    }

    private static Integer elapsed(Long start) {
        return (Integer) (System.currentTimeMillis() - start);
    }
}
