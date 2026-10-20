class AddRealtimeSignalToTasks < ActiveRecord::Migration[8.1]
  def change
    add_column :tasks, :realtime_signal, :text
  end
end
