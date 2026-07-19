/**
 * Validates an outbound AttorneyReferralRequest BEFORE the callout. Producer-side enforcement of the
 * same contract the Attorney inbound endpoint validates on receipt — so a request our own code built
 * wrong is rejected locally (no wasted callout) and, critically, so the values that reach the
 * outbound log are individually structurally validated rather than trusted.
 *
 * A locally invalid request is a programming error on our side; retrying it unchanged cannot help,
 * so the caller treats INVALID_REQUEST as PERMANENT and makes no callout.
 *
 * Scope: validates the TYPED request only. Messages/`failedCheck` are controlled field names, never
 * values. v4 / id logic is inlined (matching the inbound validator pattern) so `Uuid.cls` stays a
 * byte-identical cross-org copy per ADR-011.
 */
public with sharing class AttorneyReferralRequestValidator {

    /** Controlled error code (permanent). Owned here, referenced by AttorneyApiService. */
    public static final String INVALID_REQUEST = 'INVALID_REQUEST';

    // Must stay in sync with Care Connect's restricted Referral__c.Referral_Type__c picklist.
    // AttorneyReferralRequestValidatorTest guards against drift (a metadata change here would
    // otherwise surface as repeated permanent INVALID_REQUEST failures in production).
    @TestVisible
    private static final Set<String> VALID_REFERRAL_TYPES = new Set<String>{
        'Personal Injury', 'Workers Compensation', 'Medical Malpractice', 'General'
    };
    private static final Pattern UUID_V4 = Pattern.compile(
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
    );
    private static final Pattern ISO_DATE = Pattern.compile('^\\d{4}-\\d{2}-\\d{2}$');
    private static final Integer SF_ID_LENGTH = 18;
    private static final String CONTACT_KEY_PREFIX = '003'; // Contact is a standard object -> stable
    private static final Integer LEN_NAME = 80;
    private static final Integer LEN_EMAIL = 80;
    private static final Integer LEN_PHONE = 40;

    public class Result {
        public Boolean isValid { get; private set; }
        public String errorCode { get; private set; }   // null when valid; INVALID_REQUEST otherwise
        public String failedCheck { get; private set; } // null when valid; controlled field name, never a value
        private Result(Boolean isValid, String errorCode, String failedCheck) {
            this.isValid = isValid;
            this.errorCode = errorCode;
            this.failedCheck = failedCheck;
        }
    }

    public static Result validate(AttorneyReferralRequest req) {
        if (req == null) {
            return invalid('request');
        }
        if (!isV4Uuid(req.correlationId)) {
            return invalid('correlationId');
        }
        // Our own Referral__c id. Checksum-validated; NO prefix check (custom prefixes are per-org).
        if (!isValidSalesforceId(req.careConnectReferralId, null)) {
            return invalid('careConnectReferralId');
        }
        if (String.isBlank(req.referralType) || !VALID_REFERRAL_TYPES.contains(req.referralType)) {
            return invalid('referralType');
        }
        if (req.client == null) {
            return invalid('client');
        }
        // Contact is a standard object -> 003 prefix is asserted.
        if (!isValidSalesforceId(req.client.careConnectContactId, CONTACT_KEY_PREFIX)) {
            return invalid('careConnectContactId');
        }
        if (String.isBlank(req.client.fullName) || req.client.fullName.length() > LEN_NAME) {
            return invalid('fullName');
        }
        if (req.client.email != null && req.client.email.length() > LEN_EMAIL) {
            return invalid('email');
        }
        if (req.client.phone != null && req.client.phone.length() > LEN_PHONE) {
            return invalid('phone');
        }
        if (!isBlankOrValidIsoDate(req.client.dateOfBirth)) {
            return invalid('dateOfBirth');
        }
        return new Result(true, null, null);
    }

    // ---- helpers -----------------------------------------------------------

    private static Result invalid(String failedCheck) {
        return new Result(false, INVALID_REQUEST, failedCheck);
    }

    private static Boolean isV4Uuid(String value) {
        return String.isNotBlank(value) && UUID_V4.matcher(value).matches();
    }

    private static Boolean isValidSalesforceId(String value, String requiredPrefix) {
        if (String.isBlank(value) || value.length() != SF_ID_LENGTH) {
            return false;
        }
        try {
            Id.valueOf(value); // charset + checksum
        } catch (Exception e) {
            return false;
        }
        return requiredPrefix == null || value.startsWith(requiredPrefix);
    }

    private static Boolean isBlankOrValidIsoDate(String value) {
        if (String.isBlank(value)) {
            return true; // optional
        }
        if (!ISO_DATE.matcher(value).matches()) {
            return false;
        }
        try {
            Date.valueOf(value); // rejects impossible calendar dates
            return true;
        } catch (Exception e) {
            return false;
        }
    }
}
