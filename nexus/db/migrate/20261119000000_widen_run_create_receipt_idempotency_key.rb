class WidenRunCreateReceiptIdempotencyKey < ActiveRecord::Migration[8.2]
  def up
    change_column :run_create_receipts, :idempotency_key, :string, limit: 255
  end

  def down
    change_column :run_create_receipts, :idempotency_key, :string, limit: 36
  end
end
