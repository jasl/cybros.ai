class AddExecutionDetailRetention < ActiveRecord::Migration[8.2]
  def change
    add_column :agent_loops, :details_pruned_at, :datetime
    add_column :conversation_turn_variants, :details_pruned_at, :datetime
    add_index :agent_loops, [:account_id, :completed_at, :id],
      where: "details_pruned_at IS NULL AND conversation_turn_variant_id IS NOT NULL " \
        "AND status = ANY (ARRAY['completed'::text, 'canceled'::text])",
      name: "index_agent_loops_on_detail_retention"
    add_index :model_invocations, [:account_id, :terminal_at, :id],
      where: "conversation_id IS NOT NULL " \
        "AND status = ANY (ARRAY['completed'::text, 'failed'::text, 'canceled'::text, 'timed_out'::text])",
      name: "index_model_invocations_on_detail_retention"
  end
end
