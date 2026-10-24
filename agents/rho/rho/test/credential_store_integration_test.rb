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

  def test_loaded_credentials_keep_both_planes_and_redact_diagnostics
    issue
    credentials = CybrosAgent::Credentials.load(authority: nil, store: store, clock: -> { @now })
    assert_equal "sk-0", credentials.member_credential
    assert_equal "ek-0", credentials.executor_credential
    assert_equal 0, credentials.rotation
    [credentials.inspect, credentials.to_s].each do |diagnostic|
      %w[sk-0 ek-0 rt-0].each { |secret| refute_includes diagnostic, secret }
    end
  end

  def test_an_absent_vault_has_no_credential_owner
    assert_nil CybrosAgent::Credentials.load(authority: nil, store: store)
    report = Rho::Authority.new(oauth: nil, base_url: "https://nexus.example").check
    assert_equal({ member: :absent, executor_transport: :absent }, report.fetch(:planes))
  end
end
