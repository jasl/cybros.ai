require "test_helper"
require "fileutils"
require "json"
require "net/http"
require "securerandom"
require "time"
require "support/deferred_tools_diagnostic"
require "support/live_journey"
require "support/tool_diagnostic_capture"

# Six ordinary rho turns: eager/deferred cold, warm, then an explicitly added Runner surface.
# Every provider attempt remains in the local report, including first cache misses.
class LiveDeferredToolsTest < Minitest::Test
  include E2E::LiveJourney

  MODEL = E2E::DeferredToolsDiagnostic::MODEL
  REPORT_PATH = File.expand_path("../artifacts/deferred-tools/#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}.json", __dir__)

  def setup
    start_live_journey!(MODEL, home_prefix: "rho-live-deferred-tools-e2e")
    @campaign_cost_stop_usd = [@cost_stop_usd, E2E::DeferredToolsDiagnostic::COST_STOP_USD].min
    @cost_stop_usd = @campaign_cost_stop_usd
    @records = []
    @conversations = {}
    write_daemon_home!(settings: E2E::RhoDaemon.dev_settings(plugins: {
      "e2e.tool-catalog-author" => { "enabled" => true,
        "source" => { "kind" => "path", "path" => File.expand_path("../support/tool_catalog_author.rb", __dir__) } },
    }))
  end

  def teardown
    write_report if @records
    finish_live_journey!
  end

  def test_deferred_schema_cost_and_cache_across_runner_growth
    connect_and_open_lane!
    @daemon.await_announced(address: "runner")
    @local_runner = @daemon.status.dig("identity", "runner_executor_public_id")
    @project = File.join(@home, "project")
    FileUtils.mkdir_p(@project)
    @path = File.join(@project, "observation.txt")
    @source_configuration = @daemon.control(:get, "/e2e/tool-catalog").fetch("configuration")
    @default_catalog = catalog(@local_runner, configuration: @source_configuration)
    @initial_catalog_size = @default_catalog.length

    %w[eager deferred].each do |arm|
      select_arm(arm)
      observe(arm, "cold", @local_runner)
      observe(arm, "warm", @local_runner)
    end

    remote = start_runner_rho!(home_prefix: "rho-live-deferred-second-runner")
    @daemon.control(:get, "/runners")
    @source_configuration = @source_configuration.merge("runner_executor_public_ids" => [@local_runner, remote])
    assert_equal @initial_catalog_size, catalog(@local_runner, configuration: @source_configuration).length,
      "adding a candidate alone does not import its tools"
    remote_tools = catalog(remote, configuration: @source_configuration).select do |entry|
      entry.dig("route", "runner_executor_public_id") == remote
    end.map do |entry|
      entry.merge("function" => entry.fetch("function").merge("name" => "remote_#{entry.dig("route", "tool_name")}"))
    end
    configuration = @source_configuration.merge("kernel_tools" => [], "runner_tool_names" => [],
      "tool_definitions" => @default_catalog + remote_tools)
    @default_catalog = catalog(@local_runner, configuration: configuration)
    assert_operator @default_catalog.length, :>, @initial_catalog_size
    %w[eager deferred].each do |arm|
      select_arm(arm)
      observe(arm, "runner_added", remote)
    end

    deferred = @records.select { |record| record.fetch("arm") == "deferred" }
    assert_equal 1, deferred.flat_map { |record| record.fetch("requests").map { |request| request.fetch("tools") } }.uniq.length,
      "the provider tool list stays identical across discovery rounds and explicit Runner imports"
    eager = @records.select { |record| record.fetch("arm") == "eager" }
    assert_operator eager.last.fetch("requests").first.fetch("tools").length, :>,
      eager.first.fetch("requests").first.fetch("tools").length
  end

  private

    def catalog(runner, configuration:)
      @daemon.control(:post, "/e2e/tool-assembly", body: {
        "default_runner_executor_public_id" => runner, "configuration" => configuration,
      }).fetch("tool_definitions")
    end

    def select_arm(arm)
      definitions = arm == "eager" ? @default_catalog.map { |entry| entry.except("defer_loading") } : @default_catalog
      @daemon.control(:post, "/e2e/tool-catalog", body: {
        "tool_definitions" => definitions, "kernel_tools" => [], "runner_tool_names" => [],
        "runner_executor_public_ids" => @source_configuration.fetch("runner_executor_public_ids"),
      })
    end

    def observe(arm, stage, runner)
      enforce_total_cost!
      marker = "The silver heron waits beside the green lantern. Observation code: #{SecureRandom.hex(6)}."
      File.write(@path, "#{marker}\n")
      prompt = "Read #{@path} on Runner #{runner} using that Runner's read tool. " \
        "Discover the matching tool if needed. Call it exactly once and return only the file's text. " \
        "Do not use code, bash, or any other filesystem tool."
      document = submit(arm, prompt)
      run_id = accepted_run(document, @conversations.fetch(arm))
      row = await_loop_completion(run_id, deadline: 300)
      record = capture(arm, stage, run_id, row, runner)
      @records << record
      write_report
      assert_arm_declarations(arm, record, runner)
      assert_equal "completed", row.fetch("status"), summarize(row)
      calls = row.fetch("tasks").select { |task| task["tool_name"] == "read" }
      assert_equal 1, calls.length, summarize(row)
      assert_equal runner, calls.first.dig("target", "executor_public_id")
      assert_equal runner, calls.first.dig("claimed_by", "executor_public_id")
      output = agent_api("#{loop_path(run_id)}/tasks/#{calls.first.fetch("key")}").dig("task", "output").to_s
      assert_includes output, marker
      reply = turns(@conversations.fetch(arm)).find { |turn| turn.dig("active_variant", "run_public_id") == run_id }
      record["result"] = { "read_count" => calls.length, "target_correct" => true, "read_marker_found" => true,
        "task_success" => false,
        "reply_exact" => reply.dig("active_variant", "content").to_s.strip == marker,
        "reply" => reply.dig("active_variant", "content") }
      write_report
      assert_equal marker, reply.dig("active_variant", "content").to_s.strip
      if arm == "deferred"
        assert row.fetch("tasks").any? { |task| task["tool_name"] == "tool_call" }, summarize(row)
        if stage != "warm"
          assert row.fetch("tasks").any? { |task| task["tool_name"] == "tool_search" }, summarize(row)
        end
      end
      record.fetch("result")["task_success"] = true
      write_report
      enforce_total_cost!
    ensure
      if run_id && !@records.any? { |record| record["run_public_id"] == run_id }
        @records << capture(arm, stage, run_id, loop_row(run_id), runner)
        write_report
      end
    end

    def assert_arm_declarations(arm, record, runner)
      callable = @default_catalog.find { |entry| entry.dig("route", "runner_executor_public_id") == runner &&
        entry.dig("route", "tool_name") == "read" }.dig("function", "name")
      names = record.fetch("requests").first.fetch("tools").map { |entry| entry["name"] || entry.dig("function", "name") }
      if arm == "eager"
        assert_includes names, callable, "the eager control must really send the read schema"
      else
        refute_includes names, callable, "the deferred arm must omit the read schema"
        assert_includes names, "tool_search"
        assert_includes names, "tool_call"
      end
    end

    def submit(arm, prompt)
      conversation = @conversations[arm]
      if conversation
        @daemon.control(:post, "/say", body: {
          "public_id" => conversation, "workspace_public_id" => workspace_public_id,
          "text" => prompt, "delivery_mode" => "queue", "model" => MODEL, "code_mode" => false, "wait" => false,
        })
      else
        document = @daemon.control(:post, "/conversations", body: {
          "prompt" => prompt, "model" => MODEL, "working_directory" => @project, "code_mode" => false,
        })
        @conversations[arm] = document.fetch("conversation").fetch("public_id")
        document
      end
    end

    def accepted_run(document, conversation)
      return document.dig("run", "public_id") if document.dig("run", "public_id")

      assert_equal true, document["pending"], document.inspect
      input_id = document.fetch("input").fetch("public_id")
      deadline = monotonic + 90
      loop do
        turn = turns(conversation).find { |row| row["input_public_id"] == input_id }
        run_id = turn&.dig("active_variant", "run_public_id")
        return run_id if run_id
        flunk "accepted input #{input_id} never started" if monotonic > deadline

        sleep 0.5
      end
    end

    def turns(conversation)
      agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation}/turns").fetch("turns")
    end

    def capture(arm, stage, run_id, row, runner)
      requests = E2E::ToolDiagnosticCapture.requests(E2E.operator.compiled_requests!(run_id))
      timing = row.slice("created_at", "started_at", "completed_at")
      if timing["started_at"] && timing["completed_at"]
        timing["duration_ms"] = ((Time.iso8601(timing.fetch("completed_at")) - Time.iso8601(timing.fetch("started_at"))) * 1000).round
      end
      { "arm" => arm, "stage" => stage, "run_public_id" => run_id, "runner_public_id" => runner, "timing" => timing,
        "status" => row.fetch("status"), "tasks" => row.fetch("tasks"), "requests" => requests }
    end

    # Each stage starts only below the whole-campaign bound. While a stage runs,
    # LiveJourney polls the remaining budget; the provider may settle beyond it.
    def enforce_total_cost!
      spent = @records.sum do |record|
        record.fetch("requests").sum { |request| request.fetch("receipts").sum { |receipt| Float(receipt.fetch("cost_amount")) } }
      end
      remaining = @campaign_cost_stop_usd - spent
      raise E2E::Stopped.new("cost_stop", "diagnostic reached its total USD budget") unless remaining.positive?

      @cost_stop_usd = remaining
    end

    def write_report
      FileUtils.mkdir_p(File.dirname(REPORT_PATH))
      File.write(REPORT_PATH, JSON.pretty_generate(
        "model" => MODEL, "output_token_limit" => E2E::DeferredToolsDiagnostic::OUTPUT_TOKENS,
        "reasoning" => false, "soft_total_cost_stop_usd" => @campaign_cost_stop_usd,
        "measurement" => "Provider receipts plus requests rebuilt from accepted invocations and the unchanged local catalog; not a wire capture.",
        "cost_source" => "DeepSeek token and cache counts are provider-reported; cost_amount uses the configured catalog rates, not a provider bill.",
        "runner_scope" => "Two independent paired Runner processes on one machine, sharing the test file path. The second Runner's exact assembled tools are explicitly imported under remote aliases; candidates alone do not widen the surface.",
        "records" => @records
      ))
      puts "deferred tool diagnostic: #{REPORT_PATH} (#{@records.length} recorded turns)"
    end
end
