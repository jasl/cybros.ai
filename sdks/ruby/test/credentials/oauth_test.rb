require "test_helper"
require "pp"

# The durable OAuth credential. It owns the one burden a
# long-lived agent cannot get wrong: refresh tokens are single-use and rotate,
# so presenting one that has already been spent is read by the kernel as reuse
# and revokes every credential of the connection at once.
#
# The fake authority below models exactly that — it revokes on a spent token —
# so a replay bug fails these tests the same way it would fail in production
# rather than as a mismatched string.
class CredentialsOAuthTest < Minitest::Test
  # Models the kernel's single-use rotation: one live refresh token at a time,
  # a spent one revokes the family. Records every token it was presented.
  class FakeAuthority
    attr_reader :presented

    def initialize(refresh_token: "rt-0", planes: %i[member executor], expires_in: 3600, latency: nil)
      @current = refresh_token
      @planes = planes
      @expires_in = expires_in
      @latency = latency
      @serial = 0
      @revoked = false
      @presented = []
      @failure = nil
    end

    # Script the next rotation to fail instead of rotating.
    def fail_next_with(error) = @failure = error

    def rotate(refresh_token:)
      @presented << refresh_token
      # A real rotation is a network round trip. Without that window the
      # concurrency tests below would pass even with every guard removed,
      # because threads would never actually overlap.
      sleep(@latency) if @latency
      if (scripted = @failure)
        @failure = nil
        raise scripted
      end
      if @revoked || refresh_token != @current
        @revoked = true
        raise CybrosAgent::DeviceFlow::AuthorizationLostError.new(oauth_error: "invalid_grant")
      end

      @serial += 1
      @current = "rt-#{@serial}"
      CybrosAgent::DeviceFlow::Credentials.new(
        access_token: ("sk-#{@serial}" if @planes.include?(:member)),
        executor_access_token: ("ek-#{@serial}" if @planes.include?(:executor)),
        refresh_token: @current, token_type: "Bearer", expires_in: @expires_in
      )
    end

    # RFC 7009 through the kernel: a presented refresh token ends its family.
    def revoke(token:)
      @presented << token
      @revoked = true if token == @current
      nil
    end

    def revoked? = @revoked
    def rotations = @serial
  end

  def setup
    @now = Time.utc(2026, 7, 26, 12, 0, 0)
    @authority = FakeAuthority.new
  end

  def store = @store ||= MemoryStore.new

  def clock = -> { @now }

  def bundle(serial: 0, expires_in: 3600, planes: %i[member executor])
    CybrosAgent::DeviceFlow::Credentials.new(
      access_token: ("sk-#{serial}" if planes.include?(:member)),
      executor_access_token: ("ek-#{serial}" if planes.include?(:executor)),
      refresh_token: "rt-#{serial}", token_type: "Bearer", expires_in: expires_in
    )
  end

  def issue(credentials = bundle, authority: @authority)
    CybrosAgent::Credentials::OAuth.issue(
      credentials: credentials, authority: authority, store: store, clock: clock
    )
  end

  def load(authority: @authority)
    CybrosAgent::Credentials::OAuth.load(authority: authority, store: store, clock: clock)
  end

  # A restart is invisible: the daemon comes back with the same connection and
  # no second browser ceremony.
  def test_issued_credentials_survive_into_a_new_instance
    issue

    restored = load
    assert_equal "sk-0", restored.member_credential
    assert_equal "ek-0", restored.executor_credential
    assert_equal @now + 3600, restored.expires_at
    assert_empty @authority.presented, "reloading must not spend a rotation"
  end

  def test_load_returns_nil_when_nothing_was_ever_persisted
    assert_nil load
  end

  def test_a_fresh_access_token_is_served_without_spending_a_rotation
    credentials = issue

    assert_equal "sk-0", credentials.member_credential
    assert_equal "sk-0", credentials.member_credential
    assert_empty @authority.presented
  end

  # Proactive: a token inside the skew is renewed before it is handed out, so
  # a caller never gets a credential it is about to be refused for.
  def test_a_credential_inside_the_expiry_skew_is_renewed_before_it_is_served
    credentials = issue
    @now += 3600 - (CybrosAgent::Credentials::OAuth::EXPIRY_SKEW_SECONDS - 1)

    assert_equal "sk-1", credentials.member_credential
    assert_equal ["rt-0"], @authority.presented
  end

  # Persist-before-use: what the caller receives is already on disk. If the
  # process died between rotating and persisting, the token it had just started
  # using would be unrecoverable while the old one was already spent.
  def test_the_rotated_pair_is_on_disk_before_any_caller_can_use_it
    credentials = issue
    @now += 3600

    served = credentials.member_credential
    persisted = store.read

    assert_equal "sk-1", served
    assert_equal served, persisted["access_token"]
    assert_equal "rt-1", persisted["refresh_token"], "the rotated refresh token must be durable first"
    assert_equal "ek-1", persisted["executor_access_token"]
  end

  # After a persist failure memory is ahead of disk. The store check must not
  # replace the live in-memory pair with the spent pair still on disk.
  def test_a_document_older_than_memory_is_never_adopted
    credentials = issue
    fragile = store
    credentials.instance_variable_set(:@store, FailingWrites.new(fragile))
    @now += 3600

    assert_raises(CybrosAgent::Credentials::NotDurable) { credentials.member_credential }
    assert_equal "rt-0", store.read["refresh_token"], "the failed write left the old document"

    credentials.instance_variable_set(:@store, fragile)
    credentials.refresh

    assert_equal ["rt-0", "rt-1"], @authority.presented, "rt-0 was spent; re-presenting it revokes the family"
    refute @authority.revoked?
  end

  # A rotation that succeeded but could not be persisted is not a failed
  # rotation: the old token is already spent, so the new pair is the only live
  # credential and must stay usable. The caller is told durability was lost.
  def test_a_rotation_that_cannot_be_persisted_stays_usable_and_says_so
    credentials = issue
    credentials.instance_variable_set(:@store, FailingWrites.new(store))
    @now += 3600

    error = assert_raises(CybrosAgent::Credentials::NotDurable) { credentials.refresh }
    assert_match(/restart/, error.message)
    assert_equal "sk-1", credentials.member_credential, "the live credential must not be thrown away"
    assert_empty @authority.presented - ["rt-0"], "the rotation must not be retried"
  end

  # Terminal loss stays terminal and stays visible: the document is kept so the
  # operator can see what died rather than finding an empty directory.
  def test_terminal_loss_surfaces_as_itself_and_leaves_the_document_in_place
    credentials = issue
    @authority.fail_next_with(CybrosAgent::DeviceFlow::AuthorizationLostError.new(oauth_error: "invalid_grant"))

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { credentials.refresh }
    assert_equal "rt-0", store.read["refresh_token"]
  end

  # Terminal loss latches. The rotation that failed may in fact have been redeemed — the
  # client reports an indeterminate 5xx or a dispatched-then-lost request as terminal for
  # exactly that reason — so presenting the same token again is how a recoverable
  # situation becomes a reuse event in the kernel's audit log. Never retry the spent
  # token.
  def test_terminal_loss_latches_instead_of_re_presenting_the_same_token
    credentials = issue
    @authority.fail_next_with(
      CybrosAgent::DeviceFlow::AuthorizationLostError.new("refresh rotation outcome unknown; reconnect required")
    )

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { credentials.refresh }
    3.times { assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { credentials.refresh } }

    assert_equal ["rt-0"], @authority.presented, "the spent token must never be presented a second time"
  end

  def test_a_latched_loss_still_reports_the_original_diagnosis
    credentials = issue
    @authority.fail_next_with(
      CybrosAgent::DeviceFlow::AuthorizationLostError.new("refresh rotation outcome unknown; reconnect required")
    )
    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { credentials.refresh }

    error = assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { credentials.refresh }
    assert_match(/outcome unknown/, error.message, "a later caller must not be told a different story")
  end

  # A retryable failure must leave everything exactly as it was, or the retry
  # would present something the server never issued.
  def test_a_retryable_rotation_failure_leaves_the_stored_credentials_untouched
    credentials = issue
    @authority.fail_next_with(CybrosAgent::DeviceFlow::ServerError.new("upstream"))

    assert_raises(CybrosAgent::DeviceFlow::ServerError) { credentials.refresh }
    assert_equal "sk-0", credentials.member_credential
    assert_equal({ "access_token" => "sk-0", "executor_access_token" => "ek-0", "refresh_token" => "rt-0" },
      store.read.slice("access_token", "executor_access_token", "refresh_token"))
  end

  # The planes have independent lifecycles (Round D). Losing the member plane
  # must not take down a still-valid delivery address.
  def test_a_plane_that_died_is_refused_by_name_while_the_other_keeps_working
    credentials = issue
    credentials.instance_variable_set(:@authority, FakeAuthority.new(planes: [:executor]))
    @now += 3600

    assert_equal "ek-1", credentials.executor_credential
    refute credentials.member_plane?
    error = assert_raises(CybrosAgent::Credentials::PlaneUnavailable) { credentials.member_credential }
    assert_match(/member/, error.message)
    refute store.read.key?("access_token"), "a dead plane must not stay in the document"
  end

  def test_a_runner_connection_has_no_member_plane_from_the_start
    credentials = issue(bundle(planes: [:executor]))

    assert_equal "ek-0", credentials.executor_credential
    assert_raises(CybrosAgent::Credentials::PlaneUnavailable) { credentials.member_credential }
  end

  # `rho disconnect`: the lineage's refresh token is presented
  # to the kernel's revocation door and the store is emptied — a revoked
  # secret is not kept.
  def test_revoke_presents_the_refresh_token_to_the_authority_and_empties_the_store
    credentials = issue

    assert_nil credentials.revoke

    assert_equal ["rt-0"], @authority.presented
    assert_predicate @authority, :revoked?
    assert_nil store.read, "the store holds no document after a revoke"
    assert_nil load, "a restart finds no connection to resume"
  end

  # The combined grant mints two lineages; each is its own OAuth object over
  # its own store, so revoking one leaves the other's document in place.
  def test_revoking_one_lineage_leaves_a_sibling_store_untouched
    agent = issue
    runner_store = MemoryStore.new
    runner_authority = FakeAuthority.new(refresh_token: "rt-runner", planes: [:executor])
    runner = CybrosAgent::Credentials::OAuth.issue(
      credentials: bundle(planes: [:executor]).with(refresh_token: "rt-runner"),
      authority: runner_authority, store: runner_store, clock: clock
    )

    runner.revoke

    assert_equal ["rt-runner"], runner_authority.presented
    assert_nil runner_store.read
    assert_equal "sk-0", agent.member_credential
    refute_nil store.read
  end

  # Only one rotation may happen even when every thread wants one at once. The
  # store's lock is what guarantees it — it spans read → rotate → persist for
  # every caller in this process.
  def test_concurrent_callers_in_one_process_produce_exactly_one_rotation
    @authority = FakeAuthority.new(latency: 0.02)
    credentials = issue
    @now += 3600
    start = Queue.new

    threads = 8.times.map { Thread.new { start.pop; credentials.member_credential } }
    8.times { start << :go }
    served = threads.map(&:value)

    assert_equal 1, @authority.rotations
    assert_equal ["sk-1"], served.uniq
  end

  # The reactive path under a burst: several in-flight requests are refused at
  # once and each runs the documented single retry. They are answering the same
  # expiry, so they must cost one rotation, not one each — every extra rotation
  # is another chance to spend a token that cannot be persisted.
  def test_a_burst_of_reactive_retries_after_one_refusal_costs_one_rotation
    @authority = FakeAuthority.new(latency: 0.02)
    credentials = issue
    refused_at = credentials.rotation
    start = Queue.new

    threads = 8.times.map { Thread.new { start.pop; credentials.refresh(after: refused_at) } }
    8.times { start << :go }
    threads.each(&:join)

    assert_equal 1, @authority.rotations
    assert_equal ["rt-0"], @authority.presented
    assert_equal "sk-1", credentials.member_credential
  end

  # Stragglers included: a retry that arrives after the recovery has landed
  # still names the rotation its own failed request used, so it is answered
  # rather than charged for.
  def test_a_late_retry_naming_an_already_recovered_rotation_spends_nothing
    credentials = issue
    refused_at = credentials.rotation
    credentials.refresh(after: refused_at)

    credentials.refresh(after: refused_at)

    assert_equal 1, @authority.rotations
  end

  # A kill may abandon the WAIT for the authority's answer — before the wire,
  # nothing is spent; on the wire, the answer is lost either way and the next
  # boot's re-presentation is the correct probe. What a kill must never do is
  # split the COMMIT: once `rotate` has returned, the replacement exists only
  # in this thread's hands, and a kill landing between that return and
  # `persist!` strands the spent token as the only one on disk — the next boot
  # presents it, the kernel reads replay, and the family is revoked. The gem
  # owns this invariant itself rather than trusting every embedder's shutdown
  # to be polite: the build-and-persist is interrupt-atomic.
  def test_a_kill_cannot_separate_a_rotation_from_its_persist
    entered = Queue.new
    gate = Queue.new
    slow = SlowWrites.new(store, entered: entered, gate: gate)
    oauth = CybrosAgent::Credentials::OAuth.issue(
      credentials: bundle, authority: @authority, store: slow, clock: clock
    )
    slow.arm!

    refresher = Thread.new { oauth.refresh }
    entered.pop # the rotation has returned; the commit is mid-write
    refresher.kill
    gate << true # the kill must wait for this write, not abort it
    refresher.join(5)

    assert_equal 1, store.read.fetch("rotation"),
      "the replacement must reach the store even under a kill"
    assert_equal "rt-0", @authority.presented.last
    refute @authority.revoked?, "nothing was ever re-presented"
  end

  # The wait half of the same rule, pinned so the mask never creeps outward: a
  # kill landing while the rotation is still ON the wire must abort promptly —
  # deferring it until the authority answers would hold a shutdown hostage to
  # a hung network call.
  def test_a_kill_still_abandons_a_rotation_waiting_on_the_wire
    on_wire = Queue.new
    gate = Queue.new
    authority = FakeAuthority.new
    authority.define_singleton_method(:rotate) do |refresh_token:|
      on_wire << true
      gate.pop
      super(refresh_token: refresh_token)
    end
    oauth = CybrosAgent::Credentials::OAuth.issue(
      credentials: bundle, authority: authority, store: store, clock: clock
    )

    refresher = Thread.new { oauth.refresh }
    on_wire.pop
    refresher.kill
    refute_nil refresher.join(5), "a kill on the wire must not wait for the answer"
    assert_equal 0, store.read.fetch("rotation"), "an abandoned wait commits nothing"
  end

  def test_no_diagnostic_renders_a_secret
    credentials = issue(bundle(serial: 0).with(refresh_token: "rt-cybros-api-v1-secret.value"))

    [credentials.inspect, credentials.to_s, PP.pp(credentials, +"")].each do |diagnostic|
      refute_includes diagnostic, "secret.value"
    end
  end

  # A document this class cannot understand is refused rather than half-read:
  # guessing at the shape of a credential file is how a live session gets
  # silently discarded.
  def test_a_document_from_an_unknown_format_is_refused
    issue
    store.write(store.read.merge("version" => 999))

    error = assert_raises(CybrosAgent::Credentials::StoreError) { load }
    assert_match(/version/, error.message)
  end

  def test_a_document_missing_its_refresh_token_is_refused
    issue
    store.write(store.read.except("refresh_token"))

    assert_raises(CybrosAgent::Credentials::StoreError) { load }
  end

  # Every field the class later trusts is checked at the door. A document that
  # loads clean and then dies with a KeyError three frames later tells the
  # operator nothing about what is actually wrong with their credential file.
  def test_a_document_whose_expiry_is_unusable_is_refused_at_load
    issue
    store.write(store.read.merge("expires_at" => "whenever"))

    assert_raises(CybrosAgent::Credentials::StoreError) { load }

    store.write(store.read.except("expires_at"))
    assert_raises(CybrosAgent::Credentials::StoreError) { load }
  end

  def test_a_document_whose_secrets_are_not_secrets_is_refused_at_load
    issue
    store.write(store.read.merge("access_token" => ["sk-0"]))

    assert_raises(CybrosAgent::Credentials::StoreError) { load }
  end

  # A fresh browser ceremony writes a new connection over the old document. Any
  # instance still holding the superseded one must refuse to touch it — its
  # rotation would overwrite the new connection's only refresh token, undoing
  # the ceremony with no error anywhere.
  def test_an_instance_of_a_superseded_connection_refuses_rather_than_clobbering
    superseded = issue
    reconnected = CybrosAgent::Credentials::OAuth.issue(
      credentials: bundle(serial: 9), authority: FakeAuthority.new(refresh_token: "rt-9"),
      store: store, clock: clock
    )
    @now += 3600

    assert_raises(CybrosAgent::Credentials::ConnectionSuperseded) { superseded.refresh }
    assert_equal "rt-9", store.read["refresh_token"], "the fresh ceremony's token must survive"
    assert_empty @authority.presented, "the superseded instance must not spend its own token either"
    assert_equal "sk-1", reconnected.member_credential, "the live connection is unaffected"
  end

  # A winning browser ceremony and an old connection object's committed
  # refresh can overlap in one process. The Store contract makes a write
  # atomic but does not require a bare write to participate in `with_lock`,
  # so the new connection must take that lock itself. Otherwise the old
  # refresh can return after the ceremony
  # and overwrite its only live bundle with the superseded lineage.
  def test_a_fresh_connection_waits_for_an_in_flight_old_rotation_before_persisting
    shared = SeparatelyLockedStore.new
    response_ready = Queue.new
    release_response = Queue.new
    old_authority = FakeAuthority.new
    old_authority.define_singleton_method(:rotate) do |refresh_token:|
      super(refresh_token: refresh_token).tap do
        response_ready << true
        release_response.pop
      end
    end
    old = CybrosAgent::Credentials::OAuth.issue(
      credentials: bundle, authority: old_authority, store: shared, clock: clock
    )

    rotating = Thread.new { old.refresh }
    response_ready.pop

    start_replacement = Queue.new
    replacement = Thread.new do
      start_replacement.pop
      CybrosAgent::Credentials::OAuth.issue(
        credentials: bundle(serial: 9), authority: FakeAuthority.new(refresh_token: "rt-9"),
        store: shared, clock: clock
      )
    end
    shared.watch(replacement)
    start_replacement << true
    shared.await_watched_operation

    release_response << true
    rotating.value
    reconnected = replacement.value

    assert_equal "rt-9", shared.read.fetch("refresh_token"),
      "the fresh ceremony must publish after the old rotation finishes"
    assert_equal "sk-9", reconnected.member_credential
    assert_equal ["rt-0"], old_authority.presented
  ensure
    release_response&.push(true)
    rotating&.join(5)
    replacement&.join(5)
  end

  # A physical write failure means the same thing as any other: the rotation
  # happened, the record of it did not. It must arrive as that contract and not
  # as a raw errno the caller has no reason to associate with credentials.
  def test_a_physical_write_failure_is_reported_as_lost_durability
    credentials = issue
    credentials.instance_variable_set(:@store, FailingWrites.new(store, Errno::ENOSPC))
    @now += 3600

    error = assert_raises(CybrosAgent::Credentials::NotDurable) { credentials.refresh }
    assert_match(/restart/, error.message)
    assert_equal "sk-1", credentials.member_credential
  end

  # A document that is written but whose directory entry could not be flushed
  # is written: forfeiting a live connection over an unconfirmed fsync would
  # cost a human a ceremony for nothing.
  def test_a_published_but_unflushed_document_is_not_a_persist_failure
    credentials = issue
    credentials.instance_variable_set(
      :@store, FailingWrites.new(store, Class.new(CybrosAgent::Error) { include CybrosAgent::Credentials::Store::Published })
    )
    @now += 3600

    assert_equal "sk-1", credentials.member_credential
  end

  # A store whose write, once armed, announces itself and then waits to be
  # released — the deterministic stand-in for "the kill lands mid-commit".
  class SlowWrites
    def initialize(inner, entered:, gate:)
      @inner = inner
      @entered = entered
      @gate = gate
      @armed = false
    end

    def arm! = @armed = true

    def description = @inner.description
    def read = @inner.read
    def delete = @inner.delete
    def with_lock(&) = @inner.with_lock(&)

    def write(document)
      if @armed
        @entered << true
        @gate.pop
      end
      @inner.write(document)
    end
  end

  # A state file whose writes always fail, to prove what happens after a
  # rotation that cannot be made durable. Reads still work, because the
  # question is what the class does with a live-but-unpersisted pair.
  class FailingWrites
    def initialize(inner, error = CybrosAgent::Error)
      @inner = inner
      @error = error
    end

    def description = @inner.description
    def read = @inner.read
    def delete = @inner.delete
    def with_lock(&) = @inner.with_lock(&)
    def write(_document) = raise(@error)
  end

  # A minimal Store whose atomic document publication and caller-controlled
  # coordination lock are deliberately separate. That is legal under the port:
  # `OAuth` owns when an operation must join `with_lock`.
  class SeparatelyLockedStore
    def initialize
      @document = nil
      @document_mutex = Mutex.new
      @coordination_mutex = Mutex.new
      @watched_operation = Queue.new
    end

    def description = "separately locked in-memory store"

    def read
      @document_mutex.synchronize { round_trip(@document) }
    end

    def write(document)
      observed(:write)
      @document_mutex.synchronize { @document = round_trip(document) }
    end

    def delete
      observed(:delete)
      @document_mutex.synchronize { @document = nil }
    end

    def with_lock
      observed(:with_lock)
      @coordination_mutex.synchronize { yield }
    end

    def watch(thread) = @watched_thread = thread
    def await_watched_operation = @watched_operation.pop

    private

      def observed(operation)
        @watched_operation << operation if Thread.current.equal?(@watched_thread)
      end

      def round_trip(document)
        return nil if document.nil?

        JSON.parse(JSON.generate(document))
      end
  end

  # The port, backed by a Hash (CybrosAgent::Credentials::Store). Being able to
  # run every rotation invariant against a store that is a Hash is the point of
  # the port: what the gem owns is the protocol, and the protocol does not know
  # what a file is.
  class MemoryStore
    def initialize = (@document = nil; @monitor = Monitor.new)

    def description = "in-memory store"

    def read = @monitor.synchronize { @document }

    # Round-tripped through JSON like any real store, so a test cannot pass by
    # handing back the very object it stored.
    def write(document)
      @monitor.synchronize { @document = JSON.parse(JSON.generate(document)) }
    end

    def delete = @monitor.synchronize { @document = nil }

    # Re-entrant, because the protocol reads and writes inside its own lock.
    def with_lock(&) = @monitor.synchronize(&)
  end
end
