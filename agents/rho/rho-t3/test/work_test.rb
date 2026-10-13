require_relative "test_helper"

class WorkTest < Minitest::Test
  include T3Test

  def test_agent_discovery_does_not_start_work_or_expose_native_connection_coordinates
    with_work(config: settings(default_agent: nil)) do |work, native, store|
      report = JSON.parse(work.control("action" => "agents").content)
      assert_equal ["Codex", "Claude Code"], report.fetch("agents").map { |agent| agent.fetch("agent") }
      assert_nil report.fetch("default_agent")
      assert_equal ["server.getConfig"], native.calls.map(&:first)
      assert_empty store.rows
      refute_includes JSON.generate(report), "native-codex"
    end
  end

  def test_explicit_agent_and_model_override_only_this_new_assignment
    config = settings
    with_work(config: config) do |work, native, store|
      result = work.delegate("prompt" => "Review the parser", "agent" => "Claude Code", "model" => "Review")
      selection = native.calls.find { |method, _| method == "orchestration.launchThread" }.last.fetch("modelSelection")
      assert_equal({ "instanceId" => "native-claude", "model" => "fixture-review" }, selection)
      report = JSON.parse(result.content)
      assert_equal "Claude Code", report.fetch("agent")
      assert_equal "fixture-review", report.fetch("model")
      assert_equal store.rows.keys.first, report.fetch("work_id")
      %w[thread run project permission_mode responseCapability instanceId].each { |key| refute report.key?(key) }
      refute_includes JSON.generate(report), "native-claude"
      refute_includes File.basename(result.files.first), native.document.fetch("thread").fetch("id")
    end
    with_work(config: config) do |work, native|
      work.delegate("prompt" => "Next assignment")
      assert_equal "native-codex", native.calls.find { |method, _| method == "orchestration.launchThread" }.last.dig("modelSelection", "instanceId")
    end
    assert_equal "Codex", config.default_agent
  end

  def test_unsupported_explicit_selections_do_not_fall_back_to_the_configured_preference
    [{ "agent" => "Missing Agent" }, { "agent" => "Codex", "model" => "fixture-review" }].each do |selection|
      with_work do |work, native, store|
        assert_raises(Rho::T3::Error) { work.delegate({ "prompt" => "Fix it" }.merge(selection)) }
        assert_empty store.rows
        refute native.calls.any? { |method, _| method == "orchestration.launchThread" }
      end
    end
  end

  def test_existing_work_retains_its_choice_after_default_changes_and_refuses_task_overrides
    store, native = T3Test::Store.new, T3Test::Native.new
    with_work(store: store, native: native) { |work| work.delegate("prompt" => "First", "model" => "fixture-fast") }
    id = store.rows.keys.first
    with_work(store: store, native: native, task: "followup", config: settings(default_agent: "Claude Code")) do |work|
      report = JSON.parse(work.delegate("prompt" => "Second", "work_id" => id).content)
      assert_equal "Codex", report.fetch("agent")
      assert_equal "fixture-fast", report.fetch("model")
    end
    [{ "agent" => "Claude Code" }, { "model" => "fixture-code" }].each do |selection|
      with_work(store: store, native: native, task: "third") do |work|
        assert_raises(Rho::T3::Error) { work.delegate({ "prompt" => "Third", "work_id" => id }.merge(selection)) }
      end
    end
    assert_equal 1, native.calls.count { |method, _| method == "orchestration.launchThread" }
    assert_equal 1, native.calls.count { |_, params| params["type"] == "message.dispatch" }
  end

  def test_native_run_cannot_silently_substitute_a_different_model
    native = T3Test::Native.new
    with_work(native: native, sleeper: -> { native.document.fetch("runs").last["modelSelection"] = { "instanceId" => "native-codex", "model" => "substituted" } }) do |work|
      error = assert_raises(Rho::T3::Error) { work.delegate("prompt" => "Fix it") }
      assert_match "model or provider changed", error.message
      assert native.calls.any? { |_, params| params["type"] == "run.interrupt" }
    end
  end

  def test_launch_persists_environment_and_returns_native_result_checks_and_diff
    with_work do |work, native, store, _, questions|
      result = work.delegate("prompt" => "Fix the parser")
      refute result.is_error
      assert_equal 2, result.files.length
      assert_match "fixture change", File.read(result.files.last)
      assert_match "Implemented and checked", result.content
      assert_match "ruby test.rb", result.content
      assert_equal({ "branch" => "main", "worktreePath" => "/work/project" }, store.rows.values.first.value.fetch("placement"))
      launch = native.calls.find { |method, _| method == "orchestration.launchThread" }.last
      assert_equal "approval-required", launch.fetch("runtimeMode")
      refute_includes JSON.generate(store.rows.values.map(&:value)), "fixture-bearer"
      assert_empty questions.calls, "native execution can finish without exposing an approval callback"
      refute native.calls.any? { |_, params| params["type"] == "runtime-request.respond" }
    end
  end

  def test_lost_launch_response_reconciles_same_thread_without_duplicate
    native = T3Test::Native.new
    native.uncertain_launch = true
    with_work(native: native) do |work, service|
      refute work.delegate("prompt" => "Fix it").is_error
      assert_equal 1, service.calls.count { |method, _| method == "orchestration.launchThread" }
    end
  end

  def test_partial_launch_without_accepted_message_remains_uncertain
    native = T3Test::Native.new
    native.uncertain_launch = native.partial_launch = true
    with_work(native: native) do |work, service|
      error = assert_raises(Rho::T3::Uncertain) { work.delegate("prompt" => "Fix it") }
      assert_match "no accepted message", error.message
      assert_equal 1, service.calls.count { |method, _| method == "orchestration.launchThread" }
    end
  end

  def test_incomplete_projection_reports_uncertain_stop_without_raw_parser_error
    native = T3Test::Native.new
    native.document.delete("runs")
    with_work(native: native) do |work|
      error = assert_raises(Rho::T3::Error) { work.delegate("prompt" => "Fix it") }
      assert_match "incomplete thread projection", error.message
      assert_match "Stop could not be confirmed", error.message
    end
  end

  def test_recovered_task_with_missing_projection_never_relaunches
    store, native = T3Test::Store.new, T3Test::Native.new
    with_work(store: store, native: native) { |work| work.delegate("prompt" => "Fix it") }
    native.missing = true
    with_work(store: store, native: native) do |work|
      assert_raises(Rho::T3::Uncertain) { work.delegate("prompt" => "Fix it") }
      assert_equal 1, native.calls.count { |method, _| method == "orchestration.launchThread" }
    end
  end

  def test_native_approval_is_a_task_owned_question_with_one_shot_answer
    native = T3Test::Native.new
    native.question
    with_work(native: native) do |work, service, _, _, questions|
      work.delegate("prompt" => "Fix it")
      assert_equal 1, questions.calls.length
      command = service.calls.map(&:last).find { |params| params["type"] == "runtime-request.respond" }
      assert_equal "accept", command.fetch("decision")
      assert_equal %w[accept decline], questions.calls.first.fetch(:options)
    end
  end

  def test_floor_refuses_dangerous_native_command_without_asking_for_override
    native = T3Test::Native.new
    native.question(prompt: "Run git push --force origin main?")
    with_work(native: native) do |work, service, _, _, questions|
      work.delegate("prompt" => "Fix it")
      assert_empty questions.calls
      assert_equal "decline", service.calls.map(&:last).find { |params| params["type"] == "runtime-request.respond" }.fetch("decision")
    end
  end

  def test_reason_text_cannot_hide_a_dangerous_command_from_the_floor
    native = T3Test::Native.new
    native.question(prompt: "Please approve the harmless check")
    native.document["turnItems"].last["input"] = "git push --force origin main"
    with_work(native: native) do |work, service, _, _, questions|
      work.delegate("prompt" => "Fix it")
      assert_empty questions.calls
      assert_equal "decline", service.calls.map(&:last).find { |params| params["type"] == "runtime-request.respond" }.fetch("decision")
    end
  end

  def test_missing_action_identity_does_not_approve_a_neighboring_command
    native = T3Test::Native.new
    native.question
    native.document["nodes"].first["parentNodeId"] = "missing"
    with_work(native: native) do |work, service, _, _, questions|
      work.delegate("prompt" => "Fix it")
      assert_empty questions.calls
      assert_equal "decline", service.calls.map(&:last).find { |params| params["type"] == "runtime-request.respond" }.fetch("decision")
    end
  end

  def test_session_wide_native_permission_is_never_substituted_for_one_shot_permission
    native = T3Test::Native.new
    native.question
    native.document["turnItems"].first["options"] = [{ "decision" => "acceptAlways", "label" => "Always" }]
    with_work(native: native) do |work, service, _, _, questions|
      work.delegate("prompt" => "Fix it")
      assert_empty questions.calls
      assert_equal "decline", service.calls.map(&:last).find { |params| params["type"] == "runtime-request.respond" }.fetch("decision")
    end
  end

  def test_generic_native_permission_cannot_widen_the_action_floor
    native = T3Test::Native.new
    native.question(kind: "permission")
    with_work(native: native) do |work, service, _, _, questions|
      work.delegate("prompt" => "Fix it")
      assert_empty questions.calls
      assert_equal "decline", service.calls.map(&:last).find { |params| params["type"] == "runtime-request.respond" }.fetch("decision")
    end
  end

  def test_running_native_worker_keeps_cancellation_owned_after_root_completion
    native = T3Test::Native.new
    native.document["subagents"] = [{ "id" => "worker", "status" => "running" }]
    iterations = 0
    with_work(native: native, sleeper: -> {
      iterations += 1
      native.complete
      native.document["subagents"].first["status"] = "completed" if iterations == 2
    }) do |work|
      work.delegate("prompt" => "Fix it")
      assert_equal 2, iterations
    end
  end

  def test_native_permission_mode_change_is_refused_and_stopped
    native = T3Test::Native.new
    native.document["thread"]["runtimeMode"] = "full-access"
    with_work(native: native) do |work, service|
      error = assert_raises(Rho::T3::Error) { work.delegate("prompt" => "Fix it") }
      assert_match "permission mode changed", error.message
      assert service.calls.any? { |_, params| params["type"] == "run.interrupt" }
    end
  end

  def test_list_and_forget_use_owned_continuation_slots_without_removing_task_results
    with_work do |work, _, store|
      work.delegate("prompt" => "Fix it", "title" => "Parser repair")
      id = store.rows.keys.first
      report = JSON.parse(work.control("action" => "list").content)
      assert_equal id, report.fetch("work").first.fetch("work_id")
      assert_equal "Parser repair", report.fetch("work").first.fetch("title")
      work.control("action" => "forget", "work_id" => id)
      assert_empty store.rows
    end
  end

  def test_native_question_answers_are_forwarded_under_original_question_identity
    native = T3Test::Native.new
    native.question(kind: "user_input")
    native.document["nodes"] = []
    native.document["turnItems"].select! { |item| item["requestId"] }
    with_work(native: native) do |work, service, _, _, questions|
      questions.answer = "blue"
      work.delegate("prompt" => "Fix it")
      response = service.calls.map(&:last).find { |params| params["type"] == "runtime-request.respond" }
      assert_equal({ "color" => "blue" }, response.fetch("answers"))
      refute response.key?("decision"), "an ordinary question has no identifiable operation to approve"
    end
  end

  def test_native_choice_preserves_provider_value_and_multiple_selection_shape
    native = T3Test::Native.new
    native.question(kind: "user_input")
    question = native.document.fetch("turnItems").first.fetch("questions").first
    question.merge!("multiSelect" => true, "allowCustomAnswer" => false,
      "options" => [{ "label" => "Blue", "value" => "blue-code" }, { "label" => "Green", "value" => "green-code" }])
    with_work(native: native) do |work, service, _, _, questions|
      questions.answer = '["Blue", "Green"]'
      work.delegate("prompt" => "Fix it")
      response = service.calls.map(&:last).find { |params| params["type"] == "runtime-request.respond" }
      assert_equal({ "color" => %w[blue-code green-code] }, response.fetch("answers"))
    end
  end

  def test_native_restart_during_human_wait_does_not_answer_dead_callback
    native = T3Test::Native.new
    native.question
    with_work(native: native) do |work, service, _, _, questions|
      questions.callback = -> { native.document["providerSessions"].first["status"] = "stopped" }
      error = assert_raises(Rho::T3::Error) { work.delegate("prompt" => "Fix it") }
      assert_match "expired", error.message
      refute service.calls.any? { |_, params| params["type"] == "runtime-request.respond" }
    end
  end

  def test_cancellation_interrupts_exact_native_run_and_does_not_return_late_final
    with_work do |work, native, _, context, questions|
      native.question
      questions.callback = -> { context.cancel(:canceled) }
      assert_raises(Rho::Runner::ExecutionContext::Cancelled) { work.delegate("prompt" => "Fix it") }
      stop = native.calls.map(&:last).find { |params| params["type"] == "run.interrupt" }
      assert_equal "native-run", stop.fetch("runId")
      assert stop.fetch("holdQueue")
      refute native.calls.any? { |_, params| params["type"] == "runtime-request.respond" }
    end
  end

  def test_continue_preserves_environment_and_launches_no_second_thread
    store, native = T3Test::Store.new, T3Test::Native.new
    with_work(store: store, native: native) { |work| work.delegate("prompt" => "First") }
    id = store.rows.keys.first
    with_work(store: store, native: native, task: "followup") do |work|
      refute work.delegate("prompt" => "Second", "work_id" => id).is_error
    end
    assert_equal 1, native.calls.count { |method, _| method == "orchestration.launchThread" }
    assert_equal 1, native.calls.count { |_, params| params["type"] == "message.dispatch" }
    with_work(store: store, native: native, task: "third", config: settings(project_id: "another-project")) do |work|
      assert_raises(Rho::T3::Error) { work.delegate("prompt" => "Third", "work_id" => id) }
    end
  end

  def test_rejected_takeover_does_not_stop_another_active_owner
    store, native = T3Test::Store.new, T3Test::Native.new
    with_work(store: store, native: native) { |work| work.delegate("prompt" => "First") }
    native.document.fetch("runs").last["status"] = "running"
    with_work(store: store, native: native, task: "followup") do |work, _, _, _, _, session|
      session.active = true
      assert_raises(Rho::T3::Error) { work.delegate("prompt" => "Second", "work_id" => store.rows.keys.first) }
      refute native.calls.any? { |_, params| params["type"] == "run.interrupt" }
    end
  end

  def test_changed_native_worktree_is_not_silently_adopted_on_continue
    store, native = T3Test::Store.new, T3Test::Native.new
    with_work(store: store, native: native) { |work| work.delegate("prompt" => "First") }
    native.document.fetch("thread")["worktreePath"] = "/other/checkout"
    with_work(store: store, native: native, task: "followup") do |work|
      error = assert_raises(Rho::T3::Error) { work.delegate("prompt" => "Second", "work_id" => store.rows.keys.first) }
      assert_match "branch or worktree changed", error.message
      refute native.calls.any? { |_, params| params["type"] == "message.dispatch" }
    end
  end

  def test_steering_during_wait_does_not_overwrite_continuation_or_discard_final_result
    store, native = T3Test::Store.new, T3Test::Native.new
    with_work(store: store, native: native, sleeper: -> {
      with_work(store: store, native: native, task: "steer") do |controller, _, _, _, _, session|
        session.active = true
        controller.control("action" => "steer", "work_id" => store.rows.keys.first, "prompt" => "Also test the edge case")
      end
      native.complete
    }) do |work|
      result = work.delegate("prompt" => "Fix it")
      refute result.is_error
      assert_match "Implemented and checked", result.content
      assert_equal "run:steer", store.rows.values.first.value.fetch("pending_command").fetch("key")
    end
  end

  def test_final_capture_fetches_native_check_output_omitted_from_projection
    native = T3Test::Native.new
    native.document["turnItems"] = [{ "id" => "check", "type" => "command_execution", "input" => "ruby test.rb", "outputOmitted" => true }]
    with_work(native: native) do |work|
      result = work.delegate("prompt" => "Fix it")
      assert_match "All checks passed", File.read(result.files.first)
      assert native.calls.any? { |method, params| method == "orchestration.getTurnItem" && params.fetch("itemId") == "check" }
    end
  end

  def test_forked_continuation_cannot_control_original_work
    store = T3Test::Store.new
    row = Rho::T3::Records.new(store: store, conversation: "original").create("one", {})
    records = Rho::T3::Records.new(store: store, conversation: "fork")
    assert_raises(Rho::T3::Error) { records.fetch(row.public_id) }
  end

  def test_diff_failure_is_visible_without_discarding_completed_checks
    native = T3Test::Native.new
    native.diff_failure = true
    with_work(native: native) do |work|
      result = work.delegate("prompt" => "Fix it")
      refute result.is_error
      assert_equal 1, result.files.length
      assert_match "Final diff could not be read", result.content
      assert_match "ruby test.rb", result.content
    end
  end
end
