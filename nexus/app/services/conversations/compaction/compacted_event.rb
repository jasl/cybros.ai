module Conversations
  module Compaction
    # ONE `context_compacted` payload for both hosts and every arm, task-
    # and turn-grained: the loop, the turn it backs when it backs one,
    # the round repaired and the summarizer mid-turn, the summary turn
    # between turns, what the arm chose (`mode`) and why it fired
    # (`trigger`). The fallback adds what it fell from.
    module CompactedEvent
      TYPE = "context_compacted".freeze

      module_function

      def payload(agent_loop:, mode:, trigger:, turn: nil, task_key: nil, summary_task_key: nil,
                  summary_turn: nil, **extra)
        {
          "turn_public_id" => turn&.public_id,
          "agent_loop_public_id" => agent_loop.public_id,
          "task_key" => task_key,
          "summary_task_key" => summary_task_key,
          "summary_turn_public_id" => summary_turn&.public_id,
          "mode" => mode,
          "trigger" => trigger,
          **extra,
        }.compact
      end

      def item(**payload) = { type: TYPE, payload: payload(**payload) }
    end
  end
end
