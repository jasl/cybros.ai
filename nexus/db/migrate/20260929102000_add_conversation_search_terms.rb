class AddConversationSearchTerms < ActiveRecord::Migration[8.2]
  def change
    add_column :content_bodies, :search_terms, :text, array: true, default: [], null: false
    add_column :conversations, :search_terms, :text, array: true, default: [], null: false
    add_index :content_bodies, :search_terms, using: :gin, name: "index_content_bodies_on_search_terms",
      where: "conversation_turn_variant_id IS NOT NULL AND sealed_at IS NOT NULL AND role = ANY (ARRAY['prompt'::text, 'content'::text, 'steers'::text])"
    add_index :conversations, :search_terms, using: :gin, name: "index_conversations_on_search_terms"
  end
end
