require "test_helper"
require "tmpdir"

# THE ACCEPTANCE CHECK AS AN EXTENSION: what its two hooks do to a draft
# and to a follower, loaded alone on a fresh handle — the isolation the
# registry promises every extension. The input accepts the check and hold
# atomically with round one; following installs only the original Run's gate.
class UntilExtensionTest < Minitest::Test
  include RhoTest::DaemonHarness

  Draft = Rho::Daemon::HostFollowers::Draft

  KERNEL_TOOL = { "type" => "function",
                  "function" => { "name" => "delegate_task", "parameters" => { "type" => "object" } } }.freeze

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
    def runner_selection(body) = body["default_runner_executor_public_id"]
    def remote_runner(public_id) = remote_runners[public_id]
  end

  def author_ctx(compaction: { "mode" => "kernel" }, remote_runners: {})
    AuthorContext.new(@registry, Rho::Config.from_hash({}), compaction, remote_runners)
  end

  # A remote runner's Draft carries no environment (the Surface's
  # `environment: nil`, `runs/bindings.rb`): its tools run where it is.
  def draft(body, working_directory: @dir, remote: false,
            tools: Rho::RunDeclaration.tool_entries(Rho::RunDeclaration.announcement(registry: @registry)) + [KERNEL_TOOL])
    environment = remote ? nil : Rho::Runner::Environment.local(root: @dir, working_directory: working_directory)
    lead = remote ? "" : Rho::RunDeclaration.lead(registry: @registry, environment: environment)
    Draft.new(body: { "model" => "dev/mock-text" }.merge(body), environment: environment, notes: {},
      lead: lead, tools: tools)
  end

  # The clamp the check step carries: the operator's bash timeout under
  # the tool's own ceiling.
  def clamp(config) = [config.plugin_configuration("rho.coding").fetch("bash_timeout_seconds"), Rho::Runner::Tools::Bash::MAX_TIMEOUT_SECONDS].min

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
  # without one carries the bytes it always did.
  def test_the_paragraph_rides_last_in_the_lead_only_when_given
    plain = draft({})
    gated = author.call(draft({ "until" => { "command" => "make test", "attempts" => 2 } }), author_ctx)

    assert_same plain, author.call(plain, author_ctx), "nothing to add, nothing touched"
    assert_nil plain.steps
    refute_includes plain.lead, "acceptance check"
    assert gated.lead.start_with?(plain.lead), "the paragraph is appended, not interleaved"
    assert gated.lead.end_with?(Rho::Until.paragraph(command: "make test", attempts: 2, directory: @dir))
    assert_equal plain.environment, gated.environment
    assert_equal plain.body.merge("until" => { "command" => "make test", "attempts" => 2 }), gated.body
  end

  # THE SEED IS THE TURN'S SURFACE: round 1 is minted by the kernel from
  # the profile's declaration narrowed by the input's `tool_names` — the
  # resolved model, the turn's available tools and the kernel's compaction — so every
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
    assert_equal Rho::RunDeclaration.tool_entries(Rho::RunDeclaration.announcement(registry: @registry)) + [KERNEL_TOOL], seed.fetch("tools")
    refute seed.key?("instructions")
    assert_nil recorded.fetch("run_public_id"), "the first materialized run has not been bound yet"
    assert_equal recorded.except("run_public_id"),
      Rho::Until::Policy.from_h(recorded).to_h, "round-trips through the store"
    assert_equal %w[check-1 hold-1], gated.steps.map(&:key)

    narrowed = author.call(draft({ "until" => { "command" => "make test" } },
      tools: Rho::RunDeclaration.tool_entries(Rho::RunDeclaration.announcement(registry: @registry))), author_ctx)
    assert_equal Rho::RunDeclaration.tool_entries(Rho::RunDeclaration.announcement(registry: @registry)), narrowed.notes.dig("rho.until", "seed", "tools"),
      "a narrowed tool set is retained in each check"
  end

  def test_the_check_follows_steps_authored_by_an_earlier_extension
    prepare = CybrosAgent::Steps::Tool.new(name: "bash", key: "prepare", input: { "command" => "make prepare" })
    input = draft({ "until" => { "command" => "make test" } }).with(steps: [prepare])

    authored = author.call(input, author_ctx)

    assert_equal %w[prepare check-1 hold-1], authored.steps.map(&:key)
    assert_same prepare, authored.steps.first
  end

  # ONE READER FOR THE COMPACTION POLICY: the seed
  # carries what the profile DECLARED — the daemon's policy after the
  # active plugin selection — never the settings file read raw. A
  # check round under a delegate-less rho would otherwise seed a delegate
  # nobody announced and fail every wall `tool_not_served`.
  def test_the_seed_carries_the_declared_policy_and_disables_compaction_without_its_plugin
    config = agent_mode("plugins" => { "rho.compaction" => { "configuration_version" => 1, "configuration" => { "mode" => "delegate", "model" => "dev/mock-text" } } })

    served = member_ready(boot(extensions: [Rho::Extensions::Compaction, Rho::Extensions::Until], config: config),
      NexusDoubles::FakeAgentApi.new)
    assert_equal({ "mode" => "delegate", "tool_name" => "summarize_history" }, served.context.compaction_policy)
    seeded = author.call(draft({ "until" => { "command" => "make test" } }), served.context)
    assert_equal({ "mode" => "delegate", "tool_name" => "summarize_history" },
      seeded.notes.dig("rho.until", "seed", "compaction"), "the extension is loaded: the delegate is served")

    unserved = member_ready(boot(extensions: [Rho::Extensions::Until], config: config,
      root: File.join(@dir, "delegate-less")), NexusDoubles::FakeAgentApi.new)
    assert_equal({ "mode" => "off" }, unserved.context.compaction_policy,
      "the declaration uses no compaction policy without its owner")
    seeded = author.call(draft({ "until" => { "command" => "make test" } }), unserved.context)
    assert_equal({ "mode" => "off" }, seeded.notes.dig("rho.until", "seed", "compaction"),
      "the next check retains the declared off policy")
    refute_includes unserved.context.registry.names, "summarize_history"
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
  # "Working directory does not exist" and the run is given back with
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
    body = { "until" => { "command" => "make test" }, "default_runner_executor_public_id" => "R1" }

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
    body = { "until" => { "command" => "make test" }, "default_runner_executor_public_id" => "R1" }

    recorded = author.call(draft(body, remote: true), daemon.context).notes.fetch("rho.until")

    assert_equal ["/srv/remote", "R1"], recorded.values_at("directory", "runner")
  end

  # The input owns the initial check. Following only installs a gate; it
  # neither creates tasks nor requires the write-only Ask receipt.
  def test_the_follow_hook_builds_a_gate_without_an_append_request
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    daemon = member_ready(boot(extensions: [Rho::Extensions::Until], config: agent_mode), api)
    policy = Rho::Until::Policy.new(command: "make test", attempts: 2, directory: @dir, runner: nil, seed: {})

    assert_nil follow.call("al-1", {}, daemon.context)
    before = api.requests.length
    gate = follow.call("al-1", { "rho.until" => policy.to_h.merge("run_public_id" => "al-1") }, daemon.context)

    assert_instance_of Rho::Until::Gate, gate
    assert_equal "al-1", gate.run_public_id
    assert_equal 2, gate.to_h.fetch("attempts")
    assert_empty api.appends
    assert_equal before, api.requests.length, "a bound policy needs no IO to restore its gate"
  end

  # LOADED ALONE beside the runner's tools, the whole path is reachable
  # over the wire: the body the flags fold authors the paragraph into the
  # inline lead, the first input includes the check and hold, and the
  # follower installs its gate without a second task-creation request.
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
    assert_equal "al-1", answer.dig("follower", "until", "run_public_id"), "the follower carries the gate, bound to the run"
    lead = api.conversation_inputs.fetch(0).dig("input", "inline", 0, "text")
    assert lead.end_with?(Rho::Until.paragraph(command: "make test", attempts: 2, directory: @dir))
    steps = api.conversation_inputs.fetch(0).dig("input", "steps")
    assert_equal %w[check-1 hold-1], steps.map { |step| step.dig("tool", "key") || step.dig("ask", "key") }
    assert_equal clamp(daemon.context.config), steps.first.dig("tool", "input", "timeout")
    assert_empty api.appends

    said = request(daemon, :post, "/say", token: bearer(daemon), body: {
      public_id: "c-1", text: "an independent later request", delivery_mode: "queue",
    })
    assert_equal "200", said.code, said.body
    refute api.conversation_inputs.last.fetch("input").key?("steps")
  end

  def test_a_foreign_answerer_keeps_its_own_surface_and_receives_the_authored_check
    api = NexusDoubles::FakeAgentApi.new(trace: NexusDoubles::RUNNING_TRACE)
    api.stock_principals([{ "public_id" => "peer-1", "handle" => "lark", "kind" => "agent", "display_name" => "Lark",
      "agent_identifier" => "rho.peer", "steward_public_id" => "steward-1" }])
    daemon = member_ready(boot(extensions: [Rho::Runner::Extensions::Coding, Rho::Extensions::Until]), api)

    response = request(daemon, :post, "/conversations", token: bearer(daemon), body: {
      prompt: "fix it", model: "dev/mock-text", agent: "@lark", until: { command: "make test" },
    })

    assert_equal "201", response.code, response.body
    input = api.conversation_inputs.fetch(0).fetch("input")
    assert_equal %w[check-1 hold-1], input.fetch("steps").map { |step| step.values.first.fetch("key") }
    %w[tool_names approval_mode inline].each { |field| refute input.key?(field), field }
    assert_empty api.appends
  end

  def test_a_refused_atomic_check_is_an_input_failure
    blocked = NexusDoubles::FakeAgentApi::MATERIALIZED_EVENTS.first.merge("type" => "input_blocked",
      "payload" => { "input_public_id" => "cin-1", "blocked_reason" => "runner_required" })
    api = NexusDoubles::FakeAgentApi.new(conversation_events: [blocked])
    daemon = member_ready(boot(extensions: [Rho::Runner::Extensions::Coding, Rho::Extensions::Until]), api)

    response = request(daemon, :post, "/conversations", token: bearer(daemon), body: {
      prompt: "fix it", model: "dev/mock-text", until: { command: "make test" },
    })

    assert_equal "422", response.code, response.body
    assert_equal "input_blocked", JSON.parse(response.body).dig("error", "code")
    assert_includes response.body, "runner_required"
    assert_empty api.appends
  end

  # THE VERDICT THROUGH THE DAEMON (the unit case's twin): the gate the
  # follow hook built reads the settled check's detail ONCE through the
  # run's own door — `GET …/tasks/check-1` — and appends the next attempt
  # with the hold resolved, over the wire.
  def test_the_gate_reads_the_settled_row_once_through_the_run_door_and_appends_the_verdict
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
    gate = follow.call("al-1", { "rho.until" => policy.to_h.merge("run_public_id" => "al-1") }, daemon.context)
    context = daemon.wire.client(NexusDoubles::MEMBER_TOKEN).workspace("ws-1").runs.run("al-1")

    gate.reconsider(context)

    reads = api.requests.map(&:first).grep(%r{/runs/al-1/tasks/check-1\z})
    assert_equal 1, reads.length, "one detail read: #{api.requests.map(&:first).inspect}"
    verdict = api.appends.fetch(0)
    assert_equal [{ "task" => "hold-1", "content" => "check 1/3: exit 1" }], verdict.fetch("resolve")
    assert_equal %w[work-2 check-2 hold-2],
      verdict.fetch("steps").map { |step| step.values.first.fetch("key") }
    assert_equal %w[check-1 hold-1], verdict.fetch("steps").first.dig("model", "results"),
      "the round names the rows of the earlier append it reads, on the wire"
    assert_equal ["exit 1"], gate.checks.map(&:verdict)
  end
end
