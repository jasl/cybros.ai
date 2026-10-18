class IndexEventItemsForInputObservations < ActiveRecord::Migration[8.2]
  def change
    add_index :event_items,
      "host_type, host_id, (payload ->> 'input_public_id'), sequence",
      where: "item_type = ANY (ARRAY['input_materialized'::text, 'input_deleted'::text])",
      name: "index_event_items_on_input_outcome"
  end
end
