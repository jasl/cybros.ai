class IndexCommunicationCompletion < ActiveRecord::Migration[8.2]
  def change
    add_index :tasks, :delegated_input_public_id, unique: true,
      where: "delegated_input_public_id IS NOT NULL", name: "index_tasks_on_delegated_input"
  end
end
