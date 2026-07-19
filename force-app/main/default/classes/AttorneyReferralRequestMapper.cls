/**
 * Builds the outbound AttorneyReferralRequest DTO from a claimed transmission and its source
 * Referral__c / Contact. PURE mapping — no SOQL, no callout: the caller loads the transmission with
 * Referral__r.Contact__r fields populated (one query) and performs the send.
 *
 * Where identifiers come from, and why:
 *   - correlationId          the TRANSMISSION's Correlation_Id__c (one per logical transmission,
 *                            reused across every attempt) — NOT the referral's.
 *   - careConnectReferralId  the 18-char Referral__c Id — the receiver's idempotency key.
 *   - client.careConnectContactId  the 18-char Contact Id (003 prefix, a standard object).
 *   - dateOfBirth            ISO-8601 yyyy-MM-dd, formatted EXPLICITLY (not via locale-dependent Date
 *                            formatting); a null Birthdate is omitted (an optional contract field).
 *
 * This does NOT validate. AttorneyReferralRequestValidator (invoked inside AttorneyApiService before
 * the callout) is the single validation authority; a request built wrong surfaces there as a
 * permanent INVALID_REQUEST with only the failed check name logged — never a value.
 */
public with sharing class AttorneyReferralRequestMapper {

    public static AttorneyReferralRequest fromTransmission(Integration_Transmission__c t) {
        AttorneyReferralRequest r = new AttorneyReferralRequest();
        r.correlationId = t.Correlation_Id__c;
        r.careConnectReferralId = t.Referral__c == null ? null : String.valueOf(t.Referral__c);

        Referral__c referral = t.Referral__r;
        r.referralType = referral == null ? null : referral.Referral_Type__c;

        AttorneyReferralRequest.ClientInfo c = new AttorneyReferralRequest.ClientInfo();
        Contact contact = referral == null ? null : referral.Contact__r;
        if (contact != null) {
            c.careConnectContactId = String.valueOf(contact.Id);
            c.fullName = contact.Name;
            c.email = contact.Email;
            c.phone = contact.Phone;
            c.dateOfBirth = isoDate(contact.Birthdate);
        }
        r.client = c;
        return r;
    }

    // Explicit ISO-8601 yyyy-MM-dd. Date.format()/String.valueOf(Date) are locale-dependent; the
    // Attorney contract (and its validator's ^\d{4}-\d{2}-\d{2}$ check) require this exact shape.
    private static String isoDate(Date d) {
        if (d == null) {
            return null;
        }
        return d.year() + '-' + twoDigits(d.month()) + '-' + twoDigits(d.day());
    }

    private static String twoDigits(Integer n) {
        return n < 10 ? '0' + n : String.valueOf(n);
    }
}
