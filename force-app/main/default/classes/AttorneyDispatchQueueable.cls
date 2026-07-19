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

    // A single root drains at most MAX_ROOT_CANDIDATES referrals, worst-case 2 * ceil(N / MAX_CLAIM_BATCH)
    // chain links (a dispatcher + a sender per batch). MAX_CHAIN_DEPTH must cover that; the relationship
    // is pinned by AttorneyDispatchQueueableTest and 140 is verified accepted by the org.
    @TestVisible private static final Integer MAX_ROOT_CANDIDATES = 200;
    @TestVisible private static final Integer MAX_CHAIN_DEPTH = 140;

    private final List<Id> candidateIds;

    public AttorneyDispatchQueueable(List<Id> candidateIds) {
        this.candidateIds = candidateIds == null ? new List<Id>() : candidateIds;
    }

    /**
     * The single entry point for STARTING a chain — used by BOTH the trigger and the scheduled sweep, so
     * every root sets the same explicit MaximumQueueableStackDepth via AsyncOptions. A root that skipped
     * it would begin an unconfigured chain (hasMaxStackDepth() = false) with no depth protection.
     * Chained dispatcher/sender enqueues use ordinary System.enqueueJob and inherit this maximum.
     *
     * Returns null for null/empty input; dedups; caps at MAX_ROOT_CANDIDATES; and enqueues only when the
     * transaction still has Queueable capacity — otherwise it returns null and leaves the work Pending
     * for the sweep (the safety net), rather than throwing. The payload carries ONLY transmission ids,
     * never status / correlation ids / other record data.
     */
    public static Id enqueueRoot(List<Id> candidateIds) {
        List<Id> normalized = normalizeRootCandidates(candidateIds);
        if (normalized.isEmpty()) {
            return null;
        }
        if (Limits.getQueueableJobs() >= Limits.getLimitQueueableJobs()) {
            return null; // no capacity this transaction — the sweep will resurface the Pending rows
        }
        AsyncOptions options = new AsyncOptions();
        options.MaximumQueueableStackDepth = MAX_CHAIN_DEPTH;
        return System.enqueueJob(new AttorneyDispatchQueueable(normalized), options);
    }

    // Dedups (order-preserving), drops nulls, and caps at MAX_ROOT_CANDIDATES. Split out so the
    // normalization is unit-testable without enqueuing.
    @TestVisible
    private static List<Id> normalizeRootCandidates(List<Id> candidateIds) {
        List<Id> normalized = new List<Id>();
        if (candidateIds == null) {
            return normalized;
        }
        Set<Id> seen = new Set<Id>();
        for (Id candidateId : candidateIds) {
            if (candidateId == null || seen.contains(candidateId)) {
                continue;
            }
            seen.add(candidateId);
            normalized.add(candidateId);
            if (normalized.size() == MAX_ROOT_CANDIDATES) {
                break;
            }
        }
        return normalized;
    }

    public void execute(QueueableContext ctx) {
        // Chain-depth policy: claim NOTHING if we could not enqueue the sender those claims require —
        // claiming without the capacity to dispatch would strand rows in Processing until stale
        // recovery. The candidates stay Pending and the scheduled sweep resurfaces them.
        if (!canEnqueueChild()) {
            return;
        }

        List<Id> batch = new List<Id>();
        List<Id> leftover = new List<Id>();
        for (Integer i = 0; i < candidateIds.size(); i++) {
            if (i < MAX_CLAIM_BATCH) {
                batch.add(candidateIds[i]);
            } else {
                leftover.add(candidateIds[i]);
            }
        }

        // One singular FOR UPDATE claim per candidate; collect only the rows we actually won. The claim
        // is route-gated to Attorney's target/operation, so a Provider row handed here (e.g. by a future
        // generic sweep) is refused `wrong-target` and never enters the Attorney chain.
        Map<Id, String> claimTokenById = new Map<Id, String>();
        for (Id candidateId : batch) {
            AttorneyTransmissionService.ClaimResult cr = AttorneyTransmissionService.claim(
                candidateId, AttorneyTransmissionService.TARGET, AttorneyTransmissionService.OPERATION);
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

    /**
     * The chain's depth guard, shared with the sender. Salesforce caps chained Queueable depth (5 in
     * Developer/Trial orgs), and an enqueue that hits the ceiling throws AFTER this transaction's DML —
     * rolling back its committed state and logs. So we check BEFORE enqueuing and stop the chain
     * cleanly, leaving remaining work for the scheduled sweep. PR #9's shared root-enqueue method, used
     * by BOTH the trigger and the scheduled sweep, sets an explicit MaximumQueueableStackDepth (via
     * AsyncOptions) so the ceiling is a deliberate value, not the platform default — a root that skipped
     * it would start an unconfigured chain with no protection.
     *
     * AsyncInfo is only callable inside a Queueable/Finalizer; a direct unit-test call to execute() is
     * not that context. That accommodation is made EXPLICIT (Test.isRunningTest) so that in production
     * the check FAILS CLOSED: an unexpected AsyncException stops the chain rather than proceeding with an
     * enqueue the guard exists to prevent (in the sender that enqueue follows committed DML).
     */
    public static Boolean canEnqueueChild() {
        try {
            return !System.AsyncInfo.hasMaxStackDepth()
                || System.AsyncInfo.getCurrentQueueableStackDepth()
                    < System.AsyncInfo.getMaximumQueueableStackDepth();
        } catch (System.AsyncException e) {
            // AsyncInfo is only callable inside a Queueable/Finalizer. A direct unit-test execute() call
            // is not that context — accommodate it EXPLICITLY here (which also keeps the guard exercised
            // by tests). In PRODUCTION an unexpected AsyncException must FAIL CLOSED: stop the chain
            // rather than enqueue past a ceiling the guard exists to prevent.
            if (Test.isRunningTest()) {
                return true;
            }
            System.debug(LoggingLevel.ERROR, 'Queueable depth check failed; chain stopped.'); // no e.getMessage()
            return false;
        }
    }
}
