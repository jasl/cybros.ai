require "test_helper"
require "tmpdir"

# The rotation protocol against rho's real file store. The daemon's lifetime
# Home lock owns process exclusion; this integration checks the storage port
# and persist-before-use without creating another process protocol.
class CredentialStoreIntegrationTest < Minitest::Test
  def setup
    @root = Dir.mktmpdir("rho-credential-store")
    @path = File.join(@root, "vault", "credentials.json")
    @now = Time.utc(2026, 7, 26, 12, 0, 0)
  end

  def teardown
    FileUtils.remove_entry(@root) if @root && File.directory?(@root)
  end

  def store = Rho::StateFile.new(@path)

  def issue
    CybrosAgent::Credentials::OAuth.issue(
      credentials: CybrosAgent::DeviceFlow::Credentials.new(
        access_token: "sk-0", executor_access_token: "ek-0",
        refresh_token: "rt-0", token_type: "Bearer", expires_in: 3600
      ),
      authority: nil, store:, clock: -> { @now }
    )
  end

  def test_the_file_store_answers_the_port
    file = store

    assert_respond_to file, :read
    assert_respond_to file, :write
    assert_respond_to file, :with_lock
    assert_equal @path, file.description
  end

  def test_issued_credentials_are_persisted_before_use
    credentials = issue
    stored = store.read

    assert_equal credentials.member_credential, stored.fetch("access_token")
    assert_equal credentials.executor_credential, stored.fetch("executor_access_token")
    assert_equal "rt-0", stored.fetch("refresh_token")
  end
end
