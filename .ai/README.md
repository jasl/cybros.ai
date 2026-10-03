# Cybros Instructions

Modular agent instructions for the `cybros-ai.alt2` monorepo. The root `AGENTS.md` and
project-local `AGENTS.md` files are entry points; detailed rules live here so they can be loaded by
topic.

These rules are kept compressed to principles. Mechanical prohibitions are enforced by static guard
tests (ported/re-established under `nexus/test/code_style/` as the code they guard lands); rule
files point at those tests instead of restating them. When a guard fails, its message is the rule.

Scope discipline (owner ruling, 2026-08-10): `.ai/` carries project-global durable doctrine —
primarily Nexus-wide invariants that outlive any single round. Development-phase, round, or
slice-specific rules belong in the owning plan or spec (or another more fitting home), with rare
explicitly justified exceptions. Rule text names the domain mechanism, not a phase label: a rule
that can only be stated in terms of a checkpoint or slice id is plan content wearing the wrong
file. This is the standing defense against `.ai/` bloat; consolidation back to principles plus
pointers is always in-policy.

## Authority (owner ruling, 2026-09-05)

Every document dated before 2026-09-04 — the retired founding specs under
`docs/archive/specs-retired-2026-08-17`, the round plans, the verdicts, the ledger's older
narrative, the predecessor's docs — is historical reference only. A `spec NN` citation in any
module is a pointer into that archive: it explains provenance and is never a normative source.
The authorities are `docs/plans/2026-09-04-product-mandate.md` (the mandate and the rulings
under it), `docs/plans/2026-09-05-capability-basis.md`, `docs/plans/2026-09-05-mandate-audit.md`,
these modules as rewritten to the mandate, `docs/agent-api/**` as the living contract of what
is built, the current round plan, and a `DEFERRALS.md` carrying only items re-verified against
the code on or after 2026-09-05.

## Modules

Public manuals and source comments follow `repository.md`'s self-contained documentation rule:
internal specification clauses are explained in place, not cited by identifier. The historical
references retained in these development instructions do not authorize restoring those citations
to code or published manuals. The owner plans to retire development documents after feature
completion; this does not remove them or change product behavior in the meantime.

- `repository.md`: monorepo scope, naming, rewrite posture, local development, reference research,
  shared working rules
- `boundaries.md`: kernel/agent/executor boundaries, trust domain, public identifiers, package and
  E2E boundaries
- `backend-rails.md`: vanilla-Rails style, parameter doctrine, models/concerns/POROs, Ruby style,
  logging, abstraction restraint
- `patterns.md`: named pattern adoption map mined from Fizzy, Discourse, and GitLab, with source
  paths and explicit do-not-copy list
- `database.md`: schema, migrations, reset rules, query design, the locking ladder, transactions
- `api.md`: public API style — contracts, status codes, controllers, responses, pagination
- `jobs.md`: Active Job and Solid Queue design rules
- `security.md`: trust domain, authorization, secrets, outbound requests, shell/path safety,
  parsing, AI/LLM safety
- `frontend.md`: Hotwire, Stimulus, Tailwind, accessibility, UI testing
- `testing.md`: durable coverage, Minitest style, E2E rules, test database stability
- `review.md`: review method, merge-readiness gates, verified-finding workflow
- `ci.md`: canonical CI, local verification commands, pipeline principles
- `git.md`: branch, commit, staging, and integration hygiene
- `nexus.md`: project-local Nexus kernel doctrines

## Scope

Every module states, on its first line, which projects it governs. Most of this directory was
written when `nexus` was the only project and still describes it alone; that is now said out loud
rather than assumed.

Three modules bind every project regardless of language: `repository.md`, `boundaries.md`, and
`review.md`, joined by `git.md`, `ci.md`, and `security.md`'s language-independent clauses.
Everything else is scoped.

A new subproject — including a non-Ruby one, which the edge-deployed products are likely to be —
inherits the cross-cutting modules, adds its own stack module when it has code to describe, gets
a local verification entry in `ci.md`, and gets an explicit root CI job (`boundaries.md`). It does
not inherit `backend-rails.md`, `database.md`, `api.md`, `jobs.md`, `patterns.md`, `nexus.md`, or
`frontend.md`'s *Nexus Stack* section. Write the module when the code exists, not before.

## Loading Rule

For any nontrivial task, read `repository.md` and `boundaries.md` first, then the task-specific
modules listed in `AGENTS.md` or the nearest project-local `AGENTS.md`.
