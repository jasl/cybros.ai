class IndexConversationExecutionReads < ActiveRecord::Migration[8.1]
  def change
    add_index :turns, [:conversation_id, :position], order: { position: :desc },
      where: "kind = 'compaction_summary' AND status = 'completed'", name: "index_turns_on_completed_summaries"
    add_index :tasks, [:run_id, :id], order: { id: :desc },
      where: "type = 'Tasks::ModelTask' AND continuation_source IS DISTINCT FROM 'branch'",
      name: "index_tasks_on_mainline_order"
    add_index :tasks, 'run_id, (input_from_node_keys[1] COLLATE "C")',
      where: "type = 'Tasks::ModelTask' AND continuation_source IS DISTINCT FROM 'branch'",
      name: "index_tasks_on_mainline_first_read"
    add_index :content_bodies, :variant_id,
      where: "variant_id IS NOT NULL AND role = ANY (ARRAY['content'::text, 'prompt'::text])",
      name: "index_content_bodies_on_history_variants"
    add_index :tasks, :run_id, where: "first_runner_write IS NOT NULL",
      name: "index_tasks_on_runner_writes"
  end
end
