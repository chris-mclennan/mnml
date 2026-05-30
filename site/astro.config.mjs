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
        'A NvChad-style terminal IDE in Rust — vim or standard editing, LSP, git, and an embedded HTTP client.',
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
          href: 'https://github.com/chris-mclennan/mnml-rs',
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
