require "support/host_follower_harness"

class HostFollowerProgressTest < Minitest::Test
  include RhoTest::HostFollowerHarness

  # THE FRAMES ARE ON THE HOST'S THIRD FEED. Everything below
  # drives `follow_progress`: a frame lands in the bounded ring under the
  # daemon's sequence and reaches a listener as a `progress` frame; it
  # touches no task, no position, no gate.
  def progress_frame(type, **members)
    CybrosAgent::Api::ProgressFrame.new(
      **{ type: type, run_public_id: nil, conversation_public_id: nil, task_key: nil, tool_name: nil,
          process_id: nil, executor_public_id: "ex-1", at: "2026-09-13T10:00:00.250Z", payload: {} }.merge(members)
    )
  end

  def progress_run(*frames, ending: StopIteration, **options)
    run_for([page(run_event(1, "running"))], progress_sockets: [Socket.new(frames, ending: ending)], **options)
  end

  def test_progress_frames_fill_the_ring_under_a_sequence_and_reach_a_listener
    fanned = []
    run = progress_run(
      progress_frame("executor_progress", run_public_id: "al-1", task_key: "r1t0", tool_name: "bash",
        payload: { "text_tail" => "tick 1\n" }),
      progress_frame("process_output", run_public_id: "al-1", process_id: "p1",
        payload: { "lines" => ["up"], "exit" => nil })
    )
    run.listen { |frame| fanned << [frame.type, frame.payload] }

    assert_raises(StopIteration) { run.follow_progress }
    frames = run.snapshot.frames
    assert_equal [1, 2], frames.map { |frame| frame["seq"] }
    assert_equal ["executor_progress", "process_output"], frames.map { |frame| frame["type"] }
    assert_equal "r1t0", frames.first["task_key"]
    assert_equal({ "text_tail" => "tick 1\n" }, frames.first["payload"])
    assert_equal "p1", frames.last["process_id"]
    assert_equal ["progress", "progress"], fanned.map(&:first)
    assert_equal frames, fanned.map(&:last)
    assert_equal 0, run.snapshot.sequence, "a frame moves no position"
    assert_equal [@realtime], @context.asked_progress
  end

  def test_the_ring_is_bounded_to_the_newest_frames_and_absent_when_empty
    run = run_for([page(run_event(1, "running"))])
    assert_nil run.snapshot.frames, "no frames: the snapshot is byte-identical to before"

    many = Array.new(Rho::HostFollower::FRAMES_KEPT + 5) do |index|
      progress_frame("process_output", process_id: "p1", payload: { "lines" => ["l#{index}"] })
    end
    run = progress_run(*many)
    assert_raises(StopIteration) { run.follow_progress }
    frames = run.snapshot.frames
    assert_equal Rho::HostFollower::FRAMES_KEPT, frames.length
    assert_equal 6, frames.first["seq"], "the oldest five fell off"
    assert_equal Rho::HostFollower::FRAMES_KEPT + 5, frames.last["seq"]
  end

  def test_a_frame_for_a_run_this_follower_does_not_back_is_dropped
    run = progress_run(progress_frame("executor_progress", run_public_id: "al-9", task_key: "r1t0"))
    assert_raises(StopIteration) { run.follow_progress }
    assert_nil run.snapshot.frames
  end

  def test_a_follower_with_no_socket_never_opens_the_progress_feed
    run = run_for([page(run_event(1, "running"), run_event(2, "completed"))])
    run.follow
    assert_empty @context.asked_progress
  end

  def test_detaching_and_stopping_end_the_progress_subscription
    socket = Socket.new([progress_frame("process_output", process_id: "p1")], ending: StopIteration)
    run = run_for([page(run_event(1, "running"))], sockets: [Socket.new([]), Socket.new([])],
                  progress_sockets: [socket])
    run.listen { |_frame| run.detach_socket }
    assert_raises(StopIteration) { run.follow_progress }
    assert_equal 1, socket.unsubscribed

    socket = Socket.new([progress_frame("process_output", process_id: "p1")], ending: StopIteration)
    run = run_for([page(run_event(1, "running"))], sockets: [Socket.new([])], progress_sockets: [socket])
    run.listen { |_frame| run.stop }
    assert_raises(StopIteration) { run.follow_progress }
    assert_equal 1, socket.unsubscribed
  end
end
