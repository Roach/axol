import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';
import node from '@astrojs/node';

// neuromast can deploy to two runtimes:
//
//   - Cloudflare Workers (default; Webflow Cloud uses this under the hood)
//   - Node.js standalone (Railway, Fly, Render, any Docker/VM host)
//
// Select at build time with the ADAPTER env var:
//
//   npm run build              → cloudflare (default)
//   ADAPTER=node npm run build → node standalone server at ./dist/server/entry.mjs
//
// The `base: '/app'` path matters for Webflow Cloud's mount model. On Node
// the app owns the whole domain, so the base path is only there for URL
// compatibility — your Railway URL also exposes routes under /app.
const useNode = process.env.ADAPTER === 'node';

export default defineConfig({
  base: '/app',
  output: 'server',
  adapter: useNode
    ? node({ mode: 'standalone' })
    : cloudflare({ platformProxy: { enabled: true } }),
  // Webhooks are signed / key-gated; Astro's built-in origin check rejects
  // cross-origin POSTs that we explicitly want to accept here.
  security: { checkOrigin: false },
});
