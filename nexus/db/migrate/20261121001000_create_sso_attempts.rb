class CreateSsoAttempts < ActiveRecord::Migration[8.2]
  def change
    create_table :sso_attempts do |t|
      t.references :account, null: false, foreign_key: { on_delete: :cascade }
      t.references :sso_provider, null: false, foreign_key: { on_delete: :cascade }
      t.references :session, foreign_key: { on_delete: :cascade }
      t.references :member_recovery_authorization, foreign_key: { on_delete: :cascade }
      t.uuid :public_id, null: false
      t.uuid :invitation_public_id
      t.string :purpose, null: false
      t.string :phase, null: false
      t.string :state_digest, null: false
      t.string :browser_digest, null: false
      t.string :nonce, null: false
      t.text :code_verifier
      t.integer :provider_version, null: false
      t.text :redirect_uri, null: false
      t.text :return_path
      t.string :action_name
      t.string :action_target
      t.string :subject
      t.string :email
      t.string :display_name
      t.boolean :password_proved, null: false, default: false
      t.boolean :email_verified, null: false, default: false
      t.datetime :expires_at, null: false
      t.timestamps
      t.index :public_id, unique: true
      t.index :state_digest, unique: true
      t.index [:expires_at, :id]
    end
  end
end
