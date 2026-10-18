require "minitest/autorun"
require "bundler"
require "fileutils"
require "json"
require "net/http"
require "rbconfig"
require "tmpdir"

class PumaPresenceTest < Minitest::Test
  ROOT = File.expand_path("../..", __dir__)

  # Exercise the real initializer, lifecycle, timer and Puma Rack handler.
  # Only the database boundary is replaced with per-process event recording.
  ENVIRONMENT = <<~'RUBY'.freeze
    require "active_support"
    require "active_support/core_ext/numeric/time"
    require "active_support/ordered_options"
    require "concurrent/timer_task"
    require "json"
    require "securerandom"

    module Rails
      class Executor
        def wrap
          yield
        end
      end

      Configuration = Data.define(:x)
      Application = Data.define(:config, :executor)

      def self.application
        @application ||= Application.new(
          config: Configuration.new(x: ActiveSupport::OrderedOptions.new),
          executor: Executor.new
        )
      end
    end

    class ApplicationRecord
      def self.scope(*) = nil
    end

    load File.join(ENV.fetch("NEXUS_SOURCE_ROOT"), "app/models/nexus_server.rb")
    load File.join(ENV.fetch("NEXUS_SOURCE_ROOT"), "config/initializers/nexus_server.rb")

    NexusServer.send(:remove_const, :HEARTBEAT_INTERVAL)
    NexusServer.const_set(:HEARTBEAT_INTERVAL, 1)

    class << NexusServer
      def register = record("registered")
      def heartbeat = record("heartbeat")
      def deregister = record("deregistered")

      def record(event)
        line = JSON.generate(event: event, pid: Process.pid, boot_id: boot_id) + "\n"
        File.open(ENV.fetch("PRESENCE_EVENTS"), "a") { |file| file.write(line) }
      end
    end

    NexusServer.record("loaded")
  RUBY

  SERVER = <<~'RUBY'.freeze
    require "bundler/setup"
    require "rackup"
    require "rack/handler/puma"
    require_relative "config/environment"

    app = ->(_env) do
      body = JSON.generate(pid: Process.pid, boot_id: NexusServer.boot_id)
      [200, { "content-type" => "application/json" }, [body]]
    end
    Rackup::Handler::Puma.run(app, Host: "127.0.0.1", Port: 0)
  RUBY

  def test_single_server_keeps_its_socket_identity_until_restart_or_stop
    with_server("0") do |pid|
      registered = wait_for { events("registered").first }
      assert_equal pid, registered.fetch("pid")
      assert_equal events("loaded").first.fetch("boot_id"), registered.fetch("boot_id")
      wait_for { events("heartbeat").any? }
      assert_equal registered.fetch("boot_id"), request.fetch("boot_id")

      Process.kill("USR2", pid)
      restarted = wait_for { rows = events("registered"); rows.last if rows.size >= 2 }
      refute_equal registered.fetch("boot_id"), restarted.fetch("boot_id")
      assert_equal pid, restarted.fetch("pid")
      assert_equal [registered.fetch("boot_id")], events("deregistered").map { |event| event.fetch("boot_id") }
      wait_for { events("heartbeat").any? { |event| event.fetch("boot_id") == restarted.fetch("boot_id") } }
      assert_equal restarted.fetch("boot_id"), request.fetch("boot_id")

      stop_server(pid)

      expected_ids = [registered.fetch("boot_id"), restarted.fetch("boot_id")]
      assert_equal expected_ids, events("registered").map { |event| event.fetch("boot_id") }
      assert_equal expected_ids, events("deregistered").map { |event| event.fetch("boot_id") }
    end
  end

  def test_workers_own_separate_heartbeats_and_replacement_does_not_deregister_a_sibling
    with_server("2") do |pid|
      registered = wait_for { rows = events("registered"); rows if rows.size >= 2 }
      assert_equal 2, registered.size
      worker_pids = registered.map { |event| event.fetch("pid") }
      worker_ids = registered.map { |event| event.fetch("boot_id") }
      assert_equal 2, worker_pids.uniq.size
      assert_equal 2, worker_ids.uniq.size
      refute_includes worker_pids, pid
      refute_includes worker_ids, events("loaded").first.fetch("boot_id")
      wait_for { (worker_pids - events("heartbeat").map { |event| event.fetch("pid") }).empty? }
      assert_includes worker_ids, request.fetch("boot_id")

      victim, sibling = worker_pids
      Process.kill("TERM", victim)
      replacement = wait_for { events("registered").find { |event| !worker_pids.include?(event.fetch("pid")) } }
      wait_for { events("deregistered").any? { |event| event.fetch("pid") == victim } }
      refute_includes worker_ids, replacement.fetch("boot_id")
      assert_equal [victim], events("deregistered").map { |event| event.fetch("pid") }
      sibling_ticks = events("heartbeat").count { |event| event.fetch("pid") == sibling }
      wait_for { events("heartbeat").count { |event| event.fetch("pid") == sibling } > sibling_ticks }
      wait_for { events("heartbeat").any? { |event| event.fetch("pid") == replacement.fetch("pid") } }

      stop_server(pid)

      assert_equal events("registered").map { |event| event.fetch("boot_id") }.sort,
        events("deregistered").map { |event| event.fetch("boot_id") }.sort
    end
  end

  private

    def with_server(workers)
      Dir.mktmpdir("nexus-puma-presence-") do |directory|
        @events_path = File.join(directory, "events.jsonl")
        @log_path = File.join(directory, "puma.log")
        FileUtils.mkdir_p(File.join(directory, "config"))
        FileUtils.cp(File.join(ROOT, "config/puma.rb"), File.join(directory, "config/puma.rb"))
        File.write(File.join(directory, "config/environment.rb"), ENVIRONMENT)
        File.write(File.join(directory, "server.rb"), SERVER)
        environment = Bundler.unbundled_env.merge(
          "BUNDLE_GEMFILE" => File.join(ROOT, "Gemfile"), "NEXUS_SOURCE_ROOT" => ROOT,
          "PRESENCE_EVENTS" => @events_path, "RAILS_ENV" => "production",
          "WEB_CONCURRENCY" => workers, "RAILS_MAX_THREADS" => "1",
          "SOLID_QUEUE_IN_PUMA" => "false", "PIDFILE" => nil,
        )
        pid = Process.spawn(environment, RbConfig.ruby, "server.rb", chdir: directory,
          out: @log_path, err: [:child, :out], pgroup: true, unsetenv_others: true)
        yield pid
      ensure
        if pid
          begin
            unless Process.waitpid(pid, Process::WNOHANG)
              Process.kill("KILL", -pid)
              Process.wait(pid)
            end
          rescue Errno::ECHILD
          end
        end
      end
    end

    def events(kind)
      return [] unless File.exist?(@events_path)

      File.readlines(@events_path).filter_map do |line|
        next unless line.end_with?("\n")

        event = JSON.parse(line)
        event if event.fetch("event") == kind
      end
    end

    def request
      url = wait_for { File.read(@log_path)[%r{Listening on (http://127\.0\.0\.1:\d+)}, 1] }
      response = Net::HTTP.get_response(URI(url))
      assert_equal "200", response.code
      JSON.parse(response.body)
    end

    def stop_server(pid)
      Process.kill("TERM", pid)
      wait_for { Process.waitpid(pid, Process::WNOHANG) }
      assert $?.success? || $?.termsig == Signal.list.fetch("TERM"), File.read(@log_path)
    end

    def wait_for
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 15
      loop do
        value = yield
        return value if value

        flunk "Puma presence condition timed out:\n#{File.read(@log_path)}" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline
        sleep 0.05
      end
    end
end
