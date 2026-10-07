require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "time"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/executor_process"
require "support/rho_daemon"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/session_sign_in_budget"

# One Run can address two execution environments through distinct callable
# names while preserving each Runner's exact schema. A host's default changes
# future acceptance only; queued, dispatched and claimed work retain targets.
class MultiEnvironmentTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  REGISTRATION_IDENTIFIER = "e2e-multi-environment-runner".freeze
  RUNNER_DISPLAY_NAME = "E2E second environment".freeze
  ECHO_TOOLS = %w[read grep slow_read slow_write bash write].freeze
  ROOT_DELETE_REASON = "recursive delete of a root directory".freeze
  INCUBATION_REASON = "direct installation edits are disabled; use managed extensions or develop a separate rho successor".freeze
  AWAIT_SECONDS = 120

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @steward_client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @actor = E2E::BrowserActor.new(@base_url)
    @owner = E2E::BrowserActor.new(@base_url)
    @device = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
    @home = Dir.mktmpdir("rho-multi-environment-e2e")
    File.write(File.join(@home, "settings.json"), JSON.generate(E2E::RhoDaemon.dev_settings(plugins: {
      "e2e.tool-catalog-author" => { "enabled" => true,
        "source" => { "kind" => "path", "path" => File.expand_path("../support/tool_catalog_author.rb", __dir__) } },
    })), perm: 0o600)
    @executor_home = Dir.mktmpdir("e2e-multi-environment-runner")
    @h_root = File.join(@executor_home, "tree")
    FileUtils.mkdir_p(@h_root)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    @process = nil
    sign_in(@actor, email: @steward.email, password: @steward.password)
    sign_in(@owner, email: @world.owner_email, password: @world.owner_password)
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "rho daemon stdout")
      warn_log(@daemon&.rho_log_path, "rho structured log")
      warn_log(@process&.log_path, "harness runner log")
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/multi-environment-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture multi-environment E2E capture: #{error.class}: #{error.message}"
  ensure
    stop_quietly("the harness runner") { @process&.stop }
    stop_quietly("the rho daemon") { @daemon&.stop }
    @actor&.close
    @owner&.close
    [@home, @executor_home].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  def test_explicit_targets_preserve_schemas_and_survive_default_changes
    boot_rho
    before_tools = rho_model_tools(start_rho_run([]))
    before_catalog_size = rho_tool_catalog.length
    @process = grant_and_start_harness_runner
    discovery_keeps_the_two_environments_distinct
    one_run_calls_both_read_tools_with_their_exact_schemas
    deferred_tools_preserve_exact_routes_and_stable_schemas(before_tools, before_catalog_size)
    routed_guards_refuse_discovery_calls_and_code_before_runner_claim
    code_mode_off_excludes_code_from_discovery_and_calling
    suspended_code_keeps_its_frozen_runner_after_default_change
    a_default_change_preserves_accepted_tasks_on_an_offline_runner
    cli_default_selection_accepts_distinct_routed_schemas
    revoked_targets_are_refused
  end

  private

    def discovery_keeps_the_two_environments_distinct
      listed = @steward_client.executors.list(kind: "runner")
      assert_includes listed.map(&:public_id), @rho_runner
      assert_includes listed.map(&:public_id), @h
      @local_executor = @steward_client.executors.show(@rho_runner)
      @remote_executor = @steward_client.executors.show(@h)
      assert_equal ECHO_TOOLS.sort, @remote_executor.tool_names.sort
      assert_equal @h_root, @remote_executor.environment.fetch("root")
      @local_read = @local_executor.served_tools.find { |tool| tool.name == "read" }
      @remote_read = @remote_executor.served_tools.find { |tool| tool.name == "read" }
      refute_equal @local_read.input_schema, @remote_read.input_schema,
        "the coding Runner and echo Runner really expose different read schemas"
    end

    def declaration(callable, executor_public_id, announcement)
      {
        "type" => "function",
        "function" => { "name" => callable, "description" => announcement.description,
          "parameters" => announcement.input_schema },
        "route" => { "kind" => "runner", "runner_executor_public_id" => executor_public_id,
          "tool_name" => announcement.name },
      }
    end

    def one_run_calls_both_read_tools_with_their_exact_schemas
      root = File.join(@home, "project")
      FileUtils.mkdir_p(root)
      @note = File.join(root, "multi-environment.txt")
      @marker = "local-file-#{SecureRandom.hex(4)}"
      File.write(@note, "#{@marker}\n")
      definitions = [declaration("local_read", @rho_runner, @local_read), declaration("remote_read", @h, @remote_read)]
      args = CGI.escape(JSON.generate("path" => @note))
      prompt = "!mock tool_call=local_read:#{args},remote_read:#{args} -- summarize both results"
      run_id = author_and_start(nil, [{ "model" => {
        "key" => "plan", "model" => { "model" => MODEL }, "prompt" => prompt, "tools" => definitions,
      } }])
      completed = await_run_status(run_id, "completed")
      calls = completed.fetch("tasks").select { |task| task["tool_name"] == "read" }
      assert_equal %w[local_read remote_read], calls.map { |task| task.fetch("tool_alias") }.sort
      local = calls.find { |task| task["tool_alias"] == "local_read" }
      remote = calls.find { |task| task["tool_alias"] == "remote_read" }
      [[local, @rho_runner], [remote, @h]].each do |task, target|
        assert_equal "completed", task.fetch("status")
        assert_equal target, task.dig("target", "executor_public_id")
        assert_equal target, task.dig("claimed_by", "executor_public_id")
      end
      assert_includes task_output(run_id, local.fetch("key")), @marker
      assert_includes task_output(run_id, remote.fetch("key")), "echo:read:"
      wire = agent_api("#{run_path(run_id)}/tasks/plan/request").dig("request", "request_options", "tools")
      refute_nil wire
      assert_equal definitions.map { |entry| entry.fetch("function") },
        wire.map { |entry| entry.fetch("function").reject { |key, _| key == "strict" } }
      refute wire.any? { |entry| entry.key?("route") }, "provider schemas contain no Runner routing metadata"
    end

    def deferred_tools_preserve_exact_routes_and_stable_schemas(before_tools, before_catalog_size)
      @daemon.control(:get, "/runners")
      assembly = rho_tool_assembly
      assert_equal before_catalog_size, assembly.fetch("tool_definitions").length,
        "adding a candidate does not import its tools into the current environment"
      refute assembly.fetch("tool_definitions").any? { |entry| entry.dig("route", "runner_executor_public_id") == @h }
      assert_includes assembly.fetch("environment").fetch("runner_candidates").map { |row| row.fetch("runner_executor_public_id") }, @h
      configuration = @daemon.control(:get, "/e2e/tool-catalog").fetch("configuration")
      explicit = rho_tool_assembly(runner: @h).fetch("tool_definitions").select do |tool|
        tool.dig("route", "runner_executor_public_id") == @h
      end.map do |tool|
        tool.merge("function" => tool.fetch("function").merge("name" => "remote_#{tool.dig("route", "tool_name")}"))
      end
      configuration = configuration.merge("tool_definitions" => configuration.fetch("tool_definitions") + explicit)
      compiled = rho_tool_assembly(configuration: configuration)
      @daemon.control(:post, "/e2e/tool-catalog", body: configuration)
      catalog = rho_tool_catalog
      assert_equal compiled.fetch("tool_definitions"), catalog, "the explicit multi-Runner surface uses the kernel's exact assembly"
      assert_operator catalog.length, :>, before_catalog_size
      local = routed_tool(catalog, @rho_runner, "read")
      remote = routed_tool(catalog, @h, "read")
      [local, remote].each { |entry| assert_equal true, entry.fetch("defer_loading") }
      run_id = start_rho_run([
        ["tool_search", { "query" => remote.dig("function", "name") }],
        ["tool_call", { "name" => local.dig("function", "name"), "input" => { "path" => @note } }],
        ["tool_call", { "name" => remote.dig("function", "name"), "input" => { "path" => @note } }],
      ])
      completed = await_run_status(run_id, "completed")
      assert_equal before_tools, rho_model_tools(run_id), "adding a Runner leaves the eager provider schemas byte-stable"
      search = completed.fetch("tasks").find { |task| task["tool_name"] == "tool_search" }
      found = JSON.parse(task_output(run_id, search.fetch("key"))).fetch("tools").fetch(0)
      assert_equal remote.fetch("route"), found.fetch("route")
      assert_equal @remote_read.input_schema, found.dig("definition", "function", "parameters")
      calls = completed.fetch("tasks").select { |task| task["tool_name"] == "read" }
      assert_equal [@rho_runner, @h].sort, calls.map { |task| task.dig("target", "executor_public_id") }.sort
      calls.each do |task|
        assert_equal "completed", task.fetch("status")
        assert_equal task.dig("target", "executor_public_id"), task.dig("claimed_by", "executor_public_id")
        marker = task.dig("target", "executor_public_id") == @rho_runner ? @marker : "echo:read:"
        assert_includes task_output(run_id, task.fetch("key")), marker
      end
      completed.fetch("tasks").select { |task| task["kind"] == "model_task" }.each do |task|
        assert_equal before_tools, model_tools(run_id, task.fetch("key")),
          "discovery delivers schemas as results without rewriting later model tool lists"
      end
    end

    def routed_guards_refuse_discovery_calls_and_code_before_runner_claim
      catalog = rho_tool_catalog
      protected_path = File.join(File.realpath(@home), "settings.json")
      original = File.read(protected_path)
      calls = [@rho_runner, @h].flat_map do |runner|
        [
          [routed_tool(catalog, runner, "bash").dig("function", "name"), { "command" => "printf rm -rf /" }],
          [routed_tool(catalog, runner, "write").dig("function", "name"), { "path" => protected_path, "content" => "must not write" }],
        ]
      end
      wrapped = start_rho_run(calls.map { |name, input| ["tool_call", { "name" => name, "input" => input }] })
      assert_routed_guards_refused(wrapped)

      code = routed_tool(catalog, @rho_runner, "code").dig("function", "name")
      program = <<~JS
        for (const [name, input] of #{JSON.generate(calls)}) {
          try { await tools[name](input); } catch (_) {}
        }
        return {checked: 4};
      JS
      continued = start_rho_run([["tool_call", { "name" => code, "input" => { "code" => program } }]], code_mode: true)
      row = assert_routed_guards_refused(continued)
      code_task = row.fetch("tasks").find { |task| task["tool_name"] == "code" }
      assert_equal "completed", code_task.fetch("status")
      detail = agent_api("#{run_path(continued)}/tasks/#{code_task.fetch("key")}").fetch("task")
      assert_equal({ "checked" => 4 }, detail.fetch("structured_content"))
      assert_equal original, File.read(protected_path), "neither Runner changed rho's protected settings"
    end

    def assert_routed_guards_refused(run_id)
      row = await_run_status(run_id, "completed")
      calls = row.fetch("tasks").select { |task| %w[bash write].include?(task["tool_name"]) }
      expected = [@rho_runner, @h].product(%w[bash write]).sort
      assert_equal expected, calls.map { |task| [task.dig("target", "executor_public_id"), task.fetch("tool_name")] }.sort
      calls.each do |task|
        reason = task.fetch("tool_name") == "bash" ? ROOT_DELETE_REASON : INCUBATION_REASON
        assert_equal "failed", task.fetch("status")
        assert_equal({ "key" => "approval_denied", "detail" => reason }, task.fetch("error"))
        refute task.key?("claimed_by"), "the kernel denied the served name before its Runner could claim"
        refute task.key?("approval"), "a deny rule never becomes an approval grant"
      end
      row
    end

    def code_mode_off_excludes_code_from_discovery_and_calling
      code = routed_tool(rho_tool_catalog, @rho_runner, "code").dig("function", "name")
      run_id = start_rho_run([
        ["tool_search", { "query" => code }],
        ["tool_call", { "name" => code, "input" => { "code" => "text('must not execute');" } }],
      ])
      completed = await_run_status(run_id, "completed")
      search = completed.fetch("tasks").find { |task| task["tool_name"] == "tool_search" }
      assert_empty JSON.parse(task_output(run_id, search.fetch("key"))).fetch("tools")
      wrapper = completed.fetch("tasks").find { |task| task["tool_name"] == "tool_call" }
      assert_includes task_output(run_id, wrapper.fetch("key")), "unknown_tool_name"
      refute completed.fetch("tasks").any? { |task| task["tool_name"] == "code" }
    end

    def suspended_code_keeps_its_frozen_runner_after_default_change
      catalog = rho_tool_catalog
      code = routed_tool(catalog, @rho_runner, "code").dig("function", "name")
      read = routed_tool(catalog, @rho_runner, "read").dig("function", "name")
      program = "await nexus.ask({prompt: 'Continue on the original Runner?'}); " \
        "return await tools[#{JSON.generate(read)}]({path: #{JSON.generate(@note)}});"
      run_id = start_rho_run([["tool_call", { "name" => code, "input" => { "code" => program } }]], code_mode: true)
      held = await("the code did not suspend on its question") do
        row = run_row(run_id)
        row if row.fetch("tasks").any? { |task| task["kind"] == "await_task" && task["status"] == "awaiting_input" }
      end
      context = @steward_client.workspace(@workspace_public_id).conversation(held.dig("turn", "conversation_public_id"))
      context.set_default_runner(executor_public_id: @h)
      question = held.fetch("tasks").find { |task| task["kind"] == "await_task" }
      _response, status = agent_api_post("#{run_path(run_id)}/tasks/#{question.fetch("key")}/resolution",
        { "content" => "Continue" })
      assert_equal 200, status
      completed = await_run_status(run_id, "completed")
      code_task = completed.fetch("tasks").find { |task| task["tool_name"] == "code" }
      assert_equal "completed", code_task.fetch("status")
      read_task = completed.fetch("tasks").find { |task| task["tool_name"] == "read" }
      refute_nil read_task
      assert_equal @rho_runner, read_task.dig("target", "executor_public_id")
      assert_equal @rho_runner, read_task.dig("claimed_by", "executor_public_id")
      assert_includes task_output(run_id, read_task.fetch("key")), @marker
    end

    def rho_tool_catalog
      rho_tool_assembly.fetch("tool_definitions")
    end

    def rho_tool_assembly(runner: @rho_runner, configuration: nil)
      body = { "default_runner_executor_public_id" => runner }
      body["configuration"] = configuration if configuration
      @daemon.control(:post, "/e2e/tool-assembly", body: body)
    end

    def routed_tool(catalog, runner_id, name)
      catalog.find { |entry| entry.dig("route", "runner_executor_public_id") == runner_id &&
        entry.dig("route", "tool_name") == name } || flunk("#{runner_id} did not declare #{name}")
    end

    def start_rho_run(calls, code_mode: false)
      encoded = calls.map { |name, input| "#{name}:#{CGI.escape(JSON.generate(input))}" }.join(",")
      prompt = "!mock reply=done #{encoded.empty? ? "" : "tool_call=#{encoded}"} -- finish the requested tools"
      document = @daemon.control(:post, "/conversations", body: {
        "prompt" => prompt, "model" => MODEL, "working_directory" => @home, "code_mode" => code_mode,
      })
      return document.dig("run", "public_id") if document.dig("run", "public_id")

      assert_equal true, document["pending"], document.inspect
      conversation = document.fetch("conversation").fetch("public_id")
      input_id = document.fetch("input").fetch("public_id")
      await("rho input #{input_id} never started") do
        turns = agent_api("/agent_api/v1/workspaces/#{@workspace_public_id}/conversations/#{conversation}/turns")
        turns.fetch("turns").find { |turn| turn["input_public_id"] == input_id }&.dig("active_variant", "run_public_id")
      end
    end

    def rho_model_tools(run_id)
      row = await_run_status(run_id, "completed")
      model = row.fetch("tasks").find { |task| task["kind"] == "model_task" }
      model_tools(run_id, model.fetch("key"))
    end

    def model_tools(run_id, key)
      agent_api("#{run_path(run_id)}/tasks/#{key}/request").dig("request", "request_options", "tools")
    end

    def a_default_change_preserves_accepted_tasks_on_an_offline_runner
      @process.kill!
      steps = [{ "parallel" => [
        { "tool" => { "key" => "before", "name" => "read", "input" => { "path" => @note },
          "route" => { "kind" => "runner" }, "timeout_ms" => 120_000 } },
        { "tool" => { "key" => "explicit", "name" => "slow_read", "input" => { "seconds" => 0.1 },
          "route" => { "kind" => "runner", "runner_executor_public_id" => @h }, "timeout_ms" => 120_000 } },
      ] }, { "model" => { "key" => "joined", "model" => { "model" => MODEL },
        "prompt" => "!mock -- finish the accepted work" } }]
      run_id = author_and_start(@h, steps)
      before = await("both tasks were not dispatched to the offline Runner") do
        run = run_row(run_id)
        tasks = run.fetch("tasks").select { |task| %w[before explicit].include?(task["key"]) }
        run if tasks.length == 2 && tasks.all? { |task| task["status"] == "dispatched" && !task.key?("claimed_by") }
      end
      context = @steward_client.workspace(@workspace_public_id).run(run_id)
      selected = context.set_default_runner(executor_public_id: @rho_runner)
      assert_equal @rho_runner, selected.default_runner.executor_public_id
      after = run_row(run_id)
      %w[before explicit].each do |key|
        original = task_of(before, key)
        current = task_of(after, key)
        assert_equal @h, current.dig("target", "executor_public_id")
        assert_equal @h, current.dig("addressed_to", "executor_public_id")
        assert_equal original.fetch("started_at"), current.fetch("started_at")
        assert_equal "dispatched", current.fetch("status")
      end
      context.append(steps: [{ "tool" => {
        "key" => "after", "name" => "read", "input" => { "path" => @note }, "route" => { "kind" => "runner" },
      } }], idempotency_key: SecureRandom.uuid)
      assert_equal @rho_runner, task_of(run_row(run_id), "after").dig("target", "executor_public_id")
      context.set_default_runner(executor_public_id: nil)
      assert_nil context.fetch.default_runner
      @process.start
      completed = await_run_status(run_id, "completed")
      assert_equal @h, task_of(completed, "before").dig("claimed_by", "executor_public_id")
      assert_equal @h, task_of(completed, "explicit").dig("claimed_by", "executor_public_id")
      assert_equal @rho_runner, task_of(completed, "after").dig("claimed_by", "executor_public_id")
      assert_includes task_output(run_id, "before"), "echo:read:"
      assert_includes task_output(run_id, "after"), @marker
    end

    def cli_default_selection_accepts_distinct_routed_schemas
      output, status = @daemon.cli("do", "!mock -- ready", "--model", MODEL)
      assert_predicate status, :success?, output
      @conversation = output[/^conversation:\s+(\S+)/, 1]
      refute_nil @conversation, output
      output, status = @daemon.cli("set_default_runner", @conversation, @h)
      assert_predicate status, :success?, output
      chat = @steward_client.workspace(@workspace_public_id).conversation(@conversation)
      assert_equal @h, chat.fetch.default_runner.executor_public_id
      output, status = @daemon.cli("call_tool", @h, "read", JSON.generate("path" => @note))
      assert_predicate status, :success?, output
      assert_match(/^run:\s+\S+/, output)
      assert_includes output, "echo:read:"
      output, status = @daemon.cli("set_default_runner", @conversation, @rho_runner)
      assert_predicate status, :success?, output
      assert_equal @rho_runner, chat.fetch.default_runner.executor_public_id
    end

    def revoked_targets_are_refused
      @process.stop
      @device.revoke(token: @h_credential)
      context = @steward_client.workspace(@workspace_public_id).conversation(@conversation)
      error = assert_raises(CybrosAgent::Api::Conflict) { context.set_default_runner(executor_public_id: @h) }
      assert_equal "runner_not_eligible", error.code
      assert_equal @rho_runner, context.fetch.default_runner.executor_public_id
    end

    def author_and_start(default_runner, steps)
      created = @steward_client.workspace(@workspace_public_id).runs.create(steps: steps,
        default_runner_executor_public_id: default_runner, prompt_mechanism: "raw", approval_mode: "bypass",
        idempotency_key: SecureRandom.uuid)
      context = @steward_client.workspace(@workspace_public_id).run(created.run.public_id)
      context.start
      created.run.public_id
    end

    def run_path(run_id) = "/agent_api/v1/workspaces/#{@workspace_public_id}/runs/#{run_id}"
    def run_row(run_id) = agent_api(run_path(run_id)).fetch("run")
    def task_of(run, key) = run.fetch("tasks").find { |task| task.fetch("key") == key }
    def task_output(run_id, key) = agent_api("#{run_path(run_id)}/tasks/#{key}").dig("task", "output").to_s

    def await_run_status(run_id, status)
      await("Run #{run_id} never reached #{status}") do
        run = run_row(run_id)
        run if run.fetch("status") == status
      end
    end

    def boot_rho
      @daemon.start
      E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
      adopted = await_workspace_state("adopted")
      @workspace_public_id = adopted.dig("workspace", "public_id")
      @rho_runner = adopted.dig("identity", "runner_executor_public_id")
      refute_nil @rho_runner, "a full-mode rho registers a runner row: #{adopted["identity"].inspect}"
      await_rho_announced
      E2E.enable_dev_lane!
      E2E.hosts.start
    end

    # THE ACCOUNT-WIDE GRANT: the founding owner walks the machine page — the selector is theirs —
    # so H is eligible for the steward's Runs and rho's Agent hosts. One budget consume; the
    # credential reaches the child on stdin; the root rides argv.
    def grant_and_start_harness_runner
      E2E::DeviceAuthorizationBudget.consume
      authorization = @device.request_runner_authorization(
        registration_identifier: REGISTRATION_IDENTIFIER, runner_display_name: RUNNER_DISPLAY_NAME
      )
      assert_equal :runner, authorization.branch
      E2E::RunnerGrant.visit_connection(actor: @owner, authorization: authorization)
      case (offer = E2E::RunnerGrant.scope_offer(@owner))
      when :selector
        E2E::RunnerGrant.connect_in_browser(actor: @owner, authorization: authorization, account_wide: true)
      when :account_wide
        E2E::RunnerGrant.connect_in_browser(actor: @owner, authorization: authorization, existing_runner_scope: :account_wide)
      else
        flunk "the multi-environment runner must be account-wide, and the owner's page offered #{offer.inspect}"
      end
      credentials = @device.await_credentials(authorization)
      @h_credential = credentials.executor_access_token
      assert_nil credentials.access_token, "a machine is a delivery address, never a member principal"

      process = E2E::ExecutorProcess.new(base_url: @base_url, home: @executor_home,
        credential: credentials.executor_access_token, tools: ECHO_TOOLS, environment: @h_root)
      process.start
      assert_equal ECHO_TOOLS.sort, process.announced.sort, "the process announced what it was asked to"
      assert_equal @h_root, process.announced_environment_root, "the process announced its root"
      @h = process.executor_public_id
      process
    end

    def await_rho_announced
      @daemon.await("rho never announced its tools") do
        runner = @daemon.control(:get, "/runner")["runner"]
        runner if runner && runner["announced"] == runner.fetch("tools").length
      end
    end

    def await(message, every: 0.5)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = yield
        return latest if latest
        flunk "#{message}; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep every
      end
    end

    # The MEMBER plane, as the person who owns the work. UTF-8 by name: the
    # test process inherits the machine's empty locale.
    def agent_api(path)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Get.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      JSON.parse(response.body.force_encoding(Encoding::UTF_8))
    end

    def agent_api_post(path, body)
      uri = URI.join(@base_url, path)
      request = Net::HTTP::Post.new(uri)
      request["Authorization"] = "Bearer #{@steward.member_token}"
      request["Content-Type"] = "application/json"
      request["Idempotency-Key"] = SecureRandom.uuid
      request.body = JSON.generate(body)
      response = Net::HTTP.start(uri.hostname, uri.port) { |http| http.request(request) }
      text = response.body.to_s.force_encoding(Encoding::UTF_8)
      [JSON.parse(text.empty? ? "{}" : text), response.code.to_i]
    end

    def await_workspace_state(state)
      @daemon.await("the daemon never reported workspace #{state}") do
        document = @daemon.status
        workspace = document["workspace"]
        flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == state ? document : nil
      end
    end

    # One sign-in per browser: the steward's for the ceremony, the owner's
    # for the account-wide grant and the revoke — two of the shared budget.
    def sign_in(actor, email:, password:)
      page = actor.page
      actor.visit("/session/new")
      page.fill_in "Email", with: email
      page.fill_in "Password", with: password
      E2E::SessionSignInBudget.consume
      page.click_button "Sign in"
      assert page.has_text?("Dashboard")
    end

    def stop_quietly(label)
      yield
    rescue StandardError => error
      warn "Could not stop #{label}: #{error.class}: #{error.message}"
    end

    LOG_TAIL_LINES = 120

    def warn_log(path, label)
      return unless path && File.file?(path)

      tail = File.read(path, encoding: Encoding::UTF_8).scrub.lines.last(LOG_TAIL_LINES).join
      warn "#{label} (last #{LOG_TAIL_LINES} lines):\n#{E2E::SecretHygiene.redact(tail)}"
    end
end
