require "test_helper"
require "cgi/escape"
require "fileutils"
require "net/http"
require "rho"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# Only the external native service and model provider are fixtures. The real
# native RPC client, rho executor and Nexus question/store/capture path run end to end.
class RhoT3Test < Minitest::Test
  MODEL = "dev/mock-text".freeze
  TOOLS = %w[coding_work delegate_coding].freeze
  HUMAN_WAIT_SECONDS = 35

  def setup
    @base_url = E2E.base_url
    steward = E2E::ActorProvisioning.world(@base_url).rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: steward)
    @root = Dir.mktmpdir("rho-t3-e2e")
    @home, @project = File.join(@root, "home"), File.join(@root, "work")
    @issued_tool_calls = 0
    FileUtils.mkdir_p(@home, mode: 0o700)
    FileUtils.mkdir_p(@project)
    start_native
    Rho::StateFile.new(File.join(@home, "settings.json")).write({
      "settings_version" => 1, "api_only" => true,
      "plugins" => { "rho.t3" => { "enabled" => false, "configuration_version" => 1, "configuration" => {} } },
    })
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, tools_root: @project,
      env: { "RHO_T3_TOKEN" => "fixture-t3-bearer" })
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    @daemon.await("rho never adopted its workspace") { @daemon.status.dig("workspace", "state") == "adopted" }
    @daemon.await_announced(address: "agent")
    @member = CybrosAgent::Client.new(base_url: @base_url, credential: steward.member_token)
    @workspace = @member.workspace(@daemon.status.dig("workspace", "public_id"))
    @core = Rho::Core.new(home: Rho::Home.resolve(base_url: @base_url, root: @home))
    assert_t3_tools([])
    @core.enable_extension("rho.t3")
    assert_t3_tools([])
    configure_t3
    assert_t3_tools(TOOLS)
    E2E.enable_dev_lane!
    E2E.hosts.start
  end

  def teardown
    unless passed?
      [@daemon&.log_path, @daemon&.rho_log_path, @native_log].compact.each do |path|
        warn E2E::SecretHygiene.redact(File.read(path)) if File.file?(path)
      end
    end
    @daemon&.dispose_connection
    E2E::ProcessRegistry.terminate(@native_pid) if @native_pid
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_settings_publish_and_remove_tools_for_future_turns_without_restarting
    daemon_pid = @daemon.pid
    opened = @core.open_conversation(model: MODEL, directory: @project)
    @conversation = opened.fetch("conversation").fetch("public_id")
    @chat = @workspace.conversation(@conversation)

    @core.disable_extension("rho.t3")
    assert_t3_tools([])
    assert_empty declared_t3_tools(visibility_turn)

    @core.enable_extension("rho.t3")
    assert_t3_tools(TOOLS)
    accepted = visibility_turn
    assert_equal TOOLS, declared_t3_tools(accepted)

    error = assert_raises(Rho::Core::Refused) do
      @core.configure_extension("rho.t3", operations: [{ op: "set", path: ["url"], value: "file:///tmp/t3" }])
    end
    assert_equal "plugin_configuration_unapplied", error.code
    assert_t3_tools(TOOLS)

    configure_t3
    @core.disable_extension("rho.t3")
    assert_t3_tools([])
    assert_empty declared_t3_tools(visibility_turn)
    assert_equal TOOLS, declared_t3_tools(accepted), "accepted model tasks retain their frozen tool declarations"
    assert_equal daemon_pid, @daemon.pid
    assert_empty native.fetch("calls"), "configuration publishes tools without connecting to the native service"
  end

  def test_background_coding_relays_questions_captures_results_and_continues_the_same_work_after_restart
    opened = @core.open_conversation(model: MODEL, directory: @project)
    @conversation = opened.fetch("conversation").fetch("public_id")
    @chat = @workspace.conversation(@conversation)
    first = delegate("Implement a blue marker.", agent: "Codex", model: "Fixture Coding Model")
    ordinary = await_question(first, "Which color")
    waiting_since = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    daemon_pid = @daemon.pid
    assert_nil @workspace.runs.run(first).task(ordinary.fetch("task_key")).options
    assert_reply(first)
    ongoing = @workspace.runs.run(first).fetch.tasks.find { |row| row.tool_name == "delegate_coding" }
    refute_nil ongoing
    refute_includes %w[completed failed canceled], ongoing.status

    # A second ordinary turn completes while the native worker and question wait.
    later = run_id(@core.say(@conversation, "!mock reply=still-available -- Can we discuss another detail?", model: MODEL, mode: "queue"))
    assert_reply(later, "Mock: still-available")
    listed = JSON.parse(control("list").output).fetch("work")
    assert_equal 1, listed.length
    work_id = listed.first.fetch("work_id")
    assert_equal "Codex", listed.first.fetch("agent")
    waiting = JSON.parse(control("observe", work_id: work_id).output)
    assert_equal "running", waiting.fetch("status")
    assert_equal "fixture-model", waiting.fetch("model")
    assert_equal "user_input", waiting.fetch("requests").first.fetch("kind")
    assert_includes control("steer", work_id: work_id, prompt: "Keep the change focused on the marker.").output,
      "Steering submitted"
    assert_same_question_after_human_wait(first, ordinary, waiting_since)
    assert_equal "dispatched", @workspace.runs.run(first).task(ongoing.key).task.status,
      "the original delegation remains active while its Human question waits"
    assert_equal daemon_pid, @daemon.pid, "the live claim and native callback did not require a daemon restart"
    state = native
    assert_equal ["native-run-1"], state.dig("projection", "runs").map { |run| run.fetch("id") }
    assert_equal 1, state.fetch("calls").count { |call| call.fetch("method") == "orchestration.launchThread" }
    assert_empty state.fetch("calls").select { |call| call.dig("params", "type") == "runtime-request.respond" }
    answer(ordinary, "blue")
    approval = await_question(first, "Run the fixture checks?")
    assert_equal %w[accept decline], @workspace.runs.run(first).task(approval.fetch("task_key")).options
    assert_includes approval.fetch("prompt"), "ruby test.rb"
    answer(approval, "accept")
    @daemon.await("the native main run never finished") { native.dig("projection", "runs", 0, "status") == "completed" }
    refute_equal "completed", @workspace.runs.run(first).task(ongoing.key).task.status,
      "a native worker still running keeps the delegation open"
    native("/fixture/settle-workers", post: true)
    detail = await_tool(first, "delegate_coding", "completed")
    report = JSON.parse(detail.output)
    assert_equal "completed", report.fetch("status")
    assert_equal "Codex", report.fetch("agent")
    assert_equal "fixture-model", report.fetch("model")
    assert_equal @project, report.fetch("worktree")
    assert_equal "1 check passed", report.fetch("checks").first.fetch("output")
    assert_equal "completed", report.fetch("workers").first.fetch("status")
    assert_captures(detail, report)
    assert_equal work_id, report.fetch("work_id")
    stored = @chat.store_entries.fetch(work_id)
    thread_id = stored.value.fetch("thread")
    assert_equal "rho.t3", stored.namespace
    assert_equal @native_url, stored.value.dig("environment", "url")
    assert_equal [ordinary.fetch("task_key"), approval.fetch("task_key")].sort,
      @workspace.runs.run(first).fetch.tasks.select(&:await?).map(&:key).sort,
      "each native callback created exactly one Human question"
    @daemon.stop
    @daemon.start
    @daemon.await("rho did not reconnect") { @daemon.status.fetch("state") == "active" }
    @core = Rho::Core.new(home: @core.home)
    resumed = delegate("Continue the same marker work.", work_id: work_id)
    @daemon.await("the original native thread was not continued") do
      native.fetch("calls").any? { |call| call.dig("params", "dispatchMode", "type") == "start_immediately" }
    end
    assert_reply(resumed)
    unanswered = await_question(resumed, "Which color")
    resumed_task = @workspace.runs.run(resumed).fetch.tasks.find { |row| row.tool_name == "delegate_coding" }
    refute_nil resumed_task
    @core.stop(resumed, resumed_task.key, host_type: "run", workspace_public_id: @workspace.public_id)
    @daemon.await("Stop did not reach the original native run") do
      native.fetch("calls").any? { |call| call.dig("params", "type") == "run.interrupt" }
    end
    await_tool(resumed, "delegate_coding", "canceled")
    @daemon.await("Stop did not settle the exact pending Human question") do
      @workspace.runs.run(resumed).task(unanswered.fetch("task_key")).task.status == "canceled"
    end
    refute @core.asks.any? { |row| row.fetch("run_public_id") == resumed }, "the stopped native callback left no pending question"
    calls = native.fetch("calls")
    assert_equal 1, calls.count { |call| call.fetch("method") == "orchestration.launchThread" }
    launch = calls.find { |call| call.fetch("method") == "orchestration.launchThread" }.fetch("params")
    assert_equal "fixture-project", launch.fetch("projectId")
    assert_equal({ "instanceId" => "fixture-provider", "model" => "fixture-model" }, launch.fetch("modelSelection"))
    assert_equal %w[choose-color approve-check], calls.filter_map { |call| call.dig("params", "requestId") }
    steering = calls.find { |call| call.dig("params", "dispatchMode", "type") == "steer_active" }.fetch("params")
    assert_equal thread_id, steering.fetch("threadId")
    assert_equal "native-run-1", steering.dig("dispatchMode", "targetRunId")
    continued = calls.find { |call| call.dig("params", "dispatchMode", "type") == "start_immediately" }.fetch("params")
    stopped = calls.find { |call| call.dig("params", "type") == "run.interrupt" }.fetch("params")
    assert_equal thread_id, continued.fetch("threadId")
    assert_equal "Continue the same marker work.", continued.fetch("text")
    assert_equal({ "type" => "start_immediately" }, continued.fetch("dispatchMode"))
    assert_equal thread_id, stopped.fetch("threadId")
    assert_equal "native-run-2", stopped.fetch("runId")
    assert stopped.fetch("holdQueue")
    assert_equal 1, calls.count { |call| call.dig("params", "type") == "run.interrupt" }
    assert_equal "completed", native.fetch("projection").fetch("runs").first.fetch("status")
    assert_equal "interrupted", native.fetch("projection").fetch("runs").last.fetch("status")
    assert_equal ["cancelled"], native.fetch("projection").fetch("subagents").map { |worker| worker.fetch("status") }
    assert_empty native.fetch("projection").fetch("runtimeRequests")
    continuation = @chat.store_entries.fetch(work_id)
    assert_equal stored.value.fetch("environment"), continuation.value.fetch("environment")
    assert_equal stored.value.fetch("placement"), continuation.value.fetch("placement")
    assert_equal resumed, continuation.value.dig("owner", "run")

    # The work control must cancel the saved Nexus owner too: interrupting only
    # the native run cannot release its original durable Human question.
    controlled = delegate("Continue the marker work for a final check.", work_id: work_id)
    assert_reply(controlled)
    pending = await_question(controlled, "Which color")
    controlled_task = @workspace.runs.run(controlled).fetch.tasks.find { |row| row.tool_name == "delegate_coding" }
    refute_nil controlled_task
    assert_equal "dispatched", controlled_task.status
    assert_equal "awaiting_input", @workspace.runs.run(controlled).task(pending.fetch("task_key")).task.status
    assert_equal({ "run" => controlled, "task" => controlled_task.key }, @chat.store_entries.fetch(work_id).value.fetch("owner"))

    assert_includes control("stop", work_id: work_id).output, "Stop requested"
    await_tool(controlled, "delegate_coding", "canceled")
    @daemon.await("coding_work stop did not settle the original pending Human question") do
      @workspace.runs.run(controlled).task(pending.fetch("task_key")).task.status == "canceled"
    end
    refute @core.asks.any? { |row| row.fetch("run_public_id") == controlled },
      "coding_work stop left its original native callback question pending"
    @daemon.await("coding_work stop did not interrupt the native continuation") do
      native.fetch("calls").any? { |call| call.dig("params", "type") == "run.interrupt" && call.dig("params", "runId") == "native-run-3" }
    end
    state = native
    interruptions = state.fetch("calls").select { |call| call.dig("params", "type") == "run.interrupt" }.map { |call| call.fetch("params") }
    assert_equal %w[native-run-2 native-run-3], interruptions.map { |params| params.fetch("runId") },
      "task Stop and coding_work stop each interrupt their own native run exactly once"
    assert_equal thread_id, interruptions.last.fetch("threadId")
    assert interruptions.last.fetch("holdQueue")
    assert_equal %w[completed interrupted interrupted], state.dig("projection", "runs").map { |run| run.fetch("status") }
    assert_equal ["cancelled"], state.dig("projection", "subagents").map { |worker| worker.fetch("status") }
    assert_empty state.dig("projection", "runtimeRequests")
    assert_equal 1, state.fetch("calls").count { |call| call.fetch("method") == "orchestration.launchThread" }
    assert_equal %w[choose-color approve-check], state.fetch("calls").filter_map { |call| call.dig("params", "requestId") },
      "neither canceled question was answered back to the native service"
    assert_equal controlled, @chat.store_entries.fetch(work_id).value.dig("owner", "run")
  end

  private

    def t3_configuration
      { "server" => "host", "url" => @native_url, "project_id" => "fixture-project", "default_agent" => "Codex" }
    end

    def configure_t3
      operations = t3_configuration.map { |key, value| { op: "set", path: [key], value: value } }
      @core.configure_extension("rho.t3", operations: operations)
    end

    def assert_t3_tools(expected)
      extension = @core.extensions.fetch("plugins").find { |entry| entry.fetch("id") == "rho.t3" }
      refute_nil extension, "static metadata remains available while the plugin is disabled"
      assert_equal expected, extension.fetch("capabilities").fetch("tools").sort
      agent = @daemon.control(:get, "/runner").fetch("agent")
      assert_equal expected, (agent.fetch("tools") & TOOLS).sort
      assert_equal agent.fetch("tools").length, agent.fetch("announced")
    end

    def visibility_turn
      id = run_id(@core.say(@conversation, "!mock reply=visibility -- Describe the available tools.",
        model: MODEL, mode: "queue", code_mode: false))
      assert_reply(id, "Mock: visibility")
      id
    end

    def declared_t3_tools(id)
      run = @workspace.runs.run(id)
      model = run.fetch.tasks.find { |task| task.kind == "model_task" }
      refute_nil model, "the ordinary conversation turn must accept a model task"
      (run.task(model.key).tool_definitions.map { |tool| tool.fetch("function").fetch("name") } & TOOLS).sort
    end

    def start_native
      announcement = File.join(@root, "native-url")
      @native_log = File.join(@root, "native.log")
      @native_pid = E2E::ProcessRegistry.spawn("bun", File.expand_path("../fixtures/t3_service.mjs", __dir__), announcement, @project,
        in: File::NULL, out: [@native_log, "a"], err: [@native_log, "a"], pgroup: true)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
      until File.file?(announcement)
        raise "the native fixture never started" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.05
      end
      @native_url = File.read(announcement)
    end

    def native(path = "/fixture", post: false)
      uri = URI.join(@native_url, path)
      response = Net::HTTP.start(uri.host, uri.port) { |http| http.request(post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)) }
      assert_equal "200", response.code, response.body
      JSON.parse(response.body)
    end

    def delegate(prompt, work_id: nil, agent: nil, model: nil)
      arguments = { "prompt" => prompt, "work_id" => work_id, "agent" => agent, "model" => model }.compact
      source = "const work = tools.delegate_coding(#{JSON.generate(arguments)}); " \
        "await nexus.background({operation_key: work.operation_key, lifetime: 'conversation', wake: 'passive'}); text('coding started');"
      tool_turn("code", { "code" => source }, reply: "coding-started", code_mode: true)
    end

    def control(action, work_id: nil, prompt: nil)
      id = tool_turn("coding_work", { "action" => action, "work_id" => work_id, "prompt" => prompt }.compact,
        reply: "control-finished", code_mode: false)
      assert_reply(id, "Mock: control-finished")
      await_tool(id, "coding_work", "completed")
    end

    def tool_turn(name, arguments, reply:, code_mode:)
      encoded = CGI.escape(JSON.generate(arguments))
      script = Array.new(@issued_tool_calls + 1, "#{name}:#{encoded}").join(",")
      @issued_tool_calls += 1
      run_id(@core.say(@conversation, "!mock tool_call=#{script} reply=#{reply} -- Execute the requested tool.",
        model: MODEL, mode: "queue", approval_mode: "bypass", code_mode: code_mode))
    end

    def assert_same_question_after_human_wait(id, question, started)
      # Cross the former 30-second execution-segment boundary with real elapsed
      # time while the same native callback and Nexus question are pending.
      remaining = HUMAN_WAIT_SECONDS - (Process.clock_gettime(Process::CLOCK_MONOTONIC) - started)
      sleep remaining if remaining.positive?
      assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC) - started, :>=, HUMAN_WAIT_SECONDS
      pending = @core.asks.select { |row| row.fetch("run_public_id") == id && row.fetch("kind") == "ask" }
      assert_equal [question.fetch("task_key")], pending.map { |row| row.fetch("task_key") }
      assert_equal "awaiting_input", @workspace.runs.run(id).task(question.fetch("task_key")).task.status
    end

    def run_id(document)
      document.dig("run", "public_id") || @daemon.await("the input never materialized") do
        @chat.turns.list.items.find { |row| row.input_public_id == document.fetch("input").fetch("public_id") }&.active_variant&.run_public_id
      end
    end

    def assert_reply(id, content = "Mock: coding-started")
      turn = @daemon.await("the main conversation reply never completed") do
        @chat.turns.list.items.find { |row| row.active_variant&.run_public_id == id && row.active_variant.status == "completed" }
      end
      assert_equal content, turn.active_variant.content
    end

    def await_question(id, prompt)
      @daemon.await("the native question never reached Nexus: #{prompt}") do
        @core.asks.find { |row| row.fetch("run_public_id") == id && row.fetch("kind") == "ask" && row.fetch("prompt").include?(prompt) }
      end
    end

    def answer(question, value)
      @core.answer(question.fetch("run_public_id"), question.fetch("task_key"), value, workspace_public_id: @workspace.public_id)
    end

    def await_tool(id, name, status)
      @daemon.await("#{name} never reached #{status}") do
        run = @workspace.runs.run(id)
        task = run.fetch.tasks.find { |row| row.tool_name == name }
        run.task(task.key) if task&.status == status
      end
    end

    def assert_captures(detail, report)
      links = detail.content.select { |block| block.fetch("type") == "resource_link" }
      assert_equal 2, links.length, detail.content.inspect
      captures = links.to_h do |link|
        bytes = @core.upload_bytes(link.fetch("uri").delete_prefix("nexus://uploads/"))
        [File.extname(link.fetch("name")), bytes]
      end
      assert_equal report, JSON.parse(captures.fetch(".json"))
      assert_includes captures.fetch(".diff"), "+blue marker"
      refute_includes captures.values.join, "fixture-t3-bearer"
    end
end
