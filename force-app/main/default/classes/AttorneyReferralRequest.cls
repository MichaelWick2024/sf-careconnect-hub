/**
 * Outbound referral contract (DTO) that Care Connect SENDS to the Attorney org's inbound
 * endpoint: POST /services/apexrest/v1/referrals.
 *
 * This is the PRODUCER half of the shared contract; the Attorney org's `ReferralRequest` is
 * the consumer half. The Apex FIELD NAMES here are the JSON keys on the wire, so they must
 * match the Attorney contract exactly — renaming a field here silently breaks the integration
 * with no compile error on either side. `AttorneyReferralRequestTest` pins the key set so that
 * a rename fails the build instead.
 *
 * Contract obligations carried from the Attorney API (see that repo's ADRs):
 *   - correlationId          v4 UUID, one per logical transmission, reused across retries
 *   - careConnectReferralId  18-char Referral__c Id (the receiver's idempotency key)
 *   - client.careConnectContactId  18-char Contact Id (003 prefix)
 *
 * `priority` is DELIBERATELY ABSENT. The Attorney endpoint neither validates nor persists it, so
 * it is not part of the contract — including it here would enforce (via the shape test) the return
 * of a field the receiver ignores, recreating the invisible, unvalidated input surface Phase 3
 * removed. If Attorney ever adds priority handling, add it to both contracts deliberately, with
 * validation, not as a silently-ignored field.
 *
 * Pure data. Mapping from `Referral__c` / `Contact` lives in the outbound service, and building
 * a valid instance (id formats, referral type) is enforced there — not in this DTO.
 */
public class AttorneyReferralRequest {
    public String correlationId;
    public String careConnectReferralId;
    public String referralType;
    public ClientInfo client;

    public class ClientInfo {
        public String careConnectContactId;
        public String fullName;
        public String email;       // optional
        public String phone;       // optional
        public String dateOfBirth; // optional; ISO-8601 yyyy-MM-dd
    }
}
