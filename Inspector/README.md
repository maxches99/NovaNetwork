# NovaNetworkInspector

A macOS app for reading a network trace someone sent you.

It opens HAR files — the ones `DiagnosticsRecorder.exportHAR()` writes, and the ones a browser,
Charles, or Proxyman write — and shows them with the same `NetworkDiagnosticsView` a live app
embeds. It is a reader, not a proxy: it never attaches to a running process.

## Running it

Open `NovaNetworkInspector.xcodeproj` and run, or from the command line:

```bash
xcodebuild -project Inspector/NovaNetworkInspector.xcodeproj -scheme NovaNetworkInspector -destination 'platform=macOS' build
```

Like the demo app, it consumes this repository as a **local** Swift package, so it always builds
against the working copy.

## Opening a trace

Three ways, all equivalent:

- Drop a `.har` file on the window.
- **File ▸ Open…** (⌘O).
- From the shell or the Finder: `open -a NovaNetworkInspector trace.har`.

Each window holds one trace, so **File ▸ New Window** (⌘N is Open here) lets you keep two side by
side. The file name and request count are in the window subtitle.

## What you get

The same two views the panel offers in an app:

- **List** — newest request first, with status, duration, and the retry, coalescing, and cache
  badges.
- **Timeline** — every request on one clock, so overlap, coalescing, and backoff are visible at a
  glance.

Selecting a request shows its outcome, its attempt waterfall, and its headers.

What HAR carries, the inspector shows. What it does not carry, the inspector does not invent: a HAR
has no field for attempt timings, so a retried request read from a file shows the right number of
attempts stamped at the request's start.

## Producing a trace to open

From an app that has a recorder installed:

```swift
let har = try await recorder.exportHAR()
try har.write(to: url)
```

The [demo app](../DemoApp/README.md) does exactly this from its Diagnostics panel's export button.

## Signing and sandbox

The project signs ad hoc and does not enable the app sandbox, because it is a developer tool that
reads files you hand it. If you want a sandboxed build, turn `ENABLE_APP_SANDBOX` on and add the
user-selected-files read entitlement; the model already brackets its read with a security-scoped
resource, so nothing else needs to change.
