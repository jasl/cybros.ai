require "test_helper"

# One application identity owns both advertised executor services.
class IdentityTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-identity")
    @home = Rho::Home.resolve(base_url: "https://nexus.example", root: @root).prepare
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def test_an_application_identity_uses_one_executor_and_user_owned_storage
    identity = Rho::Identity.agent(home: @home, user_public_id: "0199-user", executor_public_id: "0199-executor")

    assert_equal "0199-executor", identity.runner_executor_public_id
    assert_equal({ "version" => 6, "user_public_id" => "0199-user", "executor_public_id" => "0199-executor" },
      identity.pointer_document)
    assert_equal @home.identity_root("0199-user"), identity.root
    assert_equal File.join(identity.root, "credentials.json"), identity.vault.path
    assert_equal @home.identity_work_root("0199-user"), identity.work_root
    restored = Rho::Identity.from_pointer(home: @home, pointer: identity.pointer_document)
    assert_equal identity.pointer_document, restored.pointer_document
  end

  def test_from_pointer_refuses_old_formats_and_missing_identity_fields
    error = assert_raises(Rho::StoredConnectionError) do
      Rho::Identity.from_pointer(home: @home,
        pointer: { "version" => 5, "mode" => "full", "user_public_id" => "0199-user", "executor_public_id" => "0199-executor" })
    end
    assert_match(/format version 6/, error.message)
    %w[user_public_id executor_public_id].each do |field|
      pointer = { "version" => 6, "user_public_id" => "0199-user", "executor_public_id" => "0199-executor" }
      pointer.delete(field)
      assert_raises(Rho::StoredConnectionError) { Rho::Identity.from_pointer(home: @home, pointer: pointer) }
      pointer[field] = ""
      assert_raises(Rho::StoredConnectionError) { Rho::Identity.from_pointer(home: @home, pointer: pointer) }
    end
  end

  def test_the_recorded_session_must_match_the_pointer_executor
    identity = Rho::Identity.agent(home: @home, user_public_id: "0199-user", executor_public_id: "0199-executor")
      .prepare.record(clock: -> { Time.utc(2026, 9, 7) })
    identity.verify_belongs_here
    refute identity.session.read.key?("mode")
    changed = Rho::Identity.agent(home: @home, user_public_id: "0199-user", executor_public_id: "0199-replacement")
    error = assert_raises(Rho::StoredConnectionError) { changed.verify_belongs_here }
    assert_match(/pointer's executor_public_id/, error.message)
    assert_same changed, changed.verify_installable
  end
end
