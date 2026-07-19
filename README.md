# Care Connect Hub

> ## ⚠️ Fictional training data — please read
>
> **This is a training project. Every organization, person, identifier, and healthcare or legal
> scenario in this repository is entirely fictional and fabricated.**
>
> - **"Care Connect", "Attorney Case Management", and "Medical Provider System" are invented
>   organizations.** They do not exist and do not represent any real company.
> - **No real patient, client, or customer data appears anywhere in this repository** — not in code,
>   tests, documentation, commit history, or examples.
> - Names (`Jane Doe`), emails (`@example.com`), phone numbers (`555-…`), dates of birth, record
>   identifiers, and any medical or legal phrasing are **invented for testing** — including strings
>   that deliberately *look* like health information, which exist only to prove that the code
>   refuses to log them.
> - **No credentials, tokens, keys, or org secrets are committed here**, and none ever have been.
>   Salesforce authentication lives in the local `sf` CLI keychain, never in this repository.
>
> This code is not connected to any production system and has never processed real data.

---

Care Connect is the **hub** of a three-org Salesforce referral integration, built as an integration
training exercise. Attorney and Provider never communicate directly — everything routes through here.

```
Attorney Org  ◄── REST ──►  Care Connect (this repo)  ◄── REST ──►  Provider Org
```

## Status

**Schema & config**

| Component | State |
|---|---|
| `Referral__c`, `Integration_Log__c` | ✅ Deployed |
| `Integration_Transmission__c` (outbound state model) | ✅ Deployed |
| Permission sets, page layouts | ✅ Deployed |

**Outbound Apex** (Phase 4, in sequence)

| Class | State |
|---|---|
| `Uuid` | ✅ Merged |
| `AttorneyReferralRequest` / `AttorneyReferralResponse` DTOs | ✅ Merged |
| `AttorneyReferralResponseValidator` (five response checks) | ✅ Merged |
| `AttorneyReferralRequestValidator` (pre-callout checks) | ✅ Merged (PR #5) |
| `AttorneyApiService` (callout + classification + value-safe allowlisted log payloads) | ✅ Merged (PR #5) |
| `AttorneyTransmissionService` — #1–#3 (create + claim) and #4–#8b outcome application | ✅ Implemented (PR #6, #7) |
| `AttorneyReferralRequestMapper` — `Referral__c`/`Contact` → request DTO | ✅ Implemented (PR #7) |
| `AttorneyDispatchQueueable` / `AttorneySendQueueable` — serial chain, invokes #4–#7b | ✅ Implemented (PR #8) |
| Trigger (enqueue on new referrals) · retry & stale-recovery sweep (#8) | ⏳ Planned |

## Documentation

**Start here:** [`docs/`](docs/) — in particular
[**Outbound Transmission State**](docs/01-outbound-transmission-state.md), the specification that
gates all outbound callout code.

The receiving side (Attorney inbound) is complete and documented in its own repository, including 14
architecture decision records that are **binding on this org's outbound work**.

## Repository layout

```
force-app/main/default/
├── objects/          Referral__c, Integration_Log__c, Integration_Transmission__c
├── classes/          Uuid, AttorneyReferralRequest/Response (+ tests)
├── layouts/
└── permissionsets/   Integration_Admin,
                      Integration_Transmission_Runtime, Integration_Transmission_Support
docs/                 Architecture and specifications
```

## Working with this repo

```bash
sf org login web --alias careconnect --instance-url https://login.salesforce.com
sf config set target-org=careconnect          # pins this project to one org
sf project deploy start -o careconnect -d force-app/main/default

# Permission sets — the transmission object is deliberately NOT covered by Integration_Admin.
sf org assign permset -n Integration_Admin -o careconnect                 # Referral__c, Integration_Log__c
sf org assign permset -n Integration_Transmission_Runtime -o careconnect  # execution path: Integration_Transmission__c

# For human/support users, assign the read-only set INSTEAD of Runtime:
sf org assign permset -n Integration_Transmission_Support -o careconnect  # read-only investigation
```

> ⚠️ **`Integration_Admin` does not grant access to `Integration_Transmission__c`** — that object is
> governed by the two `Integration_Transmission_*` sets so ordinary editing can't bypass its state
> machine (see [the spec](docs/01-outbound-transmission-state.md)). If transmission fields *"appear
> not to exist"* after deploy, it's missing FLS, not a failed deploy: assign `Runtime` (or `Support`).

`target-org` is set **locally per project**, so a deploy from this folder can only reach the Care
Connect org. That is deliberate — it makes a cross-org mistake structurally hard.

## License

[MIT](LICENSE).
