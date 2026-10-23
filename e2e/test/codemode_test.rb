require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

# The fake provider authors one normal code call. Nexus, the rho daemon,
# JavaScript VM, child tools and task-operation HTTP are real product processes.
class CodemodeTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  AWAIT_SECONDS = 150
  World = Data.define(:daemon, :home, :project, :steward, :workspace)

  class << self
    def world(base_url)
      @world ||= begin
        steward = E2E::ActorProvisioning.world(base_url).rho_steward
        actor = E2E::StewardSession.actor(base_url: base_url, human: steward)
        home = Dir.mktmpdir("rho-codemode-e2e")
        project = Dir.mktmpdir("rho-codemode-project")
        File.write(File.join(home, "settings.json"), JSON.generate({ "settings_version" => 1, "plugins" => { "e2e.codemode-author" => { "enabled" => true,
          "source" => { "kind" => "path", "path" => File.expand_path("../support/codemode_author.rb", __dir__) } } } }), perm: 0o600)
        daemon = E2E::RhoDaemon.new(base_url: base_url, home: home, tools_root: project)
        @owned = [daemon, home, project]
        daemon.start
        E2E::Ceremony.confirm(actor: actor, started: daemon.start_ceremony, status: -> { daemon.status })
        workspace = daemon.await("the code daemon never adopted a workspace") do
          row = daemon.status["workspace"]
          raise "workspace failed: #{row.inspect}" if row && row["state"] == "error"

          row && row["state"] == "adopted" ? row.fetch("public_id") : nil
        end
        # Workspace adoption precedes the asynchronous profile tool declaration.
        daemon.await("the code daemon never declared its profile") do
          daemon.log_lines.find { |line| line["event"] == "profile.declared" }
        end
        daemon.await("the code daemon never declared its code tool") do
          tools = daemon.control(:get, "/e2e/code-context").fetch("tools")
          tools.any? { |tool| tool.dig("function", "name") == "code" }
        end
        E2E.enable_dev_lane!
        E2E.hosts.start
        World.new(daemon: daemon, home: home, project: project, steward: steward, workspace: workspace)
      end
    end

    def stop_world
      daemon, home, project = @owned
      @owned = @world = nil
      daemon&.stop
    ensure
      [home, project].compact.each { |path| FileUtils.remove_entry(path) if File.directory?(path) }
    end
  end

  Minitest.after_run { CodemodeTest.stop_world }

  def setup
    @base_url = E2E.base_url
    @world = self.class.world(@base_url)
  end

  def teardown
    return if passed?

    sources = Dir.glob(File.join(E2E.handle.fetch("log_dir"), "*.log")).sort.to_h do |path|
      ["nexus.#{File.basename(path)}", path]
    end
    if @world
      sources["daemon.log"] = @world.daemon.log_path
      sources["rho.log"] = @world.daemon.rho_log_path
    end
    directory = File.expand_path("../artifacts/codemode/#{Process.pid}/#{name}", __dir__)
    E2E::FailureDump.write(into: directory, sources: sources)
    warn "codemode failure logs: #{directory}"
    [@world&.daemon&.log_path, @world&.daemon&.rho_log_path].compact.each do |path|
      next unless File.file?(path)

      warn E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8).lines.last(100).join)
    end
  end

  def test_real_code_sequences_children_and_returns_only_its_selected_result
    path = File.join(@world.project, "sequential.txt")
    loop_id = start_program(<<~'JS', params: { "path" => path })
      await tools.write({path: params.path, content: "from durable code\n"});
      const read = await tools.read({path: params.path});
      text(JSON.stringify(read));
      return {finished: true};
    JS
    row = await_loop(loop_id, "completed")
    parent = completed_code(loop_id, row)
    assert_equal "from durable code\n", File.read(path, encoding: Encoding::UTF_8)
    tasks = row.fetch("tasks")
    assert_equal 1, tasks.count { |task| task["tool_name"] == "code" }
    assert_equal 1, tasks.count { |task| task["tool_name"] == "write" }
    assert_equal 1, tasks.count { |task| task["tool_name"] == "read" }
    assert_includes parent.fetch("output").to_s, "from durable code"
    assert_equal({ "finished" => true }, parent.fetch("structured_content"))
  end

  def test_conversation_code_mode_survives_restart_and_can_be_enabled_again
    source = "await tools.write({path: params.path, content: 'enabled again'}); text('code ran');"
    path = File.join(@world.project, "conversation-code-mode.txt")
    opened = open_program("text('initial code ran');")
    conversation = opened.fetch("conversation").fetch("public_id")
    initial_loop = program_loop(opened)
    assert_equal "initial code ran", completed_code(initial_loop, await_loop(initial_loop, "completed")).fetch("output")
    disabled = say_program(conversation, source, params: { "path" => path }, answered: 1, code_mode: false)
    assert_disabled_code(program_loop(disabled, conversation: conversation), path)

    @world.daemon.stop
    @world.daemon.start
    @world.daemon.await("the code daemon never resumed its member connection") do
      @world.daemon.status.fetch("state") == "active"
    end
    attached = @world.daemon.control(:post, "/followers/attach", body: {
      "public_id" => conversation, "host_type" => "conversation", "workspace_public_id" => @world.workspace,
    })
    refute attached.key?("error"), attached.inspect
    inherited = say_program(conversation, source, params: { "path" => path }, answered: 2)
    assert_disabled_code(program_loop(inherited, conversation: conversation), path)

    enabled = say_program(conversation, source, params: { "path" => path }, answered: 3, code_mode: true)
    enabled_loop = program_loop(enabled, conversation: conversation)
    assert_equal "code ran", completed_code(enabled_loop, await_loop(enabled_loop, "completed")).fetch("output")
    assert_code_mode(enabled_loop, enabled: true)
    assert_equal "enabled again", File.read(path, encoding: Encoding::UTF_8)
  ensure
    @world.daemon.start if @world && @world.daemon.pid.nil?
  end

  def test_real_code_can_forward_an_observed_child_capture
    path = File.join(@world.project, "report.txt")
    File.write(path, "published through a child\n")
    loop_id = start_program(<<~'JS', params: { "path" => path })
      const published = await tools.file_publish({path: params.path});
      for (const block of published.content || []) {
        if (block.type === "resource_link") resource(block);
      }
      text("published report");
      return false;
    JS
    row = await_loop(loop_id, "completed")
    parent = completed_code(loop_id, row)
    assert_equal false, parent.fetch("structured_content")
    link = parent.fetch("content").find { |block| block["type"] == "resource_link" }
    refute_nil link, parent.inspect
    assert_equal "report.txt", link.fetch("name")
    upload_id = link.fetch("uri").delete_prefix("nexus://uploads/")
    response = member_request("/agent_api/v1/uploads/#{upload_id}/bytes")
    assert_equal "200", response.code
    assert_equal "published through a child\n", response.body
  end

  def test_a_long_pause_retains_the_live_vm_and_delays_its_next_effect_until_resume
    before = File.join(@world.project, "before-pause.txt")
    after = File.join(@world.project, "after-pause.txt")
    source = <<~'JS'
      let local = 40;
      await tools.write({path: params.before, content: "before pause"});
      await nexus.ask({prompt: "Continue after the long pause?"});
      local += 2;
      await tools.write({path: params.after, content: String(local)});
      return {local};
    JS
    tools = @world.daemon.control(:get, "/e2e/code-context").fetch("tools")
    created = @world.daemon.control(:post, "/e2e/standalone-code", body: {
      "idempotency_key" => SecureRandom.uuid,
      "steps" => [{ "tool" => { "key" => "paused_code", "name" => "code", "route" => code_runner_route,
        "timeout_ms" => 30_000, "input" => { "code" => source, "params" => { "before" => before, "after" => after } },
        "model_defaults" => { "tools" => tools, "model" => { "model" => MODEL } } } }],
    })
    loop_id = created.fetch("public_id")
    held = await_claimed_question(loop_id)
    question = held.fetch("tasks").find { |task| task["kind"] == "await_task" }
    daemon_pid = @world.daemon.pid
    member_json("#{loop_path(loop_id)}/pause", method: :post, body: {})
    assert_equal "before pause", File.read(before, encoding: Encoding::UTF_8)

    # Let the actual wall clock exceed the authored grant. A paused Run keeps
    # its virtual deadline, while the live Runner must retain its execution.
    sleep 35
    assert_equal "paused", member_json(loop_path(loop_id)).fetch("run").fetch("status")
    assert_equal "dispatched", task_detail(loop_id, "paused_code").fetch("status")
    member_json("#{loop_path(loop_id)}/tasks/#{question.fetch("key")}/resolution",
      method: :post, body: { "content" => "Continue" })
    assert_equal "completed", task_detail(loop_id, question.fetch("key")).fetch("status")
    sleep 1
    refute File.exist?(after), "answering a question must not admit the next effect while paused"
    assert_equal "dispatched", task_detail(loop_id, "paused_code").fetch("status")

    member_json("#{loop_path(loop_id)}/resume", method: :post, body: {})
    row = await_loop(loop_id, "completed")
    assert_equal({ "local" => 42 }, completed_code(loop_id, row).fetch("structured_content"))
    assert_equal "42", File.read(after, encoding: Encoding::UTF_8)
    assert_equal daemon_pid, @world.daemon.pid
    assert_equal 1, row.fetch("tasks").count { |task| task["tool_name"] == "code" }
    assert_equal 1, row.fetch("tasks").count { |task| task["kind"] == "await_task" }
    assert_equal 2, row.fetch("tasks").count { |task| task["tool_name"] == "write" }
  end

  def test_a_killed_code_process_times_out_without_replaying_its_source
    before = File.join(@world.project, "before-restart.txt")
    after = File.join(@world.project, "after-restart.txt")
    source = <<~'JS'
      await tools.write({path: params.before, content: "accepted before death"});
      const answer = await nexus.ask({prompt: "Answer after the process has died?"});
      await tools.write({path: params.after, content: JSON.stringify(answer)});
      text("must not reconstruct this VM");
    JS
    tools = @world.daemon.control(:get, "/e2e/code-context").fetch("tools")
    # Author the ordinary finite park through the public step API. The default
    # ten-minute tool park is unsuitable for a focused owner-loss journey.
    created = @world.daemon.control(:post, "/e2e/standalone-code", body: {
      "idempotency_key" => SecureRandom.uuid,
      "steps" => [{ "tool" => { "key" => "lost_owner", "name" => "code", "route" => code_runner_route,
        "timeout_ms" => 30_000, "on_failure" => "absorb",
        "input" => { "code" => source, "params" => { "before" => before, "after" => after } },
        "model_defaults" => { "tools" => tools, "model" => { "model" => MODEL } } } }],
    })
    loop_id = created.fetch("public_id")
    held = await_claimed_question(loop_id)
    question = held.fetch("tasks").find { |task| task["kind"] == "await_task" }
    assert_equal "accepted before death", File.read(before, encoding: Encoding::UTF_8)
    old_pid = @world.daemon.pid
    @world.daemon.kill!
    member_json("#{loop_path(loop_id)}/tasks/#{question.fetch("key")}/resolution",
      method: :post, body: { "content" => "Continue" })
    refute File.exist?(after), "a persisted answer cannot execute JavaScript without its worker"

    @world.daemon.start
    refute_equal old_pid, @world.daemon.pid
    deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
    parent = loop do
      detail = task_detail(loop_id, "lost_owner")
      break detail if detail["status"] == "timed_out"
      flunk "the lost code owner never expired: #{detail.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

      sleep 0.2
    end
    assert_equal "tool_timeout", parent.dig("error", "key"), parent.inspect
    row = member_json(loop_path(loop_id)).fetch("run")
    assert_equal 1, row.fetch("tasks").count { |task| task["tool_name"] == "write" },
      "restarting the executor must not replay the source or submit its later write"
    assert_equal 1, row.fetch("tasks").count { |task| task["kind"] == "await_task" }
    assert_equal 1, row.fetch("tasks").count { |task| task["tool_name"] == "code" }
    assert_equal "accepted before death", File.read(before, encoding: Encoding::UTF_8)
    refute File.exist?(after), "a completed child answer cannot reconstruct its lost parent VM"
  ensure
    @world.daemon.start if @world && @world.daemon.pid.nil?
  end

  def test_restarting_kernel_hosts_preserves_the_live_claimed_code_invocation
    before = File.join(@world.project, "before-kernel-restart.txt")
    after = File.join(@world.project, "after-kernel-restart.txt")
    loop_id = start_program(<<~'JS', params: { "before" => before, "after" => after })
      await tools.write({path: params.before, content: "before kernel restart"});
      await nexus.ask({prompt: "Continue after restarting the kernel workers?"});
      await tools.write({path: params.after, content: "after kernel restart"});
      text("kernel recovered");
    JS
    held = await_claimed_question(loop_id)
    question = held.fetch("tasks").find { |task| task["kind"] == "await_task" }
    E2E.hosts.stop
    stopped = true
    member_json("#{loop_path(loop_id)}/tasks/#{question.fetch("key")}/resolution",
      method: :post, body: { "content" => "Continue" })
    assert_equal "completed", task_detail(loop_id, question.fetch("key")).fetch("status")
    E2E.hosts.start
    stopped = false

    row = await_loop(loop_id, "completed")
    assert_equal "kernel recovered", completed_code(loop_id, row).fetch("output")
    assert_equal "after kernel restart", File.read(after, encoding: Encoding::UTF_8)
    assert_equal 2, row.fetch("tasks").count { |task| task["tool_name"] == "write" }
  ensure
    E2E.hosts.start if stopped
  end

  private

    def start_program(source, params: {})
      program_loop(open_program(source, params: params))
    end

    def open_program(source, params: {}, code_mode: nil)
      @world.daemon.control(:post, "/conversations", body: {
        "prompt" => program_prompt(source, params: params),
        "model" => MODEL, "working_directory" => @world.project, "code_mode" => code_mode,
      }.compact)
    end

    def say_program(conversation, source, params: {}, answered:, code_mode: nil)
      document = @world.daemon.control(:post, "/say", body: {
        "public_id" => conversation, "workspace_public_id" => @world.workspace,
        "text" => program_prompt(source, params: params, answered: answered), "delivery_mode" => "queue",
        "model" => MODEL, "code_mode" => code_mode, "wait" => false,
      }.compact)
      assert_equal true, document["pending"], document.inspect
      refute document.key?("run"), document.inspect
      document
    end

    # The fake provider counts prior tool answers in the public conversation
    # history. The fixed reply keeps that history small across these turns.
    def program_prompt(source, params:, answered: 0)
      arguments = CGI.escape(JSON.generate({ "code" => source, "params" => params }))
      calls = Array.new(answered + 1, "code:#{arguments}").join(",")
      "!mock reply=code-finished tool_call=#{calls} -- execute the code and report its result"
    end

    def program_loop(document, conversation: nil)
      loop_id = document.dig("run", "public_id")
      return loop_id if loop_id

      unless document["pending"] == true && document.dig("input", "state") == "pending" &&
          !document["error"] && !document["blocked"]
        flunk "code conversation was refused: #{document.inspect}"
      end
      input_id = document.fetch("input").fetch("public_id")
      conversation ||= document.fetch("conversation").fetch("public_id")
      path = "/agent_api/v1/workspaces/#{@world.workspace}/conversations/#{conversation}/turns"
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        # An accepted input may materialize after the control response. Follow
        # its own turn so a previous or concurrently queued reply cannot win.
        turn = member_json(path).fetch("turns").find { |row| row["input_public_id"] == input_id }
        loop_id = turn&.dig("active_variant", "run_public_id")
        return loop_id if loop_id
        flunk "code input #{input_id} never materialized a loop" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.2
      end
    end

    def assert_disabled_code(loop_id, path)
      row = await_loop(loop_id, "completed")
      task = row.fetch("tasks").find { |entry| entry["tool_name"] == "code" }
      refute_nil task, "the provider must actually attempt the undeclared code call: #{row.inspect}"
      detail = task_detail(loop_id, task.fetch("key"))
      assert_equal %w[failed unknown_tool], [detail.fetch("status"), detail.dig("error", "key")], detail.inspect
      refute row.fetch("tasks").any? { |entry| entry["tool_name"] == "write" }, row.inspect
      refute File.exist?(path), "disabled code must not produce its requested effect"
      assert_code_mode(loop_id, enabled: false)
    end

    def assert_code_mode(loop_id, enabled:)
      definitions = task_detail(loop_id, "r1").fetch("tool_definitions")
      names = definitions.map { |entry| entry.fetch("function").fetch("name") }
      routed_code = definitions.select { |entry| entry.dig("route", "tool_name") == "code" }
      assert_equal enabled, !routed_code.empty?, "code mode covers the Runner alias as well as the Agent tool"
      assert_equal enabled, names.include?("code"), names.inspect
      request = member_json("#{loop_path(loop_id)}/tasks/r1/request").fetch("request")
      # Earlier turns retain their captured leads; the current preface is last.
      lead = request.fetch("entries").select { |entry| entry["role"] == "developer" }.last
        .fetch("parts").filter_map { |part| part["text"] }.join("\n")
      assert_equal enabled, lead.match?(/^- code: /), lead
    end

    def code_runner_route
      { "kind" => "runner", "runner_executor_public_id" => @world.daemon.status.fetch("identity").fetch("runner_executor_public_id") }
    end

    def loop_path(id) = "/agent_api/v1/workspaces/#{@world.workspace}/runs/#{id}"

    def await_loop(id, status)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        row = member_json(loop_path(id)).fetch("run")
        return row if row["status"] == status
        flunk "code loop ended unexpectedly: #{row.inspect}" if %w[failed stopped canceled].include?(row["status"])
        flunk "code loop never reached #{status}: #{row.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.2
      end
    end

    def task_detail(loop_id, key) = member_json("#{loop_path(loop_id)}/tasks/#{key}").fetch("task")

    def completed_code(loop_id, row)
      task = row.fetch("tasks").find { |candidate| candidate["tool_name"] == "code" }
      refute_nil task, row.inspect
      detail = task_detail(loop_id, task.fetch("key"))
      assert_equal "completed", detail.fetch("status"), detail.inspect
      detail
    end

    def await_claimed_question(loop_id)
      @world.daemon.await("the claimed code never reached its question") do
        row = member_json(loop_path(loop_id)).fetch("run")
        parent = row.fetch("tasks").find { |task| task["tool_name"] == "code" }
        question = row.fetch("tasks").find { |task| task["kind"] == "await_task" }
        if parent && %w[completed failed canceled timed_out uncertain].include?(parent["status"])
          flunk "code ended before its question: #{task_detail(loop_id, parent.fetch("key")).inspect}"
        end
        row if parent&.fetch("status") == "dispatched" && question&.fetch("status") == "awaiting_input"
      end
    end

    def member_json(path, **options)
      response = member_request(path, **options)
      assert_equal "200", response.code, E2E::SecretHygiene.redact(response.body)
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def member_request(path, method: :get, body: nil, idempotency_key: nil)
      uri = URI.join(@base_url, path)
      request = method == :post ? Net::HTTP::Post.new(uri) : Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@world.steward.member_token}"
      request["Idempotency-Key"] = idempotency_key if idempotency_key
      if body
        request["Content-Type"] = "application/json"
        request.body = JSON.generate(body)
      end
      Net::HTTP.start(uri.hostname, uri.port, open_timeout: 10, read_timeout: 30) { |http| http.request(request) }
    end
end
