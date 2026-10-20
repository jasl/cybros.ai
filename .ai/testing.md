# Testing Principles

**Applies to:** every project. Minitest specifics apply to the Ruby projects; a non-Ruby subproject keeps the durability and naming principles and brings its own runner.

- Select validation by actual change impact under `.ai/ci.md`, Selecting Verification Scope.
  Cover changed behavior and its affected callers; a small slice does not require full E2E.
  Record unrelated failures without expanding the repair scope. The coverage rules below apply
  to the behavior being changed, not every existing feature in a touched project.
- Fixtures-first behavior testing (Nexus recipes in `.ai/patterns.md`): a small canonical fixture
  world, integration tests that drive real flows (sign in through the real flow, not session
  stubbing), and behavior
  assertions (`assert_changes -> { record.reload.closed? }`, `assert_difference` on event/side
  effect counts) — never assertions that only prove code was edited.
- Tests assert behavior, not implementation mechanics. TDD scaffolding is allowed while reshaping
  an API, but before finishing collapse it into durable behavior, boundary, validation,
  concurrency, persistence, or regression tests. For TDD: failing test first, verify the failure is
  meaningful, then the smallest change that passes.
- Cover all meaningful branches of conditionals, guards, state transitions, and permission checks.
  For hierarchical lifecycle surfaces, test local state and effective operability under the owning
  archive contract. Workspace archive rejects or defers ordinary creation/claim/enqueue while
  descendants keep their own execution status. Conversation archive changes visibility and
  refuses new work while accepted execution continues, including claims, queued inputs and its
  resulting child work. Cover explicit cancel/interrupt separately from archive.
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

## E2E And Contract Coverage

- E2E boundaries follow `.ai/boundaries.md`: act and assert through public APIs; inspection only
  explains. Bootstrap/pairing/provisioning flows need product E2E in `e2e/`; CLI unit and request
  tests are not sufficient.
- Changes crossing principal, access or background-lifecycle boundaries need a small real
  integration case at that boundary, alongside focused unit coverage. For principal or access
  changes, choose principals whose permissions differ in the relevant way: for example, a Workspace
  reader excluded from the source Conversation, or a sender that cannot discover the answerer's
  private Runner. Prove both the permitted work and the denied access while the derived work
  exists; disabling the feature or checking only after deletion does not prove its access boundary.
  Reuse the existing fixture world and cover the distinguishing combinations, not an exhaustive
  permissions matrix.
- Follow an accepted input through its receipt/materialization and exact Run or turn identity.
  Do not infer its result from a list position, the first page, or a Workspace-wide count unless
  that whole collection is the behavior under test. Unrelated optional helpers may be explicitly
  disabled in a focused fixture; keep them enabled in the cases that verify their interaction,
  and preserve the original business assertions when repairing a stale fixture.
- Keep fake-provider acknowledgements bounded and independent of incidental prompt growth unless
  context size or compaction is the subject of the test. Await the relevant public lifecycle or
  navigation condition instead of extending sleeps, deadlines or global retries to hide a failure.
- Research historical behavior or external implementations only when the task needs it. Gather
  sources on demand and identify their version and a reproducible observation; a local reference
  checkout is optional research material, never a required baseline or contract authority.
  Restate adopted behavior in the current contract and pin it in the owning tests or E2E harness.
  Kernel↔agent contract pinning uses shared exported fixtures/schemas, never source-grepping the
  other side.
- E2E launch isolation, test database serialization and real-provider execution policy live in
  `.ai/ci.md`. Diagnose setup failures in the harness before attributing them to the product.
- Development, test, E2E and real-provider diagnostic code and fixtures prefer their owning
  non-deployable tree; Nexus-local support stays minimal under `.ai/repository.md` Development
  And Test Placement. The executable dependency is one-way: E2E and test suites call into Nexus,
  while production boot/runtime does not depend on them (`.ai/boundaries.md`).
- Ordinary regression coverage uses small authored synthetic fixtures and deterministic fake
  providers. Test generic behavior with fictional model identifiers and explicit local
  capabilities, independently of evaluation rosters or deployed catalogs. Concrete model names
  and samples are appropriate only for that model's explicit adaptation or protocol behavior.
- MockLLM is a standalone E2E-owned fake-provider process under `e2e/support/mock_llm/**`, reached
  through ordinary provider configuration; Nexus mounts no mock route. Nexus's own unit/integration
  suites use an injected deterministic fake transport at the `simple_inference` seam instead.
- Real-model transcripts, generated scripts, per-run records, scorecards, ledgers and intermediate
  analysis remain local, ignored output. Commit durable conclusions with their date, measurement
  conditions and limitations; retain raw evidence privately. A useful failure becomes a small,
  authored, model-independent regression case, not a committed copy of a live run. Keep only the
  model-specific samples needed to test an explicit model adaptation or protocol behavior.
- Rails system tests run serially and exercise ordinary Capybara interaction semantics. Global
  JavaScript click/fill fallbacks that bypass visibility, overlap, focus, or disabled-state checks
  are prohibited: fix the product or the test when semantic interaction fails.

## Database Test Transactions

- `uses_transaction` is keyed by the test method name. Rename its entry with the test: a stale name
  silently restores Rails' wrapping transaction and can deadlock `RowLockTestHelper`'s separate
  connection, surfacing as a `Timeout::Error` in `start_database_call`.
