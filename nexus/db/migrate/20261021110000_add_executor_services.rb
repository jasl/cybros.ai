class AddExecutorServices < ActiveRecord::Migration[8.2]
  def up
    add_column :executors, :services, :jsonb
    execute <<~SQL
      UPDATE executors SET services = jsonb_build_object(executor_kind,
        jsonb_build_object('tools', served_tools, 'documents', served_documents, 'environment', environment))
    SQL
    change_column_null :executors, :services, false
  end

  def down
    remove_column :executors, :services
  end
end
