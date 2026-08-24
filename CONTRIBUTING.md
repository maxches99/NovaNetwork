# Contributing

Thanks for considering a contribution to `NovaNetworkClient`. This file covers the practical
mechanics; [AGENTS.md](AGENTS.md) has the full process this project follows (DFR-first delivery,
traceability, test policy) in more detail and is kept as the source of truth for the full
contribution process — this file summarizes it for a first-time contributor.

## Requirements

- Swift 6.2+ (a Swift 6.3 compatibility CI lane also runs)
- Xcode with an Apple platform SDK, or the open-source Swift toolchain

## Building and testing

```bash
swift build
swift test
```

Run a single test:

```bash
swift test --filter <TestName>
```

E2E tests exercise real public APIs (`jsonplaceholder.typicode.com`, `httpbin.org`) and are
disabled by default. Mocks and stubs are not allowed in that suite — see
[Unit Test Policy](docs/UNIT_TEST_POLICY.md).

```bash
RUN_E2E_TESTS=1 swift test --filter E2ECoverageTests
```

Check strict-concurrency compilation before opening a PR — CI enforces it on both the minimum and
current Swift lanes:

```bash
swift build -Xswiftc -strict-concurrency=complete -Xswiftc -warn-concurrency
```

## Linting

There's no SwiftLint SwiftPM plugin dependency (this project avoids adding dependencies unless
there's a clear need for them); install SwiftLint separately and run it against
`.swiftlint.yml` at the repo root:

```bash
brew install swiftlint
swiftlint
```

## What a change needs

- **Keep changes minimal and focused.** A bug fix doesn't need surrounding cleanup; avoid
  abstractions beyond what the task requires.
- **Tests for behavior changes.** Unit test coverage must stay at or above 90% (CI enforces this
  with `llvm-cov`); a PR that drops it is blocked until coverage is restored.
- **Docs for user-facing changes.** Update `README.md` and add a
  `docs/WHATS_NEW_v<major>.<minor>.md` entry (see the
  [template](docs/templates/WHATS_NEW_TEMPLATE.md)) for anything a consumer of the package would
  notice. Add an entry to [CHANGELOG.md](CHANGELOG.md) linking it.
- **DocC comments on public API.** Document every `public`/`open` entity with `///` and keep it
  in sync with behavior.
- **No AI/assistant attribution in commits, code, or docs** for contributions to this
  repository — commit authorship belongs to the human contributor.

For a non-trivial feature, a DFR (Design/Functional Requirements document, see the
[template](docs/templates/DFR_TEMPLATE.md)) written before implementation is this project's
normal process — see [AGENTS.md](AGENTS.md#product-driven-delivery-dfr-first) for what one
contains and why. Small, self-contained changes (a bug fix, a small additive API) don't need one.

## API compatibility

CI runs `swift package diagnose-api-breaking-changes` against the most recently tagged release to
catch accidental breaking changes to public API. A small number of known, deliberate,
source-compatible differences are allowlisted in `docs/api-breakage-allowlist.txt` — that file
documents why each entry is there. If your change is intentionally breaking, discuss it in the PR
first; if CI flags something you didn't intend to change, that's the gate doing its job.

## Git hygiene

- Don't revert unrelated local changes.
- Don't use destructive git commands (`push --force`, `reset --hard`) unless explicitly asked.
- Keep commits small and task-focused.
- Never skip hooks (`--no-verify`) or bypass checks to make CI pass.

## Getting help

- [GitHub Issues](https://github.com/maxches99/NovaNetwork/issues) for bugs and feature requests.
- [Security Policy](SECURITY.md) for reporting vulnerabilities — please don't file those as
  public issues.
- [Code of Conduct](CODE_OF_CONDUCT.md) applies to all project spaces.
