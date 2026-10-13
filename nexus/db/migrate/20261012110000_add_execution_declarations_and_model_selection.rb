class AddExecutionDeclarationsAndModelSelection < ActiveRecord::Migration[8.2]
  def change
    remove_column :users, :fallback_model, :string, limit: 193
    add_column :users, :fallback_models, :jsonb
    remove_column :agent_runs, :result_delivery_model_fallback_used, :boolean, default: false, null: false

    %i[conversation_inputs conversation_turn_variants agent_runs].each do |table|
      add_column table, :execution_declaration, :jsonb
    end

    %i[conversation_inputs conversation_turn_variants agent_runs agent_run_tasks inference_requests].each do |table|
      add_column table, :model_selection, :jsonb
      add_column table, :fallback_models, :jsonb
    end
  end
end
