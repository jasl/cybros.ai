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
require "support/secret_hygiene"
require "support/session_sign_in_budget"

# RUNNER MODE, THE SEPARABLE ROLE: one executable, two homes, two modes. An AGENT-mode rho under the
# empty prelude (Ops's verbs, no tool; the echo names declared) registers no runner row and names,
# on `rho run --runner`, a RUNNER-mode rho paired on a second RHO_HOME — `RHO_MODE=runner rho
# server`, the container's shape — whose ceremony is branch B alone (identifier `rho-runner.<id>`,
# the id that home derived at its first boot, beside the agent home's `rho.<id>`; the machine page
# with its scope block), which holds ONE plane and no member standing, adopts no workspace, and
# offers no conversation verb. The call lands on the runner-mode rho's REAL `read`: its own log
# carries the claim, the agent's carries none, and the answer is the file. Two grants; the
# coding-turn version on a real model is `live_rho_runner`.
class RhoRunnerModeTest < Minitest::Test
  EMPTY_PRELUDE = File.expand_path("../support/empty_extensions_prelude.rb", __dir__)
  MODEL = "dev/mock-text".freeze
  # Readiness of a runner-mode rho is its runner address's announcement —
  # never a workspace, which a runner adopts none of.
  ANNOUNCED_RUNNER = /event=executor\.announced tools=\d+ address=runner\b/
  ANNOUNCED_AGENT_NOTHING = /event=executor\.announced tools=0 address=agent\b/
  # A runner-mode home lists no conversation verb: not the core's `run`,
  # not rho-dev's (this product-shaped home names no extension).
  CONVERSATION_VERBS = %w[run do say stop compact watch].freeze
  TROUBLE = /runner_task_failed|runner_submit_refused/

  def setup
    @base_url = E2E.base_url
    @world = E2E::ActorProvisioning.world(@base_url)
    @steward = @world.rho_steward
    @actor = E2E::BrowserActor.new(@base_url)
    @page = @actor.page
    @home = Dir.mktmpdir("rho-agent-mode-e2e")
    @runner_home = Dir.mktmpdir("rho-runner-mode-e2e")
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
        File.expand_path("../artifacts/screenshots/rho_runner_mode-#{Process.pid}.png", __dir__)
      )
    end
  rescue StandardError => error
    warn "Could not capture rho runner-mode E2E capture: #{error.class}: #{error.message}"
  ensure
    stop_quietly("the runner-mode rho") { @runner&.stop }
    stop_quietly("the agent-mode rho") { @daemon&.stop }
    @actor&.close
    [@home, @runner_home].each { |dir| FileUtils.remove_entry(dir) if dir && File.directory?(dir) }
  end

  def test_an_agent_mode_rho_names_a_runner_mode_rho_on_a_second_home
    workspace_public_id = boot_agent_rho
    runner_id = boot_runner_rho

    E2E.enable_dev_lane!
    E2E.hosts.start

    # Same machine, two homes: the marker lives under the AGENT's project
    # and only the runner-mode rho holds a `read` that can answer with it.
    project = File.join(@home, "project")
    FileUtils.mkdir_p(project)
    marker = "read-by-the-runner-mode-rho-#{SecureRandom.hex(4)}"
    note = File.join(project, "note.txt")
    File.write(note, "#{marker}\n")
    loop_id = rho_run("!mock tool_call=read tool_args=#{CGI.escape(JSON.generate({ "path" => note }))} -- say what you read",
      project, runner: runner_id)

    completed = await_loop_completion(workspace_public_id, loop_id)
    tool_task = completed.fetch("tasks").find { |task| task.fetch("kind") == "tool_task" }
    refute_nil tool_task, "the model never called a tool: #{summarize(completed)}"
    assert_equal "read", tool_task.fetch("tool_name")
    assert_equal "completed", tool_task.fetch("status"), tool_task.inspect
    # The runner-mode rho's socket is pong-verified live: `online` (r-modes M4).
    assert_equal({ "role" => "runner", "executor_public_id" => runner_id, "presence" => "online" },
      tool_task.fetch("addressed_to").except("last_seen_at"),
      "the row was addressed to the runner the agent named")

    output = task_output(workspace_public_id, loop_id, tool_task.fetch("key"))
    assert_includes output, marker, "the runner-mode rho's real `read` answered with the file: #{output.inspect}"

    # WHOSE LOG SAYS SO: the second home's carries the claim, the first's
    # none — the agent-mode rho announced nothing and held nothing.
    assert_includes @runner.claimed_keys, tool_task.fetch("key"),
      "the runner-mode rho's own log says it took the row: #{@runner.claims.inspect}"
    assert_equal "runner", @runner.claims.find { |claim| claim["task"] == tool_task.fetch("key") }["address"]
    assert_empty @daemon.claimed_keys, "the agent-mode rho claimed a row it could not serve"
    refute_match TROUBLE, @runner.log_text, "the runner-mode rho met a refusal or a failure"
    refute_match TROUBLE, @daemon.log_text, "the agent-mode rho met a refusal or a failure"
  end

  def test_a_runner_without_a_member_plane_imports_a_file_from_an_earlier_conversation_turn
    workspace_public_id = boot_agent_rho
    runner_id = boot_runner_rho
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
    await_loop_completion(workspace_public_id, opened.fetch("loop").fetch("public_id"))
    conversation_id = opened.fetch("conversation").fetch("public_id")
    turns = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation_id}/turns").fetch("turns")
    upload = turns.fetch(0).fetch("active_variant").fetch("attachments").fetch(0).fetch("public_id")
    # Remove the sender's source so the subsequent read proves transfer from
    # Nexus, even though this harness runs its two homes on one machine.
    File.unlink(source)

    args = CGI.escape(JSON.generate("upload" => "nexus://uploads/#{upload}"))
    admitted = core.say(conversation_id,
      "!mock tool_call=file_import:#{args} reply=imported -- import the earlier file", mode: "queue")
    loop_id = admitted.fetch("loop").fetch("public_id")
    completed = await_loop_completion(workspace_public_id, loop_id)
    imported = completed.fetch("tasks").find { |task| task["tool_name"] == "file_import" }
    refute_nil imported, summarize(completed)
    assert_equal "completed", imported.fetch("status")
    assert_equal runner_id, imported.fetch("addressed_to").fetch("executor_public_id")
    assert_equal "runner", imported.fetch("addressed_to").fetch("role")
    detail = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_id}/tasks/#{imported.fetch("key")}").fetch("task")
    path = detail.fetch("structured_content").fetch("path")
    assert_equal "# Notes\n#{marker}\n", File.binread(path)
    refute_equal source, path
    assert_includes @runner.claimed_keys, imported.fetch("key")
    assert_empty @daemon.claimed_keys
    assert_equal %w[runner_transport], @runner.status.dig("authority", "planes").keys
    refute_match TROUBLE, @runner.log_text
  end

  private

    LOOP_POLL = 1
    AWAIT_SECONDS = 120

    # The AGENT half: the empty prelude under `RHO_MODE=agent` — a full-mode
    # boot refuses to serve nothing — pairs branch A alone (no runner
    # sentence on the page), adopts a workspace, announces `[]` on its one
    # address and registers no runner row.
    def boot_agent_rho
      File.write(File.join(@home, "settings.json"),
        JSON.generate({ "extensions" => [], "extension_paths" => [] }))
      @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home,
        env: { "RUBYOPT" => "-r#{EMPTY_PRELUDE}", "RHO_MODE" => "agent" })
      @daemon.start
      started = @daemon.start_ceremony
      assert_equal "agent", started["branch"], "an agent-mode rho pairs branch A alone: #{started.inspect}"
      E2E::Ceremony.confirm(actor: @actor, started: started, status: -> { @daemon.status })
      adopted = await_workspace_state("adopted")
      await_log(@daemon, ANNOUNCED_AGENT_NOTHING, "the agent address never announced its empty set")
      assert_equal "agent", adopted["mode"]
      assert_nil adopted.dig("identity", "runner_executor_public_id"),
        "an agent-mode rho registers no runner row: #{adopted["identity"].inspect}"
      adopted.dig("workspace", "public_id")
    end

    # The RUNNER half on a second home: `RHO_MODE=runner` with the shipped
    # set, branch B alone under `rho-runner.<this home's id>`, one plane,
    # no workspace, no conversation verb — and its runner address
    # announced before anything could be addressed to it.
    def boot_runner_rho
      # A PRODUCT-SHAPED home: no extension named, so the listing below is
      # the shipped runner's own (a bare home would get rho-dev from the
      # harness, and its verbs with it).
      File.write(File.join(@runner_home, "settings.json"), JSON.generate({ "extensions" => [], "extension_paths" => [] }))
      @runner = E2E::RhoDaemon.new(base_url: @base_url, home: @runner_home, env: { "RHO_MODE" => "runner" })
      @runner.start
      started = @runner.start_ceremony
      assert_equal "runner", started["branch"], "a runner-mode rho pairs branch B alone: #{started.inspect}"
      E2E::Ceremony.confirm(actor: @actor, started: started, status: -> { @runner.status })
      await_log(@runner, ANNOUNCED_RUNNER, "the runner-mode rho never announced its tools")

      document = @runner.status
      runner_id = document.dig("identity", "runner_executor_public_id")
      refute_nil runner_id, "the runner-mode rho's identity is its runner row: #{document.inspect}"
      assert_equal "runner", document["mode"]
      assert_equal %w[runner_transport], document.dig("authority", "planes").keys,
        "a runner-mode rho holds ONE plane and no member standing: #{document["authority"].inspect}"
      assert_equal "live", document.dig("authority", "planes", "runner_transport")
      refute document.key?("workspace"), "a runner adopts no workspace: #{document.inspect}"

      # The verbs a person types against that home: no conversation verb,
      # the footer that says why, and `rho status` naming the mode.
      helped, status = @runner.cli("help")
      assert_predicate status, :success?, helped
      CONVERSATION_VERBS.each do |verb|
        refute_match(/^  rho #{verb}\b/, helped, "a runner-mode home offers no `#{verb}`:\n#{helped}")
      end
      assert_match(/This rho runs in mode runner/, helped, helped)
      assert_match(/\(`run` is not here\)/, helped, helped)
      reported, status = @runner.cli("status")
      assert_predicate status, :success?, reported
      assert_match(/^mode:      runner$/, reported, reported)
      assert_match(/^runner:    #{Regexp.escape(runner_id)} serving \d+ tools/, reported, reported)
      runner_id
    end

    # `rho run` on the agent-mode rho, naming the runner its tools run on:
    # the one conversation verb a product home has, followed to its end.
    def rho_run(prompt, project, runner:)
      output, status = @daemon.cli("run", prompt, "--model", MODEL, "--dir", project, "--runner", runner)
      assert_predicate status, :success?, "rho run failed:\n#{output}"
      loop_id = output[/^loop:\s+(\S+)/, 1]
      refute_nil loop_id, output
      loop_id
    end

    def await_log(daemon, pattern, message)
      daemon.await(message) { daemon.log_text.match?(pattern) ? true : nil }
    end

    def await_loop_completion(workspace_public_id, loop_id)
      latest = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + AWAIT_SECONDS
      loop do
        latest = agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_id}")
        found = latest["agent_loop"]
        return found if found && found["status"] == "completed"
        flunk "the loop never completed; last seen #{latest.inspect}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline

        sleep LOOP_POLL
      end
    end

    def task_output(workspace_public_id, loop_id, key)
      agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/agent_loops/#{loop_id}/tasks/#{key}")
        .dig("task", "output").to_s
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
      assert @page.has_text?("Dashboard")
    end

    def stop_quietly(label)
      yield
    rescue StandardError => error
      warn "Could not stop #{label}: #{error.class}: #{error.message}"
    end

    def warn_log(path, label)
      warn "#{label}:\n#{E2E::SecretHygiene.redact(File.read(path, encoding: Encoding::UTF_8))}" if path && File.file?(path)
    end
end
