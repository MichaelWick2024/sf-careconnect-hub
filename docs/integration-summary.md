# Salesforce Integration Summary

> **The one-page version.** Eight steps that condense the full material. For the exhaustive controls and
> failure modes see [`docs/integration-checklist.md`](integration-checklist.md); for the ordered,
> gated build process see [`docs/integration-build-playbook.md`](integration-build-playbook.md).

---

## 1. Understand the business process

Determine:

- What starts the integration?
- Which systems are involved?
- What result must occur?
- Which system owns each piece of data?
- Does it need to be real-time, asynchronous, or scheduled?

## 2. Choose the integration pattern

Choose based on the requirements:

- REST API
- Platform Events
- Change Data Capture
- Batch or scheduled synchronization
- Salesforce Connect
- Middleware such as MuleSoft

Decide whether processing should be **synchronous or asynchronous**, and consider **Salesforce governor
limits** (they often dictate the topology, not merely tune it).

## 3. Define the API contract

Agree on:

- Endpoint and HTTP method
- Request and response JSON
- Required and optional fields
- Data types, lengths, and allowed values
- Success and error responses
- API versioning
- An **idempotency key for retryable, state-changing operations**

## 4. Secure the connection

Use:

- **Named and External Credentials** for outbound Salesforce callouts
- OAuth, JWT, or another appropriate authentication method
- A **least-privilege** integration user
- **Separate** sandbox and production credentials
- **No hardcoded** passwords, tokens, or secrets

## 5. Map and validate the data

Use DTOs rather than sending an entire Salesforce record:

> Salesforce record → Mapper → Request DTO → Request validator → JSON

Validate required values, identifiers, lengths, dates, picklists, and related records **before sending**.

## 6. Send the request and validate the response

The HTTP service should:

> Serialize request → Make callout → Receive response → Classify HTTP result → Validate response body → Return controlled outcome

**Do not trust a 200 automatically.** Validate required response fields, identifiers, and the correlation
id before saving anything.

## 7. Handle failures safely

Classify failures:

- **Temporary** — timeout, 429, most 5xx → **retry with backoff**
- **Permanent** — invalid data, authorization problem, unsupported request → **fail and require correction**

Use **idempotency** so a retry does not create duplicates. Add **concurrency protections** when volume
and risk justify them.

## 8. Test and operate it

Test:

- Successful callout
- Invalid request
- Malformed response
- Authentication and authorization errors
- Rate-limit and server errors
- Timeouts
- Duplicate delivery
- Retry exhaustion
- Sensitive-data logging protections

Use `HttpCalloutMock` for unit tests — but **also perform a real sandbox-to-sandbox test**, because mocks
cannot prove authentication, permissions, endpoint configuration, or actual communication.

---

## Care Connect example

> Referral marked ready
> → Transmission created
> → Queueable claims the transmission
> → Mapper builds the Attorney DTO
> → Validator checks the request
> → API service calls Attorney through a Named Credential
> → Attorney creates or updates the case idempotently
> → Care Connect validates the response
> → Transmission becomes **Succeeded**, **Retry Scheduled**, or **Failed**
> → A sanitized attempt log is written
