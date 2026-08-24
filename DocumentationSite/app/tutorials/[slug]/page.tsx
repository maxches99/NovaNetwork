import type { Metadata } from "next";
import Link from "next/link";
import { notFound } from "next/navigation";
import { CodeBlock } from "../../components/CodeBlock";
import { SiteShell } from "../../components/SiteShell";
import { tutorialForSlug, tutorials } from "../../docs-data";

export function generateStaticParams() { return tutorials.map(({ slug }) => ({ slug })); }

export async function generateMetadata({ params }: { params: Promise<{ slug: string }> }): Promise<Metadata> {
  const tutorial = tutorialForSlug((await params).slug);
  return { title: tutorial?.title ?? "Tutorial" };
}

export default async function TutorialPage({ params }: { params: Promise<{ slug: string }> }) {
  const tutorial = tutorialForSlug((await params).slug);
  if (!tutorial) notFound();
  const index = tutorials.findIndex((item) => item.slug === tutorial.slug);
  const previous = tutorials[index - 1];
  const next = tutorials[index + 1];

  return (
    <SiteShell active="tutorials">
      <main className="tutorial-layout">
        <aside className="lesson-nav" aria-label="Tutorial progress">
          <Link className="back-link" href="/tutorials">← All tutorials</Link>
          <p className="eyebrow">{tutorial.eyebrow}</p>
          <h2>{tutorial.title}</h2>
          <ol>{tutorial.steps.map((step, stepIndex) => <li key={step.title}><a href={`#step-${stepIndex + 1}`}><span>{stepIndex + 1}</span>{step.title}</a></li>)}</ol>
          <div className="lesson-progress"><span style={{ width: `${((index + 1) / tutorials.length) * 100}%` }} /><small>{index + 1} of {tutorials.length} tutorials</small></div>
        </aside>
        <article className="lesson-content">
          <header className="lesson-hero">
            <p className="eyebrow">{tutorial.level} · {tutorial.duration}</p>
            <h1>{tutorial.title}</h1>
            <p>{tutorial.summary}</p>
            <div className="outcome"><strong>You’ll build</strong><span>{tutorial.outcome}</span></div>
          </header>
          {tutorial.steps.map((step, stepIndex) => (
            <section className="lesson-step" id={`step-${stepIndex + 1}`} key={step.title}>
              <div className="step-heading"><span>{stepIndex + 1}</span><div><small>Step {stepIndex + 1}</small><h2>{step.title}</h2></div></div>
              <p>{step.explanation}</p>
              {step.code && <CodeBlock code={step.code} filename={`${tutorial.title.replaceAll(" ", "")}.swift`} />}
              {step.note && <aside className="note">{step.note}</aside>}
            </section>
          ))}
          <section className="completion"><span>✓</span><div><p className="eyebrow">Tutorial complete</p><h2>{tutorial.outcome}</h2></div></section>
          <nav className="lesson-pagination" aria-label="Adjacent tutorials">
            {previous ? <Link href={`/tutorials/${previous.slug}`}><small>Previous</small><strong>← {previous.title}</strong></Link> : <span />}
            {next ? <Link className="next" href={`/tutorials/${next.slug}`}><small>Next</small><strong>{next.title} →</strong></Link> : <Link className="next" href="/concepts"><small>Next</small><strong>Core concepts →</strong></Link>}
          </nav>
        </article>
      </main>
    </SiteShell>
  );
}
