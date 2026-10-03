require "test_helper"
require "socket"

class ModelProviders::DiscoverModelsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  test "directory discovery normalizes the same origin and prefixes as inference" do
    [["", "/v1/models"], ["/v1", "/v1/models"], ["/api", "/api/v1/models"]].each do |prefix, path|
      with_directory(body: { data: [{ id: "sample-text", display_name: "Sample Text" }, { id: "sample-text" }] }.to_json) do |origin, requests|
        configure(origin + prefix, credentials: "api_key")
        ModelProviders::SetAPIKey.call(account: @account, provider_id: "local", api_key: "test-directory-key")
        result = ModelProviders::DiscoverModels.call(account: @account, provider_id: "local")
        assert_predicate result, :success?
        assert_equal [{ id: "sample-text", display_name: "Sample Text" }], result.models
        request = requests.pop
        assert_equal "GET #{path} HTTP/1.1", request.fetch(:request_line)
        assert_equal "Bearer test-directory-key", request.fetch(:headers).fetch("authorization")
      end
    end
  end

  test "Gemini directory names become model IDs and use their own API prefix" do
    with_directory(body: { models: [{ name: "models/gemini-custom", displayName: "Gemini custom" }] }.to_json) do |origin, requests|
      configure("#{origin}/v1beta", format: "gemini_generate_content")
      result = ModelProviders::DiscoverModels.call(account: @account, provider_id: "local")
      assert_predicate result, :success?
      assert_equal [{ id: "gemini-custom", display_name: "Gemini custom" }], result.models
      assert_equal "GET /v1beta/models HTTP/1.1", requests.pop.fetch(:request_line)
    end
  end

  test "directory failures do not mutate definitions or follow redirects" do
    with_directory(body: "", status: 302, headers: { "Location" => "http://127.0.0.1:1/do-not-follow" }) do |origin, requests|
      policy = configure(origin)
      before = policy.attributes
      result = ModelProviders::DiscoverModels.call(account: @account, provider_id: "local")
      assert_equal :discovery_failed, result.outcome
      assert_empty result.models
      assert_equal before, policy.reload.attributes
      assert_equal "GET /v1/models HTTP/1.1", requests.pop.fetch(:request_line)
    end
  end

  test "a malformed or oversized directory is a bounded failure" do
    ["not-json", { data: ["not-a-model"] }.to_json, "x" * (ModelProviders::DiscoverModels::MAX_BYTES + 1)].each do |body|
      with_directory(body: body) do |origin, _requests|
        configure(origin)
        result = ModelProviders::DiscoverModels.call(account: @account, provider_id: "local")
        assert_equal :discovery_failed, result.outcome
        assert_empty result.models
      end
    end
  end

  test "a missing API key refuses before provider IO even when the lane is disabled" do
    configure("http://127.0.0.1:1", credentials: "api_key")
    result = ModelProviders::DiscoverModels.call(account: @account, provider_id: "local")
    assert_equal :missing_credential, result.outcome
  end

  private

    def configure(url, credentials: "none", format: "openai_compatible_chat")
      policy = ModelProviderPolicy.find_by(account: @account, provider_id: "local")
      result = ModelProviders::SetDefinition.call(account: @account, provider_id: "local",
        expected_lock_version: policy&.lock_version,
        definition: { "base_url" => url, "api_format" => format, "credentials" => credentials })
      assert_predicate result, :done?
      result.policy
    end

    def with_directory(body:, status: 200, headers: {})
      server = TCPServer.new("127.0.0.1", 0)
      requests = Queue.new
      worker = Thread.new do
        socket = server.accept
        request_line = socket.gets.strip
        fields = {}
        while (line = socket.gets) && line != "\r\n"
          name, value = line.split(":", 2)
          fields[name.downcase] = value.strip
        end
        requests << { request_line: request_line, headers: fields }
        response_headers = { "Content-Type" => "application/json", "Content-Length" => body.bytesize, "Connection" => "close" }.merge(headers)
        socket.write("HTTP/1.1 #{status} Directory\r\n#{response_headers.map { |name, value| "#{name}: #{value}\r\n" }.join}\r\n#{body}")
      rescue Errno::EPIPE, Errno::ECONNRESET
        nil
      ensure
        socket&.close
      end
      yield "http://127.0.0.1:#{server.addr[1]}", requests
    ensure
      server&.close
      worker&.kill
      worker&.join
    end
end
