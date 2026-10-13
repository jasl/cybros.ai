class AddModelSelectionToSchedules < ActiveRecord::Migration[8.2]
  def change
    add_column :schedules, :model_selection, :jsonb
    add_column :schedules, :fallback_models, :jsonb
  end
end
