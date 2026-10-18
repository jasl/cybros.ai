require "test_helper"
require "stringio"

class ApiCredentialProviderTest < Minitest::Test
  BASE_URL = "https://nexus.example".freeze

  def test_an_existing_member_context_reads_its_provider_once_per_request_including_downloads
    token = "member-before"
    reads = 0
    transport = CybrosAgentTest::FakeTransport.new([
      [200, {}, { "workspaces" => [], "pagination" => { "next_after" => nil } }],
      [200, {}, { "workspaces" => [], "pagination" => { "next_after" => nil } }],
      [200, { "etag" => '"capture"' }, "file bytes"],
    ])
    client = CybrosAgent::Client.new(base_url: BASE_URL, transport: transport,
      credential_provider: -> { reads += 1; token })
    workspaces = client.workspaces
    uploads = client.uploads
    assert_equal 0, reads, "construction and scoping perform no credential IO"

    workspaces.list
    token = "member-after"
    workspaces.list
    token = "member-download"
    bytes = StringIO.new
    uploads.bytes("capture", bytes)

    assert_equal "file bytes", bytes.string
    assert_equal 3, reads
    assert_equal %w[member-before member-after member-download],
      transport.requests.map { |request| request.fetch(:credential) }
  end

  def test_an_existing_executor_context_reads_its_own_provider_without_replacing_the_context
    token = "executor-before"
    transport = CybrosAgentTest::FakeTransport.new(Array.new(2) {
      [200, {}, { "tasks" => [], "pagination" => { "next_after" => nil } }]
    })
    inbox = CybrosAgent::ExecutorClient.new(base_url: BASE_URL, transport: transport,
      credential_provider: -> { token }).inbox

    inbox.list
    token = "executor-after"
    inbox.list

    assert_equal %w[executor-before executor-after], transport.requests.map { |request| request.fetch(:credential) }
  end

  def test_a_provider_failure_is_propagated_without_sending_or_refreshing
    transport = CybrosAgentTest::FakeTransport.new([])
    client = CybrosAgent::Client.new(base_url: BASE_URL, transport: transport,
      credential_provider: -> { raise CybrosAgent::DeviceFlow::AuthorizationLostError })

    assert_raises(CybrosAgent::DeviceFlow::AuthorizationLostError) { client.workspaces.list }
    assert_empty transport.requests
  end

  def test_a_refused_request_is_not_retried_or_given_a_second_credential
    reads = 0
    transport = CybrosAgentTest::FakeTransport.new([[401, {}, { "error" => { "code" => "unauthorized" } }]])
    client = CybrosAgent::Client.new(base_url: BASE_URL, transport: transport,
      credential_provider: -> { reads += 1; "member-current" })

    assert_raises(CybrosAgent::Api::Unauthorized) { client.workspaces.list }
    assert_equal 1, reads
    assert_equal 1, transport.requests.length
  end

  def test_credentials_have_one_explicit_source_and_static_input_keeps_its_guard
    [{}, { credential: "member", credential_provider: -> { "another" } }].each do |options|
      assert_raises(ArgumentError) { CybrosAgent::Client.new(base_url: BASE_URL, **options) }
    end
    ["", false, 1, []].each do |credential|
      if ENV["RBS_TEST_TARGET"] && credential != ""
        # Runtime signatures reject a wrong type before the implementation's
        # guard. Both passes still prove refusal at their actual boundary.
        assert_raises(RBS::Test::Tester::TypeError) do
          CybrosAgent::Client.new(base_url: BASE_URL, credential: credential)
        end
      else
        error = assert_raises(ArgumentError) { CybrosAgent::Client.new(base_url: BASE_URL, credential: credential) }
        assert_equal "credential must be a nonempty String", error.message
      end
    end
  end
end
