require "test_helper"
require "async"

class DeploymentTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-deployment")
    @helper = File.join(@root, "updater.rb")
    @env = { "RHO_DEPLOYMENT_SOCKET" => File.join(@root, "updater.sock") }
    write_helper('puts JSON.generate("status" => 200, "data" => { "request" => request, "socket" => ENV.fetch("CYBROS_UPDATER_SOCKET") })')
  end

  def teardown
    FileUtils.remove_entry(@root)
  end

  def test_unsupported_installations_name_their_actual_update_path
    status, body = Rho::Deployment.new(environment: {}).status
    assert_equal 200, status
    assert_equal({ "supported" => false, "mode" => "checkout" }, body)
    assert_equal "container", Rho::Deployment.new(environment: { "RHO_CONTAINER" => "1" }).status.last.fetch("mode")
    File.write(File.join(@root, "receipt.json"), "{}")
    assert_equal "installed", Rho::Deployment.new(environment: { "RHO_PREFIX" => @root }).status.last.fetch("mode")
    assert_equal 409, Rho::Deployment.new(environment: {}).check("latest").first
  end

  def test_commands_use_the_existing_helper_and_fix_the_rho_scope
    deployment = Rho::Deployment.new(environment: @env, helper: @helper)
    assert_equal({ "operation" => "status", "scope" => "rho" }, deployment.status.last.fetch("request"))
    check = deployment.check("latest").last
    assert_equal({ "operation" => "check", "scope" => "rho", "tag" => "latest", "backup" => false }, check.fetch("request"))
    assert_match(/\A[0-9a-f-]{14}7[0-9a-f-]{21}\z/, check.fetch("idempotency_key"))
    assert_equal @env.fetch("RHO_DEPLOYMENT_SOCKET"), check.fetch("socket")
    candidate = { "release" => "2610111234", "images" => [{ "name" => "rho", "reference" => "rho@sha256:abc" }], "ignored" => true }
    payload = { "candidate" => candidate, "idempotency_key" => check.fetch("idempotency_key"), "scope" => "installation", "backup" => true, "actor_public_id" => "other" }
    expected = { "operation" => "upgrade", "scope" => "rho", "backup" => false, "actor_public_id" => nil,
      "candidate" => candidate.slice("release", "images"), "idempotency_key" => check.fetch("idempotency_key") }
    assert_equal expected, deployment.upgrade(payload).last.fetch("request")
    assert_equal({ "operation" => "receipt", "scope" => "rho", "operation_id" => "operation" }, deployment.receipt("operation").last.fetch("request"))
    assert_equal({ "operation" => "log", "scope" => "rho", "operation_id" => "operation", "cursor" => "cursor" }, deployment.log("operation", "cursor").last.fetch("request"))
  end

  def test_updater_refusals_preserve_status_and_the_operation_reference
    write_helper('puts JSON.generate("status" => 409, "error" => { "code" => "recovery_required", "message" => "Inspect the receipt.", "operation_id" => "operation" }); exit 1')
    status, body = Rho::Deployment.new(environment: @env, helper: @helper).status
    assert_equal 409, status
    assert_equal "recovery_required", body.dig("error", "code")
    assert_equal "operation", body.dig("error", "operation_id")
  end

  def test_unavailable_or_malformed_helper_output_is_a_safe_refusal
    ["warn 'private failure'; exit 1", "puts 'not JSON'", "puts '[]'", "puts 'x' * (128 * 1024 + 1)"].each do |script|
      write_helper(script)
      status, body = Rho::Deployment.new(environment: @env, helper: @helper).status
      assert_equal 503, status
      assert_equal "updater_unavailable", body.dig(:error, :code)
      refute_includes JSON.generate(body), "private failure"
      refute_includes JSON.generate(body), @root
    end
  end

  def test_a_slow_installation_check_keeps_the_daemon_reactor_available
    write_helper('sleep 0.1; puts JSON.generate("status" => 200, "data" => { "supported" => true })')
    Async do |task|
      sibling = task.async { sleep 0.02; :available }
      status, = Rho::Deployment.new(environment: @env, helper: @helper).check("latest")
      assert_equal 200, status
      assert sibling.finished?, "the updater wait must yield to other daemon requests"
      assert_equal :available, sibling.wait
    end.wait
  end

  def test_missing_selection_and_oversized_requests_are_refused_before_the_helper
    File.delete(@helper)
    deployment = Rho::Deployment.new(environment: @env, helper: @helper)
    status, body = deployment.upgrade({})
    assert_equal 400, status
    assert_equal "invalid_request", body.dig(:error, :code)
    status, body = deployment.check("x" * (16 * 1024))
    assert_equal 400, status
    assert_equal "invalid_request", body.dig(:error, :code)
  end

  private

  def write_helper(script)
    File.write(@helper, "require 'json'\nrequest = JSON.parse(STDIN.read)\n#{script}\n")
  end
end
