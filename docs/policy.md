---
title: Policy
---

# Internal Policies

!!! note "Internal use only"
    This section is for internal technical use by BSE team members. Official customer-facing policies are not publicly detailed on this documentation site. For compliance queries, refer to internal HR and legal documents, or contact [info@bse.com.eg](mailto:info@bse.com.eg).

## General Guidelines

- All technical implementations must follow the methodology outlined in the [Technical Guide](technical_guide.md).
- **Data privacy:** Customer data must be handled securely in line with Egyptian data protection laws and any customer-specific contractual obligations.
- **Documentation scope:** The resources on this site are for BSE team members and authorized contractors only.
- **Architectural decisions:** Significant technical choices should be captured as ADRs under [Framework → ADRs](framework/index.md) so the reasoning is preserved for future contributors.
- **Breaking changes:** Any change that affects a published API, database schema, or tenant configuration requires an RFC under [Framework → RFCs](framework/index.md) before implementation.

## Documentation Standards

- Every new feature that ships to a customer must be reflected in either a product runbook, an ADR, or an RFC — whichever fits best.
- Internal framework code (`Bse.Framework.*`) should be documented via ADRs and RFCs rather than inline design commentary.
- Prefer editing an existing document over creating a new one if the topic already has a home.

## Update Log

- **2025-10-07** — Initial version.
- **2026-04-07** — Added documentation standards, linked the Framework ADR/RFC sections.

---

Public-facing contact and company information: [bse.com.eg](https://bse.com.eg/?utm_source=docs&utm_medium=docs-site&utm_campaign=bse-documentation&utm_content=policy).
