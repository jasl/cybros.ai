require "support/daemon_run_helpers"

class DaemonPresetsTest < Minitest::Test
  include RhoTest::DaemonRunHelpers

  def ready
    @api = kernel_api(user_public_id: IDENTITY.user_public_id)
    @daemon = member_ready(boot(realtime_factory: ->(*) { nil },
      config: catalog_config("default_model" => "dev/first", "fallback_models" => ["dev/second", "dev/third"])), @api)
  end

  def call(verb, path, body = nil)
    response = request(@daemon, verb, path, token: bearer(@daemon), body: body)
    assert_equal "200", response.code, response.body
    JSON.parse(response.body)
  end

  def test_catalog_edits_and_role_publication_never_create_identities
    ready
    catalog = call(:get, "/presets")
    main = catalog.fetch("main_preset_public_id")
    created = call(:post, "/presets", { name: "Custom", description: "Review changes", configuration: { model: "dev/reviewer" } })
    custom = created.fetch("presets").find { |row| row.fetch("name") == "Custom" }
    assert_equal main, created.fetch("main_preset_public_id")
    assert_equal 7, created.fetch("presets").length

    published = call(:put, "/presets/role", { public_id: custom.fetch("public_id"), name: "custom-review", description: "Review supplied work" })
    row = published.fetch("presets").find { |preset| preset.fetch("public_id") == custom.fetch("public_id") }
    assert_equal "custom-review", row.dig("role", "name")
    assert_equal "dev/reviewer", row.dig("configuration", "model")
    assert_empty @api.named_agent_declarations
  end

  def test_preset_edits_change_future_input_configuration_without_changing_identity_or_old_input
    ready
    catalog = call(:get, "/presets")
    main = catalog.fetch("presets").find { |row| row.fetch("public_id") == catalog.fetch("main_preset_public_id") }
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1")

    call(:post, "/say", { public_id: "c-1", text: "First task" })
    first = @api.conversation_inputs.last.fetch("input")
    assert_equal "dev/first", first.dig("model", "model")
    assert_equal "default", first.dig("model_selection", "source")
    assert_equal ["dev/second", "dev/third"], first.fetch("fallback_models")

    call(:put, "/presets", main.slice("public_id", "name", "description").merge("configuration" => {
      "model" => "dev/new", "system_prompt" => "NEW-PRESET-PROMPT", "fallback_models" => [] }))
    call(:post, "/say", { public_id: "c-1", text: "Second task" })
    second = @api.conversation_inputs.last.fetch("input")
    assert_equal "dev/new", second.dig("model", "model")
    assert_empty second.fetch("fallback_models")
    assert_includes second.dig("execution_declaration", "system_prompt", "content"), "NEW-PRESET-PROMPT"
    refute_includes first.dig("execution_declaration", "system_prompt", "content"), "NEW-PRESET-PROMPT"
    assert_equal "dev/first", first.dig("model", "model")
    refute second.key?("answering_user_public_id")
    assert_empty @api.named_agent_declarations
  end

  def test_role_withdrawal_changes_only_future_captured_directories
    ready
    catalog = call(:get, "/presets")
    reviewer = catalog.fetch("presets").find { |entry| entry.dig("role", "name") == "reviewer" }
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1")
    call(:post, "/say", { public_id: "c-1", text: "First task" })
    first = @api.conversation_inputs.last.dig("input", "execution_declaration", "delegation_catalog")

    call(:delete, "/presets/role", { public_id: reviewer.fetch("public_id") })
    call(:post, "/say", { public_id: "c-1", text: "Next task" })
    next_catalog = @api.conversation_inputs.last.dig("input", "execution_declaration", "delegation_catalog")

    assert_equal %w[worker planner explorer reviewer], first.map { |entry| entry.fetch("name") }
    assert_equal %w[worker planner explorer], next_catalog.map { |entry| entry.fetch("name") }
    assert_empty @api.named_agent_declarations
  end

  def test_child_and_fork_continuations_leave_configuration_and_automatic_model_with_the_kernel
    ready
    original = @api.method(:conversation_row)
    @api.define_singleton_method(:conversation_row) do |*arguments, **keywords|
      original.call(*arguments, **keywords).merge("execution_declaration_present" => true)
    end
    store.remember(conversation_host("c-1"), workspace: "ws-1", turn: "t-1", run_public_id: "al-1", model: "old/parent")
    call(:post, "/say", { public_id: "c-1", text: "Continue this role task" })
    fields = @api.conversation_inputs.last.fetch("input")
    refute fields.key?("model")
    refute fields.key?("execution_declaration")
    refute fields.key?("model_selection")
    refute fields.key?("fallback_models")
    assert_equal "c-1", @api.tool_assemblies.last.fetch("conversation_public_id")
    refute @api.tool_assemblies.last.key?("configuration")

    call(:post, "/say", { public_id: "c-1", text: "Use this model for the next task", model: "dev/explicit", fallback_models: [] })
    explicit = @api.conversation_inputs.last.fetch("input")
    assert_equal "dev/explicit", explicit.dig("model", "model")
    assert_empty explicit.fetch("fallback_models")
    refute explicit.key?("execution_declaration")
  end
end
