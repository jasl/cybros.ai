require "test_helper"

# The model's prompt grammar belongs to sending. A lowered role must never
# become the source a regeneration or a later conversation turn reads.
class ModelRequests::PromptFormatIsolationTest < ActiveJob::TestCase
  include InvocationHarness
  include RunLaneTestHelper

  ADAPTED_MODEL = "prompt-format-adapted".freeze
  ORDINARY_MODEL = "prompt-format-ordinary".freeze
  INSTRUCTIONS = "Keep the caller's instructions.\n保留原文。".freeze

  setup do
    @account = accounts(:cybros)
    @human = users(:member)
    @agent = users(:agent)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: @human,
      answering_user: @agent)
    current = ModelCatalog.current
    model = {
      "api_format" => "openai_compatible_chat",
      "pricing" => current.models.fetch("dev/mock-text").fetch("pricing"),
    }
    @catalog = current.with(models: current.models.merge(
      "dev/#{ADAPTED_MODEL}" => model.merge("wire_options" => { "prompt_format" => "qwen3_5" }),
      "dev/#{ORDINARY_MODEL}" => model
    ))
  end

  test "raw regeneration on another model restores canonical roles and instructions after adapted sends" do
    ModelCatalog.stub(:current, @catalog) do
      entries = [
        entry("system", "Root policy."),
        entry("developer", "Leading guidance."),
        entry("user", "Original question."),
        entry("assistant", "Earlier answer."),
        entry("system", "Later policy.\n第二行。"),
        entry("developer", "Later guidance."),
        entry("user", "Follow-up question."),
      ]
      turn = reply(entries: entries, context_mode: "raw", instructions: INSTRUCTIONS)
      original = turn.active_variant
      before = stored_input(original)
      assert_equal entries, before.fetch(:prompt)
      assert_equal entries, before.fetch(:request)

      adapted = wire(original.model_invocation)
      assert_equal [
        ["system", [INSTRUCTIONS, "Root policy.", "Leading guidance."].join("\n\n")],
        ["user", "Original question."],
        ["assistant", "Earlier answer."],
        ["user", "Later policy.\n第二行。"],
        ["user", "Later guidance."],
        ["user", "Follow-up question."],
      ], wire_pairs(adapted)
      assert_equal adapted.fetch("messages").to_json,
        wire(original.model_invocation.reload).fetch("messages").to_json,
        "rebuilding the same invocation must preserve the adapted prefix byte for byte"
      assert_equal before, stored_input(original)

      settle(turn, "The first answer.")
      regenerated = Conversations::Turns::Regenerate.call(Conversations::Turns::Regenerate::Command.new(
        conversation: @conversation.reload, turn_public_id: turn.public_id, acting_user: @human,
        provider_id: "dev", model_ref: ORDINARY_MODEL, reasoning_effort: nil, request_options: nil
      ))
      assert_predicate regenerated, :accepted?, regenerated.outcome.inspect
      sibling = regenerated.value
      assert_equal ORDINARY_MODEL, sibling.model_ref
      assert_equal entries, stored_input(sibling).fetch(:prompt)
      assert_equal entries, stored_input(sibling).fetch(:request)
      assert_equal INSTRUCTIONS, sibling.model_invocation.request_options.fetch("instructions")
      assert_equal [["system", INSTRUCTIONS]] + entry_pairs(entries), wire_pairs(wire(sibling.model_invocation)),
        "the other model receives every original role, including both later instruction messages"
      assert_equal before, stored_input(original), "neither sending nor regeneration rewrites its source"
    end
  end

  test "a later turn on another model replays the original preface after an adapted assembly" do
    ModelCatalog.stub(:current, @catalog) do
      written = PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt",
        content: "Stable system prompt.")
      assert_predicate written, :written?
      post(entries: [{ "text" => "Earlier context." }], kind: "message")
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      turn = reply(entries: [{ "text" => "First question." }], context_options: {
        "inline" => [{ "role" => "developer", "position" => "lead", "text" => "Keep this preface." }],
      })
      original = turn.active_variant
      before = stored_input(original)
      expected = [
        ["system", "Stable system prompt."], ["user", "Earlier context."],
        ["developer", "Keep this preface."], ["user", "First question."],
      ]
      assert_equal expected, entry_pairs(before.fetch(:request))
      assert_equal [["developer", "Keep this preface."]], entry_pairs(before.fetch(:preface))
      assert_equal expected.map { |role, text| [role == "developer" ? "user" : role, text] },
        wire_pairs(wire(original.model_invocation))
      assert_equal before, stored_input(original)

      settle(turn, "The first answer.")
      second = reply(entries: [{ "text" => "Next question." }], model_ref: ORDINARY_MODEL)
      current = second.active_variant
      expected += [["assistant", "The first answer."], ["user", "Next question."]]
      assert_equal ORDINARY_MODEL, current.model_ref
      assert_equal expected, entry_pairs(stored_input(current).fetch(:request))
      assert_equal expected, wire_pairs(wire(current.model_invocation)),
        "the later turn reads the sealed developer preface, not the first model's user-role projection"
      assert_equal before, stored_input(original)
      assert_equal "Stable system prompt.", @agent.prompt_documents.find_by!(slot: "system_prompt").content
    end
  end

  test "a tool continuation replays the canonical prior request after the first round was adapted" do
    ModelCatalog.stub(:current, @catalog) do
      declare_tools!(@agent)
      written = PromptDocuments::Write.call(anchor: { user: @agent }, slot: "system_prompt",
        content: "Stable system prompt.")
      assert_predicate written, :written?
      post(entries: [{ "text" => "Earlier context." }], kind: "message")
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      post(entries: [{ "text" => "Read the file." }], context_options: {
        "inline" => [{ "role" => "developer", "position" => "lead", "text" => "Keep this preface." }],
      })
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      turn = @conversation.conversation_turns.order(:position).last
      agent_run = turn.active_variant.agent_run
      assert_not_nil agent_run
      schedule_loop!(agent_run)
      first_node = loop_node(agent_run, "r1")
      first = round_request_entries(first_node)
      assert_equal %w[system user developer user], first.map { |item| item.fetch("role") }
      first_wire = wire(ModelInvocation.find(first_node.selected_model_invocation_id)).fetch("messages")
      assert_equal %w[system user user user], first_wire.map { |item| item.fetch("role") }

      applied = apply_via(loop_attempt(agent_run), chat_response("I will read it.", tool_calls: [{
        "id" => "call_read", "type" => "function",
        "function" => { "name" => "read_file", "arguments" => '{"path":"notes.txt"}' },
      }]))
      assert_predicate applied, :applied?, applied.outcome.inspect
      AgentRuns::ConvergeTerminalSteps.call
      clear_enqueued_jobs
      schedule_loop!(agent_run)
      tool = agent_run.agent_run_tasks.find_by!(tool_call_id: "call_read")
      settled = AgentRuns::Parks::Settle.call(node: tool, trusted: true,
        content: "Contents of notes.", outcome: "completed")
      assert_predicate settled, :applied?
      schedule_loop!(agent_run)

      second_node = loop_node(agent_run, "r2")
      second = round_request_entries(second_node)
      assert_equal first, second.first(first.length),
        "InputComposition must replay the original sealed prefix, including its developer role"
      assert_includes second.drop(first.length).map { |item| item["type"] }, "tool_result_item"
      second_wire = wire(ModelInvocation.find(second_node.selected_model_invocation_id)).fetch("messages")
      assert_equal first_wire.to_json, second_wire.first(first_wire.length).to_json,
        "the adapted wire prefix is stable across the tool fan without becoming the stored prefix"
      assert_equal first, round_request_entries(first_node)
      assert_equal second, round_request_entries(second_node)
      assert_equal [["developer", "Keep this preface."]],
        entry_pairs(turn.active_variant.content_bodies.find_by!(role: "preface").entry_payloads)
    end
  end

  private

    def entry(role, text)
      { "role" => role, "parts" => [{ "type" => "text", "text" => text }] }
    end

    def reply(**arguments)
      post(**arguments)
      assert_equal 1, Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      turn = @conversation.conversation_turns.order(:position).last
      assert_equal "inference", turn.active_variant.source
      turn
    end

    def post(entries:, kind: "direct_reply", model_ref: ADAPTED_MODEL, context_mode: nil,
             context_options: nil, instructions: nil)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.new(
        host: @conversation.reload, acting_user: @agent, kind: kind, role: "user", entries: entries,
        visible_in_context: true, delivery_mode: "queue", context_mode: context_mode,
        context_options: context_options, expected_context_revision: nil, expected_tail_turn_public_id: nil,
        provider_id: ("dev" if kind == "direct_reply"), model_ref: (model_ref if kind == "direct_reply"),
        reasoning_effort: nil, request_options: nil, instructions: instructions
      ))
      assert_predicate result, :accepted?, result.outcome.inspect
      result.value
    end

    def stored_input(variant)
      invocation = variant.model_invocation.reload
      {
        prompt: variant.content_bodies.find_by!(role: "prompt").entry_payloads,
        preface: variant.content_bodies.find_by(role: "preface")&.entry_payloads,
        request: invocation.content_bodies.find_by!(role: "request").entry_payloads,
        options: invocation.request_options,
      }
    end

    def wire(invocation)
      result = ModelRequests::Build.call(invocation: invocation,
        profile: DevModelLane.profile_for_invocation(invocation),
        base_url: ModelCatalog.provider_base_url(invocation.provider_id), host: "solid_queue")
      assert_predicate result, :built?, result.refusal.inspect
      JSON.parse(result.request.payload)
    end

    def entry_pairs(entries)
      entries.map { |item| [item.fetch("role"), item.fetch("parts").map { |part| part.fetch("text") }.join("\n\n")] }
    end

    def wire_pairs(payload)
      payload.fetch("messages").map do |message|
        text = case message.fetch("content")
        in String => content then content
        in Array => parts then parts.map { |part| part.fetch("text") }.join
        else raise "unexpected text message content"
        end
        [message.fetch("role"), text]
      end
    end

    def settle(turn, text)
      invocation = turn.active_variant.model_invocation
      admitted = ModelInvocations::AdmitQueuedWork.call.admitted.find do |candidate|
        candidate.attempt.model_invocation_id == invocation.id
      end
      assert_not_nil admitted, "the accepted reply should be admitted"
      clear_enqueued_jobs
      applied = apply_via(admitted.attempt, chat_response(text))
      assert_predicate applied, :applied?, applied.outcome.inspect
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
    end

    def chat_response(text, tool_calls: [])
      delta = { "role" => "assistant", "content" => text }
      delta["tool_calls"] = tool_calls.each_with_index.map { |call, index| call.merge("index" => index) } if tool_calls.any?
      chunks = [
        { "id" => "chat-isolation", "object" => "chat.completion.chunk",
          "choices" => [{ "index" => 0, "delta" => delta }] },
        { "id" => "chat-isolation", "object" => "chat.completion.chunk",
          "choices" => [{ "index" => 0, "delta" => {}, "finish_reason" => tool_calls.any? ? "tool_calls" : "stop" }],
          "usage" => { "prompt_tokens" => 2, "completion_tokens" => 3, "total_tokens" => 5 } },
      ]
      { sse: chunks.map { |chunk| "data: #{JSON.generate(chunk)}\n\n" } + ["data: [DONE]\n\n"],
        status: 200, headers: { "content-type" => "text/event-stream" } }
    end
end
