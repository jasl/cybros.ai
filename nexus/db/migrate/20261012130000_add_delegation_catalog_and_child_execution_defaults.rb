class AddDelegationCatalogAndChildExecutionDefaults < ActiveRecord::Migration[8.2]
  def change
    add_column :users, :delegation_catalog, :jsonb
    add_column :conversations, :execution_declaration, :jsonb
    add_column :conversations, :model_selection, :jsonb
    add_column :conversations, :fallback_models, :jsonb
  end
end
