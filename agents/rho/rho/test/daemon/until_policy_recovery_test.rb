require "support/daemon_loop_helpers"

class UntilPolicyRecoveryTest < Minitest::Test
  include RhoTest::DaemonLoopHelpers

  def test_first_materialization_commits_the_binding_before_installing_the_check
    api = recovery_api("al-1")
    observed = []
    original_call = api.method(:call)
    api.define_singleton_method(:call) do |path, **options|
      if path.end_with?("/agent_loops/al-1/tasks") && options.fetch(:method, :get) == :post
        observed << store_entries_of("c-1").find { |entry| entry.fetch("namespace") == Rho::HostPolicy::NAMESPACE }
          .dig("value", "notes", "rho.until", "loop_public_id")
      end
      original_call.call(path, **options)
    end
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    notes = { "rho.until" => policy.merge("loop_public_id" => nil), "other" => { "kept" => true } }
    store.remember(conversation_host("c-1"), workspace: "ws-1", model: "dev/mock-text", compose: false,
      turn: "t-1", loop: "al-1", notes: notes)

    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    assert_equal ["al-1"], observed
    assert_equal "al-1", followed(daemon).fetch(0).dig("until", "loop")
    assert_equal "al-1", stored_policy(api).dig("notes", "rho.until", "loop_public_id")
    assert_equal({ "kept" => true }, stored_policy(api).dig("notes", "other"))
    assert_equal ["dev/mock-text", false], stored_policy(api).values_at("model", "compose")
    assert_equal "al-1", store.find("c-1").notes.dig("rho.until", "loop_public_id")
  end

  def test_restart_and_cache_loss_restore_the_gate_on_its_original_loop
    api = recovery_api("al-1")
    restarted = restart_without_cache(api, policy.merge("loop_public_id" => "al-1"))

    response = attach(restarted)

    assert_equal "200", response.code, response.body
    assert_equal "al-1", followed(restarted).fetch(0).dig("until", "loop")
    assert_equal 1, api.appends.length
    assert_empty api.store_entry_updates, "a bound policy needs no further binding write"
  end

  def test_restart_and_cache_loss_do_not_apply_an_old_goal_to_a_later_plain_turn
    api = recovery_api("al-2", conversation_events: [])
    restarted = restart_without_cache(api, policy.merge("loop_public_id" => "al-1"))

    response = attach(restarted)

    assert_equal "200", response.code, response.body
    row = followed(restarted).fetch(0)
    assert_equal "al-2", row.fetch("loop")
    refute row.key?("until"), "the conversation's old goal belongs only to al-1"
    assert_empty api.appends
    assert_equal "al-1", stored_policy(api).dig("notes", "rho.until", "loop_public_id")
  end

  def test_legacy_policy_is_bound_only_when_the_loop_already_has_its_check_and_hold
    api = recovery_api("al-1", checked: true)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", loop: "al-1",
      notes: { "rho.until" => policy })

    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    assert_equal "al-1", stored_policy(api).dig("notes", "rho.until", "loop_public_id")
    assert_equal "al-1", followed(daemon).fetch(0).dig("until", "loop")
    assert_equal 1, api.appends.length, "the original seed receipt is replayed after binding"
  end

  def test_an_unproven_legacy_policy_is_logged_without_a_gate_or_new_check
    api = recovery_api("al-2")
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-2", loop: "al-2",
      notes: { "rho.until" => policy })

    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    refute followed(daemon).fetch(0).key?("until")
    assert_empty api.appends
    assert_empty api.store_entry_updates
    assert_equal policy, stored_policy(api).dig("notes", "rho.until")
    log = File.read(daemon.home.log_path, encoding: Encoding::UTF_8)
    assert_includes log, "event=until.not_restored"
    assert_includes log, "reason=legacy_loop_unproven"
  end

  def test_a_failed_binding_write_never_installs_a_gate_or_check
    rejected = CybrosAgent::Response.new(status: 503, headers: {},
      body: { "error" => { "code" => "unavailable", "message" => "store unavailable" } })
    api = recovery_api("al-1", store_entry_update: rejected)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", loop: "al-1",
      notes: { "rho.until" => policy.merge("loop_public_id" => nil) })

    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    refute followed(daemon).fetch(0).key?("until")
    assert_empty api.appends
    assert_nil stored_policy(api).dig("notes", "rho.until", "loop_public_id")
    assert_nil store.find("c-1").notes.dig("rho.until", "loop_public_id")
    assert_includes File.read(daemon.home.log_path, encoding: Encoding::UTF_8), "event=until.bind_failed"
  end

  def test_a_concurrent_binding_winner_is_not_overwritten_or_retried
    api = recovery_api("al-1")
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", loop: "al-1",
      notes: { "rho.until" => policy.merge("loop_public_id" => nil) })
    winner = stored_policy(api)
    winner["notes"]["rho.until"]["loop_public_id"] = "al-winner"
    original_call = api.method(:call)
    raced = false
    api.define_singleton_method(:call) do |path, **options|
      if !raced && path.include?("/store_entries/") && options.fetch(:method, :get) == :patch
        raced = true
        patch_store_entry("c-1", namespace: Rho::HostPolicy::NAMESPACE, key: Rho::HostPolicy::KEY, value: winner)
      end
      original_call.call(path, **options)
    end

    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    refute followed(daemon).fetch(0).key?("until")
    assert_empty api.appends
    assert_equal "al-winner", stored_policy(api).dig("notes", "rho.until", "loop_public_id")
    assert_equal 1, api.store_entry_updates.length, "a stale binding must not retry against the winning version"
    assert_includes File.read(daemon.home.log_path, encoding: Encoding::UTF_8), "event=until.bind_failed"
  end

  def test_a_failed_first_binding_cannot_move_to_a_later_plain_turn
    assert_failed_binding_cannot_move("al-2", "t-2")
  end

  def test_a_failed_first_binding_cannot_move_to_a_regenerated_variant_of_the_same_turn
    assert_failed_binding_cannot_move("al-regenerated", "t-1")
  end

  def test_pending_policy_with_a_trimmed_materialization_record_is_not_bound
    retained = NexusDoubles::FakeAgentApi::MATERIALIZED_EVENTS.map do |event|
      sequence = event.fetch("sequence") + 10
      event.merge("public_id" => "ev-#{sequence}", "sequence" => sequence, "cursor" => "c#{sequence}",
        "payload" => event.fetch("payload").merge("queue_position" => 0,
        "turn_public_id" => "t-2", "agent_loop_public_id" => "al-2"))
    end
    api = recovery_api("al-2", conversation_events: retained)
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    note = policy.merge("loop_public_id" => nil)
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-2", loop: "al-2",
      notes: { "rho.until" => note })

    assert_nil Rho::Extensions::Until.follow("al-2", note, daemon.context)

    assert_empty api.appends
    assert_empty api.store_entry_updates
    assert_nil stored_policy(api).dig("notes", "rho.until", "loop_public_id")
    assert_includes File.read(daemon.home.log_path, encoding: Encoding::UTF_8), "reason=pending_loop_unproven"
  end

  private

    def assert_failed_binding_cannot_move(next_loop, next_turn)
      api = recovery_api("al-1")
      original_call = api.method(:call)
      reject_binding = true
      api.define_singleton_method(:call) do |path, **options|
        if reject_binding && path.include?("/store_entries/") && options.fetch(:method, :get) == :patch
          CybrosAgent::Response.new(status: 503, headers: {},
            body: { "error" => { "code" => "unavailable", "message" => "store unavailable" } })
        else
          original_call.call(path, **options)
        end
      end
      daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
      note = policy.merge("loop_public_id" => nil)
      store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", loop: "al-1",
        notes: { "rho.until" => note })
      assert_nil Rho::Extensions::Until.follow("al-1", note, daemon.context)
      assert_empty api.appends

      reject_binding = false
      store.remember(conversation_host("c-1"), workspace: "ws-1", turn: next_turn, loop: next_loop)
      assert_nil Rho::Extensions::Until.follow(next_loop, note, daemon.context)
      assert_empty api.appends
      assert_nil stored_policy(api).dig("notes", "rho.until", "loop_public_id")
      assert_includes File.read(daemon.home.log_path, encoding: Encoding::UTF_8), "reason=pending_loop_unproven"

      store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", loop: "al-1")
      gate = Rho::Extensions::Until.follow("al-1", note, daemon.context)
      assert_equal "al-1", gate.loop_public_id, "retrying the original execution remains possible"
      assert_equal "al-1", stored_policy(api).dig("notes", "rho.until", "loop_public_id")
      assert_equal 1, api.appends.length
    end

    def policy
      Rho::Until::Policy.new(command: "make test", attempts: 2, directory: @root, runner: nil, seed: {}).to_h
    end

    def stored_policy(api)
      entry = api.store_entries_of("c-1").find { |row| row.fetch("namespace") == Rho::HostPolicy::NAMESPACE }
      JSON.parse(JSON.generate(entry.fetch("value")))
    end

    def restart_without_cache(api, note)
      daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
      store.remember(conversation_host("c-1"), workspace: "ws-1", notes: { "rho.until" => note })
      cache = daemon.home.host_cache_path(IDENTITY.user_public_id)
      daemon.stop
      FileUtils.rm_f(cache)
      member_ready(boot(realtime_factory: ->(*) { nil }), api)
    end

    def attach(daemon)
      request(daemon, :post, "/loops/attach", token: bearer(daemon), body: { public_id: "c-1", host_type: "conversation" })
    end

    def recovery_api(loop_public_id, checked: false, **options)
      turn_public_id = loop_public_id.sub("al-", "t-")
      variant = { "public_id" => "v-1", "source" => "agent_loop", "status" => "running",
        "agent_loop_public_id" => loop_public_id, "active" => true }
      turn = { "public_id" => turn_public_id, "position" => 0, "kind" => "direct_reply", "role" => "assistant",
        "status" => "running", "visibility" => "visible", "inherited" => false,
        "answering_user_public_id" => IDENTITY.user_public_id, "created_at" => "2026-09-30T00:00:00Z",
        "active_variant" => variant }
      trace = NexusDoubles::RUNNING_TRACE.merge("public_id" => loop_public_id,
        "turn" => { "public_id" => turn_public_id, "conversation_public_id" => "c-1", "status" => "running" })
      if checked
        trace = trace.merge("tasks" => trace.fetch("tasks") + %w[check-1 hold-1].map do |key|
          trace.fetch("tasks").first.merge("key" => key, "status" => "queued")
        end)
      end
      NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, trace: trace,
        conversation_events: NexusDoubles::FakeAgentApi::MATERIALIZED_EVENTS,
        conversation_busy: turn_public_id, turns: [turn],
        variants: { "turn" => { "public_id" => turn_public_id, "inherited" => false }, "variants" => [variant] }, **options)
    end
end
