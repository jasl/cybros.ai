require "test_helper"

# WHAT rho SENDS WHEN IT STARTS A LOOP. Nexus holds no record of what a
# runner can execute — deliberately, because a server-side capability
# record must never influence the per-round tools list — so the
# declarations are CARRIED, and rho is the first thing in this repository
# that can author them.
class RhoLoopRequestTest < Minitest::Test
  def registry
    @registry ||= Rho::Extensions.load(host: RhoTest.host).registry
  end

  # `sole` is ActiveSupport's and this gem has no Rails.
  def sole_step(steps)
    assert_equal 1, steps.length, "expected exactly one step"
    steps.first
  end

  def test_the_step_declares_this_machines_tools_in_the_providers_shape
    step = sole_step(Rho::LoopRequest.steps(
      prompt: "fix the failing test", model: "dev/mock-text", registry: registry
    ))

    assert_instance_of CybrosAgent::Steps::Model, step
    assert_equal "work", step.key
    assert_equal({ "model" => "dev/mock-text" }, step.model)
    names = step.tools.map { |entry| entry.dig("function", "name") }
    assert_equal %w[bash edit file_import file_publish find grep list_processes ls manage_scheduled_job read read_process read_scheduled_jobs start_process stop_process todo_write write],
      names, "sorted, because the tool list is the front of every cached prefix"
    assert_equal "function", step.tools.first.fetch("type")
    assert_equal %w[prompt key model tools instructions], step.to_h.fetch("model").keys,
      "one model step on the wire, no edge and no kind"
  end

  # THE ANNOUNCEMENT: what this machine SERVES, for the
  # kernel to address work by — this machine's tools alone, each with its
  # EFFECT_PROFILE constant and the declaration facts (DESCRIPTION, SCHEMA)
  # a remote agent authors a declaration from; a `timeout_ms` only from the
  # one tool that declares a park of its own (the delegate summarizer), the rest fall to the kernel's default (`bash`'s bound is the
  # runner's setting, honoured under the park). The declaration is the
  # model's fact — and it leaves the delegate out; this is the kernel's,
  # computed from the same registry.
  def test_the_announcement_is_this_machines_tools_with_their_effect_profiles
    announcement = Rho::LoopRequest.announcement(registry: registry)

    assert_equal %w[bash checkpoints edit environment_bind file_import file_publish files_bytes find grep list_processes ls manage_scheduled_job process_log read
                    read_process read_scheduled_jobs skill start_process stop_process summarize_history todo_write world_restore write],
      announcement.map { |entry| entry.fetch("name") }, "sorted by name, and never the kernel's"
    announcement.each do |entry|
      expected_keys = %w[name effect_profile description input_schema]
      # Described to nobody: the name and the profile alone.
      expected_keys = %w[name effect_profile] if %w[files_bytes process_log skill checkpoints world_restore environment_bind].include?(entry.fetch("name"))
      expected_keys += ["timeout_ms"] if %w[manage_scheduled_job read_scheduled_jobs summarize_history todo_write world_restore].include?(entry.fetch("name"))
      assert_equal expected_keys.sort, entry.keys.sort,
        "name, profile and the declaration facts, and a timeout only where one is declared"
      assert_equal registry.effect_profile(entry.fetch("name")), entry.fetch("effect_profile")
      assert_equal Rho::Runner::Extensions::Tool::EFFECT_KEYS, entry.fetch("effect_profile").keys
      registered = registry.entries.find { |candidate| candidate.name == entry.fetch("name") }
      next if registered.undescribed?

      assert_equal registered.description, entry.fetch("description")
      assert_equal registered.schema, entry.fetch("input_schema")
      assert_equal "object", entry.fetch("input_schema").fetch("type")
    end
    assert_equal 120_000, announcement.find { |entry| entry.fetch("name") == "summarize_history" }.fetch("timeout_ms")
    declared = Rho::LoopRequest.tool_entries(Rho::LoopRequest.announcement(registry: registry))
      .map { |entry| entry.dig("function", "name") }
    # The delegate, and the person's two reads: announced
    # and never declared — addressed by policy or by the relay, never
    # offered to a model.
    assert_equal Rho::LoopRequest.undeclared.sort, announcement.map { |entry| entry.fetch("name") } - declared,
      "the delegate is announced and never declared: addressed by policy, never offered to a model"
    assert_equal (declared + Rho::LoopRequest.undeclared).sort, announcement.map { |entry| entry.fetch("name") },
      "the announcement is the declaration's machine half plus the undeclared names"
  end

  # THE ENVIRONMENT DOCUMENT: the root's facts and every
  # provider's fragment, announced beside the list so a remote reader can
  # render the lead this machine renders for itself. The ROOT's, not a
  # request's — no working directory — and no daemon-UI `source`.
  def test_the_environment_document_is_the_roots_facts_and_the_fragments
    Dir.mktmpdir do |root|
      environment = Rho::Runner::Environment.local(root: root)

      document = Rho::LoopRequest.environment_document(registry: registry, environment: environment)

      assert_equal File.expand_path(root), document.fetch("root")
      assert_equal RbConfig::CONFIG["host_os"], document.fetch("platform")
      refute document.key?("working_directory"), "the announced document is the root's"
      refute document.key?("source"), "a daemon-UI fact, not an environment one"
      refute document.key?("branch"), "a tmp dir is no checkout"
      refute document.key?("worktree")
      fragments = document.fetch("fragments")
      assert_equal ["rho.coding"], fragments.map { |fragment| fragment.fetch("extension") }
      assert fragments.first.fetch("text").start_with?("Relative paths resolve against #{File.expand_path(root)}.")
      assert_equal registry.environment_fragments(environment), fragments
    end
  end

  # The fragments every tool has declared and nothing has ever read.
  def test_the_instructions_are_assembled_from_the_tools_own_snippets
    step = sole_step(Rho::LoopRequest.steps(
      prompt: "go", model: "dev/mock-text", registry: registry
    ))

    instructions = step.instructions
    assert_includes instructions, "bash:"
    assert_includes instructions, "read:"
  end

  def test_a_caller_may_state_its_own_instructions
    step = sole_step(Rho::LoopRequest.steps(
      prompt: "go", model: "dev/mock-text", registry: registry, instructions: "Be brief."
    ))

    assert_equal "Be brief.", step.instructions
  end

  # The kernel refuses `tools: []` as a typo'd intent — authoring an empty
  # list reads like disabling something that was never on — so a machine
  # serving nothing authors no tools key at all.
  # THE ENVIRONMENT LEADS, and it rides even when the caller stated its
  # own instructions: an operator who wanted to add one sentence must not
  # silently lose the working directory.
  def test_the_environment_block_leads_the_instructions
    env = Rho::Runner::Environment.local(root: "/tmp/root", working_directory: "/src/app")

    step = sole_step(Rho::LoopRequest.steps(
      prompt: "go", model: "dev/mock-text", registry: registry, environment: env
    ))

    instructions = step.instructions
    assert instructions.start_with?("Relative paths resolve against /tmp/root."),
      "the environment is the first thing the model reads"
    assert_includes instructions, "/src/app"
    assert_includes instructions, "bash:", "the tool preamble still follows it"
    # The describers in load order — coding, processes, conventions — so
    # the block a seed carries is the block it carried before conventions
    # was an extension. Two of them say
    # nothing here: no live process, no AGENTS.md above /src/app.
    describers = Rho::Extensions::DEFAULT_EXTENSIONS.map { |extension| extension::NAME }
    assert_equal %w[rho.processes rho.conventions],
      describers.values_at(describers.index("rho.processes"), describers.index("rho.processes") + 1)
    assert_equal ["rho.coding"], registry.environment_fragments(env).map { |fragment| fragment.fetch("extension") }
  end

  def test_stated_instructions_replace_the_preamble_and_not_the_environment
    env = Rho::Runner::Environment.local(root: "/tmp/root", working_directory: "/src/app")

    step = sole_step(Rho::LoopRequest.steps(
      prompt: "go", model: "dev/mock-text", registry: registry,
      environment: env, instructions: "Be brief."
    ))

    instructions = step.instructions
    assert_includes instructions, "/src/app", "the operator did not ask to lose this"
    assert_includes instructions, "Be brief."
    refute_includes instructions, "bash:", "their words replaced the preamble"
  end

  # NOTHING IS REQUIRED. A loop authored with no directory at all still
  # works — the environment is a statement, not a boundary, and absolute
  # paths go anywhere on the machine regardless.
  def test_a_loop_with_no_directory_still_gets_the_one_fact_that_always_exists
    env = Rho::Runner::Environment.local(root: "/tmp/root")

    instructions = sole_step(Rho::LoopRequest.steps(
      prompt: "go", model: "dev/mock-text", registry: registry, environment: env
    )).instructions

    assert_includes instructions, "Relative paths resolve against /tmp/root."
    refute_includes instructions, "which is NOT that directory"
  end

  def test_no_environment_at_all_authors_the_step_it_always_did
    step = sole_step(Rho::LoopRequest.steps(
      prompt: "go", model: "dev/mock-text", registry: registry
    ))

    refute_includes step.instructions, "Relative paths resolve"
  end

  def test_a_machine_serving_nothing_authors_no_tools_key
    empty = Rho::Runner::Extensions::Loader.call.registry

    step = sole_step(Rho::LoopRequest.steps(
      prompt: "go", model: "dev/mock-text", registry: empty
    ))

    refute step.to_h.fetch("model").key?("tools")
    refute step.to_h.fetch("model").key?("instructions")
  end
end
