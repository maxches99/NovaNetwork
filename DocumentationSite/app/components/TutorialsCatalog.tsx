"use client";

import Link from "next/link";
import type { MouseEvent } from "react";
import type { Tutorial } from "../docs-data";
import { openTutorialLightbox, TutorialLightbox } from "./TutorialLightbox";

export function TutorialsCatalog({ tutorials }: { tutorials: Tutorial[] }) {
  function handleClick(event: MouseEvent<HTMLAnchorElement>, index: number) {
    if (event.defaultPrevented || event.button !== 0) return;
    if (event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
    event.preventDefault();
    openTutorialLightbox(index, event.currentTarget);
  }

  return (
    <>
      <div className="catalog-list">
        {tutorials.map((tutorial, index) => (
          <Link
            className="catalog-item"
            href={`/tutorials/${tutorial.slug}`}
            key={tutorial.slug}
            onClick={(event) => handleClick(event, index)}
          >
            <span className="catalog-index">{String(index + 1).padStart(2, "0")}</span>
            <span className={`card-icon tone-${tutorial.tone}`}>{tutorial.symbol}</span>
            <span className="catalog-copy"><small>{tutorial.eyebrow}</small><strong>{tutorial.title}</strong><span>{tutorial.summary}</span></span>
            <span className="catalog-meta">{tutorial.level}<br />{tutorial.duration}</span>
            <span className="catalog-arrow">→</span>
          </Link>
        ))}
      </div>
      <TutorialLightbox tutorials={tutorials} />
    </>
  );
}
