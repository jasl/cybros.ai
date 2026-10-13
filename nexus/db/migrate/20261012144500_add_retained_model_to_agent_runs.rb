class AddRetainedModelToAgentRuns < ActiveRecord::Migration[8.2]
  def change
    add_column :agent_runs, :retained_model, :jsonb
  end
end
