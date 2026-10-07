# CI And Verification Principles

**Applies to:** every project, and the root workflow that gates them.

The canonical CI entry point is `.github/workflows/ci.yml`. Each active project stays
independently verifiable, with local toolchain files and explicit root CI jobs.

GitHub Actions runs bounded smoke tests and key quality checks. Full Nexus tests, rho's full
behavior and runtime-RBS suites, every product E2E journey, image builds and heavy measurements
remain local acceptance work. Run the relevant full local gates before integration; a green
GitHub smoke run does not prove full acceptance. Do not move heavy suites into parallel or
scheduled GitHub jobs merely to reduce elapsed time: the shared monthly runner allowance is a
constraint.

## Local Verification Commands

Run each command from its named project directory.

- Root hygiene: `git diff --check` and `ruby bin/lint-eof`.
- `nexus`: `bin/ci` is the full local pipeline, defined in `nexus/config/ci.rb`: setup, EOF lint,
  RuboCop, architecture checks, Zeitwerk, Solid Queue configuration, JavaScript lint/tests,
  Bundler audit, Brakeman, Rails tests, offline manual-tooling tests, test seeds and system tests.
  Focused checks include `bin/brakeman --no-pager`, `bin/bundler-audit`, `bin/rubocop -f github`,
  `bundle exec archspec check`, `bun run lint:js`, `bun run test:js`,
  `bin/rails db:test:prepare`, `bin/rails test`, `bin/rails test ../e2e/manual`,
  `env RAILS_ENV=test bin/rails db:seed:replant`, `bin/rails test:system`,
  `bin/rails zeitwerk:check` and `env RAILS_ENV=test bin/jobs check`.
- `sdks/ruby`: `bundle exec rake` and `bundle exec rake build`. The default task includes tests,
  RuboCop and RBS validation/conformance; `rake test` alone is not the full gate.
- `agents/rho/rho`: `bundle exec rake` and `bundle exec rake build`. The default task includes
  tests, RuboCop, RBS validation/conformance and installer checks. RBS loads the SDK and Runner
  signatures, so drift in their typed surfaces is caught here.
- Each other gem under `agents/rho/`: `bundle exec rake` and `bundle exec rake build` in the
  affected gem. Its Rakefile owns the precise gate; `rho-webui` includes browser JavaScript tests.
- `cmctl`: `bundle exec rake` and `bundle exec rake build` (tests and RuboCop).
- `e2e`: `bundle exec rake` runs the offline harness, all deterministic product journeys and
  RuboCop. Paid diagnostics are separate named tasks, never part of this default gate.
- `nexus/vendor/simple_inference`: `bundle exec rake`.

## Execution And Isolation

- Never run Nexus commands that purge or prepare the same test database concurrently, including
  `db:test:prepare`, `bin/rails test` and focused runs. Run Rails tests and system tests
  sequentially; both can trigger conflicting Bun asset work. If test preparation blocks, inspect
  `pg_stat_activity` for stale local test-database maintenance backends, terminate those once,
  and rerun. Rerun cleanup-heavy deadlocks with `PARALLEL_WORKERS=1` before declaring a regression.
- E2E launches Nexus in `RAILS_ENV=development` by default with isolated databases, runtime
  directories, HOME and CLI configuration supplied through environment variables. Keep that
  launch path usable alongside any Docker path. Supported defaults and documented launch
  configuration must never select, mutate, drop or clean a non-E2E database.
- CI has no real Provider credentials and makes no real model calls. Default local suites remain
  offline even when keys happen to exist. Real-provider work is an explicit named
  `RAILS_ENV=development E2E_LIVE=1` operation using an owner-provided credential, invoked on
  demand for a focused diagnostic, never scheduled by CI or required as a release gate.
- Real-call tools do a preflight before paid IO, emit secret-free diagnostics and retain only the
  minimum request/response capture needed for an offline behavior fixture. Do not add source
  pins, promotion/currentness stores, content-addressed capture hierarchies, environment
  attestation or recapture protocols. Fixture design and ignored live-run output follow
  `.ai/testing.md`; runtime dependency and placement rules follow `.ai/repository.md`.

## Verification Records

- Serious monorepo changes record clean branch state or explain unrelated dirty work, name the
  merge base when assessing merge readiness, pass root hygiene and the relevant full project
  suites, and run E2E when user-visible cross-project behavior changes.
- Keep shared CI foundations centralized at the repository root, with explicit package job names
  and failure artifacts for UI/E2E jobs. Coverage reductions require an explicit local
  verification path. No job depends on hidden local state, untracked credentials or reference
  checkouts.
