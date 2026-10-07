require "test_helper"
require "tmpdir"

# THE OPERATOR'S SETTINGS. Every knob here took its own default because
# nothing could state it, which is workable while rho runs on the laptop
# in front of you and is not once it runs somewhere you reach from
# elsewhere: a flag is not a deployment.
class ConfigTest < Minitest::Test
  def with_settings(hash)
    Dir.mktmpdir("rho-config") do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, JSON.generate(hash))
      yield path
    end
  end

  def test_code_mode_has_an_on_default_and_validates_interactive_changes
    defaults = Rho::Config.from_hash({})
    assert_equal "on", defaults.plugin_configuration("rho.codemode").fetch("default")
    assert Rho::CodeMode.enabled?(defaults)
    config = Rho::Config.from_hash({ "plugins" => { "rho.codemode" => {
      "configuration_version" => 1, "configuration" => { "default" => "off" } } } })
    refute Rho::CodeMode.enabled?(config)
    assert Rho::CodeMode.enabled?(config, true)
    disabled = config.with({ "plugins" => { "rho.codemode" => { "enabled" => false, "configuration_version" => 1,
      "configuration" => { "default" => "on" } } } })
    refute Rho::CodeMode.enabled?(disabled, true), "a turn override cannot enable an inactive plugin"
    schema = defaults.catalog.fetch("rho.codemode").schema
    %w[auto false disabled].each do |value|
      assert_raises(Rho::ConfigurationError) do
        schema.edit({}, operations: [{ "op" => "set", "path" => ["default"], "value" => value }])
      end
    end
  end

  def test_browser_idle_settings_use_the_current_schema_fallback
    ["soon", 0, -5].each do |value|
      config = Rho::Config.from_hash({ "plugins" => { "rho.browser" => {
        "configuration_version" => 1, "configuration" => { "idle_seconds" => value } } } })
      assert_equal 600, config.plugin_configuration("rho.browser").fetch("idle_seconds")
      assert_raises(Rho::ConfigurationError) do
        config.catalog.fetch("rho.browser").schema.edit({}, operations: [{ "op" => "set", "path" => ["idle_seconds"], "value" => value }])
      end
    end
  end

  def test_an_absent_file_is_the_ordinary_case
    assert_equal 120, Rho::Config.load(nil).plugin_configuration("rho.coding").fetch("bash_timeout_seconds")
    assert_nil Rho::Config.load("/nowhere/settings.json").tools_root
  end

  def test_lifecycle_hooks_are_carried_to_the_profile_declaration
    hooks = {
      "turn_start" => { "tool" => "verify", "timeout_ms" => 30_000 },
      "pre_compact" => { "tool" => "verify", "timeout_ms" => 30_000 },
      "post_compact" => { "tool" => "verify", "timeout_ms" => 30_000 },
      "stop" => { "tool" => "verify", "timeout_ms" => 30_000, "max_continuations" => 2 },
    }
    config = Rho::Config.from_hash({ "plugins" => { "rho.lifecycle_hooks" => {
      "configuration_version" => 1, "configuration" => hooks } } })
    registry = Rho::Extensions.load(host: RhoTest.host).registry
    declaration = Rho::RunDeclaration.declaration(registry: registry,
      lifecycle_hooks: config.plugin_configuration("rho.lifecycle_hooks"))

    assert_equal hooks, declaration.fetch(:lifecycle_hooks)
    schema = config.catalog.fetch("rho.lifecycle_hooks").schema
    invalid = hooks.merge("stop" => { "tool" => "verify", "timeout_ms" => 300_001 })
    assert_equal hooks.except("stop"), schema.normalize(invalid).value
    assert_raises(Rho::ConfigurationError) do
      schema.edit(hooks, operations: [{ "op" => "set", "path" => ["stop", "max_continuations"], "value" => 21 }])
    end
    assert_equal({}, Rho::Config.load(nil).plugin_configuration("rho.lifecycle_hooks"))
  end

  # Environment values seed a deployment; saved choices must still win
  # after a restart. An explicit launch flag remains the final override.
  def test_saved_settings_override_the_environment_and_flags_override_both
    with_settings("bind" => "127.0.0.1", "plugins" => { "rho.coding" => { "configuration_version" => 1,
      "configuration" => { "bash_timeout_seconds" => 60 } } }) do |path|
      env = { "RHO_BIND" => "0.0.0.0", "RHO_DEFAULT_MODEL" => "dev/environment" }
      config = Rho::Config.load(path, env: env)

      assert_equal "127.0.0.1", config.bind
      assert_equal 60, config.plugin_configuration("rho.coding").fetch("bash_timeout_seconds")
      assert_equal "dev/environment", config.default_model, "an unsaved key takes the deployment value"
      assert_equal "192.168.1.10", Rho::Config.load(path, env: env, flags: { bind: "192.168.1.10" }).bind
      assert_equal "127.0.0.1", Rho::Config.load(path, env: env, flags: { bind: nil }).bind,
        "a nil launch flag states nothing"
    end
  end

  def test_a_saved_null_clears_an_environment_value_after_reload
    env = { "RHO_DEFAULT_MODEL" => "dev/environment", "RHO_TOOLS_ROOT" => "/from/env" }
    with_settings("default_model" => nil, "tools_root" => nil) do |path|
      assert_equal "dev/environment", Rho::Config.load(nil, env: env).default_model
      assert_equal "/from/env", Rho::Config.load(nil, env: env).tools_root
      reloaded = Rho::Config.load(path, env: env)
      assert_nil reloaded.default_model
      assert_nil reloaded.tools_root
      assert_equal "dev/flag", Rho::Config.load(path, env: env, flags: { default_model: "dev/flag" }).default_model
    end
  end

  # An EMPTY variable is UNSET, not an empty value: `RHO_BIND=` in a unit
  # file is how an operator disables an override, and reading it as ""
  # would bind nowhere.
  def test_an_empty_variable_is_unset_rather_than_empty
    with_settings("bind" => "192.168.1.10") do |path|
      assert_equal "192.168.1.10", Rho::Config.load(path, env: { "RHO_BIND" => "" }).bind
    end
  end

  def test_unknown_keys_are_ignored_rather_than_refused
    with_settings("bind" => "0.0.0.0", "colour" => "blue") do |path|
      assert_equal "0.0.0.0", Rho::Config.load(path).bind
    end
  end

  def test_malformed_settings_say_which_file_and_why
    Dir.mktmpdir("rho-config") do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, "{not json")
      error = assert_raises(Rho::ConfigurationError) { Rho::Config.load(path) }
      assert_includes error.message, path

      File.write(path, "[]")
      assert_raises(Rho::ConfigurationError) { Rho::Config.load(path) }
    end
  end

  # WHERE A BARE RELATIVE PATH LANDS, and the one environment fact this
  # daemon holds. Until it had a writer, every relative path a model wrote
  # resolved under a scratch directory rather than under the operator's
  # code.
  def test_tools_root_is_nil_until_someone_states_it
    assert_nil Rho::Config.from_hash({}).tools_root
  end

  def test_tools_root_expands_the_tilde_an_operator_actually_writes
    config = Rho::Config.from_hash({ "tools_root" => "~/src" })

    assert_equal File.expand_path("~/src"), config.tools_root
    refute_includes config.tools_root, "~",
      "a tool resolving against a literal ~/src would create a directory called ~"
  end

  def test_tools_root_takes_the_environment_until_the_file_names_one
    assert_equal "/from/env", Rho::Config.load(nil, env: { "RHO_TOOLS_ROOT" => "/from/env" }).tools_root
    with_settings("tools_root" => "/from/file") do |path|
      config = Rho::Config.load(path, env: { "RHO_TOOLS_ROOT" => "/from/env" })
      assert_equal "/from/file", config.tools_root
    end
  end

  def test_browser_urls_normalize_the_base_and_refuse_credential_or_callback_material
    %w[public_url nexus_public_url].each do |key|
      config = Rho::Config.from_hash({ key => "http://10.0.0.115:7777/" })
      assert_equal "http://10.0.0.115:7777", config.public_send(key)
      ["ftp://example.test", "http://user:secret@example.test", "https://example.test?code=secret",
        "https://example.test#secret", "not a URL"].each do |value|
        assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash({ key => value }) }
      end
    end
  end

  def test_bash_timeouts_fall_back_on_file_load_and_invalid_interactive_edits_are_refused
    schema = Rho::Config.from_hash({}).catalog.fetch("rho.coding").schema
    [0, 541, "soon"].each do |value|
      config = Rho::Config.from_hash({ "plugins" => { "rho.coding" => { "configuration_version" => 1,
        "configuration" => { "bash_timeout_seconds" => value } } } })
      assert_equal 120, config.plugin_configuration("rho.coding").fetch("bash_timeout_seconds")
      assert_equal ["bash_timeout_seconds"], config.plugin_resolution("rho.coding").diagnostics.first.path
      assert_raises(Rho::ConfigurationError) do
        schema.edit({}, operations: [{ "op" => "set", "path" => ["bash_timeout_seconds"], "value" => value }])
      end
    end
    config = Rho::Config.from_hash({ "plugins" => { "rho.coding" => { "configuration_version" => 1,
      "configuration" => { "bash_timeout_seconds" => 540 } } } })
    assert_equal 540, config.plugin_configuration("rho.coding").fetch("bash_timeout_seconds")
  end

  def test_api_only_reads_the_spellings_an_operator_writes
    %w[1 true yes on TRUE].each do |value|
      assert Rho::Config.from_hash({ "api_only" => value }).api_only, value
    end
    %w[0 false no off].each do |value|
      refute Rho::Config.from_hash({ "api_only" => value }).api_only, value
    end
    assert Rho::Config.from_hash({ "api_only" => true }).api_only
  end

  def test_kernel_tool_lists_must_be_arrays_and_drop_blanks
    config = Rho::Config.from_hash({ "kernel_tools" => ["nexus.memory.read", "", nil] })
    assert_equal ["nexus.memory.read"], config.kernel_tools

    assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash({ "kernel_tools" => "nexus.memory.read" }) }
  end

  # THE MODEL `rho do` OPENS ON when `--model` names none:
  # nil until stated, from the file, or from the environment — the daemon
  # holds it, because the CLI cannot read the daemon's settings.
  def test_default_model_is_nil_until_someone_states_it
    assert_nil Rho::Config.from_hash({}).default_model
    assert_nil Rho::Config.from_hash({ "default_model" => "" }).default_model
    assert_equal "openrouter/x", Rho::Config.from_hash({ "default_model" => "openrouter/x" }).default_model
  end

  def test_default_model_takes_the_environment_then_the_saved_choice
    assert_equal "dev/environment", Rho::Config.load(nil, env: { "RHO_DEFAULT_MODEL" => "dev/environment" }).default_model
    with_settings("default_model" => "dev/mock-text") do |path|
      assert_equal "dev/mock-text", Rho::Config.load(path).default_model
      assert_equal "dev/mock-text", Rho::Config.load(path, env: { "RHO_DEFAULT_MODEL" => "dev/environment" }).default_model
    end
  end

  # THE FALLBACK ON REFUSAL OR OVERLOAD: the model the kernel re-runs a step rho answers
  # on once when a provider's classifier declined it — nil until stated,
  # from the file or `RHO_FALLBACK_MODEL`; refused under mode runner, which
  # declares no profile, so a setting that would lie is caught where it is
  # read. It may equal `default_model` (a run on `--model` falls back home).
  def test_fallback_model_is_nil_until_stated_takes_saved_choices_over_the_environment_and_refuses_a_runner
    assert_nil Rho::Config.from_hash({}).fallback_model
    assert_nil Rho::Config.from_hash({ "fallback_model" => "" }).fallback_model
    assert_equal "dev/fallback", Rho::Config.from_hash({ "fallback_model" => "dev/fallback" }).fallback_model
    same = Rho::Config.from_hash({ "default_model" => "dev/mock-text", "fallback_model" => "dev/mock-text" })
    assert_equal "dev/mock-text", same.fallback_model, "equal to default_model is a valid declaration"
    assert_equal "dev/environment", Rho::Config.load(nil, env: { "RHO_FALLBACK_MODEL" => "dev/environment" }).fallback_model
    with_settings("fallback_model" => "dev/mock-unmetered") do |path|
      assert_equal "dev/mock-unmetered", Rho::Config.load(path).fallback_model
      assert_equal "dev/mock-unmetered", Rho::Config.load(path, env: { "RHO_FALLBACK_MODEL" => "dev/environment" }).fallback_model
    end
    assert_equal "RHO_FALLBACK_MODEL", Rho::Config::ENV_KEYS.fetch("fallback_model")
    error = assert_raises(Rho::ConfigurationError) do
      Rho::Config.from_hash({ "fallback_model" => "dev/mock-text", "mode" => "runner" })
    end
    assert_match(/fallback_model needs mode full or agent/, error.message)
  end

  # Native plugin configuration remains saved when the current mode cannot
  # serve its tools. The mode gates activation, not the user's saved intent.
  def test_image_model_is_unset_until_stated_and_runner_mode_keeps_it_inactive
    assert_nil Rho::Config.from_hash({}).plugin_configuration("rho.images")["model"]
    document = { "plugins" => { "rho.images" => { "configuration_version" => 1,
      "configuration" => { "model" => "dev/mock-image" } } } }
    config = Rho::Config.from_hash(document)
    assert_equal "dev/mock-image", config.plugin_configuration("rho.images").fetch("model")
    with_settings(document) do |path|
      assert_equal "dev/mock-image", Rho::Config.load(path).plugin_configuration("rho.images").fetch("model")
    end
    refute Rho::Config::ENV_KEYS.key?("image_model"), "plugin configuration has one saved owner"
    runner = Rho::Config.from_hash(document.merge("mode" => "runner"))
    refute runner.plugin_enabled?("rho.images")
    assert_equal "dev/mock-image", runner.plugin_configuration("rho.images").fetch("model")
  end

  def test_default_kernel_tools_include_runner_discovery
    assert_equal %w[nexus.graph.delegate_task nexus.human.ask
                    nexus.memory.read nexus.memory.write nexus.memory.edit
                    nexus.memory.ls nexus.memory.grep nexus.memory.delete
                    nexus.conversation.spawn nexus.conversation.send
                    nexus.conversation.status nexus.conversation.cancel
                    nexus.conversation.search nexus.conversation.read
                    nexus.skill.load nexus.tools.search nexus.tools.call
                    nexus.runners.list],
      Rho::Config.from_hash({}).kernel_tools
  end

  # Defaults still match the store. Invalid file fields fall back independently;
  # an interactive invalid edit is rejected before it can replace saved intent.
  def test_checkpoints_defaults_match_the_store_and_validation_preserves_valid_siblings
    store = Rho::Runner::Checkpoints::Store
    base = Rho::Config.from_hash({})
    defaults = base.plugin_configuration("rho.checkpoints")
    assert_equal({ "retention_days" => store::DEFAULT_RETENTION_DAYS,
                   "max_file_bytes" => store::DEFAULT_MAX_FILE_BYTES, "max_tree_bytes" => store::DEFAULT_MAX_TREE_BYTES,
                   "capture_timeout_seconds" => store::DEFAULT_CAPTURE_TIMEOUT_SECONDS }, defaults)
    assert base.plugin_enabled?("rho.checkpoints")
    assert_predicate defaults, :frozen?
    refute Rho::Config::ENV_KEYS.key?("checkpoints"), "a table is not an environment variable"

    config = Rho::Config.from_hash({ "plugins" => { "rho.checkpoints" => { "enabled" => false, "configuration_version" => 1,
      "configuration" => { "retention_days" => 3, "max_tree_bytes" => 1024 } } } })
    refute config.plugin_enabled?("rho.checkpoints")
    assert_equal 3, config.plugin_configuration("rho.checkpoints").fetch("retention_days")
    assert_equal 1024, config.plugin_configuration("rho.checkpoints").fetch("max_tree_bytes")
    assert_equal store::DEFAULT_MAX_FILE_BYTES, config.plugin_configuration("rho.checkpoints").fetch("max_file_bytes")
    with_settings("plugins" => { "rho.checkpoints" => { "configuration_version" => 1,
      "configuration" => { "capture_timeout_seconds" => 5, "retention_days" => 0, "max_files" => 1 } } }) do |path|
      saved = Rho::Config.load(path)
      assert_equal 5, saved.plugin_configuration("rho.checkpoints").fetch("capture_timeout_seconds")
      assert_equal store::DEFAULT_RETENTION_DAYS, saved.plugin_configuration("rho.checkpoints").fetch("retention_days")
      assert_equal [%w[max_files], %w[retention_days]], saved.plugin_resolution("rho.checkpoints").diagnostics.map(&:path).sort
    end
    schema = base.catalog.fetch("rho.checkpoints").schema
    [{ "max_files" => 1 }, { "retention_days" => 0 }, { "retention_days" => "3" }].each do |fields|
      key, value = fields.first
      assert_raises(Rho::ConfigurationError) do
        schema.edit({}, operations: [{ "op" => "set", "path" => [key], "value" => value }])
      end
    end
    malformed = schema.normalize("on")
    assert_equal defaults, malformed.value
    assert_equal "type", malformed.diagnostics.first.reason
  end

  # Each optional package publishes the schema used for current file reads and
  # interactive edits. Invalid rows do not discard valid sibling configuration.
  def test_mcp_server_configuration_uses_its_schema_and_retains_valid_siblings
    base = Rho::Config.from_hash({})
    refute base.plugin_configuration("rho.mcp").dig("servers", "context7", "enabled")
    row = { "transport" => "stdio", "command" => "ruby", "tools" => ["*"], "anything" => [1] }
    document = { "plugins" => { "rho.mcp" => { "configuration_version" => 1,
      "configuration" => { "servers" => { "fx" => row, "bad" => "ruby" } } } } }
    config = Rho::Config.from_hash(document)
    normalized = config.plugin_configuration("rho.mcp").fetch("servers").fetch("fx")
    assert_equal row.except("anything"), normalized.slice(*row.keys)
    assert_predicate normalized, :frozen?
    assert_equal [%w[servers bad], %w[servers fx anything]], config.plugin_resolution("rho.mcp").diagnostics.map(&:path).sort
    with_settings(document) do |path|
      assert_equal normalized, Rho::Config.load(path).plugin_configuration("rho.mcp").fetch("servers").fetch("fx")
    end
    assert_raises(Rho::ConfigurationError) do
      base.catalog.fetch("rho.mcp").schema.edit({}, operations: [{ "op" => "set", "path" => ["servers"], "value" => ["fx"] }])
    end
  end

  def test_acp_agent_configuration_keeps_valid_fields_and_rejects_invalid_interactive_rows
    base = Rho::Config.from_hash({})
    assert_equal({}, base.plugin_configuration("rho.acp-client").fetch("agents"))
    row = { "command" => "opencode", "args" => ["acp"], "env" => { "OPENROUTER_API_KEY" => "${OPENROUTER_API_KEY}" },
      "description" => "OpenCode on OpenRouter", "permissions" => "allow", "timeout_ms" => 600_000,
      "auth_method" => nil, "model" => nil, "enabled" => true, "anything" => [1] }
    document = { "plugins" => { "rho.acp-client" => { "configuration_version" => 1,
      "configuration" => { "agents" => { "opencode" => row } } } } }
    config = Rho::Config.from_hash(document)
    normalized = config.plugin_configuration("rho.acp-client").fetch("agents").fetch("opencode")
    assert_equal row.except("anything"), normalized
    assert_predicate normalized, :frozen?
    assert_equal %w[agents opencode anything], config.plugin_resolution("rho.acp-client").diagnostics.first.path
    with_settings(document) do |path|
      assert_equal normalized, Rho::Config.load(path).plugin_configuration("rho.acp-client").fetch("agents").fetch("opencode")
    end
    refute Rho::Config::ENV_KEYS.key?("acp_agents"), "a table is not an environment variable"
    [["opencode"], { "opencode" => "opencode acp" }].each do |value|
      assert_raises(Rho::ConfigurationError) do
        base.catalog.fetch("rho.acp-client").schema.edit({}, operations: [{ "op" => "set", "path" => ["agents"], "value" => value }])
      end
    end
  end

  def test_t3_keeps_its_optional_extension_configuration_local_and_validates_its_schema
    base = Rho::Config.from_hash({})
    refute base.plugin_enabled?("rho.t3")
    value = { "server" => "host", "url" => "http://localhost:3773", "project_id" => "project", "token_env" => "RHO_T3_TOKEN",
      "default_agent" => "Codex", "workspace" => { "type" => "root" } }
    document = { "plugins" => { "rho.t3" => { "enabled" => true, "configuration_version" => 1, "configuration" => value } } }
    config = Rho::Config.from_hash(document)
    assert_equal value, config.plugin_configuration("rho.t3").slice(*value.keys)
    assert_predicate config.plugin_configuration("rho.t3"), :frozen?
    with_settings(document) { |path| assert_equal config.plugin_configuration("rho.t3"), Rho::Config.load(path).plugin_configuration("rho.t3") }
    changed = config.with({ "plugins" => { "rho.t3" => { "enabled" => true, "configuration_version" => 1,
      "configuration" => value.merge("default_agent" => "Claude Code") } } })
    assert_equal "Claude Code", changed.plugin_configuration("rho.t3").fetch("default_agent")
    assert_equal "Codex", config.plugin_configuration("rho.t3").fetch("default_agent")
    malformed = base.catalog.fetch("rho.t3").schema.normalize("invalid")
    assert_equal base.plugin_configuration("rho.t3"), malformed.value
    assert_equal "type", malformed.diagnostics.first.reason
  end

  def test_web_configuration_uses_its_own_schema_without_losing_valid_fields
    base = Rho::Config.from_hash({})
    assert_equal({ "allow_private_network" => false }, base.plugin_configuration("rho.web_tools"))
    document = { "plugins" => { "rho.web_tools" => { "configuration_version" => 1,
      "configuration" => { "allow_private_network" => true, "anything" => "yes" } } } }
    config = Rho::Config.from_hash(document)
    assert_equal({ "allow_private_network" => true }, config.plugin_configuration("rho.web_tools"))
    assert_predicate config.plugin_configuration("rho.web_tools"), :frozen?
    assert_equal ["anything"], config.plugin_resolution("rho.web_tools").diagnostics.first.path
    with_settings(document) do |path|
      assert_equal config.plugin_configuration("rho.web_tools"), Rho::Config.load(path).plugin_configuration("rho.web_tools")
    end
    [true, ["allow_private_network"]].each do |value|
      answer = base.catalog.fetch("rho.web_tools").schema.normalize(value)
      assert_equal base.plugin_configuration("rho.web_tools"), answer.value
      assert_equal "type", answer.diagnostics.first.reason
    end
    refute Rho::Config::ENV_KEYS.key?("web"), "a table is not an environment variable"
  end

  # THE EXECUTOR SOCKET KNOB: on by default; off is the
  # sweep-only mode E4 proves the product works in. A test-only knob in
  # the sense that no operator wants it — it exists so the negative can
  # be driven through the same file and environment as everything else.
  def test_the_executor_socket_is_on_unless_switched_off
    assert Rho::Config.from_hash({}).executor_socket
    refute Rho::Config.from_hash({ "executor_socket" => false }).executor_socket
    refute Rho::Config.from_hash({ "executor_socket" => "0" }).executor_socket
    assert Rho::Config.from_hash({ "executor_socket" => "on" }).executor_socket
    refute Rho::Config.load(nil, env: { "RHO_EXECUTOR_SOCKET" => "0" }).executor_socket
    with_settings("executor_socket" => true) do |path|
      assert Rho::Config.load(path).executor_socket
      assert Rho::Config.load(path, env: { "RHO_EXECUTOR_SOCKET" => "0" }).executor_socket
      assert Rho::Config.load(path, env: { "RHO_EXECUTOR_SOCKET" => "" }).executor_socket, "empty is unset"
    end
    with_settings("executor_socket" => false) do |path|
      refute Rho::Config.load(path, env: { "RHO_EXECUTOR_SOCKET" => "1" }).executor_socket,
        "a saved false overrides an environment switch"
    end
  end

  # THE COMPACTION KNOB: the kernel's summarizer is the
  # shipped default; `delegate` declares rho's own `summarize_history` as
  # the profile's policy and needs a model to place its InferenceRequest on — the
  # row names none.
  def test_compaction_is_the_kernels_by_default_and_the_delegate_reads_its_model
    config = Rho::Config.from_hash({})
    assert_equal({ "mode" => "kernel" }, Rho::Extensions::Compaction.policy(config, active: true))
    assert_nil config.plugin_configuration("rho.compaction")["model"]

    delegate = Rho::Config.from_hash({ "plugins" => { "rho.compaction" => { "configuration_version" => 1,
      "configuration" => { "mode" => "delegate", "model" => "dev/summary" } } } })
    assert_equal({ "mode" => "delegate", "tool_name" => "summarize_history" }, Rho::Extensions::Compaction.policy(delegate, active: true))
    assert_equal "dev/summary", delegate.plugin_configuration("rho.compaction").fetch("model")
    assert_equal({ "mode" => "off" }, Rho::Extensions::Compaction.policy(delegate, active: false))

    on_default = Rho::Config.from_hash({ "plugins" => { "rho.compaction" => { "configuration_version" => 1,
      "configuration" => { "mode" => "delegate" } } }, "default_model" => "dev/mock-text" })
    assert_equal "delegate", Rho::Extensions::Compaction.policy(on_default, active: true).fetch("mode")
    assert_nil on_default.plugin_configuration("rho.compaction")["model"], "the tool falls to default_model"
  end

  # A kernel policy carries an explicitly selected summary model; a delegate
  # chooses it in the tool. Unknown interactive fields remain rejected by name.
  def test_compaction_declares_the_kernel_model_and_refuses_unknown_interactive_fields
    base = Rho::Config.from_hash({ "default_model" => "dev/mock-text" })
    assert_equal({ "mode" => "kernel" }, Rho::Extensions::Compaction.policy(base, active: true),
      "without an explicit summary model, the kernel inherits the current turn's model")
    config = Rho::Config.from_hash({ "plugins" => { "rho.compaction" => { "configuration_version" => 1,
      "configuration" => { "mode" => "kernel", "model" => "dev/summary" } } } })
    assert_equal({ "mode" => "kernel", "model" => "dev/summary" }, Rho::Extensions::Compaction.policy(config, active: true))
    %w[summarize_after_prunes prunes].each do |key|
      error = assert_raises(Rho::ConfigurationError) do
        base.catalog.fetch("rho.compaction").schema.edit({}, operations: [{ "op" => "set", "path" => [key], "value" => 2 }])
      end
      assert_includes error.message, key
    end
  end

  def test_compaction_falls_back_for_invalid_fields_and_keeps_an_incomplete_delegate_unready
    base = Rho::Config.from_hash({})
    schema = base.catalog.fetch("rho.compaction").schema
    [{ "mode" => "prune" }, "delegate"].each do |value|
      answer = schema.normalize(value)
      assert_equal({ "mode" => "kernel" }, answer.value)
      refute_empty answer.diagnostics
    end
    assert_raises(Rho::ConfigurationError) do
      schema.edit({}, operations: [{ "op" => "set", "path" => ["mode"], "value" => "prune" }])
    end
    config = Rho::Config.from_hash({ "plugins" => { "rho.compaction" => { "configuration_version" => 1,
      "configuration" => { "mode" => "delegate" } } } })
    host = RhoTest.host.with(config: config)
    api = Rho::Extensions::Api.new(host: host, extension_name: "rho.compaction", source: "<built-in>")
    Rho::Extensions::Compaction.register(api)
    assert_empty api.tools
    refute api.readiness.fetch(:ready)
    assert_includes api.readiness.fetch(:issues), "Select a compaction model or a default model"
  end

  def test_the_file_can_override_the_compaction_mode_or_supply_only_its_model
    with_settings("plugins" => { "rho.compaction" => { "configuration_version" => 1,
      "configuration" => { "mode" => "kernel", "model" => "dev/summary" } } }) do |path|
      config = Rho::Config.load(path)
      assert_equal "kernel", Rho::Extensions::Compaction.policy(config, active: true).fetch("mode")
      assert_equal "dev/summary", config.plugin_configuration("rho.compaction").fetch("model")
    end
    with_settings("plugins" => { "rho.compaction" => { "configuration_version" => 1,
      "configuration" => { "model" => "dev/summary" } } }) do |path|
      config = Rho::Config.load(path)
      assert_equal "kernel", Rho::Extensions::Compaction.policy(config, active: true).fetch("mode")
      assert_equal "dev/summary", config.plugin_configuration("rho.compaction").fetch("model")
    end
  end

  def test_a_config_is_frozen_so_nothing_edits_the_operators_intent
    assert_predicate Rho::Config.from_hash({}), :frozen?
  end

  def test_the_current_handle_publishes_new_values_without_changing_existing_snapshots
    original = Rho::Config.from_hash({ "default_model" => "dev/old", "plugins" => {
      "rho.coding" => { "configuration_version" => 1, "configuration" => { "bash_timeout_seconds" => 60 } },
      "rho.compaction" => { "configuration_version" => 1, "configuration" => { "mode" => "kernel", "model" => "dev/old-summary" } },
      "rho.web_tools" => { "configuration_version" => 1, "configuration" => { "allow_private_network" => false } } } })
    current = Rho::Config::Current.new(original)
    captured = current.to_h
    read = -> { [current.default_model, current.plugin_configuration("rho.coding").fetch("bash_timeout_seconds"),
      Rho::Extensions::Compaction.policy(current, active: true), current.plugin_configuration("rho.web_tools")] }
    replacement = current.with({ "default_model" => "dev/new", "plugins" => {
      "rho.coding" => { "configuration_version" => 1, "configuration" => { "bash_timeout_seconds" => 7 } },
      "rho.compaction" => { "configuration_version" => 1, "configuration" => { "mode" => "delegate", "model" => "dev/new-summary" } },
      "rho.web_tools" => { "configuration_version" => 1, "configuration" => { "allow_private_network" => true } } } })

    assert_predicate replacement, :frozen?
    assert_equal "dev/old", current.default_model, "validating a candidate does not publish it"
    assert_same current, current.apply(replacement)
    assert_equal ["dev/new", 7, { "mode" => "delegate", "tool_name" => "summarize_history" },
                  { "allow_private_network" => true }], read.call
    assert_equal "dev/new-summary", current.plugin_configuration("rho.compaction").fetch("model")
    assert_equal replacement.to_h, current.to_h
    assert_equal "dev/old", original.default_model
    assert_equal 60, original.plugin_configuration("rho.coding").fetch("bash_timeout_seconds")
    assert_equal({ "mode" => "kernel", "model" => "dev/old-summary" }, Rho::Extensions::Compaction.policy(original, active: true))
    assert_equal original.to_h, captured, "previously captured settings retain their values"
    assert_predicate original, :frozen?
    assert_raises(Rho::ConfigurationError) do
      current.catalog.fetch("rho.coding").schema.edit({}, operations: [{ "op" => "set", "path" => ["bash_timeout_seconds"], "value" => 0 }])
    end
    assert_equal "dev/new", current.default_model
    assert_equal 7, current.plugin_configuration("rho.coding").fetch("bash_timeout_seconds")
  end
