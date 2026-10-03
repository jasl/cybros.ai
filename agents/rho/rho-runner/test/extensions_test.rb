require "test_helper"
require "tmpdir"
require "json"

# THE EXTENSION PLANE — the seam `Toolset` spent its whole life saying it
# was standing in for: "The predecessor registered them through its
# extension API so the built-ins would hold no privileged path into the
# loop. There is no extension plane here yet, so this is a frozen table
# instead — and when one arrives, this is the seam it replaces."
class ExtensionsTest < Minitest::Test
  Extensions = Rho::Runner::Extensions

  def env
    @env ||= Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: File.join(Dir.tmpdir, "a"))
  end

  # A tool class, written the way the contract asks rather than copied
  # from a built-in — if this is hard to write, the contract is wrong.
  def tool_class(name, answer: "ok", effect: nil, schema: nil, timeout: nil, internal_clamp: nil)
    Class.new do
      const_set(:NAME, name)
      const_set(:TIMEOUT_MS, timeout) unless timeout.nil?
      const_set(:INTERNAL_CLAMP, internal_clamp) unless internal_clamp.nil?
      const_set(:DESCRIPTION, "does #{name}")
      const_set(:SCHEMA, schema || { "type" => "object", "properties" => {} })
      const_set(:EFFECT_PROFILE, effect || {
        "kind" => "read_only", "destructive" => false, "world" => "closed",
        "idempotency" => "intrinsic", "reconciliation" => "none",
      })
      const_set(:PROMPT_SNIPPET, "Do #{name}")
      define_method(:initialize) { |env:| @env = env }
      define_method(:call) { |args| Rho::Runner::Result.ok("#{answer}:#{args["x"]}") }
    end
  end

  # `sole` is ActiveSupport's and this gem has no Rails.
  def sole_message(failures)
    assert_equal 1, failures.length, "expected exactly one failure"
    failures.first.message
  end

  def extension(name, &block)
    Module.new do
      const_set(:NAME, name)
      define_singleton_method(:register) { |api| block.call(api) }
    end
  end

  # THE DOGFOOD RULE, and the reason the plane is trustworthy: the door a
  # third party uses is the door the built-ins use, so it cannot rot
  # untested behind a privileged path.
  def test_the_seven_built_ins_and_the_two_undescribed_names_register_through_the_public_door
    result = Extensions::Loader.call(builtin: [Extensions::Coding])

    assert_predicate result, :ok?
    assert_equal %w[bash edit file_import file_publish files_bytes find grep ls read skill write], result.registry.names.sort
    assert_equal ["rho.coding"], result.registry.extension_names
    assert_equal %w[bash edit file_import file_publish files_bytes find grep ls read skill write],
      result.registry.toolset(env: env).names.sort
    # The seven describe themselves; the person's read and the kernel's
    # skill load describe themselves to nobody.
    assert_equal %w[files_bytes skill], result.registry.entries.select(&:undescribed?).map(&:name).sort
  end

  # THE ANNOUNCEMENT IS THE REGISTRY'S OWN: moved down from
  # rho's `LoopRequest.announcement` so rho's daemon and the harness
  # executor render ONE shape. BYTE-IDENTICAL to the six lines it
  # replaced (the rendering below is that method's body, verbatim): every
  # entry's name, profile and park, the declaration facts unless the entry
  # is described to nobody, sorted by name.
  def test_the_announcement_is_byte_identical_to_the_rendering_it_moved_down_from
    registry = Extensions::Loader.call(builtin: [Extensions::Coding, tool_class("parked", timeout: 120_000).then do |klass|
      extension("rho.parked") { |api| api.register_tool(klass) }
    end]).registry
    expected = registry.entries.map do |entry|
      facts = { "name" => entry.name, "effect_profile" => entry.effect_profile, "timeout_ms" => entry.timeout_ms }
      facts = facts.merge("description" => entry.description, "input_schema" => entry.schema) unless entry.undescribed?
      facts.compact
    end.sort_by { |entry| entry.fetch("name") }

    announcement = registry.announcement

    assert_equal JSON.generate(expected), JSON.generate(announcement)
    assert_equal %w[bash edit file_import file_publish files_bytes find grep ls parked read skill write], announcement.map { |e| e.fetch("name") }
    assert_equal %w[effect_profile name], announcement.find { |e| e.fetch("name") == "files_bytes" }.keys.sort
    assert_equal %w[description effect_profile input_schema name timeout_ms],
      announcement.find { |e| e.fetch("name") == "parked" }.keys.sort
    assert_equal %w[description effect_profile input_schema name], announcement.find { |e| e.fetch("name") == "bash" }.keys.sort
    assert_equal registry.serving(:runner).announcement, announcement, "one address's view renders the same way"
  end

  # WHAT THE HOST ANNOUNCES ALREADY reaches the next extension's handle:
  # the second extension sees the first's
  # entries on the address they were registered on, rendered by the one
  # renderer, and nothing on the other; the base handle given nothing
  # answers an empty list per address, never nil.
  def test_an_extension_reads_what_the_host_announced_before_it_per_address
    seen = {}
    first = extension("rho.first") { |api| api.register_tool(tool_class("first")) }
    second = extension("rho.second") { |api| seen[:second] = api.announced }
    result = Extensions::Loader.call(builtin: [Extensions::Coding, first, second])

    assert_predicate result, :ok?, result.failures.inspect
    assert_equal %i[agent runner], seen.fetch(:second).keys.sort
    assert_equal result.registry.serving(:runner).announcement, seen.fetch(:second).fetch(:runner)
    assert_equal %w[bash edit file_import file_publish files_bytes find first grep ls read skill write], seen.fetch(:second).fetch(:runner).map { |e| e.fetch("name") }
    assert_equal [], seen.fetch(:second).fetch(:agent)
    assert_predicate seen.fetch(:second), :frozen?
    assert_equal({ runner: [], agent: [] }, Extensions::Api.new(extension_name: "rho.bare", source: "<test>").announced)
  end

  # THE DOCUMENTS A RUNNER ANNOUNCES: the Coding
  # extension's scan of the root's two skill directories, as `{name,
  # description}` — read through the same seam a third party's list
  # would take, fail-open per provider, the runner address's alone.
  def test_the_coding_extension_announces_the_roots_skills_as_documents
    Dir.mktmpdir("rho-runner-documents") do |root|
      dir = File.join(root, ".agents", "skills", "deploy-notes")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"),
        "---\nname: deploy-notes\ndescription: How this project is deployed.\n---\n# Deploy\n", encoding: "UTF-8")
      FileUtils.mkdir_p(File.join(root, ".claude", "skills", "Bad Name"))
      File.write(File.join(root, ".claude", "skills", "Bad Name", "SKILL.md"), "---\ndescription: x\n---\n")
      registry = Extensions::Loader.call(builtin: [Extensions::Coding]).registry
      environment = Rho::Runner::Environment.local(root: root)

      assert_equal [{ "name" => "deploy-notes", "description" => "How this project is deployed." }],
        registry.documents(environment)
      assert_equal registry.documents(environment), registry.serving(:runner).documents(environment)
      assert_empty registry.serving(:agent).documents(environment), "the documents are the runner address's"
      assert_empty registry.documents(Rho::Runner::Environment.local(root: File.join(root, "nowhere")))
    end
  end

  def test_a_document_provider_that_raises_or_answers_nothing_costs_only_its_own_list
    result = Extensions::Loader.call(builtin: [
      extension("rho.a") { |api| api.describe_documents { |_environment| [{ "name" => "a", "description" => "A" }] } },
      extension("rho.b") { |api| api.describe_documents { |_environment| raise "scan failed" } },
      extension("rho.c") { |api| api.describe_documents { |_environment| nil } },
      extension("rho.d") { |api| api.describe_documents { |_environment| [{ "name" => "d", "description" => "D" }] } },
    ])
    assert_predicate result, :ok?

    documents = result.registry.documents(Rho::Runner::Environment.local(root: Dir.tmpdir))
    assert_equal %w[a d], documents.map { |entry| entry.fetch("name") }, "in registration order; the raiser and the silent one contribute nothing"
  end

  # A NAME MET TWICE keeps its first entry whether the second comes from
  # another provider or the SAME provider's list: the kernel's door refuses
  # a repeated name for the whole announcement, so neither may reach it.
  def test_a_repeated_document_name_keeps_the_first_across_and_within_providers
    result = Extensions::Loader.call(builtin: [
      extension("rho.a") do |api|
        api.describe_documents { |_environment| [{ "name" => "a", "description" => "A" }, { "name" => "a", "description" => "A again" }] }
      end,
      extension("rho.b") { |api| api.describe_documents { |_environment| [{ "name" => "a", "description" => "A elsewhere" }, { "name" => "b", "description" => "B" }] } },
    ])
    assert_predicate result, :ok?

    documents = result.registry.documents(Rho::Runner::Environment.local(root: Dir.tmpdir))
    assert_equal [%w[a A], %w[b B]], documents.map { |entry| [entry.fetch("name"), entry.fetch("description")] },
      "the first `a` stands; its own list's repeat and the other provider's both fall"
  end

  # THE DOCUMENT LISTS AND LOADERS CARRY THEIR ADDRESS: a list announced on the agent address rides the agent's
  # projection alone, and the base handle — a runner with no daemon —
  # refuses the agent address for both verbs by name, as `register_tool`
  # does; an address outside SERVES is refused before that.
  def test_document_lists_and_loaders_are_per_address_and_the_base_handle_serves_the_runner_alone
    api = Extensions::Api.new(extension_name: "rho.mcp", source: "<test>")
    error = assert_raises(Extensions::RegistrationError) { api.describe_documents(serves: :agent) { |_e| [] } }
    assert_equal "rho.mcp calls describe_documents with serves: :agent; this host serves no agent address — " \
                 "a standalone runner hosts the runner's alone, a daemon what its mode serves", error.message
    error = assert_raises(Extensions::RegistrationError) { api.load_document(serves: :agent) { |_n, _e| nil } }
    assert_match(/calls load_document with serves: :agent/, error.message)
    error = assert_raises(Extensions::RegistrationError) { api.load_document(serves: :kernel) { |_n, _e| nil } }
    assert_equal "rho.mcp calls load_document: serves must be :runner or :agent, not :kernel", error.message
    assert_empty api.document_descriptions
    assert_empty api.document_loaders

    registry = Extensions::Loader.call(builtin: [
      extension("rho.a") { |api| api.describe_documents { |_e| [{ "name" => "a", "description" => "A" }] } },
      extension("rho.b") do |api|
        api.define_singleton_method(:serves?) { |_source| true }
        api.describe_documents(serves: :agent) { |_e| [{ "name" => "b", "description" => "B" }] }
        api.load_document(serves: :agent) { |name, _env| Rho::Runner::Result.ok("agent #{name}") }
      end,
    ]).registry
    environment = Rho::Runner::Environment.local(root: Dir.tmpdir)
    tool_env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: Dir.tmpdir)
    assert_equal %w[a], registry.serving(:runner).documents(environment).map { |e| e.fetch("name") }
    assert_equal %w[b], registry.serving(:agent).documents(environment).map { |e| e.fetch("name") }
    assert_equal %w[a b], registry.documents(environment).map { |e| e.fetch("name") }, "the whole registry lists both"
    assert_equal :agent, registry.serving(:agent).instance_variable_get(:@loaders).fetch(0).serves
    assert_nil registry.serving(:runner).load_document("b", tool_env), "the agent's loader never answers the runner's load"
    assert_equal "agent b", registry.serving(:agent).load_document("b", tool_env).content
  end

  # THE COLLISION RULE IS ONE ADDRESS'S: the plane's `skill` served on the
  # runner address by Coding and on the agent address by an extension
  # announcing documents there is lawful; the same name twice on one
  # address is the load error it always was.
  def test_the_collision_rule_is_per_address_and_the_toolset_is_one_addresss
    agent_skill = extension("rho.mcp") do |api|
      api.define_singleton_method(:serves?) { |_source| true }
      api.define_singleton_method(:register_tool) do |klass, serves: :runner|
        @tools << Extensions::Api::Registration.new(klass: klass, serves: serves)
        self
      end
      api.register_tool(Rho::Runner::Tools::Skill, serves: :agent)
      api.load_document(serves: :agent) { |name, _env| Rho::Runner::Result.ok("prompt #{name}") if name == "fx-summarize" }
    end
    result = Extensions::Loader.call(builtin: [Extensions::Coding, agent_skill])
    assert_predicate result, :ok?, result.failures.inspect
    registry = result.registry
    assert_equal 2, registry.names.count("skill"), "once per address"
    assert_equal %w[skill], registry.serving(:agent).names
    assert_includes registry.serving(:runner).names, "skill"
    assert_equal registry.names.sort, (registry.serving(:runner).names + registry.serving(:agent).names).sort

    tool_env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: Dir.tmpdir)
    agent = registry.serving(:agent).toolset(env: tool_env)
    assert_equal "prompt fx-summarize", agent.fetch("skill").handler.call({ "name" => "fx-summarize" }, nil).content
    assert_equal "skill_unknown: deploy-notes", agent.fetch("skill").handler.call({ "name" => "deploy-notes" }, nil).content,
      "the agent's skill walks the agent's loaders alone"
    runner = registry.serving(:runner).toolset(env: tool_env)
    assert_equal "skill_unknown: fx-summarize", runner.fetch("skill").handler.call({ "name" => "fx-summarize" }, nil).content
    assert_equal registry.serving(:runner).names.sort, registry.toolset(env: tool_env).names.sort,
      "a whole-registry toolset reads as the runner's"

    twice = Extensions::Loader.call(builtin: [
      Extensions::Coding,
      extension("rho.evil") { |api| api.register_tool(Rho::Runner::Tools::Skill) },
    ])
    refute_predicate twice, :ok?
    assert_match(/registers "skill" on the runner address, already registered there by rho\.coding/, sole_message(twice.failures))
  end

  # THE LOADER WALK: registration order, the first
  # `Result` wins, nil falls through, a raise costs its loader and never
  # the load, and a name nobody holds is nil — the tool's `skill_unknown`.
  def test_the_loader_walk_is_ordered_fail_open_and_nil_falls_through
    log = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |event, **fields| log << [event, fields] }
    registry = Extensions::Loader.call(log: logger, builtin: [
      extension("rho.a") { |api| api.load_document { |name, _env| Rho::Runner::Result.ok("a #{name}") if name == "one" } },
      extension("rho.b") { |api| api.load_document { |_name, _env| raise "boom" } },
      extension("rho.c") { |api| api.load_document { |name, _env| Rho::Runner::Result.ok("c #{name}") } },
    ]).registry
    tool_env = Rho::Runner::ToolEnv.new(root: Dir.tmpdir, artifacts_dir: Dir.tmpdir)
    assert_equal "a one", registry.load_document("one", tool_env).content, "the first loader that answers wins"
    assert_equal "c two", registry.load_document("two", tool_env).content, "nil falls through; the raiser is skipped"
    assert_equal [["extension_document_load_failed", { extension: "rho.b", name: "two", error_class: "RuntimeError" }]], log
    assert_nil Extensions::Loader.call(builtin: [Extensions::Coding]).registry.load_document("nobody", tool_env)
  end

  # A NAME MET TWICE across providers keeps the first: the kernel refuses a
  # repeated name for the whole announcement, which would cost every tool.
  def test_a_document_name_met_twice_keeps_the_first_and_logs
    log = []
    logger = Object.new
    logger.define_singleton_method(:warn) { |event, **fields| log << [event, fields] }
    registry = Extensions::Loader.call(log: logger, builtin: [
      extension("rho.a") { |api| api.describe_documents { |_e| [{ "name" => "x", "description" => "A" }] } },
      extension("rho.b") { |api| api.describe_documents { |_e| [{ "name" => "x", "description" => "B" }, { "name" => "y", "description" => "B" }] } },
    ]).registry
    documents = registry.documents(Rho::Runner::Environment.local(root: Dir.tmpdir))
    assert_equal [%w[x A], %w[y B]], documents.map { |e| e.values_at("name", "description") }
    assert_equal [["extension_document_repeated", { extension: "rho.b", name: "x", announced_by: "rho.a" }]], log
  end

  def test_a_third_party_extension_reaches_the_same_toolset
    result = Extensions::Loader.call(builtin: [
      Extensions::Coding,
      extension("rho.net") { |api| api.register_tool(tool_class("net_fetch")) },
    ])

    assert_predicate result, :ok?
    assert_includes result.registry.names, "net_fetch"
    toolset = result.registry.toolset(env: env)
    assert_includes toolset.names, "net_fetch", "the announcement reads this"
    assert_equal "ok:1", toolset.fetch("net_fetch").handler.call({ "x" => 1 }, nil).content
  end

  # `BUILT_IN.to_h` took the LAST registration of a duplicated name and
  # said nothing, so two extensions claiming `bash` produced a runner that
  # served one of them by load order.
  def test_a_name_collision_is_a_load_error_rather_than_a_silent_winner
    result = Extensions::Loader.call(builtin: [
      Extensions::Coding,
      extension("rho.evil") { |api| api.register_tool(tool_class("bash")) },
    ])

    refute_predicate result, :ok?
    assert_match(/registers "bash" on the runner address, already registered there by rho\.coding/, sole_message(result.failures))
    assert_equal 11, result.registry.names.length, "the good extension is untouched"
  end

  # ONE FACTORY'S FAILURE IS ITS OWN. An operator with three extensions and
  # one typo gets two working tools and a line saying which one broke —
  # not a daemon that will not take work.
  def test_a_raising_factory_costs_only_its_own_tools
    result = Extensions::Loader.call(builtin: [
      Extensions::Coding,
      extension("rho.broken") { |_api| raise "boom" },
      extension("rho.fine") { |api| api.register_tool(tool_class("fine")) },
    ])

    refute_predicate result, :ok?
    assert_equal 1, result.failures.length
    assert_includes result.registry.names, "fine", "loading did not stop at the failure"
    assert_equal 12, result.registry.names.length
  end

  # NOTHING HALF-REGISTERED SURVIVES: the staging handle is committed only
  # when the factory returned.
  def test_a_factory_that_raises_after_registering_leaves_nothing_behind
    result = Extensions::Loader.call(builtin: [
      extension("rho.half") do |api|
        api.register_tool(tool_class("first"))
        raise "boom"
      end,
    ])

    assert_empty result.registry.names,
      "a tool from a factory that did not finish is a tool nobody vouched for"
  end

  # VALIDATED AT LOAD, because the alternative is a task parked to its
  # deadline with nothing to read.
  def test_a_malformed_tool_is_refused_where_somebody_can_still_read_it
    cases = {
      "dotted name" => tool_class("rho.net.fetch"),
      "not an object schema" => Class.new(tool_class("x")) { const_set(:SCHEMA, { "type" => "string" }) },
    }
    cases.each do |label, klass|
      result = Extensions::Loader.call(builtin: [extension("rho.bad") { |api| api.register_tool(klass) }])
      refute_predicate result, :ok?, label
      assert_empty result.registry.names, label
    end
  end

  # THE VALUE VOCABULARY IS THE KERNEL'S, CHECKED AT LOAD: the kernel's door judges every profile value and refuses
  # the WHOLE announcement on one stranger, after which every tool on that
  # address answers `tool_not_served` — so a value outside the mirrored
  # vocabulary costs its extension here, where the sentence names the
  # key, the allowed words and the stranger; the built-ins' own profiles
  # pass the same check.
  def test_an_effect_profile_value_outside_the_kernels_vocabulary_is_refused_at_load
    good = { "kind" => "write", "destructive" => true, "world" => "open", "idempotency" => "none",
             "reconciliation" => "none" }
    assert_nil Extensions::Tool.effect_profile_fault(good)
    Extensions::Coding::TOOLS.each { |klass| assert_nil Extensions::Tool.effect_profile_fault(klass::EFFECT_PROFILE), klass.name }

    { "kind" => "readonly", "destructive" => "no", "world" => "local", "idempotency" => "always",
      "reconciliation" => "retry" }.each do |key, stranger|
      klass = tool_class("x", effect: good.merge(key => stranger))
      result = Extensions::Loader.call(builtin: [extension("rho.bad") { |api| api.register_tool(klass) }])
      refute_predicate result, :ok?, key
      assert_empty result.registry.names, key
      message = sole_message(result.failures)
      assert_includes message, "must declare EFFECT_PROFILE with #{key} one of"
      assert_includes message, "not #{stranger.inspect}"
      assert_equal "with #{key} one of #{Extensions::Tool::EFFECT_VALUES.fetch(key).map(&:inspect).join(", ")}, " \
                   "not #{stranger.inspect}", Extensions::Tool.effect_profile_fault(good.merge(key => stranger))
    end
    assert_equal "with exactly kind, destructive, world, idempotency, reconciliation",
      Extensions::Tool.effect_profile_fault(good.except("world"))
    assert_equal "with exactly kind, destructive, world, idempotency, reconciliation",
      Extensions::Tool.effect_profile_fault("write")
  end

  # A SCHEMA json_schemer CANNOT COMPILE IS REFUSED AT LOAD too: every
  # call would be validated against it, and "fail where
  # somebody can still read it" beats a runner that refuses every call
  # with a validator's own exception.
  def test_a_schema_the_validator_cannot_compile_is_refused_at_load
    klass = tool_class("x", schema: { "type" => "object", "required" => "path" })
    result = Extensions::Loader.call(builtin: [extension("rho.bad") { |api| api.register_tool(klass) }])

    refute_predicate result, :ok?
    assert_empty result.registry.names
    assert_match(/SCHEMA .*cannot compile|not an array/, sole_message(result.failures))
  end

  # A PER-TOOL TIMEOUT IS OPTIONAL AND BOUNDED: a tool that
  # declares `TIMEOUT_MS` announces it and the kernel parks its rows that
  # long; one outside the bound is refused where somebody can still read
  # it, never as a row parked for a week. A tool declaring none carries
  # nil on its entry and falls to the kernel's default.
  def test_a_timeout_ms_outside_the_bound_is_refused_at_load
    cases = {
      "zero" => 0, "negative" => -1, "a float" => 1.5, "a string" => "120000",
      "past seven days" => (7 * 24 * 60 * 60 * 1000) + 1,
    }
    cases.each do |label, value|
      klass = tool_class("x", timeout: value)
      result = Extensions::Loader.call(builtin: [extension("rho.bad") { |api| api.register_tool(klass) }])
      refute_predicate result, :ok?, label
      assert_empty result.registry.names, label
      assert_match(/TIMEOUT_MS/, sole_message(result.failures), label)
    end
  end

  def test_a_declared_timeout_ms_rides_the_registry_entry_and_an_undeclared_one_is_nil
    result = Extensions::Loader.call(builtin: [extension("rho.t") { |api|
      api.register_tool(tool_class("timed", timeout: 120_000))
      api.register_tool(tool_class("plain"))
    }])

    assert_predicate result, :ok?
    by_name = result.registry.entries.to_h { |entry| [entry.name, entry.timeout_ms] }
    assert_equal({ "timed" => 120_000, "plain" => nil }, by_name)
  end

  # THE TOOLSET CARRIES WHAT THE EXTENSION NEEDS (executor.md "Extend"):
  # the announced park bounds the ask, and `INTERNAL_CLAMP = true` — bash's
  # declaration — says the handler is never extended at all.
  def test_the_announced_park_and_the_internal_clamp_ride_the_toolset
    result = Extensions::Loader.call(builtin: [extension("rho.t") { |api|
      api.register_tool(tool_class("timed", timeout: 120_000))
      api.register_tool(tool_class("clamped", internal_clamp: true))
      api.register_tool(tool_class("plain"))
    }])
    toolset = result.registry.toolset(env: env)

    assert_equal 120_000, toolset.fetch("timed").timeout_ms
    refute toolset.fetch("timed").internal_clamp
    assert toolset.fetch("clamped").internal_clamp
    assert_nil toolset.fetch("plain").timeout_ms
    refute toolset.fetch("plain").internal_clamp
    assert Rho::Runner::Extensions::Tool.internal_clamp?(Rho::Runner::Tools::Bash), "bash clamps itself"
  end

  # A DOTTED NAME IS THE TRAP WORTH NAMING: `rho.net.fetch` is the
  # canonical spelling a human writes, and no provider wire accepts it.
  def test_the_dotted_canonical_name_is_refused_with_a_reason_that_says_why
    result = Extensions::Loader.call(
      builtin: [extension("rho.net") { |api| api.register_tool(tool_class("rho.net.fetch")) }]
    )

    assert_match(/not a wire name/, sole_message(result.failures))
  end

  def test_an_unknown_event_is_refused_rather_than_silently_never_firing
    result = Extensions::Loader.call(
      builtin: [extension("rho.x") { |api| api.on(:before_provider_request) { nil } }]
    )

    refute_predicate result, :ok?
    assert_match(/unknown event/, sole_message(result.failures))
  end

  # A STANDALONE RUNNER ANSWERS THE DAEMON'S VERBS, so an extension
  # written for a daemon still LOADS on a machine with no daemon in it.
  def test_a_daemon_verb_in_a_standalone_runner_is_a_no_op_not_a_crash
    result = Extensions::Loader.call(builtin: [
      extension("rho.cmd") do |api|
        api.register_command("deploy") { nil }
        api.background { nil }
        api.register_tool(tool_class("still_here"))
      end,
    ])

    assert_predicate result, :ok?
    assert_includes result.registry.names, "still_here"
  end

  # A route or a flag is a daemon's verb too, and the same rule holds: an
  # extension registering one loads here, and the log says who is not
  # listening.
  def test_a_route_or_flag_in_a_standalone_runner_is_logged_not_a_crash
    log = RecordingLog.new
    result = Extensions::Loader.call(log: log, builtin: [
      extension("rho.web_tools") do |api|
        api.register_route("GET", "/web") { |_request, _ctx| nil }
        api.register_flags("do", until: { type: :string }) { |body, _options| body }
        api.register_tool(tool_class("still_here"))
      end,
    ])

    assert_predicate result, :ok?, result.failures.inspect
    assert_includes result.registry.names, "still_here"
    assert_nil result.committed.first.host, "a standalone runner has no host to hand over"
    details = log.lines.select { |event, _| event == "extension_verb_unavailable" }.map { |_, fields| fields[:detail] }
    assert_equal 2, details.length
    assert_match(/route GET \/web/, details[0])
    assert_match(/flags on do/, details[1])
  end

  # HOW A HOST REACHES EVERY HANDLE: the loader builds them all, so the
  # host's extras ride its one constructor call.
  def test_api_options_reach_every_handle_the_loader_builds
    host = Object.new
    result = Extensions::Loader.call(builtin: [Extensions::Coding], api_options: { host: host })

    assert_predicate result, :ok?
    assert_same host, result.committed.first.host
  end

  class RecordingLog
    attr_reader :lines

    def initialize = @lines = []
    def info(event, **fields) = @lines << [event, fields]
    def warn(event, **fields) = @lines << [event, fields]
  end

  # The fragments every built-in has declared and nothing has ever read.
  def test_the_registry_reads_the_prompt_fragments_that_were_being_thrown_away
    fragments = Extensions::Loader.call(builtin: [Extensions::Coding]).registry.prompt_fragments

    assert_equal 7, fragments.length
    bash = fragments.find { |f| f["name"] == "bash" }
    assert_includes bash.fetch("snippet"), "bash"
  end

  def test_the_declarations_are_the_mcp_shape_the_sdk_lowering_takes
    declaration = Extensions::Loader.call(builtin: [Extensions::Coding])
      .registry.declarations.find { |d| d["name"] == "ls" }

    assert_equal %w[name description inputSchema], declaration.keys
    assert_equal "object", declaration.fetch("inputSchema").fetch("type")
  end

  def test_the_effect_profile_is_readable_for_every_registered_tool_not_just_built_ins
    registry = Extensions::Loader.call(builtin: [
      Extensions::Coding,
      extension("rho.net") { |api| api.register_tool(tool_class("net_fetch")) },
    ]).registry

    assert_equal "write", registry.effect_profile("bash").fetch("kind")
    assert_equal "read_only", registry.effect_profile("net_fetch").fetch("kind"),
      "the old class-method scan over BUILT_IN made every extension tool invisible here"
  end

  # A file dropped in the operator's own directory, loaded into an
  # anonymous module so two extensions cannot collide in Object.
  def test_a_file_extension_loads_from_a_path
    Dir.mktmpdir do |dir|
      path = File.join(dir, "hello.rb")
      File.write(path, <<~RUBY)
        module HelloExtension
          NAME = "rho.hello"
          class Hello
            NAME = "hello"
            DESCRIPTION = "says hello"
            SCHEMA = { "type" => "object", "properties" => {} }.freeze
            EFFECT_PROFILE = {
              "kind" => "read_only", "destructive" => false, "world" => "closed",
              "idempotency" => "intrinsic", "reconciliation" => "none"
            }.freeze
            def initialize(env:) = @env = env
            def call(_args) = Rho::Runner::Result.ok("hello")
          end
          def self.register(api) = api.register_tool(Hello)
        end
      RUBY

      result = Extensions::Loader.call(paths: [path])

      assert_predicate result, :ok?, result.failures.map(&:message).join
      assert_equal ["hello"], result.registry.names
      refute Object.const_defined?(:HelloExtension),
        "an anonymous wrapper is what keeps two extensions from colliding in Object"
    end
  end

  # THE DAEMON'S THREE EVENTS — the two turn events and the host's end —
  # are its verbs' kin: an extension that shapes turns or releases a
  # conversation's children loads here, registers nothing a runner would
  # fire, and the log says who is not listening.
  def test_a_daemon_loop_event_in_a_standalone_runner_is_logged_not_a_crash
    log = RecordingLog.new
    result = Extensions::Loader.call(log: log, builtin: [
      extension("rho.gate") do |api|
        api.on(:turn_author) { |draft, _ctx| draft }
        api.on(:turn_follow) { |_loop_public_id, _notes, _ctx| nil }
        api.on(:host_ended) { |_host_public_id| nil }
        api.register_tool(tool_class("still_here"))
      end,
    ])

    assert_predicate result, :ok?, result.failures.inspect
    handle = result.committed.first
    assert_empty handle.lifecycle
    assert_empty handle.hooks
    assert_includes result.registry.names, "still_here"
    details = log.lines.select { |event, _| event == "extension_verb_unavailable" }.map { |_, fields| fields[:detail] }
    assert_equal ["hook turn_author is not surfaced by a standalone runner",
                  "hook turn_follow is not surfaced by a standalone runner",
                  "hook host_ended is not surfaced by a standalone runner"], details
    assert_equal %i[turn_author turn_follow host_ended], Extensions::Api::DAEMON_EVENTS
  end

  # THE LIFECYCLE BRANCH ON THE BASE HANDLE. Before this lived here, a
  # standalone runner answered `on(:shutdown)` with an unknown-event
  # error, so an extension holding a browser could not load at all. The
  # registrations must land on `lifecycle`, stay OUT of the tool hooks
  # (Hooks::Host must never see a :shutdown), and a genuinely unknown
  # event must still be refused by name.
  def test_lifecycle_events_register_on_the_base_handle_and_stay_out_of_the_tool_hooks
    fired = []
    result = Extensions::Loader.call(builtin: [
      extension("rho.holder") do |api|
        api.on(:startup) { fired << :startup }
        api.on(:shutdown) { fired << :shutdown }
        api.on(:tool_call) { |_call| nil }
      end,
    ])

    assert_predicate result, :ok?, result.failures.inspect
    handle = result.committed.first
    assert_equal %i[startup shutdown], handle.lifecycle.map(&:event)
    assert_equal [:tool_call], handle.hooks.map(&:event)
    assert_equal [:tool_call], result.registry.hooks.instance_variable_get(:@by_event).keys

    # Stored, not fired: a standalone runner has no lifetime to fire them in.
    assert_empty fired
    handle.lifecycle.each { |hook| hook.handler.call }
    assert_equal %i[startup shutdown], fired
  end

  def test_an_unknown_event_names_every_event_the_host_offers
    result = Extensions::Loader.call(builtin: [
      extension("rho.typo") { |api| api.on(:shutdwon) { nil } },
    ])
    message = sole_message(result.failures)
    assert_match(/unknown event :shutdwon/, message)
    assert_match(/tool_call, tool_result, startup, shutdown/, message)
  end

  # THE HEADER'S PROMISE: a factory that stashed its handle and kept
  # registering after commit gets a FrozenError, never a silent drop.
  def test_a_committed_handle_refuses_late_registrations_loudly
    stashed = nil
    result = Extensions::Loader.call(builtin: [
      extension("rho.stasher") { |api| stashed = api },
    ])
    assert_predicate result, :ok?

    assert_raises(FrozenError) { stashed.on(:shutdown) { nil } }
    assert_raises(FrozenError) { stashed.on(:tool_call) { nil } }
    assert_raises(FrozenError) { stashed.register_tool(tool_class("late")) }
  end
end
