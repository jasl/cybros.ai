class AddScheduleResultWake < ActiveRecord::Migration[8.2]
  def change
    add_column :schedules, :wake, :string, default: "auto", null: false
    add_column :conversations, :scheduled_result_wake, :string, default: "auto", null: false
  end
end
