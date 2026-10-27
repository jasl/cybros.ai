require_relative "turn_test"

class TurnTest
  def test_rho_bidirectional_messages_keep_the_original_request_result
    boot_rho!
    source_id, = rho_open("!mock -- requester ready")
    target_id, = rho_open("!mock -- worker ready")
    source = steward_conversation(source_id)
    target = steward_conversation(target_id)
    await_settled_reply(source)
    await_settled_reply(target)
    link = source.links.create(agent_public_id: source.fetch.answering_user_public_id,
      peer_conversation_public_id: target_id, peer_agent_public_id: target.fetch.answering_user_public_id,
      idempotency_key: SecureRandom.uuid)
    answer = CGI.escape(JSON.generate(link_public_id: link.public_id, message: "!mock -- criterion received"))
    question = CGI.escape(JSON.generate(link_public_id: link.public_id,
      message: "!mock tool_call=send:#{answer} -- criterion sent"))
    hold = CGI.escape(JSON.generate(prompt: "Finish the original review?"))
    request = CGI.escape(JSON.generate(to: target_id, lifetime: "conversation", wait: false,
      prompt: "!mock tool_call=send:#{question}&ask:#{hold} -- original review result"))
    accepted = @daemon.control(:post, "/say", body: { public_id: source_id, delivery_mode: "queue",
      text: "!mock tool_call=request:#{request} -- review started", idempotency_key: SecureRandom.uuid })
    source_run = accepted.fetch("run").fetch("public_id")
    context = rho_loops.run(source_run)
    launch = await("rho accepting request through its declared tools") do
      row = context.fetch
      flunk "request failed: #{row.failure_reason}" if row.status == "failed"
      row.tasks.find { |task| task.tool_name == "request" && task.status == "completed" }
    end
    receipt = context.task(launch.key).structured_content
    refute_nil receipt, context.task(launch.key).output
    original = await("the request's original materialization") { target.inputs.materialization(receipt.fetch("input_public_id")) }
    worker = rho_loops.run(original.run_public_id)
    ask = await("the original worker waiting for its question") do
      worker.fetch.tasks.find { |task| task.kind == "await_task" && task.status == "awaiting_input" }
    end
    await("the requester answering through the same link") do
      target.inputs.list.items.find { |input| input.text == "!mock -- criterion received" }
    end
    worker.tasks_context(ask.key).resolve(content: "Finish")
    completion = receipt.fetch("completion")
    result = await("the original completion result") do
      detail = rho_loops.run(completion.fetch("run_public_id")).task(completion.fetch("task_key"))
      detail if detail.task.status == "completed"
    end
    assert_equal original.turn_public_id, result.structured_content.fetch("turn_public_id")
    assert_equal original.variant_public_id, result.structured_content.fetch("variant_public_id")
    assert_equal original.run_public_id, result.structured_content.fetch("run_public_id")
    await("the later worker message completing independently") do
      target.turns.list.items.find { |turn| turn.communication_kind == "message" && turn.status == "completed" }
    end
    recovered = target.input_execution(receipt.fetch("input_public_id")).recover
    assert_equal original.run_public_id, recovered.execution.run_public_id
    assert_includes recovered.content, "original review result"
    row = await("rho retaining the original result source") do
      @daemon.control(:get, "/followers").fetch("followers").find do |follower|
        follower["public_id"] == source_id && follower.fetch("delivered_results").any? { |mail| mail["run_public_id"] == source_run && mail["origin"] == "child" }
      end
    end
    mail = row.fetch("delivered_results").find { |entry| entry["run_public_id"] == source_run && entry["origin"] == "child" }
    turns = @daemon.control(:get, "/conversations/turns?#{URI.encode_www_form(public_id: target_id)}").fetch("turns")
    request_turn = turns.find { |turn| turn["public_id"] == original.turn_public_id }
    assert_equal "request", request_turn.fetch("communication_kind")
    assert turns.any? { |turn| turn["communication_kind"] == "message" }
    @daemon.stop
    @daemon.start
    @daemon.await("rho restoring its adopted workspace") { @daemon.status.dig("workspace", "state") == "adopted" }
    query = URI.encode_www_form(public_id: completion.fetch("run_public_id"), task_key: completion.fetch("task_key"))
    restored = @daemon.control(:get, "/runs/task?#{query}").fetch("task").fetch("structured_content")
    assert_equal receipt.fetch("input_public_id"), restored.fetch("input_public_id")
    assert_equal original.run_public_id, restored.fetch("run_public_id")
    assert_equal source_run, mail.fetch("run_public_id")
    links = @daemon.control(:get, "/conversations/links?#{URI.encode_www_form(public_id: source_id)}")
    assert_equal [link.public_id], links.fetch("links").map { |item| item.fetch("public_id") }
    closed = @daemon.control(:post, "/conversations/links/close",
      body: { public_id: source_id, link_public_id: link.public_id })
    assert_equal "closed", closed.fetch("link").fetch("state")
    assert_equal "completed", rho_loops.run(completion.fetch("run_public_id")).task(completion.fetch("task_key")).task.status
  end
end
