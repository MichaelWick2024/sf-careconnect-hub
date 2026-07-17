# Care Connect Hub — Integration Documentation

> **Purpose** Index for this repository's documentation.
> **Audience** Salesforce developers and admins.
> **Status** Phase 4 in progress — outbound transmission state specified, no Apex yet.
> **Last verified against** `Integration_Transmission__c` deployed to the `careconnect` org, 17/17 fields verified. No Apex in this org.
> **Owner** Care Connect integration team.

Care Connect is the **hub** of a three-org referral integration. Attorney and Provider never
communicate directly — everything routes through here.

```
Attorney Org  ◄── REST ──►  Care Connect (this repo)  ◄── REST ──►  Provider Org
sf-attorney-cms                 sf-careconnect-hub                 sf-provider-med
```

## Documents

| # | Document | Status |
|---|---|---|
| 01 | [Outbound Transmission State](01-outbound-transmission-state.md) | **Specification — the approval gate for callout code** |

## Where the rest of the documentation lives

Phase 3 (Attorney inbound) is complete and documented in the **`sf-attorney-cms`** repo under
`docs/`. Start with its `08-architecture-decisions.md` — the decisions recorded there are **binding
on this org's outbound work**:

| Obligation on Care Connect | Source |
|---|---|
| Generate one **v4 UUID** per logical request, reused across retries | ADR-013, ADR-003 |
| Send **18-character** Salesforce Ids — never 15 | ADR-004 |
| Store `attorneyCaseId` (the UUID) as the integration key — **never** `attorneyCaseRecordId` | ADR-002 |
| **400 is terminal.** Never retry it | Attorney API contract |
| **500 is retryable** — safe, because Attorney inbound is idempotent | Attorney API contract |
| Copy `Uuid.cls` + `UuidTest.cls` here — orgs cannot share Apex | ADR-011 |
| **Validate the Attorney response before persisting it** — a response is remote input too | Phase 3, applied symmetrically |

## Current state of this org

| Built | Status |
|---|---|
| `Referral__c`, `Integration_Log__c` | ✅ Deployed (Phase 2) |
| `Integration_Transmission__c` | ✅ Deployed (Phase 4, Story 1) |
| `Integration_Admin` permission set | ✅ Deployed |
| Page layouts | ✅ Deployed |
| **Apex** | ❌ **None yet** — gated on approval of doc 01 |

## Documentation standard

Every document states **Purpose, Audience, Status, Last verified against, Owner, Related metadata**.

The *Last verified against* stamp names a commit or a verified org state so a reader can tell whether
the document still describes reality. **Update it in the same PR as the behaviour change.** A stale
stamp is worse than no document — it reads as authoritative.

If a stamp doesn't match reality, trust the code.
