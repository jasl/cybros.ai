require "test_helper"

class AgentDocumentsExtensionTest < Minitest::Test
  include RhoTest::DaemonHarness

  MODEL = { "ref" => "test/text", "provider" => "test", "workload" => "text_generation", "visible" => true,
    "available" => true, "capabilities" => {}, "pricing" => { "state" => "unknown" } }.freeze

  BOT_RUNNER_TOOLS = %w[bash edit file_import file_publish find grep list_processes ls read read_process
    skill start_process stop_process web_fetch write].freeze

  def setup
    super
    @api = NexusDoubles::FakeAgentApi.new(user_public_id: IDENTITY.user_public_id, models: [MODEL])
    @daemon = member_ready(boot(config: Rho::Config.from_hash({ "default_model" => "test/text" })), @api, identity: RUNNER_IDENTITY)
  end

  def test_preset_exports_and_imports_never_create_or_reconfigure_an_identity
    create_source
    before = @api.named_agent_declarations.dup
    settings = bot_settings.dup
    @api.stock_memory("profile", "agent/private-notes", "Keep my notes.")
    %w[md json].each do |format|
      code, exported = call(:get, "/presets/export?public_id=#{@preset.fetch("public_id")}&format=#{format}")
      assert_equal "200", code, exported.inspect
      parsed = Rho::AgentPresets::Portable.load(exported.fetch("content"), format: format)
      assert_equal "Helpful configuration", parsed.fetch(:name)
      assert_equal "Remember evidence.", parsed.fetch(:configuration).fetch("system_prompt")
      refute_includes exported.fetch("content"), @source.fetch("public_id")
      refute_includes exported.fetch("content"), @preset.fetch("public_id")
      refute_includes exported.fetch("content"), "welcome_message"
      refute_includes exported.fetch("content"), "audience"

      code, answer = call(:post, "/presets/import_document", content: exported.fetch("content"), format: format, name: "Copy #{format}")
      assert_equal "200", code, answer.inspect
      imported = answer.fetch("presets").find { |preset| preset.fetch("name") == "Copy #{format}" }
      refute_equal @preset.fetch("public_id"), imported.fetch("public_id")
      assert_equal @preset.fetch("configuration"), imported.fetch("configuration")
    end
    assert_equal before, @api.named_agent_declarations
    assert_equal settings, bot_settings
    assert_empty @api.memory_writes
  end

  def test_duplicate_changes_purpose_only_on_a_new_identity_and_shares_the_preset
    create_source
    code, copied = call(:post, "/agents/duplicate", source_name: "helper", name: "private-helper", audience: "owner")
    assert_equal "200", code, copied.inspect
    refute_equal @source.fetch("public_id"), copied.fetch("agent").fetch("public_id")
    assert_nil copied.dig("agent", "configuration", "memory_context_limit")
    _, listing = call(:get, "/agents")
    assert_equal({ "helper" => "external", "private-helper" => "owner" }, listing.fetch("bots").to_h { |row| row.values_at("name", "audience") })
    listing.fetch("bots").each do |row|
      assert_nil row.fetch("home_workspace_public_id")
      assert_equal @preset.fetch("public_id"), row.fetch("preset_public_id")
      assert_equal "Welcome to this Bot.", row.fetch("welcome_message")
    end
    assert_empty @api.memory_writes

    code, answer = call(:post, "/agents/duplicate", source_name: "helper", name: "helper", audience: "owner")
    assert_equal "409", code, answer.inspect
    assert_equal "bot_audience_fixed", answer.dig("error", "code")
  end

  def test_removed_names_cannot_restore_an_old_identity_through_duplicate
    create_source
    code, = call(:post, "/agents/duplicate", source_name: "helper", name: "reserved", audience: "owner")
    assert_equal "200", code
    code, = call(:post, "/agents/rm", name: "reserved")
    assert_equal "200", code
    code, answer = call(:post, "/agents/duplicate", source_name: "helper", name: "reserved", audience: "owner")
    assert_equal "409", code, answer.inspect
    assert_equal "name_taken", answer.dig("error", "code")
  end

  def test_unknown_document_fields_are_not_silently_dropped
    document = JSON.generate("name" => "helper", "description" => "Help", "unexpected" => true)
    code, answer = call(:post, "/presets/import_document", content: document, format: "json")
    assert_equal "400", code, answer.inspect
    assert_includes answer.dig("error", "message"), "unexpected"
    assert_empty @api.named_agent_declarations
  end

  def test_import_content_must_be_text_before_any_preset_is_written
    before = call(:get, "/presets").last.fetch("presets")
    [nil, 1, false, [], {}].each do |value|
      code, answer = call(:post, "/presets/import_document", content: value, format: "json")
      assert_equal "400", code, answer.inspect
      assert_equal "Preset document content must be a string", answer.dig("error", "message")
    end

    assert_equal before, call(:get, "/presets").last.fetch("presets")
    assert_empty @api.named_agent_declarations
  end

  def test_preset_documents_and_bot_duplicate_require_the_daemon_control_bearer
    [[:get, "/presets/export?public_id=unselected&format=json"],
     [:post, "/presets/import_document"], [:post, "/presets/import"], [:post, "/agents/duplicate"]].each do |method, path|
      response = request(@daemon, method, path, body: method == :post ? {} : nil)
      assert_equal "401", response.code, path
    end
    assert_empty @api.named_agent_declarations
  end

  def test_uploaded_preset_without_a_name_uses_its_filename
    content = JSON.generate("description" => "Checks the work", "model" => "test/text", "tools" => [])
    code, answer = call(:post, "/presets/import_document", content: content, format: "json", filename: "Checker.json")
    assert_equal "200", code, answer.inspect
    assert answer.fetch("presets").any? { |preset| preset.fetch("name") == "Checker" }
    code, answer = call(:post, "/presets/import_document", content: content, format: "json", filename: "Checker.json", name: "Chosen name")
    assert_equal "200", code, answer.inspect
    assert answer.fetch("presets").any? { |preset| preset.fetch("name") == "Chosen name" }
    assert_empty @api.named_agent_declarations
  end

  def test_portable_presets_preserve_all_tools_and_bot_duplicate_omits_only_code_mode
    preset = create_preset("All tools", tools: nil, runner_tool_names: nil)
    code, source = call(:put, "/agents", name: "all-tools", description: "Use the available tools", preset_public_id: preset.fetch("public_id"))
    assert_equal "200", code, source.inspect
    assert_equal BOT_RUNNER_TOOLS, source.dig("agent", "configuration", "runner_tool_names").sort

    %w[md json].each do |format|
      _, exported = call(:get, "/presets/export?public_id=#{preset.fetch("public_id")}&format=#{format}")
      code, answer = call(:post, "/presets/import_document", content: exported.fetch("content"), format: format, name: "All #{format}")
      assert_equal "200", code, answer.inspect
      imported = answer.fetch("presets").find { |row| row.fetch("name") == "All #{format}" }
      assert_nil imported.dig("configuration", "runner_tool_names")
      assert_nil imported.dig("configuration", "tools")
    end
    code, duplicate = call(:post, "/agents/duplicate", source_name: "all-tools", name: "all-copy")
    assert_equal "200", code, duplicate.inspect
    assert_equal BOT_RUNNER_TOOLS, duplicate.dig("agent", "configuration", "runner_tool_names").sort
  end

  def test_explicit_runner_selection_does_not_widen_kernel_tools_when_imported
    preset = create_preset("Runner only", tools: [], runner_tool_names: nil)
    _, exported = call(:get, "/presets/export?public_id=#{preset.fetch("public_id")}&format=json")
    code, answer = call(:post, "/presets/import_document", content: exported.fetch("content"), format: "json", name: "Runner copy")
    assert_equal "200", code, answer.inspect
    imported = answer.fetch("presets").find { |row| row.fetch("name") == "Runner copy" }
    code, selected = call(:put, "/agents", name: "runner-copy", description: "Only Runner tools", preset_public_id: imported.fetch("public_id"))
    assert_equal "200", code, selected.inspect
    assert_equal BOT_RUNNER_TOOLS, selected.dig("agent", "configuration", "runner_tool_names").sort
    assert_empty selected.dig("agent", "configuration", "kernel_tools")
  end

  def test_directory_import_keeps_first_name_and_never_creates_users
    root = @daemon.context.environment.root
    [[".agents/agents", "First instructions"], [".claude/agents", "Later instructions"]].each do |directory, prompt|
      folder = File.join(root, directory)
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, "reviewer.json"), JSON.generate("name" => "Reviewer", "description" => "Reviews changes",
        "model" => "test/text", "system_prompt" => prompt))
    end
    code, answer = call(:post, "/presets/import", names: ["Reviewer"])
    assert_equal "200", code, answer.inspect
    assert_equal ["Reviewer"], answer.fetch("imported").map { |row| row.fetch("name") }
    assert_equal "First instructions", answer.fetch("imported").first.dig("configuration", "system_prompt")
    assert_empty @api.named_agent_declarations
  end

  def test_invalid_files_are_reported_without_hiding_a_later_valid_same_name
    root = @daemon.context.environment.root
    first = File.join(root, ".agents/agents")
    second = File.join(root, ".claude/agents")
    FileUtils.mkdir_p([first, second])
    invalid = File.join(first, "reviewer.md")
    File.write(invalid, "---\nname: Reviewer\ndescription: []\n---\nInvalid body\n")
    File.write(File.join(first, "broken.md"), "# Missing frontmatter\n")
    File.write(File.join(second, "reviewer.md"), "---\nname: Reviewer\ndescription: Reviews changes\n---\nValid body\n")

    code, answer = call(:post, "/presets/import")

    assert_equal "200", code, answer.inspect
    assert_equal ["Reviewer"], answer.fetch("imported").map { |row| row.fetch("name") }
    assert_equal "Valid body\n", answer.fetch("imported").first.dig("configuration", "system_prompt")
    assert_equal %w[broken.md reviewer.md], answer.fetch("skipped").map { |row| File.basename(row.fetch("path")) }
    assert_includes answer.fetch("skipped").last.fetch("reason"), "/description"
    assert_empty @api.named_agent_declarations
  end

  def test_directory_import_reads_one_level_and_only_supported_files
    root = @daemon.context.environment.root
    [[".agents/agents/nested", "deep.md"], [".agents/agents", "notes.txt"],
     ["agents", "loose.md"], [".agents/skills", "skill.md"]].each do |directory, filename|
      folder = File.join(root, directory)
      FileUtils.mkdir_p(folder)
      File.write(File.join(folder, filename), "---\ndescription: Reviews changes\n---\nBody\n")
    end

    code, answer = call(:post, "/presets/import")

    assert_equal "200", code, answer.inspect
    assert_empty answer.fetch("imported")
    assert_empty answer.fetch("skipped")
  end

  def test_a_missing_root_or_a_root_without_import_directories_reads_nothing
    [@daemon.context.environment.root, nil].each do |root|
      @daemon.context.define_singleton_method(:environment) { Rho::EnvironmentStore::Selection.new(root: root, source: "test") }
      code, answer = call(:post, "/presets/import", names: ["Missing"])
      assert_equal "200", code, answer.inspect
      assert_empty answer.fetch("imported")
      assert_empty answer.fetch("skipped")
      assert_equal ["Missing"], answer.fetch("missing")
    end
    assert_empty @api.named_agent_declarations
  end

  private

    def create_source
      @preset = create_preset("Helpful configuration", tools: [], system_prompt: "Remember evidence.")
      code, answer = call(:put, "/agents", name: "helper", display_name: "Helpful Bot", description: "Helps people",
        preset_public_id: @preset.fetch("public_id"), audience: "external", welcome_message: "Welcome to this Bot.")
      assert_equal "200", code, answer.inspect
      @source = answer.fetch("agent")
    end

    def create_preset(name, **configuration)
      code, answer = call(:post, "/presets", name: name, description: "Reusable configuration",
        configuration: { model: "test/text" }.merge(configuration))
      assert_equal "200", code, answer.inspect
      answer.fetch("presets").find { |preset| preset.fetch("name") == name }
    end

    def bot_settings
      @api.store_entries_of("profile").select { |entry| entry.fetch("namespace") == "rho.bots" }
    end

    def call(method, path, **body)
      response = request(@daemon, method, path, token: bearer(@daemon), body: body.empty? ? nil : body)
      [response.code, JSON.parse(response.body)]
    end
end
