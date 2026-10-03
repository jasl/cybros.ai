class AddPublicIdToMemoryDocuments < ActiveRecord::Migration[8.2]
  def change
    add_column :memory_documents, :public_id, :uuid, default: -> { "uuidv7()" }, null: false
    add_index :memory_documents, :public_id, unique: true
  end
end
