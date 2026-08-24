# NovaNetworkClient Documentation Experience DFR

## Metadata

- Feature: Product website and Apple-style guided documentation
- Owner: NovaNetwork maintainers
- Stakeholders: Swift package consumers, Engineering, QA, Support
- Status: Implemented
- Goal: Help Swift teams understand why NovaNetworkClient is valuable, evaluate its production
  capabilities, and follow a reliable path from installation to a production-ready client.
- Non-goals: Change runtime behavior, add dependencies, or duplicate every API reference page.
- Definition of Done: A product-led website that explains the problems the library solves and its
  verified capabilities, a discoverable Getting Started article, at least eight interactive DocC
  tutorials, concept guides, production checklist, compiled examples, valid DocC output, a
  responsive standalone documentation website with a reproducible CI build, and release notes.
- Rollout: Ship with the next documentation update; no feature flag or migration is required.
- Dependencies: Swift-DocC included with Xcode/Swift, the existing public API, SwiftPM, and the
  Node.js toolchain used only to build the standalone documentation website.
- Risks: Examples drifting from the API, broken DocC links, and readers mistaking sample endpoints
  or authentication scopes for production values.

## User value

### Problem statement

Swift teams often begin with a small URLSession wrapper, then separately rebuild request
deduplication, cancellation ownership, retries, caching, authentication refresh, offline delivery,
realtime connections, and diagnostics. The existing learning materials explain how to use the
library, but the website must first make the product value, intended audience, and breadth of the
coherent solution clear. After evaluation, a first-time user still needs a progressive,
project-based learning path.

### Success metrics

| Metric | Target | Measurement |
|---|---:|---|
| Time to first typed response | Under 10 minutes | Tutorial usability review |
| Tutorial code buildability | 100% | Swift type-check validation |
| DocC diagnostics caused by new pages | 0 warnings/errors | DocC conversion gate |
| Core and advanced learning concepts covered | 100% | Requirement-to-page audit |
| Standalone website build | 100% of pushes and pull requests | CI website build gate |
| Product capability coverage | 100% of verified core capability groups | Content audit against public API and examples |
| Adoption path visibility | Primary Get Started and GitHub actions visible on the landing page | Responsive UI review |

### Scope

- MVP: installation, first typed request, coalescing, retry/cache, endpoint modeling, errors.
- V1: authentication refresh, batching, offline writes, realtime networking, production checklist,
  concept map, API-selection guide, testing and observability links.
- V1 website: responsive product landing page, problem/solution narrative, verified capability
  overview, adoption CTAs, tutorial catalog, Getting Started, concepts, copyable Swift snippets,
  previous/next navigation, and CI build validation.
- Nice-to-have: downloadable starter project, localized tutorials, hosted search analytics.

## Requirements

### Functional requirements

| ID | Requirement | Acceptance criteria |
|---|---|---|
| FR-DOC-1 | Complete Getting Started | Covers requirements, Xcode and manifest installation, first model/request/client/load, errors, and next steps. |
| FR-DOC-2 | Guided tutorial path | At least four ordered DocC tutorials take the reader from first request through production concepts. |
| FR-DOC-3 | Buildable code | Each tutorial provides a complete Swift source resource that type-checks against the package. |
| FR-DOC-4 | Discoverability | README and the DocC landing page link to the new learning path. |
| FR-DOC-5 | Conceptual guidance | Dedicated articles explain request identity, API selection, and production readiness. |
| FR-DOC-6 | Advanced tutorials | Guided tutorials cover authentication refresh, batching, offline writes, and realtime networking. |
| FR-DOC-7 | Standalone website | A responsive website exposes Getting Started, the ordered tutorial catalog, concept guides, and API-reference entry points without requiring Xcode. |
| FR-DOC-8 | Reproducible site build | A documented package script produces a deployable website artifact and CI runs that build for every push and pull request. |
| FR-DOC-9 | Product positioning | The landing page clearly states what the library is, who it is for, and why it is preferable to assembling production networking concerns ad hoc. |
| FR-DOC-10 | Capability proof | The landing page presents only capabilities grounded in the package API, examples, manifest, tests, and license. |
| FR-DOC-11 | Adoption path | The landing page provides prominent paths to Get Started, tutorials, concepts, GitHub, and SwiftPM installation. |

