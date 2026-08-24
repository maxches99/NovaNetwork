# What's New in NovaNetworkClient 2.10

## Guided documentation

NovaNetworkClient now includes a Swift-DocC learning path modeled after Apple Developer Tutorials.
It is organized into chapters, short sections, numbered steps, explanations, experiments, and
complete source files:

Each code step compares a progressive source snapshot with the previous step, so Xcode's DocC
renderer visibly highlights the exact lines introduced at that point in the tutorial.
Run, verification, inspection, and adaptation steps now include their own actionable code instead
of ending with prose-only instructions.

- Build your first typed request.
- Share concurrent requests and inspect coalescer metrics.
- Add bounded retry and cache policies.
- Model reusable operations as typed endpoints.
- Refresh authentication once per credential scope.
- Load ordered batches with bounded concurrency.
- Queue idempotent writes for offline replay.
- Open and manage a realtime WebSocket channel.

## Standalone documentation website

A responsive browser-first site now complements the native DocC experience. Its product-led home
page explains the production networking problems NovaNetworkClient solves, its execution model,
verified capabilities, and a clear adoption path. It also includes prominent Get Started and
GitHub actions, repository-backed quality facts, a product comparison, and a new social preview.

The learning experience includes a complete Getting Started page, an eight-tutorial catalog,
focused lesson pages with copyable Swift snippets, previous/next navigation, core concepts, and a
production build that runs in CI.

Open the deployed [NovaNetworkClient Documentation](https://novanetworkclient-docs.maxchesnikov.chatgpt.site).

## Complete onboarding

The new Getting Started guide covers supported platforms, installation from Xcode or a package
manifest, response modeling, request creation, typed loading, `authScope`, error handling, and
recommended next steps.

New conceptual articles explain request identity, API selection, client lifetime, retry and cache
boundaries, and a production-readiness checklist.

## Compatibility and rollout

- Runtime behavior and public APIs are unchanged.
- No dependency or migration is required.
- Open the package documentation in Xcode to use the interactive tutorial renderer.
- Build `DocumentationSite` with pnpm to produce the standalone web artifact.
- Markdown sources remain readable directly in the repository.

## Requirement traceability

Implemented requirements: `FR-DOC-1...11`, `UR-DOC-1...10`, `DR-DOC-1...2`,
`NFR-DOC-1...6`, and `EC-DOC-1...7` from
[`DOCUMENTATION_EXPERIENCE_DFR.md`](dfr/DOCUMENTATION_EXPERIENCE_DFR.md).
