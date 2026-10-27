# Run sequentially in an explicit isolated test database after fixtures load:
# RAILS_ENV=test RAILS_TEST_APP_DB_NAME=cybros_takeover_experiment_test \
# RAILS_TEST_CABLE_DB_NAME=cybros_takeover_experiment_cable_test \
# bin/rails runner test/manual/conversation_takeover_plan.rb
# Capture the actual command over a three-Run ownership chain among 10,000
# unrelated executions. All inserted data and takeover writes roll back.
abort "explicit test database required" unless Rails.env.test? && ENV["RAILS_TEST_APP_DB_NAME"].present?

human = User.members.find_by!(handle: "member")
workspace = Workspace.data_accessible_to(human).browsable.find_by!(name: "Shared")
connection = ApplicationRecord.lease_connection
now = Time.current

ApplicationRecord.transaction do
  source = Conversation.create!(workspace: workspace, creating_user: human, answering_user: human)
  child = Conversation.create!(workspace: workspace, creating_user: human, answering_user: human,
    parent_conversation: source, parent_conversation_public_id: source.public_id)
  descendant = Conversation.create!(workspace: workspace, creating_user: human, answering_user: human,
    parent_conversation: child, parent_conversation_public_id: child.public_id)
  unrelated = 10.times.map { Conversation.create!(workspace: workspace, creating_user: human, answering_user: human) }
  hosts = [source, child, descendant] + Array.new(10_000) { |index| unrelated[index / 1_000] }
  speaker = Speakers::Resolve.member(account: human.account, user: human)
  turns = Turn.insert_all!(hosts.each_with_index.map { |host, index|
    { account_id: human.account_id, conversation_id: host.id, position: index,
      kind: "direct_reply", role: "assistant", status: "completed", speaker_id: speaker.id,
      control_owner_user_id: human.id, answering_user_id: human.id, created_at: now, updated_at: now }
  }, returning: %w[id]).to_a
  variants = Variant.insert_all!(turns.map { |turn|
    { account_id: human.account_id, turn_id: turn.fetch("id"), position: 0,
      source: "run", status: "running", created_at: now, updated_at: now }
  }, returning: %w[id]).to_a
  runs = Run.insert_all!(variants.map { |variant|
    { account_id: human.account_id, workspace_id: workspace.id, creating_user_id: human.id,
      variant_id: variant.fetch("id"), status: "running", approval_mode: "bypass", created_at: now, updated_at: now }
  }, returning: %w[id public_id]).to_a
  [1, 2].each do |index|
    Turn.where(id: turns[index].fetch("id")).update_all(
      sender_run_public_id: runs[index - 1].fetch("public_id"),
      sender_conversation_public_id: hosts[index - 1].public_id, sender_task_key: "request", communication_kind: "request")
  end
  Turn.where(conversation_id: unrelated.map(&:id)).update_all(
    sender_run_public_id: runs.first.fetch("public_id"), sender_conversation_public_id: source.public_id,
    sender_task_key: "background", communication_kind: "request")
  %w[conversations turns variants runs inputs tasks].each { |table| connection.execute("ANALYZE #{table}") }
  statements = []
  capture = ->(_name, _start, _finish, _id, payload) {
    sql = payload.fetch(:sql).dup
    payload.fetch(:binds, []).each_with_index.to_a.reverse_each do |bind, index|
      sql = sql.gsub("$#{index + 1}", connection.quote(bind.value_for_database))
    end
    statements << sql if sql.include?("FOR NO KEY UPDATE NOWAIT") || sql.start_with?("WITH RECURSIVE owners AS") || sql.start_with?('UPDATE "turns" SET "source_released_at"') ||
      sql.start_with?('UPDATE "turns" SET source_released_at')
  }
  ActiveSupport::Notifications.subscribed(capture, "sql.active_record") do
    ApplicationRecord.transaction(requires_new: true) do
      result = Conversations::Takeover.call(conversation: child, acting_user: human)
      raise "takeover refused: #{result.outcome}" unless result.accepted?

      raise ActiveRecord::Rollback
    end
  end
  raise "owner query was not captured" unless statements.any? { |sql| sql.include?("FOR NO KEY UPDATE NOWAIT") }

  statements.each do |sql|
    puts sql
    puts connection.select_values("EXPLAIN (ANALYZE, BUFFERS, COSTS ON, TIMING OFF) #{sql}")
  end
  raise ActiveRecord::Rollback
end
