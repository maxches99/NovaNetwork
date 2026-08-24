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

## Deployment

Every push to `main` that touches `DocumentationSite/**` builds and deploys the site to Cloudflare
Workers via [`deploy-docs.yml`](../.github/workflows/deploy-docs.yml). That workflow needs two
repository secrets:

- `CLOUDFLARE_API_TOKEN` — a token with the "Edit Cloudflare Workers" template permissions
- `CLOUDFLARE_ACCOUNT_ID` — the Cloudflare account ID that owns the Worker

To deploy manually from a local checkout with the Cloudflare CLI authenticated (`pnpm dlx wrangler login`):

```bash
pnpm build
pnpm deploy
```
