require "support/host_run_harness"

class HostRunAttentionTest < Minitest::Test
  include RhoTest::HostRunHarness

  # A hold comes with a reason and stays until a terminal write CLEARS it —
  # a stale ask is worse than none, because it is what a console renders as
  # something a human must do.
  def test_attention_carries_the_reason_and_the_actionable_tasks_and_the_terminal_clears_it
    run = run_for([page(
      loop_event(1, "running", attention_reason: "await_task"),
      event(2, "attention_required",
            { "reason" => "await_task", "blocked_task_keys" => %w[ask-1] })
    )], sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow }
    attention = run.snapshot.attention
    assert_equal "await_task", attention.reason
    assert_equal %w[ask-1], attention.blocked_task_keys

    run = run_for([page(
      loop_event(1, "running", attention_reason: "await_task"),
      event(2, "attention_required",
            { "reason" => "await_task", "blocked_task_keys" => %w[ask-1] }),
      loop_event(3, "completed")
    )])
    run.follow
    assert_nil run.snapshot.attention
  end

  # A PARK ANNOUNCED: an `attention_required` item
  # tells `on_attention` with the attention and its source loop after the
  # snapshot carries it and outside the monitor (the daemon denies over
  # HTTP from it); one with no reason tells nobody.
  def test_an_attention_item_tells_the_follower_after_the_snapshot_carries_it
    told = []
    run = run_for([page(
      event(1, "turn_status", { "status" => "running", "turn_public_id" => "t-1", "agent_loop_public_id" => "al-1" }),
      event(2, "attention_required", { "reason" => "approval_required", "blocked_task_keys" => %w[r1t0 r1t1],
        "agent_loop_public_id" => "al-1" }),
      event(3, "attention_required", { "blocked_task_keys" => %w[r1t2] })
    )], host: CONVERSATION,
      on_attention: ->(r, attention, source_loop_public_id) { told << [r.public_id, source_loop_public_id, r.snapshot.loop, attention.to_h] },
      sleeper: ->(_s) { raise StopIteration })

    assert_raises(StopIteration) { run.follow }
    assert_equal [["c-1", "al-1", "al-1", { reason: "approval_required", blocked_task_keys: %w[r1t0 r1t1] }]], told
    assert_equal "approval_required", run.snapshot.attention.reason
  end
end
