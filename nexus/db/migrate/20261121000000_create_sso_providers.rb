class CreateSsoProviders < ActiveRecord::Migration[8.2]
  def change
    add_column :accounts, :sso_only, :boolean, default: false, null: false

    create_table :sso_providers do |t|
      t.references :account, null: false, foreign_key: true, index: false
      t.uuid :public_id, null: false, default: -> { connection.database_version >= 180_000 ? "uuidv7()" : "uuid_generate_v7()" }
      t.string :name, null: false, limit: 100
      t.string :protocol, null: false
      t.string :issuer, null: false, limit: 1024
      t.string :client_id
      t.text :client_secret
      t.text :authorization_endpoint
      t.text :token_endpoint
      t.text :userinfo_endpoint
      t.text :trusted_origins
      t.string :scopes, default: "openid profile email", null: false
      t.string :token_auth_method, default: "client_secret_basic", null: false
      t.string :subject_field, default: "id", null: false
      t.string :email_field, default: "email"
      t.string :email_verified_field, default: "email_verified"
      t.string :name_field, default: "name"
      t.string :required_group
      t.boolean :jit, default: false, null: false
      t.boolean :enabled, default: false, null: false
      t.integer :admission_version, default: 0, null: false
      t.integer :lock_version, default: 0, null: false
      t.datetime :tested_at
      t.text :pending_configuration
      t.timestamps
      t.index :public_id, unique: true
      t.index [:account_id, :issuer], unique: true
    end

    create_table :sso_connections do |t|
      t.references :sso_provider, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.references :identity, null: false, foreign_key: { on_delete: :cascade }, index: false
      t.string :subject, null: false, limit: 512
      t.string :display_name, limit: 255
      t.integer :admission_version, default: 0, null: false
      t.timestamps
      t.index [:sso_provider_id, :subject], unique: true
      t.index [:identity_id, :sso_provider_id], unique: true
    end
  end
end
