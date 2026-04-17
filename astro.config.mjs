import { defineConfig } from 'astro/config';
import cloudflare from '@astrojs/cloudflare';

export default defineConfig({
  // Webflow Cloud mounts the worker under a site subpath; `/app` is the
  // default used by `webflow cloud init`. All routes are prefixed with it
  // — e.g. POST /app/api/hooks/{source}.
  base: '/app',
  output: 'server',
  adapter: cloudflare({ platformProxy: { enabled: true } }),
  // Webhooks are signed / key-gated; Astro's built-in origin check rejects
  // cross-origin POSTs that we explicitly want to accept here.
  security: { checkOrigin: false },
});
