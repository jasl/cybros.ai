# Run after test workers stop, against a migrated explicit test database with
# standard fixtures already loaded. Captures the shipped observation query over
# 20,000 unrelated same-host events; this checks query shape, not throughput.
# Synthetic rows roll back. ANALYZE may refresh database planner statistics.
# RAILS_ENV=test RAILS_TEST_APP_DB_NAME=nexus_steering_plan_test \
# RAILS_TEST_CABLE_DB_NAME=nexus_steering_plan_cable_test \
# bin/rails runner test/manual/steering_observation_plan.rb
abort "explicit test database required" unless Rails.env.test? && ENV["RAILS_TEST_APP_DB_NAME"].present?

require_relative "../test_helpers/run_seam_test_helper"
extend RunSeamTestHelper

reader = User.members.find_by!(handle: "member")
workspace = Workspace.data_accessible_to(reader).browsable.find_by!(name: "Shared")
account = reader.account
connection = ApplicationRecord.lease_connection
now = Time.current

ApplicationRecord.transaction do
  connection.execute("SET LOCAL statement_timeout = '15s'")
  conversation = Conversation.create!(workspace: workspace, creating_user: reader)
  run = create_run_backed_turn(conversation: conversation, acting_user: reader).run
  input_public_id = SecureRandom.uuid_v7
  Event::Append.call(host: conversation, idempotency_key: input_public_id, items: [{
    type: "input_accepted", payload: { "input_public_id" => input_public_id,
      "expected_steering_run_public_id" => run.public_id },
  }])
  envelope = conversation.events.create!(account: account, idempotency_key: SecureRandom.uuid_v7)
  common = { account_id: account.id, event_id: envelope.id, host_type: "Conversation",
             host_id: conversation.id, occurred_at: now, created_at: now, updated_at: now }
  rows = [{ sequence: 2, item_type: "input_materialized",
            payload: { "input_public_id" => input_public_id,
              "run_public_id" => run.public_id, "task_key" => "consume" } }]
  20_000.times do |index|
    rows << if index.even?
      { sequence: index + 3, item_type: "input_materialized",
        payload: { "input_public_id" => SecureRandom.uuid_v7,
          "run_public_id" => run.public_id, "task_key" => "unrelated-#{index}" } }
    else
      { sequence: index + 3, item_type: "task_status",
        payload: { "run_public_id" => run.public_id,
          "task_key" => "unrelated-#{index}", "status" => "completed" } }
    end
  end
  EventItem.insert_all!(rows.map { |row| common.merge(row) })
  %w[events event_items].each { |table| connection.execute("ANALYZE #{table}") }

  statements = []
  listener = ->(_name, _start, _finish, _id, payload) {
    sql = payload.fetch(:sql).dup
    payload.fetch(:type_casted_binds).each_with_index.to_a.reverse_each do |value, index|
      sql = sql.gsub("$#{index + 1}", connection.quote(value))
    end
    statements << sql
  }
  observation = ApplicationRecord.uncached do
    ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
      Run::SteeringObservation.new(run: run, input_public_id: input_public_id)
    end
  end
  raise "target consumption not observed" unless observation.consumed?
  sql = statements.find { |statement|
    statement.include?('FROM "event_items"') && statement.include?("payload ->> 'input_public_id'")
  }
  raise "missing production terminal query" unless sql

  puts "Target is sequence 2, followed by 20,000 unrelated same-host events, including 10,000 other input outcomes."
  puts "SHIPPED TERMINAL QUERY, default planner, no index forcing:"
  puts sql
  plan = connection.select_values("EXPLAIN (ANALYZE, BUFFERS, COSTS ON, TIMING OFF) #{sql}")
  puts plan
  raise "terminal input index not selected" unless plan.any? { |line| line.include?("index_event_items_on_input_outcome") }
  raise ActiveRecord::Rollback
end
puts "Rolled back all synthetic observation rows."