### UX requirements

| ID | Requirement | Acceptance criteria |
|---|---|---|
| UR-DOC-1 | Progressive disclosure | Every tutorial has a goal, short sections, numbered steps, explanations, and an experiment. |
| UR-DOC-2 | Apple-style navigation | Tutorials are grouped into named chapters in a DocC `@Tutorials` table of contents. |
| UR-DOC-3 | Safe copy/paste | Placeholders are clearly identified and samples use a public demo API only for learning. |
| UR-DOC-4 | Clear terminology | Coalescing, fingerprint, `authScope`, retry eligibility, and cache freshness are defined before advanced use. |
| UR-DOC-5 | Visible step focus | Every code-bearing tutorial step uses a progressive source snapshot and renders a non-empty highlight for the lines introduced by that step. |
| UR-DOC-6 | Web learning flow | The website provides persistent navigation, visible learning progress, copyable code, and previous/next links on tutorial pages. |
| UR-DOC-7 | Responsive access | Core documentation remains readable and navigable at phone, tablet, and desktop widths with keyboard-visible focus states. |
| UR-DOC-8 | Product storytelling | The landing page progresses from pain to solution, capabilities, operating model, proof, learning resources, and a final adoption CTA. |
| UR-DOC-9 | Credible claims | Quality and compatibility claims use concrete, repository-verifiable evidence and avoid invented customer or performance metrics. |
| UR-DOC-10 | Actionable verification steps | Tutorial steps that ask the reader to run, verify, inspect, or adapt behavior include a progressive code snapshot rather than prose alone. |

### Data requirements

| ID | Requirement | Acceptance criteria |
|---|---|---|
| DR-DOC-1 | No secrets | Examples contain no real credentials, tokens, certificates, or private endpoints. |
| DR-DOC-2 | Stable sample data | Tutorial models match the public JSONPlaceholder response used in runnable samples. |

### Analytics requirements

No runtime analytics are added because this feature is repository documentation. Documentation
success is validated through build gates and optional hosted-site analytics in a future DFR.

### Non-functional requirements

| ID | Requirement | Acceptance criteria |
|---|---|---|
| NFR-DOC-1 | DocC validity | The catalog converts with no diagnostics attributable to new content. |
| NFR-DOC-2 | Runtime compatibility | `swift build` and `swift test` continue to pass without package dependency changes. |
| NFR-DOC-3 | Accessibility | Tutorial prose does not rely on images or color to communicate required information. |
| NFR-DOC-4 | Maintainability | Pages link to symbols and concepts instead of copying the full API reference. |
| NFR-DOC-5 | Static delivery | The documentation website builds to deployable static assets with no runtime database or required credentials. |
| NFR-DOC-6 | CI reliability | The website build is isolated from Swift package dependencies and fails CI on compile or static-generation errors. |

### Edge cases

| ID | Scenario | Expected documentation behavior |
|---|---|---|
| EC-DOC-1 | Reader has no authenticated user | Use `authScope: "public"` and explain when `nil` is appropriate. |
| EC-DOC-2 | Two calls are sequential | Explain that coalescing applies only while equivalent work overlaps. |
| EC-DOC-3 | POST is retried | Warn that non-idempotent writes require an idempotency strategy. |
| EC-DOC-4 | Public sample API is offline | Treat it as a learning endpoint, surface the typed error path, and avoid availability promises. |
| EC-DOC-5 | Reader uses only `NovaNetworkCore` | Point out that it contains contracts, not the batteries-included URLSession client. |
| EC-DOC-6 | JavaScript is unavailable | Core article and tutorial text remains present in generated HTML; only progressive enhancements such as copy feedback may be unavailable. |
| EC-DOC-7 | Site is hosted below a path prefix | Internal navigation and static assets use deployment-safe relative routing. |

