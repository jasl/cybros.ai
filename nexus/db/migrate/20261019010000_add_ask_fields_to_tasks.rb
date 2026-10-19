class AddAskFieldsToTasks < ActiveRecord::Migration[8.2]
  def change
    add_column :tasks, :ask_fields, :jsonb
  end
end
