require "test_helper"

class OwnedProcessTest < Minitest::Test
  # TERM first, and it must not spend the latch: a server that ignores TERM
  # still has to die to the KILL that follows.
  def test_terminate_is_polite_and_leaves_the_kill_available
    # The child says when its trap is armed: a TERM sent before that line
    # ran would kill an untrapped shell and prove nothing.
    reader, writer = IO.pipe
    child = Rho::Runner::OwnedProcess.spawn(
      "/bin/sh", "-c", 'trap "" TERM; echo armed; while :; do sleep 1; done',
      in: File::NULL, out: writer, err: File::NULL
    )
    writer.close
    assert_equal "armed\n", reader.gets

    assert child.terminate("TERM")
    sleep 0.2
    assert_nil child.poll, "TERM was ignored by design; the child must still be there"

    status = child.kill_and_reap
    assert_equal 9, status.termsig
  ensure
    reader&.close
  end

  def test_terminate_reaches_the_whole_group
    child = Rho::Runner::OwnedProcess.spawn(
      "/bin/sh", "-c", "sleep 30 & wait", in: File::NULL, out: File::NULL, err: File::NULL
    )
    sleep 0.1

    assert child.terminate("TERM")
    status = child.kill_and_reap
    refute_nil status
    assert_raises(Errno::ESRCH) { Process.kill(0, -child.group_pid) }
  end

  def test_terminate_after_the_guard_is_reaped_is_a_no_op
    child = Rho::Runner::OwnedProcess.spawn("/usr/bin/true", in: File::NULL, out: File::NULL, err: File::NULL)
    child.kill_and_reap

    refute child.terminate("TERM")
  end
end