## State and flow definition

| State | UI/content | Reader actions | Analytics |
|---|---|---|---|
| Discovering | README and DocC landing page | Choose Getting Started or tutorials | Not applicable |
| Installing | Getting Started installation section | Add the SwiftPM package and product | Not applicable |
| First success | First-request tutorial | Decode one typed response | Not applicable |
| Understanding | Coalescing and concepts tutorial | Run overlapping requests and inspect metrics | Not applicable |
| Hardening | Resilience tutorial and production checklist | Select retry/cache/error policies | Not applicable |
| Scaling | Endpoint tutorial and API-selection guide | Move repeated calls into endpoint types | Not applicable |
| Advancing | Auth, batch, offline, and realtime tutorials | Choose and complete a production scenario | Not applicable |
| Browsing on web | Standalone documentation site | Navigate, copy code, and move between guides | No analytics in V1 |
| Evaluating | Product landing page | Compare current networking pain with NovaNetworkClient capabilities | No analytics in V1 |
| Adopting | Product CTA and Getting Started | Open installation steps, GitHub, or a guided tutorial | No analytics in V1 |

Transitions: `Discovering -> Evaluating -> Adopting -> Installing -> First success -> Understanding -> Hardening -> Scaling -> Advancing`.
Readers may jump directly from Discovering to the production checklist or API reference.

## Test matrix

| Requirement ID | Test ID | Verification | Owner |
|---|---|---|---|
| FR-DOC-1, FR-DOC-4 | T-DOC-LINKS | Link and topic audit | Engineering |
| FR-DOC-2, UR-DOC-1, UR-DOC-2 | T-DOC-DOCC | DocC conversion | Engineering |
| UR-DOC-5 | T-DOC-HIGHLIGHTS | Inspect rendered tutorial JSON and verify every code reference has a non-empty `highlights` collection | Engineering |
| FR-DOC-3, DR-DOC-1, DR-DOC-2 | T-DOC-CODE | Type-check every tutorial resource | Engineering |
| FR-DOC-5, UR-DOC-4 | T-DOC-REVIEW | Concept coverage review | Product + Engineering |
| NFR-DOC-2 | T-DOC-REGRESSION | `swift build` and `swift test` | QA |
| EC-DOC-1...5 | T-DOC-EDGE | Editorial checklist | Product + Engineering |
| FR-DOC-6, UR-DOC-1, UR-DOC-5 | T-DOC-ADVANCED | DocC conversion, highlight audit, and complete-resource type-check | Engineering |
| FR-DOC-7, UR-DOC-6, UR-DOC-7, NFR-DOC-5 | T-WEB-BUILD | Production website build and generated-route audit | Engineering |
| FR-DOC-8, NFR-DOC-6 | T-WEB-CI | CI workflow syntax and website build gate | QA |
| EC-DOC-6, EC-DOC-7 | T-WEB-STATIC | Inspect generated HTML, relative links, and static assets | Engineering |
| FR-DOC-9...11, UR-DOC-8, UR-DOC-9 | T-WEB-PRODUCT | Content audit against `Package.swift`, public API, examples, tests, and license plus responsive CTA review | Product + Engineering |
| UR-DOC-5, UR-DOC-10 | T-DOC-ACTION-CODE | Audit every run, verify, inspect, and adaptation step for a code directive and non-empty rendered highlights | Engineering |

## Engineering notes

- The tutorials use native `.tutorial` files and `@Code` resources so Xcode renders the same
  chapter/section/step experience used by Apple Developer Tutorials.
- Runtime code is unchanged. Documentation examples intentionally build as standalone `@main`
  programs so the code shown to readers can be type-checked directly.
- The standalone site lives in `DocumentationSite`, server-renders its core content without a
  database or credentials, and is validated by a dedicated GitHub Actions build job.
