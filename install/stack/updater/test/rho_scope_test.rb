require_relative "updater_test"
require_relative "docker_test"

class UpdaterTest
  def test_rho_upgrade_preserves_nexus_and_skips_every_database_effect
    checked = check(scope: "rho")
    assert_equal ["rho"], checked.fetch("sources").map { |image| image.fetch("name") }
    assert_equal false, checked.dig("preflight", "backup")
    request = upgrade_request(scope: "rho")
    accepted = @engine.call(request)
    assert_equal 202, accepted.fetch("status")
    @engine.wait
    receipt = current_receipt(scope: "rho")
    assert_equal "succeeded", receipt.fetch("status")
    assert_equal false, receipt.fetch("backup")
    assert_nil receipt.fetch("migrator_name")
    assert_nil receipt.fetch("database_backup")
    effects = @docker.calls.reject { |call| [:installed, :check].include?(call.first) }
    assert_equal [:prepare, :stop, :activate, :verify], effects.map(&:first)
    assert_includes effects, [:stop, "rho"]
    pins = File.read(File.join(@directory, "images.env"))
    assert_includes pins, @installed.reference("nexus")
    assert_includes pins, @candidate.reference("rho")
    restart
    count = @docker.calls.length
    replay = @engine.call(request)
    assert_equal receipt.fetch("id"), replay.dig("data", "id")
    assert_equal "succeeded", replay.dig("data", "status")
    assert_equal count, @docker.calls.length
    %w[receipt log resume].each do |operation|
      answer = @engine.call("operation" => operation, "scope" => "nexus", "operation_id" => receipt.fetch("id"))
      assert_equal 404, answer.fetch("status")
    end
  end

  def test_rho_scope_rejects_database_backup_and_foreign_targets
    assert_equal 400, @engine.call("operation" => "check", "scope" => "rho", "backup" => true).fetch("status")
    check(scope: "rho")
    request = upgrade_request(scope: "rho")
    assert_equal 400, @engine.call(request.merge("backup" => true)).fetch("status")
    assert_equal 400, @engine.call(request.merge("candidate" => @candidate.selection)).fetch("status")
    refute @docker.calls.any? { |call| call.first == :stop }
  end

  def test_rho_activation_failure_resumes_the_same_receipt_without_database_work
    check(scope: "rho")
    @docker.failure = :activate
    accept(scope: "rho")
    @engine.wait
    receipt = current_receipt(scope: "rho")
    assert_equal "failed", receipt.fetch("status")
    refute_includes receipt.fetch("recovery"), "migration"
    restart
    @docker.failure = nil
    assert_equal 202, @engine.call("operation" => "resume", "operation_id" => receipt.fetch("id")).fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt(scope: "rho").fetch("status")
    refute @docker.calls.any? { |call| [:backup, :migrate, :migration_status].include?(call.first) }
  end

  def test_rho_shares_the_installation_lock_while_hiding_foreign_receipts
    check(scope: "nexus")
    @docker.prepare_entered = Queue.new
    @docker.prepare_release = Queue.new
    accept(scope: "nexus")
    @docker.prepare_entered.pop
    checked = check(scope: "rho")
    refute checked.dig("preflight", "ready")
    assert_nil checked.fetch("active_operation")
    result = accept(scope: "rho")
    assert_equal "upgrade_in_progress", result.dig("error", "code")
    refute result.fetch("error").key?("operation_id")
  end
end

class UpdaterDockerTest
  def test_rho_upgrade_manages_only_rho_without_requiring_postgresql_or_nexus_health
    @command.database_failed = true
    @command.disk_bytes = 0
    @command.versions["nexus"] = "independent-release"
    @command.containers.fetch("nexus").fetch("State").fetch("Health")["Status"] = "unhealthy"
    previous_nexus = JSON.parse(JSON.generate(@command.containers.fetch("nexus")))
    inspection = @docker.preflight("latest", backup_directory: File.join(@directory, "backups"), scope: "rho", backup: false)
    assert inspection.preflight.ready?
    refute inspection.preflight.checks.any? { |check| ["PostgreSQL", "Backup storage"].include?(check.name) }
    target = inspection.candidate
    assert_equal ["rho"], target.images.map(&:name)
    @docker.prepare(target, log: @logger, backup: false)
    @docker.stop(log: @logger, scope: "rho")
    @docker.activate(target, log: @logger)
    @docker.verify(target)
    commands = @command.calls.map(&:first)
    assert_equal ["rho"], commands.select { |arguments| arguments.include?("stop") }.map(&:last)
    starts = commands.select { |arguments| arguments.include?("up") }
    assert_equal 1, starts.length
    assert_equal "rho", starts.first.last
    refute commands.any? { |arguments| arguments.include?("psql") || arguments.include?("pg_dumpall") || arguments.include?("run") }
    assert_equal previous_nexus, @command.containers.fetch("nexus")
    refute @command.calls.any? { |_arguments, options| options.fetch(:environment, {}).key?("CYBROS_NEXUS_IMAGE") }
  end
end
