import type { Metadata } from "next";
import Link from "next/link";
import { SiteShell } from "../components/SiteShell";

export const metadata: Metadata = { title: "Core Concepts" };

const concepts = [
  ["01", "Request identity", "Method, canonical URL, selected headers, body, and authScope form the fingerprint used to decide whether work is equivalent."],
  ["02", "Shared ownership", "Callers await one underlying task but retain independent cancellation ownership. The network operation ends when no interested caller remains."],
  ["03", "Freshness vs overlap", "Coalescing shares work that overlaps in time. Caching can serve a later caller according to an explicit freshness policy."],
  ["04", "Bounded resilience", "Retry, auth refresh, batch concurrency, reconnect, and replay all need finite limits that match the product’s failure contract."],
  ["05", "Typed boundaries", "APIRequest describes wire intent. Endpoint adds a reusable typed response contract. NetworkClient owns execution policies."],
  ["06", "Operational visibility", "Lifecycle events and telemetry hooks expose coalescing, retries, queues, batches, and realtime transitions without changing feature code."],
];

export default function ConceptsPage() {
  return <SiteShell active="concepts"><main className="content-main"><header className="page-hero compact"><p className="eyebrow">Architecture</p><h1>Core concepts</h1><p>A mental model for predictable networking under concurrency and failure.</p></header><div className="concept-grid">{concepts.map(([number, title, body]) => <article key={number}><span>{number}</span><h2>{title}</h2><p>{body}</p></article>)}</div><section className="production-cta"><div><p className="eyebrow">Ready to ship?</p><h2>Turn the concepts into a production configuration.</h2></div><Link className="button light" href="/tutorials/resilience">Add bounded resilience</Link></section></main></SiteShell>;
}
