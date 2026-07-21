/**
 * Starts the outbound Attorney chain when a referral becomes eligible. Eligibility is the explicit
 * business signal `Ready_For_Attorney__c`, and ONLY on:
 *   - insert with Ready_For_Attorney__c = true, or
 *   - an update where Ready_For_Attorney__c changes false → true.
 * Any other update to an already-ready referral is NOT a trigger — re-checking the box is not a retry
 * mechanism (manual retry is a separate, deliberate control; see the state spec, transition #9).
 *
 * Per firing: collect qualifying referral ids → create-or-get their Attorney CREATE_REFERRAL
 * transmissions (idempotent, bulk-safe) → enqueue at most ONE root dispatcher for the transaction.
 *
 * The transaction-level static guards ONLY the root enqueue, never transmission creation. A trigger can
 * fire multiple times in one transaction; every firing must still create transmissions for its qualifying
 * referrals (else those referrals never get a row and the sweep cannot find them), but only one root is
 * enqueued. A dispatcher serialized during the first firing cannot gain transmissions created by later
 * firings — those stay Pending and are picked up by the hourly recovery sweep. If there is no Queueable
 * capacity, `enqueueRoot` returns null and the transmissions simply stay Pending for the sweep.
 */
public with sharing class ReferralTriggerHandler {

    // Per-transaction: true once a root dispatcher has been enqueued this transaction.
    @TestVisible private static Boolean rootEnqueued = false;

    public static void handleAfterInsert(List<Referral__c> newReferrals) {
        Set<Id> qualifying = new Set<Id>();
        for (Referral__c r : newReferrals) {
            if (r.Ready_For_Attorney__c == true) {
                qualifying.add(r.Id);
            }
        }
        process(qualifying);
    }

    public static void handleAfterUpdate(List<Referral__c> newReferrals, Map<Id, Referral__c> oldById) {
        Set<Id> qualifying = new Set<Id>();
        for (Referral__c r : newReferrals) {
            Referral__c prior = oldById.get(r.Id);
            // false → true ONLY. Already-ready (prior true) is not re-submitted.
            if (r.Ready_For_Attorney__c == true && (prior == null || prior.Ready_For_Attorney__c != true)) {
                qualifying.add(r.Id);
            }
        }
        process(qualifying);
    }

    private static void process(Set<Id> referralIds) {
        if (referralIds.isEmpty()) {
            return;
        }

        // Every firing creates/finds transmissions for its qualifying referrals — idempotent via the
        // unique Transmission_Key__c, and bulk-safe (one partial-success insert + one requery, no loops).
        List<Integration_Transmission__c> transmissions =
            AttorneyTransmissionService.createReferralTransmissions(referralIds);

        // At most one root per transaction. The guard is checked AFTER creation, so a later firing still
        // creates its transmissions even once a root has been enqueued.
        if (rootEnqueued) {
            return;
        }
        List<Id> transmissionIds = new List<Id>();
        for (Integration_Transmission__c t : transmissions) {
            transmissionIds.add(t.Id);
        }
        Id jobId = AttorneyDispatchQueueable.enqueueRoot(transmissionIds);
        if (jobId != null) {
            rootEnqueued = true; // set only after a SUCCESSFUL enqueue (null = no capacity → sweep handles)
        }
    }
}
