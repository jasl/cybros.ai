class AddStrictCommunicationDelivery < ActiveRecord::Migration[8.2]
  def change
    add_column :inputs, :requested_delivery_mode, :string
    add_column :inputs, :on_target_end, :string
    add_column :inputs, :fallback_reason, :string
  end
end
