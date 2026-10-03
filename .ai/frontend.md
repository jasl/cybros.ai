# Frontend Principles

**Applies to:** `nexus`'s Rails/Hotwire surface in *Nexus Stack*; *JavaScript Toolchain*
and *Surface Principles* bind every project's frontend.

## Nexus Stack

Stack: Rails, Hotwire, Turbo, Stimulus, Tailwind CSS 4, daisyUI 5, Capybara. The CJK typography
layer and Graphite themes live in `nexus/app/assets/stylesheets/application.tailwind.css`.

- Keep UI state close to the owning view and Stimulus controller, with stable identifiers such
  as `sidebar` and `tabs`. HTML is a client of the public API surface; do not hide server
  contract gaps behind UI-only behavior.
- Each independently submitted form or paginated collection owns an addressable resource URL
  and the controller state needed to render its success, validation failure, and page. Turbo
  may replace that resource inside a stable frame, but its direct HTML URL remains complete
  and usable. Do not coordinate unrelated form errors or pagination keys through one
  controller render state merely to place several features on one screen. Use Pagy's default
  `page` parameter for one collection; a custom key requires multiple collections in one response.
- Follow `.ai/patterns.md` for broadcasting: aggregate morph-refreshes through
  `broadcasts_refreshes`, targeted streams only for incremental UI such as notifications or
  token streams.
- Prefer Tailwind utilities and design tokens to custom CSS. Use design-centered class names
  and explicit state classes such as `.is-expanded`; do not style through ID selectors or
  ARIA attributes. Build mobile-first, without fixed dimensions that let dynamic text or
  controls overlap.
- Prefer semantic Capybara actions and matchers (`click_button`, `fill_in`, `have_field`);
  use implementation selectors only to scope a complex area. Test execution follows
  `.ai/testing.md` and `.ai/ci.md`.

## JavaScript Toolchain

- Bun is the runtime for frontend builds and JavaScript checks. CI and build images own their
  version pins; an image exposes its default through a build argument. Do not add a repository
  `.bun-version` that constrains the contributor's host runtime.
- Make the runtime explicit in every invocation: use `bun <path>`, including a tool's concrete
  script path, or a Bun command such as `bun test`. When invoking a package command or script,
  use `--bun` where needed to force Bun. Do not replace these with bare `eslint`, `vite build`,
  `bunx <tool>`, or other spellings that may follow a Node shebang on `PATH`.
- Keep package scripts consistent with that rule. The root CI workflow checks Nexus script
  prefixes; a green tool run alone does not prove which runtime a child used. When runtime
  selection is in question, check the child's `process.versions.bun` with Node also on `PATH`.
  A Node-free check proves absence of a Node dependency, not correct selection when both exist.
- Validate a newly introduced tool's build and development behavior under Bun. Compatibility
  evidence from another toolchain or a production build alone does not establish dev-server,
  proxy, or watch behavior.
- Node is not required for this frontend toolchain. Separately invoked tools such as the
  Playwright driver may require it; that dependency belongs to their owning package. Browser
  JavaScript does not create a Node/Bun server dependency for a Ruby-served page.
- For Nexus builds, what the build writes is what production serves: Propshaft digests every
  file under `nexus/app/assets/builds`. Shipping builds minify and remove stale sourcemaps; watch builds
  keep usable linked sourcemaps for debugging (`nexus/bun.config.js`).

## Surface Principles

These apply to every user-facing surface, including the Nexus console and rho's WebUI.
Subprojects add stack-specific rules without restating these principles.

- Build the actual usable workflow first; operator/admin tools do not need marketing landing
  pages.
- Prefer semantic HTML to ARIA: real `<button>`, `<a>`, and `<nav>` elements; a label for every
  input; `alt` on every image, empty for decoration; accessible names for icon-only buttons;
  keyboard access and visible focus for every interactive element. No positive `tabindex` or
  div/span controls.
- Use user-meaningful copy rather than internal runtime terms such as inbox task ids or
  scheduler lanes. Restorable resources have an archive action, never a delete affordance.
  Expose cancel only when the backend contract supports it. Design disabled, loading, empty,
  and error states deliberately. Wrap or truncate long tokens safely.
- Verify meaningful UI changes at desktop and narrow viewports.
