@IsTest
private class AttorneyReferralResponseTest {

    /**
     * Representative success body in the exact shape verified against a real 201 response during
     * Attorney inbound development. All values below are fabricated test data.
     *
     * clientRecordId is included because the Attorney endpoint really does return it — but
     * AttorneyReferralResponse deliberately does not model it, so this fixture also demonstrates
     * that a real-but-unmodeled field is silently ignored on deserialization.
     */
    private static final String SUCCESS_JSON =
        '{"correlationId":"aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee",'
      + '"success":true,'
      + '"attorneyCaseId":"11111111-2222-4333-8444-555555555555",'
      + '"attorneyCaseRecordId":"a00000000000001AAA",'
      + '"clientRecordId":"a01000000000001AAA",'
      + '"status":"Open","message":"Created","errorCode":null}';

    @IsTest
    static void deserializesSuccessResponse() {
        AttorneyReferralResponse r =
            (AttorneyReferralResponse) JSON.deserialize(SUCCESS_JSON, AttorneyReferralResponse.class);

        System.assertEquals(true, r.success);
        System.assertEquals('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', r.correlationId);
        System.assertEquals('11111111-2222-4333-8444-555555555555', r.attorneyCaseId, 'the durable contract id');
        System.assertEquals('a00000000000001AAA', r.attorneyCaseRecordId, 'diagnostics only');
        System.assertEquals('Open', r.status, 'status is present on a success (step 7 requires nonblank)');
        System.assertEquals(null, r.errorCode);
        // `message` is present in the fixture but not modeled — see ignoresUnmodeledMessageField.
    }

    @IsTest
    static void deserializesValidationErrorResponse() {
        String errorJson =
            '{"correlationId":null,"success":false,"errorCode":"VALIDATION_ERROR",'
          + '"message":"referralType must be one of: Personal Injury, Workers Compensation, '
          + 'Medical Malpractice, General.","attorneyCaseId":null,"attorneyCaseRecordId":null,'
          + '"clientRecordId":null,"status":null}';

        AttorneyReferralResponse r =
            (AttorneyReferralResponse) JSON.deserialize(errorJson, AttorneyReferralResponse.class);

        System.assertEquals(false, r.success);
        System.assertEquals('VALIDATION_ERROR', r.errorCode, 'controlled failure category — this drives outcome, not the remote message');
        System.assertEquals(null, r.attorneyCaseId, 'no contract id on a rejected referral');
    }

    /**
     * Proves that a populated remote `message` does not bind to the typed response contract — it is
     * not modeled, so DTO-driven code cannot read it.
     *
     * This test does NOT prove logging safety. The raw HTTP body still exists before deserialization,
     * so the outbound logging path must INDEPENDENTLY omit raw response bodies and build logs from an
     * allowlist. Omitting the property protects only the typed-consumption path.
     */
    @IsTest
    static void ignoresUnmodeledMessageField() {
        String withMessage =
            '{"success":true,"attorneyCaseId":"11111111-2222-4333-8444-555555555555","status":"Open",'
          + '"message":"Created"}';
        AttorneyReferralResponse r =
            (AttorneyReferralResponse) JSON.deserialize(withMessage, AttorneyReferralResponse.class);
        System.assertEquals(true, r.success);
        System.assertEquals('Open', r.status);
        // No r.message to read — the field does not exist on the DTO, which is the point.
    }

    /**
     * Forward compatibility: the Attorney side may add response fields. JSON.deserialize ignores
     * unknown keys, so an added field must neither throw nor disturb the known ones. This is why
     * lenient (not strict) deserialization is the deliberate choice.
     */
    @IsTest
    static void ignoresUnknownResponseFields() {
        String withExtra =
            '{"success":true,"attorneyCaseId":"11111111-2222-4333-8444-555555555555",'
          + '"serverRegion":"us-east","processedAtEpoch":1710000000}'; // last two are unknown

        AttorneyReferralResponse r =
            (AttorneyReferralResponse) JSON.deserialize(withExtra, AttorneyReferralResponse.class);

        System.assertEquals(true, r.success);
        System.assertEquals('11111111-2222-4333-8444-555555555555', r.attorneyCaseId);
    }

    /** A missing optional key deserializes to null, not an error. */
    @IsTest
    static void missingKeysDeserializeToNull() {
        AttorneyReferralResponse r =
            (AttorneyReferralResponse) JSON.deserialize('{"success":true}', AttorneyReferralResponse.class);
        System.assertEquals(true, r.success);
        System.assertEquals(null, r.attorneyCaseId);
        System.assertEquals(null, r.status);
    }
}
