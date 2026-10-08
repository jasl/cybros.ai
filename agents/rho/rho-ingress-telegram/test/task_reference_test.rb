require "support/runtime"

class TelegramTaskReferenceTest < Minitest::Test
  include TelegramRuntimeSupport

  def setup
    super
    @state.change do |document|
      document.fetch("access").fetch("allowed_users") << "3"
      document.fetch("access").fetch("allowed_chats") << "-20"
    end
    @execution_reads = []
    reads = @execution_reads
    @bridge.define_singleton_method(:submit) do |id, **request|
      result = super(id, **request)
      number = result.fetch("input").fetch("public_id").delete_prefix("input-").to_i
      result.fetch("input")["public_id"] = TelegramTaskReferenceTest.task_id(number)
      result
    end
    @bridge.define_singleton_method(:task_execution) do |id, workspace_public_id:|
      reads << [id, workspace_public_id]
      { "status" => id == "loop-1" ? "completed" : "running" }
    end
  end

  def self.task_id(number) = "019a1234-5678-7000-8000-#{format("%012d", number)}"

  def test_status_exposes_stable_task_ids_without_chat_receipts_or_steering_replacing_them
    request(1)
    request(2)
    refute @state.read.fetch("deliveries").key?("control:1")
    control(3, "/status")
    assert_includes feedback(3), task_id(1)
    assert_includes feedback(3), task_id(2)
    control(4, "/steer #{task_id(1)} keep A's goal")
    submitted = @bridge.inputs.fetch("telegram:42:4:input")
    assert_equal "keep A's goal", submitted.fetch(:text)
    assert_equal "loop-1", submitted.fetch(:expected_steering_run_public_id)
    assert_equal task_id(1), @state.read.fetch("requests").fetch("telegram:42:1:input").fetch("input_id")
    refute @state.read.fetch("requests").values.any? { |row| row["input_id"] == task_id(3) }
  end

  def test_same_conversation_tasks_keep_distinct_status_and_stop_targets
    request(1)
    request(2)
    @bridge.current = { "status" => "running", "action" => "working on B", "run_public_id" => "loop-2" }
    control(3, "/status #{task_id(1)}")
    control(4, "/stop #{task_id(1)}")
    assert_equal [["loop-1", "workspace-home"]], @execution_reads
    assert_includes feedback(3), "Root execution: completed (loop-1)"
    refute_includes feedback(3), "loop-2"
    assert_equal [["loop-1", "run", "workspace-home"]], @bridge.stop_calls
    assert_equal "conversation-1", @state.read.fetch("routes").fetch("-10:4:2").fetch("current")
    assert_equal 2, @bridge.inputs.length
  end

  def test_new_workspace_resume_and_disk_restart_keep_the_original_scope
    request(1)
    control(2, "/workspace use workspace-project", user: 1, reply_to: 1, reply_user: 2)
    control(3, "/new")
    request(4)
    @bridge.define_singleton_method(:attach) { |id, workspace_public_id:| { "public_id" => id } }
    control(5, "/resume conversation-1")
    control(6, "/resume conversation-3")
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime
    control(7, "/stop #{task_id(1)}")
    control(8, "/steer #{task_id(1)} exact old task")
    assert_equal [["loop-1", "run", "workspace-home"]], @bridge.stop_calls
    submitted = @bridge.inputs.fetch("telegram:42:8:input")
    assert_equal "conversation-1", submitted.fetch(:conversation_id)
    assert_equal "workspace-home", submitted.fetch(:workspace_public_id)
    assert_equal "loop-1", submitted.fetch(:expected_steering_run_public_id)
    current = @state.read.fetch("routes").fetch("-10:4:2")
    assert_equal "conversation-3", current.fetch("current")
    assert_equal "workspace-project", current.fetch("workspace_public_id")
    assert_equal "workspace-project", @bridge.inputs.fetch("telegram:42:4:input").fetch(:workspace_public_id)
  end

  def test_known_original_execution_does_not_depend_on_retained_event_history
    request(1)
    @bridge.define_singleton_method(:events) do |*_arguments, **_options|
      raise Rho::Core::Refused.new("Event cursor expired", status: 410, code: "cursor_expired")
    end
    control(2, "/status #{task_id(1)}")
    control(3, "/stop #{task_id(1)}")

    assert_includes feedback(2), "Root execution: completed (loop-1)"
    assert_equal ["loop-1"], @bridge.stops
  end

  def test_pending_task_stop_deletes_only_its_input_and_steer_does_not_admit_new_work
    @bridge.defer_inputs = true
    request(1)
    request(2)
    @bridge.queue_rows["conversation-1"] = [1, 2].map { |id| { "public_id" => task_id(id), "state" => "pending" } }
    control(3, "/status #{task_id(1)}")
    control(4, "/steer #{task_id(1)} change waiting A")
    control(5, "/stop #{task_id(1)}")
    assert_includes feedback(3), "Input: pending"
    assert_includes feedback(4), "no known execution to steer"
    assert_equal [[:cancel, "conversation-1", task_id(1), "workspace-home"]], @bridge.queue_writes
    assert_equal [task_id(2)], @bridge.queue_rows.fetch("conversation-1").map { |row| row.fetch("public_id") }
    assert_equal 2, @bridge.inputs.length
    assert_empty @bridge.stops
  end

  def test_pending_materialization_delete_conflict_does_not_stop_the_current_execution
    @bridge.defer_inputs = true
    request(1)
    @bridge.defer_inputs = false
    request(2)
    attempts = []
    @bridge.define_singleton_method(:delete_input) do |id, input_id, **options|
      attempts << [id, input_id, options]
      raise Rho::Core::Refused.new("Input already materialized", status: 409, code: "input_not_pending")
    end
    control(3, "/stop #{task_id(1)}")
    assert_equal [["conversation-1", task_id(1), { workspace_public_id: "workspace-home" }]], attempts
    assert_includes feedback(3), "Input already materialized"
    assert_empty @bridge.stops
  end

  def test_materialized_event_maps_the_task_to_its_first_loop_before_explicit_stop
    @bridge.defer_inputs = true
    request(1)
    @bridge.event_rows["conversation-1"] = [
      event(1, "input_materialized", "input_public_id" => task_id(1), "turn_public_id" => "original-turn"),
      event(2, "turn_status", "turn_public_id" => "original-turn", "run_public_id" => "original-loop"),
      event(3, "turn_status", "turn_public_id" => "original-turn", "run_public_id" => "regenerated-loop"),
    ]
    control(2, "/stop #{task_id(1)}")
    assert_equal [["original-loop", "run", "workspace-home"]], @bridge.stop_calls
  end

  def test_explicit_id_takes_precedence_over_reply_to_another_or_unknown_task
    request(1)
    request(2, user: 3)
    control(3, "/stop #{task_id(1)}", reply_to: 2, reply_user: 3)
    control(4, "/steer #{task_id(1)} own task", reply_to: 999)
    control(5, "/status #{task_id(1)}", reply_to: 2, reply_user: 3)
    assert_equal ["loop-1"], @bridge.stops
    assert_equal "loop-1", @bridge.inputs.fetch("telegram:42:4:input").fetch(:expected_steering_run_public_id)
    assert_equal [["loop-1", "workspace-home"]], @execution_reads
  end

  def test_other_requester_wrong_room_and_wrong_topic_cannot_read_or_control_a_task
    request(1)
    id = 1
    ["/status", "/stop", "/steer"].each do |command|
      text = "#{command} #{task_id(1)}#{" change" if command == "/steer"}"
      control(id += 1, text, user: 3)
      assert_includes feedback(id), "Only this task's requester or the bot owner"
      control(id += 1, text, user: 1, topic: 5)
      assert_includes feedback(id), "not available in this chat/topic"
      control(id += 1, text, user: 1, chat: -20)
      assert_includes feedback(id), "not available in this chat/topic"
    end
    assert_empty @bridge.stops
    assert_empty @execution_reads
    assert_equal 1, @bridge.inputs.length
    control(11, "/stop #{task_id(1)}", user: 1)
    assert_equal ["loop-1"], @bridge.stops
  end

  def test_unknown_and_malformed_references_never_fall_back_to_the_current_task
    request(1)
    ["/stop #{task_id(99)}", "/status #{task_id(99)}", "/steer #{task_id(99)} wrong task",
      "/stop typo", "/status #{task_id(1)} extra", "/steer #{task_id(1)}", "/steer 019a1234-typo change"].each_with_index do |text, index|
      control(index + 2, text)
      assert_match(/not available|Use \/(?:stop|status|steer)/, feedback(index + 2))
    end
    assert_empty @bridge.stops
    assert_empty @execution_reads
    assert_equal 1, @bridge.inputs.length
  end

  def test_deleted_pending_task_is_reported_and_does_not_redirect_stop
    @bridge.defer_inputs = true
    request(1)
    @bridge.event_rows["conversation-1"] = [event(1, "input_deleted", "input_public_id" => task_id(1))]
    control(2, "/status #{task_id(1)}")
    control(3, "/stop #{task_id(1)}")
    assert_includes feedback(2), "Input: canceled"
    assert_includes feedback(3), "already canceled"
    assert_empty @bridge.stops
    assert_empty @bridge.queue_writes
  end

  def test_lost_steer_response_retries_the_exact_reference_and_stopped_response_is_not_repeated
    request(1)
    request(2)
    update = telegram_message(3, "/steer #{task_id(1)} retained instruction", user: 2, chat: -10, topic: 4)
    @bridge.fail_input = true
    assert_raises(Rho::ConnectionError) { receive(update) }
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime
    receive(update)
    assert_equal "loop-1", @bridge.inputs.fetch("telegram:42:3:input").fetch(:expected_steering_run_public_id)
    @bridge.fail_stop = true
    stop = telegram_message(4, "/stop #{task_id(1)}", user: 2, chat: -10, topic: 4)
    assert_raises(Rho::ConnectionError) { receive(stop) }
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime
    receive(stop)
    assert_equal ["loop-1"], @bridge.stops
    assert_includes feedback(4), "It was not repeated"
  end

  def test_terminal_root_steering_refusal_does_not_choose_a_child_or_current_task
    request(1)
    request(2)
    targets = []
    @bridge.define_singleton_method(:submit) do |id, **options|
      targets << [id, options.fetch(:expected_steering_run_public_id)]
      raise Rho::Core::Refused.new("Root no longer accepts steering", status: 409, code: "steering_target_changed")
    end
    control(3, "/steer #{task_id(1)} too late")
    assert_equal [["conversation-1", "loop-1"]], targets
    assert_includes feedback(3), "Root no longer accepts steering"
    assert_equal 2, @bridge.inputs.length
  end

  private

    def task_id(number) = self.class.task_id(number)

    def request(id, user: 2)
      receive(telegram_message(id, "@rho_bot task #{id}", user: user, chat: -10, topic: 4,
        entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }]))
    end

    def control(id, text, **options)
      receive(telegram_message(id, text, **{ user: 2, chat: -10, topic: 4 }.merge(options)))
    end

    def feedback(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")

    def event(sequence, type, payload)
      { "sequence" => sequence, "cursor" => sequence.to_s, "type" => type, "payload" => payload }
    end
end
