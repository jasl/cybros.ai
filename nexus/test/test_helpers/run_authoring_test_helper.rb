# The authoring vocabulary in tests: the four verbs as the door reads them, key-first so a fixture
# reads as `model("plan")`, with string overrides in the wire's own words; `seed` creates through
# the real front door and `grow` appends through the one append door. Kernel cases build a `Tip`.
# Every loop it creates is born bound to an announcer: a runner-tool call on a loop nobody serves
# fails `tool_not_served` at start, so the helper connects one account-wide runner serving the
# suites' vocabulary and NAMES it on the create — the kernel infers no runner (r-modes M6); a case
# that names another, or none, says so.
module RunAuthoringTestHelper
  MOCK_MODEL = { "model" => "dev/mock-text" }.freeze

  WRITE_PROFILE = {
    "kind" => "write", "destructive" => true, "effect_scope" => "open",
    "idempotency" => "none", "reconciliation" => "none",
  }.freeze
  # The tool names the unit suites start, announced by `suite_runner`. A new
  # tool name a test starts is added HERE or announced in that test;
  # `tool_not_served` is the failure you get otherwise.
  TEST_SERVED_TOOLS = (
    %w[read_file probe x t clip tiny search read strict_default bounded avatar a answer reply
       read_the_internet read_process].map { |name|
      { "name" => name, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }
    } + %w[bash write shell write_file].map { |name|
      { "name" => name, "effect_profile" => WRITE_PROFILE }
    }
  ).freeze

  # The suites' announcer: one account-wide runner with a transport
  # credential, managed by the owner, named by `create_loop` as the loop's
  # initial binding (Executors::InitialRunner) so every runner-tool node
  # is addressed to it. Built lazily by the create door, never in `setup`:
  # the helper is included in every test, and an executor row in all of
  # them would move the counts the executor suites pin.
  def suite_runner
    @suite_runner ||= begin
      runner = suite_runner_connection.executor_access_token.task_executor
      outcome = runner.announce(tools: TEST_SERVED_TOOLS)
      raise "the test vocabulary was refused: #{outcome.outcome} #{outcome.detail}" unless outcome.accepted?

      runner
    end
  end

  # The ceremony's answer, kept: its `executor_access_secret` is the
  # transport bearer a controller test presents on the executor plane.
  def suite_runner_connection
    @suite_runner_connection ||= connect_runner(
      manager: users(:owner), registration_identifier: "test-runner",
      display_name: "Test runner", assignment_scope: :account_wide
    )
  end

  # A pool member: a credential-ready tools provider announcing `tools` — entries, or bare names
  # given the read-only profile. Never a binding; a name it alone announces is addressed to the
  # pool.
  def connect_provider(identifier:, tools:, manager: users(:owner), assignment_scope: :account_wide)
    provider = connect_runner(
      manager: manager, registration_identifier: identifier, display_name: "Provider #{identifier}",
      assignment_scope: assignment_scope, executor_kind: :tool_provider
    ).executor_access_token.task_executor
    entries = tools.map do |tool|
      tool.is_a?(Hash) ? tool : { "name" => tool, "effect_profile" => Nexus::ToolRegistry::READ_ONLY_CLOSED }
    end
    outcome = provider.announce(tools: entries)
    raise "the provider's announcement was refused: #{outcome.outcome} #{outcome.detail}" unless outcome.accepted?

    provider
  end

  def model(key, **over)
    fields = { "key" => key, "model" => MOCK_MODEL, "prompt" => "p" }.merge(over)
    fields["tools"] = fixture_runner_declarations(fields["tools"]) if fields["tools"]
    { "model" => fields }
  end

  def fixture_runner_declarations(tools)
    tools.map do |entry|
      name = entry.dig("function", "name")
      if !entry.key?("route") && TEST_SERVED_TOOLS.any? { |served| served.fetch("name") == name }
        entry.merge("route" => { "kind" => "runner", "runner_executor_public_id" => suite_runner.public_id,
          "tool_name" => name })
      else
        entry
      end
    end
  end

  def tool(key, name = "shell", **over)
    fields = { "key" => key, "name" => name }
    fields["route"] = { "kind" => "runner" } if TEST_SERVED_TOOLS.any? { |entry| entry.fetch("name") == name }
    { "tool" => fields.merge(over) }
  end

  def ask(key, **over)
    { "ask" => { "key" => key, "prompt" => "?" }.merge(over) }
  end

  # Members are steps or nested Arrays of steps; `until:`, `losers:`, `key:`
  # and `on_failure:` ride as the door spells them.
  def parallel(*members, **over)
    { "parallel" => members }.merge(over.transform_keys(&:to_s))
  end

  # The door's per-step word: a detached step is a branch the envelope does not wait for; its answer
  # reaches the loop by the wake.
  def detached(step)
    verb, fields = step.sole
    { verb => fields.merge("detached" => true) }
  end

  # `approval_mode: "bypass"` is a TEST default and never a production one: the create door refuses
  # nil by name (no silent default); naming the word once here keeps sixty fixtures readable, and a
  # case about the stage names its own mode and rules.
  def create_loop(*steps, workspace: @workspace, creating_user: @human, billing_subject: nil,
                  idempotency_key: nil, default_runner_executor_public_id: suite_runner.public_id,
                  approval_mode: "bypass", **shell)
    AgentRuns::Create.call(AgentRuns::Create::Command.new(
      workspace: workspace, creating_user: creating_user, steps: steps,
      billing_subject: billing_subject, idempotency_key: idempotency_key,
      default_runner_executor_public_id: default_runner_executor_public_id, approval_mode: approval_mode, **shell
    ))
  end

  def seed(*steps, **command)
    result = create_loop(*steps, **command)
    assert_predicate result, :created?, "#{result.outcome}: #{result.errors.inspect}"
    result.agent_run
  end

  def grow(agent_run, *steps, **command)
    AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.authored(
      agent_run: agent_run, steps: steps, **command
    ))
  end

  def grow!(agent_run, *steps, **command)
    result = grow(agent_run, *steps, **command)
    assert_predicate result, :applied?, "#{result.outcome}: #{result.errors.inspect}"
    result
  end

  def kernel_tip(mainline = nil, waits = [], reads = [], mark = AgentRuns::Tasks::Compile::ROUND,
                 detached = false)
    AgentRuns::Tasks::Tip.new(
      mainline: known(mainline), waits: waits.map { |node| known(node) },
      reads: reads.map { |node| known(node) }, mark: mark, detached: detached
    )
  end

  def known(node) = AgentRuns::Tasks::Known.of(node)

  # Exercise general expansion/delivery with explicit kernel steps. Language
  # authoring is tested in the Agent package and does not belong in these fixtures.
  def append_branch!(parent, steps, detached: true)
    result = AgentRuns::Tasks::Append.call(AgentRuns::Tasks::Append::Command.kernel(
      agent_run: parent.agent_run,
      steps: steps.each_with_index.map { |step, index| AgentRuns::Tasks::Step.from_h(step, "steps[#{index}]") },
      tip: AgentRuns::KernelTool.branch_tip(parent).with(detached: detached),
      origin: "model", expansion_parent: parent
    ))
    assert_predicate result, :applied?, result.inspect
    settled = AgentRuns::Parks::Settle.call(node: parent, trusted: true, content: "accepted")
    assert_predicate settled, :applied?, settled.inspect
  end
end
