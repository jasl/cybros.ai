require_relative "../test_helper"
require_relative "../support/ops_harness"

# One-shot submission, subscriptions and credential-bound follower ownership.
class OpsOneShotsTest < Minitest::Test
  include RhoTest::OpsHarness

  class OneShotLane
    Pending = Data.define(:result)

    def initialize(page)
      @page = page
    end

    def feed(_public_id, **_options)
      CybrosAgent::KernelFeed.new(replay: ->(_cursor) { @page })
    end

    def fetch(_public_id) = Pending.new(result: nil)
    def realtime_opener(_public_id, _realtime, items: nil) = raise "not used"
  end

  def queued_one_shot_response(public_id: "os-accepted")
    {
      "one_shot" => {
        "public_id" => public_id,
        "workload" => "text_generation",
        "status" => "queued",
        "model" => {
          "provider_id" => "dev", "model_ref" => "mock-text",
          "reasoning_effort" => nil,
        },
        "billing_subject" => nil,
        "created_at" => "2026-08-28T00:00:00Z",
        "updated_at" => "2026-08-28T00:00:00Z",
        "usage_summary" => {
          "request_count" => 0,
          "input_tokens" => 0,
          "cache_read_tokens" => 0,
          "uncached_input_tokens" => 0,
          "cache_creation_tokens" => 0,
          "cache_hit_rate" => nil,
          "output_tokens" => 0,
          "reasoning_tokens" => 0,
          "total_tokens" => 0,
          "cost_amount" => "0.0",
          "cost_complete" => true,
        },
      },
    }
  end

  def blocking_one_shot_transport(started, release)
    response = queued_one_shot_response
    Object.new.tap do |transport|
      transport.define_singleton_method(:call) do |_path, method: :get, credential:,
        body: nil, params: nil, headers: {}, timeout:|
        started << true
        release.pop
        CybrosAgent::Response.new(status: 202, headers: {}, body: response)
      end
    end
  end

  # A create that answers at once and keeps what crossed the wire: the
  # envelope is what a test of the create members can honestly read.
  def capturing_one_shot_transport(bodies)
    response = queued_one_shot_response
    Object.new.tap do |transport|
      transport.define_singleton_method(:call) do |_path, method: :get, credential:,
        body: nil, params: nil, headers: {}, timeout:|
        bodies << body
        CybrosAgent::Response.new(status: 202, headers: {}, body: response)
      end
    end
  end

  def adopt_one_shot(daemon, about, lane, public_id, body)
    Rho::Extensions::Ops::OneShots.adopt(daemon.context, about, lane, public_id, body)
  end

  # THE CREATE ENVELOPE. rho was a truncated client of a complete API: it read
  # four members off the body and dropped the rest, so generation control could
  # not cross this daemon at all — and a caller who sent some got a 202 and
  # silence, which is worse than a refusal.
  def test_generation_control_crosses_the_daemon_and_an_absent_one_stays_absent
    daemon = one_shot_ready(boot)
    bodies = []
    daemon.wire.api_transport = capturing_one_shot_transport(bodies)
    create = route(daemon, "POST", "/one_shots")

    capturing_spawns(daemon) do
      create.call(json_request(one_shot_body.merge(
        "configuration" => { "temperature" => 0.2 }, "reasoning_effort" => "low"
      ), token: bearer(daemon)))
      create.call(json_request(one_shot_body, token: bearer(daemon)))
      create.call(json_request(one_shot_body.merge("configuration" => nil), token: bearer(daemon)))
    end

    carried, plain, explicit_null = bodies.map { |body| body.fetch("one_shot") }
    assert_equal({ "temperature" => 0.2 }, carried.fetch("configuration"))
    assert_equal "low", carried.dig("model", "reasoning_effort")
    # ABSENT, NOT NULL. rho forwards opaque JSON and lets Nexus be the
    # authority on the vocabulary, so the only thing it owes is the difference
    # between "I said nothing" and "I said nothing on purpose" — an explicit
    # null reaches the request digest that idempotency receipts are taken over.
    refute plain.key?("configuration")
    refute plain.fetch("model").key?("reasoning_effort")
    refute explicit_null.key?("configuration")
  end

  # THE OUTPUT SUBSCRIPTION FOLLOWS ATTENTION, and the caller is what knows
  # where attention is. A run nobody is looking at keeps a lifecycle-only
  # logical subscription on the shared connection; one coming into focus gets
  # what already landed and then continues with full output through the SDK's
  # own barrier.
  def test_subscribing_and_unsubscribing_move_one_followed_run
    daemon = one_shot_ready(boot)
    moves = []
    run = fake_run("os-1")
    run.define_singleton_method(:attach_socket) { moves << :attach; true }
    run.define_singleton_method(:detach_socket) { moves << :detach; false }
    run.define_singleton_method(:snapshot) do
      Struct.new(:to_h).new({ public_id: "os-1", live: true })
    end
    daemon.lineage.install_run(daemon.lineage.credentials, run)

    status, body = route(daemon, "POST", "/one_shots/subscribe")
      .call(json_request({ "public_id" => "os-1" }, token: bearer(daemon)))
    assert_equal 200, status
    assert body.fetch(:changed), "a caller can tell 'I attached it' from 'it already was'"
    assert_equal({ public_id: "os-1", live: true }, body.fetch(:one_shot))

    _status, body = route(daemon, "POST", "/one_shots/unsubscribe")
      .call(json_request({ "public_id" => "os-1" }, token: bearer(daemon)))
    refute body.fetch(:changed), "and the second answer says nothing moved"
    assert_equal %i[attach detach], moves
  end

  def test_a_run_this_daemon_does_not_follow_is_a_404
    daemon = boot
    subscribe = route(daemon, "POST", "/one_shots/subscribe")
    status, body = subscribe.call(json_request({ "public_id" => "nope" }, token: bearer(daemon)))

    assert_equal 404, status
    assert_equal "one_shot_not_followed", body.dig(:error, :code)

    status, body = subscribe.call(json_request({}, token: bearer(daemon)))
    assert_equal 400, status
    assert_equal "parameter_missing", body.dig(:error, :code)
  end

  def test_current_lineage_runs_share_one_realtime_client
    daemon = one_shot_ready(boot)
    about = daemon.lineage.credentials
    page = CybrosAgent::Api::OneShotEventPage.new(items: [], next_after: nil, watermark: 0)
    lane = OneShotLane.new(page)

    first, first_adopted = adopt_one_shot(daemon, about, lane, "os-1", {})
    second, second_adopted = adopt_one_shot(daemon, about, lane, "os-2", { "live" => false })

    assert first_adopted
    assert second_adopted
    assert_same first.realtime, second.realtime,
      "one credential lineage owns one multiplexed ActionCable client"
    assert_equal [first, second], daemon.lineage.runs
    refute second.snapshot.live,
      "live false selects lifecycle-only output without allocating another client"
  end

  # Nexus can answer the replay before the original request's 202 reaches this
  # daemon. The resource id, not response arrival order, is the local registry
  # authority, so either response reuses the one follower already installed.
  def test_the_same_remote_run_is_adopted_once_regardless_of_response_order
    daemon = one_shot_ready(boot)
    about = daemon.lineage.credentials
    page = CybrosAgent::Api::OneShotEventPage.new(items: [], next_after: nil, watermark: 0)
    lane = OneShotLane.new(page)

    replay, replay_adopted = adopt_one_shot(daemon, about, lane, "os-same", {})
    original, original_adopted = adopt_one_shot(daemon, about, lane, "os-same", {})

    assert replay_adopted
    refute original_adopted
    assert_same replay, original
    assert_equal [replay], daemon.lineage.runs
  end

  # THE CEILING IS NEXUS'S. Staging bytes is an ordinary HTTP POST to the
  # member plane's `/uploads` on the credential this caller already holds, so
  # what reaches rho is the id that came back — the daemon never touches the
  # bytes and has no reason to be the narrower thing. Dropping this member is
  # what made rho advertise five workloads and serve one: transcription and
  # every media input need it, and Nexus refuses without it.
  def test_an_upload_reference_and_a_billing_subject_cross_the_daemon
    daemon = one_shot_ready(boot)
    bodies = []
    daemon.wire.api_transport = capturing_one_shot_transport(bodies)

    capturing_spawns(daemon) do
      route(daemon, "POST", "/one_shots").call(json_request({
        "model" => "dev/mock-transcription", "input" => "transcribe it",
        "idempotency_key" => "k-1", "workload" => "transcription",
        "upload_public_ids" => %w[up-1], "billing_subject" => "bs-1",
      }, token: bearer(daemon)))
    end

    fields = bodies.fetch(0).fetch("one_shot")
    assert_equal %w[up-1], fields.fetch("upload_public_ids")
    assert_equal "bs-1", fields.fetch("billing_subject")
    assert_equal "transcription", fields.fetch("workload")
  end

  # A MINTED KEY IS A SECOND BILL. rho used to supply `SecureRandom.uuid` when
  # the caller sent none, which made every retried POST a fresh run — the exact
  # thing the SDK refuses to do for its own callers, "because a retry that the
  # caller cannot recognize as a retry is how one prompt becomes two bills".
  def test_the_daemon_never_mints_an_idempotency_key
    daemon = one_shot_ready(boot)
    bodies = []
    daemon.wire.api_transport = capturing_one_shot_transport(bodies)

    status, body = route(daemon, "POST", "/one_shots").call(
      json_request({ "model" => "dev/mock-text", "input" => "hi" }, token: bearer(daemon))
    )

    assert_equal 400, status
    assert_equal "parameter_missing", body.dig(:error, :code)
    assert_empty bodies, "nothing crossed the wire without the caller's own key"
  end

  def test_shutdown_waits_for_an_accepted_run_to_be_registered_before_draining
    daemon = one_shot_ready(boot)
    create_started = Queue.new
    release_create = Queue.new
    daemon.wire.api_transport = blocking_one_shot_transport(create_started, release_create)
    request_body = {
      "model" => "dev/mock-text", "input" => "hi", "idempotency_key" => "k-accepted",
    }
    creating = nil
    stopping = nil

    capturing_spawns(daemon) do |spawned|
      creating = Thread.new do
        route(daemon, "POST", "/one_shots").call(json_request(request_body, token: bearer(daemon)))
      end
      create_started.pop
      stopping = Thread.new do
        daemon.lineage.begin_stop
        daemon.lineage.quiesce(deadline: Rho::Daemon::STOP_CONTROL_DRAIN_DEADLINE)
      end
      await_daemon_stopping(daemon)
      assert stopping.alive?, "shutdown waits for the admitted create to reach its local checkpoint"

      release_create << true
      status, body = creating.value
      stopping.value

      runs = daemon.lineage.runs
      assert_equal 202, status
      assert_equal "os-accepted", body.dig(:one_shot, :public_id)
      assert_equal ["os-accepted"], runs.map(&:public_id)
      assert_equal 2, spawned.size, "the registered run starts its event and result followers exactly once"
    end
  ensure
    release_create&.push(true)
    daemon&.lineage&.abort_stop
    creating&.kill if creating&.alive?
    stopping&.kill if stopping&.alive?
  end

  def test_an_idempotent_create_replay_reuses_the_registered_run
    daemon = one_shot_ready(boot)
    calls = 0
    response = queued_one_shot_response
    transport = Object.new
    transport.define_singleton_method(:call) do |_path, method: :get, credential:,
      body: nil, params: nil, headers: {}, timeout:|
      calls += 1
      CybrosAgent::Response.new(
        status: calls == 1 ? 202 : 200, headers: {}, body: response
      )
    end
    daemon.wire.api_transport = transport
    request_body = {
      "model" => "dev/mock-text", "input" => "hi", "idempotency_key" => "same-key",
    }
    create = route(daemon, "POST", "/one_shots")

    capturing_spawns(daemon) do |spawned|
      first = create.call(json_request(request_body, token: bearer(daemon)))
      replay = create.call(json_request(request_body, token: bearer(daemon)))

      assert_equal 202, first.first
      assert_equal 202, replay.first
      assert_equal "os-accepted", replay.last.dig(:one_shot, :public_id)
      assert_equal 1, daemon.lineage.runs.size
      assert_equal 2, spawned.size,
        "a replay reuses both followers instead of opening a duplicate channel or result poller"
    end
  end

  def test_credential_replacement_after_acceptance_delivers_the_locator_without_stale_adoption
    daemon = one_shot_ready(boot)
    create_started = Queue.new
    release_create = Queue.new
    daemon.wire.api_transport = blocking_one_shot_transport(create_started, release_create)
    request_body = {
      "model" => "dev/mock-text", "input" => "hi", "idempotency_key" => "k-rotation",
    }
    creating = nil

    capturing_spawns(daemon) do |spawned|
      creating = Thread.new do
        route(daemon, "POST", "/one_shots").call(json_request(request_body, token: bearer(daemon)))
      end
      create_started.pop
      daemon.lineage.adopt(identity: IDENTITY, credentials: Rho::Credentials.new)
      release_create << true
      status, body = creating.value

      assert_equal 202, status
      assert_equal "os-accepted", body.dig(:one_shot, :public_id),
        "the accepted remote run remains recoverable by the locator returned to the caller"
      assert_empty daemon.lineage.runs,
        "an old-lineage run must not be installed into the replacement's registry"
      assert_nil daemon.lineage.realtime
      assert_empty spawned, "a dead credential has no useful follower to start"
    end
  ensure
    release_create&.push(true)
    creating&.kill if creating&.alive?
  end
end
