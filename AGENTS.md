# AGENTS.md

## Purpose
This repository contains a Swift Package (`RequestCoalescer`).
Use this file as the default operating guide for coding agents.

## Project Layout
- `Sources/` - library source code
- `Tests/` - unit tests
- `Package.swift` - SwiftPM manifest
- `README.md` - usage and examples
- `docs/` - additional documentation

## Environment
- Platform: macOS
- Language: Swift
- Build tool: Swift Package Manager

## Commands
- Build: `swift build`
- Test: `swift test`
- Run a specific test: `swift test --filter <TestName>`

## Working Rules
- Keep changes minimal and focused on the requested task.
- Prefer fixing root causes over adding workarounds.
- Do not break public API without updating tests and docs.
- Add or update tests for behavior changes.
- Keep code style consistent with surrounding files.
- Avoid adding dependencies unless explicitly requested.

## Validation Checklist
Before finishing:
1. Build succeeds (`swift build`).
2. Tests pass (`swift test`).
3. `README.md` is updated if user-facing behavior changed.

## Git Hygiene
- Do not revert unrelated local changes.
- Do not use destructive git commands unless explicitly requested.
- Keep commits small and task-focused.

