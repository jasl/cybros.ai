# CI And Verification Principles

**Applies to:** every project, and the root workflow that gates them.

The canonical CI entry point is the root `.github/workflows/ci.yml`. Each active project stays
independently verifiable; new projects get local toolchain files and explicit root CI jobs when
introduced.

GitHub Actions runs smoke tests and key quality checks, with bounded job durations. Full Nexus
tests, rho's complete behavior and runtime-RBS suites, all product E2E journeys, image builds and
heavy measurements are local acceptance work. Keep the full local gates intact and run the
relevant ones before integrating changes; a green GitHub smoke run does not prove full acceptance.
Do not move heavy suites into parallel or scheduled GitHub jobs merely to reduce elapsed time:
the shared monthly runner allowance is a constraint (owner direction, 2026-10-02).

## Local Verification Commands

- Root hygiene: `ruby bin/lint-eof`
- `nexus`: `bin/brakeman --no-pager`, `bin/bundler-audit`, `bin/rubocop -f github`,
  `bundle exec archspec check`,
  `bun run lint:js`, `bun run test:js`, `bin/rails db:test:prepare`, `bin/rails test`,
  `bin/rails test:system`, `bin/rails zeitwerk:check`, `env RAILS_ENV=test bin/jobs check`. Run
  `test` and `test:system` sequentially — both can trigger Bun asset work and conflict. `bin/ci`
  runs the full local pipeline.
- `sdks/ruby`: `bundle exec rake` and `bundle exec rake build` — `rake` is the gate (test +
  rubocop + rbs); `rake test` alone is not
- `agents/rho/rho`: `bundle exec rake` and `bundle exec rake build` — same three-part gate; its
  `rbs` task also loads `sdks/ruby/sig`, so a drift in the gem's typed surface fails here rather
  than at runtime in a daemon
- `e2e`: `bundle exec rake` (deterministic tiers only); real-provider diagnostics use the separate
  named development task with `E2E_LIVE=1` and never run as part of this gate
- `nexus/vendor/simple_inference`: `bundle exec rake`

## Principles

- Serious monorepo changes ship with a verification record: clean branch state (or an explanation of
  unrelated dirty work), explicit merge base for merge-readiness decisions, `git diff --check`,
  root EOF lint, full relevant project suites, and E2E when user-visible cross-project behavior
  changes.
- Keep shared CI foundations centralized at the repository root; preserve failure artifacts for
  UI/E2E jobs and explicit job names per package. Coverage reductions require an explicit local
  verification path; no jobs depend on hidden local state, untracked credentials, or reference
  checkouts.
- CI and every default local suite use only authored offline behavior fixtures and the
  independent fake-Provider process under `e2e/support/mock_llm/**`. CI has no real Provider
  credentials and must not contact an external model provider. A real-provider diagnostic is an
  explicit, manually invoked `RAILS_ENV=development E2E_LIVE=1` task and is never scheduled by a
  CI workflow or included in an ordinary local gate. Its support code and sanitized output remain
  E2E-owned; Nexus production boot/runtime never loads them. Real-call tooling does not maintain a
  promotion registry, source pins, content-addressed capture store, or release-currentness proof.
  E2E starts and owns the fake-provider process and points Nexus at it through ordinary catalog/
  provider configuration. Nexus has no MockLLM route, controller, parser, fixture, or boot hook in
  `app/**`, `lib/**`, or production-loaded configuration. Nexus-local deterministic tests use
  test-owned transports/fixtures rather than requiring E2E at Nexus boot or test load time.
  Generic regression coverage uses fictional models and local capabilities, not the live eval
  roster or saved model outputs. Concrete models belong in their specific adaptation/protocol
  tests. Generated runs and intermediate analysis stay ignored; commit reviewed conclusions.
- Real-call policy (owner ruling 2026-08-25): CI never makes real LLM calls and carries no
  Provider credentials; development runs the small diagnostic explicitly and on demand with an
  owner-provided key. A paid call is evidence for a focused investigation, never a default
  acceptance gate.
