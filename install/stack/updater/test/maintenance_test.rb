require_relative "updater_test"
require_relative "docker_test"

class UpdaterTest
  def test_nexus_drains_before_stopping_and_resumes_before_verification
    check(scope: "nexus")
    accept(scope: "nexus")
    @engine.wait
    assert_equal "succeeded", current_receipt(scope: "nexus").fetch("status")
    effects = @docker.calls.map(&:first).reject { |name| [:installed, :check].include?(name) }
    assert_equal [:prepare, :drain, :stop, :backup, :migrate, :activate, :resume_execution, :verify], effects
  end

  def test_unknown_drain_outcome_retains_recovery_and_never_stops_services
    check(scope: "nexus")
    @docker.failure = :drain
    accept(scope: "nexus")
    @engine.wait
    receipt = current_receipt(scope: "nexus")
    assert_equal "failed", receipt.fetch("status")
    assert_equal "draining", receipt.fetch("phase")
    refute @docker.calls.any? { |call| [:stop, :migrate, :resume_execution].include?(call.first) }
    restart
    assert_equal "recovery_required", @engine.call("operation" => "assert_idle").dig("error", "code")
    @docker.failure = nil
    assert_equal 202, @engine.call("operation" => "resume", "operation_id" => receipt.fetch("id")).fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt(scope: "nexus").fetch("status")
    assert_equal 1, @docker.calls.count { |call| call.first == :migrate }
  end

  def test_confirmed_drain_timeout_retains_services_and_allows_a_new_checked_upgrade
    original_drain = @docker.method(:drain)
    command = use_expired_drain
    check(scope: "nexus")
    accept(scope: "nexus")
    @engine.wait
    receipt = current_receipt(scope: "nexus")
    assert_equal "failed", receipt.fetch("status")
    assert_equal "preparing", receipt.fetch("phase")
    assert_equal "drain_refused", receipt.dig("error", "code")
    assert_equal 200, @engine.call("operation" => "assert_idle").fetch("status")
    assert command.calls.any? { |arguments, _options| arguments.last.include?("Maintenance.resume") }
    refute @docker.calls.any? { |call| [:stop, :backup, :migrate, :activate].include?(call.first) }
    refute File.exist?(File.join(@directory, "images.env"))

    restart
    assert_equal "preparing", current_receipt(scope: "nexus").fetch("phase")
    assert_equal 200, @engine.call("operation" => "assert_idle").fetch("status")
    @docker.define_singleton_method(:drain, original_drain)
    assert check(scope: "nexus").dig("preflight", "ready")
    assert_equal 202, accept(scope: "nexus").fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt(scope: "nexus").fetch("status")
    refute_equal receipt.fetch("id"), current_receipt(scope: "nexus").fetch("id")
  end

  def test_unknown_timeout_release_keeps_the_drain_receipt_blocking_recovery
    command = use_expired_drain
    command.maintenance_failure = "resume"
    check(scope: "nexus")
    accept(scope: "nexus")
    @engine.wait
    receipt = current_receipt(scope: "nexus")
    assert_equal "failed", receipt.fetch("status")
    assert_equal "draining", receipt.fetch("phase")
    assert_equal "command_timeout", receipt.dig("error", "code")
    assert CybrosUpdater::Receipt.from_h(receipt).needs_recovery?
    refute @docker.calls.any? { |call| [:stop, :backup, :migrate, :activate].include?(call.first) }
    refute File.exist?(File.join(@directory, "images.env"))

    restart
    assert_equal "draining", current_receipt(scope: "nexus").fetch("phase")
    assert_equal "recovery_required", @engine.call("operation" => "assert_idle").dig("error", "code")
    assert_equal "recovery_required", accept(scope: "nexus").dig("error", "code")
  end

  def test_failed_execution_resume_recovers_without_repeating_migration
    check(scope: "nexus")
    @docker.failure = :resume_execution
    accept(scope: "nexus")
    @engine.wait
    receipt = current_receipt(scope: "nexus")
    assert_equal "failed", receipt.fetch("status")
    assert_equal "resuming", receipt.fetch("phase")
    @docker.failure = nil
    restart
    assert_equal 202, @engine.call("operation" => "resume", "operation_id" => receipt.fetch("id")).fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt(scope: "nexus").fetch("status")
    assert_equal 1, @docker.calls.count { |call| call.first == :migrate }
  end

  private

  def use_expired_drain
    repositories = { "nexus" => "registry.example/nexus", "rho" => "registry.example/rho" }
    command = UpdaterDockerTest::FakeCommand.new(repositories)
    command.maintenance_documents = [{ "active" => true, "drained" => false,
      "model_attempts" => 0, "claimed_tools" => 1, "kernel_tools" => 0, "authorization_exchanges" => 0 }]
    adapter = CybrosUpdater::Docker.new(directory: @directory, repositories: repositories, command: command)
    @docker.define_singleton_method(:drain) do |log:|
      calls << [:drain]
      adapter.drain(log: log, timeout: 0, poll_interval: 0)
    end
    command
  end
