require "test_helper"
require "cgi/escape"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "tmpdir"
require "rho"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/executor_process"
require "support/runner_grant"
require "support/secret_hygiene"
require "support/session_sign_in_budget"
require_relative "../../protocol/support/fake_executor_process"

# Local environments retain application-family ownership. A separate environment
# host exercises the real rho-env attachment tool with only executor authority.
class RhoApplicationEnvironmentTest < Minitest::Test
  MODEL = "dev/mock-text".freeze
  TROUBLE = /runner_task_failed|runner_submit_refused/

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::BrowserActor.new(@base_url)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-application-e2e")
    @runner_home = Dir.mktmpdir("rho-environment-e2e")
    @daemon = nil
    @runner = nil
    sign_in_steward
  end

  def teardown
    unless passed?
      warn_log(@daemon&.log_path, "agent rho stdout")
      warn_log(@daemon&.rho_log_path, "agent rho structured log")
      warn_log(@runner&.log_path, "runner rho stdout")
      warn_log(@runner&.rho_log_path, "runner rho structured log")
      E2E::SecretHygiene.save_screenshot(
        @actor,
        File.expand_path("../artifacts/screenshots/rho_application_environment-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture rho environment E2E capture: #{error.class}: #{error.message}"
  ensure
    @environment&.stop
    [@runner, @daemon].compact.each do |daemon|
      if (result = daemon.dispose_connection)
        output, status = result
        assert_predicate status, :success?, output
      end
    end
    @actor&.close
    [@home, @runner_home].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  def test_two_applications_of_one_human_only_address_their_own_local_environments
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    @runner = E2E::RhoDaemon.new(base_url: @base_url, home: @runner_home)
    [@daemon, @runner].each { |daemon| boot_application(daemon) }
    first_runner = @daemon.status.fetch("identity").fetch("runner_executor_public_id")
    second_runner = @runner.status.fetch("identity").fetch("runner_executor_public_id")
    refute_equal first_runner, second_runner

    [[@daemon, first_runner, second_runner], [@runner, second_runner, first_runner]].each do |daemon, own, other|
      visible = daemon.control(:get, "/runners", expected_status: 200).fetch("runners").map { |row| row.fetch("public_id") }
      assert_includes visible, own
      refute_includes visible, other, "another application's Runner is not shared by Human ownership"
    end

    E2E.hosts.start
    [[@daemon, first_runner], [@runner, second_runner]].each do |daemon, own|
      path = File.join(daemon.home, "work", "private-runner.txt")
      FileUtils.mkdir_p(File.dirname(path))
      marker = "private-runner-#{SecureRandom.hex(6)}"
      File.write(path, "#{marker}\n")
      result = daemon.control(:post, "/runs/call_tool", expected_status: 200, body: {
        runner_executor_public_id: own, tool: "read", input: { path: path },
      }).fetch("call_tool").fetch("task")
      assert_equal "completed", result.fetch("status")
      assert_equal own, result.fetch("addressed_to").fetch("executor_public_id")
      assert_includes result.fetch("output"), marker
    end

    [[@daemon, second_runner], [@runner, first_runner]].each do |daemon, other|
      refused = daemon.control(:post, "/runs/call_tool", expected_status: 422, body: {
        runner_executor_public_id: other, tool: "read", input: { path: "private-runner.txt" },
      })
      assert_equal "executor_environment_unavailable", refused.fetch("error").fetch("code"),
        "an explicit foreign UUID cannot bypass Runner discovery"
      workspace = daemon.status.fetch("workspace").fetch("public_id")
      error = assert_raises(CybrosAgent::Api::InvalidRequest) do
        daemon.member_client.workspace(workspace).runs.start_tool_call(
          runner_executor_public_id: other, tool: "read", input: { path: "private-runner.txt" },
          idempotency_key: SecureRandom.uuid)
      end
      assert_equal "runner_not_eligible", error.code, "the kernel also refuses direct admission"
    end
  end

  def test_default_boot_and_restart_use_one_application_address_for_both_roles
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    boot_application(@daemon)
    original = @daemon.status.fetch("identity")
    assert_equal original.fetch("executor_public_id"), original.fetch("runner_executor_public_id")
    @daemon.stop
    @daemon.start
    @daemon.await_announced(address: "runner")
    restarted = await_workspace_state("adopted").fetch("identity")
    assert_equal original.fetch("user_public_id"), restarted.fetch("user_public_id")
    assert_equal original.fetch("executor_public_id"), restarted.fetch("executor_public_id")
    assert_equal restarted.fetch("executor_public_id"), restarted.fetch("runner_executor_public_id")
  end

  def test_the_application_calls_an_independent_sdk_fake_runner
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    boot_application(@daemon)
    credentials = environment_credentials
    @environment = E2E::FakeExecutorProcess.new(base_url: @base_url, home: @runner_home,
      credential: credentials.executor_access_token, tools: ["echo"], directory: @runner_home).start
    E2E.hosts.start
    marker = "foreign-implementation-#{SecureRandom.hex(6)}"
    result = @daemon.control(:post, "/runs/call_tool", expected_status: 200, body: {
      runner_executor_public_id: @environment.executor_public_id, tool: "echo", input: { value: marker },
    }).fetch("call_tool").fetch("task")
    assert_equal "completed", result.fetch("status")
    assert_equal @environment.executor_public_id, result.fetch("addressed_to").fetch("executor_public_id")
    assert_includes result.fetch("output"), marker
    assert_equal 1, @environment.claims.length
  end

  def test_a_runner_without_a_member_plane_imports_a_file_from_an_earlier_turn
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home)
    boot_application(@daemon)
    workspace_public_id = @daemon.status.fetch("workspace").fetch("public_id")
    runner_id = boot_environment
    E2E.enable_dev_lane!
    E2E.hosts.start

    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    marker = "remote-attachment-#{SecureRandom.hex(6)}"
    source = File.join(project, "input.md")
    File.binwrite(source, "# Notes\n#{marker}\n")
    core = Rho::Core.new(home: Rho::Home.resolve(base_url: @base_url, root: @home))
    opened = core.open_conversation(prompt: "!mock reply=received -- keep this file", model: MODEL,
      directory: project, runner: runner_id, attachments: [source])
    prepared = opened.fetch("run").fetch("public_id")
    await_loop_completion(workspace_public_id, prepared)
    import = runner_callable(workspace_public_id, prepared, runner_id, "file_import")
    conversation_id = opened.fetch("conversation").fetch("public_id")
    turns = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation_id}/turns").fetch("turns")
    upload = turns.fetch(0).fetch("active_variant").fetch("attachments").fetch(0).fetch("public_id")
    # Remove the sender's source so the subsequent read proves transfer from
    # Nexus, even though this harness runs its two homes on one machine.
    File.unlink(source)

    args = CGI.escape(JSON.generate("upload" => "nexus://uploads/#{upload}"))
    admitted = core.say(conversation_id,
      "!mock tool_call=#{import}:#{args} reply=imported -- import the earlier file", mode: "queue")
    loop_id = admitted.fetch("run").fetch("public_id")
    completed = await_loop_completion(workspace_public_id, loop_id)
    imported = completed.fetch("tasks").find { |task| task["tool_name"] == "file_import" }
    refute_nil imported, summarize(completed)
    assert_equal "completed", imported.fetch("status")
    assert_equal runner_id, imported.fetch("addressed_to").fetch("executor_public_id")
    assert_equal "runner", imported.fetch("addressed_to").fetch("role")
    detail = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}/tasks/#{imported.fetch("key")}").fetch("task")
    path = detail.fetch("structured_content").fetch("path")
    assert_equal "# Notes\n#{marker}\n", File.binread(path)
    refute_equal source, path
    assert_includes @environment.claims.map { |claim| claim.fetch("task") }, imported.fetch("key")
    refute_match TROUBLE, @environment.log_text
  end

  private

    LOOP_POLL = 1
    AWAIT_SECONDS = 120

    def boot_application(daemon)
      File.write(File.join(daemon.home, "settings.json"),
        JSON.generate({ "settings_version" => 2, "plugins" => { "rho.codemode" => { "enabled" => false } } }), perm: 0o600)
      daemon.start
      started = daemon.start_ceremony
      assert_equal "agent", started.fetch("branch")
      E2E::Ceremony.confirm(actor: @actor, started: started, status: -> { daemon.status })
      daemon.await("the application never adopted its workspace") { daemon.status.dig("workspace", "state") == "adopted" }
      daemon.await_announced(address: "runner")
    end

    def environment_credentials
      client = CybrosAgent::DeviceFlow::Client.new(base_url: @base_url, sleeper: ->(_seconds) { sleep 0.2 })
      E2E::DeviceAuthorizationBudget.consume
      authorization = client.request_runner_authorization(registration_identifier: "e2e-file-import-#{SecureRandom.hex(4)}",
        runner_display_name: "File import environment")
      E2E::RunnerGrant.visit_connection(actor: @actor, authorization: authorization)
      E2E::RunnerGrant.connect_in_browser(actor: @actor, authorization: authorization)
      credentials = client.await_credentials(authorization)
      assert_nil credentials.access_token
      credentials
    end

    def boot_environment
      credentials = environment_credentials
      @environment = E2E::ExecutorProcess.new(base_url: @base_url, home: @runner_home,
        credential: credentials.executor_access_token, world: @runner_home).start
      @environment.executor_public_id
    end

    def await_log(daemon, pattern, message)
      daemon.await(message) { daemon.log_text.match?(pattern) ? true : nil }
    end

    def await_loop_completion(workspace_public_id, loop_id)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}")
        found = latest["run"]
        return found if found && found["status"] == "completed"
        flunk "the loop never completed; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep LOOP_POLL
      end
    end

    def task_output(workspace_public_id, loop_id, key)
      agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{loop_id}/tasks/#{key}")
        .dig("task", "output").to_s
    end

    def runner_callable(workspace_public_id, run_public_id, runner_id, tool_name)
      definitions = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/runs/#{run_public_id}/tasks/r1")
        .fetch("task").fetch("tool_definitions")
      entry = definitions.find do |tool|
        tool.dig("route", "runner_executor_public_id") == runner_id && tool.dig("route", "tool_name") == tool_name
      end
      refute_nil entry, "the model has no #{tool_name} declaration for Runner #{runner_id}: #{definitions.inspect}"
      entry.fetch("function").fetch("name")
    end

    def summarize(row)
      row.fetch("tasks").map do |task|
        "#{task.fetch("key")}(#{task.fetch("kind")}/#{task.fetch("status")}" \
          "#{task["tool_name"] ? ":#{task["tool_name"]}" : ""})"
      end.join(" ")
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

    def await_workspace_state(state)
      @daemon.await("the daemon never reported workspace #{state}") do
        document = @daemon.status
        workspace = document["workspace"]
        flunk "the daemon reported a workspace error: #{workspace["code"]}" if workspace&.fetch("state") == "error"

        workspace&.fetch("state") == state ? document : nil
      end
    end

    def sign_in_steward
      @actor.visit("/session/new")
      @page.fill_in "Email", with: @steward.email
      @page.fill_in "Password", with: @steward.password
      E2E::SessionSignInBudget.consume
      @page.click_button "Sign in"
      assert @page.has_text?("Overview")
    end

    def warn_log(path, label)
      warn "#{label}:\n#{E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8))}" if path && File.file?(path)
    end
end
