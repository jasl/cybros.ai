require_relative "updater_test"
require_relative "docker_test"

class UpdaterTest
  def test_disabled_backup_skips_dump_and_survives_restart_and_replay
    inspected = @engine.call("operation" => "check", "backup" => false)
    assert_equal false, inspected.dig("data", "preflight", "backup")
    request = upgrade_request.merge("backup" => false)
    assert_equal 202, @engine.call(request).fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt.fetch("status")
    assert_equal false, current_receipt.fetch("backup")
    assert_nil current_receipt.fetch("database_backup")
    refute @docker.calls.any? { |call| call.first == :backup }
    assert_includes @docker.calls, [:prepare, @candidate.selection, false]
    restart
    assert_equal false, current_receipt.fetch("backup")
    assert_equal 202, @engine.call(request).fetch("status")
    assert_equal "idempotency_conflict", @engine.call(request.merge("backup" => true)).dig("error", "code")
  end

  def test_backup_choice_must_match_the_preflight
    check
    assert_equal "preflight_failed", @engine.call(upgrade_request.merge("backup" => false)).dig("error", "code")
    refute @docker.calls.any? { |call| call.first == :stop }
  end

  def test_backup_choice_rejects_non_boolean_values
    [nil, "false", 0].each do |value|
      assert_equal 400, @engine.call("operation" => "check", "backup" => value).fetch("status")
      assert_equal 400, @engine.call(upgrade_request.merge("backup" => value)).fetch("status")
    end
  end

  def test_older_saved_preflight_and_receipts_keep_the_original_mandatory_backup
    check
    accept
    @engine.wait
    document = @store.load
    document.fetch("preflight").delete("backup")
    document.fetch("receipts").each { |receipt| receipt.delete("backup") }
    @store.atomic_write(File.join(@directory, "data", "updater", "state.json"), JSON.generate(document))
    restart
    assert_equal true, @engine.call("operation" => "status").dig("data", "preflight", "backup")
    assert_equal true, current_receipt.fetch("backup")
  end

  def test_resume_without_backup_keeps_the_frozen_choice
    @engine.call("operation" => "check", "backup" => false)
    @docker.failure = :stop
    @engine.call(upgrade_request.merge("backup" => false))
    @engine.wait
    id = current_receipt.fetch("id")
    restart
    @docker.failure = nil
    assert_equal 202, @engine.call("operation" => "resume", "operation_id" => id).fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt.fetch("status")
    refute @docker.calls.any? { |call| call.first == :backup }
  end
end

class UpdaterDockerTest
  def test_disabled_backup_skips_storage_budget_but_still_checks_database
    @command.disk_bytes = 0
    inspection = @docker.preflight("latest", backup_directory: File.join(@directory, "backups"), backup: false)
    assert inspection.preflight.ready?
    assert_equal false, inspection.preflight.backup
    refute inspection.preflight.checks.any? { |check| check.name == "Backup storage" }
    @docker.prepare(inspection.candidate, log: ->(_text) { }, backup: false)
    refute @command.calls.any? { |arguments, options| options[:executable] == "df" || arguments.any? { |argument| argument.include?("pg_database_size") } }
    @command.database_failed = true
    refute @docker.preflight("latest", backup_directory: File.join(@directory, "backups"), backup: false).preflight.ready?
  end
end
