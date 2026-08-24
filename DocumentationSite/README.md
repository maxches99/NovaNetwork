# NovaNetworkClient Documentation Site

Standalone web documentation for NovaNetworkClient. It complements the native Swift-DocC catalog
with a browser-first Getting Started guide, tutorial learning path, and concept reference.

## Requirements

- Node.js 22.13 or newer
- pnpm 11

## Development

```bash
pnpm install
pnpm dev
```

## Production build

```bash
pnpm build
pnpm test
```

The deployable Cloudflare Worker and static assets are written to `dist/`. The site has no database,
authentication requirement, or runtime secret.
