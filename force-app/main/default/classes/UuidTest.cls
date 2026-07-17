@IsTest
private class UuidTest {

    // The exact contract: specifically version 4, not "any recognized RFC version".
    private static final Pattern UUID_V4 = Pattern.compile(
        '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-4[0-9a-fA-F]{3}-[89abAB][0-9a-fA-F]{3}-[0-9a-fA-F]{12}$'
    );

    /**
     * The regression that motivated this class: the previous generator produced RFC-compliant
     * output only ~8% of the time (3/40 measured). Every id must now match, every time.
     */
    @IsTest
    static void everyGeneratedUuidIsRfc4122V4() {
        for (Integer i = 0; i < 200; i++) {
            String u = Uuid.v4();
            System.assert(UUID_V4.matcher(u).matches(), 'not a v4 UUID: ' + u);
        }
    }

    @IsTest
    static void versionNibbleIsAlwaysFour() {
        for (Integer i = 0; i < 100; i++) {
            String u = Uuid.v4();
            System.assertEquals('4', u.substring(14, 15), 'version nibble must be 4: ' + u);
        }
    }

    @IsTest
    static void variantHighBitsAreAlwaysTen() {
        Set<String> seen = new Set<String>();
        for (Integer i = 0; i < 200; i++) {
            String variant = Uuid.v4().substring(19, 20).toLowerCase();
            System.assert(new Set<String>{'8', '9', 'a', 'b'}.contains(variant),
                'variant nibble must be 8/9/a/b (top bits 10), was: ' + variant);
            seen.add(variant);
        }
        // The variant's low two bits stay random — if we had replaced the whole nibble with a
        // constant we would only ever see one value here, silently losing two bits of entropy.
        System.assert(seen.size() > 1,
            'variant low bits must remain random, only ever saw: ' + seen);
    }

    @IsTest
    static void formatIsCanonical() {
        String u = Uuid.v4();
        System.assertEquals(36, u.length());
        System.assertEquals(u, u.toLowerCase(), 'canonical form is lowercase');
        List<String> groups = u.split('-');
        System.assertEquals(5, groups.size());
        System.assertEquals(8, groups[0].length());
        System.assertEquals(4, groups[1].length());
        System.assertEquals(4, groups[2].length());
        System.assertEquals(4, groups[3].length());
        System.assertEquals(12, groups[4].length());
    }

    @IsTest
    static void separateCallsProduceDistinctUuids() {
        Set<String> ids = new Set<String>();
        for (Integer i = 0; i < 500; i++) {
            ids.add(Uuid.v4());
        }
        System.assertEquals(500, ids.size(), 'every generated UUID must be unique');
    }

    /**
     * Care Connect-specific: the generated UUID is the Correlation_Id__c on both the log
     * (Text(64)) and — crucially — the transmission (Text(36)). The transmission field is the
     * tight contract: a canonical v4 UUID is exactly 36 characters. If the generator or schema
     * drifts so the value no longer fits, transmission persistence FAILS — Salesforce rejects an
     * oversized string with a DML error (STRING_TOO_LONG); it does NOT silently truncate
     * (verified against this org). Equality detects that incompatibility here, before it would
     * surface as a runtime insert failure. That is why this asserts equality against the
     * exact-fit field, not merely "<=".
     */
    @IsTest
    static void uuidFitsBothCorrelationFields() {
        String u = Uuid.v4();

        Integer transmissionLen =
            Schema.SObjectType.Integration_Transmission__c.fields.Correlation_Id__c.getLength();
        System.assertEquals(36, transmissionLen, 'transmission Correlation_Id__c is expected to be Text(36)');
        System.assertEquals(transmissionLen, u.length(),
            'a v4 UUID must fit Integration_Transmission__c.Correlation_Id__c exactly (Text(36), zero slack)');

        Integer logLen = Schema.SObjectType.Integration_Log__c.fields.Correlation_Id__c.getLength();
        System.assert(u.length() <= logLen,
            'log Correlation_Id__c (' + logLen + ') must hold a 36-char UUID without truncation');
    }
}
