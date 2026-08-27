# NovaDiagnosticsDemo

A small iOS app that exists for one reason: to let you look at
`NovaNetworkDiagnostics` with your own eyes, on a device, with real recorded
traffic in it.

It is a separate Xcode project that consumes this repository as a **local**
Swift package (`XCLocalSwiftPackageReference` pointing at `..`), so it always
builds against the working copy — edit the library, hit run, see the change.

## Running it

Open `NovaDiagnosticsDemo.xcodeproj` and run on any iOS 17 simulator, or from
the command line:

```bash
xcodebuild -project DemoApp/NovaDiagnosticsDemo.xcodeproj -scheme NovaDiagnosticsDemo -destination 'generic/platform=iOS Simulator' build
```

## Two backends

The **Backend** picker decides where the traffic goes, and nothing else about
the app changes when you move it:

- **Scripted** (the default) answers from `DemoAPI`, a `NetworkTransport` inside
  the app. No network, no server, no credentials, and every scenario behaves
  identically on every run.
- **Live** sends real HTTPS requests through the package's `Transport`. It
  defaults to `https://httpbin.org` and the paths follow the httpbin contract,
  so any httpbin-compatible host works — `httpbingo.org`, or one you run
  yourself. Edit the **Host** field to point it somewhere else.

Switching backends builds a new client and clears the recorder, so one list is
never showing two backends' requests.

The live flaky endpoint (`/status/200,503`) really does return either status at
random, so the retry scenario is a genuine coin flip rather than a script — and
the timings in the waterfall are whatever the network gave you.

## Driving it from a script

Two launch arguments, for screenshots and for showing the panel without tapping
anything:

```bash
xcrun simctl launch booted com.novanetwork.diagnosticsdemo --args --autorun
xcrun simctl launch booted com.novanetwork.diagnosticsdemo --args --autorun --live
```

`--autorun` runs every scenario and opens the panel; `--live` starts on the live
backend.

## What the scenarios show

| Scenario | Scripted | Live | What the panel proves |
| --- | --- | --- | --- |
| Retry until it works | `/flaky` | `/status/200,503` | The waterfall attributes elapsed time to backoff rather than to the server. |
| Two callers, one request | `/profile` | `/json` | Two concurrent loads produce one transport call; the record is marked coalesced. |
| Read it twice | `/settings` | `/uuid` | The second read is served from cache and never reaches the transport. |
| Server says no | `/orders` | `/status/422` | A 422 is recorded as a failure and counts in the summary's failure rate. |
| Give up waiting | `/slow` | `/delay/8` | The caller cancels after 150 ms; the operation keeps running and the panel still shows it in flight. |

The `Authorization` header is sent as a real bearer token and appears in the
panel already redacted — the redaction is the library's, not the demo's.

The toolbar button opens `NetworkDiagnosticsView`; its export action writes a
HAR 1.2 file into the app's Documents directory, which is what a support build
would do.

## How it is wired

The whole integration is four lines in [DemoSession.swift](NovaDiagnosticsDemo/DemoSession.swift):

```swift
let recorder = DiagnosticsRecorder(options: DiagnosticsOptions(capacity: 100, emitsSignposts: true))

var configuration = NetworkClientConfiguration()
configuration.telemetryHooks = recorder.hooks
client = NetworkClient(configuration: configuration)
recorder.startConsuming(client.events())
```

Nothing else in the app knows diagnostics exists.

## Tests

`NovaDiagnosticsDemoUITests` covers the part of the panel a unit test cannot
reach: whether a row in the request list is actually tappable, and whether the
backend picker rewrites the paths. Both run offline.

```bash
xcodebuild test -project DemoApp/NovaDiagnosticsDemo.xcodeproj -scheme NovaDiagnosticsDemo -destination 'platform=iOS Simulator,name=iPhone 17'
```
