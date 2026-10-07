require "test_helper"
require_relative "guard_test"

# rho declares source intentions and application policy. Nexus imports Runner
# schemas; Agent custom tools and compact aliases are the only carried entries.
class RunDeclarationTest < Minitest::Test
  def registry = @registry ||= Rho::Extensions.load(host: RhoTest.host).registry

  def own = Rho::RunDeclaration.announcement(registry: registry)

  def name_of(entry) = entry.dig("function", "name")

  # THE BYTES DO NOT MOVE (ordering note 8): the entries lowered from the
  # announcement are the entries lowered from the registry's own
  # declarations — the lowering already sorts by name and reads the
  # kernel's `input_schema` spelling — and the delegate summarizer stays
  # announced, never declared.
  # THE NAMES NO MODEL IS OFFERED: the delegate
  # summarizer and the runner's person-facing capabilities, hidden BY NAME
  # from whichever list served them — and announced described to nobody,
  # so a peer reading discovery cannot author a declaration from them.
  # The runner's `skill` is the fourth: the kernel's
  # tool of that name is what the profile declares; the runner's announced
  # one is where a load of an announced document is delivered. The
  # checkpoint store's two are the fifth and
  # sixth: `checkpoint_restore` — no model rewinds its own world — and the
  # `checkpoints` read.
  # `environment_bind` is the seventh: the
  # call_tool's way of telling a runner elsewhere a conversation's root set.
  def test_code_mode_filters_local_and_remote_standalone_tools_and_local_prompt_without_changing_registration
    registry = Rho::Extensions.load(host: RhoTest.host, gems: ["rho/codemode"]).registry
    own = Rho::RunDeclaration.announcement(registry: registry.serving(:runner))
    [nil, own].each do |served|
      step = Rho::RunDeclaration.steps(runner_executor_public_id: "own-runner", runner_executor_public_ids: ["own-runner"],
        prompt: "work", model: "dev/test", registry: registry, served: served, code_mode: false).first
      refute_includes Array(step.tools).map { |entry| name_of(entry) }, "code"
      assert_includes step.runner_tool_names, "read"
      assert_includes step.runner_tool_names, "skill"
      assert_empty step.runner_tool_names & (Rho::RunDeclaration.undeclared + ["code"])
      assert step.runner_tool_names.none? { |name| name.include?("__") }, "policy uses original served names"
      refute_match(/^- code:/, step.instructions)
    end
    assert_includes registry.names, "code"
    assert_includes Rho::RunDeclaration.tool_entries(own).map { |entry| name_of(entry) }, "code"
    assert_match(/^- code:/, Rho::RunDeclaration.lead(registry: registry))
    refute_match(/^- code:/, Rho::RunDeclaration.lead(registry: registry, code_mode: false))
  end

  def test_undeclared_names_are_hidden_from_the_entries_and_announced_schema_less
    assert_equal %w[summarize_history files_bytes process_log checkpoints checkpoint_restore environment_bind],
      Rho::RunDeclaration.undeclared
    names = Rho::RunDeclaration.tool_entries(own).map { |entry| name_of(entry) }
    refute_includes names, "files_bytes"
    refute_includes names, "process_log"
    refute_includes names, "skill"
    refute_includes names, "checkpoints"
    refute_includes names, "checkpoint_restore"
    assert_includes names, "read"
    assert_includes names, "read_process", "the model's own process read stays"

    announced = own.to_h { |entry| [entry.fetch("name"), entry] }
    %w[files_bytes process_log checkpoints environment_bind].each do |name|
      entry = announced.fetch(name)
      assert_equal %w[name effect_profile], entry.keys, "#{name} announces its name and profile alone: #{entry.inspect}"
    end
    assert_equal %w[name effect_profile timeout_ms], announced.fetch("checkpoint_restore").keys,
      "checkpoint_restore announces its name, profile and its own park alone"
    assert_equal %w[name effect_profile description input_schema], announced.fetch("read").keys
    # A served list from elsewhere hides the same names: by name, not by class.
    served = [NexusDoubles.served_tool("files_bytes"), NexusDoubles.served_tool("read")]
    assert_equal ["read"], Rho::RunDeclaration.tool_entries(served).map { |entry| name_of(entry) }
  end

  # THE DOCUMENTS: the announcement's third list is
  # the registry's runner-address scan of the root — the checkout's
  # `SKILL.md` files as `{name, description}` — and nothing from nowhere.
  def test_documents_are_the_roots_skills_as_the_registry_scans_them
    Dir.mktmpdir("rho-documents") do |root|
      dir = File.join(root, ".agents", "skills", "deploy-notes")
      FileUtils.mkdir_p(dir)
      File.write(File.join(dir, "SKILL.md"), "---\nname: deploy-notes\ndescription: How we deploy.\n---\n# Deploy\n")
      environment = Rho::Runner::Environment.local(root: root)

      assert_equal [{ "name" => "deploy-notes", "description" => "How we deploy." }],
        Rho::RunDeclaration.documents(registry: registry.serving(:runner), environment: environment)
      assert_empty Rho::RunDeclaration.documents(registry: registry.serving(:agent), environment: environment),
        "the agent address announces no documents"
      assert_empty Rho::RunDeclaration.documents(registry: registry,
        environment: Rho::Runner::Environment.local(root: File.join(root, "empty")))
    end
  end

  def test_tool_entries_over_the_announcement_are_the_registrys_own_bytes
    entries = Rho::RunDeclaration.tool_entries(own)

    declared = registry.declarations.reject { |tool| (Rho::RunDeclaration.undeclared + ["skill"]).include?(tool.fetch("name")) }
    assert_equal CybrosAgent::Api::ToolLowering.function_entries(declared), entries
    refute_includes entries.map { |entry| name_of(entry) }, Rho::Extensions::Compaction::TOOL_NAME
    assert_equal entries.map { |entry| name_of(entry) }.sort, entries.map { |entry| name_of(entry) }
  end

  # THE REMOTE FEEDER reads the SDK's discovery projection as it is — the
  # `ServedTool` Data with symbol keys — or the announcement hash.
  def test_tool_entries_take_the_discovery_projection_or_the_announcement_hash
    served = [NexusDoubles.served_tool("slow_read", description: "reads slowly"),
              NexusDoubles.served_tool("slow_write")]
    projection = served.map do |entry|
      CybrosAgent::Api::ServedTool.new(name: entry["name"], effect_profile: entry["effect_profile"],
        description: entry["description"], input_schema: entry["input_schema"])
    end

    from_hashes = Rho::RunDeclaration.tool_entries(served)
    assert_equal from_hashes, Rho::RunDeclaration.tool_entries(projection)
    assert_equal [{ "type" => "function",
                    "function" => { "name" => "slow_read", "description" => "reads slowly",
                                    "parameters" => { "type" => "object", "properties" => {} } } }],
      from_hashes.first(1)
    assert_empty Rho::RunDeclaration.tool_entries([])
    assert_empty Rho::RunDeclaration.tool_entries(nil)
  end

  def test_same_callable_with_different_bytes_is_an_author_error
    original = Rho::RunDeclaration.tool_entries([NexusDoubles.served_tool("read")]).first
    changed = Rho::RunDeclaration.tool_entries([NexusDoubles.served_tool("read", description: "different")]).first
    assert_equal [original], Rho::RunDeclaration.unique_entries([[original], [original]])
    assert_raises(ArgumentError) { Rho::RunDeclaration.unique_entries([[original], [changed]]) }
  end

  RunnerDocument = Data.define(:public_id, :served_tools)

  def test_declaration_keeps_sources_separate_from_carried_agent_entries
    kernel = %w[nexus.graph.delegate_task nexus.human.ask]
    kernel_alias = { "type" => "function", "function" => { "name" => "Agent" }, "canonical" => "nexus.graph.delegate_task" }
    remote = [NexusDoubles.served_tool("slow_read"), NexusDoubles.served_tool("slow_write")]

    declaration = Rho::RunDeclaration.declaration(registry: registry, kernel_tools: kernel, kernel_aliases: [kernel_alias],
      runner_executor_public_ids: %w[remote-a own-runner], remote: [RunnerDocument.new(public_id: "remote-a", served_tools: remote)])

    names = declaration.fetch(:tool_definitions).map { |entry| name_of(entry) }
    assert_equal %w[Agent list_extensions manage_extension manage_schedule read_schedules todo_write], names
    assert_includes declaration.fetch(:tool_definitions), kernel_alias
    assert_equal kernel, declaration.fetch(:kernel_tools)
    assert_equal %w[remote-a own-runner], declaration.fetch(:runner_executor_public_ids), "caller order is preserved"
    assert_nil declaration.fetch(:runner_tool_names)
    refute declaration.fetch(:tool_definitions).any? { |entry| entry.key?("route") }
    assert_equal Rho::RunDeclaration.declaration(registry: registry, kernel_tools: kernel),
      Rho::RunDeclaration.declaration(registry: registry, kernel_tools: kernel, remote: []),
      "discovery supplies policy facts, not candidate membership or tool schemas"
    assert_equal %i[tool_definitions kernel_tools runner_executor_public_ids runner_tool_names approval_mode approval_rules prompt_mechanism prompt_template compaction_policy
                    default_model lifecycle_hooks fallback_model],
      declaration.keys, "the complete standing configuration, including lifecycle hooks and the fallback"
    assert_equal Rho::RunDeclaration::APPROVAL_RULES, declaration.fetch(:approval_rules),
      "the complete wire-name policy is independent of the routed callable set"
  end

  # THE FALLBACK ON REFUSAL OR OVERLOAD rides the declaration beside rho's own model:
  # the settings' ref, written whole on every declaration, so a setting
  # removed is a fallback removed; nil declares none.
  def test_the_declaration_carries_the_fallback_model_beside_the_default
    declared = Rho::RunDeclaration.declaration(registry: registry, default_model: "dev/primary",
      fallback_model: "dev/fallback")

    assert_equal "dev/primary", declared.fetch(:default_model)
    assert_equal "dev/fallback", declared.fetch(:fallback_model)
    assert_nil Rho::RunDeclaration.declaration(registry: registry).fetch(:fallback_model), "none stated, none declared"
  end

  # THE SELF-MODIFICATION DENIES: per protected root — the checkout the running process
  # loads from, and RHO_HOME — `write|edit` on the root and under it, and a command that
  # names it, refused with the shared sentence; a deny binds under every mode. Rho's own
  # rules, never the kernel's: `approval_rules(roots:)` is the constant plus them, and the
  # declaration writes that list when the daemon hands its roots.
  def test_approval_rules_with_roots_append_the_self_modification_denies_to_the_constant
    rules = Rho::RunDeclaration.approval_rules(roots: ["/opt/rho", "/home/a/.rho"])
    added = rules - Rho::RunDeclaration::APPROVAL_RULES

    assert_equal Rho::RunDeclaration::APPROVAL_RULES, rules.first(Rho::RunDeclaration::APPROVAL_RULES.length),
      "the Guard list first, untouched"
    assert_equal added, Rho::RunDeclaration.self_modification_rules(["/opt/rho", "/home/a/.rho"])
    assert_equal 6, added.length, "three rules per root"
    assert_equal added, rules.last(6), "appended after the allow rule — deny wins wherever it sits"
    added.each do |rule|
      assert_equal %w[tool path match verdict reason], rule.keys
      assert_equal "deny", rule.fetch("verdict")
      assert_equal Rho::RunDeclaration::INCUBATION, rule.fetch("reason")
      assert rule.frozen?
    end
    assert_equal "direct installation edits are disabled; use managed extensions or develop a separate rho successor",
      Rho::RunDeclaration::INCUBATION
    assert_equal [%w[write|edit path /opt/rho], %w[write|edit path /opt/rho/*], ["bash|start_process", "command", "*/opt/rho*"]],
      added.first(3).map { |rule| rule.values_at("tool", "path", "match") }
    assert_equal ["/home/a/.rho", "/home/a/.rho/*", "*/home/a/.rho*"], added.last(3).map { |rule| rule.fetch("match") }
    assert_equal Rho::RunDeclaration::APPROVAL_RULES, Rho::RunDeclaration.approval_rules(roots: []), "no roots: the constant"
    declaration = Rho::RunDeclaration.declaration(registry: registry, roots: ["/opt/rho"])
    assert_equal rules.first(Rho::RunDeclaration::APPROVAL_RULES.length + 3), declaration.fetch(:approval_rules)
  end

  # THE SESSION GRANTS: the person's allow rules ride LAST — after the constant and
  # after the roots' denies, because deny wins wherever it sits — and none
  # is the list as before, byte for byte; the declaration passes them.
  # `request_rules` (the call_tool's author-origin list) takes none.
  def test_approval_rules_append_the_session_grants_after_the_roots_denies
    grant = { "tool" => "bash", "path" => "command", "match" => "npm test", "verdict" => "allow" }.freeze
    whole = { "tool" => "mcp__fs__read_file", "verdict" => "allow" }.freeze

    rules = Rho::RunDeclaration.approval_rules(roots: ["/opt/rho"], grants: [grant, whole])
    assert_equal Rho::RunDeclaration.approval_rules(roots: ["/opt/rho"]) + [grant, whole], rules
    assert_equal [grant, whole], rules.last(2), "grants last: a deny above still wins"
    assert_predicate rules, :frozen?
    assert_equal Rho::RunDeclaration::APPROVAL_RULES + [grant], Rho::RunDeclaration.approval_rules(grants: [grant]),
      "no roots: the constant, then the grant"
    assert_equal Rho::RunDeclaration::APPROVAL_RULES, Rho::RunDeclaration.approval_rules(grants: []),
      "no grants: the constant itself"
    assert_equal Rho::RunDeclaration.approval_rules(roots: ["/opt/rho"]),
      Rho::RunDeclaration.approval_rules(roots: ["/opt/rho"], grants: []), "no grants: the list as before"

    declaration = Rho::RunDeclaration.declaration(registry: registry, roots: ["/opt/rho"], grants: [grant])
    assert_equal grant, declaration.fetch(:approval_rules).last, "the declaration passes the grants"
    assert_equal Rho::RunDeclaration.declaration(registry: registry, roots: ["/opt/rho"]).fetch(:tool_definitions),
      declaration.fetch(:tool_definitions), "a grant moves no tool byte"
    refute Rho::RunDeclaration.request_rules(roots: ["/opt/rho"]).include?(grant.merge("origin" => "author")),
      "the call_tool's list carries no grant"
  end

  # THE DERIVED DENIES FOR A THIRD PARTY'S TOOL: an
  # announced entry named `mcp__…` — the prefix is the provenance rule —
  # gets, per protected root, ONE deny per text-shaped top-level property
  # of its announced schema (`string`, or an array of strings: the kernel
  # joins a scalar array as text), in the `bash` form with the shared
  # sentence; a property whose name is not one valid path segment
  # (`file.path`) is SKIPPED and listed, never a rule the kernel would
  # refuse or one that never matches; an object-array property and a
  # non-`mcp__` entry derive nothing. The declaration passes the announced
  # entries — the local announcement AND a remote runner's served tools —
  # so a runner-mode rho's stdio tools get the rules by the same hand.
  def test_the_self_modification_denies_derive_from_an_mcp_entrys_text_properties_and_skip_dotted_names
    entry = {
      "name" => "mcp__fx__lookup", "effect_profile" => {},
      "input_schema" => { "type" => "object", "properties" => {
        "key" => { "type" => "string" }, "text" => { "type" => "string", "description" => "words" },
        "paths" => { "type" => "array", "items" => { "type" => "string" } },
        "edits" => { "type" => "array", "items" => { "type" => "object" } },
        "count" => { "type" => "integer" }, "file.path" => { "type" => "string" },
      } },
    }
    properties = Rho::RunDeclaration.deny_properties(entry)
    assert_equal %w[key text paths], properties.derivable
    assert_equal ["file.path"], properties.skipped
    assert_equal Rho::RunDeclaration::DenyProperties.new(derivable: [], skipped: []),
      Rho::RunDeclaration.deny_properties(entry.merge("name" => "lookup")), "no prefix, no derivation"
    assert_equal [], Rho::RunDeclaration.deny_properties(entry.merge("input_schema" => nil)).derivable

    rules = Rho::RunDeclaration.self_modification_rules(["/opt/rho", "/home/a/.rho"], entries: [entry])
    assert_equal 12, rules.length, "three base rules and three derived per root"
    derived = rules.select { |rule| rule.fetch("tool") == "mcp__fx__lookup" }
    assert_equal [%w[key */opt/rho*], %w[text */opt/rho*], %w[paths */opt/rho*],
                  %w[key */home/a/.rho*], %w[text */home/a/.rho*], %w[paths */home/a/.rho*]],
      derived.map { |rule| rule.values_at("path", "match") }
    derived.each do |rule|
      assert_equal %w[tool path match verdict reason], rule.keys
      assert_equal ["deny", Rho::RunDeclaration::INCUBATION], rule.values_at("verdict", "reason")
      assert rule.frozen?
    end
    refute(rules.any? { |rule| rule.fetch("path") == "file.path" }, "a dotted property is never a rule")
    assert_equal Rho::RunDeclaration.self_modification_rules(["/opt/rho"]),
      Rho::RunDeclaration.self_modification_rules(["/opt/rho"], entries: [entry.merge("name" => "read")]),
      "a non-mcp entry adds nothing"

    # Through the declaration: the local announcement's entries and the
    # remote served tools both feed the list; the SDK's projection shape
    # (symbol keys, `to_h`) is read the same way.
    remote = [CybrosAgent::Api::ServedTool.new(name: "mcp__remote__echo", effect_profile: {},
      input_schema: { "type" => "object", "properties" => { "text" => { "type" => "string" } } }, description: "x")]
    declaration = Rho::RunDeclaration.declaration(registry: registry, roots: ["/opt/rho"], remote: [RunnerDocument.new(public_id: "remote-a", served_tools: remote)])
    assert_includes declaration.fetch(:approval_rules),
      { "tool" => "mcp__remote__echo",
        "path" => "text", "match" => "*/opt/rho*", "verdict" => "deny",
        "reason" => Rho::RunDeclaration::INCUBATION }
    assert_equal Rho::RunDeclaration::APPROVAL_RULES.length + 3 + 1, declaration.fetch(:approval_rules).length
    assert_equal Rho::RunDeclaration.request_rules(roots: ["/opt/rho"]).length + 1,
      Rho::RunDeclaration.request_rules(roots: ["/opt/rho"], entries: [entry.merge("name" => "mcp__fx__echo",
        "input_schema" => { "type" => "object", "properties" => { "text" => { "type" => "string" } } })]).length
  end

  # Through the mirror of the kernel's glob: a path at the root or under
  # it is denied, a sibling with the root as a prefix and an unrelated path
  # are not; a command naming the root is denied whole — the COARSE floor,
  # a command cannot be path-precise — and one elsewhere is not.
  def test_the_self_modification_denies_match_the_root_and_under_it_and_a_command_naming_it_coarsely
    denies = Rho::RunDeclaration.self_modification_rules(["/opt/rho"])
    paths = denies.select { |rule| rule.fetch("path") == "path" }
    commands = denies.select { |rule| rule.fetch("path") == "command" }

    ["/opt/rho/lib/rho.rb", "/opt/rho"].each do |path|
      assert paths.any? { |rule| glob(rule.fetch("match")).match?(path) }, "denied: #{path}"
    end
    ["/opt/rho-other/x", "/elsewhere/x", "lib/rho.rb"].each do |path|
      refute paths.any? { |rule| glob(rule.fetch("match")).match?(path) }, "not denied (the rule anchors on the resolved root): #{path}"
    end
    assert commands.any? { |rule| glob(rule.fetch("match")).match?("cat /opt/rho/README.md") }, "the coarse floor: a read that names the root is refused too"
    assert commands.any? { |rule| glob(rule.fetch("match")).match?("echo x >> /opt/rho/settings.json") }
    refute commands.any? { |rule| glob(rule.fetch("match")).match?("ls /elsewhere") }
    assert_equal [%w[write edit], %w[bash start_process]],
      [paths.first.fetch("tool").split("|"), commands.first.fetch("tool").split("|")]
  end

  # THE GUARD LIST IN THE KERNEL'S GRAMMAR: the rules
  # are judged against the Guard's own two lists — every REFUSED command is
  # denied by a rule OR by the Guard's regex (the union is what runs on
  # rho's own runner: the kernel first, the floor after), and NO ALLOWED
  # command matches any rule (a kernel denial is a refusal the model must
  # reformulate around, so `grep -rn shutdown lib` must not be "powering
  # the machine off"). `glob` below is the five-line mirror of
  # `nexus/app/services/executors/rules.rb` (`Glob.compile`: `*` is `.*`,
  # `?` is `.`, everything else escaped, anchored both ends, MULTILINE) —
  # rho cannot load the kernel and the kernel cannot load rho's constant,
  # so a drift there is a red test here; the REAL evaluator is exercised by
  # the approval journey and the guard lane.
  def test_the_rules_are_the_guard_list_in_the_kernels_grammar
    constant = Rho::RunDeclaration::APPROVAL_RULES
    rules = Rho::RunDeclaration.approval_rules(roots: ["/opt/rho", "/home/a/.rho"])
    denies, allows = rules.partition { |rule| rule.fetch("verdict") == "deny" }
    guard_denies, self_denies = denies.partition { |rule| rule.fetch("reason") != Rho::RunDeclaration::INCUBATION }
    assert_equal 31, constant.length, "twenty-nine deny rules and the two allow rules — the constant of this version"
    assert_equal constant.length + 6, rules.length, "plus three self-modification denies per root"
    assert_equal [{ "tool" => Rho::RunDeclaration::READ_ONLY_TOOLS, "verdict" => "allow" },
                  { "tool" => "memory_*|ask|delegate_task|code|tool_search|tool_call|runners_list|skill|todo_write|session_search|session_read", "verdict" => "allow" }], allows,
      "the runner's reads, the kernel tools, the skill load and the todo tracker's write run under `ask` and " \
      "`rules`; inert under `bypass`"
    assert_equal constant.last, allows.last, "the kernel allow rule closes the constant"
    # THE IMAGE TOOL'S FAMILY: a write on the OPEN
    # world — one network call, one file — is named in NO allow row under
    # either spelling, exactly as `write` and `web_fetch` are not: it runs
    # under `bypass`, parks under `ask` and is refused under `rules` until
    # a rule of the person's allows it.
    allowed = allows.flat_map { |rule| rule.fetch("tool").split("|") }
    [Rho::Extensions::Images::ImageGenerate::NAME, Rho::Extensions::Images::Imagegen::NAME].each do |name|
      refute_includes allowed, name, "#{name} is an effect; no allow row names it"
    end
    guard_denies.each do |rule|
      assert_equal %w[tool path match verdict reason], rule.keys, rule.inspect
      assert_equal Rho::RunDeclaration::GUARDED_TOOLS, rule.fetch("tool")
      assert_equal "command", rule.fetch("path")
      refute_empty rule.fetch("reason"), "a deny carries the sentence the model reads: #{rule.inspect}"
    end
    assert_equal 6, self_denies.length
    assert_equal Rho::Extensions::Guard::GUARDED_TOOLS, Rho::RunDeclaration::GUARDED_TOOLS.split("|"),
      "two spellings of one fact: the kernel's `|` glob and the runner's array"
    reasons = Rho::Extensions::Guard::RULES.map(&:last)
    assert_equal reasons, guard_denies.map { |rule| rule.fetch("reason") }.uniq,
      "every Guard sentence, verbatim and in the Guard's order — model-facing names are load-bearing"
    assert constant.frozen? && rules.all?(&:frozen?)

    GuardTest::REFUSED.each do |command|
      denied = denied_by_rule?(guard_denies, command) || !Rho::Extensions::Guard.refusal_for(command).nil?
      assert denied, "neither the rules nor the floor refuse: #{command.inspect}"
    end
    GuardTest::ALLOWED.each do |command|
      refute denied_by_rule?(denies, command), "over-refused by a rule: #{command.inspect}"
    end
    # The guard lane's two spellings are the KERNEL's to refuse (never
    # dispatched), plain and behind a `cd`.
    ["git push --force origin main", "cd x && git push --force", "rm -rf /"].each do |command|
      assert denied_by_rule?(denies, command), "the kernel must refuse #{command.inspect} before any runner"
    end
  end

  # THE READS ROW IS READ-ONLY BY CONSTRUCTION: every
  # tool it names declares `kind: read_only` on the CLOSED world on this
  # machine's registry — rho-runner's `read|grep|ls|find` and the process
  # reads — and every such tool the registry declares is in the row, so a
  # new local read parks under `ask` until it is named here, and a write
  # can never ride the row. `bash` is a command (a `cat` is not a read
  # tool); the memory reads are the kernel's, inside `memory_*`. The
  # narrowing to `world == "closed"` is web_fetch's: a
  # `read_only` tool on the OPEN world is never named here.
  def test_the_reads_allow_row_names_exactly_the_registrys_closed_world_read_only_tools
    named = Rho::RunDeclaration::READ_ONLY_TOOLS.split("|")
    assert_equal %w[read grep ls find file_import file_publish read_process list_processes read_schedules list_extensions], named
    named.each do |name|
      profile = registry.effect_profile(name)
      refute_nil profile, "#{name} is not a tool this registry declares"
      assert_equal "read_only", profile.fetch("kind"), "#{name} is not read-only by construction: #{profile.inspect}"
      assert_equal "closed", profile.fetch("effect_scope"), "#{name} reaches outside this machine: #{profile.inspect}"
      refute profile.fetch("destructive"), name
    end
    # The person's reads through the call_tool are never a model's row
    # to allow: hidden by name, granted by the seed's own origin.
    read_only = registry.names.select do |name|
      profile = registry.effect_profile(name)
      profile&.fetch("kind") == "read_only" && profile.fetch("effect_scope") == "closed"
    end - Rho::RunDeclaration.undeclared - ["skill"]
    assert_equal read_only.sort, named.sort, "a read-only tool the row does not name, or a name the registry lacks"
    refute_includes named, "bash"
  end

  # THE OPEN WORLD'S READ IS ABSENT FROM THE ROW — the tool's declared scope,
  # cross-pinned: `rho/web-tools` loaded explicitly (the gem is a path dependency, as rho-mcp
  # is; the default set never loads it) announces `web_fetch` as `read_only` on the OPEN
  # world, and the row does not name it — so it runs under `bypass`, parks under `ask`,
  # and is refused under `rules` until a rule allows it.
  def test_the_open_worlds_read_is_read_only_open_and_absent_from_the_reads_row
    with_web = Rho::Extensions.load(host: RhoTest.host, gems: ["rho/web-tools"])
    assert_predicate with_web, :ok?, with_web.failures.inspect
    profile = with_web.registry.effect_profile("web_fetch")
    assert_equal({ "kind" => "read_only", "destructive" => false, "effect_scope" => "open",
                   "idempotency" => "intrinsic", "reconciliation" => "none" }, profile)
    refute_includes Rho::RunDeclaration::READ_ONLY_TOOLS.split("|"), "web_fetch"
    rules = Rho::RunDeclaration::APPROVAL_RULES
    refute rules.any? { |rule| rule["tool"].to_s.split("|").include?("web_fetch") },
      "web_fetch has a rule of its own; an ask row would defeat every allow, an allow row would skip the park"
  ensure
    Rho::WebTools.reset! if defined?(Rho::WebTools)
  end

  def denied_by_rule?(denies, command)
    denies.any? { |rule| glob(rule.fetch("match")).match?(command) }
  end

  # The mirror of `Executors::Rules::Glob.compile` (nexus).
  def glob(pattern)
    escaped = pattern.split(/([*?])/).map do |piece|
      case piece
      when "*" then ".*"
      when "?" then "."
      else Regexp.escape(piece)
      end
    end.join
    Regexp.new("\\A#{escaped}\\z", Regexp::MULTILINE)
  end

  # ONE DIGEST per set of bytes — what decides whether the profile is
  # written again — the same whatever order the sets came in.
  def test_the_digest_reads_the_bytes_not_the_order
    a = Rho::RunDeclaration.tool_entries([NexusDoubles.served_tool("a")])
    b = Rho::RunDeclaration.tool_entries([NexusDoubles.served_tool("b")])

    assert_equal Rho::RunDeclaration.digest(a + b), Rho::RunDeclaration.digest(b + a)
    refute_equal Rho::RunDeclaration.digest(a), Rho::RunDeclaration.digest(b)
    assert_kind_of String, Rho::RunDeclaration.digest([])
  end

  # THE REMOTE LEAD: the announced SNAPSHOT's
  # fragments and nothing else — no per-tool lines (the descriptions ride
  # the schema), no guideline (that is the profile's `system_prompt` slot)
  # — or the caller's own words; a runner that announced no fragment has
  # NO lead, and an empty lead sends no inline entry.
  def test_the_remote_lead_is_the_announced_snapshot_alone
    environment = NexusDoubles.remote_runner("0199-h", root: "/srv/x").fetch("environment")

    assert_equal "Relative paths resolve against /srv/x.", Rho::RunDeclaration.remote_lead(environment)
    assert_equal "Relative paths resolve against /srv/x.\n\nBe brief.",
      Rho::RunDeclaration.remote_lead(environment, instructions: "Be brief.")
    assert_equal "", Rho::RunDeclaration.remote_lead({}), "a runner that announced no fragment"
    assert_equal "", Rho::RunDeclaration.remote_lead(nil)
  end

  def test_kernel_environment_leads_keep_bound_roots_and_hints_without_duplicate_fragments
    environment = Rho::Runner::Environment.local(root: "/runner/default")
    lead = Rho::RunDeclaration.lead(registry: registry, environment: environment, kernel_environment: true,
      root: "/project", directories: ["/shared"], instructions: "Use the editor.", hints: ["Check the result."])
    expected = "This conversation's root is /project; relative paths resolve against it there.\nAdditional directories: /shared\n\nUse the editor.\n\nCheck the result."
    assert_equal expected, lead
    snapshot = { "fragments" => [{ "text" => "Runner environment snapshot." }] }
    assert_equal expected, Rho::RunDeclaration.remote_lead(snapshot, kernel_environment: true,
      root: "/project", directories: ["/shared"], instructions: "Use the editor.", hints: ["Check the result."])
    assert_equal "", Rho::RunDeclaration.remote_lead(snapshot, kernel_environment: true)
    assert_equal Rho::RunDeclaration.tool_lines(registry),
      Rho::RunDeclaration.lead(registry: registry, environment: environment, kernel_environment: true)
  end

  # Raw seeds keep the environment across compaction, behind stable guidance.
  def test_the_standalone_instructions_start_with_stable_guidance
    environment = NexusDoubles.remote_runner("0199-h", root: "/srv/x").fetch("environment")
    [Rho::RunDeclaration.instructions(registry: registry), Rho::RunDeclaration.remote_instructions(environment)].each do |text|
      assert_includes text, "Conversation kind: standalone."
      refute_includes text, "{{conversation_kind}}"
    end

    assert_equal "#{Rho::RunDeclaration::GUIDELINE}\n\nConversation kind: standalone.\n\nRelative paths resolve against /srv/x.",
      Rho::RunDeclaration.remote_instructions(environment)
    assert_equal "Be brief.\n\nRelative paths resolve against /srv/x.",
      Rho::RunDeclaration.remote_instructions(environment, instructions: "Be brief.")
    assert_equal "#{Rho::RunDeclaration::GUIDELINE}\n\nConversation kind: standalone.", Rho::RunDeclaration.remote_instructions({})
    assert_equal "#{Rho::RunDeclaration::GUIDELINE}\n\nConversation kind: standalone.", Rho::RunDeclaration.remote_instructions(nil)

    local = Rho::RunDeclaration.instructions(registry: registry)
    assert_equal "#{Rho::RunDeclaration::GUIDELINE}\n\nConversation kind: standalone.\n\n#{Rho::RunDeclaration.lead(registry: registry)}", local,
      "the stable guideline precedes the variable lead"
    assert_equal "Be brief.", Rho::RunDeclaration.instructions(registry: registry, instructions: "Be brief.")
  end

  # THE GUIDELINE NAMES RHO'S OWN TOOLS: the runner facts that left
  # the kernel's `task` bytes — a file or a few greps are your own work,
  # `start_process` is for a server — live here, in rho's `system_prompt`
  # slot, under rho's names; a name the guideline quotes that rho does not
  # declare is worse than none, so every backticked identifier is one this
  # registry declares (the six kernel memory tools are the exception). The guideline is
  # style-neutral: it never spells a kernel tool a preset re-spells.
  def test_the_guideline_quotes_only_tools_rho_declares_and_no_aliasable_kernel_word
    quoted = Rho::RunDeclaration::GUIDELINE.scan(/`([a-z_]+)`/).flatten.uniq
    kernel = %w[memory_read memory_write memory_edit memory_ls memory_grep memory_delete]

    assert_includes quoted, "read"
    assert_includes quoted, "grep"
    assert_includes quoted, "start_process"
    assert_includes quoted, "bash"
    assert_empty quoted - kernel - registry.names, "a name rho does not declare"
    assert_empty quoted & CybrosAgent::ModelAdaptations.load.presets.plain.values,
      "a preset re-spells these: the slot cannot follow an alias"
    assert_includes Rho::RunDeclaration::GUIDELINE, "never for a command whose result you need"
  end

  # THE CONVERSATION LEAD: the developer-role entry a turn
  # opens with — the environment block, then the tool lines (the operator
  # sentence, the per-tool snippets, the per-tool guidelines) — what
  # changes per turn and per runner, behind history and outside the stable
  # prefix; the guideline is the profile's slot and never rides here.
  def test_the_conversation_lead_is_the_environment_then_the_tool_lines_and_never_the_guideline
    Dir.mktmpdir do |root|
      environment = Rho::Runner::Environment.local(root: root, working_directory: root)
      lead = Rho::RunDeclaration.lead(registry: registry, environment: environment)

      assert lead.start_with?("Relative paths resolve against #{root}."), lead
      assert_includes lead, "\n\nYou are working on the operator's own machine through these tools:\n- bash: "
      assert lead.end_with?("start_process, never `&`."), "the last tool line closes it"
      refute_includes lead, Rho::RunDeclaration::GUIDELINE
      assert_equal Rho::RunDeclaration.tool_lines(registry), Rho::RunDeclaration.lead(registry: registry),
        "no environment: the tool lines alone"
      block = Rho::RunDeclaration.environment_block(registry, environment)
      assert_equal "#{block}\n\nBe brief.",
        Rho::RunDeclaration.lead(registry: registry, environment: environment, instructions: "Be brief."),
        "the caller's words in the tool lines' place; the environment still leads"
    end
  end

  # THE HINTS: the turn row's
  # `lead_hints` texts ride every lead AFTER the tool lines (or the
  # caller's words) — per request, developer-role, outside the stable
  # prefix — one line each, verbatim. Raw seeds keep them behind stable guidance;
  # an empty hint list adds no block.
  def test_the_hints_ride_after_the_tool_lines_and_stable_raw_guidance
    hints = ["Do not wait for a detached call.", "Name every file you read."]
    block = "Do not wait for a detached call.\nName every file you read."
    lines = Rho::RunDeclaration.tool_lines(registry)
    environment = NexusDoubles.remote_runner("0199-h", root: "/srv/x").fetch("environment")

    assert_equal "#{lines}\n\n#{block}", Rho::RunDeclaration.lead(registry: registry, hints: hints)
    assert_equal "Be brief.\n\n#{block}", Rho::RunDeclaration.lead(registry: registry, instructions: "Be brief.", hints: hints)
    assert_equal lines, Rho::RunDeclaration.lead(registry: registry, hints: []), "no hint, no block"
    assert_equal "#{Rho::RunDeclaration::GUIDELINE}\n\nConversation kind: standalone.\n\n#{lines}\n\n#{block}",
      Rho::RunDeclaration.instructions(registry: registry, hints: hints), "the standalone seed keeps hints behind stable guidance"
    assert_equal "Be brief.\n\n#{block}", Rho::RunDeclaration.instructions(registry: registry, instructions: "Be brief.", hints: hints)
    assert_equal "Relative paths resolve against /srv/x.\n\n#{block}", Rho::RunDeclaration.remote_lead(environment, hints: hints)
    assert_equal "#{Rho::RunDeclaration::GUIDELINE}\n\nConversation kind: standalone.\n\nRelative paths resolve against /srv/x.\n\n#{block}",
      Rho::RunDeclaration.remote_instructions(environment, hints: hints)
    assert_equal block, Rho::RunDeclaration.remote_lead(nil, hints: hints), "a runner with no snapshot still carries the hints"
    step, = Rho::RunDeclaration.steps(runner_executor_public_id: "own-runner", prompt: "p", model: "m/x", registry: registry, hints: hints)
    assert step.instructions.end_with?("\n\n#{block}"), "the seed's system field carries the hints last"
  end

  def test_steps_keep_remote_sources_separate_and_preserve_raw_instructions
    kernel = %w[nexus.graph.delegate_task]
    served = [NexusDoubles.served_tool("slow_read")]
    instructions = Rho::RunDeclaration.remote_instructions(NexusDoubles.remote_runner("0199-h").fetch("environment"))

    step, = Rho::RunDeclaration.steps(runner_executor_public_id: "own-runner", prompt: "p", model: "m/x", registry: registry, served: served,
      instructions: instructions, kernel_tools: kernel, runner_executor_public_ids: %w[own-runner other-runner])

    assert_equal kernel, step.kernel_tools
    assert_equal %w[own-runner other-runner], step.runner_executor_public_ids
    assert_nil step.runner_tool_names
    assert_equal %w[list_extensions manage_extension manage_schedule read_schedules todo_write], step.tools.map { |entry| name_of(entry) }
    assert_equal instructions, step.instructions
    assert step.instructions.start_with?(Rho::RunDeclaration::GUIDELINE), "the standalone seed keeps its stable guidance first"
  end
end
