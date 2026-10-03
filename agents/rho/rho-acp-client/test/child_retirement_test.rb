require "test_helper"

# The table admits a Child before process creation. A host ending or a
# shutdown can take that row while creation is in flight; late completion
# must reap that exact process without publishing an orphan session.
class ChildRetirementTest < Minitest::Test
  include RhoAcpClientTest::Helpers

  Children = Rho::AcpClient::Children

  def teardown = Rho::AcpClient.reset!

  def test_shutdown_before_spawn_reaps_the_late_child_and_publishes_no_session
    with_inflight_child do |worker, child, resume, stopped, _env, _root|
      Children.close!
      assert stopped.pop(timeout: 3), "shutdown finished taking the unspawned child"
      resume << true
      assert worker.join(3), "late creation returns without waiting for a retired child"
      assert_kind_of Rho::AcpClient::Refused, worker.value
      assert_empty Children.sessions
      assert_equal 0, Children.children_of("plain")
      refute process_group_alive?(child.group_pid), "the process born after shutdown is reaped"
    end
  end

  def test_host_release_before_spawn_reaps_the_late_child_and_publishes_no_session
    with_inflight_child do |worker, child, resume, stopped, _env, _root|
      Children.release("conv-1", log: nil)
      assert stopped.pop(timeout: 3), "host release finished taking the unspawned child"
      resume << true
      assert worker.join(3)
      assert_kind_of Rho::AcpClient::Refused, worker.value
      assert_empty Children.sessions
      assert_equal 0, Children.children_of("plain")
      refute process_group_alive?(child.group_pid)
    end
  end

  def test_a_retired_creation_cannot_remove_the_same_hosts_replacement_child
    with_inflight_child do |worker, child, resume, stopped, env, root|
      Children.release("conv-1", log: nil)
      assert stopped.pop(timeout: 3)
      replacement = acquire(env, root)
      resume << true
      assert worker.join(3)
      assert_kind_of Rho::AcpClient::Refused, worker.value
      assert_equal [replacement.id], Children.sessions.map { |session| session.fetch("session") }
      assert_equal 1, Children.children_of("plain")
      assert process_group_alive?(replacement.child.group_pid)
      refute process_group_alive?(child.group_pid)
      result = Rho::AcpClient::Call.new(session: replacement, prompt: "replacement-answer", env: env,
        home: nil, log: nil, clock: -> { Time.now }).run
      assert_equal "echo: replacement-answer", result.content.lines.first.strip
    end
  end

  def test_release_while_session_open_is_in_flight_prevents_its_late_publication
    with_inflight_child(after_open: true) do |worker, child, resume, stopped, _env, _root|
      Children.release("conv-1", log: nil)
      assert stopped.pop(timeout: 3)
      resume << true
      assert worker.join(3)
      assert_kind_of Rho::AcpClient::Refused, worker.value
      assert_empty Children.sessions
      assert_equal 0, Children.children_of("plain")
      refute process_group_alive?(child.group_pid)
    end
  end

  private

    def acquire(env, root)
      Children.acquire(RhoAcpClientTest.row("plain"), conversation: "conv-1", cwd: root, workdir_given: false,
        session: nil, env: env, artifacts_dir: env.ensure_artifacts_dir!, log: nil, clock: -> { Time.now })
    end

    def with_inflight_child(after_open: false)
      with_tool_env do |env, root, context|
        entered = Queue.new
        resume = Queue.new
        stopped = Queue.new
        constructor = Children::Child.method(:new)
        first = true
        factory = lambda do |*args, **kwargs|
          constructor.call(*args, **kwargs).tap do |child|
            next unless first

            first = false
            child.define_singleton_method(after_open ? :open_session : :spawn!) do |**options|
              result = super(**options) if after_open
              entered << self
              resume.pop
              after_open ? result : super(**options)
            end
            child.define_singleton_method(:stop!) do |**options|
              super(**options).tap { stopped << true }
            end
          end
        end
        Children::Child.define_singleton_method(:new, &factory)
        begin
          worker = Thread.new do
            Rho::Runner::ExecutionContext.with(context) { acquire(env, root) }
          rescue Rho::AcpClient::Error => error
            error
          end
          child = entered.pop(timeout: 3)
          refute_nil child, "the admitted child has reached process creation"
          yield worker, child, resume, stopped, env, root
        ensure
          Children::Child.singleton_class.remove_method(:new)
          resume << true
          worker&.join(3)
          child&.kill!
        end
      end
    end
end
