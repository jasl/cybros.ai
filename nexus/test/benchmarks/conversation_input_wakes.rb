# PARALLEL_WORKERS=1 bin/rails test test/benchmarks/conversation_input_wakes.rb
# Bursts arrive before the test worker picks up precise wakes. SQL includes
# admission and actual drain execution; queue delivery and model IO are excluded.
require "test_helper"
require_relative "../test_helpers/inputs_apply_next_test_helper"

class ConversationInputWakesBenchmark < ActiveSupport::TestCase
  include InputsApplyNextTestHelper

  SIZE = 24

  %w[idle history busy steer steer_now future blocked held].each do |lane|
    test "input burst on a #{lane} conversation" do
      case lane
      when "history"
        accept!(text: "earlier message")
        drain!
      when "busy", "steer", "steer_now"
        create_run_backed_turn(conversation: @conversation, acting_user: @user)
      when "blocked"
        accept!.update!(state: "blocked", blocked_reason: "model_selection_missing")
      when "held"
        hold_settled_seam!(before: "queued before failure")
      else
        assert_includes %w[idle future], lane
      end
      clear_enqueued_jobs
      at = 1.hour.from_now if lane == "future"
      admitted = measure do
        SIZE.times do
          if lane == "held"
            kernel_result_delivery!
          else
            mode = Input::STEERING_MODES.include?(lane) ? lane : "queue"
            accept!(delivery_mode: mode, deliver_at: at)
          end
        end
      end
      precise = enqueued_jobs.select { |job| job[:job] == Conversations::Inputs::DrainJob }
      schedules = enqueued_jobs.count { |job| job[:job] == Runs::ScheduleJob }
      clear_enqueued_jobs
      applied = []
      drained = measure do
        precise.reject { |job| job[:at] }.each { applied << Conversations::Inputs::DrainJob.perform_now(@conversation.id) }
      end
      pass = nil
      swept = measure { pass = Conversations::Inputs::WakeDue.call }
      puts JSON.generate(lane: lane, admitted: admitted, drain_jobs: precise.count, scheduler_jobs: schedules,
        productive_drains: applied.count(&:positive?), applied: applied.sum, drained: drained,
        sweep: swept.merge(scanned: pass[:scanned], woken: pass[:woken]))
    end
  end

  test "recovery over multiple pages of the same waiting room" do
    backlog = Integer(ENV.fetch("BACKLOG_SIZE", "1501"))
    first = accept!
    common = first.attributes.except("id", "public_id", "queue_position")
    Input.insert_all!(Array.new(backlog - 1) { |i| common.merge("queue_position" => i + 1) })
    ApplicationRecord.lease_connection.execute("ANALYZE inputs")
    clear_enqueued_jobs
    pass = nil
    windows = []
    work = measure do
      loop do
        cutoff, after_at, after_id = pass&.cursor
        pass = ApplicationRecord.uncached do
          Conversations::Inputs::WakeDue.call(cutoff: cutoff, after_at: after_at, after_id: after_id || 0)
        end
        windows << [pass[:scanned], pass[:woken]]
        break unless pass.more?
      end
    end
    puts JSON.generate(lane: "one_room_backlog", backlog: backlog, pages: windows.size,
      scanned: windows.sum(&:first), woken: windows.sum(&:last), sweep: work)
  end

  test "source recovery for a busy room with queued execution mail" do
    source = Run.create!(workspace: @workspace, creating_user: @user, status: "running", approval_mode: "bypass")
    create_run_backed_turn(conversation: @conversation, acting_user: @user)
    SIZE.times { |i| kernel_result_delivery!(run_public_id: source.public_id, task_key: "mail#{i}") }
    clear_enqueued_jobs
    sampled = measure { Runs::Spawn::Relay.call }
    drains = enqueued_jobs.count { |job| job[:job] == Conversations::Inputs::DrainJob }
    puts JSON.generate(lane: "busy_source_mail", drain_jobs: drains, sweep: sampled)
  end

  test "turn settlement with an empty queue" do
    seam = create_run_backed_turn(conversation: @conversation, acting_user: @user)
    Runs::Transition.run(seam.run, status: "needs_attention", attention_reason: "halt_failure")
    clear_enqueued_jobs
    settled = measure { Conversations::Turns::Converge.call(run_id: seam.run.id, conversation_id: @conversation.id) }
    assert_equal "failed", seam.turn.reload.status
    precise = enqueued_jobs.select { |job| job[:job] == Conversations::Inputs::DrainJob }
    drained = measure { precise.each { Conversations::Inputs::DrainJob.perform_now(@conversation.id) } }
    puts JSON.generate(lane: "empty_settlement", drain_jobs: precise.size, settled: settled, drained: drained)
  end

  private

    def measure
      statements = 0
      capture = lambda do |*, payload|
        statements += 1 unless payload[:cached] || %w[SCHEMA TRANSACTION].include?(payload[:name])
      end
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond)
      ActiveSupport::Notifications.subscribed(capture, "sql.active_record") { yield }
      { sql: statements, ms: (Process.clock_gettime(Process::CLOCK_MONOTONIC, :float_millisecond) - started).round(1) }
    end
end
