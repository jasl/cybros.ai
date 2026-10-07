require "test_helper"
require "cybros_agent/realtime"

class DaemonExecutorRecoveryTest < Minitest::Test
  class Connection
    attr_reader :identifier

    def initialize
      @incoming = Async::Queue.new
      @incoming.enqueue(JSON.generate({ "type" => "welcome" }))
    end

    def read = @incoming.dequeue

    def write(text)
      command = JSON.parse(text)
      if command["command"] == "subscribe"
        @identifier = command.fetch("identifier")
        @incoming.enqueue(JSON.generate({ "type" => "confirm_subscription", "identifier" => @identifier }))
      end
    end

    def flush = nil
    def framer = self
    def close = @incoming.enqueue(nil)

    def cancel(key)
      @incoming.enqueue(JSON.generate({ "identifier" => @identifier, "message" => {
        "event" => { "type" => "work_canceled", "run_public_id" => "run-1", "task_key" => key },
      } }))
    end
  end

  class Client < CybrosAgent::Realtime::Client
    attr_reader :connections, :attempts

    def initialize(fail_first: false, **options)
      super(**options)
      @connections = []
      @attempts = 0
      @fail_first = fail_first
    end

    private

      def open_connection
        @attempts += 1
        raise CybrosAgent::TransportError, "connection unavailable" if @fail_first && @attempts == 1

        Connection.new.tap { |connection| @connections << connection }
      end
  end

  class Runner
    attr_reader :canceled

    def initialize = @canceled = []
    def cancel(**fields) = @canceled << fields
  end

  class Context < Rho::Daemon::Context
    def initialize(task) = @task = task
    def spawn(&block) = @task.async(&block)
  end

  def test_a_lost_executor_connection_recovers_and_delivers_later_cancellation
    with_plane do |task, plane, lineage, about, client, runner|
      following = task.async { plane.nudge_stream(about) }
      await { client.connections.first&.identifier }
      client.connections.first.close

      await { client.connections[1]&.identifier }
      client.connections.last.cancel("task-1")
      await { runner.canceled.any? }

      assert_equal [{ run_public_id: "run-1", task_key: "task-1" }], runner.canceled
      assert_same client, lineage.executor_realtime
      assert_same runner, lineage.runner
      assert_equal 2, client.attempts
      refute following.finished?
    end
  end

  def test_a_transient_handshake_failure_does_not_end_the_executor_listener
    with_plane(fail_first: true) do |task, plane, _lineage, about, client, runner|
      task.async { plane.nudge_stream(about) }
      await { client.connections.first&.identifier }
      client.connections.first.cancel("task-2")
      await { runner.canceled.any? }

      assert_equal 2, client.attempts
      assert_equal "task-2", runner.canceled.first.fetch(:task_key)
    end
  end

  def test_retirement_during_recovery_does_not_reopen_the_old_credential
    with_plane do |task, plane, lineage, about, client, _runner|
      following = task.async { plane.nudge_stream(about) }
      await { client.connections.first&.identifier }
      client.connections.first.close
      await { !client.connected? }
      lineage.retire_runs.clients.each(&:close)

      task.with_timeout(7) { following.wait }

      assert_equal 1, client.attempts
      assert_nil lineage.executor_realtime
    end
  end

  private

    def with_plane(fail_first: false)
      Sync do |task|
        client = Client.new(fail_first: fail_first,
          endpoint: CybrosAgent::Realtime::Endpoint.new(base_url: "http://kernel.test", credential: "runner-token"))
        lineage = Rho::Daemon::Lineage.new(clock: -> { Time.now }, realtime_factory: ->(_credential) { client })
        about = Object.new
        about.define_singleton_method(:runner) { self }
        about.define_singleton_method(:runner_credential) { "runner-token" }
        lineage.adopt(identity: RhoTest::DaemonHarness::RUNNER_IDENTITY, credentials: about)
        runner = Runner.new
        lineage.reserve_runner(about)
        lineage.install_runner(about, runner, nil)
        plane = Rho::Daemon::ExecutorPlane.new(
          wire: Rho::Daemon::Wire.new(base_url: "http://kernel.test"), lineage: lineage, context: Context.new(task),
          log: Rho::Log.new(io: StringIO.new))
        yield task, plane, lineage, about, client, runner
      ensure
        lineage&.retire_runs&.clients&.each(&:close)
        task&.children&.each(&:stop)
      end
    end

    def await
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 7
      until yield
        flunk "executor listener did not recover" if Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        Kernel.sleep(0.01)
      end
    end
end
