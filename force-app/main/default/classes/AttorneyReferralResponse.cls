/**
 * Outbound response contract (DTO): what Care Connect RECEIVES back from the Attorney inbound
 * endpoint. This is the CONSUMER half; the Attorney org's `ReferralResponse` is the producer.
 *
 * A 2xx status does NOT imply success, and this DTO does NOT validate. It only carries the
 * values. Response validation (step 7) runs before ANY Attorney identifier is persisted, and per
 * the transmission spec it treats a response as untrusted remote input even though we wrote the
 * other end. On a successful response ALL of the following must hold, else INVALID_RESPONSE:
 *
 *   - success == true
 *   - correlationId matches the transmission's Correlation_Id__c
 *   - attorneyCaseId is a v4 UUID
 *   - attorneyCaseRecordId is null OR a valid 18-character Salesforce Id
 *   - status is nonblank
 *
 * `status` is required nonblank (not `== 'Open'`): the spec mandates the status field be present,
 * but pinning it to one value would break the moment Attorney legitimately returns another (an
 * update can yield In Review / Referred / Closed). Nonblank preserves forward compatibility.
 *
 * Deserialized with `JSON.deserialize`, which ignores unknown keys, so the Attorney side can add
 * response fields without breaking Care Connect.
 *
 * Identifier hierarchy (do not confuse):
 *   - attorneyCaseId        the durable contract id (v4 UUID). Store this.
 *   - attorneyCaseRecordId  the foreign org's Case record Id. Diagnostics only
 *                           (persisted to Integration_Transmission__c.External_Salesforce_Id__c).
 *
 * Only fields Care Connect actually consumes are modeled. Deliberately NOT modeled:
 *   - `clientRecordId` — the foreign Client record Id; Care Connect has no storage or use for it.
 *   - `message` — a human-readable REMOTE message. Care Connect drives its own outcome from
 *     `success`, `errorCode`, HTTP status and its controlled internal error vocabulary, so there is
 *     no consumer. Not modeling it prevents DTO-driven business logic or persistence from consuming
 *     it. Logging safety is a SEPARATE guarantee, NOT provided by this DTO: the raw HTTP body still
 *     exists before deserialization, so the API service must never persist the raw response body and
 *     must build logs from an explicit allowlist (as the inbound side does).
 * Model a response field here only when there is a consumer AND a test for it.
 */
public class AttorneyReferralResponse {
    public String correlationId;
    public Boolean success;
    public String attorneyCaseId;
    public String attorneyCaseRecordId;
    public String status;
    public String errorCode;
}
