# Frontend Principles

**Applies to:** `nexus`'s Rails/Hotwire surface in *Nexus Stack*; *The JavaScript Toolchain* and *Surface Principles* below bind every project in this repository, in any language.

## Nexus Stack

Stack: Rails, Hotwire, Turbo, Stimulus, Tailwind CSS 4, daisyUI 5, Capybara. The hand-crafted CJK
typography layer and Graphite themes (flat neutral surfaces, Cursor-style console shell) live in
`nexus/app/assets/stylesheets/application.tailwind.css`.

- Build the actual usable workflow first — no marketing-style landing pages for operator/admin
  tools. (Stack-independent; it belongs to the surface principles below as much as here.) Keep UI state close to the owning view and Stimulus controller (stable identifiers like
  `sidebar`, `tabs`); HTML is one client of the public API surface — never hide server contract
  gaps behind UI-only behavior.
- Each independently submitted form or paginated collection owns an addressable resource URL and
  the controller state needed to render its own success, validation failure, and page. Turbo may
  replace that resource inside a stable frame, but the direct HTML URL remains complete and usable.
  Do not coordinate unrelated form errors or multiple pagination keys through one controller render
  state merely to make several features appear on one screen. Use Pagy's default `page` parameter
  when a response owns one collection; a custom page key requires multiple collections in the same
  response.
- Broadcasting is two-tier (`.ai/patterns.md`): `broadcasts_refreshes` morph-refresh on aggregates;
  targeted streams only for genuinely incremental UI (notification tray, token streams).
- Tailwind utilities and design tokens over custom CSS; design-centered class names; no ID
  selectors or ARIA attributes as styling state (use explicit state classes like `.is-expanded`);
  mobile-first responsive behavior; no fixed dimensions that let dynamic text or controls overlap.

## The JavaScript Toolchain

**Bun is the JavaScript runtime for this repository's frontend build and checks** — pinned in CI
and the images that build those assets. The pin stays out of the working tree deliberately
(owner, 2026-09-04): a `.bun-version` file would bind a contributor's own `bun`, and development
is not where the version is decided. So an image states its default and a build overrides it with
`--build-arg`; nothing constrains the host.

**Node is not required for rho's core runtime or this repository's frontend toolchain.**
`gem install rho` pulls only Ruby, and the heavy tools are
native binaries anyway (TypeScript 7 is a Go executable behind a 609-byte launcher, Biome is a
Rust binary, Vite bundles through rolldown/lightningcss/oxide N-API addons). A frontend toolchain
run under Bun was measured against the same toolchain under Node on the predecessor's real
frontend and emits **byte-identical output**, sourcemap included. The one place the dependency is
already forced runs the other way: `scripts/codegen.ts` uses `import.meta.dir`, which Node cannot
execute at all.

Three things follow:

- **Spell every invocation so the runtime is not PATH-dependent.** Bun runs the file itself
  whenever it is handed a **path** — `bun <path>`, `bun run <path>`, any extension, including
  `node_modules/.bin/<tool>` — and honours that shim's `#!/usr/bin/env node` only when it resolves
  a **bare name**, which is why `bunx <tool>`, `bun run <tool>` and a bare `<tool>` all execute on
  **Node** wherever Node is on `PATH`. `--bun` forces Bun in either position (`bunx --bun <tool>`,
  `bun run --bun <script>`). Every script in `nexus/package.json` is spelled the pinned way (a path,
  or `bun test`); a "cleanup" back to `vite build` silently reverts the runtime with no diagnostic
  and no failing test.
- **CI cannot detect a regression to a bare-name spelling.** The `nexus_lint_js` job does run ESLint
  and the JS tests on Bun as spelled today. What is unguarded is the edit that quietly stops them: a
  reverted `eslint` or `vite build` is just as green, on the Node `ubuntu-latest` ships. Stripping
  `node` from `PATH` does not close that hole — Bun then runs the `.bin` shim itself and the reverted
  spelling passes too; a node-free job proves the other half of the rule, that the toolchain needs no
  Node at all. Catching the spelling takes an assertion made *while Node is on `PATH`*: run each
  script and fail unless the child reports `process.versions.bun`.
- **A Vite dev server requires Bun >= 1.4.0.** On 1.3.14 a single WebSocket to a proxied path kills
  the dev server with `TypeError: socket.destroySoon is not a function`, taking HMR and HTTP with it
  — loudly on stderr (Vite's own `ws proxy error`, a code frame at http-proxy-3's `socket.destroySoon()`,
  the TypeError, Bun's version banner) and silently on stdout, which is where a supervisor looks. The
  *build* is byte-identical on 1.3.14, so the pin only had to move when a dev server did: CI and both
  images pin 1.4.2 since 2026-09-18, which is why this rule reads as satisfied rather than owed.

The carve-outs are named rather than implied: rho-browser's Playwright driver and two e2e live
journeys use a Node binary. The distributed rho Docker image also preinstalls project language
toolchains, Chromium and document-processing software for coding and Cowork tasks (owner request,
2026-10-01; `docs/plans/2026-10-01-rho-codex-environment.md`). Their versions belong to the
installation manifest and dependency locks. This image convenience adds no Node or Python boot
dependency to a bare-metal rho installation; optional tools there report a missing dependency
when invoked.

**What the build writes is what production serves.** Propshaft digests every file under
`app/assets/builds` and the image precompiles there, so a build that emits an unminified bundle and
its sourcemap ships both. Minify in the shipping build; keep sourcemaps for the watch build, which
is the one a person debugs.

## Surface Principles

These hold for any user-facing surface this repository ships, in any language or framework — the
`nexus` console today, rho's local page next, whatever an edge product brings after that. A
subproject adopts them as-is and adds a module for its own stack rather than restating these.

- Semantic HTML over ARIA: real `<button>`/`<a>`/`<nav>` elements, every input labeled, every image
  with `alt` (empty for decorative), icon-only buttons with accessible names, all interactive
  elements keyboard-reachable with visible focus, no positive `tabindex`, no div/span controls.
- Copy uses user-meaningful language, not internal runtime terms (inbox task ids, scheduler
  lanes). Archive appears as an archive action, never a delete affordance, for restorable
  resources; cancel is an explicit action only when the backend contract supports it. Disabled,
  loading, empty, and error states are intentional. Long tokens wrap or truncate safely.
- Verify desktop and narrow viewports for meaningful UI work. Prefer semantic Capybara actions and
  matchers (`click_button`, `fill_in`, `have_field`); implementation selectors only to scope a
  complex area.
