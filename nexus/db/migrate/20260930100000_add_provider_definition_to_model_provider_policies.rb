class AddProviderDefinitionToModelProviderPolicies < ActiveRecord::Migration[8.2]
  def change
    add_column :model_provider_policies, :provider_definition, :jsonb
  end
end
