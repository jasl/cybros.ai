require "test_helper"
require "tmpdir"

# THE ACCEPTANCE CHECK AS AN EXTENSION: what its two hooks do to a draft
# and to a follower, loaded alone on a fresh handle — the isolation the
# reshape asks of every extension. Round 1 is the
# kernel's now: the paragraph joins the turn's
# lead, and the check is hung below `r1` through the loop door once the
# loop exists.
class UntilExtensionTest < Minitest::Test
  include RhoTest::DaemonHarness

  Draft = Rho::Daemon::Loops::Draft

  KERNEL_TOOL = { "type" => "function",
                  "function" => { "name" => "compose", "parameters" => { "type" => "object" } } }.freeze

  def setup
    super
    @dir = Dir.mktmpdir("rho-until-ext")
    @api = Rho::Extensions::Api.new(host: RhoTest.host, extension_name: "rho.until", source: "<test>")
    Rho::Extensions::Until.register(@api)
    @registry = Rho::Extensions.load(host: RhoTest.host).registry
  end

  def teardown
    super
    FileUtils.rm_rf(@dir)
  end

  def author = @api.daemon_hooks.find { |hook| hook.event == :turn_author }.handler
  def follow = @api.daemon_hooks.find { |hook| hook.event == :turn_follow }.handler

  # The facade an author hook reads: this machine's registry, the
  # daemon's DECLARED compaction policy (one reader — the profile declaration's, downgraded where this address cannot serve it),
  # and the two runner reads the check's placement needs — the body's
  # selection and the discovery document of a runner elsewhere. The turn's tools ride the Draft, so
  # the seed no longer asks the facade for the kernel's bytes.
  AuthorContext = Struct.new(:registry, :config, :compaction_policy, :remote_runners) do
    def runner_selection(body) = body["runner_executor_public_id"]
    def remote_runner(public_id) = remote_runners[public_id]
  end

  def author_ctx(compaction: { "mode" => "kernel" }, remote_runners: {})
    AuthorContext.new(@registry, Rho::Config.from_hash({}), compaction, remote_runners)
  end

  # A remote runner's Draft carries no environment (the Surface's
  # `environment: nil`, `loops/bindings.rb`): its tools run where it is.
  def draft(body, working_directory: @dir, remote: false,
            tools: Rho::LoopRequest.tool_entries(Rho::LoopRequest.announcement(registry: @registry)) + [KERNEL_TOOL])
    environment = remote ? nil : Rho::Runner::Environment.local(root: @dir, working_directory: working_directory)
    lead = remote ? "" : Rho::LoopRequest.lead(registry: @registry, environment: environment)
    Draft.new(body: { "model" => "dev/mock-text" }.merge(body), environment: environment, notes: {},
      lead: lead, tools: tools)
  end

  # The clamp the check step carries: the operator's bash timeout under
  # the tool's own ceiling.
  def clamp(config) = [config.bash_timeout_seconds, Rho::Runner::Tools::Bash::MAX_TIMEOUT_SECONDS].min

  # The two flags land on `run`, the one conversation verb a product home
  # has, through the ONE fold (`Rho::Until.fold`, S5) —
  # rho-dev's `do` declares the same two and calls the same fold: one
  # spelling of the body, and the paragraph names no verb.
  def test_it_registers_the_two_flags_on_run_the_two_hooks_and_nothing_else
    assert_equal [["run", %i[until attempts]]], @api.flags.map { |flags| [flags.command, flags.options.keys] }
    @api.flags.each do |flags|
      assert_equal Rho::Until.fold({ "prompt" => "p" }, until: "make test", attempts: 2),
        flags.fold.call({ "prompt" => "p" }, { until: "make test", attempts: 2 })
      assert_equal({ "prompt" => "p" }, flags.fold.call({ "prompt" => "p" }, {}))
      assert_match(/the next message lands with the next check/, flags.options.dig(:until, :desc),
        "the desc names no verb: a product home has none for it")
    end
    assert_equal %i[turn_author turn_follow], @api.daemon_hooks.map(&:event)
    assert_empty @api.routes
    assert_empty @api.commands
  end

  # The paragraph rides the LEAD — the system entry every round of the
  # turn opens with — LAST, and only when there is a check, so a turn
  # without one carries the bytes it always did. Nothing hangs at author
  # time: no loop exists yet.
  def test_the_paragraph_rides_last_in_the_lead_only_when_given
    plain = draft({})
    gated = author.call(draft({ "until" => { "command" => "make test", "attempts" => 2 } }), author_ctx)

    assert_same plain, author.call(plain, author_ctx), "nothing to add, nothing touched"
    refute_includes plain.lead, "acceptance check"
    assert gated.lead.start_with?(plain.lead), "the paragraph is appended, not interleaved"
    assert gated.lead.end_with?(Rho::Until.paragraph(command: "make test", attempts: 2, directory: @dir))
    assert_equal plain.environment, gated.environment
    assert_equal plain.body.merge("until" => { "command" => "make test", "attempts" => 2 }), gated.body
  end

  # THE SEED IS THE TURN'S SURFACE: round 1 is minted by the kernel from
  # the profile's declaration narrowed by the input's `tool_names` — the
  # resolved model, the turn's tools (this machine's and the kernel's, less
  # compose when the tier is off), the kernel's compaction — so every
  # `work-N` continuation copies those bytes and moves no cached prefix;
  # and no instructions, because the paragraph rides the lead.
  def test_the_policy_is_remembered_with_the_turns_surface_as_the_seed
    gated = author.call(draft({ "until" => { "command" => "make test" } }), author_ctx)
    recorded = gated.notes.fetch("rho.until")

    assert_equal ["make test", Rho::Until::DEFAULT_ATTEMPTS, @dir, nil],
      recorded.values_at("command", "attempts", "directory", "runner"),
      "this machine's own runner: the local directory, no runner named"
    seed = recorded.fetch("seed")
    assert_equal %w[model compaction tools], seed.keys, "a step has no kind: the verb is the key"
    assert_equal({ "model" => "dev/mock-text" }, seed.fetch("model"))
    assert_equal({ "mode" => "kernel" }, seed.fetch("compaction"), "the settings' policy, the kernel's by default")
    assert_equal Rho::LoopRequest.tool_entries(Rho::LoopRequest.announcement(registry: @registry)) + [KERNEL_TOOL], seed.fetch("tools")
    refute seed.key?("instructions")
    assert_nil recorded.fetch("loop_public_id"), "the first materialized loop has not been bound yet"
    assert_equal recorded.except("loop_public_id"), Rho::Until::Policy.from_h(recorded).to_h, "round-trips through the store"

    narrowed = author.call(draft({ "until" => { "command" => "make test" } },
      tools: Rho::LoopRequest.tool_entries(Rho::LoopRequest.announcement(registry: @registry))), author_ctx)
    assert_equal Rho::LoopRequest.tool_entries(Rho::LoopRequest.announcement(registry: @registry)), narrowed.notes.dig("rho.until", "seed", "tools"),
      "a turn opened without compose seeds every check without it"
  end

  # ONE READER FOR THE COMPACTION POLICY: the seed
  # carries what the profile DECLARED — the daemon's policy after the
  # `delegate_unserved` downgrade — never the settings file read raw. A
  # check round under a delegate-less rho would otherwise seed a delegate
  # nobody announced and fail every wall `tool_not_served`.
  def test_the_seed_carries_the_declared_policy_downgraded_where_this_address_cannot_serve_it
    config = agent_mode("compaction" => { "mode" => "delegate", "model" => "dev/mock-text" })

    served = member_ready(boot(extensions: [Rho::Extensions::Compaction, Rho::Extensions::Until], config: config),
      NexusDoubles::FakeAgentApi.new)
    assert_equal({ "mode" => "delegate", "tool_name" => "summarize_history" }, served.context.compaction_policy)
    seeded = author.call(draft({ "until" => { "command" => "make test" } }), served.context)
    assert_equal({ "mode" => "delegate", "tool_name" => "summarize_history" },
      seeded.notes.dig("rho.until", "seed", "compaction"), "the extension is loaded: the delegate is served")

    unserved = member_ready(boot(extensions: [Rho::Extensions::Until], config: config,
      root: File.join(@dir, "delegate-less")), NexusDoubles::FakeAgentApi.new)
    assert_equal({ "mode" => "kernel" }, unserved.context.compaction_policy,
      "the same downgrade the declaration applies (configuration_test's sibling)")
    seeded = author.call(draft({ "until" => { "command" => "make test" } }), unserved.context)
    assert_equal({ "mode" => "kernel" }, seeded.notes.dig("rho.until", "seed", "compaction"),
      "a delegate flag without the extension seeds the kernel's summarizer")
    assert_includes File.read(unserved.home.log_path, encoding: Encoding::UTF_8), "compaction.delegate_unserved"
  end

  # The kernel refuses `tools: []` as a typo'd intent, so a machine serving
  # nothing seeds no tools key.
  def test_a_machine_serving_nothing_seeds_no_tools_key
    gated = author.call(draft({ "until" => { "command" => "make test" } }, tools: []), author_ctx)

    refute gated.notes.dig("rho.until", "seed").key?("tools")
  end

  # The policy is validated at author time, and a bad one is a Refusal
  # the daemon relays — never a raise. THE DIRECTORY IS A CLAIM, NOT A
  # CHECK: the check runs where the tree is, so a path that
  # does not exist here is passed as given — bash on the runner answers
  # "Working directory does not exist" and the loop is given back with
  # that sentence.
  def test_a_malformed_policy_is_refused_and_a_directory_is_taken_as_given
    malformed = author.call(draft({ "until" => "make test" }), author_ctx)
    assert_equal [400, "malformed_body"], [malformed.status, malformed.code]

    spent = author.call(draft({ "until" => { "command" => "make test", "attempts" => 0 } }), author_ctx)
    assert_equal "malformed_body", spent.code
    assert_match(/between 1 and #{Rho::Until::MAX_ATTEMPTS}/, spent.message)

    blank = author.call(draft({ "until" => { "command" => "  " } }), author_ctx)
    assert_match(/command is required/, blank.message)

    elsewhere = File.join(@dir, "missing")
    given = author.call(draft({ "until" => { "command" => "make test" } }, working_directory: elsewhere), author_ctx)
    assert_equal elsewhere, given.notes.dig("rho.until", "directory"), "minted with the path as given"
  end

  # A RUNNER ELSEWHERE: the Draft carries no environment, so
  # the directory is the person's `--dir` (a path they assert exists where
  # the runner is), else the root the runner ANNOUNCED, else nothing (bash
  # runs in the runner's root); and the policy names the runner, so the
  # snapshot and the log say where the check ran.
  def test_a_remote_runners_policy_takes_the_snapshots_root_and_names_the_runner
    document = CybrosAgent::Api::DiscoveredExecutor.new(
      **NexusDoubles.remote_runner("R1", root: "/srv/remote").transform_keys(&:to_sym)
    )
    ctx = author_ctx(remote_runners: { "R1" => document })
    body = { "until" => { "command" => "make test" }, "runner_executor_public_id" => "R1" }

    announced = author.call(draft(body, remote: true), ctx).notes.fetch("rho.until")
    assert_equal ["/srv/remote", "R1"], announced.values_at("directory", "runner")
    assert announced.fetch("seed").key?("model")

    asserted = author.call(draft(body.merge("working_directory" => "/srv/remote/app"), remote: true), ctx)
    assert_equal "/srv/remote/app", asserted.notes.dig("rho.until", "directory"), "the person's --dir wins"
    assert asserted.lead.end_with?(Rho::Until.paragraph(command: "make test",
      attempts: Rho::Until::DEFAULT_ATTEMPTS, directory: "/srv/remote/app"))

    unknown = author.call(draft(body, remote: true), author_ctx(remote_runners: {}))
    assert_nil unknown.notes.dig("rho.until", "directory"), "no snapshot: bash runs in the runner's root"
    assert_equal "R1", unknown.notes.dig("rho.until", "runner")
    assert_includes unknown.lead, "run in the runner's root"
  end

  # The same, through the daemon: the discovery read on a miss goes over
  # the member plane, and the author hook reads it off the facade.
  def test_the_daemon_reads_the_remote_runners_root_from_discovery
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE,
      executors: [NexusDoubles.remote_runner("R1", root: "/srv/remote")])
    daemon = member_ready(boot(extensions: [Rho::Extensions::Until], config: agent_mode), api)
    body = { "until" => { "command" => "make test" }, "runner_executor_public_id" => "R1" }

    recorded = author.call(draft(body, remote: true), daemon.context).notes.fetch("rho.until")

    assert_equal ["/srv/remote", "R1"], recorded.values_at("directory", "runner")
  end

  # THE FOLLOW HOOK, given the LOOP backing the turn: it hangs the check
  # below the kernel's `r1` through the loop's own door, then builds the
  # gate bound to that loop from what was remembered. A loop with no
  # policy gets no gate and no append.
  def test_the_follow_hook_hangs_the_check_below_r1_and_builds_a_gate_bound_to_the_loop
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(extensions: [Rho::Extensions::Until], config: agent_mode), api)
    policy = Rho::Until::Policy.new(command: "make test", attempts: 2, directory: @dir, runner: nil, seed: {})

    assert_nil follow.call("al-1", {}, daemon.context)
    assert_empty api.appends

    gate = follow.call("al-1", { "rho.until" => policy.to_h.merge("loop_public_id" => "al-1") }, daemon.context)

    assert_instance_of Rho::Until::Gate, gate
    assert_equal "al-1", gate.loop_public_id
    assert_equal 2, gate.to_h.fetch("attempts")
    append = api.appends.fetch(0)
    expected = Rho::Until.check_steps(1, command: "make test", directory: @dir,
      timeout_seconds: clamp(daemon.context.config)).map(&:to_h)
    assert_equal expected, append.fetch("steps"), "the check as a bash TOOL step, the hold behind it"
    refute append.key?("deliverable"), "placed after r1 by position; the hold becomes the answer"
    assert(api.requests.any? { |path, _| path.end_with?("/agent_loops/al-1/tasks") },
      "through the LOOP door: #{api.requests.map(&:first).inspect}")
  end

  # TOLERANT OF A LOOP THAT SETTLED FIRST: round 1 without a call completes
  # in a second on a fake, and the append lands on a settled loop. That is
  # a turn that simply completes — logged, no gate, never a raise into the
  # follower.
  def test_a_settled_loop_costs_the_gate_and_is_logged
    refusal = CybrosAgent::Response.new(
      status: 409, headers: {},
      body: { "error" => { "code" => "agent_loop_settled", "message" => "the loop completed" } }
    )
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE, append: refusal)
    daemon = member_ready(boot(extensions: [Rho::Extensions::Until], config: agent_mode), api)
    policy = Rho::Until::Policy.new(command: "make test", attempts: 2, directory: @dir, runner: nil, seed: {})

    assert_nil follow.call("al-1", { "rho.until" => policy.to_h.merge("loop_public_id" => "al-1") }, daemon.context)
    late = File.readlines(daemon.home.log_path, encoding: "UTF-8").grep(/event=until\.too_late/)
    assert_equal 1, late.length, "logged once"
    assert_includes late.first, "agent_loop=al-1"
    assert_includes late.first, "code=agent_loop_settled"
  end

  # LOADED ALONE beside the runner's tools, the whole path is reachable
  # over the wire: the body the flags fold authors the paragraph into the
  # inline lead, the check hangs below the kernel's round once the loop is
  # known, and the follower carries the gate.
  def test_loaded_alone_it_authors_the_gate_over_the_wire
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(extensions: [Rho::Runner::Extensions::Coding, Rho::Extensions::Until]), api)

    response = request(daemon, :post, "/conversations", token: bearer(daemon), body: {
      prompt: "fix it", model: "dev/mock-text", working_directory: @dir,
      until: { command: "make test", attempts: 2 },
    })

    assert_equal "201", response.code, response.body
    answer = JSON.parse(response.body)
    assert_equal({ "command" => "make test", "attempts" => 2, "directory" => @dir }, answer.fetch("until"),
      "own runner: no runner key on the answer (the daemon compacts the nil the store keeps)")
    assert_equal "al-1", answer.dig("run", "until", "loop"), "the follower carries the gate, bound to the loop"
    lead = api.conversation_inputs.fetch(0).dig("input", "inline", 0, "text")
    assert lead.end_with?(Rho::Until.paragraph(command: "make test", attempts: 2, directory: @dir))
    assert_equal %w[check-1 hold-1],
      api.appends.fetch(0).fetch("steps").map { |step| step.dig("tool", "key") || step.dig("ask", "key") }
  end

  # THE VERDICT THROUGH THE DAEMON (the unit case's twin): the gate the
  # follow hook built reads the settled check's detail ONCE through the
  # loop's own door — `GET …/tasks/check-1` — and appends the next attempt
  # with the hold resolved, over the wire.
  def test_the_gate_reads_the_settled_row_once_through_the_loop_door_and_appends_the_verdict
    settled = NexusDoubles::RUNNING_TRACE.merge("deliverable_task_key" => "hold-1", "tasks" => [
      { "key" => "r1", "kind" => "model_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "on_failure" => "halt",
        "visibility" => "visible", "created_at" => "2026-09-05T00:00:00Z" },
      { "key" => "check-1", "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "bash",
        "on_failure" => "absorb", "visibility" => "visible", "created_at" => "2026-09-05T00:00:00Z" },
      { "key" => "hold-1", "kind" => "await_task", "lifetime" => "conversation", "wake" => "auto", "status" => "dispatched", "on_failure" => "halt",
        "visibility" => "visible", "created_at" => "2026-09-05T00:00:00Z" },
    ])
    api = NexusDoubles::FakeAgentApi.new(trace: settled, task_detail: {
      "kind" => "tool_task", "lifetime" => "conversation", "wake" => "auto", "status" => "completed", "tool_name" => "bash", "on_failure" => "absorb",
      "visibility" => "visible", "created_at" => "2026-09-05T00:00:00Z",
      "output" => "not yet: run 1\n\nCommand exited with code 1", "structured_content" => { "exit_status" => 1 },
    })
    daemon = member_ready(boot(extensions: [Rho::Extensions::Until], config: agent_mode), api)
    policy = Rho::Until::Policy.new(command: "make test", attempts: 3, directory: @dir, runner: nil, seed: {})
    gate = follow.call("al-1", { "rho.until" => policy.to_h.merge("loop_public_id" => "al-1") }, daemon.context)
    context = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1").agent_loops.agent_loop("al-1")

    gate.reconsider(context)

    reads = api.requests.map(&:first).grep(%r{/agent_loops/al-1/tasks/check-1\z})
    assert_equal 1, reads.length, "one detail read: #{api.requests.map(&:first).inspect}"
    verdict = api.appends.fetch(1)
    assert_equal [{ "task" => "hold-1", "content" => "check 1/3: exit 1" }], verdict.fetch("resolve")
    assert_equal %w[work-2 check-2 hold-2],
      verdict.fetch("steps").map { |step| step.values.first.fetch("key") }
    assert_equal %w[check-1 hold-1], verdict.fetch("steps").first.dig("model", "results"),
      "the round names the rows of the earlier append it reads, on the wire"
    assert_equal ["exit 1"], gate.checks.map(&:verdict)
  end
end
