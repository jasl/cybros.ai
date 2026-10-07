require "test_helper"

# THE REACTOR'S EGRESS SEAM.
#
# The control server's reactor was inbound-only: its scheduler is captured
# inside the Async block and read by `stop` alone, so nothing outside could put
# work on it. A fiber can only be spawned from inside its own reactor, so
# outbound work that wants to be one — a feed following a run — needed a door
# that is safe to open from another thread.
class ControlServerSpawnTest < Minitest::Test
  def server(routes: {})
    Rho::ControlServer.new(bind: "127.0.0.1", port: 0, routes: routes)
  end

  def test_work_pushed_from_another_thread_runs_inside_the_reactor
    control = server
    ran = Thread::Queue.new
    control.spawn { ran << Fiber.scheduler.class.name }
    control.run

    assert_match(/Async/, ran.pop(timeout: 5).to_s,
      "the work must run under the server's scheduler, not on the caller's thread")
  ensure
    control&.stop
  end

  # The queue buffers, so a caller does not have to know whether the reactor
  # is up yet — which is the whole reason this is a queue and not a scheduler
  # reference somebody has to wait for.
  def test_work_pushed_before_the_reactor_starts_is_not_lost
    control = server
    ran = Thread::Queue.new
    3.times { |index| control.spawn { ran << index } }
    control.run

    assert_equal [0, 1, 2], 3.times.map { ran.pop(timeout: 5) }.sort
  ensure
    control&.stop
  end

  # One spawned failure must not take the drain — or the accept loop — with
  # it. A daemon whose control surface died because a feed raised would be
  # unreachable for the one request that could diagnose it.
  def test_a_task_that_raises_leaves_the_drain_and_the_surface_alive
    control = server(routes: { ["GET", "/probe"] => ->(_request) { [200, { ok: true }] } })
    ran = Thread::Queue.new
    control.spawn { raise "the spawned task failed" }
    control.spawn { ran << :after }
    control.run

    assert_equal :after, ran.pop(timeout: 5), "the drain admitted the next task"
    response = Net::HTTP.get_response(URI("http://127.0.0.1:#{control.port}/probe"))
    assert_equal "200", response.code, "and the accept loop is still serving"
  ensure
    control&.stop
  end
end
