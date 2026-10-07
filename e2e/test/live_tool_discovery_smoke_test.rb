require "test_helper"
require "fileutils"
require "securerandom"
require "tempfile"
require "time"
require "support/live_journey"
require "support/evals/sealed_request"
require "support/tool_diagnostic_capture"
require "support/tool_discovery_smoke"

# One read per arm/model, followed by one small coding task per arm on the floor.
# Each cell keeps its first outcome; the report is a smoke trace, not a benchmark.
class LiveToolDiscoverySmokeTest < Minitest::Test
  include E2E::LiveJourney

  Smoke = E2E::ToolDiscoverySmoke

  def setup
    start_live_journey!(Smoke::CODING_MODEL, models: Smoke.models, home_prefix: "rho-tool-discovery-smoke")
    @report_path = File.expand_path("../artifacts/tool-discovery-smoke/#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{Process.pid}.json", __dir__)
    @source_report = ENV["E2E_TOOL_SMOKE_RESUME"].to_s
    previous = @source_report.empty? ? {} : JSON.parse(File.read(@source_report))
    @records = previous.fetch("records", [])
    @read_marker = previous.fetch("read_marker") { "The silver heron waits beside the green lantern. Observation code: #{SecureRandom.hex(6)}." }
    @campaign_cost_stop_usd = [@cost_stop_usd, Smoke::COST_STOP_USD].min
    @project = Dir.mktmpdir("rho-tool-discovery-project")
    write_daemon_home!(settings: E2E::RhoDaemon.dev_settings(plugins: {
      "e2e.tool-catalog-author" => { "enabled" => true,
        "source" => { "kind" => "path", "path" => File.expand_path("../support/tool_catalog_author.rb", __dir__) } },
    }))
  end

  def teardown
    write_report if @records
    finish_live_journey!
    FileUtils.remove_entry(@project) if @project && File.directory?(@project)
  end

  def test_reference_models_read_and_the_floor_repairs_a_small_program
    connect_and_open_lane!
    @daemon.await_announced(address: "runner")
    @runner_id = @daemon.status.dig("identity", "runner_executor_public_id")
    @daemon.control(:get, "/runners")
    @default_profile = @daemon.control(:get, "/e2e/tool-catalog")
    @default_catalog = @daemon.control(:post, "/e2e/tool-assembly", body: {
      "default_runner_executor_public_id" => @runner_id,
    }).fetch("tool_definitions")
    @default_documents = @default_profile.fetch("prompt_documents")

    Smoke.cells.each do |cell|
      next if @records.any? { |record| record["cell"] == cell.id && (record["run_public_id"] || record["skipped_reason"]) }
      break if known_cost + unknown_cost_reserve >= @campaign_cost_stop_usd || unpriced_receipts.any? { |receipt| receipt["status"] != "failed" }

      observe(cell)
    end

    failures = @records.reject { |record| record.dig("result", "task_success") }
    assert_equal Smoke.cells.length, @records.length, "campaign stopped before every cell; see #{@report_path}"
    assert_empty failures, failures.map { |record| "#{record.fetch("cell")}: #{record["error"] || record["status"]}" }.join("\n")
  end

  private

    def observe(cell)
      prepare_project(cell)
      definitions = Smoke.definitions_for(cell.arm, @default_catalog)
      @daemon.control(:post, "/e2e/tool-catalog", body: {
        "tool_definitions" => definitions,
        "kernel_tools" => [], "runner_tool_names" => [],
        "prompt_documents" => Smoke.documents_for(cell.arm, @default_documents),
      })
      @cost_stop_usd = @campaign_cost_stop_usd - known_cost - unknown_cost_reserve
      record = { "cell" => cell.id, "model" => cell.model, "kind" => cell.kind, "arm" => cell.arm,
        "runner_public_id" => @runner_id, "code_mode" => cell.kind == "coding",
        "started_at" => Time.now.utc.iso8601, "result" => { "task_success" => false } }
      @records << record
      write_report
      record["prompt"] = prompt_for(cell)
      document = @daemon.control(:post, "/conversations", body: {
        "model" => cell.model, "working_directory" => @project,
        "code_mode" => cell.kind == "coding",
      })
      record["conversation_public_id"] = document.fetch("conversation").fetch("public_id")
      document = @daemon.control(:post, "/say", body: {
        "public_id" => record.fetch("conversation_public_id"), "workspace_public_id" => workspace_public_id,
        "text" => record.fetch("prompt"), "delivery_mode" => "queue", "model" => cell.model,
        "tool_names" => definitions.map { |entry| entry.fetch("function").fetch("name") },
        "code_mode" => cell.kind == "coding", "wait" => false,
      })
      record["run_public_id"] = accepted_run(document, record.fetch("conversation_public_id"))
      write_report
      await_loop_completion(record.fetch("run_public_id"), deadline: Smoke::TURN_SECONDS)
      capture(record)
      assert_equal "completed", record.fetch("status"), record.fetch("tasks").inspect
      assert_declaration(cell, record)
      cell.kind == "read" ? assert_read(record) : assert_coding(record)
      record.fetch("result")["task_success"] = true
    rescue Minitest::Assertion, E2E::Stopped => error
      record["error"] = "#{error.class}: #{error.message}"
      stop_unfinished(record)
      capture(record) if record["run_public_id"] && !record["requests"]
    rescue StandardError => error
      record["harness_error"] = "#{error.class}: #{error.message}" if record
      stop_unfinished(record) if record
      raise
    ensure
      if record
        record["finished_at"] = Time.now.utc.iso8601
        write_report
        puts "tool discovery smoke: #{record.fetch("cell")} success=#{record.dig("result", "task_success")} " \
          "requests=#{record.dig("counts", "model_requests")} attempts=#{record.dig("counts", "provider_attempts")} " \
          "functions=#{record.dig("counts", "model_function_calls")} total_usd=#{format("%.6f", known_cost)}"
      end
    end

    def prepare_project(cell)
      if cell.kind == "read"
        File.write(File.join(@project, "observation.txt"), "#{@read_marker}\n")
      else
        %w[ranges.py test_ranges.py].each { |name| FileUtils.cp(File.join(Smoke::FIXTURE, name), @project) }
      end
    end

    def prompt_for(cell)
      if cell.kind == "read"
        "Read #{File.join(@project, "observation.txt")} on Runner #{@runner_id} using that Runner's read tool. " \
          "Call read exactly once and return only the file's text. Do not use code, bash, or another filesystem tool. " \
          "Work synchronously in this conversation without delegation."
      else
        "Work synchronously in this conversation without delegation. In #{@project} on Runner #{@runner_id}, " \
          "read ranges.py and test_ranges.py, then fix merge_ranges. Inputs are integer intervals (start, end) " \
          "with start <= end. Merge overlapping and adjacent intervals, ignore zero-length intervals, " \
          "return sorted tuples, and do not modify the input list. Only edit ranges.py. " \
          "Run python3 -B test_ranges.py and report the result."
      end
    end

    def accepted_run(document, conversation)
      return document.dig("run", "public_id") if document.dig("run", "public_id")

      assert_equal true, document["pending"], document.inspect
      input_id = document.fetch("input").fetch("public_id")
      limit = monotonic + 90
      loop do
        turn = turns(conversation).find { |row| row["input_public_id"] == input_id }
        run_id = turn&.dig("active_variant", "run_public_id")
        return run_id if run_id
        flunk "accepted input #{input_id} never started" if monotonic > limit

        sleep 0.5
      end
    end

    def turns(conversation)
      agent_api("/agent_api/v1/workspaces/#{workspace_public_id}/conversations/#{conversation}/turns").fetch("turns")
    end

    def capture(record)
      run_id = record.fetch("run_public_id")
      row = loop_row(run_id)
      record.merge!(row.slice("status", "failure_reason", "created_at", "completed_at", "tasks"))
      record["task_details"] = row.fetch("tasks").map do |task|
        agent_api("#{loop_path(run_id)}/tasks/#{task.fetch("key")}").fetch("task")
      end
      record["sealed_requests"] = row.fetch("tasks").filter_map do |task|
        next unless task["kind"] == "model_task"

        key = task.fetch("key")
        document = agent_api(E2E::Evals::SealedRequest.path(loop_path(run_id), key))
        E2E::Evals::SealedRequest.from_document(document, key)
      end
      record["requests"] = E2E::ToolDiagnosticCapture.requests(E2E.operator.compiled_requests!(run_id))
      record["model_calls"] = Smoke.model_calls(record.fetch("sealed_requests"))
      record["model_call_count_complete"] = row.fetch("status") == "completed"
      record["model_call_history_through_task"] = record.fetch("sealed_requests").last&.fetch("task_key")
      reply = turns(record.fetch("conversation_public_id")).find { |turn| turn.dig("active_variant", "run_public_id") == run_id }
      record["reply"] = reply&.dig("active_variant", "content")
      calls = record.fetch("model_calls")
      runner_tasks = row.fetch("tasks").select { |task| task.dig("target", "executor_public_id") }
      record["counts"] = {
        "model_requests" => record.fetch("requests").length,
        "provider_attempts" => record.fetch("requests").sum { |request| request.fetch("receipts").length },
        "model_function_calls" => calls.length, "model_calls_by_name" => calls.map { |call| call.fetch("name") }.tally,
        "model_calls_by_kind" => calls.map { |call| call_kind(call) }.tally,
        "runner_tasks" => runner_tasks.length, "runner_leaf_tasks" => runner_tasks.count { |task| task["tool_name"] != "code" },
        "runner_tasks_by_name" => runner_tasks.map { |task| task.fetch("tool_name") }.tally,
      }
      write_report
    end

    def call_kind(call)
      name = call.fetch("name")
      entry = @default_catalog.find { |tool| tool.dig("function", "name") == name }
      canonical = entry&.fetch("canonical", nil) || name
      if %w[tool_search nexus.tools.search].include?(canonical)
        "search"
      elsif %w[tool_call nexus.tools.call].include?(canonical)
        "wrapper"
      elsif name == "code" || entry&.dig("route", "tool_name") == "code"
        "code"
      elsif entry&.fetch("route", nil)
        "direct_runner"
      else
        "other"
      end
    end

    def assert_declaration(cell, record)
      names = record.fetch("requests").first.fetch("tools").map { |tool| tool["name"] || tool.dig("function", "name") }
      read = @default_catalog.find { |entry| entry.dig("route", "runner_executor_public_id") == @runner_id && entry.dig("route", "tool_name") == "read" }
      callable = read.fetch("function").fetch("name")
      prompt = JSON.generate(record.fetch("sealed_requests").first.fetch("entries"))
      if cell.arm == "eager_direct"
        assert_includes names, callable
        refute_includes names, "tool_search"
        refute_includes names, "tool_call"
        refute_includes prompt, Smoke::DISCOVERY_PREFIX
      else
        refute_includes names, callable
        assert_includes names, "tool_search"
        assert_includes names, "tool_call"
        assert_includes prompt, Smoke::DISCOVERY_PREFIX
      end
      record["declaration_verified"] = true
    end

    def assert_read(record)
      reads = record.fetch("task_details").select { |task| task["tool_name"] == "read" }
      result = record.fetch("result")
      result["read_count"] = reads.length
      result["reply_exact"] = record["reply"].to_s.strip == @read_marker
      assert_equal 1, reads.length
      assert_equal @runner_id, reads.first.dig("target", "executor_public_id")
      assert_equal @runner_id, reads.first.dig("claimed_by", "executor_public_id")
      assert_equal "completed", reads.first.fetch("status")
      refute_equal true, reads.first.dig("result", "is_error")
      assert_includes reads.first.fetch("output"), @read_marker
      assert result.fetch("reply_exact"), "final answer did not exactly match the file"
    end

    def assert_coding(record)
      source = File.read(File.join(@project, "ranges.py"))
      original = File.read(File.join(Smoke::FIXTURE, "ranges.py"))
      tasks = record.fetch("task_details").select do |task|
        task["status"] == "completed" && task.dig("result", "is_error") != true &&
          task.dig("target", "executor_public_id") == @runner_id &&
          task.dig("claimed_by", "executor_public_id") == @runner_id
      end
      read = tasks.any? { |task| (task["tool_name"] == "read" && File.basename(task.dig("tool_input", "path").to_s) == "ranges.py") || task["output"].to_s.include?(original.strip) }
      edited = source != original && tasks.any? do |task|
        %w[write edit apply_patch bash].include?(task["tool_name"]) && JSON.generate(task["tool_input"]).include?("ranges.py")
      end
      ran_tests = tasks.any? do |task|
        task["tool_name"] == "bash" && task.dig("tool_input", "command").to_s.include?("test_ranges.py") &&
          task["output"].to_s.match?(/^OK\s*$/)
      end
      unchanged_tests = File.binread(File.join(@project, "test_ranges.py")) == File.binread(File.join(Smoke::FIXTURE, "test_ranges.py"))
      verification = independent_verification
      record.fetch("result").merge!("source" => source, "read_source" => read, "modified_source" => edited,
        "model_ran_tests" => ran_tests, "tests_unchanged" => unchanged_tests, "independent_verification" => verification,
        "model_used_code" => record.fetch("model_calls").any? { |call| call_kind(call) == "code" },
        "executed_code" => record.fetch("task_details").any? { |task| task["tool_name"] == "code" && task["status"] == "completed" })
      write_report
      assert read, "no successful Runner read of the source was observed"
      assert edited, "no successful Runner edit and changed source were observed"
      assert ran_tests, "the model did not run the existing tests successfully through the Runner"
      assert unchanged_tests, "the model changed the public tests"
      assert_equal 0, verification.fetch("exit_status"), verification.fetch("output")
    end

    def independent_verification
      Tempfile.create("tool-smoke-verification") do |output|
        status = E2E::ProcessRunner.run("python3", "-B", File.join(Smoke::FIXTURE, "verify_ranges.py"),
          File.join(@project, "ranges.py"), timeout: 10, out: output, err: output)
        output.rewind
        { "exit_status" => status.exitstatus, "output" => output.read }
      end
    end

    def stop_unfinished(record)
      run_id = record["run_public_id"]
      return unless run_id
      return if settled?(loop_row(run_id))

      stop_the_run!(run_id)
      await_loop_completion(run_id, deadline: 30)
    end

    def known_cost
      @records.sum do |record|
        Array(record["requests"]).sum do |request|
          request.fetch("receipts").sum { |receipt| receipt["cost_amount"] ? Float(receipt.fetch("cost_amount")) : 0.0 }
        end
      end
    end

    def unpriced_receipts
      @records.flat_map { |record| Array(record["requests"]).flat_map { |request| request.fetch("receipts") } }
        .select { |receipt| receipt["cost_amount"].nil? }
    end

    # This small diagnostic reserves money for unmetered failed requests;
    # it never changes an unknown receipt into a zero-cost receipt.
    def unknown_cost_reserve = unpriced_receipts.count { |receipt| receipt["status"] == "failed" }.to_f

    def write_report
      FileUtils.mkdir_p(File.dirname(@report_path))
      File.write(@report_path, JSON.pretty_generate(
        "models" => Smoke.models, "read_marker" => @read_marker, "output_token_limit" => Smoke::OUTPUT_TOKENS,
        "reasoning" => "unchanged catalog policy", "turn_deadline_seconds" => Smoke::TURN_SECONDS,
        "soft_total_cost_stop_usd" => @campaign_cost_stop_usd, "known_cost_usd" => known_cost,
        "unpriced_attempts" => unpriced_receipts.length, "unknown_cost_reserve_usd" => unknown_cost_reserve,
        "unknown_cost_policy" => "Reserve USD 1 per failed receipt with unknown amount for budget control only; stop on any other unpriced receipt.",
        "source_report" => (@source_report unless @source_report.empty?),
        "measurement" => "Public sealed requests and task details, plus provider receipts and requests rebuilt from accepted invocations; not a wire capture.",
        "model_call_count" => "Calls in the last sealed request minus the first request's inherited history, by occurrence rather than call_id. These fresh short conversations do not compact. Incomplete after an interrupted or failed turn without a subsequent request.",
        "cost_source" => "Nexus settlement receipts: provider-reported amounts where supported, otherwise configured catalog estimates; unknown amounts remain null in receipts.",
        "scope" => "One paired Runner on one machine; one attempt per cell, no repeated benchmark samples or cache claims.",
        "records" => @records
      ))
    end
end
