require "support/runtime"

class TelegramWorkerResultDeliveryTest < Minitest::Test
  include TelegramRuntimeSupport

  def setup
    super
    receive(telegram_message(1, "Prepare independent reports"))
    receive(telegram_message(2, "/new", chat: -10, topic: 4))
    @worker_results, @worker_requests, @worker_reads = {}, {}, []
    results, requests, reads = @worker_results, @worker_requests, @worker_reads
    @bridge.define_singleton_method(:worker_request) do |id, workspace_public_id:|
      reads << [:request, id, workspace_public_id]
      requests[id]
    end
    @bridge.define_singleton_method(:worker_result) do |source, workspace_public_id:|
      reads << [:result, source, workspace_public_id]
      value = results[source.fetch("variant_public_id")]
      raise value if value in Exception

      value
    end
    @bridge.define_singleton_method(:task_execution) do |id, workspace_public_id:|
      reads << [:execution, id, workspace_public_id]
      { "status" => "completed" }
    end
    @bridge.define_singleton_method(:recent_turns) do |id, before_position: nil, workspace_public_id:|
      { "turns" => @turn_rows.fetch(id, []), "pagination" => { "has_older" => false } }
    end
  end

  def test_busy_child_receipt_can_select_future_destination_without_following_the_child
    @bridge.current["children"] = [{ "public_id" => "child-a", "label" => "A", "spawn_node_key" => "r1.a", "busy" => true }]
    @worker_requests["child-a"] = worker_turn("a", status: "running")
    @runtime.tick

    request = worker_request("a")
    assert_equal "child-a", request.fetch("execution_conversation_id")
    assert_nil request["run_id"]
    assert_equal "conversation-1", request.fetch("conversation_id")
    refute @state.read.fetch("routes").values.any? { |route| route.fetch("conversations").key?("child-a") }
    receive(telegram_message(3, "/deliver #{task_id("a")} -10:4"))
    assert_includes feedback(3), "no completed result to copy"

    publish_report(%w[a], "Parent report")
    drain
    assert_equal ["-10"], sends("Worker a result").map { |row| row.fetch(:chat_id) }
    assert_equal ["1"], sends("Parent report").map { |row| row.fetch(:chat_id) }
  end

  def test_same_child_later_send_has_another_task_identity
    @bridge.current["children"] = [{ "public_id" => "child-a", "busy" => true }]
    @worker_requests["child-a"] = worker_turn("a", status: "running")
    @runtime.tick
    @worker_requests["child-a"] = worker_turn("b", status: "running").merge("conversation_public_id" => "child-a")
    @bridge.current["sequence"] += 1
    @now += 60
    @runtime.tick

    assert_nil worker_request("a")["run_id"]
    assert_nil worker_request("b")["run_id"]
    assert_equal "child-a", worker_request("b").fetch("execution_conversation_id")
  end

  def test_fast_workers_and_mixed_parent_report_keep_separate_destinations_and_receipts
    publish_report(%w[a b], "Combined A and B")
    @state.change { |document| document["retry_at"] = @now + 1_000 }
    @runtime.tick
    summary = @state.read.fetch("deliveries").values.find { |row| row["text"] == "Combined A and B" }
    assert_equal "1", summary.fetch("chat_id")
    assert_nil summary["request_id"]
    assert_equal %w[a b].map { |name| task_id(name) }, summary.fetch("callback_sources").map { |row| row.fetch("result").fetch("input_public_id") }
    refute worker_request("b").key?("result_destination")

    receive(telegram_message(3, "/deliver #{task_id("a")} -10:4"))
    receive(telegram_message(4, "/deliver #{task_id("b")} 1:0"))
    receive(telegram_message(5, "/deliver #{task_id("a")} -10:4"))
    assert_equal summary, @state.read.fetch("deliveries").values.find { |row| row["text"] == "Combined A and B" }
    assert_equal "1", worker_request("b").fetch("result_destination").fetch("chat_id")
    @now += 1_001
    drain

    assert_equal ["-10"], sends("Worker a result").map { |row| row.fetch(:chat_id) }
    assert_equal ["1"], sends("Worker b result").map { |row| row.fetch(:chat_id) }
    assert_equal ["1"], sends("Combined A and B").map { |row| row.fetch(:chat_id) }
  end

  def test_single_worker_callback_does_not_become_the_parent_tasks_exported_final
    publish_report(%w[a], "Child synthesis")
    @bridge.turn_rows.fetch("conversation-1").unshift(turn(0, "Parent own final"))
    @bridge.event_rows["conversation-1"] = [
      event(1, "input_accepted", "input_public_id" => "callback-a", "origin" => "child", "run_public_id" => "loop-1"),
      event(2, "input_materialized", "input_public_id" => "callback-a", "turn_public_id" => "turn-1"),
      event(3, "turn_status", "turn_public_id" => "turn-1", "run_public_id" => "summary-loop"),
    ]
    @state.change { |document| document.fetch("requests").fetch("telegram:42:1:input")["input_id"] = task_id("c") }
    receive(telegram_message(3, "/deliver #{task_id("c")} -10:4"))
    drain

    assert_equal ["-10"], sends("Parent own final").map { |row| row.fetch(:chat_id) }
    assert_equal ["1"], sends("Child synthesis").map { |row| row.fetch(:chat_id) }
    refute worker_request("a").key?("result_destination")
  end

  def test_canonical_worker_result_survives_child_active_variant_change_and_restart
    publish_report(%w[a], "Parent report")
    @runtime.tick
    receive(telegram_message(3, "/deliver #{task_id("a")} -10:4"))
    @bridge.turn_rows["child-a"] = [worker_turn("a").merge("variant_public_id" => "manual-edit", "text" => "Later edit")]
    @state = Rho::IngressTelegram::State.new(store: TelegramStateSupport.document(@home))
    @runtime = runtime
    drain

    assert_equal 1, sends("Worker a result").length
    assert_empty sends("Later edit")
  end

  def test_unreadable_worker_discards_its_copy_without_retiring_parent_report
    publish_report(%w[a], "Parent report")
    @runtime.tick
    receive(telegram_message(3, "/deliver #{task_id("a")} -10:4"))
    assert @state.read.fetch("deliveries").values.any? { |row| row["canonical_result"] }
    @worker_results["worker-a-variant"] = Rho::Core::Refused.new("not readable", code: "not_found", status: 404)
    drain

    assert_empty sends("Worker a result")
    assert_equal ["1"], sends("Parent report").map { |row| row.fetch(:chat_id) }
    assert @state.read.fetch("routes").fetch("1:0").fetch("conversations").key?("conversation-1")
    refute @state.read.fetch("deliveries").values.any? { |row| row["canonical_result"] }
  end

  def test_worker_identity_does_not_replace_the_unqualified_main_stop_target
    publish_report(%w[a], "Parent report")
    @runtime.tick
    receive(telegram_message(3, "/stop"))

    assert_equal [["loop-1", "run", "workspace-home"]], @bridge.stop_calls
  end

  def test_stopping_a_worker_preserves_an_already_queued_parent_report
    publish_report(%w[a b], "Combined report")
    @state.change { |document| document["retry_at"] = @now + 1_000 }
    @runtime.tick
    receive(telegram_message(3, "/stop #{task_id("a")}"))
    assert_equal [["worker-a-loop", "run", "workspace-home"]], @bridge.stop_calls
    assert @state.read.fetch("deliveries").values.any? { |row| row["text"] == "Combined report" }
    @now += 1_001
    drain

    assert_equal ["1"], sends("Combined report").map { |row| row.fetch(:chat_id) }
  end

  def test_repeated_parent_history_reads_do_not_reload_registered_worker_variants
    publish_report(%w[a b], "Combined report")
    @state.change { |document| document.fetch("requests").fetch("telegram:42:1:input")["input_id"] = task_id("c") }
    @runtime.tick
    before = @worker_reads.count { |row| row.first == :result }
    receive(telegram_message(3, "/deliver #{task_id("c")} -10:4"))
    receive(telegram_message(4, "/deliver #{task_id("c")} -10:4"))

    assert_equal 2, before
    assert_equal before, @worker_reads.count { |row| row.first == :result }
  end

  def test_future_worker_copy_contains_only_its_own_committed_attachments
    media = { "upload_public_id" => "worker-file", "filename" => "report.txt", "content_type" => "text/plain", "byte_size" => 5 }
    @bridge.define_singleton_method(:turn_media) do |row, workspace_public_id:|
      row["run_public_id"] == "worker-a-loop" ? [media] : []
    end
    @bridge.define_singleton_method(:media_bytes) { |_, **| "hello" }
    @client.define_singleton_method(:upload) { |method, params, **fields| call(method, params.merge(fields)) }
    @bridge.current["children"] = [{ "public_id" => "child-a", "busy" => true }]
    @worker_requests["child-a"] = worker_turn("a", status: "running")
    @runtime.tick
    receive(telegram_message(3, "/deliver #{task_id("a")} -10:4"))
    publish_report(%w[a], "Parent report")
    drain

    uploads = @client.calls.select { |method, _| method == "sendDocument" }
    assert_equal 1, uploads.length
    assert_equal "-10", uploads.first.last.fetch(:chat_id)
    assert_equal "report.txt", uploads.first.last.fetch(:filename)
  end

  def test_parent_report_reply_and_controls_use_its_own_conversation_and_loop
    publish_report(%w[a b], "Combined report")
    drain
    report_message = @state.read.fetch("messages").find { |_key, owner| owner == "report:#{task_id("s")}" }.first.split(":").last.to_i
    receive(telegram_message(3, "/new"))
    receive(telegram_message(4, "Explain the comparison", reply_to: report_message))
    assert_equal "conversation-1", @bridge.inputs.fetch("telegram:42:4:input").fetch(:conversation_id)
    receive(telegram_message(5, "/steer add details", reply_to: report_message))
    steering = @bridge.inputs.fetch("telegram:42:5:input")
    assert_equal "conversation-1", steering.fetch(:conversation_id)
    assert_equal "summary-loop", steering.fetch(:expected_steering_run_public_id)
    receive(telegram_message(6, "/stop #{task_id("s")}"))
    assert_equal [["summary-loop", "run", "workspace-home"]], @bridge.stop_calls
    receive(telegram_message(7, "/status #{task_id("s")}"))
    assert_includes @worker_reads, [:execution, "summary-loop", "workspace-home"]
    assert_equal "worker-a-loop", worker_request("a").fetch("run_id")
    assert_equal "worker-b-loop", worker_request("b").fetch("run_id")
  end

  def test_parent_report_controls_retain_the_original_loop_after_regeneration
    publish_report(%w[a b], "Combined report")
    drain
    report_message = @state.read.fetch("messages").find { |_key, owner| owner == "report:#{task_id("s")}" }.first.split(":").last.to_i
    @bridge.turn_rows.fetch("conversation-1").first.merge!("variant_public_id" => "regenerated-variant", "run_public_id" => "regenerated-loop")
    @bridge.event_rows.fetch("conversation-1") << event(4, "turn_status", "turn_public_id" => "turn-1", "run_public_id" => "regenerated-loop")
    @bridge.current["sequence"] += 1
    @now += 60
    @runtime.tick
    @state.change { |document| document.fetch("requests").fetch("telegram:42:1:input")["input_id"] = task_id("c") }
    receive(telegram_message(3, "/deliver #{task_id("c")} -10:4"))
    receive(telegram_message(4, "/stop", reply_to: report_message))
    receive(telegram_message(5, "/status #{task_id("s")}"))
    receive(telegram_message(6, "/steer add details", reply_to: report_message))

    assert_equal [["summary-loop", "run", "workspace-home"]], @bridge.stop_calls
    assert_includes @worker_reads, [:execution, "summary-loop", "workspace-home"]
    refute_includes @worker_reads, [:execution, "regenerated-loop", "workspace-home"]
    assert_equal "summary-loop", @bridge.inputs.fetch("telegram:42:6:input").fetch(:expected_steering_run_public_id)
  end

  def test_history_only_report_never_guesses_its_execution_from_an_active_variant
    publish_report(%w[a], "Parent report")
    @bridge.event_rows["conversation-1"] = []
    @bridge.turn_rows.fetch("conversation-1").first["run_public_id"] = "regenerated-loop"
    drain
    report_message = @state.read.fetch("messages").find { |_key, owner| owner == "report:#{task_id("s")}" }.first.split(":").last.to_i
    @bridge.event_rows["conversation-1"] << event(4, "turn_status", "turn_public_id" => "turn-1", "run_public_id" => "regenerated-loop")
    @bridge.current["sequence"] += 1
    @now += 60
    @runtime.tick
    receive(telegram_message(3, "/stop", reply_to: report_message))
    receive(telegram_message(4, "/steer add details", reply_to: report_message))
    receive(telegram_message(5, "/status #{task_id("s")}"))

    assert_nil @state.read.fetch("work").fetch(task_id("s"))["run_id"]
    assert_includes feedback(3), "No known execution"
    assert_includes feedback(4), "No known execution"
    assert_includes feedback(5), "Execution not yet linked"
    assert_empty @bridge.stop_calls
    assert_equal 1, @bridge.inputs.length
    refute @worker_reads.any? { |row| row.first == :execution }
    receive(telegram_message(6, "Explain this report", reply_to: report_message))
    assert_equal "conversation-1", @bridge.inputs.fetch("telegram:42:6:input").fetch(:conversation_id)
    receive(telegram_message(7, "/stop #{task_id("s")}"))
    assert_includes feedback(7), "original execution is not linked"
    assert_empty @bridge.queue_writes
  end

  def test_busy_worker_does_not_bind_original_input_to_a_regenerated_active_loop
    @bridge.current["children"] = [{ "public_id" => "child-a", "busy" => true }]
    @worker_requests["child-a"] = worker_turn("a", status: "running").merge("run_public_id" => "regenerated-loop")
    @runtime.tick
    assert_nil worker_request("a")["run_id"]
    receive(telegram_message(3, "/stop #{task_id("a")}"))
    receive(telegram_message(4, "/steer #{task_id("a")} add details"))
    assert_includes feedback(3), "original execution is not linked"
    assert_includes feedback(4), "no known execution to steer"
    assert_empty @bridge.stop_calls
    assert_empty @bridge.queue_writes
    publish_report(%w[a], "Parent report")
    @now += 60
    @runtime.tick
    receive(telegram_message(5, "/stop #{task_id("a")}"))

    assert_equal [["worker-a-loop", "run", "workspace-home"]], @bridge.stop_calls
    assert_equal "worker-a-loop", worker_request("a").fetch("run_id")
  end

  def test_report_with_one_requester_preserves_private_route_ownership_for_a_new_worker_after_restart
    receive(telegram_message(3, "A second independent request"))
    publish_report(%w[a b], "Combined report", position: 2)
    @bridge.turn_rows.fetch("conversation-1").last.fetch("callback_sources").last["sender_run_public_id"] = "loop-2"
    @runtime.tick
    @runtime = runtime
    @bridge.current["children"] = [{ "public_id" => "child-c", "busy" => true }]
    @worker_requests["child-c"] = worker_turn("c", status: "running").merge("sender_run_public_id" => "summary-loop")
    @bridge.current["sequence"] += 1
    @now += 60
    @runtime.tick

    request = worker_request("c")
    assert_equal "1", request.fetch("owner_id")
    assert_equal "1:0", request.fetch("route_key")
    assert_nil request["source_request_id"]
    assert_equal "conversation-1", request.fetch("conversation_id")
    @worker_results["worker-c-variant"] = worker_turn("c")
    @bridge.turn_rows.fetch("conversation-1") << turn(3, "Next report").merge("input_public_id" => task_id("t"),
      "run_public_id" => "next-summary-loop", "callback_sources" => [source("c").merge("sender_run_public_id" => "summary-loop")])
    @bridge.current["sequence"] += 1
    @now += 60
    @runtime.tick
    assert_equal "worker-c-variant", worker_request("c").fetch("canonical_result").fetch("variant_public_id")
  end

  def test_report_with_different_requesters_does_not_grant_a_child_or_reply_owner
    publish_report(%w[a b], "Incompatible report")
    @bridge.turn_rows.fetch("conversation-1").first.fetch("callback_sources").last.fetch("result")["requester_speaker_public_id"] = "speaker-2"
    @runtime.tick
    report = @state.read.fetch("work").fetch(task_id("s"))
    refute report.key?("owner_id")
    @bridge.current["children"] = [{ "public_id" => "child-c", "busy" => true }]
    @worker_requests["child-c"] = worker_turn("c", status: "running").merge("sender_run_public_id" => "summary-loop")
    @bridge.current["sequence"] += 1
    @now += 60
    @runtime.tick

    refute @state.read.fetch("requests").values.any? { |row| row["input_id"] == task_id("c") }
  end

  def test_worker_export_reply_remains_explicit_control_only
    publish_report(%w[a], "Parent report")
    @runtime.tick
    receive(telegram_message(3, "/deliver #{task_id("a")} -10:4"))
    drain
    export = @state.read.fetch("deliveries").values.find { |row| row["canonical_result"] }
    receive(telegram_message(4, "Continue privately", chat: -10, topic: 4, reply_to: export.fetch("message_ids").first))

    assert_includes feedback(4), "/steer #{task_id("a")}"
    assert_equal 1, @bridge.inputs.length
  end

  def test_group_report_reply_preserves_the_original_requester
    update = telegram_message(3, "@rho_bot compare these reports", user: 2, chat: -10, topic: 4,
      entities: [{ "type" => "mention", "offset" => 0, "length" => 8 }])
    receive(update)
    @worker_results["worker-a-variant"] = worker_turn("a")
    callback = source("a").merge("sender_run_public_id" => "loop-2")
    callback.fetch("result")["requester_speaker_public_id"] = "speaker-2"
    @bridge.turn_rows["conversation-3"] = [turn(1, "Group report", conversation_id: "conversation-3").merge(
      "input_public_id" => task_id("g"), "run_public_id" => "group-summary-loop", "callback_sources" => [callback])]
    drain
    report_message = @state.read.fetch("messages").find { |_key, owner| owner == "report:#{task_id("g")}" }.first.split(":").last.to_i
    @state.change { |document| document.fetch("access").fetch("allowed_users") << "3" }
    receive(telegram_message(4, "Read private notes", user: 3, chat: -10, topic: 4, reply_to: report_message))
    assert_includes feedback(4), "Only this task's requester"
    assert_equal 2, @bridge.inputs.length
    receive(telegram_message(5, "Explain the comparison", user: 2, chat: -10, topic: 4, reply_to: report_message))
    assert_equal "conversation-3", @bridge.inputs.fetch("telegram:42:5:input").fetch(:conversation_id)
  end

  def test_inherited_report_does_not_register_or_rebind_its_original_task_receipts
    publish_report(%w[a], "Parent report")
    original = @bridge.turn_rows.fetch("conversation-1").first
    @bridge.turn_rows["conversation-1"] = []
    @bridge.event_rows["conversation-1"] = []
    @bridge.turn_rows["conversation-2"] = [original.merge("inherited" => true)]
    @runtime.tick
    refute @state.read.fetch("requests").values.any? { |row| row["input_id"] == task_id("a") }
    refute @state.read.fetch("work").key?(task_id("s"))
    @bridge.turn_rows["conversation-1"] = [original]
    @bridge.current["sequence"] += 1
    @now += 60
    @runtime.tick

    assert_equal "conversation-1", worker_request("a").fetch("conversation_id")
    assert_equal "conversation-1", @state.read.fetch("work").fetch(task_id("s")).fetch("conversation_id")
    assert_equal 1, @worker_reads.count { |row| row.first == :result }
  end

  private

    def task_id(name) = "019a1234-5678-7000-8000-#{name.ord.to_s.rjust(12, "0")}"
    def worker_turn(name, status: "completed")
      { "public_id" => "worker-#{name}-turn", "input_public_id" => task_id(name), "position" => 0,
        "conversation_public_id" => "child-#{name}", "variant_public_id" => "worker-#{name}-variant",
        "run_public_id" => "worker-#{name}-loop", "kind" => "direct_reply", "status" => status,
        "sender_conversation_public_id" => "conversation-1", "sender_run_public_id" => "loop-1", "sender_task_key" => "r1.#{name}",
        "text" => "Worker #{name} result" }
    end
    def source(name)
      { "input_public_id" => "callback-#{name}", "origin" => "child", "sender_conversation_public_id" => "child-#{name}",
        "sender_run_public_id" => "loop-1", "sender_task_key" => "r1.#{name}", "result" => {
          "conversation_public_id" => "child-#{name}", "input_public_id" => task_id(name), "turn_public_id" => "worker-#{name}-turn",
          "variant_public_id" => "worker-#{name}-variant", "requester_speaker_public_id" => "speaker-1",
        } }
    end
    def publish_report(names, text, position: 1)
      names.each { |name| @worker_results["worker-#{name}-variant"] = worker_turn(name) }
      @bridge.turn_rows["conversation-1"] = [turn(position, text).merge("input_public_id" => task_id("s"), "run_public_id" => "summary-loop",
        "callback_sources" => names.map { |name| source(name) })]
      @bridge.event_rows["conversation-1"] = [
        event(1, "input_accepted", "input_public_id" => task_id("s"), "origin" => "child", "run_public_id" => "loop-1"),
        event(2, "input_materialized", "input_public_id" => task_id("s"), "turn_public_id" => "turn-#{position}"),
        event(3, "turn_status", "turn_public_id" => "turn-#{position}", "run_public_id" => "summary-loop"),
      ]
      @bridge.current["sequence"] += 1
    end
    def worker_request(name) = @state.read.fetch("requests").values.find { |row| row["input_id"] == task_id(name) } || flunk("No receipt for worker #{name}")
    def feedback(id) = @state.read.fetch("deliveries").fetch("control:#{id}").fetch("text")
    def event(sequence, type, payload) = { "sequence" => sequence, "cursor" => sequence.to_s, "type" => type, "payload" => payload }
    def drain
      8.times do
        @now += 60
        @runtime.tick
      end
    end
    def sends(text) = @client.calls.filter_map { |method, fields| fields if method == "sendMessage" && fields.fetch(:text, "").include?(text) }
end
