require "minitest/autorun"
require "tmpdir"
require "stringio"
require_relative "../updater"

class UpdaterTest < Minitest::Test
  class FakeDocker
    attr_accessor :failure, :prepare_entered, :prepare_release, :migration_success, :observed_release, :preflight_blocked
    attr_reader :calls

    def initialize(candidate, installed)
      @candidate = candidate
      @observed_release = installed
      @calls = []
      @migration_success = true
    end

    def installed(scope: "installation")
      @calls << [:installed, scope]
      select_products(@observed_release, scope)
    end

    def sources(scope: "installation")
      select_products(@candidate, scope).images.map { |image| image.with(reference: image.reference.split("@").first, version: nil) }
    end

    def check(tag, scope: "installation")
      @calls << [:check, tag, scope]
      fail_at(:check)
      select_products(@candidate, scope)
    end

    def preflight(tag, backup_directory:, scope: "installation", backup: true)
      candidate = nil
      begin
        candidate = check(tag, scope: scope)
        status = @preflight_blocked ? "blocked" : "passed"
        message = @preflight_blocked ? "Free backup space before upgrading." : "The installation is ready."
      rescue CybrosUpdater::Error => error
        status = "blocked"
        message = error.message
      end
      check = CybrosUpdater::PreflightCheck.new(name: "Installation", status: status, message: message, next_step: status == "blocked" ? "Repair and check again." : nil, available_bytes: nil, required_bytes: nil)
      CybrosUpdater::Inspection.new(candidate: candidate, installed: installed, preflight: CybrosUpdater::Preflight.new(scope: scope, backup: backup, checked_at: Time.now.utc.iso8601(6), checks: [check]))
    end

    def prepare(target, log:, backup: true)
      @calls << [:prepare, target.selection, backup]
      @prepare_entered&.push(true)
      @prepare_release&.pop
      log.call("Pulled selected images.\n")
      fail_at(:prepare)
    end

    def stop(log:, scope: "installation")
      @calls << [:stop, scope]
      log.call("Stopped application services.\n")
      fail_at(:stop)
    end

    def dump_database(file)
      @calls << [:backup]
      file.write("CREATE DATABASE preserved; -- private-database-content\n")
      fail_at(:backup)
    end

    def migrate(target, name:, log:)
      @calls << [:migrate, target.selection, name]
      log.call("Migration output.\n")
      fail_at(:migrate)
    end

    def migration_succeeded?(name)
      @calls << [:migration_status, name]
      @migration_success
    end

    def activate(target, log:)
      @calls << [:activate, target.selection]
      log.call("Activated selected images.\n")
      fail_at(:activate)
      images = @observed_release.images.to_h { |image| [image.name, image] }
      target.images.each { |image| images[image.name] = image }
      versions = images.values.map(&:version).uniq
      @observed_release = @observed_release.with(images: images.values, release: versions.size == 1 ? versions.first : nil)
    end

    def verify(target)
      @calls << [:verify, target.selection]
      fail_at(:verify)
    end

    private

    def select_products(release, scope)
      images = release.images.select { |image| CybrosUpdater::Docker.products(scope).include?(image.name) }
      versions = images.map(&:version).uniq
      release.with(images: images, release: versions.size == 1 ? versions.first : nil)
    end

    def fail_at(phase)
      if @failure == phase
        raise CybrosUpdater::Error.new("#{phase}_failed", "Injected #{phase} failure.")
      end
    end
  end

  def setup
    @directory = Dir.mktmpdir("updater installation ")
    File.write(File.join(@directory, ".env"), "# Custom configuration\n")
    File.write(File.join(@directory, "secrets.env"), "# Preserved private settings\n")
    FileUtils.mkdir_p(File.join(@directory, "data"))
    File.write(File.join(@directory, "data", "preserved"), "conversation, uploads and credentials")
    @candidate = release("2610080750", "a", "b")
    @installed = release("2610080748", "c", "d")
    @docker = FakeDocker.new(@candidate, @installed)
    @store = CybrosUpdater::Store.new(File.join(@directory, "data", "updater"))
    @engine = CybrosUpdater::Engine.new(directory: @directory, store: @store, docker: @docker)
  end

  def teardown
    @docker.prepare_release&.push(true)
    @engine.wait
    @store.close
    FileUtils.remove_entry(@directory)
  end

  def test_complete_upgrade_preserves_data_and_configuration_and_freezes_images
    checked = check
    assert_equal @candidate.to_h, checked.fetch("candidate")
    accepted = accept
    assert_equal 202, accepted.fetch("status")
    @engine.wait
    receipt = current_receipt
    assert_equal "succeeded", receipt.fetch("status")
    assert_equal "completed", receipt.fetch("phase")
    assert_equal @candidate.to_h, receipt.fetch("target")
    assert_equal @installed.to_h, receipt.fetch("previous")
    effects = @docker.calls.reject { |call| [:installed, :check].include?(call.first) }
    assert_equal [:prepare, :stop, :backup, :migrate, :activate, :verify], effects.map(&:first)
    assert_equal true, receipt.dig("database_backup", "available")
    assert_operator receipt.dig("database_backup", "size_bytes"), :>, 0
    assert_equal "# Custom configuration\n", File.read(File.join(@directory, ".env"))
    assert_equal "# Preserved private settings\n", File.read(File.join(@directory, "secrets.env"))
    assert_equal "conversation, uploads and credentials", File.read(File.join(@directory, "data", "preserved"))
    pins = File.read(File.join(@directory, "images.env"))
    assert_includes pins, @candidate.reference("nexus")
    assert_includes pins, @candidate.reference("rho")
    assert_equal 0o600, File.stat(File.join(@directory, "images.env")).mode & 0o777
    assert_equal File.stat(File.join(@directory, ".env")).uid, File.stat(File.join(@directory, "images.env")).uid
    assert_equal 200, @engine.call("operation" => "assert_idle").fetch("status")
  end

  def test_accepted_receipt_is_durable_before_docker_work_and_replayed_after_restart
    check
    @docker.prepare_entered = Queue.new
    @docker.prepare_release = Queue.new
    request = upgrade_request
    accepted = @engine.call(request)
    @docker.prepare_entered.pop
    disk = JSON.parse(File.read(File.join(@directory, "data", "updater", "state.json")))
    assert_equal accepted.dig("data", "id"), disk.fetch("receipts").last.fetch("id")
    assert_equal "preparing", disk.fetch("receipts").last.fetch("phase")
    assert_equal 0o600, File.stat(File.join(@directory, "data", "updater", "state.json")).mode & 0o777
    @docker.prepare_release.push(true)
    @engine.wait
    restart
    count = @docker.calls.length
    replay = @engine.call(request)
    assert_equal accepted.dig("data", "id"), replay.dig("data", "id")
    assert_equal "succeeded", replay.dig("data", "status")
    assert_equal count, @docker.calls.length
  end

  def test_concurrent_cli_and_browser_share_one_operation_and_reject_conflicts
    check
    @docker.prepare_entered = Queue.new
    @docker.prepare_release = Queue.new
    request = upgrade_request
    threads = 2.times.map { Thread.new { @engine.call(request) } }
    answers = threads.map(&:value)
    @docker.prepare_entered.pop
    assert_equal [202, 202], answers.map { |answer| answer.fetch("status") }
    assert_equal 1, answers.map { |answer| answer.dig("data", "id") }.uniq.size
    conflict = @engine.call(upgrade_request)
    assert_equal "upgrade_in_progress", conflict.dig("error", "code")
    assert_equal answers.first.dig("data", "id"), conflict.dig("error", "operation_id")
    altered = request.merge("actor_public_id" => SecureRandom.uuid_v7)
    assert_equal "idempotency_conflict", @engine.call(altered).dig("error", "code")
    assert_equal "upgrade_in_progress", @engine.call("operation" => "assert_idle").dig("error", "code")
    @docker.prepare_release.push(true)
    @engine.wait
    assert_equal 1, @docker.calls.count { |call| call.first == :migrate }
  end

  def test_status_is_local_and_check_refreshes_installed_release
    @docker.observed_release = release("2610080749", "e", "f")
    before = @docker.calls.dup
    data = @engine.call("operation" => "status").fetch("data")
    assert_equal @installed.release, data.dig("installed", "release")
    assert_equal "registry.example/team/nexus", data.fetch("sources").first.fetch("reference")
    assert_equal before, @docker.calls
    assert_equal "2610080749", check.dig("installed", "release")
  end

  def test_startup_and_explicit_refresh_observe_installed_images_without_registry_access
    @docker.observed_release = release("2610080749", "e", "f")
    restart
    assert_equal "2610080749", @engine.call("operation" => "status").dig("data", "installed", "release")
    @docker.observed_release = @candidate
    refreshed = @engine.call("operation" => "refresh_installed")
    assert_equal @candidate.release, refreshed.dig("data", "installed", "release")
    refute @docker.calls.any? { |call| call.first == :check }
  end

  def test_candidate_must_match_the_checked_pair_and_no_caller_path_reaches_docker
    check
    request = upgrade_request
    request.fetch("candidate").fetch("images").first["reference"] = "bad; touch /tmp/not-an-operation"
    assert_equal "candidate_changed", @engine.call(request).dig("error", "code")
    assert_empty @docker.calls.select { |call| call.first == :prepare }
    assert_equal "invalid_request", @engine.call("operation" => "check", "tag" => "latest; bad").dig("error", "code")
    assert_equal "invalid_request", @engine.call("operation" => "receipt", "operation_id" => "../../secrets.env").dig("error", "code")
  end

  def test_release_checks_reject_invalid_calendar_tags_before_registry_io
    @docker.calls.clear
    %w[1791439200 20261008075000 261008750 2613000750 2602290750 2604310750 2610082400 2610080760].each do |tag|
      result = @engine.call("operation" => "check", "tag" => tag)
      assert_equal 400, result.fetch("status"), tag
      assert_equal "invalid_request", result.dig("error", "code")
    end
    assert_empty @docker.calls

    %w[2610080750 0002292359 2402290000].each do |tag|
      assert_equal 200, @engine.call("operation" => "check", "tag" => tag).fetch("status"), tag
      assert_includes @docker.calls, [:check, tag, "installation"]
    end
  end

  def test_upgrade_rejects_invalid_calendar_release_before_acceptance
    check
    request = upgrade_request
    request.fetch("candidate")["release"] = "2602290750"
    @docker.calls.clear

    result = @engine.call(request)

    assert_equal 400, result.fetch("status")
    assert_equal "invalid_request", result.dig("error", "code")
    assert_nil current_receipt
    assert_empty @docker.calls
  end

  def test_failed_check_invalidates_candidate_without_mutating_services
    check
    @docker.failure = :check
    assert_equal 200, @engine.call("operation" => "check").fetch("status")
    assert_nil @engine.call("operation" => "status").dig("data", "candidate")
    assert_equal false, @engine.call("operation" => "status").dig("data", "preflight", "ready")
    refute @docker.calls.any? { |call| call.first == :stop }
  end

  def test_preflight_is_saved_with_blockers_and_status_does_not_repeat_io
    assert_nil @engine.call("operation" => "status").dig("data", "preflight")
    @docker.preflight_blocked = true
    data = check
    assert_equal @candidate.to_h, data.fetch("candidate")
    assert_equal false, data.dig("preflight", "ready")
    assert_equal "preflight_failed", accept.dig("error", "code")
    restart
    before = @docker.calls.dup
    assert_equal data.fetch("preflight"), @engine.call("operation" => "status").dig("data", "preflight")
    assert_equal before, @docker.calls
    @docker.preflight_blocked = false
    assert_equal true, check.dig("preflight", "ready")
  end

  def test_backup_failure_stops_before_migration_and_can_retry_explicitly
    check
    @docker.failure = :backup
    accept
    @engine.wait
    failed = current_receipt
    assert_equal "failed", failed.fetch("status")
    assert_equal "backing_up", failed.fetch("phase")
    assert_nil failed.fetch("database_backup")
    refute @docker.calls.any? { |call| call.first == :migrate }
    assert_equal "recovery_required", accept.dig("error", "code")
    @docker.failure = nil
    assert_equal 202, @engine.call("operation" => "resume", "operation_id" => failed.fetch("id")).fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt.fetch("status")
    assert_equal 2, @docker.calls.count { |call| call.first == :backup }
    assert_equal 1, @docker.calls.count { |call| call.first == :migrate }
    refute_includes @store.log(failed.fetch("id"), offset: 0, limit: 65_536).to_s, "private-database-content"
  end

  def test_resume_adopts_completed_database_file_when_receipt_update_was_interrupted
    check
    @docker.failure = :migrate
    accept
    @engine.wait
    state = @store.load
    receipt = CybrosUpdater::Receipt.from_h(state.fetch("receipts").last).with(status: "running", phase: "backing_up", database_backup: nil, error: nil)
    @store.save(installed: @installed, candidate: @candidate, preflight: CybrosUpdater::Preflight.from_h(state.fetch("preflight")), receipts: [receipt])
    path = File.join(@directory, "backups", "databases", "#{receipt.id}.sql")
    before = File.binread(path)
    restart
    @docker.failure = nil
    assert_equal 202, @engine.call("operation" => "resume", "operation_id" => receipt.id).fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt.fetch("status")
    assert_equal before, File.binread(path)
    assert_equal 1, @docker.calls.count { |call| call.first == :backup }
    assert_equal true, current_receipt.dig("database_backup", "available")
  end

  def test_failed_pull_preserves_old_services_and_allows_explicit_retry
    check
    @docker.failure = :prepare
    accept
    @engine.wait
    assert_equal "failed", current_receipt.fetch("status")
    assert_equal "preparing", current_receipt.fetch("phase")
    refute @docker.calls.any? { |call| call.first == :stop }
    refute File.exist?(File.join(@directory, "images.env"))
    assert_equal 200, @engine.call("operation" => "assert_idle").fetch("status")
    @docker.failure = nil
    assert_equal 202, accept.fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt.fetch("status")
  end

  def test_stop_and_migration_failures_block_normal_start_and_new_upgrade
    [:stop, :migrate].each do |failure|
      @docker.failure = failure
      check
      accept
      @engine.wait
      assert_equal "failed", current_receipt.fetch("status")
      assert_equal failure == :stop ? "stopping" : "migrating", current_receipt.fetch("phase")
      assert_equal "recovery_required", accept.dig("error", "code")
      assert_equal "recovery_required", @engine.call("operation" => "assert_idle").dig("error", "code")
      refute @docker.calls.any? { |call| call.first == :activate }
      refute File.exist?(File.join(@directory, "images.env"))
      break if failure == :migrate
      # A second independent installation exercises the migration failure branch.
      teardown
      setup
    end
  end

  def test_failed_preparation_while_resuming_a_stop_keeps_recovery_required
    check
    @docker.failure = :stop
    accept
    @engine.wait
    id = current_receipt.fetch("id")
    assert_equal "stopping", current_receipt.fetch("phase")

    @docker.failure = :prepare
    assert_equal 202, @engine.call("operation" => "resume", "operation_id" => id).fetch("status")
    @engine.wait
    assert_equal "failed", current_receipt.fetch("status")
    assert_equal "stopping", current_receipt.fetch("phase")
    assert CybrosUpdater::Receipt.from_h(@store.load.fetch("receipts").last).needs_recovery?
    assert_equal "recovery_required", @engine.call("operation" => "assert_idle").dig("error", "code")
    assert_equal "recovery_required", accept.dig("error", "code")
    refute @docker.calls.any? { |call| call.first == :migrate || call.first == :activate }

    restart
    assert_equal "recovery_required", @engine.call("operation" => "assert_idle").dig("error", "code")
  end

  def test_activation_and_worker_readiness_failures_never_report_completion
    [:activate, :verify].each do |failure|
      previous_migrations = @docker.calls.count { |call| call.first == :migrate }
      check
      @docker.failure = failure
      accept
      @engine.wait
      assert_equal "failed", current_receipt.fetch("status")
      assert_equal failure == :activate ? "activating" : "verifying", current_receipt.fetch("phase")
      assert_includes File.read(File.join(@directory, "images.env")), @candidate.reference("nexus")
      assert_equal "recovery_required", accept.dig("error", "code")
      @docker.failure = nil
      id = current_receipt.fetch("id")
      assert_equal 202, @engine.call("operation" => "resume", "operation_id" => id).fetch("status")
      @engine.wait
      assert_equal "succeeded", current_receipt.fetch("status")
      assert_equal previous_migrations + 1, @docker.calls.count { |call| call.first == :migrate }
    end
  end

  def test_stop_failure_can_resume_without_repeating_a_migration
    check
    @docker.failure = :stop
    accept
    @engine.wait
    id = current_receipt.fetch("id")
    @docker.failure = nil
    assert_equal 202, @engine.call("operation" => "resume", "operation_id" => id).fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt.fetch("status")
    assert_equal 1, @docker.calls.count { |call| call.first == :migrate }
    assert_equal 2, @docker.calls.count { |call| call.first == :stop }
  end

  def test_cli_drains_all_terminal_log_windows_before_exiting
    operation = { "id" => SecureRandom.uuid_v7, "status" => "succeeded", "log_cursor" => Base64.strict_encode64("32768") }
    windows = [
      { "entries" => [{ "text" => "first page\n" }], "next_cursor" => Base64.strict_encode64("16384"), "operation" => operation },
      { "entries" => [{ "text" => "last page\n" }], "next_cursor" => operation.fetch("log_cursor"), "operation" => operation },
    ]
    client = Object.new
    client.define_singleton_method(:call) do |request|
      { "status" => 200, "data" => request.fetch("operation") == "resume" ? operation : windows.shift }
    end
    output = StringIO.new
    cli = CybrosUpdater::CLI.new(["resume", operation.fetch("id")], output: output)
    cli.instance_variable_set(:@client, client)
    assert_equal 0, cli.run
    assert_empty windows
    assert_includes output.string, "first page\nlast page\n"
  end

  def test_interrupted_migration_requires_observed_success_before_activation_resume
    check
    @docker.failure = :migrate
    accept
    @engine.wait
    state = @store.load
    receipt = CybrosUpdater::Receipt.from_h(state.fetch("receipts").last).with(status: "running", error: nil)
    @store.save(installed: @installed, candidate: @candidate, preflight: CybrosUpdater::Preflight.from_h(state.fetch("preflight")), receipts: [receipt])
    restart
    assert_equal "interrupted", current_receipt.fetch("status")
    @docker.migration_success = false
    assert_equal "recovery_required", @engine.call("operation" => "resume", "operation_id" => receipt.id).dig("error", "code")
    assert_equal "recovery_required", accept.dig("error", "code")
    @docker.migration_success = true
    @docker.failure = nil
    assert_equal 202, @engine.call("operation" => "resume", "operation_id" => receipt.id).fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt.fetch("status")
    assert_equal 1, @docker.calls.count { |call| call.first == :migrate }
  end

  def test_logs_are_bounded_resumable_and_reject_foreign_offsets
    check
    accept
    @engine.wait
    id = current_receipt.fetch("id")
    first = @engine.call("operation" => "log", "operation_id" => id, "limit" => 12).fetch("data")
    assert_operator first.fetch("entries").sum { |entry| entry.fetch("text").bytesize }, :<=, 12
    second = @engine.call("operation" => "log", "operation_id" => id, "cursor" => first.fetch("next_cursor"), "limit" => 12).fetch("data")
    refute_equal first.fetch("entries"), second.fetch("entries")
    assert_equal "succeeded", second.dig("operation", "status")
    assert_equal "invalid_request", @engine.call("operation" => "log", "operation_id" => id, "cursor" => "../../file").dig("error", "code")
    assert_equal "invalid_request", @engine.call("operation" => "log", "operation_id" => id, "limit" => 65_537).dig("error", "code")
    assert_equal "not_found", @engine.call("operation" => "log", "operation_id" => SecureRandom.uuid_v7).dig("error", "code")
    @store.append_log(id, "x" * (CybrosUpdater::Store::LOG_LIMIT + 100))
    assert_equal CybrosUpdater::Store::LOG_LIMIT, File.size(File.join(@directory, "data", "updater", "#{id}.log"))
  end

  def test_lifetime_lock_refuses_an_independent_updater
    error = assert_raises(CybrosUpdater::Error) { CybrosUpdater::Store.new(File.join(@directory, "data", "updater")) }
    assert_equal "updater_unavailable", error.code
  end

  def test_durability_failure_never_starts_docker_or_reports_replay_as_accepted
    check
    original = @store.method(:save)
    @store.define_singleton_method(:save) { |**_arguments| raise Errno::ENOSPC }
    request = upgrade_request
    answer = @engine.call(request)
    assert_equal "updater_unavailable", answer.dig("error", "code")
    assert_equal "updater_unavailable", @engine.call(request).dig("error", "code")
    refute @docker.calls.any? { |call| call.first == :prepare }
    @store.define_singleton_method(:save, original)
  end

  def test_recent_receipts_and_logs_have_bounded_retention
    check
    ids = 22.times.map do
      result = accept
      @engine.wait
      result.dig("data", "id")
    end
    assert_equal 20, @store.load.fetch("receipts").size
    assert_equal "not_found", @engine.call("operation" => "receipt", "operation_id" => ids.first).dig("error", "code")
    refute File.exist?(File.join(@directory, "data", "updater", "#{ids.first}.log"))
    assert_equal 20, Dir.glob(File.join(@directory, "data", "updater", "*.log")).size
    assert_equal 3, Dir.glob(File.join(@directory, "backups", "databases", "*.sql")).size
    assert_equal false, @engine.call("operation" => "receipt", "operation_id" => ids.fetch(2)).dig("data", "database_backup", "available")
    assert_equal true, @engine.call("operation" => "receipt", "operation_id" => ids.last).dig("data", "database_backup", "available")
  end

  def test_nexus_upgrade_preserves_rho_pin_and_observes_mixed_installed_versions
    checked = check(scope: "nexus")
    assert_equal ["nexus"], checked.fetch("candidate").fetch("images").map { |image| image.fetch("name") }
    assert_equal ["nexus"], checked.fetch("sources").map { |image| image.fetch("name") }
    refute File.exist?(File.join(@directory, "images.env"))

    accepted = accept(scope: "nexus")
    assert_equal 202, accepted.fetch("status")
    @engine.wait
    receipt = current_receipt(scope: "nexus")
    assert_equal "succeeded", receipt.fetch("status")
    %w[target previous].each do |field|
      assert_equal ["nexus"], receipt.fetch(field).fetch("images").map { |image| image.fetch("name") }
    end
    @docker.calls.select { |call| [:prepare, :migrate, :activate, :verify].include?(call.first) }.each do |call|
      assert_equal ["nexus"], call.fetch(1).fetch("images").map { |image| image.fetch("name") }
    end
    assert_includes @docker.calls, [:stop, "nexus"]
    assert_equal 1, @docker.calls.count { |call| call.first == :backup }
    assert_equal true, receipt.dig("database_backup", "available")
    pins = File.read(File.join(@directory, "images.env"))
    assert_includes pins, @candidate.reference("nexus")
    assert_includes pins, @installed.reference("rho")
    refute_includes pins, @candidate.reference("rho")

    full = @engine.call("operation" => "status").dig("data", "installed")
    assert_nil full.fetch("release")
    assert_equal({ "nexus" => @candidate.release, "rho" => @installed.release }, full.fetch("images").to_h { |image| [image.fetch("name"), image.fetch("version")] })
    assert_equal full, @store.load.fetch("installed")
    restart
    nexus = @engine.call("operation" => "status", "scope" => "nexus").dig("data", "installed")
    assert_equal @candidate.release, nexus.fetch("release")
    assert_equal ["nexus"], nexus.fetch("images").map { |image| image.fetch("name") }
    assert_equal receipt.fetch("id"), current_receipt.fetch("id")
  end

  def test_scope_and_nexus_selection_are_validated_before_acceptance
    @docker.calls.clear
    assert_equal "invalid_request", @engine.call("operation" => "status", "scope" => "rho").dig("error", "code")
    assert_empty @docker.calls
    check(scope: "nexus")
    @docker.calls.clear
    request = upgrade_request(scope: "nexus")
    request.fetch("candidate")["images"] = @candidate.selection.fetch("images")
    assert_equal "invalid_request", @engine.call(request).dig("error", "code")
    request.fetch("candidate")["images"] = @candidate.selection.fetch("images").select { |image| image.fetch("name") == "rho" }
    assert_equal "invalid_request", @engine.call(request).dig("error", "code")
    assert_empty @docker.calls
    assert_nil current_receipt
  end

  def test_checks_share_one_candidate_while_nexus_hides_foreign_candidate_and_preflight
    check
    nexus = @engine.call("operation" => "status", "scope" => "nexus").fetch("data")
    assert_nil nexus.fetch("candidate")
    assert_nil nexus.fetch("preflight")
    refute_includes JSON.generate(nexus), "rho"

    check(scope: "nexus")
    request = upgrade_request(scope: "nexus")
    check
    assert_equal "candidate_changed", @engine.call(request).dig("error", "code")
    refute @docker.calls.any? { |call| call.first == :prepare }
    assert_equal @candidate.to_h, @engine.call("operation" => "status").dig("data", "candidate")
  end

  def test_failed_nexus_check_retains_its_blockers_after_restart_without_a_candidate
    @docker.failure = :check
    checked = check(scope: "nexus")
    assert_nil checked.fetch("candidate")
    assert_equal false, checked.dig("preflight", "ready")
    assert_equal "nexus", checked.dig("preflight", "scope")
    restart
    assert_equal checked.fetch("preflight"), @engine.call("operation" => "status", "scope" => "nexus").dig("data", "preflight")

    check
    document = @store.load
    document.fetch("preflight").delete("scope")
    @store.atomic_write(File.join(@directory, "data", "updater", "state.json"), JSON.generate(document))
    restart
    assert_nil @engine.call("operation" => "status", "scope" => "nexus").dig("data", "preflight")
    assert_equal false, @engine.call("operation" => "status").dig("data", "preflight", "ready")
    assert_equal "installation", @engine.call("operation" => "status").dig("data", "preflight", "scope")
  end

  def test_nexus_cannot_read_or_resume_an_installation_receipt_or_its_log
    check
    accept
    @engine.wait
    id = current_receipt.fetch("id")
    @store.append_log(id, "rho installation detail\n")
    %w[receipt log resume].each do |operation|
      answer = @engine.call("operation" => operation, "operation_id" => id, "scope" => "nexus")
      assert_equal 404, answer.fetch("status"), operation
      assert_equal "not_found", answer.dig("error", "code"), operation
      refute answer.fetch("error").key?("operation_id"), operation
      refute answer.key?("data"), operation
    end
    assert_nil current_receipt(scope: "nexus")
    assert_equal id, @engine.call("operation" => "receipt", "operation_id" => id).dig("data", "id")
  end

  def test_foreign_busy_recovery_and_idempotency_conflicts_do_not_expose_operation_ids
    check
    @docker.prepare_entered = Queue.new
    @docker.prepare_release = Queue.new
    request = upgrade_request
    accepted = @engine.call(request)
    @docker.prepare_entered.pop
    check(scope: "nexus")
    %w[upgrade assert_idle refresh_installed].each do |operation|
      answer = @engine.call(upgrade_request(scope: "nexus").merge("operation" => operation))
      assert_equal "upgrade_in_progress", answer.dig("error", "code"), operation
      refute answer.fetch("error").key?("operation_id"), operation
    end
    conflicting = upgrade_request(scope: "nexus").merge("idempotency_key" => request.fetch("idempotency_key"))
    answer = @engine.call(conflicting)
    assert_equal "idempotency_conflict", answer.dig("error", "code")
    refute answer.fetch("error").key?("operation_id")
    assert_nil @engine.call("operation" => "status", "scope" => "nexus").dig("data", "active_operation")
    @docker.failure = :migrate
    @docker.prepare_release.push(true)
    @engine.wait

    answer = accept(scope: "nexus")
    assert_equal "recovery_required", answer.dig("error", "code")
    refute answer.fetch("error").key?("operation_id")
    assert_equal accepted.dig("data", "id"), @engine.call("operation" => "assert_idle").dig("error", "operation_id")
  end

  def test_nexus_receipt_replays_after_restart_without_repeating_effects
    check(scope: "nexus")
    request = upgrade_request(scope: "nexus")
    accepted = @engine.call(request)
    @engine.wait
    restart
    before = @docker.calls.dup
    replay = @engine.call(request)
    assert_equal accepted.dig("data", "id"), replay.dig("data", "id")
    assert_equal "succeeded", replay.dig("data", "status")
    assert_equal before, @docker.calls
    log = @engine.call("operation" => "log", "scope" => "nexus", "operation_id" => accepted.dig("data", "id"))
    assert_equal 200, log.fetch("status")
    refute_includes JSON.generate(log), "rho"
  end

  def test_nexus_migration_recovery_reuses_the_existing_receipt_and_cli_can_resume_it
    check(scope: "nexus")
    @docker.failure = :migrate
    accept(scope: "nexus")
    @engine.wait
    id = current_receipt(scope: "nexus").fetch("id")
    restart
    @docker.migration_success = false
    answer = @engine.call("operation" => "resume", "scope" => "nexus", "operation_id" => id)
    assert_equal "recovery_required", answer.dig("error", "code")
    assert_equal id, answer.dig("error", "operation_id")
    @docker.migration_success = true
    @docker.failure = nil
    assert_equal 202, @engine.call("operation" => "resume", "operation_id" => id).fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt(scope: "nexus").fetch("status")
    assert_equal id, current_receipt.fetch("id")
    assert_equal 1, @docker.calls.count { |call| call.first == :migrate }
    assert_equal 1, @docker.calls.count { |call| call.first == :backup }
    assert_includes File.read(File.join(@directory, "images.env")), @installed.reference("rho")
  end

  def test_failed_nexus_preparation_replays_the_failure_and_retries_only_on_a_new_request
    check(scope: "nexus")
    @docker.failure = :prepare
    request = upgrade_request(scope: "nexus")
    accepted = @engine.call(request)
    @engine.wait
    assert_equal "failed", current_receipt(scope: "nexus").fetch("status")
    refute @docker.calls.any? { |call| call.first == :stop }
    refute File.exist?(File.join(@directory, "images.env"))
    before = @docker.calls.dup
    replay = @engine.call(request)
    assert_equal accepted.dig("data", "id"), replay.dig("data", "id")
    assert_equal "failed", replay.dig("data", "status")
    assert_equal before, @docker.calls

    @docker.failure = nil
    assert_equal 202, accept(scope: "nexus").fetch("status")
    @engine.wait
    assert_equal "succeeded", current_receipt(scope: "nexus").fetch("status")
    refute_equal accepted.dig("data", "id"), current_receipt(scope: "nexus").fetch("id")
    assert_includes @docker.calls, [:stop, "nexus"]
    assert_includes File.read(File.join(@directory, "images.env")), @installed.reference("rho")
  end

  private

  def release(version, nexus, rho)
    CybrosUpdater::Release.new(
      release: version,
      images: [CybrosUpdater::Image.new(name: "nexus", reference: "registry.example/team/nexus@sha256:#{nexus * 64}", version: version), CybrosUpdater::Image.new(name: "rho", reference: "registry.example/team/rho@sha256:#{rho * 64}", version: version)],
      checked_at: Time.now.utc.iso8601, source_revision: "abcdef", source_url: "https://example.test/project",
    )
  end

  def check(scope: "installation") = @engine.call("operation" => "check", "tag" => "latest", "scope" => scope).fetch("data")
  def accept(scope: "installation") = @engine.call(upgrade_request(scope: scope))

  def upgrade_request(scope: "installation")
    selection = @candidate.selection
    selection["images"] = selection.fetch("images").select { |image| CybrosUpdater::Docker.products(scope).include?(image.fetch("name")) }
    request = { "operation" => "upgrade", "candidate" => selection, "idempotency_key" => SecureRandom.uuid_v7, "actor_public_id" => nil }
    request["scope"] = scope unless scope == "installation"
    request
  end

  def current_receipt(scope: "installation") = @engine.call("operation" => "status", "scope" => scope).fetch("data").fetch("last_operation")

  def restart
    @store.close
    @store = CybrosUpdater::Store.new(File.join(@directory, "data", "updater"))
    @engine = CybrosUpdater::Engine.new(directory: @directory, store: @store, docker: @docker)
  end
end
