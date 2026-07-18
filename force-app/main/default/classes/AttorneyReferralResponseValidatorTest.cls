@IsTest
private class AttorneyReferralResponseValidatorTest {

    private static final String CORRELATION = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

    /** A response that passes all five checks. */
    private static AttorneyReferralResponse valid() {
        AttorneyReferralResponse r = new AttorneyReferralResponse();
        r.success = true;
        r.correlationId = CORRELATION;
        r.attorneyCaseId = '11111111-2222-4333-8444-555555555555'; // v4
        r.attorneyCaseRecordId = 'a00000000000001AAA';             // checksum-valid 18-char
        r.status = 'Open';
        return r;
    }

    private static AttorneyReferralResponseValidator.Result run(AttorneyReferralResponse r) {
        return AttorneyReferralResponseValidator.validate(r, CORRELATION);
    }

    // ---- the happy path ----------------------------------------------------

    @IsTest
    static void validResponsePassesAllChecks() {
        AttorneyReferralResponseValidator.Result res = run(valid());
        System.assertEquals(true, res.isValid);
        System.assertEquals(null, res.errorCode);
        System.assertEquals(null, res.failedCheck);
    }

    @IsTest
    static void nullAttorneyCaseRecordIdIsAllowed() {
        AttorneyReferralResponse r = valid();
        r.attorneyCaseRecordId = null; // explicitly permitted by check 4
        System.assertEquals(true, run(r).isValid);
    }

    // ---- each check fails independently, all -> INVALID_RESPONSE ------------

    private static void assertFails(AttorneyReferralResponse r, String expectedCheck) {
        AttorneyReferralResponseValidator.Result res = run(r);
        System.assertEquals(false, res.isValid, 'expected invalid for check ' + expectedCheck);
        System.assertEquals(AttorneyReferralResponseValidator.INVALID_RESPONSE, res.errorCode);
        System.assertEquals(expectedCheck, res.failedCheck);
    }

    @IsTest
    static void nullResponseFails() {
        AttorneyReferralResponseValidator.Result res =
            AttorneyReferralResponseValidator.validate(null, CORRELATION);
        System.assertEquals(false, res.isValid);
        System.assertEquals('response', res.failedCheck);
    }

    @IsTest
    static void successMustBeTrue() {
        AttorneyReferralResponse r = valid();
        r.success = false;
        assertFails(r, 'success');

        r = valid();
        r.success = null; // 2xx body that never affirms success
        assertFails(r, 'success');
    }

    @IsTest
    static void correlationIdMustMatch() {
        AttorneyReferralResponse r = valid();
        r.correlationId = '99999999-8888-4777-8666-555555555555'; // a valid v4, but not ours
        assertFails(r, 'correlationId');

        r = valid();
        r.correlationId = null; // response echoed nothing
        assertFails(r, 'correlationId');
    }

    @IsTest
    static void blankExpectedCorrelationIdFailsClosed() {
        // A caller that fails to supply the transmission's id cannot be validated as a match.
        AttorneyReferralResponseValidator.Result res =
            AttorneyReferralResponseValidator.validate(valid(), '   ');
        System.assertEquals(false, res.isValid);
        System.assertEquals('correlationId', res.failedCheck);
    }

    @IsTest
    static void attorneyCaseIdMustBeV4() {
        for (String bad : new List<String>{
                null,
                '',
                'not-a-uuid',
                '11111111-1111-1111-8111-111111111111', // v1 (version nibble 1)
                '11111111-2222-4333-1444-555555555555'  // bad variant nibble
        }) {
            AttorneyReferralResponse r = valid();
            r.attorneyCaseId = bad;
            assertFails(r, 'attorneyCaseId');
        }
    }

    @IsTest
    static void attorneyCaseRecordIdMustBeNullOr18CharId() {
        for (String bad : new List<String>{
                '',                    // blank-but-not-null
                'a00000000000001',     // 15-char form
                'a00000000000001AAAA', // 19 chars
                'a00000000000001ZZZ',  // 18 chars, bad checksum
                'not an id at all!!'   // prose
        }) {
            AttorneyReferralResponse r = valid();
            r.attorneyCaseRecordId = bad;
            assertFails(r, 'attorneyCaseRecordId');
        }
    }

    @IsTest
    static void attorneyCaseRecordIdAcceptsAnyForeignPrefix() {
        // No key-prefix check: the record belongs to a foreign org whose prefixes we cannot assume.
        for (String prefix : new List<String>{'a00', 'a03', '500', 'zzz'}) {
            AttorneyReferralResponse r = valid();
            r.attorneyCaseRecordId = String.valueOf(Id.valueOf(prefix + '000000000001'));
            System.assertEquals(true, run(r).isValid, 'prefix ' + prefix + ' must be accepted');
        }
    }

    @IsTest
    static void statusMustBeNonblank() {
        for (String blank : new List<String>{ null, '', '   ' }) {
            AttorneyReferralResponse r = valid();
            r.status = blank;
            assertFails(r, 'status');
        }
    }

    /** status is required nonblank, but NOT pinned to 'Open' — an update may return other values. */
    @IsTest
    static void statusOtherThanOpenIsAccepted() {
        for (String s : new List<String>{ 'In Review', 'Referred', 'Closed' }) {
            AttorneyReferralResponse r = valid();
            r.status = s;
            System.assertEquals(true, run(r).isValid, 'status ' + s + ' must be accepted (nonblank)');
        }
    }

    // ---- safety: the diagnostic never carries a response value -------------

    @IsTest
    static void failedCheckIsAControlledNameNeverAValue() {
        Set<String> allowed = new Set<String>{
            'response', 'success', 'correlationId', 'attorneyCaseId', 'attorneyCaseRecordId', 'status'
        };
        AttorneyReferralResponse r = valid();
        r.attorneyCaseId = 'Patient Jane Doe has cancer'; // if this ever leaked into failedCheck...
        AttorneyReferralResponseValidator.Result res = run(r);
        System.assertEquals(false, res.isValid);
        System.assert(allowed.contains(res.failedCheck),
            'failedCheck must be a controlled field name, was: ' + res.failedCheck);
        System.assert(!res.failedCheck.contains('Jane Doe'), 'failedCheck must never echo a value');
    }

    /** Short-circuits on the first failing check, in declared order. */
    @IsTest
    static void reportsFirstFailingCheck() {
        AttorneyReferralResponse r = valid();
        r.success = false;                // check 1 fails
        r.correlationId = 'wrong';        // check 2 would also fail
        assertFails(r, 'success');        // ...but the first failure wins
    }
}
