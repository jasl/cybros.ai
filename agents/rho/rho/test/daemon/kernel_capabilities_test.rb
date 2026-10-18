require "support/daemon_run_helpers"

class DaemonKernelCapabilitiesTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  TOOLS = { "nexus.image.generate" => "image_generate", "nexus.schedules.read" => "read_schedules",
    "nexus.schedules.manage" => "manage_schedule" }.freeze
  CATALOG = TOOLS.map do |canonical, name|
    { "canonical_name" => canonical, "name" => name, "effect_profile" => {},
      "definition" => { "type" => "function", "function" => { "name" => name, "description" => name,
        "parameters" => { "type" => "object", "properties" => {} } } } }
  end.freeze

  def ready(settings = {})
    @api = NexusDoubles::FakeAgentApi.new(tools: [*NexusDoubles::KERNEL_CATALOG, *CATALOG])
    @daemon = member_ready(boot(config: Rho::Config.from_hash({ "kernel_tools" => NexusDoubles::KERNEL_TOOLS.keys + TOOLS.keys }.merge(settings)), realtime_factory: ->(*) { nil }), @api)
    @daemon.context.declare_profile
  end

  def declaration = @api.configuration_declarations.last.fetch("configuration")

  def image_configuration(model = "dev/image")
    { "configuration_version" => 1, "configuration" => { "model" => model } }
  end

  def test_images_and_schedules_execute_in_nexus_and_the_image_model_is_captured
    ready("plugins" => { "rho.images" => image_configuration })

    assert_equal "dev/image", declaration.fetch("image_model")
    TOOLS.each_key { |canonical| assert_includes declaration.fetch("kernel_tools"), canonical }
    names = @daemon.context.registry.serving(:agent).names
    assert_empty names & %w[image_generate imagegen read_schedules manage_schedule summarize_history todo_write]
    children = declaration.fetch("delegation_catalog")
    assert children.all? { |child| child.dig("declaration", "image_model") == "dev/image" }
  end

  def test_images_without_a_model_are_not_declared
    ready

    assert_nil declaration.fetch("image_model")
    refute_includes declaration.fetch("kernel_tools"), "nexus.image.generate"
    refute declaration.fetch("tool_definitions").any? { |entry| entry["canonical"] == "nexus.image.generate" }
  end

  def test_disabled_capabilities_are_not_reintroduced_by_the_catalog_or_aliases
    ready("adaptations" => "codex", "plugins" => {
      "rho.images" => image_configuration.merge("enabled" => false), "rho.schedules" => { "enabled" => false },
    })

    assert_nil declaration.fetch("image_model")
    assert_empty declaration.fetch("kernel_tools") & TOOLS.keys
    assert_empty declaration.fetch("tool_definitions").filter_map { |entry| entry["canonical"] } & TOOLS.keys
  end

  def test_codex_image_alias_is_a_kernel_tool_with_the_captured_model
    ready("adaptations" => "codex", "plugins" => { "rho.images" => image_configuration })

    assert_equal "dev/image", declaration.fetch("image_model")
    alias_entry = declaration.fetch("tool_definitions").find { |entry| entry["canonical"] == "nexus.image.generate" }
    assert_equal "imagegen", alias_entry.dig("function", "name")
  end

  def test_changed_image_model_redeclares_without_registering_an_application_tool
    ready("plugins" => { "rho.images" => image_configuration })
    previous = declaration
    config = @daemon.host.config.with({ "plugins" => @daemon.host.config.plugins.merge("rho.images" => image_configuration("dev/new-image")) })
    loaded = Rho::Extensions.load(host: @daemon.host.with(config: config))

    assert_equal :declared, Async { @daemon.host_followers.configure(config: config, loaded: loaded) }.wait
    assert_equal "dev/new-image", declaration.fetch("image_model")
    assert_equal "dev/image", previous.fetch("image_model")
    assert_equal :declared, Async { @daemon.host_followers.configure(config: config, loaded: loaded) }.wait
  end

  def test_a_preset_summary_model_chooses_its_own_adaptation_prompt
    mock_row("summary", models: ["custom-summary"], summarizer_prompt: "Keep the custom summary facts.")
    ready("default_model" => "dev/default")
    response = request(@daemon, :get, "/presets", token: bearer(@daemon))
    catalog = JSON.parse(response.body)
    main = catalog.fetch("presets").find { |row| row.fetch("public_id") == catalog.fetch("main_preset_public_id") }
    response = request(@daemon, :put, "/presets", token: bearer(@daemon),
      body: main.slice("public_id", "name", "description").merge("configuration" => {
        "compaction_policy" => { "mode" => "kernel", "model" => "dev/custom-summary" },
      }))
    assert_equal "200", response.code, response.body
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1")

    response = request(@daemon, :post, "/say", token: bearer(@daemon), body: { public_id: "c-1", text: "Continue" })

    assert_equal "200", response.code, response.body
    captured = @api.inputs.last.dig("input", "agent_configuration")
    assert_equal "dev/custom-summary", captured.dig("compaction_policy", "model")
    assert_equal "Keep the custom summary facts.", captured.dig("summarizer", "content")
  end

  def test_disabling_compaction_overrides_main_and_role_presets_for_future_inputs
    ready("default_model" => "dev/default")
    response = request(@daemon, :get, "/presets", token: bearer(@daemon))
    catalog = JSON.parse(response.body)
    selected = catalog.fetch("presets").select do |row|
      row.fetch("public_id") == catalog.fetch("main_preset_public_id") || row.dig("role", "name") == "worker"
    end
    selected.each do |preset|
      response = request(@daemon, :put, "/presets", token: bearer(@daemon),
        body: preset.slice("public_id", "name", "description").merge("configuration" => {
          "compaction_policy" => { "mode" => "kernel", "model" => "dev/custom-summary" },
        }))
      assert_equal "200", response.code, response.body
    end
    @daemon.context.declare_profile
    assert_equal "dev/custom-summary", declaration.dig("compaction_policy", "model")
    worker = declaration.fetch("delegation_catalog").find { |entry| entry.fetch("name") == "worker" }
    assert_equal "dev/custom-summary", worker.dig("declaration", "compaction_policy", "model")

    response = request(@daemon, :post, "/extensions/rho.compaction/disable", token: bearer(@daemon), body: {})

    assert_equal "200", response.code, response.body
    refute JSON.parse(response.body).dig("plugin", "active")
    assert_equal({ "mode" => "off" }, declaration.fetch("compaction_policy"))
    assert_nil @api.configuration_declarations.last.dig("prompt_documents", "summarizer")
    declaration.fetch("delegation_catalog").each do |entry|
      assert_equal({ "mode" => "off" }, entry.dig("declaration", "compaction_policy"))
      assert_nil entry.dig("declaration", "summarizer")
    end
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1")

    response = request(@daemon, :post, "/say", token: bearer(@daemon), body: { public_id: "c-1", text: "Continue" })

    assert_equal "200", response.code, response.body
    captured = @api.inputs.last.dig("input", "agent_configuration")
    assert_equal({ "mode" => "off" }, captured.fetch("compaction_policy"))
    assert_nil captured.fetch("summarizer")
    captured.fetch("delegation_catalog").each do |entry|
      assert_equal({ "mode" => "off" }, entry.dig("declaration", "compaction_policy"))
      assert_nil entry.dig("declaration", "summarizer")
    end
  end
end
