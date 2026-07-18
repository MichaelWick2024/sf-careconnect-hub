/**
 * Validates a deserialized Attorney response before any Attorney identifier is persisted.
 *
 * Step 7 of the outbound sequence. Enforces the FIVE normative checks from the transmission spec's
 * response-validation table. A 2xx status is not enough — the receiver's body must actually confirm
 * success and carry well-formed identifiers, or the transmission is treated as INVALID_RESPONSE
 * (transient: retried, because Attorney inbound is idempotent by Care Connect referral Id).
 *
 * SCOPE — read before extending:
 *   - This validates the TYPED response (AttorneyReferralResponse) only. It performs no logging and
 *     never touches the raw HTTP body. Raw-response logging safety is the API service's separate
 *     responsibility (never persist the raw body; build logs from an allowlist).
 *   - `Result.failedCheck` names WHICH check failed for diagnostics. It is a controlled field name,
 *     never a value from the response, so it is safe to record. `errorCode` is the controlled
 *     `INVALID_RESPONSE` from the transmission vocabulary.
 *   - `attorneyCaseRecordId` is validated for shape only (null or a checksum-valid 18-char Id). Its
 *     key prefix is NOT checked — it belongs to a foreign org whose custom prefixes we cannot assume.
 */
public with sharing class AttorneyReferralResponseValidator {

    /** Controlled error code (matches Integration_Transmission__c.Last_Error_Code__c vocabulary). */
    public static final String INVALID_RESPONSE = 'INVALID_RESPONSE';

    // Specifically version 4 — the identifier our integration generates and requires. Same contract
    // the inbound side enforces; kept local per the existing validator pattern (Uuid.cls stays a
    // byte-identical cross-org copy and gains no consumer-specific methods).
    private static final Pattern UUID_V4 = Pattern.compile(
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
    );

    private static final Integer SF_ID_LENGTH = 18;

    /**
     * Immutable outcome. Fields are read-only to callers (private setters), so the controlled-result
     * contract — only `validate()` can produce a Result, and it only emits controlled values — is
     * encoded structurally, not merely by convention. A caller cannot flip `isValid` after the fact.
     */
    public class Result {
        public Boolean isValid { get; private set; }
        public String errorCode { get; private set; }   // null when valid; INVALID_RESPONSE otherwise
        public String failedCheck { get; private set; } // null when valid; controlled check name, never a response value
        private Result(Boolean isValid, String errorCode, String failedCheck) {
            this.isValid = isValid;
            this.errorCode = errorCode;
            this.failedCheck = failedCheck;
        }
    }

    /**
     * @param response              the deserialized Attorney response (untrusted remote input)
     * @param expectedCorrelationId the transmission's Correlation_Id__c the response must echo
     */
    public static Result validate(AttorneyReferralResponse response, String expectedCorrelationId) {
        if (response == null) {
            return invalid('response');
        }
        // 1. success == true  (Boolean may be null -> not true -> fail)
        if (response.success != true) {
            return invalid('success');
        }
        // 2. correlationId matches the transmission's id exactly
        if (String.isBlank(expectedCorrelationId) || !expectedCorrelationId.equals(response.correlationId)) {
            return invalid('correlationId');
        }
        // 3. attorneyCaseId is a v4 UUID
        if (!isV4Uuid(response.attorneyCaseId)) {
            return invalid('attorneyCaseId');
        }
        // 4. attorneyCaseRecordId is null OR a checksum-valid 18-char Salesforce Id (no prefix check)
        if (!isNullOrValidSalesforceId(response.attorneyCaseRecordId)) {
            return invalid('attorneyCaseRecordId');
        }
        // 5. status is nonblank (present with a real value, not null/""/whitespace)
        if (String.isBlank(response.status)) {
            return invalid('status');
        }
        return new Result(true, null, null);
    }

    // ---- helpers -----------------------------------------------------------

    private static Result invalid(String failedCheck) {
        return new Result(false, INVALID_RESPONSE, failedCheck);
    }

    private static Boolean isV4Uuid(String value) {
        return String.isNotBlank(value) && UUID_V4.matcher(value).matches();
    }

    private static Boolean isNullOrValidSalesforceId(String value) {
        if (value == null) {
            return true; // null is explicitly allowed
        }
        if (value.length() != SF_ID_LENGTH) {
            return false; // 18 exactly; "" and 15-char forms fail here
        }
        try {
            Id.valueOf(value); // validates charset + checksum
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}
