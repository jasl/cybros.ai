require "test_helper"
require_relative "test_helpers/lock_order_test_helper"

class LockOrderGuardTest < ActiveSupport::TestCase
  include LockOrderTestHelper

  # Concatenation alone would make a suffix-equality assertion tautological, so
  # this pins the ordering claims the plan actually reviewed: a reorder inside
  # the suffix has to fail something.
  test "the model-work programme keeps its reviewed lock order" do
    assert_equal LOCK_LADDER.keys, FOUNDATION_LOCK_LADDER + MODEL_WORK_LOCK_LADDER
    assert_operator LOCK_LADDER.fetch("users"), :<, LOCK_LADDER.fetch("inference_requests"),
      "the aggregate is taken below the Workspace/User authority rows"
    assert_operator LOCK_LADDER.fetch("users"), :<, LOCK_LADDER.fetch("conversations"),
      "the conversation lane lock sits below the authority rows too"
    assert_operator LOCK_LADDER.fetch("conversations"), :<, LOCK_LADDER.fetch("model_invocations"),
      "the conversation owner precedes the invocation work its variants anchor"
    assert_operator LOCK_LADDER.fetch("conversations"), :<,
      LOCK_LADDER.fetch("conversation_event_cursors"),
      "every appender holds the conversation before the cursor's allocation lock"
    assert_operator LOCK_LADDER.fetch("inference_requests"), :<, LOCK_LADDER.fetch("model_invocations"),
      "the InferenceRequest owner precedes its invocation"
    assert_operator LOCK_LADDER.fetch("agent_runs"), :<, LOCK_LADDER.fetch("model_invocations"),
      "the loop row is the graph's universal lane lock — every writer takes it " \
      "before the step invocations it cancels or converges"
    assert_operator LOCK_LADDER.fetch("agent_runs"), :<,
      LOCK_LADDER.fetch("conversation_event_cursors"),
      "every appender holds the loop before the cursor's allocation lock"
    assert_operator LOCK_LADDER.fetch("agent_runs"), :<,
      LOCK_LADDER.fetch("agent_run_tasks"),
      "an await resolution takes the loop, then the one task it settles"
    assert_operator LOCK_LADDER.fetch("agent_runs"), :<,
      LOCK_LADDER.fetch("conversation_inputs"),
      "the drain holds the loop, then the input rows it lands"
    assert_operator LOCK_LADDER.fetch("conversation_inputs"), :<,
      LOCK_LADDER.fetch("agent_run_tasks"),
      "the door and the drain both rank the waiting room above the graph"
    assert_operator LOCK_LADDER.fetch("agent_run_tasks"), :<,
      LOCK_LADDER.fetch("model_invocations"),
      "the task row precedes the step invocation it names"
    assert_operator LOCK_LADDER.fetch("model_provider_oauth_sessions"), :<,
      LOCK_LADDER.fetch("model_provider_oauth_tasks"),
      "an authorization session is held before its per-request task"
    assert_operator LOCK_LADDER.fetch("model_provider_oauth_tasks"), :<,
      LOCK_LADDER.fetch("model_provider_credentials"),
      "an OAuth request task is held before token installation mutates the credential"
    assert_operator LOCK_LADDER.fetch("usage_records"), :<, LOCK_LADDER.fetch("users"),
      "the settle scan discovers its payers FROM the locked receipts"
    assert_operator LOCK_LADDER.fetch("agent_runs"), :<, LOCK_LADDER.fetch("content_uploads"),
      "a door pins the uploads it binds under its host's lane lock"
    assert_operator LOCK_LADDER.fetch("content_uploads"), :<, LOCK_LADDER.fetch("conversation_inputs"),
      "a door pins the uploads it binds BEFORE the row it binds them to is locked (the driven flow)"
    assert_operator LOCK_LADDER.fetch("content_uploads"), :<, LOCK_LADDER.fetch("content_fragments"),
      "the upload pin precedes the fragment writer it hands the rows to"
    # Every rank must name a table that exists. The
    # ladder is a list of strings, so a table deleted underneath it leaves a
    # rank that reads as reviewed and can never be violated — which is exactly
    # what the course correction found: three ranks outlived their tables and
    # nothing failed. Unbuilt or unlocked future tables acquire a rank only
    # with their first real flow.
    tables = ApplicationRecord.with_connection { _1.tables.to_set }
    LOCK_LADDER.each_key do |name|
      assert_includes tables, name, "#{name} is ranked in the ladder but no such table exists"
    end
    assert_equal LOCK_LADDER.keys.uniq.length, LOCK_LADDER.keys.length
  end

  # The guard's own failure mode, including KEY SHARE capture, proven: an
  # out-of-order acquisition must be reported, or every green run above is
  # vacuous. Single-threaded, so the deliberate inversion cannot actually
  # deadlock.
  test "the guard detects an acquisition against the ladder" do
    member = create_agent_member(steward: users(:owner), agent_identifier: "install-guard-detect")
    executor = member.task_executors.create!(
      account: member.account, executor_kind: :agent_application, display_name: "Guard app"
    )

    sequences = capture_lock_sequences do
      ApplicationRecord.transaction do
        TaskExecutor.lock("FOR KEY SHARE").find(executor.id)
        User.lock.find(member.id)
      end
    end

    assert_equal 1, violations_in(sequences).length,
      "an executor-before-user acquisition must be detected, or this guard guards nothing"
  end

  test "the guard rejects a locking OF clause naming multiple relations" do
    error = assert_raises Minitest::Assertion do
      capture_lock_sequences do
        ActiveSupport::Notifications.instrument(
          "sql.active_record",
          sql: <<~SQL.squish
            SELECT "model_invocations"."id"
            FROM "model_invocations"
            INNER JOIN "content_bodies" ON TRUE
            FOR UPDATE OF "model_invocations", "content_bodies"
          SQL
        )
      end
    end

    assert_match(/must name exactly one relation/, error.message)
  end

  test "the guard attributes a schema-qualified locking FROM to its table" do
    sequences = capture_lock_sequences do
      ActiveSupport::Notifications.instrument(
        "sql.active_record",
        sql: <<~SQL.squish
          SELECT source.*
          FROM "private_schema"."model_invocations" AS source
          WHERE source.id = 1
          FOR UPDATE
        SQL
      )
    end

    assert_equal [["model_invocations"]], sequences
    assert_empty violations_in(sequences)
  end
end
