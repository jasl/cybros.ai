require "test_helper"

class Conversations::Inputs::WakeDueTest < ActiveSupport::TestCase
  include ActiveJob::TestHelper
  include ActiveSupport::Testing::ConstantStubbing

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    @actor = Actors::Resolve.member(account: @account, user: @user)
  end

  def room = Conversation.create!(workspace: @workspace, creating_user: @user)

  # Straight onto the row, past the door: the door's own kick is what this
  # sweep exists to replace, so the test enqueues nothing but the pass's.
  def row!(host, deliver_at:, state: "pending", position: nil)
    position ||= (host.conversation_inputs.maximum(:queue_position) || -1) + 1
    input = ConversationInput.create!(
      account: @account, host: host, queue_position: position, kind: "message",
      speaker_actor: @actor, authoring_user: @user, state: state,
      blocked_reason: (state == "blocked" ? "policy" : nil)
    )
    # The loop host's row may carry no time (the door refuses it by name
    # and the row's backstop refuses it too); it is written past both here
    # so the sweep's own `host_type` fence is what the pin proves.
    input.update_columns(deliver_at: deliver_at)
    input
  end

  def woken
    enqueued_jobs.select { |job| job[:job] == Conversations::Inputs::DrainJob }.map { |job| job[:args].first }
  end

  test "each room with a due pending row is kicked once; a future row, a blocked row, a row with no time and the loop host never" do
    due_twice = room
    row!(due_twice, deliver_at: 2.minutes.ago)
    row!(due_twice, deliver_at: 1.minute.ago)
    due_once = room
    row!(due_once, deliver_at: 30.seconds.ago)
    future = room
    row!(future, deliver_at: 1.hour.from_now)
    blocked = room
    row!(blocked, deliver_at: 5.minutes.ago, state: "blocked")
    untimed = room
    row!(untimed, deliver_at: nil)
    agent_loop = AgentLoop.create!(workspace: @workspace, creating_user: @user, status: "running",
      approval_mode: "bypass")
    row!(agent_loop, deliver_at: 5.minutes.ago)

    pass = nil
    assert_enqueued_jobs 2, only: Conversations::Inputs::DrainJob do
      pass = Conversations::Inputs::WakeDue.call
    end

    assert_equal [due_twice.id, due_once.id].sort, woken.sort
    assert_equal 2, pass[:woken]
    assert_equal 3, pass[:scanned]
    assert_not pass.more?
  end

  test "the longest-stranded room is kicked first and the budget bounds the pass, more? saying so" do
    recent = room
    row!(recent, deliver_at: 1.minute.ago)
    stranded = room
    row!(stranded, deliver_at: 10.minutes.ago)
    row!(stranded, deliver_at: 20.seconds.ago)

    pass = nil
    stub_const(Conversations::Inputs::WakeDue, :BUDGET, 1) do
      pass = Conversations::Inputs::WakeDue.call
    end

    assert_equal [stranded.id], woken, "the room whose oldest due row has waited longest"
    assert_equal 1, pass[:woken]
    assert_predicate pass, :more?

    clear_enqueued_jobs
    Conversations::Inputs::WakeDue.call
    assert_equal [stranded.id, recent.id], woken, "the full pass keeps that order"
  end

  test "a room whose due row is still there is kicked again by the next recurring scan" do
    busy = room
    row!(busy, deliver_at: 1.minute.ago)

    2.times { Conversations::Inputs::WakeDue.call }

    assert_equal [busy.id, busy.id], woken
  end

  test "the frontier is one clock read and one statement" do
    3.times { row!(room, deliver_at: 1.minute.ago) }

    assert_queries_count(2, include_schema: false) { Conversations::Inputs::WakeDue.call }
    assert_queries_match(/ORDER BY .*deliver_at.*id.*LIMIT/, count: 1) do
      Conversations::Inputs::WakeDue.call
    end
  end

  test "source rows consume the budget and equal timestamps advance before hosts are deduplicated" do
    repeated = room
    later = room
    at = 1.minute.ago
    first = row!(repeated, deliver_at: at)
    second = row!(repeated, deliver_at: at)
    row!(repeated, deliver_at: at)
    row!(later, deliver_at: at)

    stub_const(Conversations::Inputs::WakeDue, :BUDGET, 2) do
      pass = Conversations::Inputs::WakeDue.call
      assert_equal 2, pass[:scanned]
      assert_equal [repeated.id], woken
      assert_equal [at.iso8601(6), second.id], pass.cursor.last(2)
      first.destroy!
      second.destroy!
      clear_enqueued_jobs

      pass = continue(pass)
      assert_equal 2, pass[:scanned]
      assert_equal [repeated.id, later.id], woken
      assert_predicate pass, :more?
      clear_enqueued_jobs
      pass = continue(pass)
      assert_equal 0, pass[:scanned]
      assert_not_predicate pass, :more?
      assert_empty woken
    end
  end

  test "a continuation keeps its initial due cutoff and the next recurring scan sees newly due rows" do
    now = Time.current.change(usec: 123456)
    older = room
    later = room
    future = room
    row!(older, deliver_at: now - 2.seconds)
    row!(later, deliver_at: now - 1.second)
    row!(future, deliver_at: now + 1.second)

    stub_const(Conversations::Inputs::WakeDue, :BUDGET, 1) do
      pass = DatabaseClock.stub(:now, now) { Conversations::Inputs::WakeDue.call }
      assert_equal now.iso8601(6), pass.cursor.first
      clear_enqueued_jobs

      DatabaseClock.stub(:now, now + 1.minute) do
        pass = continue(pass)
        assert_equal [later.id], woken
        clear_enqueued_jobs
        pass = continue(pass)
        assert_not_predicate pass, :more?
        assert_empty woken
      end
    end

    DatabaseClock.stub(:now, now + 1.minute) { Conversations::Inputs::WakeDue.call }
    assert_equal [older.id, later.id, future.id], woken
  end

  test "each source page stops its index walk at the budget over retained due history" do
    due = row!(room, deliver_at: 1.minute.ago)
    common = due.attributes.except("id", "public_id", "queue_position", "deliver_at")
    ConversationInput.insert_all!(Array.new(10_000) do |index|
      common.merge("queue_position" => index + 1, "deliver_at" => nil)
    end)
    ConversationInput.insert_all!(Array.new(1_500) do |index|
      common.merge("queue_position" => index + 10_001, "deliver_at" => due.deliver_at)
    end)
    ApplicationRecord.lease_connection.execute("ANALYZE conversation_inputs")
    sources = []
    subscriber = ActiveSupport::Notifications.subscribe("sql.active_record") do |*, payload|
      if !payload[:cached] && payload[:sql].start_with?('SELECT "conversation_inputs"."deliver_at"')
        sources << [payload[:sql].dup, payload.fetch(:binds).dup]
      end
    end
    begin
      first = Conversations::Inputs::WakeDue.call
      second = continue(first)
      assert_equal [500, 500], [first[:scanned], second[:scanned]]
      assert_equal [1, 1], [first[:woken], second[:woken]]
    ensure
      ActiveSupport::Notifications.unsubscribe(subscriber)
    end

    assert_equal 2, sources.length
    sources.each do |sql, binds|
      plan = ApplicationRecord.lease_connection.select_values(
        "EXPLAIN (ANALYZE, BUFFERS) #{sql}", "EXPLAIN", binds
      ).join("\n")
      assert_match(/\ALimit\s/, plan)
      assert_match(/Index(?: Only)? Scan using index_conversation_inputs_due/, plan)
      assert_no_match(/Seq Scan|Bitmap|Sort|Filter:/, plan)
      assert_match(/actual [^\n]*rows=500(?:\.0+)? loops=1/, plan)
    end
  end

  test "the job is the pass's shell and the schedule runs it every minute" do
    due = room
    row!(due, deliver_at: 1.minute.ago)

    assert_enqueued_with(job: Conversations::Inputs::DrainJob, args: [due.id]) do
      Conversations::Inputs::WakeDueJob.perform_now
    end

    schedule = recurring_schedule
    assert_equal "Conversations::Inputs::WakeDueJob", schedule.dig("wake_due_conversation_inputs", "class")
    assert_equal "every minute", schedule.dig("wake_due_conversation_inputs", "schedule")
  end

  private

    def continue(pass)
      cutoff, after_at, after_id = pass.cursor
      Conversations::Inputs::WakeDue.call(cutoff: cutoff, after_at: after_at, after_id: after_id)
    end
end
