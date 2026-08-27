import Link from "next/link";
import { SiteShell } from "./components/SiteShell";
import { tutorials } from "./docs-data";

const capabilities = [
  ["01", "Shared in-flight work", "Equivalent callers join one request. Each caller keeps independent cancellation semantics."],
  ["02", "Resilience policies", "Retry, rate limiting, circuit breaking, and HTTP-aware caching live in one execution pipeline."],
  ["03", "Authentication refresh", "Coordinate token refresh and prevent a burst of unauthorized requests from becoming a refresh stampede."],
  ["04", "Offline delivery", "Queue writes, replay them deliberately, and model recovery instead of hiding it behind a transport wrapper."],
  ["05", "Realtime & transfers", "Use WebSocket, Server-Sent Events, multipart uploads, downloads, and progress APIs from the same package."],
  ["06", "Observable by design", "Inspect lifecycle events, metrics, diagnostics, and deterministic test support without replacing the client."],
  ["07", "Declarative endpoints", "Generate request construction from an annotated Swift type, or generate whole endpoint types from an OpenAPI document."],
  ["08", "Record and replay", "Capture real traffic into a reviewable cassette and replay it in tests, previews, and offline demo builds."],
] as const;

export default function Home() {
  return (
    <SiteShell active="home">
      <main className="marketing-home">
        <section className="product-hero" id="product">
          <div className="product-hero-copy">
            <p className="eyebrow">Production networking for Swift 6.2+</p>
            <h1>Stop rebuilding your network layer.</h1>
            <p className="product-lede">
              NovaNetworkClient turns typed requests, shared work, cancellation, resilience,
              authentication, offline delivery, and realtime connections into one coherent system.
            </p>
            <div className="hero-actions">
              <Link className="button primary" href="/getting-started">Add Nova to your app <span>→</span></Link>
              <a className="button secondary" href="#how-it-works">See how it works</a>
            </div>
            <div className="hero-note"><span>✓</span> Zero third-party runtime dependencies · Apache 2.0</div>
          </div>

          <div className="request-visual" aria-label="Two callers share one network request">
            <div className="visual-toolbar"><span />Request pipeline</div>
            <div className="caller-stack">
              <div className="caller"><span className="caller-icon">A</span><div><strong>ProfileView</strong><small>GET /users/42</small></div><b>→</b></div>
              <div className="caller"><span className="caller-icon purple">B</span><div><strong>HeaderView</strong><small>GET /users/42</small></div><b>→</b></div>
            </div>
            <div className="shared-request"><small>ONE SHARED TASK</small><strong>Request fingerprint</strong><code>GET · /users/42 · public</code></div>
            <div className="policy-row"><span>Retry</span><span>Cache</span><span>Auth</span><span>Metrics</span></div>
            <div className="visual-result"><span>200</span><strong>One response, two typed values</strong></div>
          </div>
        </section>

        <section className="proof-strip" aria-label="Project facts">
          <div><strong>451</strong><span>automated tests</span></div>
          <div><strong>90%+</strong><span>unit coverage policy</span></div>
          <div><strong>3</strong><span>library products</span></div>
          <div><strong>0</strong><span>third-party dependencies</span></div>
        </section>

        <section className="marketing-section problem-section">
          <div className="section-kicker">
            <p className="eyebrow">The real problem</p>
            <h2>Networking starts simple.<br />Production doesn&apos;t.</h2>
          </div>
          <div className="problem-grid">
            <article><span>01</span><h3>Duplicate work</h3><p>Multiple screens ask for the same resource and quietly multiply traffic, decoding, and battery cost.</p></article>
            <article><span>02</span><h3>Policy sprawl</h3><p>Retry loops, cache rules, auth locks, and cancellation flags accumulate across services and view models.</p></article>
            <article><span>03</span><h3>Invisible failure modes</h3><p>Offline writes, reconnects, rate limits, and token expiry appear only after the happy path ships.</p></article>
          </div>
        </section>

        <section className="solution-panel" id="how-it-works">
          <div className="solution-copy">
            <p className="eyebrow">One execution model</p>
            <h2>Describe intent once. Let policies do the hard work.</h2>
            <p>A stable request identity gives Nova one place to coordinate callers and apply production behavior. The API stays explicit while the infrastructure stays reusable.</p>
            <Link className="text-link light-link" href="/concepts">Explore the architecture →</Link>
          </div>
          <ol className="pipeline-steps">
            <li><span>1</span><div><strong>Describe</strong><p>Method, URL, body, headers, and authentication scope form a typed request.</p></div></li>
            <li><span>2</span><div><strong>Coordinate</strong><p>A deterministic fingerprint joins equivalent in-flight work and tracks each subscriber.</p></div></li>
            <li><span>3</span><div><strong>Execute</strong><p>Resilience, cache, auth, transport, decoding, and telemetry run through one pipeline.</p></div></li>
          </ol>
        </section>

        <section className="marketing-section" id="features">
          <div className="center-heading">
            <p className="eyebrow">Batteries included, decisions exposed</p>
            <h2>A production stack, not another thin URLSession wrapper.</h2>
            <p>Adopt the pieces you need today without painting the next feature into a corner.</p>
          </div>
          <div className="capability-grid">
            {capabilities.map(([number, title, body]) => (
              <article key={number}><span>{number}</span><h3>{title}</h3><p>{body}</p></article>
            ))}
          </div>
        </section>

        <section className="comparison-section">
          <div className="comparison-copy">
            <p className="eyebrow">From ad hoc to intentional</p>
            <h2>Keep business code about the request—not the machinery around it.</h2>
          </div>
          <div className="comparison-card before"><small>WITHOUT A COHERENT CLIENT</small><ul><li>Task dictionaries in every feature</li><li>Retry rules copied between services</li><li>Refresh locks tied to UI state</li><li>Logs that cannot explain shared work</li></ul></div>
          <div className="comparison-card after"><small>WITH NOVANETWORKCLIENT</small><ul><li>Stable request identity</li><li>Composable, explicit policies</li><li>Coordinated auth and cancellation</li><li>Lifecycle events and metrics</li></ul></div>
        </section>

        <section className="code-story">
          <div className="code-story-copy">
            <p className="eyebrow">Small surface, serious behavior</p>
            <h2>Your first typed response stays readable.</h2>
            <p>The simple case remains simple. Production capabilities are configured around it instead of leaking into every call site.</p>
            <Link className="button secondary" href="/getting-started">Read Getting Started</Link>
          </div>
          <div className="hero-code">
            <div className="code-window-title"><span />ProfileService.swift</div>
            <pre><code>{`let request = APIRequest(
    method: .get,
    url: apiURL.appending(path: "users/42")
)

let profile: Profile = try await client.load(
    request: request,
    authScope: "current-user"
)`}</code></pre>
            <div className="code-result"><span>✓</span> Typed, cancellable, observable, and shareable</div>
          </div>
        </section>

        <section className="marketing-section learning-preview">
          <div className="section-heading">
            <div><p className="eyebrow">Learn by building</p><h2>From first request to production confidence.</h2></div>
            <Link className="text-link" href="/tutorials">All {tutorials.length} tutorials →</Link>
          </div>
          <div className="tutorial-grid">
            {tutorials.slice(0, 4).map((tutorial, index) => (
              <Link className="tutorial-card" href={`/tutorials/${tutorial.slug}`} key={tutorial.slug}>
                <span className="card-number">{String(index + 1).padStart(2, "0")}</span>
                <span className={`card-icon tone-${tutorial.tone}`}>{tutorial.symbol}</span>
                <h3>{tutorial.title}</h3><p>{tutorial.summary}</p>
                <span className="card-meta">{tutorial.duration} · {tutorial.steps.length} steps</span>
              </Link>
            ))}
          </div>
        </section>

        <section className="final-product-cta">
          <p className="eyebrow">Built for the code after the prototype</p>
          <h2>Ship the network layer once.</h2>
          <p>Start with one typed request. Add production policies when your app needs them.</p>
          <div className="hero-actions"><Link className="button light" href="/getting-started">Get started in 10 minutes</Link><a className="button ghost" href="https://github.com/maxches99/NovaNetwork" rel="noreferrer">View on GitHub ↗</a></div>
        </section>
      </main>
    </SiteShell>
  );
}
