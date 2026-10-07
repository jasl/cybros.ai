# Cybros Instructions

**Applies to:** every project; individual modules narrow their scope explicitly.

The root and project-local `AGENTS.md` files are entry points. This directory holds the
current, durable rules, organized by their owning concern. Keep one primary definition of
each rule and link to it from related modules. Update that definition in place; dates,
revision notes, superseded wording and implementation-stage narratives belong in Git history,
not alongside the current rule.

## Current Rules

These modules state the repository's current design and implementation rules. Public contracts
live in the tracked documentation under `docs/agent-api/`, `docs/platform-api/`, and
`docs/oauth/`; code and tests establish the behavior currently implemented. Apply the user's
explicit requirements and reconcile any conflict with those contracts before implementation.

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

## Scope And Loading

Read live copies of `repository.md` and `boundaries.md` before implementation or modeling,
then every applicable module listed by `AGENTS.md` and the nearest nested `AGENTS.md`.
Earlier reads, conversation summaries and memory do not satisfy this entry gate.

`repository.md`, `boundaries.md`, `review.md`, `git.md`, and `ci.md` apply across projects, as
do `security.md`'s language-independent clauses and `frontend.md`'s JavaScript Toolchain and
Surface Principles. Rails-specific rules are scoped to Nexus: `backend-rails.md`,
`database.md`, `api.md`, `jobs.md`, `patterns.md`, `nexus.md`, and `frontend.md`'s Nexus Stack.

New projects inherit the cross-cutting rules and add stack guidance when code exists to
describe. Each gets its own toolchain, local verification entry in `ci.md`, and explicit root
CI job. Mechanical rules belong in their owning static guard tests where practical;
instructions state the principle and reference those guards rather than duplicating them.
