require "test_helper"
require "cgi/escape"
require "fileutils"
require "rho"
require "tmpdir"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/secret_hygiene"
require "support/steward_session"

class RhoHouseholdTest < Minitest::Test
  MODEL = "dev/mock-text".freeze

  def setup
    @base_url = E2E.base_url
    @steward = E2E::ActorProvisioning.world(@base_url).rho_steward
    @actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
    @root = Dir.mktmpdir("rho-household-e2e")
    @home, @project = File.join(@root, "home"), File.join(@root, "work")
    FileUtils.mkdir_p([@home, @project])
    File.write(File.join(@home, "settings.json"), JSON.generate({ "settings_version" => 1, "plugins" => {}, "api_only" => true }), perm: 0o600)
    @daemon = E2E::RhoDaemon.new(base_url: @base_url, home: @home, tools_root: @project)
    @daemon.start
    E2E::Ceremony.confirm(actor: @actor, started: @daemon.start_ceremony, status: -> { @daemon.status })
    @daemon.await("rho never adopted its workspace") { @daemon.status.dig("workspace", "state") == "adopted" }
    @daemon.await_announced(address: "agent")
    @member = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    @workspace = @member.workspace(@daemon.status.dig("workspace", "public_id"))
    @core = Rho::Core.new(home: Rho::Home.resolve(base_url: @base_url, root: @home))
    E2E.enable_dev_lane!
    E2E.hosts.start
  end

  def teardown
    unless passed?
      [@daemon&.log_path, @daemon&.rho_log_path].compact.each do |path|
        warn E2E::SecretHygiene.redact(File.read(path)) if File.file?(path)
      end
    end
    @daemon&.dispose_connection
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_personal_household_work_persists_reminds_from_its_scheduled_child_and_returns_completion_evidence
    install_example
    opened = @core.open_conversation(model: MODEL, directory: @project)
    @conversation = opened.fetch("conversation").fetch("public_id")
    @chat = @workspace.conversation(@conversation)
    @calls = 0

    observation = { "event_id" => "fixture-spill", "source" => "fixture-observer", "observed_at" => Time.now.iso8601, "finding" => "untidy" }
    observed = tool("observe", **observation)
    assert_nil observed.fetch("cleaning")
    assigned = tool("triage", "reason" => "The reported spill needs cleaning").fetch("cleaning")
    id, schedule_id = assigned.values_at("id", "schedule_id")
    assert_equal "assigned", assigned.fetch("status")
    assert assigned.fetch("last_notice").fetch("simulated")
    assert_equal "fixture-worker", assigned.fetch("last_notice").fetch("recipient")
    assert_equal id, tool("observe", **observation).fetch("cleaning").fetch("id")
    assert_equal 1, tool("triage", "reason" => "Repeated observation").fetch("cleaning").fetch("notice_count")
    assert_equal 1, @chat.schedules.list.items.length

    location = tool("check_in", "event_id" => "fixture-check-in", "source" => "fixture-check-in",
      "observed_at" => (Time.now - 3600).iso8601, "worker" => "fixture-worker", "reported_room" => "entry").fetch("worker_location")
    assert_equal "stale_report", location.fetch("freshness")
    assert_equal "fixture-check-in", location.fetch("source")
    refute location.key?("current_room")

    # The fixture provider reads authored directives, so configure the saved
    # schedule through its public edit surface to call the same domain action.
    # Timing, child creation, authority and tool execution stay product-owned.
    reminder = { "action" => "remind", "room" => "hall", "work_id" => id, "source_conversation" => @conversation }
    schedule = @chat.schedules.fetch(schedule_id)
    @chat.schedules.update(schedule_id, expected_lock_version: schedule.lock_version,
      prompt: directive(reminder), rule: { "kind" => "interval", "every_seconds" => 60, "starts_at" => (Time.now + 60).iso8601 })
    @daemon.stop
    @daemon.start
    @daemon.await_announced(address: "agent")
    @core = Rho::Core.new(home: @core.home)
    selected = cli_json("extensions", "packages").fetch("packages").find { |row| row.fetch("active") }
    assert_equal @version, selected.fetch("version")
    assert_equal schedule_id, tool("status").fetch("cleaning").fetch("schedule_id")
    execution = await_reminder(schedule_id)
    reminded = result_of(execution.run_public_id)
    assert_equal id, reminded.fetch("cleaning").fetch("id")
    assert_equal 2, reminded.fetch("cleaning").fetch("notice_count")
    refute_equal @conversation, execution.child_conversation_public_id
    assert_equal 2, tool("status").fetch("cleaning").fetch("notice_count")

    @configuration["enabled"] = false
    activate_configuration
    assert tool("triage", "reason" => "Disabled rule").fetch("actions_suppressed")
    assert tool("remind", "work_id" => id).fetch("actions_suppressed")
    assert_equal 2, tool("status").fetch("cleaning").fetch("notice_count")
    acknowledged = tool("acknowledge", "work_id" => id, "worker" => "fixture-worker", "source" => "fixture-worker-report", "note" => "Accepted the assignment").fetch("cleaning")
    assert_equal "acknowledged", acknowledged.fetch("status")
    assert_nil acknowledged["completion"]
    completed = tool("complete", "work_id" => id, "worker" => "fixture-worker", "source" => "fixture-worker-report", "note" => "Spill removed and floor inspected").fetch("cleaning")
    assert_equal "completed", completed.fetch("status")
    assert_equal "Accepted the assignment", completed.fetch("acknowledgement").fetch("note")
    assert_equal "Spill removed and floor inspected", completed.fetch("completion").fetch("note")
    assert_equal "canceled", @chat.schedules.fetch(schedule_id).status
    link = @last_detail.content.find { |block| block.fetch("type") == "resource_link" }
    refute_nil link, "completion evidence must be attached to the committed task result"
    assert_match(/cleaning-.*\.json/, link.fetch("name"))
    metadata = @chat.store_entries.list.items.find { |row| row.namespace == "household.cleaning" }
    stored = @chat.store_entries.fetch(metadata.public_id).value
    assert_equal "completed", stored.fetch("work").fetch("status")
    refute_includes JSON.generate(stored), "upload:"
  end

  private

    def install_example
      candidate = File.join(@project, "household-ledger")
      FileUtils.cp_r(File.expand_path("../../agents/rho/rho/examples/household-ledger", __dir__), candidate)
      @configuration_path = File.join(@project, "household.json")
      @configuration = JSON.parse(File.read(File.join(candidate, "configuration.json"))).merge(
        "enabled" => true, "working_days" => (0..6).to_a, "starts_at" => "00:00", "ends_at" => "23:59", "utc_offset" => "+00:00", "remind_every_seconds" => 60)
      @version = cli_json("extensions", "install", candidate).fetch("version")
      assert cli_json("extensions", "check", "household-ledger", @version).fetch("passed")
      @tool = "household_cleaning_#{@version[0, 12]}"
      activate_configuration
    end

    def activate_configuration
      File.write(@configuration_path, JSON.generate(@configuration))
      cli_json("extensions", "activate", "household-ledger", @version, "--configuration", @configuration_path)
    end

    def cli_json(*arguments)
      output, status = @daemon.cli(*arguments)
      assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
      JSON.parse(output)
    end

    def directive(args, skip: 0)
      script = (["unused"] * skip + ["#{@tool}:#{CGI.escape(JSON.generate(args))}"]).join(",")
      "!mock tool_call=#{script} reply=Done -- Coordinate the fixture household work."
    end

    def await_reminder(schedule_id)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 150
      loop do
        row = @chat.schedules.fetch(schedule_id).last_execution
        return row if row&.run_public_id
        flunk "the saved reminder did not run after restart" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.25
      end
    end

    def tool(action, **fields)
      args = { "action" => action, "room" => "hall" }.merge(fields)
      reply = @core.say(@conversation, directive(args, skip: @calls), model: MODEL, mode: "queue")
      run_id = reply.dig("run", "public_id") || @daemon.await("the household input did not materialize") do
        event = @chat.events(limit: 200).find do |item|
          item.type == "input_materialized" && item.payload.fetch("input_public_id") == reply.fetch("input").fetch("public_id")
        end
        event&.payload&.fetch("run_public_id")
      end
      result = result_of(run_id)
      @calls += 1
      result
    end

    def result_of(id)
      run = @daemon.await("household run #{id} did not settle") do
        row = @workspace.runs.run(id).fetch
        row if %w[completed failed canceled timed_out].include?(row.status)
      end
      assert_equal "completed", run.status, run.to_h.inspect
      task = run.tasks.find { |row| row.kind == "tool_task" && row.tool_name == @tool }
      refute_nil task, run.to_h.inspect
      assert_equal "completed", task.status, task.to_h.inspect
      @last_detail = @workspace.runs.run(id).task(task.key)
      block = @last_detail.content.find { |part| part.fetch("type") == "text" }
      JSON.parse(block.fetch("text"))
    end
end
