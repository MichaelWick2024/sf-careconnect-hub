@IsTest
private class AttorneyReferralRequestTest {

    private static AttorneyReferralRequest fullyPopulated() {
        AttorneyReferralRequest r = new AttorneyReferralRequest();
        r.correlationId = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';
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

    /**
     * THE CONTRACT GUARD. The Attorney inbound endpoint validates a fixed set of keys; the Apex
     * field names here are those keys on the wire. This asserts the serialized shape is EXACTLY
     * the contract — no missing key, no extra key — so a field rename fails the build instead of
     * silently breaking the integration in the other org.
     */
    @IsTest
    static void serializedShapeIsExactlyTheAttorneyContract() {
        // NB: not named `json` — Apex identifiers are case-insensitive, so a local `json`
        // shadows the `JSON` system class (the same trap Uuid.cls documents).
        String serialized = JSON.serialize(fullyPopulated());
        Map<String, Object> top = (Map<String, Object>) JSON.deserializeUntyped(serialized);

        System.assertEquals(
            new Set<String>{'correlationId', 'careConnectReferralId', 'referralType', 'client'},
            top.keySet(),
            'outbound top-level keys must match the Attorney contract exactly (no priority — the '
            + 'receiver ignores it, so it is not part of the contract)');

        Map<String, Object> client = (Map<String, Object>) top.get('client');
        System.assertEquals(
            new Set<String>{'careConnectContactId', 'fullName', 'email', 'phone', 'dateOfBirth'},
            client.keySet(),
            'outbound client keys must match the Attorney contract exactly');
    }

    /** Values must survive serialization unchanged — the receiver reads these verbatim. */
    @IsTest
    static void valuesSerializeVerbatim() {
        Map<String, Object> top = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(fullyPopulated()));
        System.assertEquals('aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee', top.get('correlationId'));
        System.assertEquals('a01000000000001AAA', top.get('careConnectReferralId'));
        System.assertEquals('Personal Injury', top.get('referralType'));
        Map<String, Object> client = (Map<String, Object>) top.get('client');
        System.assertEquals('003000000000001AAA', client.get('careConnectContactId'));
        System.assertEquals('jane@example.com', client.get('email'));
    }

    /**
     * The outbound service serializes with suppressApexObjectNulls = true, so optional fields
     * that were not provided are omitted rather than sent as null. This builds a genuinely
     * minimal, required-only referral (only correlationId, careConnectReferralId, referralType
     * and the two required client fields) and confirms the wire payload carries no null noise.
     */
    @IsTest
    static void nullOptionalsAreOmittedWhenSuppressed() {
        AttorneyReferralRequest r = fullyPopulated();
        r.client.email = null;
        r.client.phone = null;
        r.client.dateOfBirth = null;

        Map<String, Object> top = (Map<String, Object>) JSON.deserializeUntyped(JSON.serialize(r, true));
        System.assertEquals(new Set<String>{'correlationId', 'careConnectReferralId', 'referralType', 'client'},
            top.keySet(), 'a required-only referral carries no null top-level fields');

        Map<String, Object> client = (Map<String, Object>) top.get('client');
        System.assertEquals(new Set<String>{'careConnectContactId', 'fullName'}, client.keySet(),
            'null optionals must be omitted from the wire payload when nulls are suppressed');
    }

    /** Round-trip through the contract must reconstruct an equivalent object. */
    @IsTest
    static void roundTripReconstructsEquivalent() {
        AttorneyReferralRequest original = fullyPopulated();
        AttorneyReferralRequest back =
            (AttorneyReferralRequest) JSON.deserialize(JSON.serialize(original), AttorneyReferralRequest.class);

        System.assertEquals(original.correlationId, back.correlationId);
        System.assertEquals(original.careConnectReferralId, back.careConnectReferralId);
        System.assertEquals(original.referralType, back.referralType);
        System.assertEquals(original.client.careConnectContactId, back.client.careConnectContactId);
        System.assertEquals(original.client.dateOfBirth, back.client.dateOfBirth);
    }
}
