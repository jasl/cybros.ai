require "test_helper"
require "support/live_journey"
require "support/result_dag"
require "support/secret_hygiene"
require "support/evals/world_log"

class LiveResultDagTest < Minitest::Test
  MODEL = ENV.fetch("E2E_LIVE_MODEL") { E2E::LiveJourney.default_model }.freeze
  ARTIFACTS = File.expand_path("../artifacts/result-dag", __dir__)
  TERMINAL_TASKS = %w[completed failed timed_out canceled skipped].freeze

  include E2E::LiveJourney

  def setup
    skip "live result DAG diagnostic is opt-in (E2E_LIVE=1)" unless ENV["E2E_LIVE"] == "1"
    E2E::ResultDag.validate!
    E2E::SecretHygiene.register(ENV.fetch(E2E::ProviderLanes.key_name_for(MODEL)))
    start_live_journey!(MODEL, home_prefix: "rho-live-result-dag-", daemon_env: { "RHO_COMPOSE" => "on" })
    @capture_dir = File.join(ARTIFACTS, "#{Time.now.utc.strftime("%Y%m%dT%H%M%S")}-#{SecureRandom.hex(3)}-#{MODEL.tr("/", "_")}")
    FileUtils.mkdir_p(@capture_dir)
    overlay = File.join(E2E.handle.fetch("env").fetch("MODEL_CATALOG_OVERRIDE_DIR"), E2E::CatalogOverlay::FILENAME)
    capture("configuration", "model" => MODEL,
      "model_override" => YAML.safe_load_file(overlay).fetch("models")[MODEL], "case_deadline_seconds" => 420,
      "pipeline_feedback" => (E2E::ResultDag::PIPELINE_FEEDBACK if ENV["E2E_RESULT_DAG_PIPELINE_CORRECTION"] == "1"))
  end

  def teardown
    if @capture_dir && @daemon
      E2E::Evals::WorldLog.copy(into: File.join(@capture_dir, "logs"),
        sources: E2E::Evals::WorldLog.sources(handle: E2E.handle, daemon: @daemon),
        windows: E2E::Evals::WorldLog.rails_windows(handle: E2E.handle).map { |window| window.with(from: 0) })
    end
  ensure
    finish_live_journey!
  end

  def test_the_model_authors_and_executes_result_driven_workflows
    connect_and_open_lane!
    verdicts = E2E::ResultDag.selected.map { |name| run_case(name) }
    capture("summary", "model" => MODEL, "cases" => verdicts)
    failures = verdicts.reject { |row| row.fetch("passed") }
    assert_empty failures, JSON.pretty_generate(failures)
  end

  private

    def run_case(name)
      project = File.join(@home, "cases", name)
      data = E2E::ResultDag.prepare(project, name)
      @daemon.control(:post, "/environment", body: { root: project })
      started = @daemon.control(:post, "/loops", body: {
        prompt: E2E::ResultDag.prompt(name), model: MODEL, working_directory: project,
      })
      opened = started.fetch("loop") { raise "loop creation refused: #{JSON.generate(started)}" }
      loop_id = opened.fetch("public_id")
      done = await_loop_completion(loop_id, deadline: 420)
      evidence = evidence_for(loop_id, project)
      assessment = assess_case(name, data, evidence)
      capture(name, evidence.merge("assessment" => assessment))
      verify_case(name, data, done, evidence)
      { "case" => name, "passed" => true, "loop" => loop_id }.merge(assessment)
    rescue StandardError, Minitest::Assertion => error
      reason = E2E::SecretHygiene.redact("#{error.class}: #{error.message}")
      if loop_id
        stop_the_run!(loop_id) unless done && settled?(done)
        evidence ||= salvage(loop_id, project)
      else
        evidence = { "model" => MODEL, "start_response" => started }
      end
      assessment ||= assess_case(name, data, evidence) if evidence["loop"]
      capture(name, evidence.merge("failure" => reason, "assessment" => assessment))
      { "case" => name, "passed" => false, "loop" => loop_id, "reason" => reason }.merge(assessment || {})
    ensure
      puts "result-dag #{name} #{MODEL}: #{reason ? "FAIL" : "pass"}"
    end

    def evidence_for(loop_id, project)
      row = loop_row(loop_id)
      graph = agent_api("#{loop_path(loop_id)}/graph")
      tasks = row.fetch("tasks").map do |task|
        agent_api("#{loop_path(loop_id)}/tasks/#{task.fetch("key")}").fetch("task")
      end
      requests = tasks.select { |task| task.fetch("kind") == "model_task" && task["request_bytes"] }.map do |task|
        key = task.fetch("key")
        { "task_key" => key, "request" => agent_api("#{loop_path(loop_id)}/tasks/#{key}/request").fetch("request") }
      end
      events_path = File.join(project, "events.jsonl")
      events = File.exist?(events_path) ? File.readlines(events_path).map { |line| JSON.parse(line) } : []
      fixture = JSON.parse(File.read(File.join(project, "data.json"))).slice("case", "records", "noise")
      { "model" => MODEL, "loop" => row, "graph" => graph, "tasks" => tasks,
        "requests" => requests, "fixture_events" => events, "fixture" => fixture,
        "transcript" => agent_api("#{loop_path(loop_id)}/transcript?limit=100"), "spend" => loop_spend(loop_id) }
    end

    def salvage(loop_id, project)
      evidence_for(loop_id, project)
    rescue StandardError => error
      { "loop_id" => loop_id, "capture_error" => E2E::SecretHygiene.redact("#{error.class}: #{error.message}") }
    end

    # Preserve the strict run verdict, while checking a correction against every
    # original behavior assertion. Previous attempts remain in the full capture;
    # their fixture effects still count, so a correction cannot hide repeated work.
    def assess_case(name, data, evidence)
      calls = evidence.fetch("tasks").select { |task| task["tool_name"] == "compose" }
      assessment = { "attempt_count" => calls.length, "final_behavior_passed" => false,
                     "first_generation_passed" => false, "self_correction_passed" => false }
      assert evidence.fetch("tasks").all? { |task| TERMINAL_TASKS.include?(task.fetch("status")) },
        "unfinished work from an earlier attempt"
      assert_fixture_commands_in_workflow(evidence.fetch("tasks"), evidence.fetch("graph"))
      if calls.any?
        spine = E2E::Evals::Trace.spine_keys(evidence.fetch("graph"))
        graph = evidence.fetch("graph").merge("edges" => evidence.fetch("graph").fetch("edges").reject do |edge|
          spine.include?(edge.fetch("to"))
        end)
        root = calls.last.fetch("key")
        tasks = evidence.fetch("tasks").select do |task|
          key = task.fetch("key")
          spine.include?(key) || key == root || E2E::Gallery.reachable?(graph, root, key)
        end
        verify_case(name, data, evidence.fetch("loop"), evidence.merge("tasks" => tasks))
        assessment.merge("final_behavior_passed" => true, "first_generation_passed" => calls.one?,
          "self_correction_passed" => calls.length > 1)
      else
        assessment.merge("final_behavior_failure" => "the model never authored compose")
      end
    rescue Minitest::Assertion => error
      assessment.merge("final_behavior_failure" => error.message)
    end

    def verify_case(name, data, done, evidence)
      assert_equal "completed", done.fetch("status"), summarize(done)
      tasks = evidence.fetch("tasks")
      assert tasks.all? { |task| TERMINAL_TASKS.include?(task.fetch("status")) }, "unfinished generated work"
      composed = tasks.select { |task| task["tool_name"] == "compose" }
      refute_empty composed, "the model never authored compose"
      assert composed.any? { |task| task["status"] == "completed" }, "no authored compose was accepted"
      scripts = tasks.select { |task| task["kind"] == "script_task" }
      refute_empty scripts, "the workflow never executed a result-driven script"
      events = evidence.fetch("fixture_events")
      assert_command_graph(tasks, evidence.fetch("graph"), name)

      if name == "failure"
        assert scripts.any? { |task| task["status"] == "failed" }, "failed listing did not fail a script"
        refute events.any? { |event| event["operation"] == "inspect" }, "inspection ran after a failed listing"
        assert_equal 1, events.count { |event| event["operation"] == "list" && event["state"] == "started" },
          "the model retried the failed data source"
      else
        refute scripts.any? { |task| task["status"] != "completed" }, "script execution failed"
        expected = E2E::ResultDag.expected(name, data)
        outputs = scripts.filter_map { |task| parse_output(task["output"]) }
        assert_includes outputs, expected, "no script returned the required reduction"
        verify_fixture_work(name, data, events)
      end

      spine = evidence.fetch("graph").fetch("nodes").select { |node| node["spine"] }.map { |node| node.fetch("key") }
      completed_models = tasks.select { |task| task["kind"] == "model_task" && task["status"] == "completed" }.map { |task| task.fetch("key") }
      last_request = evidence.fetch("requests").reverse.find do |entry|
        spine.include?(entry.fetch("task_key")) && completed_models.include?(entry.fetch("task_key"))
      end
      refute_nil last_request, "no completed mainline model request was captured"
      refute JSON.generate(last_request.fetch("request").fetch("entries")).include?(data.fetch("noise")),
        "the outer reporter re-imported internal script material"
    end

    def assert_command_graph(tasks, graph, name)
      commands = tasks.select { |task| task["tool_name"] == "bash" }
      refute_empty commands, "the graph never ran the data service"
      assert_fixture_commands_in_workflow(tasks, graph)
      if name == "dynamic"
        inspections = commands.select { |task| task.dig("tool_input", "command").to_s.match?(/\binspect\s/) }
        inspections.combination(2) do |a, b|
          refute E2E::Gallery.reachable?(graph, a.fetch("key"), b.fetch("key")), "inspections were serialized"
          refute E2E::Gallery.reachable?(graph, b.fetch("key"), a.fetch("key")), "inspections were serialized"
        end
      end
      operation = name == "dependencies" ? "source" : "discover"
      return unless %w[dependencies pipeline].include?(name)

      a, b = %w[a b].map do |group|
        commands.find { |task| task.dig("tool_input", "command").to_s.match?(/\b#{operation}\s+#{group}\b/) }
      end
      refute_nil a, "missing #{operation} a"
      refute_nil b, "missing #{operation} b"
      refute E2E::Gallery.reachable?(graph, a.fetch("key"), b.fetch("key")), "the data sources were serialized"
      refute E2E::Gallery.reachable?(graph, b.fetch("key"), a.fetch("key")), "the data sources were serialized"
    end

    def assert_fixture_commands_in_workflow(tasks, graph)
      spine = E2E::Evals::Trace.spine_keys(graph)
      tasks.each do |task|
        next unless task["tool_name"] == "bash" && task.dig("tool_input", "command").to_s.match?(/\bwork\.rb\b/)

        assert_empty Array(task["after"]) & spine, "a mainline model ran a fixture command outside the authored workflow"
      end
    end

    def verify_fixture_work(name, data, events)
      completed = events.select { |event| event.fetch("state") == "completed" }
      if name == "dependencies"
        assert_equal %w[c d], completed.select { |event| event["operation"] == "consume" }.map { |event| event.fetch("arguments").first }.sort
        c = events.index { |event| event["operation"] == "consume" && event["arguments"].first == "c" && event["state"] == "started" }
        b = events.index { |event| event["operation"] == "source" && event["arguments"] == ["b"] && event["state"] == "completed" }
        assert_operator c, :<, b, "C was blocked on B"
      else
        actual = completed.select { |event| event["operation"] == "inspect" }.map { |event| event.fetch("arguments").first }.sort
        expected = E2E::ResultDag.expected(name, data).fetch("items").map { |item| item.fetch("path") }
        assert_equal expected, actual, "the runtime fan inspected the wrong files or repeated work"
        if name == "pipeline"
          a = events.index { |event| event["operation"] == "inspect" && event["arguments"].first.start_with?("a-") && event["state"] == "started" }
          b = events.index { |event| event["operation"] == "discover" && event["arguments"] == ["b"] && event["state"] == "completed" }
          assert_operator a, :<, b, "the pipeline added a global discovery barrier"
        end
      end
    end

    def parse_output(text)
      JSON.parse(text.to_s)
    rescue JSON::ParserError
      nil
    end

    def capture(name, value)
      File.write(File.join(@capture_dir, "#{name}.json"), E2E::SecretHygiene.redact(JSON.pretty_generate(value)) + "\n")
    end
end
