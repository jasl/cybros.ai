# AGENTS.md — nexus

Entry point for work under `nexus/`. Read the root `AGENTS.md` first, then:

- `.ai/nexus.md` — the kernel under the mandate (the three primitives, executor roles and the
  gateway, the task inbox, events/liveness, billing, memory, discipline)
- `.ai/backend-rails.md` + `.ai/patterns.md` — Nexus Rails house style and named recipes
- Task-specific modules per the root module map

## Project Rules

- Nexus is product-blind: no concrete agent product names, no product prompt text (prompt
  MEANING), and no routing policy in `nexus/app/**`. Prompt assembly, templates and persona
  entities are kernel mechanism (`.ai/nexus.md`); product policy belongs to agent applications
  built on the API.
- Minimize development-only code in Nexus, preferring `nexus/test/**` or the owning root `e2e/**`
  project without a blanket location ban (`.ai/repository.md`, Development And Test Placement).
  Environment-variable import of provider API keys is a supported deployment convenience.
  Nexus boot/runtime must not depend on test/E2E trees. Production mechanisms remain in their
  owners when tests exercise them; placement follows runtime responsibility, not test coverage.
- Pre-release reset posture: destructive schema/migration rewrites are allowed
  (`.ai/database.md`); compatibility with the old repo's shapes is not a goal.
- Public identifiers are UUIDv7; internal bigint ids never cross public, executor-facing, or
  durable audit boundaries.
- `vendor/simple_inference` is a vendored gem and stays vendored; changes to it run its own suite
  (`cd vendor/simple_inference && bundle exec rake`).
- Licensed under the O'Saasy License (`LICENSE.md`); commercial/SaaS concerns live in an overlay
  tree, never in the kernel.
- Local pipeline: `bin/ci`. Individual commands: `.ai/ci.md`.
