/**
 * The dispatcher half of the serial send chain. Given a bounded set of candidate transmission ids
 * (supplied by the trigger on new referrals, or by the recovery sweep), it claims up to
 * MAX_CLAIM_BATCH of them with singular AttorneyTransmissionService.claim(Id) calls, then enqueues
 * EXACTLY ONE sender for the rows it won — carrying the remaining candidates as leftover so the chain
 * keeps draining.
 *
 * Why a serial chain, not a fan-out: an executing Queueable may enqueue only ONE child, so a dispatcher
 * cannot spawn one sender per transmission. Instead: dispatcher → one sender → one next dispatcher → …
 * MAX_CLAIM_BATCH is bounded because the claims run in one transaction (Salesforce lock guidance favors
 * small transactions) and, more bindingly, the sender it feeds must fit every callout inside the 120 s
 * cumulative callout budget: MAX_CLAIM_BATCH * AttorneyApiService.TIMEOUT_MS (3 * 30 s = 90 s).
 *
 * Claiming is singular so a lock failure classifies ONE row as `locked` rather than the whole group;
 * unclaimed candidates (locked / not-eligible / not-found) are simply dropped from this cycle — the
 * sweep will resurface anything that still needs work.
 */
public with sharing class AttorneyDispatchQueueable implements Queueable {

    @TestVisible private static final Integer MAX_CLAIM_BATCH = 3;

    private final List<Id> candidateIds;

    public AttorneyDispatchQueueable(List<Id> candidateIds) {
        this.candidateIds = candidateIds == null ? new List<Id>() : candidateIds;
    }

    public void execute(QueueableContext ctx) {
        List<Id> batch = new List<Id>();
        List<Id> leftover = new List<Id>();
        for (Integer i = 0; i < candidateIds.size(); i++) {
            if (i < MAX_CLAIM_BATCH) {
                batch.add(candidateIds[i]);
            } else {
                leftover.add(candidateIds[i]);
            }
        }

        // One singular FOR UPDATE claim per candidate; collect only the rows we actually won.
        Map<Id, String> claimTokenById = new Map<Id, String>();
        for (Id candidateId : batch) {
            AttorneyTransmissionService.ClaimResult cr = AttorneyTransmissionService.claim(candidateId);
            if (cr.claimed) {
                claimTokenById.put(cr.transmissionId, cr.claimToken);
            }
        }

        // Enqueue EXACTLY ONE child (the platform allows only one from a running Queueable). Chaining
        // throws in test context (a guard against runaway test chains), so the enqueue is skipped there;
        // tests drive execute() directly instead.
        Queueable next = null;
        if (!claimTokenById.isEmpty()) {
            // Hand the claimed rows to one sender, which will carry `leftover` onward after it sends.
            next = new AttorneySendQueueable(claimTokenById, leftover);
        } else if (!leftover.isEmpty()) {
            // Won nothing this cycle but candidates remain — keep the chain alive without a sender.
            next = new AttorneyDispatchQueueable(leftover);
        }
        // else: nothing claimed and nothing left — the chain ends here.

        if (next != null && !Test.isRunningTest()) {
            System.enqueueJob(next);
        }
    }
}
