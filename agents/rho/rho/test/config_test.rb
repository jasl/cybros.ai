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

  def test_an_absent_file_is_the_ordinary_case
    assert_equal 120, Rho::Config.load(nil).bash_timeout_seconds
    assert_nil Rho::Config.load("/nowhere/settings.json").tools_root
  end

  def test_lifecycle_hooks_are_carried_to_the_profile_declaration
    hooks = { "stop" => { "tool" => "verify", "timeout_ms" => 30_000, "max_continuations" => 2 } }
    config = Rho::Config.from_hash("lifecycle_hooks" => hooks)
    registry = Rho::Extensions.load(host: RhoTest.host).registry
    declaration = Rho::LoopRequest.declaration(registry: registry, lifecycle_hooks: config.lifecycle_hooks)

    assert_equal hooks, declaration.fetch(:lifecycle_hooks)
    assert_equal({}, Rho::Config.load(nil).lifecycle_hooks)
  end

  # PRECEDENCE: defaults < file < environment. The environment beats the
  # file because that is how a container or a systemd unit supplies a
  # secret.
  def test_the_environment_beats_the_file
    with_settings("bind" => "127.0.0.1", "bash_timeout_seconds" => 60) do |path|
      config = Rho::Config.load(path, env: { "RHO_BIND" => "0.0.0.0" })

      assert_equal "0.0.0.0", config.bind
      assert_equal 60, config.bash_timeout_seconds, "an unset variable overrides nothing"
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
    config = Rho::Config.from_hash("tools_root" => "~/src")

    assert_equal File.expand_path("~/src"), config.tools_root
    refute_includes config.tools_root, "~",
      "a tool resolving against a literal ~/src would create a directory called ~"
  end

  def test_tools_root_takes_the_environment_too
    with_settings("tools_root" => "/from/file") do |path|
      config = Rho::Config.load(path, env: { "RHO_TOOLS_ROOT" => "/from/env" })
      assert_equal "/from/env", config.tools_root
    end
  end

  # A passphrase guards a bearer that grants this host's shell; refuse a
  # trivially guessable one loudly rather than pretending it locks
  # anything.
  def test_a_short_passphrase_is_refused_at_construction
    assert_raises(Rho::ConfigurationError) do
      Rho::Config.from_hash("access_passphrase" => "seven77")
    end
    assert_equal "eight888", Rho::Config.from_hash("access_passphrase" => "eight888").access_passphrase
  end

  def test_a_bash_timeout_past_the_parks_own_clock_is_refused
    assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("bash_timeout_seconds" => 0) }
    assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("bash_timeout_seconds" => 541) }
    assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("bash_timeout_seconds" => "soon") }
    assert_equal 540, Rho::Config.from_hash("bash_timeout_seconds" => 540).bash_timeout_seconds
  end

  def test_api_only_reads_the_spellings_an_operator_writes
    %w[1 true yes on TRUE].each do |value|
      assert Rho::Config.from_hash("api_only" => value).api_only, value
    end
    %w[0 false no off].each do |value|
      refute Rho::Config.from_hash("api_only" => value).api_only, value
    end
    assert Rho::Config.from_hash("api_only" => true).api_only
  end

  def test_extension_lists_must_be_arrays_and_drop_blanks
    config = Rho::Config.from_hash("extensions" => ["rho/net", "", nil])
    assert_equal ["rho/net"], config.extensions

    assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("extensions" => "rho/net") }
  end

  # THE MODEL `rho do` OPENS ON when `--model` names none:
  # nil until stated, from the file, or from the environment — the daemon
  # holds it, because the CLI cannot read the daemon's settings.
  def test_default_model_is_nil_until_someone_states_it
    assert_nil Rho::Config.from_hash({}).default_model
    assert_nil Rho::Config.from_hash("default_model" => "").default_model
    assert_equal "openrouter/x", Rho::Config.from_hash("default_model" => "openrouter/x").default_model
  end

  def test_default_model_takes_the_file_then_the_environment
    with_settings("default_model" => "dev/mock-text") do |path|
      assert_equal "dev/mock-text", Rho::Config.load(path).default_model
      assert_equal "openrouter/y", Rho::Config.load(path, env: { "RHO_DEFAULT_MODEL" => "openrouter/y" }).default_model
    end
  end

  # THE FALLBACK ON REFUSAL OR OVERLOAD: the model the kernel re-runs a step rho answers
  # on once when a provider's classifier declined it — nil until stated,
  # from the file or `RHO_FALLBACK_MODEL`; refused under mode runner, which
  # declares no profile, so a setting that would lie is caught where it is
  # read. It may equal `default_model` (a run on `--model` falls back home).
  def test_fallback_model_is_nil_until_stated_takes_the_file_then_the_environment_and_refuses_a_runner
    assert_nil Rho::Config.from_hash({}).fallback_model
    assert_nil Rho::Config.from_hash("fallback_model" => "").fallback_model
    assert_equal "dev/fallback", Rho::Config.from_hash("fallback_model" => "dev/fallback").fallback_model
    same = Rho::Config.from_hash("default_model" => "dev/mock-text", "fallback_model" => "dev/mock-text")
    assert_equal "dev/mock-text", same.fallback_model, "equal to default_model is a valid declaration"
    with_settings("fallback_model" => "dev/mock-unmetered") do |path|
      assert_equal "dev/mock-unmetered", Rho::Config.load(path).fallback_model
      assert_equal "openai_api/y", Rho::Config.load(path, env: { "RHO_FALLBACK_MODEL" => "openai_api/y" }).fallback_model
    end
    assert_equal "RHO_FALLBACK_MODEL", Rho::Config::ENV_KEYS.fetch("fallback_model")
    error = assert_raises(Rho::ConfigurationError) do
      Rho::Config.from_hash("fallback_model" => "dev/mock-text", "mode" => "runner")
    end
    assert_match(/fallback_model needs mode full or agent/, error.message)
  end

  # THE IMAGE MODEL: the provider/reference
  # rho's `image_generate` tool places its OneShot on — nil until stated,
  # from the file or `RHO_IMAGE_MODEL`, never a hardcoded id (codex's
  # `tool.rs:59`); refused under mode runner, which opens no member plane
  # (the `workspace` precedent), so a setting that would lie is caught
  # where it is read.
  def test_image_model_is_nil_until_stated_takes_the_file_then_the_environment_and_refuses_a_runner
    assert_nil Rho::Config.from_hash({}).image_model
    assert_nil Rho::Config.from_hash("image_model" => "").image_model
    assert_equal "dev/mock-image", Rho::Config.from_hash("image_model" => "dev/mock-image").image_model
    with_settings("image_model" => "dev/mock-image") do |path|
      assert_equal "dev/mock-image", Rho::Config.load(path).image_model
      assert_equal "openai_api/x", Rho::Config.load(path, env: { "RHO_IMAGE_MODEL" => "openai_api/x" }).image_model
    end
    assert_equal "RHO_IMAGE_MODEL", Rho::Config::ENV_KEYS.fetch("image_model")
    error = assert_raises(Rho::ConfigurationError) do
      Rho::Config.from_hash("image_model" => "dev/mock-image", "mode" => "runner")
    end
    assert_match(/image_model needs mode full or agent/, error.message)
  end

  # `task` and `ask` beside `compose`, the
  # six memory verbs, the conversation verbs (a model can spawn a subagent or a peer and keep talking to it through exe/rho), and the `skill` load (declaring it is rho's "whether to declare skills at all"; the kernel omits it from the wire while the catalog is empty).
  def test_the_kernel_tools_default_to_compose_task_ask_the_memory_the_conversation_verbs_and_skill
    assert_equal %w[nexus.graph.compose nexus.graph.task nexus.human.ask
                    nexus.memory.read nexus.memory.write nexus.memory.edit
                    nexus.memory.ls nexus.memory.grep nexus.memory.delete
                    nexus.conversation.spawn nexus.conversation.send
                    nexus.conversation.status nexus.conversation.cancel
                    nexus.conversation.search nexus.conversation.read
                    nexus.skill.load],
      Rho::Config.from_hash({}).kernel_tools
  end

  # THE COMPOSE SWITCH:
  # `compose` is a mode word — `on`, `off`, or `auto`, where the model's
  # adaptation row decides — defaulting to auto,
  # from the file then RHO_COMPOSE.
  def test_compose_defaults_to_auto_and_takes_the_file_then_the_environment
    assert_equal "auto", Rho::Config.from_hash({}).compose
    with_settings("compose" => "off") do |path|
      assert_equal "off", Rho::Config.load(path).compose
      assert_equal "on", Rho::Config.load(path, env: { "RHO_COMPOSE" => "on" }).compose
    end
  end

  def test_compose_refuses_a_third_word_naming_the_key
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("compose" => "maybe") }
    assert_match(/compose must be one of on, off, auto/, error.message)
  end

  # THE CHECKPOINTS ROW: five knobs over the store's own defaults
  # — restated here so the two cannot disagree silently — each read as an
  # integer where the store takes one; a key outside the five is refused
  # by name (a misspelled cap would silently keep the default), a shape
  # that is not an object likewise; a table is not an environment variable.
  def test_checkpoints_defaults_to_the_stores_own_and_takes_the_file_and_refuses_a_stranger
    store = Rho::Runner::Checkpoints::Store
    defaults = Rho::Config.from_hash({}).checkpoints
    assert_equal({ "enabled" => true, "retention_days" => store::DEFAULT_RETENTION_DAYS,
                   "max_file_bytes" => store::DEFAULT_MAX_FILE_BYTES, "max_tree_bytes" => store::DEFAULT_MAX_TREE_BYTES,
                   "capture_timeout_seconds" => store::DEFAULT_CAPTURE_TIMEOUT_SECONDS }, defaults)
    assert_predicate defaults, :frozen?
    refute Rho::Config::ENV_KEYS.key?("checkpoints"), "a table is not an environment variable"

    config = Rho::Config.from_hash("checkpoints" => { "enabled" => false, "retention_days" => "3", "max_tree_bytes" => 1024 })
    assert_equal false, config.checkpoints.fetch("enabled")
    assert_equal 3, config.checkpoints.fetch("retention_days")
    assert_equal 1024, config.checkpoints.fetch("max_tree_bytes")
    assert_equal store::DEFAULT_MAX_FILE_BYTES, config.checkpoints.fetch("max_file_bytes"), "the rest keep the defaults"
    with_settings("checkpoints" => { "capture_timeout_seconds" => 5 }) do |path|
      assert_equal 5, Rho::Config.load(path).checkpoints.fetch("capture_timeout_seconds")
    end

    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("checkpoints" => { "max_files" => 1 }) }
    assert_equal "checkpoints names max_files, not one of enabled, retention_days, max_file_bytes, max_tree_bytes, " \
      "capture_timeout_seconds", error.message
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("checkpoints" => { "retention_days" => 0 }) }
    assert_equal "checkpoints.retention_days must be a positive integer, got 0", error.message
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("checkpoints" => "on") }
    assert_match(/checkpoints must be an object/, error.message)
  end

  # `mcp_servers` IS OPAQUE: an object of
  # objects, kept as a document for `rho/mcp` to judge at load — rho
  # reads nothing inside a row, so a row with any keys at all passes here
  # and only the table's own shape is refused by name.
  def test_mcp_servers_is_an_opaque_object_of_objects
    assert_equal({}, Rho::Config.from_hash({}).mcp_servers)
    table = { "fx" => { "transport" => "stdio", "command" => "ruby", "tools" => "*", "anything" => [1] } }
    config = Rho::Config.from_hash("mcp_servers" => table)
    assert_equal table, config.mcp_servers
    assert_predicate config.mcp_servers, :frozen?
    assert_predicate config.mcp_servers.fetch("fx"), :frozen?
    with_settings("mcp_servers" => table) { |path| assert_equal table, Rho::Config.load(path).mcp_servers }

    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("mcp_servers" => ["fx"]) }
    assert_equal "mcp_servers must be an object of objects", error.message
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("mcp_servers" => { "fx" => "ruby" }) }
    assert_equal "mcp_servers[fx] must be an object", error.message
  end

  # `acp_agents` IS OPAQUE the way `mcp_servers` is:
  # an object of objects — the rows `{command, args, env, description,
  # permissions, timeout_ms, auth_method, model, enabled}` — kept as a
  # document for the ACP client extension to judge at load, PER ROW: a bad
  # row is that row's fault there, never this boot's refusal, so rho reads
  # nothing inside a row and only the table's own shape is refused by name.
  def test_acp_agents_is_an_opaque_object_of_objects
    assert_equal({}, Rho::Config.from_hash({}).acp_agents)
    table = { "opencode" => { "command" => "opencode", "args" => ["acp"], "env" => { "OPENROUTER_API_KEY" => "${OPENROUTER_API_KEY}" },
                              "description" => "OpenCode on OpenRouter", "permissions" => "allow", "timeout_ms" => 600_000,
                              "auth_method" => nil, "model" => nil, "enabled" => true, "anything" => [1] } }
    config = Rho::Config.from_hash("acp_agents" => table)
    assert_equal table, config.acp_agents
    assert_predicate config.acp_agents, :frozen?
    assert_predicate config.acp_agents.fetch("opencode"), :frozen?
    with_settings("acp_agents" => table) { |path| assert_equal table, Rho::Config.load(path).acp_agents }
    assert_includes Rho::Config::KEYS, "acp_agents"
    refute Rho::Config::ENV_KEYS.key?("acp_agents"), "a table is not an environment variable"

    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("acp_agents" => ["opencode"]) }
    assert_equal "acp_agents must be an object of objects", error.message
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("acp_agents" => { "opencode" => "opencode acp" }) }
    assert_equal "acp_agents[opencode] must be an object", error.message
  end

  # `web` IS OPAQUE: an object whose VALUES are
  # not objects — `{"allow_private_network": false}` — which `object_table`
  # would refuse at boot; kept as a document for `rho/web-tools` to judge at
  # load, so a key rho does not know passes here and only the table's own
  # shape is refused by name.
  def test_web_is_an_opaque_object
    assert_equal({}, Rho::Config.from_hash({}).web)
    table = { "allow_private_network" => false, "anything" => "yes" }
    config = Rho::Config.from_hash("web" => table)
    assert_equal table, config.web
    assert_predicate config.web, :frozen?
    with_settings("web" => table) { |path| assert_equal table, Rho::Config.load(path).web }

    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("web" => true) }
    assert_equal "web must be an object", error.message
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("web" => ["allow_private_network"]) }
    assert_equal "web must be an object", error.message
    refute Rho::Config::ENV_KEYS.key?("mcp_servers"), "a table is not an environment variable"
  end

  # THE EXECUTOR SOCKET KNOB: on by default; off is the
  # sweep-only mode E4 proves the product works in. A test-only knob in
  # the sense that no operator wants it — it exists so the negative can
  # be driven through the same file and environment as everything else.
  def test_the_executor_socket_is_on_unless_switched_off
    assert Rho::Config.from_hash({}).executor_socket
    refute Rho::Config.from_hash("executor_socket" => false).executor_socket
    refute Rho::Config.from_hash("executor_socket" => "0").executor_socket
    assert Rho::Config.from_hash("executor_socket" => "on").executor_socket
    with_settings("executor_socket" => true) do |path|
      assert Rho::Config.load(path).executor_socket
      refute Rho::Config.load(path, env: { "RHO_EXECUTOR_SOCKET" => "0" }).executor_socket
      assert Rho::Config.load(path, env: { "RHO_EXECUTOR_SOCKET" => "" }).executor_socket, "empty is unset"
    end
  end

  # THE COMPACTION KNOB: the kernel's summarizer is the
  # shipped default; `delegate` declares rho's own `summarize_history` as
  # the profile's policy and needs a model to place its OneShot on — the
  # row names none.
  def test_compaction_is_the_kernels_by_default_and_the_delegate_reads_its_model
    config = Rho::Config.from_hash({})
    assert_equal({ "mode" => "kernel" }, config.compaction_policy)
    assert_nil config.compaction_model

    delegate = Rho::Config.from_hash("compaction" => { "mode" => "delegate", "model" => "openrouter/x" })
    assert_equal({ "mode" => "delegate", "tool_name" => "summarize_history" }, delegate.compaction_policy)
    assert_equal "openrouter/x", delegate.compaction_model

    on_default = Rho::Config.from_hash("compaction" => { "mode" => "delegate" }, "default_model" => "dev/mock-text")
    assert_equal "delegate", on_default.compaction_policy.fetch("mode")
    assert_nil on_default.compaction_model, "the tool falls to default_model"
  end

  # A kernel policy carries an explicitly selected summary model; a
  # delegate chooses its model in the tool. The settings' compaction object is `{mode, model}` and a stranger
  # — the retired `summarize_after_prunes` among them — is refused by name.
  def test_compaction_declares_the_kernel_model_and_refuses_a_stranger_by_name
    assert_equal({ "mode" => "kernel" }, Rho::Config.from_hash("compaction" => { "mode" => "kernel" }).compaction_policy)
    assert_equal({ "mode" => "kernel", "model" => "openrouter/summary" },
      Rho::Config.from_hash("compaction" => { "mode" => "kernel", "model" => "openrouter/summary" }).compaction_policy)
    assert_equal({ "mode" => "kernel" }, Rho::Config.from_hash("default_model" => "dev/mock-text").compaction_policy,
      "without an explicit summary model, the kernel inherits the current turn's model")
    assert_equal({ "mode" => "delegate", "tool_name" => "summarize_history" },
      Rho::Config.from_hash("compaction" => { "mode" => "delegate", "model" => "openrouter/x" }).compaction_policy)

    error = assert_raises(Rho::ConfigurationError) do
      Rho::Config.from_hash("compaction" => { "mode" => "kernel", "summarize_after_prunes" => 2 })
    end
    assert_match(/\Acompaction names summarize_after_prunes, not one of mode, model\z/, error.message)
    error = assert_raises(Rho::ConfigurationError) do
      Rho::Config.from_hash("compaction" => { "mode" => "kernel", "prunes" => 1 })
    end
    assert_match(/\Acompaction names prunes, not one of mode, model\z/, error.message)
  end

  def test_compaction_refuses_an_unknown_mode_a_bare_word_and_a_delegate_with_no_model
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("compaction" => { "mode" => "prune" }) }
    assert_match(/compaction\.mode must be one of kernel, delegate/, error.message)
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("compaction" => { "mode" => "delegate" }) }
    assert_match(/compaction: delegate needs compaction\.model or default_model/, error.message)
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("compaction" => "delegate") }
    assert_match(/compaction must be an object/, error.message)
  end

  def test_the_environment_spells_the_compaction_mode_and_keeps_the_files_model
    with_settings("compaction" => { "mode" => "kernel", "model" => "openrouter/x" }) do |path|
      assert_equal "kernel", Rho::Config.load(path).compaction_policy.fetch("mode")
      config = Rho::Config.load(path, env: { "RHO_COMPACTION" => "delegate" })
      assert_equal "delegate", config.compaction_policy.fetch("mode")
      assert_equal "openrouter/x", config.compaction_model, "the environment spells the mode only"
      assert_equal "kernel", Rho::Config.load(path, env: { "RHO_COMPACTION" => "" }).compaction_policy.fetch("mode"),
        "empty is unset"
    end
  end

  def test_a_config_is_frozen_so_nothing_edits_the_operators_intent
    assert_predicate Rho::Config.from_hash({}), :frozen?
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
    assert_equal "runner", Rho::Config.from_hash("mode" => "Runner").mode
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("mode" => "server") }
    assert_match(/mode must be one of full, agent, runner/, error.message)
  end

  def test_rho_mode_spells_it_and_a_flag_beats_the_environment
    with_settings("mode" => "agent") do |path|
      assert_equal "agent", Rho::Config.load(path).mode
      assert_equal "runner", Rho::Config.load(path, env: { "RHO_MODE" => "runner" }).mode
      assert_equal "full", Rho::Config.load(path, env: { "RHO_MODE" => "runner" }, flags: { "mode" => "full" }).mode
      assert_equal "runner", Rho::Config.load(path, env: { "RHO_MODE" => "runner" }, flags: { "mode" => nil }).mode,
        "a nil flag states nothing"
    end
  end

  def test_a_runner_declares_no_profile_so_delegate_compaction_is_refused_there
    error = assert_raises(Rho::ConfigurationError) do
      Rho::Config.from_hash("mode" => "runner", "compaction" => { "mode" => "delegate", "model" => "dev/x" })
    end
    assert_match(/compaction.mode delegate needs mode full or agent/, error.message)
    assert_equal "delegate",
      Rho::Config.from_hash("mode" => "agent", "compaction" => { "mode" => "delegate", "model" => "dev/x" })
        .compaction.fetch("mode")
  end

  # The runner new hosts start on when `rho do --runner` names none: a
  # settings key with no environment spelling, nil by default.
  def test_the_runner_setting_names_a_runner_kind_executor_or_nothing
    assert_nil Rho::Config.load(nil).runner
    assert_equal "0199-r", Rho::Config.from_hash("runner" => "0199-r").runner
    assert_nil Rho::Config.from_hash("runner" => "").runner
    refute Rho::Config::ENV_KEYS.key?("runner")
  end

  # THE ROOM KNOB: `workspace` names a
  # steward-created room the daemon adopts instead of minting its own
  # dedicated workspace — the file, `RHO_WORKSPACE`, then `rho server
  # --workspace` (the same ladder as `mode`); nil is the dedicated path.
  # A runner adopts no workspace, so the key is refused there by name.
  def test_the_workspace_setting_names_a_room_and_takes_the_file_the_environment_then_the_flag
    assert_nil Rho::Config.load(nil).workspace
    assert_nil Rho::Config.from_hash("workspace" => "").workspace
    assert_equal "RHO_WORKSPACE", Rho::Config::ENV_KEYS.fetch("workspace")
    with_settings("workspace" => "0199-room-file") do |path|
      assert_equal "0199-room-file", Rho::Config.load(path).workspace
      assert_equal "0199-room-env", Rho::Config.load(path, env: { "RHO_WORKSPACE" => "0199-room-env" }).workspace
      assert_equal "0199-room-flag",
        Rho::Config.load(path, env: { "RHO_WORKSPACE" => "0199-room-env" }, flags: { "workspace" => "0199-room-flag" }).workspace
      assert_equal "0199-room-env",
        Rho::Config.load(path, env: { "RHO_WORKSPACE" => "0199-room-env" }, flags: { "workspace" => nil }).workspace,
        "a nil flag states nothing"
    end
    error = assert_raises(Rho::ConfigurationError) { Rho::Config.from_hash("mode" => "runner", "workspace" => "0199-room") }
    assert_match(/workspace needs mode full or agent/, error.message)
  end
end
