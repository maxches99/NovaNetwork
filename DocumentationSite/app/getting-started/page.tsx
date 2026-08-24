import type { Metadata } from "next";
import Link from "next/link";
import { CodeBlock } from "../components/CodeBlock";
import { SiteShell } from "../components/SiteShell";

export const metadata: Metadata = { title: "Getting Started" };

export default function GettingStartedPage() {
  return (
    <SiteShell active="start"><main className="article-layout">
      <aside className="article-toc"><p>On this page</p><a href="#requirements">Requirements</a><a href="#install">Install</a><a href="#request">First request</a><a href="#errors">Errors</a><a href="#next">Next steps</a></aside>
      <article className="prose">
        <header className="page-hero"><p className="eyebrow">Start here</p><h1>Getting Started</h1><p>Install NovaNetworkClient and decode your first typed response in a few focused steps.</p></header>
        <section id="requirements"><h2>Requirements</h2><div className="requirements"><div><strong>Swift</strong><span>6.2 or newer</span></div><div><strong>Platforms</strong><span>macOS 13+, iOS 16+</span></div><div><strong>Concurrency</strong><span>async/await</span></div></div></section>
        <section id="install"><h2>Install the package</h2><p>Add the repository URL in Xcode’s Package Dependencies panel, then link <code>NovaNetworkClient</code> to your target.</p><CodeBlock filename="Package.swift" code={`dependencies: [
    .package(
        url: "https://github.com/maxches99/NovaNetwork.git",
        from: "2.10.0"
    )
]`} /></section>
        <section id="request"><h2>Make your first request</h2><p>Import the package, describe the response, and let the generic return type drive decoding.</p><CodeBlock filename="FirstRequest.swift" code={`import Foundation
import NovaNetworkClient

struct Todo: Decodable, Sendable {
    let id: Int
    let title: String
    let completed: Bool
}

let client = NetworkClient(transport: Transport())
let request = APIRequest(
    method: .get,
    url: URL(string: "https://jsonplaceholder.typicode.com/todos/1")!
)
let todo: Todo = try await client.load(
    request: request,
    authScope: "public"
)`} /></section>
        <section id="errors"><h2>Keep errors visible</h2><p><code>NetworkError</code> separates HTTP, transport, decoding, and cancellation failures. Handle only cases that change feature behavior and let the rest flow to your normal error surface.</p></section>
        <section id="next"><h2>Continue learning</h2><div className="next-cards"><Link href="/tutorials/first-request"><strong>Build your first request</strong><span>Follow the guided version →</span></Link><Link href="/concepts"><strong>Understand shared work</strong><span>Explore request identity →</span></Link></div></section>
      </article>
    </main></SiteShell>
  );
}
