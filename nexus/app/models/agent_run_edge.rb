# Every edge waits for its source. Structural edges additionally describe
# authored branch placement; explicit result and wait references do not.
# A join's edge follows an expanding branch to its frontier; endpoint
# deduplication may upgrade a reference to structural placement. Both writes
# belong to Tasks::Append::Splice.
class AgentRunEdge < ApplicationRecord
  attr_readonly :account_id, :agent_run_id, :from_node_id, :to_node_id, :structural

  belongs_to :account, default: -> { agent_run&.account }
  belongs_to :agent_run, inverse_of: :agent_run_edges
  belongs_to :from_node, class_name: "AgentRunTask", inverse_of: :outgoing_edges
  belongs_to :to_node, class_name: "AgentRunTask", inverse_of: :incoming_edges

  validates :to_node_id, uniqueness: { scope: :from_node_id }
  validate :never_a_self_loop

  private

    def never_a_self_loop
      errors.add(:to_node_id, :invalid) if from_node_id.present? && from_node_id == to_node_id
    end
end
