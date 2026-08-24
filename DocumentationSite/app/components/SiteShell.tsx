import type { ReactNode } from "react";
import Link from "next/link";

type Props = { children: ReactNode; active?: "home" | "start" | "tutorials" | "concepts" };

const nav = [
  ["product", "Product", "/#product"],
  ["features", "Features", "/#features"],
  ["start", "Docs", "/getting-started"],
  ["tutorials", "Tutorials", "/tutorials"],
] as const;

export function SiteShell({ children, active }: Props) {
  return (
    <div className="site-frame">
      <header className="topbar">
        <Link className="brand" href="/" aria-label="NovaNetworkClient home">
          <span className="brand-mark">N</span><span>NovaNetworkClient</span><small>Swift networking</small>
        </Link>
        <nav className="topnav" aria-label="Primary navigation">
          {nav.map(([id, label, href]) => <Link aria-current={active === id ? "page" : undefined} href={href} key={id}>{label}</Link>)}
        </nav>
        <a className="github-link" href="https://github.com/maxches99/NovaNetwork" rel="noreferrer">GitHub ↗</a>
      </header>
      {children}
      <footer>
        <div><span className="brand-mark small">N</span><strong>NovaNetworkClient</strong></div>
        <p>Production networking for Swift, without rebuilding the hard parts.</p>
        <div className="footer-links"><Link href="/getting-started">Docs</Link><Link href="/tutorials">Tutorials</Link><Link href="/concepts">Architecture</Link></div>
      </footer>
    </div>
  );
}
