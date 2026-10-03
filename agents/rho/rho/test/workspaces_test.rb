require "support/daemon_loop_helpers"

class WorkspacesTest < Minitest::Test
  include RhoTest::DaemonLoopHelpers

  def test_discovery_and_creation_do_not_need_a_valid_default
    api = kernel_api(workspaces: [
      { public_id: "mine", name: "Mine" },
      { public_id: "room", name: "Team", dedicated: false },
      { public_id: "foreign", name: "Other agent", own: false },
    ])
    daemon = member_ready(boot, api)
    daemon.home.write_setting("workspace", "missing")
    core = Rho::Core.new(home: daemon.home)

    listing = core.workspaces
    assert_equal %w[mine room], listing.fetch("workspaces").map { |row| row.fetch("public_id") }
    assert_equal "missing", listing.fetch("selection")
    assert_nil listing.fetch("workspace")
    assert_equal "mine", core.workspace("mine").fetch("public_id")
    error = assert_raises(Rho::Core::Refused) { core.workspace("foreign") }
    assert_equal "workspace_unavailable", error.code
    assert_equal "New", core.create_workspace(name: "New", idempotency_key: "create-workspace").fetch("name")
    assert_equal "create-workspace", api.workspace_creates.last.fetch(:headers).fetch("Idempotency-Key")

    assert_equal "room", core.select_workspace("room").fetch("public_id")
    assert_equal "room", daemon.home.settings_workspace
    assert_equal "room", core.workspaces.dig("workspace", "public_id")
    assert_raises(Rho::Core::Refused) { core.select_workspace("missing") }
    assert_equal "room", daemon.home.settings_workspace
  end

  def test_new_open_uses_fresh_default_or_explicit_workspace_and_old_hosts_keep_their_scope
    api = kernel_api(workspaces: [{ public_id: "ws-1", name: "First" }, { public_id: "ws-2", name: "Second" }])
    daemon = member_ready(boot, api)
    core = Rho::Core.new(home: daemon.home)
    capturing_spawns(daemon) do
      first = core.open_conversation.fetch("conversation").fetch("public_id")
      assert_equal "ws-1", store.find(first).workspace
      core.select_workspace("ws-2")
      core.open_conversation
      assert_equal "/agent_api/v1/workspaces/ws-2/conversations", api.requests.reverse.find { |entry| entry.first.end_with?("/conversations") }.first
      core.open_conversation(workspace_public_id: "ws-1")
      assert_equal "/agent_api/v1/workspaces/ws-1/conversations", api.requests.reverse.find { |entry| entry.first.end_with?("/conversations") }.first
      # The double reuses c-1; restore the first host's durable routing hint.
      store.remember(conversation_host(first), workspace: "ws-1")
      daemon.home.write_setting("workspace", "missing")
      assert_equal "ws-1", core.conversation(first).fetch("workspace_public_id")
      core.turns(first)
      core.say(first, "observed", mode: "queue", kind: "message")
      core.stop(first)
      host_paths = api.requests.map(&:first).grep(%r{/conversations/#{first}(?:/|\z)})
      assert host_paths.all? { |path| path.start_with?("/agent_api/v1/workspaces/ws-1/") }, host_paths.inspect
      assert_raises(Rho::Core::Refused) { core.open_conversation }
    end
  end

  def test_boot_override_is_explicit_and_saved_default_survives_a_fresh_config_load
    api = kernel_api(workspaces: [{ public_id: "room", name: "Team", dedicated: false }])
    daemon = member_ready(boot(config: Rho::Config.from_hash("workspace" => "room")), api)
    core = Rho::Core.new(home: daemon.home)
    error = assert_raises(Rho::Core::Refused) { core.select_workspace("room") }
    assert_equal "workspace_overridden", error.code
    assert_nil daemon.home.settings_workspace

    daemon.home.write_setting("workspace", "room")
    config = Rho::Config.load(daemon.home.settings_path, env: {})
    refute config.workspace_override
    assert_equal "room", config.workspace_selection(daemon.home)
    daemon.home.write_setting("workspace", "next")
    assert_equal "next", config.workspace_selection(daemon.home)
    overridden = Rho::Config.load(daemon.home.settings_path, env: {}, flags: { workspace: "fixed" })
    assert_equal "fixed", overridden.workspace_selection(daemon.home)
  end

  def test_clearing_the_saved_workspace_immediately_restores_the_dedicated_default
    home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
    home.write_setting("workspace", "ws-1")
    api = kernel_api(workspaces: [
      { public_id: "ws-1", name: "Selected room", dedicated: false },
      { public_id: "dedicated", name: "Agent default", dedicated: true },
    ])
    daemon = member_ready(boot(home: home, config: Rho::Config.load(home.settings_path, env: {})), api)
    core = Rho::Core.new(home: daemon.home)

    capturing_spawns(daemon) do
      first = core.open_conversation.fetch("conversation").fetch("public_id")
      assert_equal "ws-1", store.find(first).workspace

      core.update_settings("workspace" => nil)

      assert_nil core.settings.dig("settings", "workspace")
      assert_equal "dedicated", core.workspaces.dig("workspace", "public_id")
      assert_equal "dedicated", daemon.lineage.workspace.public_id
      assert_equal "ws-1", core.conversation(first).fetch("workspace_public_id")
      core.open_conversation
      path = api.requests.reverse.find { |entry| entry.first.end_with?("/conversations") }.first
      assert_equal "/agent_api/v1/workspaces/dedicated/conversations", path
      assert_empty api.workspace_creates, "the existing dedicated workspace is reused"
    end
  end

  def test_task_scope_keeps_waited_and_nested_child_environment_reads_in_the_original_workspace
    api = kernel_api(workspaces: [{ public_id: "ws-1", name: "First" }, { public_id: "ws-2", name: "Second" }])
    daemon = member_ready(boot, api)
    core = Rho::Core.new(home: daemon.home)
    root = File.join(@root, "project")
    FileUtils.mkdir_p(root)
    capturing_spawns(daemon) do
      core.open_conversation(directory: root)
      api.stock_parent("child", "c-1")
      api.stock_parent("grandchild", "child")
      core.select_workspace("ws-2")

      %w[child grandchild].each do |child|
        assert_nil daemon.loops.host_workspace(child), "no settled parent or child-mail event has listed this child"
        context = Rho::Runner::ExecutionContext.new(workspace_public_id: "ws-1",
          conversation_public_id: child, agent_loop_public_id: "loop-#{child}")
        Rho::Runner::ExecutionContext.with(context) do
          plane = daemon.host.member_plane.call(host_public_id: child, workspace_public_id: context.workspace_public_id)
          assert_equal "ws-1", plane.workspace_public_id
          binding = daemon.host.environments.call.resolve(child, child == "child" ? "c-1" : "child")
          assert_equal root, binding.root
          assert_equal "c-1", binding.anchor
        end
        assert_nil store.find(child), "execution scope does not attach a host"
      end

      paths = api.requests.map(&:first).grep(%r{/conversations/(?:child|grandchild)(?:/|\z)})
      refute_empty paths
      assert paths.all? { |path| path.start_with?("/agent_api/v1/workspaces/ws-1/") }, paths.inspect
      assert_equal "ws-2", core.workspaces.dig("workspace", "public_id")
    end
  end
end
