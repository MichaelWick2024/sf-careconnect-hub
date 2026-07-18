@IsTest
private class AttorneyReferralRequestValidatorTest {

    private static AttorneyReferralRequest valid() {
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

    private static void assertFails(AttorneyReferralRequest r, String expectedCheck) {
        AttorneyReferralRequestValidator.Result res = AttorneyReferralRequestValidator.validate(r);
        System.assertEquals(false, res.isValid, 'expected invalid for ' + expectedCheck);
        System.assertEquals(AttorneyReferralRequestValidator.INVALID_REQUEST, res.errorCode);
        System.assertEquals(expectedCheck, res.failedCheck);
    }

    @IsTest
    static void validRequestPasses() {
        AttorneyReferralRequestValidator.Result res = AttorneyReferralRequestValidator.validate(valid());
        System.assertEquals(true, res.isValid);
        System.assertEquals(null, res.errorCode);
        System.assertEquals(null, res.failedCheck);
    }

    @IsTest
    static void nullRequestFails() {
        assertFails(null, 'request');
    }

    @IsTest
    static void correlationIdMustBeV4() {
        for (String bad : new List<String>{ null, '', 'Patient Jane Doe has cancer',
                '11111111-1111-1111-8111-111111111111' /* v1 */ }) {
            AttorneyReferralRequest r = valid();
            r.correlationId = bad;
            assertFails(r, 'correlationId');
        }
    }

    @IsTest
    static void referralIdMustBe18CharChecksum() {
        for (String bad : new List<String>{ null, 'a01000000000000', 'a01000000000000ZZZ',
                'Patient Jane Doe!!' }) {
            AttorneyReferralRequest r = valid();
            r.careConnectReferralId = bad;
            assertFails(r, 'careConnectReferralId');
        }
    }

    @IsTest
    static void referralIdAcceptsAnyPrefix() {
        // Our own Referral__c id: custom prefix, not asserted.
        for (String prefix : new List<String>{ 'a01', 'a03', 'a99' }) {
            AttorneyReferralRequest r = valid();
            r.careConnectReferralId = String.valueOf(Id.valueOf(prefix + '000000000001'));
            System.assertEquals(true, AttorneyReferralRequestValidator.validate(r).isValid);
        }
    }

    @IsTest
    static void referralTypeMustBeSupported() {
        for (String bad : new List<String>{ null, '', 'Bogus' }) {
            AttorneyReferralRequest r = valid();
            r.referralType = bad;
            assertFails(r, 'referralType');
        }
    }

    @IsTest
    static void clientRequired() {
        AttorneyReferralRequest r = valid();
        r.client = null;
        assertFails(r, 'client');
    }

    @IsTest
    static void contactIdMustBe18CharWith003Prefix() {
        AttorneyReferralRequest r = valid();
        r.client.careConnectContactId = 'Jane Doe the patien'; // 19 chars prose
        assertFails(r, 'careConnectContactId');

        r = valid();
        r.client.careConnectContactId = String.valueOf(Id.valueOf('001' + '000000000001')); // Account
        assertFails(r, 'careConnectContactId');
    }

    @IsTest
    static void fullNameRequiredAndBounded() {
        AttorneyReferralRequest r = valid();
        r.client.fullName = '';
        assertFails(r, 'fullName');

        r = valid();
        r.client.fullName = 'n'.repeat(81);
        assertFails(r, 'fullName');
    }

    @IsTest
    static void emailAndPhoneBounded() {
        AttorneyReferralRequest r = valid();
        r.client.email = 'e'.repeat(81);
        assertFails(r, 'email');

        r = valid();
        r.client.phone = 'p'.repeat(41);
        assertFails(r, 'phone');
    }

    @IsTest
    static void dateOfBirthOptionalButValidatedWhenPresent() {
        AttorneyReferralRequest r = valid();
        r.client.dateOfBirth = null; // optional
        System.assertEquals(true, AttorneyReferralRequestValidator.validate(r).isValid);

        r = valid();
        r.client.dateOfBirth = '04/12/1985'; // wrong format
        assertFails(r, 'dateOfBirth');

        r = valid();
        r.client.dateOfBirth = '1985-13-45'; // impossible date
        assertFails(r, 'dateOfBirth');
    }

    /**
     * Drift guard: the validator's referral-type contract must equal the active
     * Referral__c.Referral_Type__c restricted picklist. A label rename leaves the API values
     * unchanged (test passes); adding/removing/renaming an API value fails the build, before it
     * could reach production as repeated permanent INVALID_REQUEST failures.
     *
     * (Cross-repository drift with the Attorney org is a separate, documented duplicated-contract
     * risk this cannot cover — it only guards Care Connect's own metadata.)
     */
    @IsTest
    static void referralTypeContractMatchesPicklist() {
        Set<String> picklist = new Set<String>();
        for (Schema.PicklistEntry e : Schema.SObjectType.Referral__c.fields.Referral_Type__c.getPicklistValues()) {
            if (e.isActive()) {
                picklist.add(e.getValue());
            }
        }
        System.assertEquals(picklist, AttorneyReferralRequestValidator.VALID_REFERRAL_TYPES,
            'AttorneyReferralRequestValidator.VALID_REFERRAL_TYPES has drifted from '
            + 'Referral__c.Referral_Type__c — a metadata change would cause permanent INVALID_REQUEST.');
    }

    @IsTest
    static void failedCheckNeverEchoesAValue() {
        AttorneyReferralRequest r = valid();
        r.correlationId = 'Patient Jane Doe has cancer';
        AttorneyReferralRequestValidator.Result res = AttorneyReferralRequestValidator.validate(r);
        System.assertEquals('correlationId', res.failedCheck);
        System.assert(!res.failedCheck.contains('Jane Doe'), 'failedCheck must never echo a value');
    }
}
