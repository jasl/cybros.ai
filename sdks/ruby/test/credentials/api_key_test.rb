require "test_helper"
require "pp"

class CredentialsAPIKeyTest < Minitest::Test
  class MemoryStore
    attr_accessor :failure

    def initialize
      @document = nil
      @mutex = Mutex.new
    end

    def description = "in-memory credential store"
    def read = @document
    def delete = @document = nil
    def with_lock(&) = @mutex.synchronize(&)

    def write(document)
      raise failure if failure

      @document = JSON.parse(JSON.generate(document))
    end
  end

  class Authority
    attr_reader :revoked
    attr_accessor :fail_token

    def initialize = @revoked = []

    def revoke(token:)
      raise CybrosAgent::DeviceFlow::ServerError, "temporarily unavailable" if token == fail_token

      @revoked << token
    end
  end

  def setup
    @store = MemoryStore.new
    @authority = Authority.new
  end

  def issue(**tokens)
    CybrosAgent::Credentials::APIKey.issue(authority: @authority, store: @store, **tokens)
  end

  def load = CybrosAgent::Credentials.load(authority: @authority, store: @store)

  def test_static_planes_survive_reload_without_oauth_fields_or_refresh_capability
    credentials = issue(access_token: "member-key", executor_access_token: "executor-key")

    assert_equal "api_key", credentials.authentication_kind
    refute_predicate credentials, :refreshable?
    assert_equal "member-key", credentials.member_credential
    assert_equal "executor-key", credentials.executor_credential
    assert_equal %w[access_token authentication_kind connection executor_access_token version], @store.read.keys.sort
    assert_equal 2, @store.read.fetch("version")
    assert_equal "api_key", @store.read.fetch("authentication_kind")
    assert_instance_of CybrosAgent::Credentials::APIKey, load
    assert_equal "member-key", load.member_credential
    assert_equal "executor-key", load.executor_credential
    assert_empty @authority.revoked
  end

  def test_each_plane_can_be_stored_on_its_own
    { access_token: :member, executor_access_token: :executor, platform_access_token: :platform }.each do |field, plane|
      credentials = issue(**{ field => "#{plane}-key" })
      assert_equal "#{plane}-key", load.public_send("#{plane}_credential")
      %i[member executor platform].each do |candidate|
        assert_equal candidate == plane, credentials.public_send("#{candidate}_plane?")
        next if candidate == plane

        assert_raises(CybrosAgent::Credentials::PlaneUnavailable) { credentials.public_send("#{candidate}_credential") }
      end
    end
  end

  def test_keys_are_validated_before_a_document_is_published
    [nil, ""].each do |key|
      assert_raises(CybrosAgent::Credentials::StoreError) { issue(access_token: key) }
      assert_nil @store.read
    end
    expected = ENV["RBS_TEST_TARGET"] ? RBS::Test::Tester::TypeError : CybrosAgent::Credentials::StoreError
    assert_raises(expected) { issue(access_token: ["not-text"]) }
    assert_nil @store.read
  end

  def test_a_corrupted_document_is_refused_without_disclosing_its_values
    issue(access_token: "sk-cybros-api-v1-secret.value")
    original = @store.read
    [original.merge("authentication_kind" => "sk-cybros-api-v1-secret.value"),
     original.except("authentication_kind"), original.except("connection"),
     original.except("access_token"), original.merge("access_token" => ["sk-cybros-api-v1-secret.value"])].each do |document|
      @store.write(document)
      error = assert_raises(CybrosAgent::Credentials::StoreError) { load }
      refute_includes error.full_message, "secret.value"
    end
  end

  def test_revoke_presents_each_key_then_deletes_the_document
    credentials = issue(access_token: "member-key", executor_access_token: "executor-key", platform_access_token: "platform-key")

    assert_nil credentials.revoke
    assert_equal %w[member-key executor-key platform-key], @authority.revoked
    assert_nil @store.read
    assert_nil load
  end

  def test_partial_revocation_preserves_the_document_for_an_idempotent_retry
    credentials = issue(access_token: "member-key", executor_access_token: "executor-key")
    original = @store.read
    @authority.fail_token = "executor-key"

    assert_raises(CybrosAgent::DeviceFlow::ServerError) { credentials.revoke }
    assert_equal ["member-key"], @authority.revoked
    assert_equal original, @store.read

    @authority.fail_token = nil
    load.revoke
    assert_equal %w[member-key member-key executor-key], @authority.revoked
    assert_nil @store.read
  end

  def test_an_old_key_holder_cannot_revoke_or_delete_a_replacement
    old = issue(access_token: "old-member")
    replacement = issue(access_token: "new-member")

    assert_raises(CybrosAgent::Credentials::ConnectionSuperseded) { old.revoke }
    assert_equal "new-member", load.member_credential
    assert_equal "new-member", replacement.member_credential
    assert_empty @authority.revoked
  end

  def test_a_store_failure_does_not_return_an_unpublished_provider_or_disclose_the_key
    @store.failure = IOError.new("failed while writing sk-cybros-api-v1-secret.value")

    error = assert_raises(CybrosAgent::Credentials::StoreError) { issue(access_token: "sk-cybros-api-v1-secret.value") }
    assert_includes error.message, "IOError"
    refute_includes error.full_message, "secret.value"
    assert_nil @store.read
  end

  def test_an_already_published_document_remains_usable_after_an_unconfirmed_flush
    failure = Class.new(IOError) { include CybrosAgent::Credentials::Store::Published }
    @store.define_singleton_method(:write) do |document|
      super(document)
      raise failure, "directory flush failed"
    end

    credentials = issue(access_token: "member-key")
    assert_equal "member-key", credentials.member_credential
    assert_equal "member-key", load.member_credential
  end

  def test_provider_diagnostics_hide_every_key
    credentials = issue(access_token: "sk-cybros-api-v1-member.secret", executor_access_token: "sk-cybros-api-v1-executor.secret",
      platform_access_token: "sk-cybros-api-v1-platform.secret")

    [credentials.inspect, credentials.to_s, PP.pp(credentials, +"")].each do |diagnostic|
      refute_includes diagnostic, "member.secret"
      refute_includes diagnostic, "executor.secret"
      refute_includes diagnostic, "platform.secret"
    end
  end

  def test_a_refused_static_member_request_is_not_retried_and_leaves_executor_authority_independent
    credentials = issue(access_token: "member-key", executor_access_token: "executor-key")
    transport = CybrosAgentTest::FakeTransport.new([
      [401, {}, { "error" => { "code" => "unauthorized" } }],
      [200, {}, { "tasks" => [], "pagination" => { "next_after" => nil } }],
    ])
    client = CybrosAgent::Client.new(base_url: "http://example.test", transport: transport,
      credential_provider: -> { credentials.member_credential })
    executor = CybrosAgent::ExecutorClient.new(base_url: "http://example.test", transport: transport,
      credential_provider: -> { credentials.executor_credential })

    assert_raises(CybrosAgent::Api::Unauthorized) { client.workspaces.list }
    assert_empty executor.inbox.list.items
    assert_equal %w[member-key executor-key], transport.requests.map { |request| request.fetch(:credential) }
    assert_equal "executor-key", load.executor_credential
    assert_empty @authority.revoked
  end
end
