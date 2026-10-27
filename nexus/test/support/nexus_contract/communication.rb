module Nexus
  module Contract
    class << self
      private

        # Shared wire examples use the ordinary presenters. Producer tests drive
        # the matching public commands; consumers read every case through SDK APIs.
        def communication
          source = Conversation.new(id: 1, public_id: "01900000-0000-7000-8000-000000000070")
          target = Conversation.new(id: 2, public_id: "01900000-0000-7000-8000-000000000072")
          workspace = Workspace.new(public_id: "019f0000-0000-7000-8000-000000000101")
          link = ConversationLink.new(public_id: "01900000-0000-7000-8000-000000000180",
            workspace:, first_conversation: source, second_conversation: target,
            first_agent: contract_agent, second_agent: contract_agent, created_at: Time.utc(2026, 10, 27))
          active = stringify_keys(Conversations::LinkProjection.call(link, conversation: source))
          link.closed_at = Time.utc(2026, 10, 27, 0, 1)
          link.close_reason = "explicit"
          closed = stringify_keys(Conversations::LinkProjection.call(link, conversation: source))
          queued = input_fixture(communication_kind: "message", conversation_link: link)
          consumed = conversation_stamped_turn_fixture(communication_kind: "message", conversation_link_public_id: link.public_id)
          input_id = queued.fetch("public_id")
          consumed.merge!("kind" => "direct_reply", "input_public_id" => input_id,
            "sender_conversation_public_id" => source.public_id)
          identity = { "conversation_public_id" => target.public_id, "input_public_id" => input_id,
            "turn_public_id" => consumed.fetch("public_id"), "variant_public_id" => "01900000-0000-7000-8000-000000000091",
            "run_public_id" => "01900000-0000-7000-8000-0000000000b2", "status" => "completed" }
          receipt = { "input_public_id" => input_id, "conversation_public_id" => target.public_id,
            "answering_user_public_id" => contract_agent.public_id, "state" => "pending", "delivery_mode" => "queue",
            "deliver_at" => nil, "completion" => { "run_public_id" => "01900000-0000-7000-8000-0000000000b1", "task_key" => "r1t0-delegation" } }
          callback = identity.merge("requester_speaker_public_id" => "01900000-0000-7000-8000-0000000000a1")
          cases = [
            communication_case("link_accepted", "link_create", { "link" => active }, status: 201),
            communication_case("link_replayed", "link_create", { "link" => active }, status: 201,
              headers: { "Idempotency-Replayed" => "true" }),
            communication_case("link_active_pair", "link_create", { "link" => active }),
            communication_case("link_mismatch", "link_create", { "error" => {
              "code" => "idempotency_envelope_mismatch", "message" => "The key already names another request." } }, status: 409),
            communication_case("link_read", "link_read", { "link" => active }),
            communication_case("link_list", "link_list", { "links" => [active], "next_after" => "opaque-link-cursor" }),
            communication_case("link_closed", "link_close", { "link" => closed }),
            communication_case("message_queued", "inputs", { "inputs" => [queued], "input_queue" => { "limit" => 32, "held" => 1 } }),
            communication_case("message_consumed", "turn", { "turn" => consumed }),
            communication_case("message_discarded", "events", { "events" => [event_fixture.merge("type" => "input_deleted",
              "payload" => { "input_public_id" => input_id, "queue_position" => 0 })],
              "pagination" => { "next_after" => nil, "watermark" => 7 } }),
            communication_case("strict_update_refused", "task", communication_task("send", "steering_target_changed", is_error: true)),
            communication_case("request_accepted", "task", communication_task("request", JSON.generate(receipt), structured: receipt)),
          ]
          %w[completed failed canceled].each do |status|
            result = identity.merge("status" => status)
            cases << communication_case("request_#{status}", "task", communication_task(nil, "Original result: #{status}",
              structured: result, status: status == "completed" ? "completed" : "failed", key: "r1t0-delegation"))
          end
          canceled = identity.merge("turn_public_id" => nil, "variant_public_id" => nil, "run_public_id" => nil, "status" => "canceled")
          cases << communication_case("request_canceled_before_materialization", "task",
            communication_task(nil, "Canceled before starting", structured: canceled, status: "canceled", key: "r1t0-delegation"))
          cases << communication_case("await_timeout", "task", communication_task(nil, "The finite wait expired",
            status: "timed_out", key: "r1t0-await", kind: "await_task"))
          cases << communication_case("result_after_timeout", "task", communication_task(nil, "The original request completed later",
            structured: identity, key: "r1t0-delegation"))
          cases << communication_case("callback_result", "inputs", { "inputs" => [input_fixture(callback_result: callback)],
            "input_queue" => { "limit" => 32, "held" => 1 } })
          fallback = input_fixture(communication_kind: "message", conversation_link: link,
            expected_steering_run_public_id: identity.fetch("run_public_id"), requested_delivery_mode: "steer_now",
            on_target_end: "queue", fallback_reason: "steering_target_changed")
          fallback["state"], fallback["delivery_mode"] = "pending", "queue"
          cases << communication_case("strict_update_queued", "inputs", { "inputs" => [fallback],
            "input_queue" => { "limit" => 32, "held" => 1 } })
          {
            "link_request" => { "agent_public_id" => contract_agent.public_id,
              "peer_conversation_public_id" => target.public_id, "peer_agent_public_id" => contract_agent.public_id },
            "link_public_id" => link.public_id,
            "cases" => cases,
          }
        end

        def communication_case(name, operation, body, status: 200, headers: {})
          { "name" => name, "operation" => operation, "status" => status, "headers" => headers, "body" => body }
        end

        def communication_task(tool, text, structured: nil, status: "completed", is_error: false, key: "r1t0", kind: nil)
          node = CONTRACT_NODE_TYPE.new(id: 21, node_key: key, task_kind: kind || (tool ? "tool_task" : "delegation_task"),
            status:, on_failure: "absorb", transcript_visibility: "visible", tool_name: tool,
            output_summary: { "is_error" => is_error }, output_preview: text,
            created_at: Time.utc(2026, 10, 27), completed_at: Time.utc(2026, 10, 27, 0, 1))
          payloads = [text_payload(text)]
          payloads << structured_payload(structured) if structured
          detail_of(node, output: text, payloads:)
        end
    end
  end
end
