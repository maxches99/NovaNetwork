"use client";

import { useCallback, useEffect, useLayoutEffect, useRef, useState } from "react";
import type { Tutorial } from "../docs-data";
import { CodeBlock } from "./CodeBlock";

type Phase = "opening" | "open" | "closing";

type OpenRequest = { index: number; originRect: DOMRect };

export function TutorialLightbox({ tutorials }: { tutorials: Tutorial[] }) {
  const [request, setRequest] = useState<OpenRequest | null>(null);
  const [index, setIndex] = useState(0);
  const [phase, setPhase] = useState<Phase>("opening");
  const frameRef = useRef<HTMLDivElement | null>(null);
  const originRectRef = useRef<DOMRect | null>(null);

  useEffect(() => {
    function onOpen(event: Event) {
      const detail = (event as CustomEvent<OpenRequest>).detail;
      originRectRef.current = detail.originRect;
      setIndex(detail.index);
      setPhase("opening");
      setRequest(detail);
      document.body.style.overflow = "hidden";
      const tutorial = tutorials[detail.index];
      window.history.pushState({ lightbox: tutorial.slug }, "", `/tutorials/${tutorial.slug}`);
    }
    window.addEventListener("tutorial-lightbox:open", onOpen);
    return () => window.removeEventListener("tutorial-lightbox:open", onOpen);
  }, [tutorials]);

  const close = useCallback((skipHistory?: boolean) => {
    setPhase("closing");
    const frame = frameRef.current;
    const originRect = originRectRef.current;
    if (frame && originRect) {
      const finalRect = frame.getBoundingClientRect();
      const dx = originRect.left + originRect.width / 2 - (finalRect.left + finalRect.width / 2);
      const dy = originRect.top + originRect.height / 2 - (finalRect.top + finalRect.height / 2);
      const sx = originRect.width / finalRect.width;
      const sy = originRect.height / finalRect.height;
      frame.style.transition = "transform .32s cubic-bezier(.5,0,.3,1), opacity .28s ease";
      frame.style.transform = `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})`;
      frame.style.opacity = "0";
    }
    window.setTimeout(() => {
      setRequest(null);
      document.body.style.overflow = "";
    }, 320);
    if (!skipHistory) window.history.pushState({}, "", "/tutorials");
  }, []);

  const go = useCallback((step: 1 | -1) => {
    setIndex((current) => {
      const next = (current + step + tutorials.length) % tutorials.length;
      const tutorial = tutorials[next];
      window.history.pushState({ lightbox: tutorial.slug }, "", `/tutorials/${tutorial.slug}`);
      return next;
    });
  }, [tutorials]);

  useEffect(() => {
    function onPop() {
      if (request) close(true);
    }
    window.addEventListener("popstate", onPop);
    return () => window.removeEventListener("popstate", onPop);
  }, [request, close]);

  useEffect(() => {
    if (!request) return;
    function onKey(event: KeyboardEvent) {
      if (event.key === "Escape") close();
      if (event.key === "ArrowRight") go(1);
      if (event.key === "ArrowLeft") go(-1);
    }
    window.addEventListener("keydown", onKey);
    return () => window.removeEventListener("keydown", onKey);
  }, [request, close, go]);

  useLayoutEffect(() => {
    if (!request || phase !== "opening") return;
    const frame = frameRef.current;
    const originRect = originRectRef.current;
    if (!frame || !originRect) return;
    const finalRect = frame.getBoundingClientRect();
    const dx = originRect.left + originRect.width / 2 - (finalRect.left + finalRect.width / 2);
    const dy = originRect.top + originRect.height / 2 - (finalRect.top + finalRect.height / 2);
    const sx = originRect.width / finalRect.width;
    const sy = originRect.height / finalRect.height;
    frame.style.transition = "none";
    frame.style.transform = `translate(${dx}px, ${dy}px) scale(${sx}, ${sy})`;
    frame.style.opacity = "0.5";
    requestAnimationFrame(() => {
      requestAnimationFrame(() => {
        frame.style.transition = "transform .42s cubic-bezier(.16,.9,.28,1), opacity .32s ease";
        frame.style.transform = "translate(0px, 0px) scale(1, 1)";
        frame.style.opacity = "1";
        setPhase("open");
      });
    });
  }, [request, phase]);

  if (!request) return null;
  const tutorial = tutorials[index];
  const progress = ((index + 1) / tutorials.length) * 100;

  return (
    <div className={`lightbox-scrim phase-${phase}`} onClick={() => close()} role="presentation">
      <div
        className="lightbox-frame"
        ref={frameRef}
        onClick={(event) => event.stopPropagation()}
        role="dialog"
        aria-modal="true"
        aria-label={tutorial.title}
      >
        <div className="lightbox-toolbar">
          <button type="button" className="lightbox-close" onClick={() => close()} aria-label="Close tutorial">✕</button>
          <span className="lightbox-count">{String(index + 1).padStart(2, "0")} / {String(tutorials.length).padStart(2, "0")}</span>
          <div className="lightbox-arrows">
            <button type="button" onClick={() => go(-1)} aria-label="Previous tutorial">←</button>
            <button type="button" onClick={() => go(1)} aria-label="Next tutorial">→</button>
          </div>
        </div>
        <div className="lightbox-body" key={tutorial.slug}>
          <aside className="lightbox-nav">
            <p className="eyebrow">{tutorial.eyebrow}</p>
            <h2>{tutorial.title}</h2>
            <ol>
              {tutorial.steps.map((step, stepIndex) => (
                <li key={step.title}>
                  <a href={`#lightbox-step-${stepIndex + 1}`}><span>{stepIndex + 1}</span>{step.title}</a>
                </li>
              ))}
            </ol>
            <div className="lesson-progress"><span style={{ width: `${progress}%` }} /><small>{index + 1} of {tutorials.length} tutorials</small></div>
          </aside>
          <article className="lightbox-content">
            <header className="lesson-hero">
              <p className="eyebrow">{tutorial.level} · {tutorial.duration}</p>
              <h1>{tutorial.title}</h1>
              <p>{tutorial.summary}</p>
              <div className="outcome"><strong>You’ll build</strong><span>{tutorial.outcome}</span></div>
            </header>
            {tutorial.steps.map((step, stepIndex) => (
              <section className="lesson-step" id={`lightbox-step-${stepIndex + 1}`} key={step.title}>
                <div className="step-heading"><span>{stepIndex + 1}</span><div><small>Step {stepIndex + 1}</small><h2>{step.title}</h2></div></div>
                <p>{step.explanation}</p>
                {step.code && <CodeBlock code={step.code} filename={`${tutorial.title.replaceAll(" ", "")}.swift`} />}
                {step.note && <aside className="note">{step.note}</aside>}
              </section>
            ))}
            <section className="completion"><span>✓</span><div><p className="eyebrow">Tutorial complete</p><h2>{tutorial.outcome}</h2></div></section>
            <nav className="lesson-pagination" aria-label="Adjacent tutorials">
              <button type="button" onClick={() => go(-1)}><small>Previous</small><strong>← {tutorials[(index - 1 + tutorials.length) % tutorials.length].title}</strong></button>
              <button type="button" className="next" onClick={() => go(1)}><small>Next</small><strong>{tutorials[(index + 1) % tutorials.length].title} →</strong></button>
            </nav>
          </article>
        </div>
      </div>
    </div>
  );
}

export function openTutorialLightbox(index: number, originEl: HTMLElement) {
  const originRect = originEl.getBoundingClientRect();
  window.dispatchEvent(new CustomEvent("tutorial-lightbox:open", { detail: { index, originRect } }));
}
