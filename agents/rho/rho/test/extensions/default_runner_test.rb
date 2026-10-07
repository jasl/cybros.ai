require "test_helper"

class DefaultRunnerExtensionTest < Minitest::Test
  include RhoTest::DaemonHarness

  OWN = NexusDoubles.remote_runner("0199-runner", display_name: "Helper", root: "/home/rho",
    tools: %w[read write bash].map { |name| NexusDoubles.served_tool(name) }, presence: "online")
  ELSEWHERE = NexusDoubles.remote_runner("0199-h", presence: "offline", last_seen_at: "2026-09-08T00:00:00Z")
  DISTINCT = NexusDoubles.remote_runner("0199-k", display_name: "Other",
    tools: [NexusDoubles.served_tool("read", description: "another reader")], presence: "not_yet_seen")

  def store = host_store
  def conversation_host(id) = Rho::Host::Conversation.new(public_id: id)

  def api(**options)
    NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, tools: NexusDoubles::KERNEL_CATALOG,
      executors: [OWN, ELSEWHERE, DISTINCT], **options)
  end

  def ready(api)
    member_ready(boot(config: Rho::Config.from_hash({ "kernel_tools" => NexusDoubles::KERNEL_TOOLS.keys })), api, identity: RUNNER_IDENTITY)
  end

  def select_runner(daemon, host, executor)
    response = request(daemon, :post, "/default_runner", token: bearer(daemon),
      body: { public_id: host, executor_public_id: executor })
    [response.code, JSON.parse(response.body)]
  end

  def test_discovery_lists_distinct_runners_with_the_same_tool_name
    daemon = ready(api())
    File.write(daemon.home.settings_path, JSON.generate("runner" => "0199-h"))
    store.remember(conversation_host("c-1"), workspace: "ws-1", runner: "0199-h")
    rows = JSON.parse(request(daemon, :get, "/runners", token: bearer(daemon)).body).fetch("runners")
    assert_equal %w[0199-runner 0199-h 0199-k], rows.map { |row| row.fetch("public_id") }
    assert_equal true, rows[0].fetch("own")
    assert_equal true, rows[1].fetch("selected")
    assert_equal "offline", rows[1].fetch("presence"), "presence is display metadata, not a candidate filter"
    assert_equal ["c-1"], rows[1].fetch("default_hosts")
    refute rows.any? { |row| row.key?("conflict") }
  end

  def test_discovery_declares_all_candidates_without_copying_runner_schemas
    api = api()
    daemon = ready(api)
    daemon.context.declare_profile
    before = api.configuration_declarations.last

    2.times { assert_equal "200", request(daemon, :get, "/runners", token: bearer(daemon)).code }

    assert_equal 1, api.configuration_declarations.length, "the first declaration already includes the complete candidate list"
    after = api.configuration_declarations.last
    assert_equal before.fetch("prompt_documents"), after.fetch("prompt_documents")
    configuration = after.fetch("configuration")
    assert_equal %w[0199-runner 0199-h 0199-k], configuration.fetch("runner_executor_public_ids")
    assert_nil configuration.fetch("runner_tool_names")
    refute configuration.fetch("tool_definitions").any? { |entry| entry.dig("route", "kind") == "runner" }
  end

  def test_cached_and_remembered_runners_do_not_expand_the_agents_candidate_list
    api = api()
    daemon = ready(api)
    daemon.context.remote_runner("0199-h")
    store.remember(conversation_host("c-1"), workspace: "ws-1", runner: "remembered-only")
    api.remove_executor("0199-h")

    assert_equal :declared, daemon.context.declare_profile

    configuration = api.configuration_declarations.last.fetch("configuration")
    assert_equal %w[0199-runner 0199-k], configuration.fetch("runner_executor_public_ids")
    assert_equal "0199-h", daemon.context.remote_runner("0199-h").public_id,
      "an inspection cache can remain while candidate authority excludes it"
  end

  def test_selection_updates_only_the_default_and_preserves_the_followed_identity
    api = api()
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", run_public_id: "al-1", model: "m/x", runner: "0199-runner")
    code, answer = select_runner(daemon, "al-1", "0199-h")
    assert_equal "200", code, answer.inspect
    assert_equal "0199-h", answer.dig("default_runner", "executor_public_id")
    assert_equal "0199-runner", answer.fetch("previous")
    assert_equal [["c-1", "0199-h"]], api.set_default_runners
    assert api.requests.any? { |path, _| path.end_with?("/conversations/c-1/default_runner") }
    assert_equal ["0199-h", "al-1", "m/x"], [store.find("c-1").runner, store.find("c-1").run_public_id, store.find("c-1").model]
    refute answer.key?("environment")
    assert_empty api.run_creates, "selecting a default does not migrate an environment"
    refute answer.key?("warning")
  end

  def test_same_tool_name_on_another_runner_is_accepted_and_the_default_can_be_cleared
    api = api()
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", runner: "0199-runner")
    code, answer = select_runner(daemon, "c-1", "0199-k")
    assert_equal "200", code, answer.inspect
    assert_equal "0199-k", answer.dig("default_runner", "executor_public_id")
    code, answer = select_runner(daemon, "c-1", nil)
    assert_equal "200", code, answer.inspect
    assert_nil answer.fetch("default_runner")
    assert_nil store.find("c-1").runner
  end

  def test_unknown_hosts_targets_and_missing_keys_are_refused
    api = api()
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", runner: "0199-runner")
    assert_equal "404", select_runner(daemon, "missing", "0199-h").first
    assert_equal "404", select_runner(daemon, "c-1", "missing").first
    assert_equal "400", select_runner(daemon, "c-1", "").first
    assert_equal "400", select_runner(daemon, "", "0199-h").first
    response = request(daemon, :post, "/default_runner", token: bearer(daemon), body: { public_id: "c-1" })
    assert_equal "400", response.code
    assert_empty api.set_default_runners
  end

  def test_changing_or_clearing_the_default_keeps_candidates_and_changes_only_selected_tool_imports
    api = api()
    daemon = ready(api)
    store.remember(conversation_host("c-1"), workspace: "ws-1", runner: "0199-runner")
    assert_equal "200", select_runner(daemon, "c-1", "0199-h").first

    ["0199-k", nil].each do |target|
      assert_equal "200", select_runner(daemon, "c-1", target).first
      configuration = api.configuration_declarations.last.fetch("configuration")
      assert_equal %w[0199-runner 0199-h 0199-k], configuration.fetch("runner_executor_public_ids")
      projection = daemon.context.member_plane(require_workspace: false) do |client, *|
        client.tools.assemble(default_runner_executor_public_id: target)
      end
      targets = projection.tool_definitions.filter_map { |entry| entry.dig("route", "runner_executor_public_id") }.uniq
      assert_equal [target].compact, targets
    end
  end

  def test_kernel_refusal_preserves_the_local_default
    refusal = CybrosAgent::Response.new(status: 409, headers: {}, body: { "error" => { "code" => "runner_not_eligible", "message" => "revoked" } })
    daemon = ready(api(set_default_runner: refusal))
    store.remember(conversation_host("c-1"), workspace: "ws-1", runner: "0199-runner")
    code, answer = select_runner(daemon, "c-1", "0199-h")
    assert_equal ["409", "runner_not_eligible"], [code, answer.dig("error", "code")]
    assert_equal "0199-runner", store.find("c-1").runner
  end

  def test_standalone_runs_use_their_own_default_door
    api = api()
    daemon = ready(api)
    store.remember(Rho::Host::Run.new(public_id: "al-4"), workspace: "ws-1")
    code, answer = select_runner(daemon, "al-4", "0199-h")
    assert_equal "200", code, answer.inspect
    assert_equal({ "type" => "run", "public_id" => "al-4" }, answer.fetch("host"))
    assert api.requests.any? { |path, _| path.end_with?("/runs/al-4/default_runner") }
    assert_equal "0199-h", store.find("al-4").runner
  end

  def test_only_member_modes_ship_default_selection
    assert_includes Rho::Extensions.defaults_for("full"), Rho::Extensions::DefaultRunner
    assert_includes Rho::Extensions.defaults_for("agent"), Rho::Extensions::DefaultRunner
    refute_includes Rho::Extensions.defaults_for("runner"), Rho::Extensions::DefaultRunner
    assert_equal "rho.default_runner", Rho::Extensions::DefaultRunner::NAME
  end
end
