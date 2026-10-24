# CI And Verification Principles

**Applies to:** every project, and the root workflow that gates them.

CI entry points are `.github/workflows/ci.yml` on GitHub and `.gitlab-ci.yml` on the
GitLab deploy remote. Keep their bounded checks aligned. GitLab uses Linux Docker
runners accepting untagged jobs; default-branch pushes, merge requests and manual
pipelines run verification. Each active project stays independently verifiable,
with local toolchain files and explicit root CI jobs.

GitHub Actions runs bounded smoke tests and key quality checks. Full Nexus tests, rho's full
behavior and runtime-RBS suites, every product E2E journey, image builds and heavy measurements
remain local acceptance work, selected by the change scope below; they are not mandatory after
every implementation slice. A green GitHub smoke run does not prove full acceptance. Do not move
heavy suites into parallel or scheduled GitHub jobs merely to reduce elapsed time: the shared
monthly runner allowance is a constraint.

## Selecting Verification Scope

- Select checks from the actual changed behavior, its owning modules and affected callers, not
  merely from the projects touched. Start with the smallest test that distinguishes the change,
  then cover affected contracts and adjacent regressions. Run applicable type, style, architecture
  or build checks where the change can affect them.
- A small implementation slice is complete when its targeted validation passes. Do not run full
  package suites or all product E2E journeys merely because a slice is finished, crosses projects,
  is committed, or is ready for review. Command listings below describe available checks, not a
  checklist to execute for every change.
- Cross-project behavior needs a bounded integration journey through the changed caller/owner
  path. Select the relevant case or cases, using an existing test filter where possible; do not
  run an entire mixed E2E group when most of its journeys are unrelated.
- Broaden verification only when a concrete dependency, failure or unresolved regression risk
  warrants it. Full E2E belongs to explicitly scoped whole-system/release acceptance, an explicit
  user request, or a broad change whose impact cannot reasonably be covered by targeted journeys.
  State the reason and expected cost before starting a broad run. Completing one small slice is
  never that reason. Once selected checks pass, stop unless new evidence changes the scope.
- For unrelated failures, record the command, failing case, useful error and evidence for its
  relation to this change. Do not repair old fixtures, rebalance groups, rerun unrelated suites or
  expand product work just to make everything green. If attribution is uncertain, use a bounded
  focused check; report unresolved uncertainty rather than treating it as permission for a broad
  cleanup. Fix regressions caused by this change within its scope; unrelated repair needs a
  separately authorized task.
- Documentation-only instruction changes need consistency/link review and root hygiene, not
  application suites or E2E. Selecting fewer tests for a scoped change does not authorize deleting
  tests, weakening assertions or claiming broader acceptance than was actually verified.

## Local Verification Commands

Run each selected command from its named project directory. Full-suite commands are acceptance
entry points; use their focused tasks or test filters for scoped implementation work.

- Root hygiene: `git diff --check` and `ruby bin/lint-eof`.
- `nexus`: `bin/ci` is the full local pipeline, defined in `nexus/config/ci.rb`: setup, EOF lint,
  RuboCop, architecture checks, Zeitwerk, Solid Queue configuration, JavaScript lint/tests,
  Bundler audit, Brakeman, Rails tests, offline manual-tooling tests, test seeds and system tests.
  Focused checks include `bin/brakeman --no-pager`, `bin/bundler-audit`, `bin/rubocop -f github`,
  `bundle exec archspec check`, `bun run lint:js`, `bun run test:js`,
  `bin/rails db:test:prepare`, `bin/rails test`, `bin/rails test ../e2e/products/manual`,
  `env RAILS_ENV=test bin/rails db:seed:replant`, `bin/rails test:system`,
  `bin/rails zeitwerk:check` and `env RAILS_ENV=test bin/jobs check`.
- `sdks/ruby`: `bundle exec rake` and `bundle exec rake build`. The default task includes tests,
  RuboCop and RBS validation/conformance; `rake test` alone is not the full gate.
