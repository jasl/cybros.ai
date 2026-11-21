# PARALLEL_WORKERS=1 bin/rails test test/benchmarks/scheduled_result_relay.rb
require "test_helper"
require_relative "../test_helpers/schedules_console_test_helper"

class ScheduledResultRelayBenchmark < ActiveSupport::TestCase
  include SchedulesConsoleTestHelper

  test "recover scheduled results with 1000 retained receipts" do
    @workspace = workspaces(:shared)
    @human = users(:member)
    DevModelLane.ensure_enabled!(accounts(:cybros))
    @conversation = schedule_conversation
    job = console_schedule
    now = Time.current
    actor = Speakers::Resolve.member(account: @human.account, user: @human)
    rows = Array.new(1_000) do |index|
      { workspace_id: @workspace.id, account_id: @human.account_id, creating_user_id: @human.id,
        answering_user_id: @conversation.answering_user_id, last_activity_at: now,
        schedule_id: job.id, schedule_public_id: job.public_id, scheduled_for: now - index.minutes,
        scheduled_input_public_id: SecureRandom.uuid_v7, scheduled_turn_public_id: SecureRandom.uuid_v7 }
    end
    children = Conversation.insert_all!(rows, returning: %w[id scheduled_turn_public_id])
    Turn.insert_all!(children.map do |child|
      { public_id: child.fetch("scheduled_turn_public_id"), conversation_id: child.fetch("id"), position: 0,
        account_id: @human.account_id, speaker_id: actor.id, control_owner_user_id: @human.id,
        answering_user_id: @conversation.answering_user_id, kind: "direct_reply", role: "assistant",
        status: "completed", relayed_at: now }
    end)

    3.times do
      queries = 0
      pages = 0
      scanned = 0
      cursor = { delegations_done: true, variants_done: true, inputs_done: true }
      listener = ->(*_, payload) { queries += 1 unless %w[SCHEMA TRANSACTION].include?(payload[:name]) }
      start = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ActiveSupport::Notifications.subscribed(listener, "sql.active_record") do
        loop do
          pass = Runs::Spawn::Relay.call(**cursor)
          pages += 1
          scanned += pass[:scanned]
          break unless pass.more?
          cursor = pass.cursor.symbolize_keys
        end
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - start
      puts JSON.generate(pages: pages, scanned: scanned, queries: queries, milliseconds: (elapsed * 1000).round)
    end
  end
end
