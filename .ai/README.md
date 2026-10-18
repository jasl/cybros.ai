# Cybros Instructions

**Applies to:** every project; individual modules narrow their scope explicitly.

The root and project-local `AGENTS.md` files are entry points. This directory holds the
current, durable rules, organized by their owning concern. Keep one primary definition of
each rule and link to it from related modules. Update that definition in place; dates,
revision notes, superseded wording and implementation-stage narratives belong in Git history,
not alongside the current rule.

## Current Rules

These modules state the repository's current design and implementation rules. Public contracts
live under `guides/`, the public documentation site: `guides/reference/` is normative for every
wire fact — routes, request and response shapes, identifiers, status codes, statuses, event
types, limits and vocabularies — and the guide pages under `guides/build/`, `guides/runners/`,
`guides/operate/` and `guides/use/` are normative for reachable behavior and procedures. Code
and tests establish the behavior currently implemented. Apply the user's explicit requirements
and reconcile any conflict with those contracts before implementation.

The Agent API, Platform API and OAuth contracts are one common-contract page per family
(`guides/reference/agent-api.md`, `platform-api.md`, `oauth.md`) beside one page per resource
in the family's directory. The route-documentation guard
(`nexus/test/code_style/route_docs_test.rb`) pins every public route to those pages. `docs/`
is the internal development manual: public manuals and source comments do not cite it, and it
carries no contract text.

Instructions must be usable from a fresh clone. State the required behavior and its reason
here or in its tracked owning contract; do not require a development plan, retired specification,
private checkout, or cached external repository to interpret a rule. Keep accepted design intent
explicitly separate from implemented behavior. Public manuals and source comments follow
`repository.md`'s self-contained documentation rule.

## Modules

- `repository.md`: scope, projects, shared Ruby style, design direction, development placement,
  implementation entry, and reference research.
- `boundaries.md`: trust and credential planes, product ownership, administration, lifecycle,
  design expansion, public identifiers, and package boundaries.
- `backend-rails.md`: Nexus Rails structure, models, concerns, application services, and logging.
- `patterns.md`: self-contained Nexus pattern index with applicability and implementation owners.
- `database.md`: schema, migrations, queries, transactions, and locking.
- `api.md`: public contracts, boundary parameters, controllers, responses, and pagination.
- `jobs.md`: Active Job and Solid Queue execution and recovery.
- `security.md`: authorization implementation, secrets, outbound requests, shell/path safety,
  parsing, and LLM/tool safety.
- `frontend.md`: JavaScript tooling and surface principles; Nexus Hotwire and Tailwind rules.
- `testing.md`: coverage, Minitest, fixtures, system tests, and E2E assertions.
- `review.md`: evidence standards, merge readiness, and verified findings.
- `ci.md`: canonical verification commands, test isolation, and pipeline policy.
- `git.md`: branches, commits, staging, and integration.
- `nexus.md`: kernel mechanisms and their implementation rules.
- `guides.md`: the public documentation site — readers, page shapes, voice, reference
  rewriting, exports and languages.

## Scope And Loading

Read live copies of `repository.md` and `boundaries.md` before implementation or modeling,
then every applicable module listed by `AGENTS.md` and the nearest nested `AGENTS.md`.
Earlier reads, conversation summaries and memory do not satisfy this entry gate.

`repository.md`, `boundaries.md`, `review.md`, `git.md`, and `ci.md` apply across projects, as
do `security.md`'s language-independent clauses and `frontend.md`'s Surface Principles.
Its JavaScript Toolchain rules apply to frontend projects; the TypeScript server SDK owns
its Node.js toolchain. Rails-specific rules are scoped to Nexus: `backend-rails.md`,
`database.md`, `api.md`, `jobs.md`, `patterns.md`, `nexus.md`, and `frontend.md`'s Nexus Stack.

New projects inherit the cross-cutting rules and add stack guidance when code exists to
describe. Each gets its own toolchain, local verification entry in `ci.md`, and explicit root
CI job. Mechanical rules belong in their owning static guard tests where practical;
instructions state the principle and reference those guards rather than duplicating them.
