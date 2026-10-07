require "support/runtime"
require "support/schedules"

class TelegramScheduleWorkflowTest < Minitest::Test
  include TelegramRuntimeSupport

  def setup
    super
    @bridge.extend(TelegramScheduleSupport)
    @bridge.prepare_schedules
    @bridge.define_singleton_method(:worker_result) do |source, workspace_public_id:|
      execution = @job_execution_rows.values.flatten.find { |row| row["input_public_id"] == source.fetch("input_public_id") }
      { "public_id" => source.fetch("turn_public_id"), "variant_public_id" => source.fetch("variant_public_id"),
        "kind" => "direct_reply", "status" => "completed", "run_public_id" => execution&.fetch("run_public_id"),
        "text" => "Independent scheduled final" }
    end
  end

  def test_once_job_freezes_requester_and_read_only_policy_without_submitting_a_main_input
    @runtime.consume(group_message(1, "/job create once in 30m inspect the report"))

    assert_empty @bridge.inputs
    row = @bridge.job_rows.values.fetch(0)
    assert_equal "inspect the report", row.fetch("prompt")
    assert_equal({ "kind" => "once", "run_at" => "1970-01-01T00:46:40Z" }, row.fetch("rule"))
    assert_equal "speaker-2", row.fetch("speaker_public_id")
    assert_equal "group-agent", row.fetch("answering_user_public_id")
    assert_equal @bridge.read_only_tool_names(row.fetch("conversation_public_id"), group: true, workspace_public_id: "workspace-home"), row.fetch("tool_names")
    binding = @state.read.fetch("job_bindings").fetch(row.fetch("public_id"))
    assert_equal "2", binding.fetch("owner_id")
    assert_equal "-10:4:2", binding.fetch("route_key")
    assert_equal "conversation-1", binding.fetch("conversation_id")
    assert_empty binding.keys & %w[prompt rule next_run_at status]
    assert_includes feedback(1), row.fetch("public_id")
    assert_includes feedback(1), "independently"
  end

  def test_history_reread_recovers_private_job_report_ownership_and_original_controls
    main_id = input_id(98)
    submit = @bridge.method(:submit)
    @bridge.define_singleton_method(:submit) do |id, **request|
      result = submit.call(id, **request)
      result.fetch("input")["public_id"] = main_id if request.fetch(:idempotency_key) == "telegram:42:2:input"
      result
    end
    @bridge.define_singleton_method(:recent_turns) do |id, before_position: nil, workspace_public_id:|
      { "turns" => @turn_rows.fetch(id, []), "pagination" => { "has_older" => false } }
    end
    @runtime.consume(telegram_message(1, "/new"))
    @runtime.consume(telegram_message(2, "Prepare these reports"))
    @runtime.consume(telegram_message(3, "/job create once in 30m inspect A"))
    @runtime.consume(telegram_message(4, "/job create once in 30m inspect B"))
    @bridge.job_rows.keys.each_with_index { |id, index| add_execution(number: index + 1, job: id) }
    assert_equal ["speaker-1"], @bridge.job_rows.values.map { |row| row.fetch("speaker_public_id") }.uniq
    assert_equal "speaker-1", @state.read.fetch("speakers").fetch("1")

    report_id = input_id(99)
    sources = [1, 2].map do |number|
      source = callback_turn(number: number).fetch("callback_sources").first
      source.fetch("result")["requester_speaker_public_id"] = "speaker-1"
      source
    end
    @bridge.turn_rows["conversation-1"] = [turn(0, "Main ready"), turn(1, "Combined scheduled report").merge(
      "input_public_id" => report_id, "run_public_id" => "regenerated-report-loop", "callback_sources" => sources)]
    @state.change do |document|
      document.fetch("work")[report_id] = { "parent_report" => true, "input_id" => report_id,
        "turn_id" => "turn-1", "run_id" => "original-report-loop", "requester_speaker_public_id" => "speaker-1" }
    end
    @runtime = runtime
    8.times { @now += 60; @runtime.tick }
    report_message = @state.read.fetch("messages").find { |_key, owner| owner == "report:#{report_id}" }.first.split(":").last.to_i
    @state.change do |document|
      document.fetch("work")[report_id] = document.fetch("work").fetch(report_id)
        .except("owner_id", "route_key", "room_key", "conversation_id", "workspace_public_id")
    end
    @runtime = runtime
    @now += 60
    @runtime.tick
    refute @state.read.fetch("work").fetch(report_id).key?("owner_id"), "restart does not rewind consumed history"
    @runtime.consume(telegram_message(5, "/deliver #{main_id} 1:0"))
    assert_includes feedback(5), "latest completed result is queued once"

    report = @state.read.fetch("work").fetch(report_id)
    assert_equal "1", report.fetch("owner_id")
    assert_equal "1:0", report.fetch("route_key")
    assert_equal "1:0", report.fetch("room_key")
    assert_equal "conversation-1", report.fetch("conversation_id")
    assert_equal "workspace-home", report.fetch("workspace_public_id")
    assert_equal "original-report-loop", report.fetch("run_id")
    refute report.key?("request_id")
    refute report.key?("source_loop_id")
    @runtime.consume(telegram_message(6, "/new"))
    @runtime.consume(telegram_message(7, "Explain the comparison", reply_to: report_message))
    assert_equal "conversation-1", @bridge.inputs.fetch("telegram:42:7:input").fetch(:conversation_id)
    @runtime.consume(telegram_message(8, "/steer include the differences", reply_to: report_message))
    assert_equal "original-report-loop", @bridge.inputs.fetch("telegram:42:8:input").fetch(:expected_steering_run_public_id)
    @runtime.consume(telegram_message(9, "/stop #{report_id}"))
    assert_equal [["original-report-loop", "run", "workspace-home"]], @bridge.stop_calls
    executions = []
    @bridge.define_singleton_method(:task_execution) do |id, workspace_public_id:|
      executions << [id, workspace_public_id]
      { "status" => "completed" }
    end
    @runtime.consume(telegram_message(10, "/status #{report_id}"))
    assert_equal [["original-report-loop", "workspace-home"]], executions
    assert_equal %w[scheduled-loop scheduled-loop-2], @state.read.fetch("requests").values
      .select { |row| row["schedule_id"] }.map { |row| row.fetch("run_id") }
  end

  def test_relative_create_replays_the_original_rule_and_policy_after_restart
    update = group_message(1, "/job create every 20m inspect the report")
    @bridge.fail_job_create = true
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    first = @bridge.job_calls.first
    @now += 1_300
    @bridge.declared_tools[true] << "new-tool"
    @runtime = runtime
    @runtime.consume(update)

    assert_equal 1, @bridge.job_rows.length
    assert_equal first, @bridge.job_calls.last
    assert_equal "1970-01-01T00:36:40Z", @bridge.job_rows.values.first.fetch("rule").fetch("starts_at")
    assert_equal 1, @state.read.fetch("job_bindings").length
  end

  def test_lost_control_response_is_not_reapplied_after_restart
    create_group_job
    @bridge.fail_job_control = true
    update = group_message(2, "/job pause #{job_id}")
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    calls = @bridge.job_calls.length
    @runtime = runtime
    @runtime.consume(update)

    assert_equal calls, @bridge.job_calls.length
    assert_equal "paused", @bridge.job_rows.fetch(job_id).fetch("status")
    assert_includes feedback(2), "not repeated"
  end

  def test_job_commands_keep_original_conversation_after_new_and_reject_other_requesters
    create_group_job
    @runtime.consume(group_message(2, "/new"))
    @runtime = runtime
    @runtime.consume(group_message(3, "/job edit #{job_id} prompt revised report"))
    assert_equal "conversation-1", @bridge.job_calls.last[1]
    assert_equal "revised report", @bridge.job_rows.fetch(job_id).fetch("prompt")
    assert_equal ["conversation-1", true, "workspace-home"], @bridge.tool_selections.last
    @state.change { |document| document.fetch("access").fetch("allowed_users") << "3" }
    before = @bridge.job_calls.length
    @runtime.consume(group_message(4, "/job cancel #{job_id}", user: 3))

    assert_equal before, @bridge.job_calls.length
    assert_includes feedback(4), "requester or the bot owner"
  end

  def test_nonowner_cannot_resume_or_edit_a_job_whose_current_policy_is_no_longer_read_only
    create_group_job
    @bridge.job_rows.fetch(job_id)["tool_names"] = ["bash"]
    @runtime.consume(group_message(2, "/job resume #{job_id}"))
    @runtime.consume(group_message(3, "/job edit #{job_id} prompt run again"))
    assert_equal ["create"], @bridge.job_calls.map { |call| call.first.action }
    assert_includes feedback(2), "read-only"
    @runtime.consume(group_message(4, "/job cancel #{job_id}"))
    assert_equal "canceled", @bridge.job_rows.fetch(job_id).fetch("status")
  end

  def test_restart_recovers_independent_execution_and_main_callback_without_events
    create_group_job
    @runtime.consume(group_message(2, "/new"))
    add_execution
    @bridge.turn_rows["conversation-1"] = [callback_turn]
    @runtime = runtime
    4.times { @runtime.tick; @now += 5 }

    request = @state.read.fetch("requests").values.find { |row| row["input_id"] == input_id }
    assert_equal "2", request.fetch("owner_id")
    assert_equal "conversation-1", request.fetch("conversation_id")
    assert_equal "scheduled-child", request.fetch("execution_conversation_id")
    assert_equal "scheduled-loop", request.fetch("run_id")
    sends = @client.calls.select { |method, params| method == "sendMessage" && params[:text] == "Scheduled report" }
    assert_equal 1, sends.length
    assert_equal "-10", sends.first.last.fetch(:chat_id)
    assert_equal 4, sends.first.last.fetch(:message_thread_id)
    refute @state.read.fetch("routes").fetch("-10:4:2").fetch("conversations").key?("scheduled-child")
    assert_equal "execution-1", @state.read.fetch("job_bindings").fetch(job_id).fetch("execution_after")
    @runtime.consume(group_message(3, "/stop #{input_id}"))
    assert_equal [["scheduled-loop", "run", "workspace-home"]], @bridge.stop_calls
  end

  def test_each_occurrence_has_its_own_task_identity_and_steers_the_selected_child
    create_group_job
    add_execution
    add_execution(number: 2)
    @runtime.tick
    @runtime.consume(group_message(2, "/steer #{input_id} include totals"))
    input = @bridge.inputs.values.last
    assert_equal "scheduled-child", input.fetch(:conversation_id)
    assert_equal "scheduled-loop", input.fetch(:expected_steering_run_public_id)
    assert_equal 2, @state.read.fetch("requests").values.count { |row| row["schedule_id"] == job_id }
  end

  def test_unmaterialized_execution_is_revisited_before_the_cursor_advances
    create_group_job
    add_execution(run_id: nil)
    @runtime.tick
    assert_nil @state.read.fetch("job_bindings").fetch(job_id)["execution_after"]
    @bridge.job_execution_rows.fetch(job_id).first["run_public_id"] = "scheduled-loop"
    @now += 61
    @runtime.tick
    assert_equal "execution-1", @state.read.fetch("job_bindings").fetch(job_id).fetch("execution_after")
    assert_equal "scheduled-loop", @state.read.fetch("requests").values.first.fetch("run_id")
  end

  def test_scheduled_task_does_not_replace_the_main_task_selected_by_unqualified_stop
    update = group_message(1, "@rho_bot main work")
    update.fetch("message")["entities"] = [{ "type" => "mention", "offset" => 0, "length" => 8 }]
    @runtime.consume(update)
    @runtime.consume(group_message(2, "/job create every 20m inspect the report"))
    add_execution
    @runtime.tick
    @runtime.consume(group_message(3, "/stop"))
    assert_equal [["loop-1", "run", "workspace-home"]], @bridge.stop_calls
  end

  def test_commands_list_show_history_edit_and_cancel_the_same_job
    create_group_job
    @runtime.consume(group_message(2, "/job list"))
    assert_includes feedback(2), job_id
    @runtime.consume(group_message(3, "/job show #{job_id}"))
    assert_includes feedback(3), "inspect the report"
    @runtime.consume(group_message(4, "/job edit #{job_id} daily 09:00 Asia/Shanghai"))
    assert_equal({ "kind" => "daily", "local_time" => "09:00", "time_zone" => "Asia/Shanghai" }, @bridge.job_rows.fetch(job_id).fetch("rule"))
    add_execution
    @runtime.consume(group_message(5, "/job history #{job_id}"))
    assert_includes feedback(5), "Task: #{input_id}"
    @runtime.consume(group_message(6, "/job cancel #{job_id}"))
    assert_equal "canceled", @bridge.job_rows.fetch(job_id).fetch("status")
    assert_equal "scheduled-loop", @state.read.fetch("requests").values.first.fetch("run_id")
  end

  def test_create_response_beyond_receipt_window_is_not_submitted_again
    @bridge.fail_job_create = true
    update = group_message(1, "/job create once in 30m inspect")
    assert_raises(Rho::ConnectionError) { @runtime.consume(update) }
    @now += 86_400
    @runtime = runtime
    @runtime.consume(update)
    assert_equal 1, @bridge.job_calls.length
    assert_equal 1, @bridge.job_rows.length
    assert_includes feedback(1), "/job list"
    assert_empty @state.read.fetch("job_bindings")
    inspect = group_message(2, "/job list")
    inspect.fetch("message")["date"] = @now.to_i
    @runtime.consume(inspect)
    assert_includes feedback(2), job_id
    assert_empty @state.read.fetch("job_bindings"), "a visible record does not prove requester ownership"
  end

  def test_model_created_job_adopts_only_a_known_source_without_inheriting_its_result_destination
    @runtime.consume(telegram_message(1, "Inspect this report"))
    source = @state.read.fetch("requests").values.first
    @state.change do |document|
      document.fetch("requests").values.first["result_destination"] = { "chat_id" => "-10", "topic_id" => 4, "group" => true }
    end
    id = "01980000-0000-7000-8000-000000000001"
    @bridge.job_rows[id] = { "public_id" => id, "conversation_public_id" => "conversation-1",
      "source_run_public_id" => source.fetch("run_id"), "source_task_key" => "r2.job" }
    @bridge.job_rows["01980000-0000-7000-8000-000000000002"] = @bridge.job_rows[id].merge(
      "public_id" => "01980000-0000-7000-8000-000000000002", "source_run_public_id" => "unknown-loop")
    add_execution
    wire = @bridge.schedules("conversation-1", workspace_public_id: "workspace-home")
    refute wire.fetch("schedules").any? { |row| row.key?("conversation_public_id") },
      "the SDK row relies on the already scoped conversation context"
    @runtime = runtime
    @runtime.tick
    binding = @state.read.fetch("job_bindings").fetch(id)
    assert_equal "1", binding.fetch("owner_id")
    assert_equal "telegram:42:1:input", binding.fetch("source_request_id")
    refute binding.key?("result_destination")
    assert_equal [id], @state.read.fetch("job_bindings").keys
    occurrence = @state.read.fetch("requests").fetch("scheduled:#{input_id}")
    refute occurrence.key?("result_destination")
  end

  def test_pending_execution_does_not_block_an_unrelated_main_answer
    create_group_job
    add_execution(run_id: nil)
    @bridge.turn_rows["conversation-1"] = [turn(0, "Main answer")]
    3.times { @runtime.tick; @now += 5 }
    assert @client.calls.any? { |method, params| method == "sendMessage" && params[:text] == "Main answer" }
    assert_nil @state.read.fetch("job_bindings").fetch(job_id)["execution_after"]
  end

  def test_execution_history_pagination_finishes_before_callback_is_published
    create_group_job
    101.times { |index| add_execution(number: index + 1) }
    @bridge.turn_rows["conversation-1"] = [callback_turn(number: 101)]
    @runtime.tick
    assert_equal 100, @state.read.fetch("requests").length
    refute @state.read.fetch("deliveries").values.any? { |row| row["text"] == "Scheduled report" }
    @now += 5
    @runtime.tick
    assert_equal 101, @state.read.fetch("requests").length
    request = @state.read.fetch("requests").fetch("scheduled:#{input_id(101)}")
    assert_equal input_id(101), request.fetch("canonical_result").fetch("input_public_id")
    assert @client.calls.any? { |method, params| method == "sendMessage" && params[:text] == "Scheduled report" }
  end

  def test_tool_free_execution_callback_uses_its_exact_child_identity
    create_group_job
    add_execution(run_id: nil)
    @bridge.job_execution_rows.fetch(job_id).first["status"] = "completed"
    @bridge.turn_rows["conversation-1"] = [callback_turn(run_id: nil)]
    3.times { @runtime.tick; @now += 5 }
    request = @state.read.fetch("requests").fetch("scheduled:#{input_id}")
    assert_equal "scheduled-child", request.fetch("canonical_result").fetch("conversation_public_id")
    assert_equal "execution-1", @state.read.fetch("job_bindings").fetch(job_id).fetch("execution_after")
    assert @client.calls.any? { |method, params| method == "sendMessage" && params[:text] == "Scheduled report" }
  end

  def test_canceled_input_without_a_loop_does_not_hold_the_execution_cursor
    create_group_job
    add_execution(run_id: nil)
    @bridge.job_execution_rows.fetch(job_id).first.merge!("status" => "canceled", "turn_public_id" => nil)
    @runtime.tick
    assert_equal "execution-1", @state.read.fetch("job_bindings").fetch(job_id).fetch("execution_after")
    assert @state.read.fetch("requests").fetch("scheduled:#{input_id}").fetch("retired")
  end

  def test_explicit_destination_copy_recovers_a_durable_callback_before_the_next_follower_tick
    create_group_job
    add_execution
    @runtime.consume(group_message(2, "/job history #{job_id}"))
    @runtime.consume(telegram_message(3, "/new"))
    @bridge.turn_rows["conversation-1"] = [callback_turn]
    @bridge.define_singleton_method(:recent_turns) do |id, before_position: nil, workspace_public_id:|
      { "turns" => @turn_rows.fetch(id, []), "pagination" => { "has_older" => false } }
    end
    @runtime.consume(telegram_message(4, "/deliver #{input_id} 1:0"))
    assert_includes feedback(4), "latest completed result is queued once"
    result = @state.read.fetch("deliveries").values.find { |row| row["result_copy"] }
    assert_equal "scheduled:#{input_id}", result.fetch("request_id")
    assert_equal "1", result.fetch("chat_id")
    assert_equal "scheduled-child", result.fetch("conversation_id")
    assert_includes result.fetch("text"), "Independent scheduled final"
    refute_includes result.fetch("text"), "Scheduled report"
  end

  private

    def create_group_job
      @runtime.consume(group_message(1, "/job create every 20m inspect the report"))
    end

    def group_message(id, text, user: 2)
      telegram_message(id, text, user: user, chat: -10, topic: 4)
    end

    def job_id = @bridge.job_rows.keys.first
    def input_id(number = 1) = "01980000-0000-7000-9000-#{number.to_s.rjust(12, "0")}"
    def feedback(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")

    def add_execution(number: 1, run_id: "scheduled-loop", job: job_id)
      (@bridge.job_execution_rows[job] ||= []) << {
        "child_conversation_public_id" => number == 1 ? "scheduled-child" : "scheduled-child-#{number}",
        "input_public_id" => input_id(number), "turn_public_id" => "scheduled-turn-#{number}",
        "run_public_id" => number == 1 ? run_id : "scheduled-loop-#{number}",
        "scheduled_for" => "1970-01-01T00:36:40Z", "status" => run_id ? "completed" : "pending", "created_at" => "1970-01-01T00:36:40Z",
      }
    end

    def callback_turn(number: 1, run_id: "scheduled-loop")
      child_id = number == 1 ? "scheduled-child" : "scheduled-child-#{number}"
      source_loop = number == 1 ? run_id : "scheduled-loop-#{number}"
      turn(0, "Scheduled report").merge("sender_conversation_public_id" => child_id,
        "sender_run_public_id" => source_loop, "run_public_id" => "callback-loop", "callback_sources" => [{
          "input_public_id" => "callback-#{number}", "origin" => "child", "sender_conversation_public_id" => child_id,
          "sender_run_public_id" => source_loop, "sender_task_key" => "schedule_report", "result" => {
            "conversation_public_id" => child_id, "input_public_id" => input_id(number), "turn_public_id" => "scheduled-turn-#{number}",
            "variant_public_id" => "scheduled-variant-#{number}", "requester_speaker_public_id" => "speaker-2",
          },
        }])
    end
end
