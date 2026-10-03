class CreateScheduledJobs < ActiveRecord::Migration[8.1]
  def change
    create_table :scheduled_jobs do |t|
      t.references :account, null: false, foreign_key: true
      t.references :conversation, null: false, foreign_key: { on_delete: :cascade }
      t.references :creating_user, null: false, foreign_key: { to_table: :users }
      t.references :answering_user, null: false, foreign_key: { to_table: :users }
      t.uuid :public_id, null: false
      t.string :name
      t.text :prompt, null: false
      t.jsonb :rule, null: false, default: {}
      t.string :provider_id, null: false
      t.string :model_ref, null: false
      t.string :reasoning_effort
      t.jsonb :configuration, null: false, default: {}
      t.jsonb :tool_names
      t.string :approval_mode
      t.uuid :speaker_actor_public_id
      t.uuid :source_agent_loop_public_id
      t.string :source_task_key
      t.string :status, null: false, default: "active"
      t.integer :lock_version, null: false, default: 0
      t.datetime :next_run_at
      t.datetime :last_enqueued_at
      t.uuid :last_input_public_id
      t.references :last_execution_conversation, foreign_key: { to_table: :conversations, on_delete: :nullify }
      t.string :last_error_code
      t.timestamps
    end

    add_index :scheduled_jobs, :public_id, unique: true
    add_index :scheduled_jobs, [:conversation_id, :public_id]
    add_index :scheduled_jobs, [:next_run_at, :id],
      where: "status = 'active' AND next_run_at IS NOT NULL", name: :index_scheduled_jobs_due

    add_reference :conversations, :scheduled_job, foreign_key: { on_delete: :nullify }, index: false
    add_column :conversations, :scheduled_job_public_id, :uuid
    add_column :conversations, :scheduled_for, :datetime
    add_column :conversations, :scheduled_input_public_id, :uuid
    add_column :conversations, :scheduled_turn_public_id, :uuid
    add_index :conversations, [:scheduled_job_id, :public_id]
    add_index :conversations, [:scheduled_job_id, :scheduled_for], unique: true,
      where: "scheduled_job_id IS NOT NULL", name: :index_conversations_scheduled_occurrence
    add_index :conversations, :id, where: "spawn_node_id IS NOT NULL OR scheduled_job_id IS NOT NULL",
      name: :index_conversations_reply_sources

    add_index :conversation_command_receipts, [:host_type, :host_id, :acting_user_id, :idempotency_key],
      unique: true, where: "operation = 'scheduled_job_create'", name: :index_conversation_receipts_scheduled_job_create
  end
end