end

class UpdaterDockerTest
  def test_draining_keeps_http_and_workers_running_until_claimed_work_finishes
    @command.maintenance_documents = [
      { "active" => true, "drained" => false, "model_attempts" => 1, "claimed_tools" => 1, "kernel_tools" => 0, "authorization_exchanges" => 0 },
      { "active" => true, "drained" => true, "model_attempts" => 0, "claimed_tools" => 0, "kernel_tools" => 0, "authorization_exchanges" => 0 },
    ]
    @docker.drain(log: @logger, poll_interval: 0)
    assert @command.containers.values.all? { |container| container.fetch("State").fetch("Running") }
    commands = @command.calls.map(&:first)
    assert_equal 2, commands.count { |arguments| arguments.include?("runner") }
    refute commands.any? { |arguments| arguments.include?("stop") }
    @docker.resume_execution(log: @logger)
    assert_includes @log, "Execution resumed"
  end

  def test_drain_timeout_releases_the_gate_before_refusing_the_upgrade
    @command.maintenance_documents = [
      { "active" => true, "drained" => false, "model_attempts" => 0, "claimed_tools" => 1, "kernel_tools" => 0, "authorization_exchanges" => 0 },
    ]
    failure = assert_raises(CybrosUpdater::Error) { @docker.drain(log: @logger, timeout: 0, poll_interval: 0) }
    assert_equal "drain_refused", failure.code
    assert @command.calls.any? { |arguments, _options| arguments.last.include?("Maintenance.resume") }
    refute @command.calls.any? { |arguments, _options| arguments.include?("stop") }
  end

  def test_drain_timeout_cannot_report_safe_refusal_when_the_gate_remains_active
    @command.maintenance_documents = [
      { "active" => true, "drained" => false, "model_attempts" => 0, "claimed_tools" => 1, "kernel_tools" => 0, "authorization_exchanges" => 0 },
      { "active" => true },
    ]
    failure = assert_raises(CybrosUpdater::Error) { @docker.drain(log: @logger, timeout: 0, poll_interval: 0) }
    assert_equal "resume_failed", failure.code
    refute_includes @log, "Execution resumed"
    assert @command.containers.values.all? { |container| container.fetch("State").fetch("Running") }
  end

  def test_execution_idle_check_refuses_active_work_without_preparing_maintenance
    @command.maintenance_documents = [{ "active_work" => true }]
    failure = assert_raises(CybrosUpdater::Error) { @docker.assert_execution_idle }
    assert_equal "active_work", failure.code
    @command.maintenance_documents = [{ "active_work" => false }]
    assert_nil @docker.assert_execution_idle
    assert @command.calls.all? { |arguments, _options| arguments.last.include?("Maintenance.status") }
    assert @command.containers.values.all? { |container| container.fetch("State").fetch("Running") }
  end

  def test_execution_idle_cli_returns_failure_for_active_work_without_an_updater_session
    [false, true].each do |active|
      @command.maintenance_documents = [{ "active_work" => active }]
      output = StringIO.new
      errors = StringIO.new
      command = CybrosUpdater::CLI.new(["assert-execution-idle"], environment: { "CYBROS_INSTALL_DIR" => @directory }, output: output, errors: errors)
      adapter = @docker
      command.define_singleton_method(:docker) { |_directory| adapter }
      assert_equal active ? 1 : 0, command.run
      assert_empty output.string
      if active
        assert_includes errors.string, "active_work:"
      else
        assert_empty errors.string
      end
    end
    assert @command.calls.all? { |arguments, _options| arguments.last.include?("Maintenance.status") }
    refute File.exist?(File.join(@directory, "data", "updater"))
  end

  def test_unavailable_maintenance_is_refused_before_any_service_stops
    @command.maintenance_failure = "prepare"
    failure = assert_raises(CybrosUpdater::Error) { @docker.drain(log: @logger) }
    assert_equal "command_timeout", failure.code
    assert_equal 1, @command.calls.size
    assert @command.containers.values.all? { |container| container.fetch("State").fetch("Running") }
  end
end