end

# ---- mode: a boot fact like `bind` ----
class ConfigModeTest < Minitest::Test
  def with_settings(hash)
    Dir.mktmpdir("rho-config") do |dir|
      path = File.join(dir, "settings.json")
      File.write(path, JSON.generate(hash))
      yield path
    end
  end

  def test_the_mode_defaults_to_full_and_is_one_of_three_words
    assert_equal "full", Rho::Config.load(nil).mode
    assert_equal %w[full agent runner], Rho::Config::MODES
    assert_equal "runner", Rho::Config.from_hash({ "mode" => "Runner" }).mode
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash({ "mode" => "server" }) }
    assert_match(/mode must be one of full, agent, runner/, error.message)
  end

  def test_mode_takes_the_environment_then_the_file_then_a_flag
    assert_equal "runner", Rho::Config.load(nil, env: { "RHO_MODE" => "runner" }).mode
    with_settings("mode" => "agent") do |path|
      assert_equal "agent", Rho::Config.load(path).mode
      assert_equal "agent", Rho::Config.load(path, env: { "RHO_MODE" => "runner" }).mode
      assert_equal "full", Rho::Config.load(path, env: { "RHO_MODE" => "runner" }, flags: { "mode" => "full" }).mode
      assert_equal "agent", Rho::Config.load(path, env: { "RHO_MODE" => "runner" }, flags: { "mode" => nil }).mode,
        "a nil flag states nothing"
    end
  end

  def test_a_runner_declares_no_profile_so_delegate_compaction_stays_inactive
    plugins = { "rho.compaction" => { "enabled" => true, "configuration_version" => 1,
      "configuration" => { "mode" => "delegate", "model" => "dev/summary" } } }
    runner = Rho::Config.from_hash({ "mode" => "runner", "plugins" => plugins })
    refute runner.plugin_enabled?("rho.compaction")
    assert_equal "delegate", runner.plugin_configuration("rho.compaction").fetch("mode")
    agent = Rho::Config.from_hash({ "mode" => "agent", "plugins" => plugins })
    assert agent.plugin_enabled?("rho.compaction")
    assert_equal "delegate", agent.plugin_configuration("rho.compaction").fetch("mode")
  end

  # The runner new hosts start on when `rho do --runner` names none: a
  # settings key with no environment spelling, nil by default.
  def test_the_runner_setting_names_a_runner_kind_executor_or_nothing
    assert_nil Rho::Config.load(nil).runner
    assert_equal "0199-r", Rho::Config.from_hash({ "runner" => "0199-r" }).runner
    assert_nil Rho::Config.from_hash({ "runner" => "" }).runner
    refute Rho::Config::ENV_KEYS.key?("runner")
  end

  # THE ROOM KNOB: `workspace` names a
  # steward-created room the daemon adopts instead of minting its own
  # dedicated workspace — `RHO_WORKSPACE`, the file, then `rho server
  # --workspace` (the same ladder as `mode`); nil is the dedicated path.
  # A runner adopts no workspace, so the key is refused there by name.
  def test_the_workspace_setting_names_a_room_and_takes_the_environment_the_file_then_the_flag
    assert_nil Rho::Config.load(nil).workspace
    assert_nil Rho::Config.from_hash({ "workspace" => "" }).workspace
    assert_equal "RHO_WORKSPACE", Rho::Config::ENV_KEYS.fetch("workspace")
    assert_equal "0199-room-env", Rho::Config.load(nil, env: { "RHO_WORKSPACE" => "0199-room-env" }).workspace
    with_settings("workspace" => "0199-room-file") do |path|
      assert_equal "0199-room-file", Rho::Config.load(path).workspace
      assert_equal "0199-room-file", Rho::Config.load(path, env: { "RHO_WORKSPACE" => "0199-room-env" }).workspace
      assert_equal "0199-room-flag",
        Rho::Config.load(path, env: { "RHO_WORKSPACE" => "0199-room-env" }, flags: { "workspace" => "0199-room-flag" }).workspace
      assert_equal "0199-room-file",
        Rho::Config.load(path, env: { "RHO_WORKSPACE" => "0199-room-env" }, flags: { "workspace" => nil }).workspace,
        "a nil flag states nothing"
    end
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash({ "mode" => "runner", "workspace" => "0199-room" }) }
    assert_match(/workspace needs mode full or agent/, error.message)
  end
end
