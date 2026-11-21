class SupportSsoMemberCredentials < ActiveRecord::Migration[8.2]
  def change
    change_column_null :identities, :password_digest, true
    add_column :member_recovery_authorizations, :purpose, :string, default: "password", null: false
    add_reference :member_recovery_authorizations, :lost_sso_provider, foreign_key: { to_table: :sso_providers, on_delete: :nullify }
  end
end
