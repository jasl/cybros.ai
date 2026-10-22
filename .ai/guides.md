# Guides Principles

**Applies to:** `guides`, the public documentation site, and public manual text anywhere else
that the site links to.

## Scope And Ownership

- `guides/` is the public manual and the normative public contract (`README.md`, Current Rules).
  Reference pages own wire facts; guide pages own reachable behavior and procedures. Each fact has
  one primary home; other pages link to it rather than restating it.
- A page stands on its own. It does not cite internal specs, plans, decision numbers, dated
  rulings or `docs/`; it states the behavior, invariant, reason or limitation in place. External
  protocols and library documentation may be cited, and source under `agents/rho/**` may be linked
  on GitHub when a page points a developer at a worked example.
- Planned behavior appears only on `overview/roadmap.md`. Every other page describes the current
  installation; a sentence that is not true of the shipped code is removed, not softened.

## Readers And Sections

- Four readers, four sections: `use/` for a person using rho, `operate/` for the person running
  the installation, `build/` for a developer building an agent, `runners/` for a
  developer running executors. `overview/` and `get-started/` route readers to those sections;
  `reference/` is lookup.
- Two getting-started paths stay distinct: the default bundle (Nexus and rho) and building your
  own agent. rho is presented as the default agent and the reference application, never as the
  only client of Nexus.
- A section index page orients; a task page does one task; a reference page describes one
  resource or one lookup table.

## Page Shapes

- **Task page.** The title names the task. A lead paragraph says what the page does and when a
  reader needs it. Then steps or tables, then a short "Next" list. Keep a task page around 150
  lines; when it grows past that, split by task rather than by heading depth.
- **Reference resource page** (`guides/reference/<family>/<resource>.md`). A lead paragraph names
  the resource and its plane. A `Routes` block lists every method and path the page owns, spelled
  `VERB /path` on its own line, because the route guard matches that spelling. Then one section
  per operation, each with the same subsections in the same order — Endpoint, Request, Response,
  Status codes — adding Authentication only where the operation departs from the family's common
  contract. Cross-cutting sections (lifecycle, feeds, retention) come after the operations. Facts
  the family's common-contract page owns (errors envelope, rate limits, identifiers, read
  semantics) are linked, not repeated.
- **Headings** are plain nouns or verbs a reader scans for: "Claim", "Commit a result", "Status
  codes". No metaphors, no em-dash subtitles, no capitalized emphasis, no questions. The reason
  behind a rule is a sentence under the heading, not part of it.
- Tables carry closed vocabularies (fields, statuses, error codes, limits); prose carries
  behavior; code blocks carry exact wire shapes. A table cell holds a phrase, not a paragraph:
  the default theme scrolls a wide table sideways on a phone, so a field that needs
  explanation gets a bold term and a paragraph instead of a row. HTTP examples use the
  family's placeholders (`{workspace_id}`, `{public_id}`), JSON examples are valid JSON with
  `"…"` for elided values.

## Voice

- Plain, present tense. "You" is the reader acting; "Nexus", "rho", "the runner" and "the model"
  are the other subjects. One claim per sentence. No marketing language and no hedging that hides
  a limit — state the limit.
- Names follow the glossary: Cybros (product), Nexus (kernel), rho (the default agent), Agent,
  Runner, Tool provider, Conversation, Run, Task. Wire names, routes, fields and values are code
  spans.
- Every statement is true of the current implementation and is derived from code, tests or the
  existing contract text. A fact that cannot be confirmed is left out rather than guessed.

## Rewriting A Reference Page

- Rewriting preserves every fact. Before replacing a page, list its routes, status codes, field
  names, limits and named error codes, and check the new page against that list; the route guard
  catches a dropped route, nothing catches a dropped field.
- Splitting a long page keeps each route on exactly one page and moves its referrers: search
  `rg "<page>.md#"` across `guides/` and point each link at the page that now owns the section.
- Rewriting a heading changes its anchor. The build checks link targets, not anchors, so verify
  anchors by hand or link the page instead of a section.

## Links

- Relative links ending in `.md`; the build fails on a dead link, so there is no separate link
  check. Never link into `docs/` or into a package README; the guides page that owns the subject
  is the target.
- The site's navigation and sidebar live in `.vitepress/config.mts`; a new page is added to the
  sidebar of its section in the same change.

## Build, Exports And Languages

- Bun runs everything (`.ai/frontend.md`, JavaScript Toolchain): `bun run build` for the
  production build and dead-link check, `bun run dev` for the local server on `127.0.0.1`. Local
  verification is listed in `.ai/ci.md`.
- The build writes `llms.txt`, `llms-full.txt` and a Markdown copy beside every page for LLM
  readers. Keep frontmatter to `title` and `description` so those exports read well, and keep
  Vue-specific syntax out of prose; inline code containing `{{` is rendered verbatim by the
  site's markdown rule.
- English is the source language. A Chinese translation lives under `guides/zh/` with the same
  paths and is written after the English page settles, never ahead of it. Product interface
  strings (Nexus, rho) have their own i18n catalogs and are not translated here.
