require "test_helper"

# The kernel's tool registry — the binding axis. Its value is that FOUR
# doors read ONE list, so the tests here are mostly about the doors
# agreeing rather than about the data.
class Nexus::ToolRegistryTest < ActiveSupport::TestCase
  Registry = Nexus::ToolRegistry
  # Every live wire name, in registry order: the words a macro may spell.
  KERNEL_WIRE_NAMES = Registry::LIVE.values.map(&:name).freeze

  test "every name is canonical, sourced here, and reachable in both spellings" do
    Registry::LIVE.keys.each do |canonical|
      assert_match Registry::CANONICAL_NAME_FORMAT, canonical
      assert_equal Registry::SOURCE, canonical.split(".").first,
        "the source segment is the authority that EXECUTES the tool"
      assert_equal canonical, Registry.resolve(canonical)
    end
    Registry::WIRE_ALIASES.each do |wire, canonical|
      assert_equal canonical, Registry.resolve(wire)
    end
  end

  # A wire name that resolves two ways is a call nobody can route.
  test "wire names do not collide" do
    wires = Registry::LIVE.each_value.map(&:name)
    assert_equal wires.length, wires.uniq.length
  end

  # The conversation family is LIVE whole under their bare wire words — never a mechanical
  # `conversation_send` spelling.
  test "the conversation verbs are live under their wire words" do
    %w[spawn send status cancel].each do |wire|
      assert_equal "nexus.conversation.#{wire}", Registry.resolve(wire), wire
      assert Registry.kernel_name?(wire), "#{wire} is un-authorable, and LIVE: it has its executor"
      refute Registry.overridable?(wire), "live under a reserved namespace: no provider serves it"
      assert_nil Registry.resolve("conversation_#{wire}"), "no mechanical spelling resolves"
    end
    assert_equal AgentLoops::Spawn::Run, Registry.executor_for("spawn")
    %w[send status cancel].each do |wire|
      assert_equal AgentLoops::ConversationTool::Run, Registry.executor_for(wire), "one executor keyed by verb"
    end
    assert_equal Registry::GRAPH_WRITE, Registry.effect_profile_for("send")
    assert_equal Registry::GRAPH_WRITE, Registry.effect_profile_for("cancel")
    assert_equal Registry::READ_ONLY_CLOSED, Registry.effect_profile_for("status"), "a read touches nothing"
    assert_nil Registry.resolve("read")
  end

  test "every live entry declares one complete, coherent effect profile" do
    Registry::LIVE.each_key do |canonical|
      profile = Registry.effect_profile_for(canonical)
      assert_equal Registry::EFFECT_KEYS.sort, profile.keys.sort
      assert_includes Registry::EFFECT_KINDS, profile["kind"]
      assert_includes Registry::EFFECT_WORLDS, profile["world"]
      assert_includes Registry::IDEMPOTENCY_KINDS, profile["idempotency"]
      assert_includes Registry::RECONCILIATION_KINDS, profile["reconciliation"]
      assert_includes [true, false], profile["destructive"]
      refute profile["destructive"] && profile["kind"] == "read_only",
        "#{canonical}: a read cannot destroy"
    end
  end

  # The provider wire shape is exactly name/description/parameters.
  # Effect metadata is OURS; sending it would be both noise and a leak of
  # how the kernel classifies its own recovery.
  test "the wire schema carries nothing but what a provider reads" do
    schema = Registry.wire_schema_for("compose")
    assert_equal %w[name description parameters], schema.keys
    assert_equal schema, Nexus::Compose::DEFINITION.fetch("function"),
      "one home for the bytes - the tools block is the front of the cached prefix"
  end

  test "the flat verbs publish the registry's bytes" do
    assert_equal Registry.function_definition("nexus.graph.task"), Nexus::Tools::TASK
    assert_equal Registry.function_definition("nexus.human.ask"), Nexus::Tools::ASK
    assert_equal false, Nexus::Tools::ASK.dig("function", "parameters", "additionalProperties"),
      "one field name on every surface: a second spelling is refused, not dropped"
  end

  # THE KERNEL'S BYTES NAME NO RUNNER TOOL: a runner's tools are the runner's to describe (rho's
  # guideline names `read`/`grep`/`start_process` in its own prose), so every backticked identifier
  # in a live description is a kernel wire name, a parameter of a live tool, an envelope
  # attribute the text explains, or an answer word an example's prompt asks for. The cross-tree
  # half — none of them is a name rho declares — is the e2e harness's (`kernel_tool_names_test`).
  test "every backticked identifier in a live description is the kernel's own word" do
    parameters = Registry::LIVE.values.flat_map(&:parameter_names)
    attributes = %w[conversation task] # the `<task_result>` envelope's, explained by the texts
    # Compose's builder options and the selected-result envelope are kernel-owned.
    script_words = %w[g after results status is_error output content structured_content error]
    answers = %w[ship hold] # the panel example's reviewers answer one of the two
    Registry::LIVE.each_value do |tool|
      quoted = tool.description.scan(/`([a-z_]+)`/).flatten.uniq
      assert_empty quoted - KERNEL_WIRE_NAMES - parameters - attributes - script_words - answers,
        "#{tool.name}: a backticked word that is not the kernel's — a runner's name would be a cached-prefix leak"
    end
    refute Registry.const_defined?(:QUOTED_RUNNER_TOOLS), "the quoted-runner list went with the bytes"
  end

  # A RACE IS NAMED, NEVER ITS MEMBERS: the reference rule says a race is a valid reference and why
  # a member is not, with the spelling, and that a model reading it tells the selected tool results
  # apart by their calls; the stage envelope says what a race's slot holds — the failure on top when
  # the race failed, and after its partial winners in `selected`.
  test "the compose text names a race as a reference and says what a stage reads for it" do
    description = Registry.wire_schema_for("compose").fetch("description")
    assert_includes description, "Only preceding leaf handles and races from this script are valid,\n" \
      "never an \"all\" group, a string key, a future step, or a task from an\n" \
      "earlier call. A race stops the members it did not select, so a later\n" \
      "step names the race, never one of its members:\n" \
      "`const race = g.parallel([a, b, c], { until: \"any\" })`, then\n" \
      "`results: [race]` reads what the race selected. A model step reading it\n" \
      "sees each selected tool result named by its call, so a race's members\n" \
      "need no extra step to name them.\nTo observe work from an earlier call"
    assert_includes description, "and `error`.\nFor a race, `results[i]` is the first envelope it selected, or the\n" \
      "race's failure when it failed; `results[i].selected` lists what it\n" \
      "hands you, first finisher first, a failure last.\nCheck failure before parsing."
  end

  # A STEP READS ONLY WHAT IT IS HANDED: `results:` is the whole read of a model or a script, a step
  # naming nothing reads its prompt alone, and what no step reads comes back to the caller — no
  # sentence says a step reads what ran before it.
  test "the compose text says a step reads only the results it is handed" do
    description = Registry.wire_schema_for("compose").fetch("description")
    assert_includes description, "inside one g.parallel([...]) run at the same time.\n" \
      "A STEP READS ONLY WHAT YOU HAND IT. `results: [a, b]` on a model or\n" \
      "script hands that step the results of a and b, in that order"
    assert_includes description, "A model step without `results:` reads its\n" \
      "prompt alone, whatever ran before it: nothing reaches a step by\n" \
      "position, and no step sees another step's conversation. Every result\n" \
      "no step reads comes back to you.\n"
    refute_includes description, "back to the previous model step"
    refute_includes description, "accumulated results"
  end

  # A DELIVERED RESULT NAMES ITS CALL: the envelope's `<call>` line is stated right after the read
  # sentences, so the composing model need not author its own label to tell those results apart.
  test "the compose text says every tool result names the call that produced it" do
    description = Registry.wire_schema_for("compose").fetch("description")
    assert_includes description, "Neither `results:` nor `after:` removes the waits of written order.\n" \
      "Every tool result, read by a model step or delivered to you, names the\n" \
      "call that produced it: the tool and the start of its input.\n" \
      "Only preceding leaf handles and races"
  end

  # ── the tool-name macros ─────────────────────────── A description names a kernel tool as
  # `{{task}}`, and the PLAIN render spells every macro as the kernel's wire name — so the shipped
  # bytes are the template's with the braces gone, and a profile that declares an alias re-spells
  # them at declaration. The un-backticked prose mentions that are NOT the tool — "The task runs in
  # the background", "the task's id", "the kernel runs", "Ask the person" — stay literal text.
  test "the plain render is the template with every macro spelled plain, and macros are kernel wire names" do
    Registry::LIVE.each_value do |tool|
      assert_equal tool.description, Nexus::ToolDeclarations::Render.plain(tool.template)
      refute_includes tool.description, "{{", "#{tool.name}: a macro survived the plain render"
      # Every macro is a LIVE wire name (the `spawn` text names `send`/`status`/`cancel` as tools).
      tool.template.scan(Registry::MACRO).flatten.each do |word|
        assert_includes KERNEL_WIRE_NAMES, word,
          "#{tool.name}: `{{#{word}}}` is not a kernel wire name"
      end
      # "`task` attribute" is the <task_result> envelope's, not the tool.
      assert_empty tool.template.scan(/`(?:compose|task|ask|spawn|memory_\w+)`(?! attribute)/),
        "#{tool.name}: a backticked kernel name outside a macro would not follow an alias"
    end
    assert_equal %w[compose wait task ask spawn send status cancel
                    memory_read memory_write memory_edit memory_ls memory_grep memory_delete skill session_search session_read],
      KERNEL_WIRE_NAMES
  end

  test "the macros the texts use are the words the texts name as the tool, and no runner name is ever a macro" do
    macros = Registry::LIVE.values.flat_map { |tool| tool.template.scan(Registry::MACRO).flatten }.uniq.sort
    assert_equal %w[ask cancel compose memory_edit memory_write send session_read session_search skill spawn status task wait], macros,
      "every macro is a kernel wire name; a runner's tool has no alias mechanism and never appears here"
    assert_includes Registry.entry("task").parameters.dig("properties", "tools", "description"),
      "except task and compose", "a parameter description is a template too, rendered plain here"
  end

  # A MODEL WITHOUT COMPOSE STILL READS EVERY OTHER KERNEL TEXT: an agent may declare every kernel
  # tool but compose, or narrow one turn to that set for a model that should not drive it, and the
  # render spells a macro whether or not its tool is declared — so a compose directive in another
  # text would send that model to a tool it does not have. Outside its own text, compose is named
  # only to exclude it from what a task inherits: in every template, where each declaration's render
  # starts, and in the render of a set without compose, under the plain names and under an alias of
  # task.
  test "outside its own text compose is named only to exclude it, so a set without compose directs no model to it" do
    others = Registry::LIVE.values.reject { |tool| tool.name == "compose" }
    others.each do |tool|
      [tool.template, *tool.parameter_template.fetch("properties").values.filter_map { |property| property["description"] }]
        .each do |text|
          assert_equal text.scan(Registry::MACRO).flatten.count("compose"),
            text.scan(/except `?\{\{task\}\}`? and `?\{\{compose\}\}`?/).length,
            "#{tool.name}: {{compose}} outside the tools a task inherits"
        end
    end

    plain = others.map(&:function_definition)
    agent = { "name" => "Agent", "canonical" => "nexus.graph.task" }
    { "task" => plain, "Agent" => [agent, *plain.reject { |entry| entry.dig("function", "name") == "task" }] }
      .each do |task, set|
        texts = Nexus::ToolDeclarations.render(set).flat_map do |entry|
          function = entry.fetch("function")
          [function.fetch("description"),
           *function.dig("parameters", "properties").values.filter_map { |property| property["description"] }]
        end
        mentions = texts.sum { |text| text.scan(/\bcompose\b/).length }
        assert_equal 2, mentions, "#{task}: the task text and its tools parameter"
        assert_equal mentions, texts.sum { |text| text.scan(/except `?#{task}`? and `?compose`?/).length },
          "#{task}: every compose a set without it reads excludes compose from what a task inherits"
      end
  end

  test "parameter_names lists a tool's declared properties" do
    assert_equal %w[prompt lifetime wake wait tools], Registry.entry("task").parameter_names
    assert_equal %w[script params lifetime wake wait], Registry.entry("compose").parameter_names
    assert_equal %w[prompt options multi], Registry.entry("ask").parameter_names
    assert_equal %w[prompt agent label lifetime wake wait model], Registry.entry("spawn").parameter_names
    assert_equal %w[to agent message steer deliver_in deliver_at wake model], Registry.entry("send").parameter_names
    assert_equal %w[task agent_loop timeout_ms], Registry.entry("wait").parameter_names
    assert_equal %w[to], Registry.entry("status").parameter_names
    assert_equal %w[to], Registry.entry("cancel").parameter_names
    assert_equal %w[name], Registry.entry("skill").parameter_names
  end

  test "delegation tools expose independent inherited lifetime without changing message tools" do
    %w[task compose spawn].each do |name|
      properties = Registry.entry(name).parameters.fetch("properties")
      assert_equal %w[turn conversation], properties.fetch("lifetime").fetch("enum")
      assert_not properties.fetch("lifetime").key?("default"), "omission inherits the calling execution"
      assert_equal false, properties.fetch("wait").fetch("default")
    end
    %w[send status cancel ask].each do |name|
      assert_not Registry.entry(name).parameter_names.include?("lifetime")
    end
  end

  # Plain rendering resolves spawn's send/status/cancel macros to their bare names. Keeping the
  # resulting sentence stable preserves the cached prefix when these verbs are declared.
  test "the spawn text's plain render is byte-stable across the verbs going live" do
    description = Registry.entry("spawn").description
    assert_includes description, "you can `send` it more messages, read its `status`,\nand `cancel` it."
    refute_includes description, "{{"
  end

  # ── the reserved namespaces ────────────────

  test "the reserved namespaces are the three no external party can implement" do
    assert_equal %w[nexus.graph nexus.human nexus.conversation], Registry::RESERVED_NAMESPACES
    assert_predicate Registry::RESERVED_NAMESPACES, :frozen?
    assert_equal "nexus.memory", Registry.namespace("nexus.memory.read")
    assert_equal "nexus.conversation", Registry.namespace("nexus.conversation.spawn")
  end

  # Every live name is exactly one of reserved, overridable or ROUTED BY SOURCE: the door that
  # loosens (the announcement) partitions on this and nothing else, and `routed_by_source?` is the
  # ONE classifier the other two predicates derive from.
  test "every live name is exactly one of reserved, overridable or routed by source" do
    Registry::LIVE.each_key do |canonical|
      classes = [Registry.reserved_namespace?(canonical), Registry.overridable?(canonical),
                 Registry.routed_by_source?(canonical)]
      assert_equal 1, classes.count(true), "#{canonical}: reserved/overridable/routed = #{classes.inspect}"
    end
    reserved, rest = Registry::LIVE.keys.partition { |name| Registry.reserved_namespace?(name) }
    routed, overridable = rest.partition { |name| Registry.routed_by_source?(name) }
    assert_equal %w[nexus.conversation.cancel nexus.conversation.read nexus.conversation.search nexus.conversation.send nexus.conversation.spawn nexus.conversation.status
                    nexus.graph.compose nexus.graph.task nexus.graph.wait nexus.human.ask], reserved.sort
    assert_equal %w[nexus.memory.delete nexus.memory.edit nexus.memory.grep nexus.memory.ls
                    nexus.memory.read nexus.memory.write], overridable.sort
    assert_equal %w[nexus.skill.load], routed
    assert_equal %w[nexus.skill], Registry::ROUTED_BY_SOURCE
    assert_predicate Registry::ROUTED_BY_SOURCE, :frozen?
    assert Registry.routed_by_source?("nexus.skill.load")
    assert_not Registry.routed_by_source?("nexus.memory.read")
    assert_not Registry.overridable?("skill"), "a source-routed name is never a workspace's to override"
    assert Registry.kernel_name?("skill"), "but it is live: the door admits it and the kernel executes it"
  end

  # THE SKILL LOAD'S BYTES: the text points at the assembly's `skills` block through the one
  # constant the block's header opens with, the parameter sentence names the same list, the tool
  # names itself only through the macro (an alias such as `Skill` renders it as its own name) and
  # backticks nothing — rho-runner announces a `skill` of its own, and the cross-tree pin fails any
  # kernel text that quotes a name rho declares.
  test "the skill entry quotes the catalog header through one constant and backticks nothing" do
    tool = Registry.entry("nexus.skill.load")
    assert_equal "skill", tool.name
    assert_equal Registry::READ_ONLY_CLOSED, tool.effect_profile
    assert_equal "AgentLoops::Memory::Run", tool.executor, "the kernel's own skills/ rows answer it (Memory::Run#skill)"
    assert_equal "AgentLoops::MemoryJob", tool.job
    assert_equal %w[name], tool.parameter_names
    assert_equal ["name"], tool.parameters.fetch("required")
    assert_equal "Skills available now", Nexus::Skills::CATALOG_TITLE
    assert Nexus::Skills::CATALOG_HEADER.start_with?(Nexus::Skills::CATALOG_TITLE)
    assert_includes tool.description, "from the \"Skills available now\" list"
    assert_equal "The exact skill name from the \"Skills available now\" list.",
      tool.parameters.dig("properties", "name", "description")
    assert_includes tool.template, "call {{skill}} with the exact name"
    assert_includes tool.description, "call skill with the exact name"
    assert_empty tool.description.scan(/`[^`]+`/), "no backticked word: rho announces a tool named skill"
    assert_equal Registry.function_definition("skill"), Nexus::Tools::SKILL
    assert_equal "skill", KERNEL_WIRE_NAMES.fetch(14)
  end

  # The override's two vocabularies: the namespaces a workspace may name, and the wire names a
  # provider must announce whole. The source-routed namespace is subtracted with the reserved set.
  test "overridable_namespaces is LIVE minus the reserved set, and wire_names_in lists a namespace's live names" do
    assert_equal ["nexus.memory"], Registry.overridable_namespaces
    assert_equal %w[skill], Registry.wire_names_in("nexus.skill")
    assert_equal %w[memory_read memory_write memory_edit memory_ls memory_grep memory_delete].sort,
      Registry.wire_names_in("nexus.memory").sort
    assert_equal %w[compose task wait], Registry.wire_names_in("nexus.graph").sort
    assert_equal [], Registry.wire_names_in("nexus.nothing")
  end

  test "overridable? reads both spellings and answers false for an unregistered name" do
    assert Registry.overridable?("memory_read")
    assert Registry.overridable?("nexus.memory.read")
    refute Registry.overridable?("compose")
    refute Registry.overridable?("nexus.graph.compose")
    refute Registry.overridable?("read_file")
    refute Registry.overridable?(nil)
  end

  test "every live entry names the service that answers the call and the job it runs in" do
    Registry::LIVE.each_key do |canonical|
      executor = Registry.executor_for(canonical)
      assert executor, "#{canonical} is live with no executor"
      assert_respond_to executor, :call
      assert_operator Registry.job_for(canonical), :<, ApplicationJob, "#{canonical} names no kernel job"
    end
  end

  test "a name nobody registered resolves to nothing" do
    %w[read_file nexus.graph.invent memory_writ compose_extra memory_list memory_forget].each do |name|
      assert_nil Registry.resolve(name), name
      refute Registry.kernel_name?(name), name
    end
  end
end
