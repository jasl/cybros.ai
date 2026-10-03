require "support/daemon_loop_helpers"

class HostPolicyRecoveryTest < Minitest::Test
  include RhoTest::DaemonLoopHelpers

  def test_explicit_attach_after_cache_loss_recovers_policy_and_current_runner_and_answerer
    api = NexusDoubles::FakeAgentApi.new(user_public_id: "foreign-answerer", conversation_events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    until_policy = Rho::Until::Policy.new(command: "make test", attempts: 2,
      directory: @root, runner: "remote-runner", seed: {})
    notes = { "rho.until" => until_policy.to_h }
    store.remember(conversation_host("c-recovered"), workspace: "ws-1", model: "dev/recovered", compose: false,
      notes: notes, runner: "stale-runner", answerer: "stale-answerer")
    api.bind_runner("c-recovered", "remote-runner")
    cache_path = daemon.home.host_cache_path(IDENTITY.user_public_id)
    cached = JSON.parse(File.read(cache_path)).fetch("hosts").fetch(0)
    %w[model compose notes].each { |key| refute cached.key?(key), "business policy must not live in the follower cache" }
    daemon.stop
    FileUtils.rm_f(cache_path)

    restarted = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    assert_empty host_store(restarted).rows
    response = attach(restarted, "c-recovered")

    assert_equal "200", response.code, response.body
    row = host_store(restarted).find("c-recovered")
    assert_equal ["dev/recovered", false, notes], [row.model, row.compose, row.notes]
    assert_equal ["remote-runner", "foreign-answerer"], [row.runner, row.answerer]
    assert_equal notes, restarted.loops.notes("c-recovered")
    assert_equal ["c-recovered"], followed(restarted).map { |entry| entry.fetch("public_id") }
    assert_empty api.conversation_inputs, "restoration follows existing work without creating another input"
  end

  def test_policy_read_failure_blocks_attach_and_say_even_when_cache_has_a_prior_projection
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-unavailable"), workspace: "ws-1", model: "dev/old", compose: false)
    original_call = api.method(:call)
    api.define_singleton_method(:call) do |path, **options|
      if path.include?("/store_entries") && options.fetch(:method, :get) == :get
        CybrosAgent::Response.new(status: 503, headers: {}, body: nil)
      else
        original_call.call(path, **options)
      end
    end

    attached = attach(daemon, "c-unavailable")
    assert_equal "502", attached.code, attached.body
    said = request(daemon, :post, "/say", token: bearer(daemon),
      body: { public_id: "c-unavailable", text: "continue" })
    assert_equal "502", said.code, said.body
    assert_empty daemon.lineage.runs, "an unreadable policy must not start an unconfigured follower"
    assert_empty api.conversation_inputs, "cached preferences must not authorize another input"

    api.define_singleton_method(:call, original_call)
    recovered = attach(daemon, "c-unavailable")
    assert_equal "200", recovered.code, recovered.body
    assert_equal "dev/old", store.find("c-unavailable").model
  end

  def test_evicted_sides_are_reused_and_expired_from_their_nexus_policy
    now = Time.utc(2026, 10, 1, 12)
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = member_ready(boot(clock: -> { now }, realtime_factory: ->(*) { nil }), api)
    store.remember(conversation_host("c-parent"), workspace: "ws-1", model: "dev/side", compose: false)
    fresh = { "parent" => "c-parent", "tools" => "none", "opened_at" => (now - 60).iso8601,
              "last_turn_at" => (now - 60).iso8601 }
    expired = fresh.merge("parent" => "c-other", "last_turn_at" => (now - Rho::Daemon::Loops::SIDE_IDLE_TTL - 1).iso8601)
    store.remember(conversation_host("c-fresh-side"), workspace: "ws-1", model: "dev/side", compose: false,
      notes: { "rho.side" => fresh })
    store.remember(conversation_host("c-expired-side"), workspace: "ws-1", model: "dev/side", compose: false,
      notes: { "rho.side" => expired })
    Rho::HostStore::MAX_ROWS.times { |index| store.remember(loop_host("cached-#{index}"), workspace: "ws-1") }
    assert_nil store.find("c-fresh-side")
    assert_nil store.find("c-expired-side")

    assert_equal "200", attach(daemon, "c-parent").code
    response = request(daemon, :post, "/side", token: bearer(daemon), body: { parent_public_id: "c-parent", tools: "read" })
    assert_equal "200", response.code, response.body
    assert_equal ["c-fresh-side", true], JSON.parse(response.body).then { |body| [body.dig("side", "public_id"), body.fetch("reused")] }
    assert_empty api.forks, "evicting the follower must not create a second side"
    assert_equal "read", store.find("c-fresh-side").notes.fetch("rho.side").fetch("tools")

    assert_equal ["c-expired-side"], daemon.loops.sweep_sides(now)
    assert_equal ["c-expired-side"], api.conversation_deletes
    assert_empty daemon.loops.sweep_sides(now)
  end

  def test_readopt_imports_a_legacy_model_only_row_into_nexus_and_retires_the_source
    api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, conversation_events: [])
    daemon = boot(realtime_factory: ->(*) { nil })
    legacy_path = File.join(daemon.home.tmp_root, "hosts.json")
    Rho::StateFile.new(legacy_path).write("hosts" => [{
      "host_type" => "conversation", "host_public_id" => "c-legacy", "workspace" => "ws-1",
      "live" => true, "remembered_at" => Time.now.utc.iso8601, "model" => "dev/legacy",
    }])
    member_ready(daemon, api)

    daemon.loops.readopt(NexusDoubles::MEMBER_TOKEN, "ws-1")

    stored = api.store_entries_of("c-legacy").find { |row| row.fetch("namespace") == Rho::HostPolicy::NAMESPACE }
    refute_nil stored
    assert_equal [IDENTITY.user_public_id, "c-legacy", "dev/legacy", {}],
      stored.fetch("value").values_at("owner_public_id", "host_public_id", "model", "notes")
    assert_equal ["c-legacy"], followed(daemon).map { |row| row.fetch("public_id") }
    assert_equal "dev/legacy", store.find("c-legacy").model
    refute File.exist?(legacy_path)
    assert File.file?(File.join(daemon.home.tmp_root, "hosts.#{IDENTITY.user_public_id}.imported.json"))
    assert_equal 1, api.store_entry_creates.length
  end

  private

    def attach(daemon, public_id)
      request(daemon, :post, "/loops/attach", token: bearer(daemon), body: { public_id: public_id, host_type: "conversation" })
    end
end
