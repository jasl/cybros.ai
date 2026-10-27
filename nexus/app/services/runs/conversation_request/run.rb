module Runs
  module ConversationRequest
    # Existing-conversation dispatch uses the same Input and completion owners
    # as spawn. The accepted Input and launch result commit together.
    class Run
      class Refused < StandardError; end

      def self.call(node:) = new(node).call

      def initialize(node)
        @node, @run, @input = node, node.run, node.tool_input
      end

      def call
        return :not_running unless @node.status == "running"
        return :not_mutable unless @run.graph_mutable?
        raise Refused, "request needs a conversation" if @run.standalone?
        raise Refused, "prompt is empty" if @input["prompt"].to_s.strip.empty?
        raise Refused, KernelTool::INVALID_WAIT unless KernelTool.valid_wait?(@input)
        raise Refused, KernelTool::INVALID_LIFETIME unless KernelTool.valid_lifetime?(@input)
        raise Refused, KernelTool::INVALID_WAKE unless KernelTool.valid_wake?(@input)
        refusal = KernelTool.model_refusal(@run, @input)
        raise Refused, refusal if refusal
        lifetime = KernelTool.lifetime(@node, @input)
        raise Refused, "turn_already_delivered" if lifetime == "turn" && @run.delivered?

        resolution = Conversations::ConversationAddress.resolve(sender_conversation: @run.conversation,
          sender: @run.answering_user, address: @input["to"], reach: Conversations::Reach.of(@node))
        raise Refused, resolution.refusal.to_s if resolution.refusal
        target = resolution.conversation
        raise Refused, "request_target_self" if target == @run.conversation
        clock = Conversations::Inputs::DeliverAt.parse(at: @input["deliver_at"], in_: @input["deliver_in"])
        raise Refused, clock.refusal.to_s if clock.refusal

        @run.with_lock(requires_new: true) do
          if KernelTool.wait?(@input)
            result = Delegations::Observers.append_await(call: @node, prompt: @input["prompt"])
            raise Refused, result.outcome.to_s unless result.accepted?
          end
          @completion = Delegations.prepare(call: @node, lifetime: lifetime, wake: KernelTool.wake(@node, @input))
          raise Refused, "delegation_canceled" unless @completion
        end

        command = Conversations::Inputs::Create::Command.sent(
          host: target, acting_user: @run.answering_user, kind: "direct_reply",
          entries: [{ "text" => @input["prompt"] }], communication_kind: "request",
          sender_conversation_public_id: @run.conversation.public_id,
          run_public_id: @run.public_id, task_key: @node.node_key, delegation: @completion,
          answering_user_public_id: @input["agent"], deliver_at: clock.resolve(now: Time.current)&.utc&.floor,
          **KernelTool.initiator_model(@node, @input))
        accepted = Conversations::Inputs::Create.call(command) do |input|
          receipt = {
            "input_public_id" => input.public_id, "conversation_public_id" => target.public_id,
            "answering_user_public_id" => input.answering_user.public_id,
            "state" => input.state, "delivery_mode" => input.delivery_mode,
            "deliver_at" => input.deliver_at&.utc&.iso8601,
            "completion" => { "run_public_id" => @run.public_id, "task_key" => @completion.node_key },
          }
          result = KernelTool.settle(@node, JSON.generate(receipt), title: "request", structured_content: receipt, locked: true)
          raise Refused, result.to_s unless %i[applied idle].include?(result)
        end
        return :applied if accepted.outcome == :communication_published
        raise Refused, accepted.outcome.to_s unless accepted.accepted?

        :applied
      rescue Refused => error
        Delegations.launch_failed(call: @node, detail: error.message)
        KernelTool.settle(@node, error.message, title: "request refused", is_error: true)
      end
    end
  end
end
