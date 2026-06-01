// @ts-check
import { defineConfig } from 'astro/config';
import starlight from '@astrojs/starlight';

// https://astro.build/config
export default defineConfig({
  site: 'https://mnml.sh',
  integrations: [
    starlight({
      title: 'mnml',
      description:
        'A NvChad-style terminal IDE in Rust — vim or standard editing, LSP, git, embedded HTTP/CDP/DAP, AI panes, headless test harness.',
      // Hidden-during-dev: remove this `head` block before public launch.
      head: [
        {
          tag: 'meta',
          attrs: { name: 'robots', content: 'noindex, nofollow' },
        },
      ],
      social: [
        {
          icon: 'github',
          label: 'GitHub',
          href: 'https://github.com/chris-mclennan/mnml',
        },
      ],
      sidebar: [
        {
          label: 'Start here',
          items: [
            { label: 'Overview', slug: 'index' },
            { label: 'Install', slug: 'install' },
            { label: 'First run', slug: 'getting-started' },
          ],
        },
        {
          // Manual pages added by the `manual-writer` agent over time.
          // Order here reflects intended reading sequence.
          label: 'Manual',
          items: [
            { label: 'Editing', slug: 'manual/editing' },
            { label: 'LSP', slug: 'manual/lsp' },
            { label: 'Git', slug: 'manual/git' },
            { label: 'HTTP client', slug: 'manual/http' },
            { label: 'AI panes', slug: 'manual/ai-panes' },
            { label: 'Settings & configuration', slug: 'manual/settings' },
          ],
        },
        {
          label: 'Releases',
          items: [
            { label: 'Changelog', slug: 'changelog' },
          ],
        },
        {
          label: 'Family',
          items: [
            { label: 'tmnl — GPU terminal', link: 'https://tmnl.sh' },
            { label: 'mixr — DJ app', link: 'https://mixr.sh' },
          ],
        },
      ],
    }),
  ],
});
