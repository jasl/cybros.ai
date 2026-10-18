require "minitest/autorun"
require "tmpdir"
require "socket"
require "json"
require_relative "../../../lib/nexus/deployment/client"

I18n.load_path += Dir[File.expand_path("../../../config/locales/*.yml", __dir__)]

class Nexus::Deployment::ClientTest < Minitest::Test
  def test_an_unconfigured_installation_reports_unsupported_without_connecting
    result = Nexus::Deployment::Client.new(socket_path: nil).status

    assert_equal 200, result.status
    refute result.data.supported
    assert_nil result.data.installed
    assert_nil result.data.active_operation
  end

  def test_status_reads_local_state_and_check_is_a_separate_explicit_command
    with_updater(deployment) do |path, requests|
      result = Nexus::Deployment::Client.new(socket_path: path).status

      assert_equal 200, result.status
      assert_equal "2610080750", result.data.installed.release
      assert_equal [{ "operation" => "status", "scope" => "nexus" }], requests.pop
    end

    ["latest", "2610080750"].each do |tag|
      with_updater(deployment) do |path, requests|
        result = Nexus::Deployment::Client.new(socket_path: path).check(tag: tag)

        assert_equal 200, result.status
        assert_equal [{ "operation" => "check", "scope" => "nexus", "tag" => tag, "backup" => true }], requests.pop
      end
    end
  end

  def test_an_upgrade_is_fixed_to_nexus_with_the_selected_image_and_initiating_human
    id = "019a0000-0000-7000-8000-000000000001"
    actor = "019a0000-0000-7000-8000-000000000002"
    with_updater(receipt(id: id, actor: actor), status: 202) do |path, requests|
      client = Nexus::Deployment::Client.new(socket_path: path)
      result = client.upgrade(idempotency_key: id, actor_public_id: actor,
        candidate: Nexus::Deployment::Release.from_h(release))

      assert_equal 202, result.status
      assert_equal id, result.data.id
      assert_equal [{ "operation" => "upgrade", "scope" => "nexus", "idempotency_key" => id,
        "actor_public_id" => actor, "candidate" => release, "backup" => true }], requests.pop
    end
  end

  def test_a_blocked_check_keeps_the_resolved_release_and_actionable_preflight_report
    check = { "name" => "installation_space", "status" => "blocked", "message" => "More space is needed.",
      "next_step" => "Free space on the installation volume and check again.",
      "available_bytes" => 1024, "required_bytes" => 2048 }
    payload = deployment.merge("candidate" => release.merge("checked_at" => "2026-10-08T09:00:00Z"),
      "preflight" => { "checked_at" => "2026-10-08T09:00:00Z", "ready" => false, "backup" => true, "checks" => [check] })
    with_updater(payload) do |path, _requests|
      result = Nexus::Deployment::Client.new(socket_path: path).check

      assert_equal 200, result.status
      assert_equal "2610080750", result.data.candidate.target.release
      refute result.data.preflight.ready
      assert_equal check.transform_keys(&:to_sym), result.data.preflight.checks.first.to_h
    end
  end

  def test_a_combined_reply_from_an_independently_deployed_updater_is_unavailable
    combined = release.merge("images" => release.fetch("images") + [
      { "name" => "agent-application", "reference" => "example/agent-application@sha256:#{"b" * 64}" },
    ])
    with_updater(deployment.merge("candidate" => combined.merge("checked_at" => "2026-10-08T09:00:00Z"))) do |path, requests|
      result = Nexus::Deployment::Client.new(socket_path: path).check

      assert_equal 503, result.status
      assert_equal :updater_unavailable, result.error.code
      assert_nil result.data
      assert_equal [{ "operation" => "check", "scope" => "nexus", "tag" => "latest", "backup" => true }], requests.pop
    end
  end

  def test_a_combined_selection_is_refused_before_contacting_the_updater
    candidate = Nexus::Deployment::Release.from_h(release)
    candidate = candidate.with(images: candidate.images + [
      Nexus::Deployment::Image.new(name: "agent-application", reference: "example/agent-application@sha256:#{"b" * 64}"),
    ])
    Dir.mktmpdir("nexus-updater-") do |directory|
      path = File.join(directory, "updater.sock")
      server = UNIXServer.new(path)
      result = Nexus::Deployment::Client.new(socket_path: path).upgrade(
        idempotency_key: "019a0000-0000-7000-8000-000000000001", actor_public_id: nil, candidate: candidate)

      assert_equal 400, result.status
      assert_equal :invalid_request, result.error.code
      assert_nil IO.select([server], nil, nil, 0), "a non-Nexus selection must not reach the installation owner"
    ensure
      server&.close
    end
  end

  def test_a_receipt_reads_database_backup_metadata_without_exposing_a_file_location
    id = "019a0000-0000-7000-8000-000000000001"
    backup = { "created_at" => "2026-10-08T09:30:02Z", "size_bytes" => 1024, "available" => true }
    payload = receipt(id: id).merge("phase" => "backing_up",
      "database_backup" => backup.merge("path" => "/private/backups/database.sql"))
    with_updater(payload) do |path, requests|
      result = Nexus::Deployment::Client.new(socket_path: path).receipt(operation_id: id)

      assert_equal 200, result.status
      assert_equal "backing_up", result.data.phase
      assert_equal backup.transform_keys(&:to_sym), result.data.database_backup.to_h
      assert_equal [{ "operation" => "receipt", "scope" => "nexus", "operation_id" => id }], requests.pop
    end
  end

  def test_a_preflight_refusal_is_preserved_without_retrying_acceptance
    error = { "code" => "preflight_failed", "message" => "Run the preflight checks before upgrading." }
    with_updater(nil, status: 409, error: error) do |path, requests|
      result = Nexus::Deployment::Client.new(socket_path: path).upgrade(
        idempotency_key: "019a0000-0000-7000-8000-000000000001", actor_public_id: nil,
        candidate: Nexus::Deployment::Release.from_h(release))

      assert_equal 409, result.status
      assert_equal :preflight_failed, result.error.code
      assert_equal 1, requests.pop.length
    end
  end

  def test_explicitly_skipping_backup_crosses_check_acceptance_and_receipt_boundaries
    payload = deployment.merge("preflight" => {
      "checked_at" => "2026-10-08T09:00:00Z", "ready" => true, "backup" => false, "checks" => [],
    })
    with_updater(payload) do |path, requests|
      result = Nexus::Deployment::Client.new(socket_path: path).check(backup: false)

      assert_equal 200, result.status
      refute result.data.preflight.backup
      assert_equal false, requests.pop.first.fetch("backup")
    end

    id = "019a0000-0000-7000-8000-000000000001"
    with_updater(receipt(id: id).merge("backup" => false), status: 202) do |path, requests|
      result = Nexus::Deployment::Client.new(socket_path: path).upgrade(
        idempotency_key: id, actor_public_id: nil, candidate: Nexus::Deployment::Release.from_h(release), backup: false)

      assert_equal 202, result.status
      refute result.data.backup
      assert_nil result.data.database_backup
      assert_equal false, requests.pop.first.fetch("backup")
    end
  end

  def test_log_windows_keep_the_opaque_cursor_and_the_receipt
    id = "019a0000-0000-7000-8000-000000000001"
    payload = { "entries" => [{ "cursor" => "cursor-one", "text" => "Preparing images" }],
      "next_cursor" => "cursor-two", "operation" => receipt(id: id) }
    with_updater(payload) do |path, requests|
      result = Nexus::Deployment::Client.new(socket_path: path).log(operation_id: id, cursor: "opaque-input")

      assert_equal "Preparing images", result.data.entries.first.text
      assert_equal "cursor-two", result.data.next_cursor
      assert_equal id, result.data.operation.id
      assert_equal [{ "operation" => "log", "scope" => "nexus", "operation_id" => id,
        "cursor" => "opaque-input", "limit" => 65_536 }], requests.pop
    end
  end

  def test_a_refused_upgrade_exposes_the_existing_operation_without_retrying
    error = { "code" => "upgrade_in_progress", "message" => "An upgrade is already running.",
      "operation_id" => "019a0000-0000-7000-8000-000000000001" }
    with_updater(nil, status: 409, error: error) do |path, requests|
      result = Nexus::Deployment::Client.new(socket_path: path).check

      assert_equal 409, result.status
      assert_equal :upgrade_in_progress, result.error.code
      assert_equal error.fetch("operation_id"), result.error.operation_id
      assert_equal 1, requests.pop.length
    end
  end

  def test_an_unavailable_or_incomplete_updater_returns_a_safe_unavailable_result
    result = Nexus::Deployment::Client.new(socket_path: "/missing-cybros-updater/socket").status
    assert_equal 503, result.status
    assert_equal :updater_unavailable, result.error.code
    refute_includes result.error.message, "/missing-cybros"

    ["{broken}\n", "x" * 131_073, "{\"status\":200}"].each do |wire|
      with_updater(nil, wire: wire) do |path, _requests|
        result = Nexus::Deployment::Client.new(socket_path: path).status
        assert_equal 503, result.status
        assert_equal :updater_unavailable, result.error.code
      end
    end
  end

  def test_a_response_timeout_does_not_repeat_a_command
    with_updater(deployment, delay: 0.1) do |path, requests|
      result = Nexus::Deployment::Client.new(socket_path: path, timeout: 0.02).check

      assert_equal 503, result.status
      assert_equal :updater_unavailable, result.error.code
      assert_equal 1, requests.pop.length
    end
  end

  private

    def release
      { "release" => "2610080750", "images" => [
        { "name" => "nexus", "reference" => "example/nexus@sha256:#{"a" * 64}" },
      ] }
    end

    def deployment
      { "supported" => true, "sources" => [], "installed" => release, "candidate" => nil,
        "preflight" => nil, "active_operation" => nil, "last_operation" => nil }
    end

    def receipt(id:, actor: nil)
      { "id" => id, "idempotency_key" => id, "actor_public_id" => actor,
        "target" => release, "previous" => release, "phase" => "preparing", "status" => "running",
        "accepted_at" => "2026-10-08T09:30:00Z", "updated_at" => "2026-10-08T09:30:01Z",
        "completed_at" => nil, "error" => nil, "recovery" => nil, "log_cursor" => nil, "backup" => true, "database_backup" => nil }
    end

    def with_updater(data, status: 200, error: nil, wire: nil, delay: 0)
      Dir.mktmpdir("nexus-updater-") do |directory|
        path = File.join(directory, "updater.sock")
        server = UNIXServer.new(path)
        requests = Queue.new
        worker = Thread.new do
          socket = server.accept
          begin
            requests << [JSON.parse(socket.gets)]
            sleep delay if delay.positive?
            socket.write(wire || JSON.generate(error ? { status: status, error: error } : { status: status, data: data }) + "\n")
          rescue Errno::EPIPE
            # A timed-out client closes its one connection without retrying.
          ensure
            socket.close
          end
        end
        yield path, requests
      ensure
        server&.close
        worker&.join(1)
        worker&.kill
      end
    end
end
