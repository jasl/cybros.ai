# AGENTS.md

## Scope

This file is the repository entry point for agent instructions. Detailed rules
live in `.ai/` modules so they can be loaded by topic.

Always read:

- `.ai/repository.md`
- `.ai/boundaries.md`

Then read the task-specific modules below.

These reads are a pre-implementation gate. Before implementation or
schema/modeling work, read the live copies of the always-read modules and every
task-specific module applicable to the touched surfaces. Prior conversation
context, summaries, memory, or an earlier read do not satisfy this gate. When a
task spans categories, read every applicable module and the nearest nested
`AGENTS.md`.

## Module Map

- Nexus Rails/backend work: `.ai/backend-rails.md`
- Nexus implementation patterns: `.ai/patterns.md`
- Database, migrations, query, or persistence work: `.ai/database.md`
- Public API, controller, executor protocol, or E2E contract work: `.ai/api.md`
- Active Job, Solid Queue, or scheduled workflow work: `.ai/jobs.md`
- Authentication, authorization, token, credential, outbound HTTP, shell/path,
  webhook, LLM/tool, or parser work: `.ai/security.md`
- UI, Hotwire, Stimulus, Tailwind, copy, accessibility, or system-test work:
  `.ai/frontend.md`
- Tests, E2E harness, fixtures, or test database work: `.ai/testing.md`
- Work under `agents/**`: `.ai/repository.md` for shared Ruby style and the rho
  application contract under Active Projects,
  and `.ai/boundaries.md`. The Nexus-scoped modules —
  `backend-rails.md`, `database.md`, `api.md`, `jobs.md`, `patterns.md`, `frontend.md`'s *Nexus
  Stack* section — do not apply there; see `.ai/README.md`. `frontend.md`'s *JavaScript Toolchain*
  and *Surface Principles* DO apply.
- Code review, merge readiness, cleanup audit, or verified-finding loops:
  `.ai/review.md`
- CI or local verification work: `.ai/ci.md`
- Branch, commit, staging, or integration work: `.ai/git.md`
- Nexus kernel work under `nexus/`: `nexus/AGENTS.md` and `.ai/nexus.md`

## Non-Negotiables

- Ruby here is duck-typed and fail-fast: normalize once at the boundary
  (`to_s`/`to_h`/`fetch`), then one loud guard, and trust internal types.
  Type probes are banned in every spelling — `.is_a?` and its
  `case x when String` costume alike; exhaustive `case ... when ... else`
  is for real closed unions only. Do not restyle correct code into verbose
  equivalents, and never delete a guard or its pinning test to make a change
  coherent (`.ai/repository.md`, `.ai/review.md`).
- Security findings and mechanisms pass `.ai/boundaries.md`'s Threat-Model
  And Portability Gate: name the asset, attacker, capability, boundary, and
  distinguishing test first. The user's own environment, their deliberately
  installed packages, and the operator of their own deployment are not
  attackers.
- Before release, choose the correct design over compatibility with previous APIs,
  schemas, names, fixtures or local data. Keep writers, readers, tests and public
  contracts consistent; current design rules live in `.ai/`.
- Single trust domain: one `Account` contains users, agents, runners, and tool
  providers. There is no tenant-isolation layer; workspace access control is a
  product feature among trusted members, and TaskExecutor binding is a
  correctness boundary, not tenancy.
- Nexus is a fat, complete, orthogonal kernel: every
  general agent mechanism is kernel; product policy — prompt meaning, model
  routing, tiers — is the agent application's. Nexus must not branch on concrete
  agent product names.
- Keep development-only code in Nexus minimal, preferring the owning test/E2E
  tree without imposing a blanket location ban.
  Classify by runtime responsibility and consumers: environment-variable import
  of provider API keys is a supported deployment convenience, including for
  bare-metal installations. Production code exercised by tests remains production
  code. Nexus boot/runtime must not depend on `e2e/**` or test support; the
  execution dependency remains one-way from E2E/test into Nexus.
- Do not expose internal bigint IDs at external, executor-facing, or durable
  audit boundaries; public identifiers are UUIDv7.
- Shared Ruby style follows `.ai/repository.md`. Nexus uses the Rails house style
  and explicit application-service allowance in `.ai/backend-rails.md`, with
  self-contained implementation patterns in `.ai/patterns.md`.
- Run commands from the target project directory and keep changes scoped to
  the requested subproject whenever possible.