- `sdks/typescript`: `pnpm install --frozen-lockfile` and `pnpm run check`, using the pnpm
  version declared in `package.json`. The complete package gate includes build, strict types,
  Vitest behavior/contract tests, native Node tests and packaged runtime checks. Full package
  acceptance runs under Node 22 and Node 24 from a clean checkout; the SDK toolchain does not use Bun.
- `sdks/rust`: `bin/ci`. The package gate includes locked dependencies, formatting, Clippy,
  default/all-feature tests, rustdoc and package verification. Full package acceptance also compiles
  all features on the declared minimum Rust version; the current compiler alone does not prove
  that minimum.
- `agents/rho/rho`: `bundle exec rake` and `bundle exec rake build`. The default task includes
  tests, RuboCop, RBS validation/conformance and installer checks. RBS loads the SDK and rho-env
  signatures, so drift in their typed surfaces is caught here.
- Each other gem under `agents/rho/`: `bundle exec rake` and `bundle exec rake build` in the
  affected gem. Its Rakefile owns the precise gate; `rho-webui`, `rho-ingress-telegram` and `rho-t3`
  include browser JavaScript tests run with Bun.
- `cmctl`: `bundle exec rake` and `bundle exec rake build` (tests and RuboCop).
- `e2e/protocol` and `e2e/products` each own a Gemfile, lockfile and `bundle exec rake`
  gate (harness, deterministic journeys and RuboCop). The protocol lane uses SDK fake peers and
  must pass without `agents/rho/**`; the product lane exercises real rho/rho-env. The root `e2e`
  task dispatches both bundles. Product WebRTC runs explicitly with `rake realtime`; paid
  diagnostics remain separate named tasks.
- `nexus/vendor/simple_inference`: `bundle exec rake`.
- `guides`: `bun install --frozen-lockfile` and `bun run build`. The VitePress build runs under
  Bun (`bun --bun node_modules/vitepress/bin/vitepress.js`) and fails on a dead internal link,
  so it is also the public site's link check; `bun run dev` serves it locally.

## Execution And Isolation

- Run the relevant small integration journey while implementing a cross-component boundary
  change, following `.ai/testing.md`'s contract coverage. It can complete that slice's validation;
  it does not automatically trigger a later full acceptance run.
- Never run Nexus commands that purge or prepare the same test database concurrently, including
  `db:test:prepare`, `bin/rails test` and focused runs. Run Rails tests and system tests
  sequentially; both can trigger conflicting Bun asset work. If test preparation blocks, inspect
  `pg_stat_activity` for stale local test-database maintenance backends, terminate those once,
  and rerun. Rerun cleanup-heavy deadlocks with `PARALLEL_WORKERS=1` before declaring a regression.
- E2E launches Nexus in `RAILS_ENV=development` by default with isolated databases, runtime
  directories, HOME and CLI configuration supplied through environment variables. Keep that
  launch path usable alongside any Docker path. Supported defaults and documented launch
  configuration must never select, mutate, drop or clean a non-E2E database.
- Match test concurrency to the capacity of the selected isolated database and runtime. When a
  suite fails, preserve the first useful failure and distinguish product behavior, fixture
  assumptions and environment/resource failures before changing code. Cascading errors or group
  deadlines are not independent product findings; do not weaken assertions or extend product
  deadlines merely to obtain a green run.
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
  merge base when assessing merge readiness, pass root hygiene and the checks selected for the
  actual impact. Record what was tested, why, results and any unverified scope or unrelated
  failures. Targeted success is not a claim that full suites or all E2E passed.
- Keep shared CI foundations centralized at the repository root, with explicit package job names
  and failure artifacts for UI/E2E jobs. Removing durable test coverage or reducing CI coverage
  requires an explicit replacement verification path; selecting a focused local run does not
  remove that coverage. No job depends on hidden local state, untracked credentials or reference
  checkouts.
