@IsTest
private class AttorneyReferralRequestMapperTest {

    private static final String CORRELATION = 'aaaaaaaa-bbbb-4ccc-8ddd-eeeeeeeeeeee';

    // Inserts Contact + Referral + Transmission and returns the transmission loaded with the exact
    // cross-object fields the mapper reads (Referral__r.Contact__r.*).
    private static Integration_Transmission__c loadedTransmission(Contact c, String referralType) {
        insert c;
        Referral__c r = new Referral__c(Status__c = 'New', Referral_Type__c = referralType, Contact__c = c.Id);
        insert r;
        Integration_Transmission__c t = new Integration_Transmission__c(
            Referral__c = r.Id, Target_System__c = 'ATTORNEY', Operation__c = 'CREATE_REFERRAL',
            Transmission_Key__c = String.valueOf(r.Id) + '|ATTORNEY|CREATE_REFERRAL',
            Correlation_Id__c = CORRELATION, Status__c = 'Pending', Retry_Count__c = 0);
        insert t;
        return [
            SELECT Correlation_Id__c, Referral__c, Referral__r.Referral_Type__c, Referral__r.Contact__c,
                   Referral__r.Contact__r.Id, Referral__r.Contact__r.Name, Referral__r.Contact__r.Email,
                   Referral__r.Contact__r.Phone, Referral__r.Contact__r.Birthdate
            FROM Integration_Transmission__c WHERE Id = :t.Id
        ];
    }

    @IsTest
    static void mapsEveryFieldFromTransmission() {
        Contact c = new Contact(FirstName = 'Jane', LastName = 'Doe', Email = 'jane@example.com',
            Phone = '555-0100', Birthdate = Date.newInstance(1985, 4, 12));
        Integration_Transmission__c loaded = loadedTransmission(c, 'Personal Injury');

        AttorneyReferralRequest req = AttorneyReferralRequestMapper.fromTransmission(loaded);

        System.assertEquals(CORRELATION, req.correlationId, 'correlationId comes from the transmission');
        System.assertEquals(String.valueOf(loaded.Referral__c), req.careConnectReferralId);
        System.assertEquals('Personal Injury', req.referralType);
        System.assertEquals(String.valueOf(c.Id), req.client.careConnectContactId);
        System.assertEquals('Jane Doe', req.client.fullName);
        System.assertEquals('jane@example.com', req.client.email);
        System.assertEquals('555-0100', req.client.phone);
        System.assertEquals('1985-04-12', req.client.dateOfBirth, 'ISO-8601 yyyy-MM-dd, zero-padded');
    }

    // The mapper and the validator are two halves of one contract: the mapper must never produce a
    // request the validator (the single validation authority, run before every callout) would reject.
    @IsTest
    static void mappedRequestSatisfiesTheValidator() {
        Contact c = new Contact(FirstName = 'Jane', LastName = 'Doe', Birthdate = Date.newInstance(1990, 12, 1));
        Integration_Transmission__c loaded = loadedTransmission(c, 'Workers Compensation');

        AttorneyReferralRequest req = AttorneyReferralRequestMapper.fromTransmission(loaded);
        AttorneyReferralRequestValidator.Result v = AttorneyReferralRequestValidator.validate(req);

        System.assert(v.isValid, 'mapper output must pass request validation; failed check: ' + v.failedCheck);
        System.assertEquals('1990-12-01', req.client.dateOfBirth, 'single-digit month/day are zero-padded');
    }

    @IsTest
    static void optionalContactFieldsAreOmittedWhenBlank() {
        Contact c = new Contact(LastName = 'Roe'); // no email, phone, or birthdate
        Integration_Transmission__c loaded = loadedTransmission(c, 'General');

        AttorneyReferralRequest req = AttorneyReferralRequestMapper.fromTransmission(loaded);

        System.assertEquals('Roe', req.client.fullName);
        System.assertEquals(null, req.client.email);
        System.assertEquals(null, req.client.phone);
        System.assertEquals(null, req.client.dateOfBirth, 'a null Birthdate is omitted, not formatted');
    }

    // Defensive: a transmission with no referral loaded must not NPE — the client object is always
    // present (the validator can then reject it cleanly rather than the mapper throwing).
    @IsTest
    static void missingReferralDoesNotThrow() {
        Integration_Transmission__c t = new Integration_Transmission__c(Correlation_Id__c = CORRELATION);

        AttorneyReferralRequest req = AttorneyReferralRequestMapper.fromTransmission(t);

        System.assertEquals(CORRELATION, req.correlationId);
        System.assertEquals(null, req.referralType);
        System.assertNotEquals(null, req.client, 'client is always instantiated');
        System.assertEquals(null, req.client.careConnectContactId);
    }
}
