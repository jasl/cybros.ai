module Runs
  # What the graph-writing kernel tools share:
  # the round that emitted the call, the driver's continuation the work is
  # spliced under, the tip a branch starts from, and the settle of the call
  # itself.
  module KernelTool
    # THE WHEN WORD, one boolean on graph-writing calls: absent or
    # false, the work is DETACHED — the call answers at once and the
    # results queue as receipts. `wake: passive` suppresses starting a new
    # turn for the receipt; `wait: true` makes this turn wait and read the results.
    INVALID_WAIT = "wait must be true or false.".freeze
    INVALID_LIFETIME = 'lifetime must be "turn" or "conversation".'.freeze
    INVALID_WAKE = 'wake must be "auto" or "passive".'.freeze

    module_function

    def wait?(input) = input["wait"] == true

    def valid_wait?(input) = [nil, true, false].include?(input["wait"])

    def lifetime(node, input) = input["lifetime"] || node.lifetime

    def valid_lifetime?(input) = input["lifetime"].nil? || Task::LIFETIMES.include?(input["lifetime"])

    # Launch receipts retain both coordinates because task keys repeat in each
    # turn. A later turn can explicitly wait without guessing its source loop.
    def task_reference(node)
      "Task reference: run_public_id=\"#{node.run.public_id}\", task=\"#{node.node_key}\"."
    end

    def wake(node, input) = input["wake"] || node.wake

    def valid_wake?(input) = input["wake"].nil? || Task::WAKE_MODES.include?(input["wake"])

    # The round that emitted the call, whose model and tools a branch
    # inherits from its declaring context.
    def round_of(node)
      parent = node.expansion_parent
      return parent if parent&.model_task?
      return round_of(parent) if parent&.tool_call?

      node.incoming_edges.where(structural: true).includes(:from_node).map(&:from_node).find(&:model_task?)
    end

    # The same declaring-round fact for a task page. Keep only the page's
    # current ancestry frontier, rather than retaining every ancestor visited.
    def declaring_task_keys(nodes)
      frontier = nodes.to_h { |node| [node.id, node] }
      keys = {}
      until frontier.empty?
        parents = Task.where(id: frontier.values.filter_map(&:expansion_parent_id)).index_by(&:id)
        fallback = frontier.values.reject do |node|
          parent = parents[node.expansion_parent_id]
          parent&.model_task? || parent&.tool_call?
        end
        structural = RunEdge.where(to_node_id: fallback.map(&:id), structural: true).joins(:from_node)
          .where(tasks: { type: ::Tasks::ModelTask.sti_name })
          .select("DISTINCT ON (run_edges.to_node_id) run_edges.to_node_id, tasks.node_key")
          .order(:to_node_id, :id).to_h { |edge| [edge.to_node_id, edge[:node_key]] }
        next_frontier = {}
        frontier.each do |original_id, node|
          parent = parents[node.expansion_parent_id]
          if parent&.model_task?
            keys[original_id] = parent.node_key
          elsif parent&.tool_call?
            next_frontier[original_id] = parent
          else
            keys[original_id] = structural[node.id]
          end
        end
        frontier = next_frontier
      end
      keys
    end

    # The driver's continuation after this call. Waited work is spliced
    # BETWEEN the call and it, so the turn waits on what the call started;
    # a detached call has no head, and the splice adds nothing.
    def continuation_of(node)
      node.outgoing_edges.where(structural: true).includes(:to_node).map(&:to_node).find do |head|
        head.model_task? && head.continuation_source.present?
      end
    end

    # A branch hangs off the call, reads nothing of the round, and every
    # model step in it is marked `branch`. Work a background branch starts
    # remains background, including questions and waited child replies.
    def branch_tip(node)
      Tasks::Tip.new(
        mainline: nil, waits: [Tasks::Known.of(node)], reads: [],
        mark: Tasks::Compile::BRANCH, detached: node.detached?, lifetime: node.lifetime, wake: node.wake
      )
    end

    # THE INITIATOR'S MODEL, on `spawn` and `send`: the trio the addressed
    # turn falls to when its answerer has no preset and no history there
    # (`Conversations::AnswerEngine`, the last rung). The call's named
    # `model` — a catalog ref at the model's own reasoning default — else
    # the calling round's configured model (ConfiguredModel: new work begins
    # where the lineage was put, never on a fallback the round was moved
    # to), or — for a call no round emitted (an explicitly authored child's) — the loop's
    # current main-line choice, as kernel mail reads it (`ResultDelivery.surface`).
    # The wire always carries one.
    def initiator_model(node, input)
      named = input["model"]
      if named.blank?
        round = round_of(node)
        return ConfiguredModel.for(round).to_h if round

        return ResultDelivery.surface(node.run).slice(:provider_id, :model_ref, :reasoning_effort, :reasoning_enabled)
      end

      parsed = Nexus::ModelRef.parse(named)
      { provider_id: parsed.provider_id, model_ref: parsed.model_ref, reasoning_effort: nil, reasoning_enabled: nil }
    end

    # A named `model` this account may not run is refused at the call with
    # the resolver's word, not parked at the addressee's drain: the same
    # check the profile fact and the drain make (`ModelSelection.ref_refusal`).
    def model_refusal(run, input)
      return nil if input["model"].nil?

      named = String.try_convert(input["model"])
      return "model must be a string, as provider/model." if named.nil?
      return nil if named.blank?

      refusal = ModelSelection.ref_refusal(account: run.account, ref: named)
      "model_not_authorized: model: #{named.inspect} is not a model you may run here (#{refusal})." if refusal
    end

    # The kernel settles its own tool: no claim token exists, because the
    # work was never handed out.
    def settle(node, text, title:, is_error: false)
      Parks::Settle.call(
        node: node, trusted: true, outcome: "completed",
        content: text, is_error: is_error, title: title
      ).outcome
    end
  end
end
