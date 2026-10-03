# Testing Principles

**Applies to:** every project. Minitest specifics apply to the Ruby projects; a non-Ruby subproject keeps the durability and naming principles and brings its own runner.

- Fixtures-first behavior testing (`.ai/patterns.md`): a small canonical fixture world, integration
  tests that drive real flows (sign in through the real flow, not session stubbing), and behavior
  assertions (`assert_changes -> { record.reload.closed? }`, `assert_difference` on event/side
  effect counts) — never assertions that only prove code was edited.
- Tests assert behavior, not implementation mechanics. TDD scaffolding is allowed while reshaping
  an API, but before finishing collapse it into durable behavior, boundary, validation,
  concurrency, persistence, or regression tests. For TDD: failing test first, verify the failure is
  meaningful, then the smallest change that passes.
- Cover all meaningful branches of conditionals, guards, state transitions, and permission checks.
  For hierarchical lifecycle surfaces, test local state and effective operability: ancestor archive
  barriers reject or defer ordinary creation/claim/enqueue while descendants keep their own
  execution status. Cover explicit cancel/interrupt separately from archive.
- Concurrency tests are required where ancestor archive races descendant creation, claim, enqueue,
  or completion, and for write-write pairs whose ordinary workflow promises convergence or whose
  failure risks integrity, duplicate irreversible effects, or partial state. Assert the documented
  outcome from the lock order, never incidental retries. Exceptional fully rolled-back database
  losers use focused invariant/constraint coverage (`.ai/boundaries.md`, `.ai/database.md`). A
  winner rule enforced by a single guarded SQL statement is proven by a deterministic sequential
  test — the database supplies the atomicity; threaded harnesses are reserved for multi-statement
  lock-order interactions. Do not add a threaded test to pin an arbitrary order between independent
  commands when every outcome matches an allowed serial order and the final authoritative state
  still blocks prohibited use.
- Jobs must prove they carry their own context: test helpers null ambient `Current` around
  `perform_enqueued_jobs` so context leakage surfaces as failures.
- Endpoint coverage checklist lives in `.ai/api.md`. Query-count tests live at
  request/controller boundaries; add lock-free regression coverage when a bug involved hidden
  locks, long IO, or query amplification.
- Cover nil/empty/malformed/boundary/denied cases only where the contract distinguishes them — no
  permutations for unknown fields or scalar mismatches the model layer validates. No absolute
  assertions on generated IDs/timestamps; Rails time helpers; concern tests get their own files.

## E2E And Parity

- E2E boundaries follow `.ai/boundaries.md`: act and assert through public APIs; inspection only
  explains. Bootstrap/pairing/provisioning flows need product E2E in `e2e/`; CLI unit and request
  tests are not sufficient.
- A claim about predecessor behavior is checked against the old repo as an oracle and restated
  in a contract doc or the E2E harness before it is relied on; parity with the references,
  differences recorded, is the standard (`.ai/repository.md`). Kernel↔agent
  contract pinning uses shared exported fixtures/schemas, never source-grepping the other side.
- E2E launching nexus defaults to `RAILS_ENV=development` with isolated DBs, runtime dirs, HOME,
  and CLI config via env vars; the env-var path stays available even if a Docker path exists.
  Setup failures are harness bugs before product bugs.
- Development, test, E2E and real-provider diagnostic code and fixtures prefer their owning
  non-deployable tree; Nexus-local support stays minimal under `.ai/repository.md` Development
  And Test Placement. The executable dependency is one-way: E2E and test suites call into Nexus,
  while production boot/runtime does not depend on them (`.ai/boundaries.md`).
- Real-provider call policy (owner ruling 2026-08-25): CI has no Provider API keys and never makes
  a real LLM call. Default local test/E2E tasks also never make one merely because a key happens to
  exist. A real call is an explicit, named, `RAILS_ENV=development` operation guarded by
  `E2E_LIVE=1` and an owner-provided key; it is a short on-demand diagnostic, not a release gate or
  maintained qualification product. Small synthetic fixtures and the fake Provider own ordinary
  regression coverage. Test generic behavior with fictional model identifiers and explicit local
  capabilities, independently of the current evaluation roster or deployed model catalog.
  Concrete model names and data remain appropriate when the behavior under test is that model's
  specific adaptation or protocol contract.
- MockLLM is a standalone E2E-owned fake-provider process under `e2e/support/mock_llm/**`,
  reached through ordinary provider configuration; Nexus mounts no mock route (spec 12 D20,
  spec 42 D7/D8). Nexus's own unit/integration suites use an injected deterministic fake
  transport at the `simple_inference` seam instead.
- Keep real-call tooling small: a preflight before paid IO, secret-free diagnostic output, and the
  minimum request/response capture needed to update an offline behavior fixture. Do not add source
  pins, promotion/currentness stores, content-addressed capture hierarchies, environment
  attestation, or recapture protocols to make this development tool behave like a product.
- Real-model transcripts, generated scripts, per-run records, scorecards, ledgers and intermediate
  analysis remain local, ignored output. Commit durable conclusions with their date, measurement
  conditions and limitations; retain raw evidence privately. A useful failure becomes a small,
  authored, model-independent regression case, not a committed copy of a live run. Keep only the
  model-specific samples needed to test an explicit model adaptation or protocol behavior.

- Rails system tests run serially and exercise ordinary Capybara interaction semantics. Global
  JavaScript click/fill fallbacks that bypass visibility, overlap, focus, or disabled-state checks
  are prohibited: fix the product or the test when semantic interaction fails.

## Test Database Stability

- Never run multiple nexus commands that purge/prepare the test DB in parallel
  (`db:test:prepare`, `bin/rails test`, focused runs). If `db:test:prepare` blocks, inspect
  `pg_stat_activity` for stale local test-DB maintenance backends, terminate them once, rerun.
  Cleanup-heavy tests can deadlock under high parallelism: rerun with `PARALLEL_WORKERS=1` before
  treating deadlock failures as regressions.
