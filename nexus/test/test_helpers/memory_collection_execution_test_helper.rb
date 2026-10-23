module MemoryCollectionExecutionTestHelper
  extend ActiveSupport::Concern

  include InvocationHarness
  include RunLaneTestHelper

  included do
    setup do
      @account = accounts(:cybros)
      @human = users(:member)
      @agent = users(:agent)
      @workspace = workspaces(:shared)
      DevModelLane.ensure_enabled!(@account)
      @conversation = Conversation.create!(workspace: @workspace, creating_user: @human, answering_user: @agent)
      [@human, @agent, @workspace, @conversation].each { |owner| MemoryCollection.default_for(owner) }
      declare_tools!(@agent, tools: Nexus::ToolRegistry.wire_names_in("nexus.memory").map { |name| Nexus::ToolRegistry.function_definition(name) })
    end
  end

  private

    def configuration(collection, access: "read_write", name: "notes")
      { "bindings" => [{ "name" => name, "access" => access, "source" => { "collection_public_id" => collection.public_id } }] }
    end

    def bind(collection, access: "read_write")
      result = Conversations::SetMemoryContext.call(conversation: @conversation, acting_user: @human,
        memory_context: configuration(collection, access: access))
      assert_predicate result, :accepted?, result.outcome.to_s
    end

    def write_collection(collection, content, name: "fact.md", description: nil)
      collection.with_mutation do
        anchor = Scopes::Anchor::Result.new(collection: collection, scope: collection.natural_scope.to_s, name: name, refusal: nil)
        result = MemoryDocuments::Write.call(anchor: anchor, content: content, expected: nil, description: description)
        assert_predicate result, :written?, result.outcome.to_s
        result.document
      end
    end

    def open_turn
      turn, run = materialize_loop_reply!(@conversation, agent: @human, text: "use memory")
      schedule_loop!(run)
      [turn, run]
    end

    def seed_text(run)
      run.tasks.find_by!(node_key: "r1").content_bodies.find_by!(role: "input")
        .content_body_entries.map { |entry| entry.content_fragment.payload.to_json }.join
    end

    def memory_call(run, name, arguments, execute: true)
      id = SecureRandom.hex(8)
      run_loop_round!(run, sse_success("using memory", tool_calls: [
        { id: id, name: name, arguments: arguments.to_json },
      ]))
      call = run.tasks.find_by!(tool_call_id: id)
      Runs::MemoryJob.perform_now(call.id) if execute && call.status == "running"
      call.reload
    end

    def settle(turn, run)
      Runs::Transition.run(run, status: "completed", completed_at: Time.current)
      Conversations::Turns::Converge.call
      assert_equal "completed", turn.reload.status
    end

    def deliver_result(run)
      result = Conversations::Inputs::Create.call(Conversations::Inputs::Create::Command.kernel(
        host: @conversation, acting_user: @human, entries: [{ "text" => "background result" }],
        origin: "task_result", sender_conversation_public_id: @conversation.public_id,
        run_public_id: run.public_id, task_key: "background", kind: "direct_reply",
        provider_id: "dev", model_ref: "mock-text", answering_user_public_id: @agent.public_id))
      assert_predicate result, :accepted?, result.outcome.to_s
      receipt = result.value
      Conversations::Inputs::ApplyNext.drain(conversation_id: @conversation.id)
      @conversation.turns.find_by!(input_public_id: receipt.public_id).active_variant.run
    end
end
