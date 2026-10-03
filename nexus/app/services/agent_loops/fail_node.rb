module AgentLoops
  # The one failure write: the node's policy decides the settlement — by
  # DERIVATION, in `Graph.settlement`, never by a stamp written here — and
  # the cascade's newly-ready nodes join the caller's worklist. The only
  # resolution a caller names is the one cancel that IS an adjudication, a
  # person's branch cancel.
  class FailNode
    class << self
      # `output_summary` replaces the column when given — a declined step's
      # quality and category, merged by the caller into what the row already
      # says — and leaves it alone otherwise.
      def call(agent_loop:, node:, error_key:, worklist:, status: "failed",
               error_detail: nil, failure_resolution: nil, narration: nil, release: true,
               output_summary: nil)
        Transition.node(
          node,
          narration: narration,
          status: status,
          completed_at: Time.current,
          error_key: error_key.to_s.first(64),
          error_detail: error_detail&.to_s&.first(256),
          failure_resolution: failure_resolution,
          **({ output_summary: output_summary } if output_summary)
        )
        worklist.concat(Release.settled(node)) if release && Graph.settlement_of(node) != :pending
        node
      end
    end
  end
end
