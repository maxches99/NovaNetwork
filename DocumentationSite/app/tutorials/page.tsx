import type { Metadata } from "next";
import { SiteShell } from "../components/SiteShell";
import { TutorialsCatalog } from "../components/TutorialsCatalog";
import { tutorials } from "../docs-data";

export const metadata: Metadata = { title: "Tutorials" };

export default function TutorialsPage() {
  return (
    <SiteShell active="tutorials">
      <main className="content-main">
        <header className="page-hero compact"><p className="eyebrow">Guided learning</p><h1>Tutorials</h1><p>Start with a typed request, then add production capabilities in a deliberate order.</p></header>
        <div className="path-line" aria-hidden="true" />
        <TutorialsCatalog tutorials={tutorials} />
      </main>
    </SiteShell>
  );
}
