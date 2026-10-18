require "test_helper"
require "open3"
require "net/http"
require "rbconfig"
require "stringio"
require "tmpdir"
require "support/mock_llm/stack_upgrade"
require "support/mock_llm/server"
require "support/process_runner"
require "support/stack_installation_upgrade"

class StackInstallationHarnessTest < Minitest::Test
  class ReceiptActor
    include Minitest::Assertions
    include E2E::StackInstallationUpgrade
    UPGRADE_WAIT = 1
    attr_accessor :assertions

    def initialize(stack, receipt)
      @stack = stack
      @receipt = receipt
      @assertions = 0
    end

    private

      def command_output(*) = JSON.generate(@receipt)
      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      def release_active_work_during_drain(*) = flunk("rho must not run Nexus drain fixtures")
  end

  def test_installation_driver_accepts_the_native_builder_inspect_output
    output, status, calls = run_installation_driver(driver: "docker")

    assert_equal 1, status.exitstatus
    assert_includes output, "Run bundle install in e2e first"
    assert_includes calls, ["docker", "buildx", "inspect", "stack-fixture"]
    assert_includes calls, ["bundle", "check"]
  end

  def test_installation_driver_rejects_a_non_native_builder_before_installing
    output, status, calls = run_installation_driver(driver: "docker-container")

    assert_equal 1, status.exitstatus
    assert_includes output, "Use the selected context native Docker builder"
    assert_equal ["docker", "buildx", "inspect", "stack-fixture"], calls.last
  end

  def test_installation_driver_stops_when_builder_inspection_fails
    output, status, calls = run_installation_driver(driver: "docker", inspect_status: 23)

    assert_equal 23, status.exitstatus
    refute_includes output, "Run bundle install in e2e first"
    assert_equal ["docker", "buildx", "inspect", "stack-fixture"], calls.last
  end

  def test_rho_upgrade_accepts_its_receipt_without_draining_or_replacing_an_existing_database_backup
    Dir.mktmpdir do |root|
      directory = File.join(root, "backups", "databases")
      FileUtils.mkdir_p(directory)
      backup = File.join(directory, "earlier-nexus.sql")
      File.write(backup, "synthetic Nexus backup\n")
      receipt = { "id" => "01990000-0000-7000-8000-000000000001", "target" => {
        "release" => "2610111200", "images" => [{ "name" => "rho" }],
      }, "backup" => false, "database_backup" => nil, "status" => "succeeded", "phase" => "completed" }
      actor = ReceiptActor.new(root, receipt)

      assert_equal receipt, actor.send(:await_upgrade, receipt.fetch("id"), "2610111200", target: "rho")
      assert_equal "synthetic Nexus backup\n", File.read(backup)
    end
  end

  def test_a_failed_cli_worker_does_not_leave_the_other_command_running
    Dir.mktmpdir do |root|
      actor = upgrade_actor(root)
      pid_file = File.join(root, "provider.pid")
      provider = Thread.new do
        Thread.current.report_on_exception = false
        E2E::ProcessRunner.run(RbConfig.ruby, "-e",
          "File.write(ARGV.fetch(0), Process.pid); sleep 60", pid_file, timeout: 30)
      end
      wait_until { File.size?(pid_file) }
      pid = Integer(File.read(pid_file))
      active = failed_thread(Minitest::Assertion.new("the rho CLI failed"))
      actor.instance_variable_set(:@active_run, active)
      actor.instance_variable_set(:@provider_run, provider)

      error = assert_raises(Minitest::Assertion) { actor.send(:finish_active_upgrade_run) }

      assert_equal "the rho CLI failed", error.message
      refute provider.alive?, "cleanup must join or terminate every CLI worker"
      assert_raises(Errno::ESRCH) { Process.kill(0, -pid) }
      refute_path_exists File.join(root, "active")
    ensure
      provider&.kill
      provider&.join
    end
  end

  def test_cleanup_preserves_the_original_journey_failure
    Dir.mktmpdir do |root|
      actor = upgrade_actor(root)
      actor.instance_variable_set(:@active_run, failed_thread(RuntimeError.new("secondary CLI failure")))

      error = assert_raises(ArgumentError) do
        begin
          raise ArgumentError, "the upgrade failed"
        ensure
          actor.send(:finish_active_upgrade_run)
        end
      end

      assert_equal "the upgrade failed", error.message
      refute_path_exists File.join(root, "active")
    end
  end

  def test_provider_gate_preserves_the_body_and_counts_every_request
    Dir.mktmpdir do |root|
      app = E2E::MockLLM::StackUpgrade.new(E2E::MockLLM::App.new, directory: root)
      body = JSON.generate(model: "mock-text", input:
        "!mock reply=Provider+body+survived. -- #{E2E::MockLLM::StackUpgrade::MARKER}")
      worker = Thread.new { app.call(request(body)) }
      requests = File.join(root, "requests")
      wait_until { File.size?(requests) }

      assert_equal ["started"], File.readlines(requests, chomp: true)
      refute worker.join(0.05), "the actual provider request must remain held until drain releases it"
      File.write(File.join(root, "release"), "finish\n")
      assert worker.join(2), "the held request did not resume"
      status, _, response = worker.value
      assert_equal 200, status
      assert_equal "Mock: Provider body survived.", completed_text(response)

      status, _, response = app.call(request(body))
      assert_equal 200, status
      assert_equal "Mock: Provider body survived.", completed_text(response)
      assert_equal ["started", "started"], File.readlines(requests, chomp: true),
        "a repeated provider request must remain visible after the gate opens"
    ensure
      worker&.kill
      worker&.join
    end
  end

  def test_unrelated_provider_requests_do_not_wait_on_the_upgrade_fixture
    Dir.mktmpdir do |root|
      app = E2E::MockLLM::StackUpgrade.new(E2E::MockLLM::App.new, directory: root)
      status, _, body = app.call(request(JSON.generate(model: "mock-text", input: "ordinary input")))

      assert_equal 200, status
      assert_equal "Mock: ordinary input", completed_text(body)
      refute_path_exists File.join(root, "requests")
    end
  end

  def test_a_local_provider_holds_concurrent_http_requests_until_the_journey_releases_them
    Dir.mktmpdir do |root|
      app = E2E::MockLLM::StackUpgrade.new(E2E::MockLLM::App.new, directory: root)
      server = E2E::MockLLM::Server.new(app: app).start
      uri = URI("#{server.base_url}/v1/responses")
      workers = 2.times.map do |index|
        Thread.new do
          Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 3) do |http|
            http.post(uri.path, JSON.generate(model: "mock-text", input:
              "!mock reply=Held+reply+#{index} -- #{E2E::MockLLM::StackUpgrade::MARKER}"),
              "Content-Type" => "application/json")
          end
        end
      end
      requests = File.join(root, "requests")
      wait_until { File.file?(requests) && File.readlines(requests).length == 2 }

      workers.each { |worker| refute worker.join(0.05), "the provider must not answer before release" }
      File.write(File.join(root, "release"), "finish\n")
      workers.each_with_index do |worker, index|
        assert worker.join(2), "the released HTTP request did not finish"
        response = worker.value
        assert_equal "200", response.code
        assert_equal "Mock: Held reply #{index}", completed_text([response.body])
      end
      assert_equal ["started", "started"], File.readlines(requests, chomp: true)
    ensure
      File.write(File.join(root, "release"), "finish\n")
      workers&.each { |worker| worker.join(2) || worker.kill.join }
      server&.stop
    end
  end

  private

    def run_installation_driver(driver:, inspect_status: 0)
      Dir.mktmpdir("stack-driver") do |root|
        commands = File.join(root, "commands.jsonl")
        executable = <<~RUBY
          #!#{RbConfig.ruby}
          require "json"
          command = File.basename($PROGRAM_NAME)
          File.open(ENV.fetch("STACK_TEST_COMMANDS"), "a") { |file| file.puts(JSON.generate([command, *ARGV])) }
          if command == "bundle"
            abort "unexpected bundle arguments" unless ARGV == ["check"]
            exit 42
          end
          case ARGV
          when ["context", "show"]
            puts "stack-fixture"
          when ["context", "inspect", "stack-fixture", "--format", "{{.Endpoints.docker.Host}}"]
            puts "unix:///fixture/docker.sock"
          when ["info", "--format", "{{.OSType}}"]
            puts "linux"
          when ["buildx", "inspect", "stack-fixture"]
            puts "Name:          stack-fixture"
            puts "Driver:        " + ENV.fetch("STACK_TEST_DRIVER")
            puts "\\nNodes:\\nName:             stack-fixture"
            exit Integer(ENV.fetch("STACK_TEST_INSPECT_STATUS"))
          when ["compose", "version"]
            puts "Docker Compose fixture"
          else
            abort "unsupported docker arguments: " + ARGV.join(" ")
          end
        RUBY
        %w[docker bundle].each do |name|
          path = File.join(root, name)
          File.write(path, executable)
          File.chmod(0o755, path)
        end
        output, status = Open3.capture2e(
          { "PATH" => "#{root}:#{File.dirname(RbConfig.ruby)}:#{ENV.fetch("PATH")}", "DOCKER_HOST" => nil,
            "STACK_TEST_COMMANDS" => commands, "STACK_TEST_DRIVER" => driver,
            "STACK_TEST_INSPECT_STATUS" => inspect_status.to_s },
          "bash", File.expand_path("../manual/stack_installation.sh", __dir__), "2610111200",
        )
        [output, status, File.readlines(commands).map { |line| JSON.parse(line) }]
      end
    end

    def upgrade_actor(root)
      active = File.join(root, "active")
      provider = File.join(root, "provider")
      FileUtils.mkdir_p([active, provider])
      Object.new.extend(E2E::StackInstallationUpgrade).tap do |actor|
        actor.instance_variable_set(:@active_directory, active)
        actor.instance_variable_set(:@active_gate, File.join(active, "release"))
        actor.instance_variable_set(:@provider_directory, provider)
      end
    end

    def failed_thread(error)
      Thread.new do
        Thread.current.report_on_exception = false
        raise error
      end
    end

    def request(body)
      { "REQUEST_METHOD" => "POST", "PATH_INFO" => "/v1/responses", "rack.input" => StringIO.new(body) }
    end

    def completed_text(body)
      events = body.to_a.join.split("\n\n").filter_map do |frame|
        data = frame.delete_prefix("data: ").strip
        JSON.parse(data) unless data.empty? || data == "[DONE]"
      end
      events.last.fetch("response").fetch("output").fetch(0).fetch("content").fetch(0).fetch("text")
    end

    def wait_until
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 3
      until yield
        assert_operator Process.clock_gettime(Process::CLOCK_MONOTONIC), :<, deadline, "fixture did not become ready"
        sleep 0.01
      end
    end
end
