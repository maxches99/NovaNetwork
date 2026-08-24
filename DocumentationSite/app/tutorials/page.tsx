import type { Metadata } from "next";
import Link from "next/link";
import { SiteShell } from "../components/SiteShell";
import { tutorials } from "../docs-data";

export const metadata: Metadata = { title: "Tutorials" };

export default function TutorialsPage() {
  return (
    <SiteShell active="tutorials">
      <main className="content-main">
        <header className="page-hero compact"><p className="eyebrow">Guided learning</p><h1>Tutorials</h1><p>Start with a typed request, then add production capabilities in a deliberate order.</p></header>
        <div className="path-line" aria-hidden="true" />
        <div className="catalog-list">
          {tutorials.map((tutorial, index) => (
            <Link className="catalog-item" href={`/tutorials/${tutorial.slug}`} key={tutorial.slug}>
              <span className="catalog-index">{String(index + 1).padStart(2, "0")}</span>
              <span className={`card-icon tone-${tutorial.tone}`}>{tutorial.symbol}</span>
              <span className="catalog-copy"><small>{tutorial.eyebrow}</small><strong>{tutorial.title}</strong><span>{tutorial.summary}</span></span>
              <span className="catalog-meta">{tutorial.level}<br />{tutorial.duration}</span>
              <span className="catalog-arrow">→</span>
            </Link>
          ))}
        </div>
      </main>
    </SiteShell>
  );
}
