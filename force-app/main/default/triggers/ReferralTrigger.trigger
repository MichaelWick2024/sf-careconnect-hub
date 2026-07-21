/**
 * Thin trigger — all logic lives in ReferralTriggerHandler. Fires on the events where a referral can
 * become eligible for Attorney submission (insert, or a false → true change of Ready_For_Attorney__c).
 * After-events so the referral has an Id and its committed values are available.
 */
trigger ReferralTrigger on Referral__c (after insert, after update) {
    if (Trigger.isInsert) {
        ReferralTriggerHandler.handleAfterInsert(Trigger.new);
    } else if (Trigger.isUpdate) {
        ReferralTriggerHandler.handleAfterUpdate(Trigger.new, Trigger.oldMap);
    }
}
