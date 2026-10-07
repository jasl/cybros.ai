require "test_helper"
require "socket"
require "openssl"

class ModelProviders::DiscoverModelsTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
  end

  test "directory discovery normalizes the same origin and prefixes as inference" do
    [["", "/v1/models"], ["/v1", "/v1/models"], ["/api", "/api/v1/models"]].each do |prefix, path|
      with_directory(body: { data: [{ id: "sample-text", display_name: "Sample Text" }, { id: "sample-text" }] }.to_json) do |origin, requests|
        configure(origin + prefix, credentials: "api_key")
        ModelProviders::SetAPIKey.call(account: @account, provider_id: "local", api_key: "test-directory-key")
        result = discover
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
      result = discover
      assert_predicate result, :success?
      assert_equal [{ id: "gemini-custom", display_name: "Gemini custom" }], result.models
      assert_equal "GET /v1beta/models?pageSize=1000 HTTP/1.1", requests.pop.fetch(:request_line)
    end
  end

  test "Anthropic collects every page before returning a sorted unique directory" do
    pages = [
      { body: { data: [{ id: "model-z", display_name: "Model Z" }], has_more: true, last_id: "model-z" }.to_json },
      { body: { data: [{ id: "model-a" }, { id: "model-z" }], has_more: false, last_id: "model-z" }.to_json },
    ]
    with_pages(pages) do |origin, requests|
      configure(origin, format: "anthropic_messages", credentials: "api_key")
      ModelProviders::SetAPIKey.call(account: @account, provider_id: "local", api_key: "test-directory-key")
      result = discover

      assert_predicate result, :success?
      assert_equal [{ id: "model-a", display_name: nil }, { id: "model-z", display_name: "Model Z" }], result.models
      first, second = requests.pop, requests.pop
      assert_equal "GET /v1/models?limit=1000 HTTP/1.1", first.fetch(:request_line)
      assert_equal "GET /v1/models?limit=1000&after_id=model-z HTTP/1.1", second.fetch(:request_line)
      [first, second].each do |request|
        assert_equal "test-directory-key", request.fetch(:headers).fetch("x-api-key")
        assert_equal "2023-06-01", request.fetch(:headers).fetch("anthropic-version")
      end
    end
  end

  test "Gemini follows opaque page tokens for both directory formats on the configured endpoint" do
    %w[gemini_generate_content gemini_embeddings].each do |format|
      pages = [
        { body: { models: [{ name: "models/first" }], nextPageToken: "opaque&next=/other" }.to_json },
        { body: { models: [{ name: "models/second" }] }.to_json },
      ]
      with_pages(pages) do |origin, requests|
        configure("#{origin}/custom", format: format)
        result = discover

        assert_predicate result, :success?
        assert_equal %w[first second], result.models.pluck(:id)
        first, second = requests.pop, requests.pop
        assert_equal "GET /custom/v1beta/models?pageSize=1000 HTTP/1.1", first.fetch(:request_line)
        uri = URI.parse(second.fetch(:request_line).split.fetch(1))
        assert_equal "/custom/v1beta/models", uri.path
        assert_equal({ "pageSize" => "1000", "pageToken" => "opaque&next=/other" }, URI.decode_www_form(uri.query).to_h)
      end
    end
  end

  test "OpenRouter requests all modalities without requesting a partial page" do
    body = { data: [{ id: "text-model" }, { id: "embedding-model" }], total_count: 2, links: { next: nil } }.to_json
    with_directory(body: body) do |origin, requests|
      configure(origin, format: "openrouter_chat")
      result = discover

      assert_predicate result, :success?
      assert_equal %w[embedding-model text-model], result.models.pluck(:id)
      assert_equal "GET /v1/models?output_modalities=all HTTP/1.1", requests.pop.fetch(:request_line)
    end
  end

  test "a failed later page discards the directory without retrying or following redirects" do
    [302, 401, 429, 500].each do |status|
      pages = [
        { body: { models: [{ name: "models/first" }], nextPageToken: "second" }.to_json },
        { body: "unavailable", status: status, headers: { "Location" => "http://127.0.0.1:1/do-not-follow", "Retry-After" => "0" } },
      ]
      with_pages(pages) do |origin, requests|
        policy = configure(origin, format: "gemini_generate_content")
        before = policy.attributes
        result = discover

        assert_equal :discovery_failed, result.outcome
        assert_empty result.models
        assert_equal 2, requests.size
        assert_equal before, policy.reload.attributes
      end
    end
  end

  test "missing malformed empty or repeated cursors cannot produce a complete directory" do
    anthropic_payloads = [
      { data: [{ id: "first" }] },
      { data: [{ id: "first" }], has_more: "false" },
      { data: [{ id: "first" }], has_more: true },
      { data: [{ id: "first" }], has_more: true, last_id: "" },
      { data: [{ id: "first" }], has_more: true, last_id: 123 },
      { data: [], has_more: true, last_id: "first" },
    ]
    gemini_payloads = [nil, "", 123, "x" * (ModelProviders::DiscoverModels::MAX_CURSOR_BYTES + 1)].map do |cursor|
      { models: [{ name: "models/first" }], nextPageToken: cursor }
    end
    { "anthropic_messages" => anthropic_payloads, "gemini_generate_content" => gemini_payloads }.each do |format, payloads|
      payloads.each do |payload|
        with_directory(body: payload.to_json) do |origin, _requests|
          configure(origin, format: format)
          result = discover
          assert_equal :discovery_failed, result.outcome
          assert_empty result.models
        end
      end
    end

    page = { body: { models: [{ name: "models/first" }], nextPageToken: "repeated" }.to_json }
    with_pages([page, page]) do |origin, requests|
      configure(origin, format: "gemini_generate_content")
      result = discover
      assert_equal :discovery_failed, result.outcome
      assert_empty result.models
      assert_equal 2, requests.size
    end
  end

  test "a nominally unpaginated directory rejects continuation and count mismatches" do
    [{ has_more: true }, { nextPageToken: "next" }, { next_page: "next" },
     { links: { next: "/models?offset=1" } }, { links: [] }, { total_count: 2 }].each do |pagination|
      with_directory(body: { data: [{ id: "first" }] }.merge(pagination).to_json) do |origin, _requests|
        configure(origin, format: "openrouter_chat")
        result = discover
        assert_equal :discovery_failed, result.outcome
        assert_empty result.models
      end
    end
  end

  test "page model and byte limits cover the whole directory" do
    first = { body: { models: [{ name: "models/first" }], nextPageToken: "second" }.to_json }
    second = { body: { models: [{ name: "models/second" }], nextPageToken: "third" }.to_json }
    limits = { MAX_PAGES: 2, MAX_MODELS: 1, MAX_BYTES: first.fetch(:body).bytesize + 1 }
    limits.each do |constant, limit|
      with_pages([first, second]) do |origin, requests|
        configure(origin, format: "gemini_generate_content")
        result = stub_const(ModelProviders::DiscoverModels, constant, limit) do
          discover
        end
        assert_equal :discovery_failed, result.outcome
        assert_empty result.models
        assert_equal 2, requests.size
      end
    end
  end

  test "the operation deadline is shared by every page" do
    pages = [
      { body: { models: [{ name: "models/first" }], nextPageToken: "second" }.to_json, delay: 0.15 },
      { body: { models: [{ name: "models/second" }] }.to_json, delay: 0.15 },
    ]
    with_pages(pages) do |origin, requests|
      configure(origin, format: "gemini_generate_content")
      result = stub_const(ModelProviders::DiscoverModels, :TIMEOUT_SECONDS, 0.25) do
        discover
      end
      assert_equal :discovery_failed, result.outcome
      assert_empty result.models
      assert_equal 2, requests.size
    end
  end

  test "the total deadline includes a slow TLS handshake and the subsequent response wait" do
    context = local_tls_context
    trust = OpenSSL::X509::Store.new
    trust.add_cert(context.cert)
    client = HTTPX.plugin(:stream).with(ssl: { cert_store: trust })
    pages = [{ body: { data: [] }.to_json, delay: 0.8 }]
    with_pages(pages, tls: context, handshake_delay: 0.3) do |origin, requests|
      policy = configure(origin)
      add_model("local/existing")
      before = policy.reload.attributes
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      result = stub_const(ModelProviders::DiscoverModels, :TIMEOUT_SECONDS, 0.6) do
        HTTPX.stub(:plugin, client) { discover }
      end
      elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

      assert_equal :discovery_failed, result.outcome
      assert_empty result.models
      assert_equal 1, requests.size, "the TLS handshake completed before the response wait timed out"
      assert_operator elapsed, :<, 0.8
      assert_equal before, policy.reload.attributes
    end
  end

  test "directory failures do not mutate definitions or follow redirects" do
    with_directory(body: "", status: 302, headers: { "Location" => "http://127.0.0.1:1/do-not-follow" }) do |origin, requests|
      policy = configure(origin)
      before = policy.attributes
      result = discover
      assert_equal :discovery_failed, result.outcome
      assert_empty result.models
      assert_equal before, policy.reload.attributes
      assert_equal "GET /v1/models HTTP/1.1", requests.pop.fetch(:request_line)
    end
  end

  test "missing directory IDs retain existing restrictions and failures change nothing" do
    [[200, { data: [] }.to_json], [200, { data: [{ id: "another-model" }] }.to_json],
     [404, "unsupported"], [405, "unsupported"], [503, "unavailable"]].each do |status, body|
      with_directory(body: body, status: status) do |origin, _requests|
        policy = configure(origin)
        policy.put_entry("local/existing", { "op" => "upsert", "model" => { "model_id" => "existing" } })
        policy.set_model_visibility("local/existing", visible: false)
        policy.set_model_availability("local/existing", available: false)
        policy.save!
        before = policy.attributes
        result = discover
        assert_equal status == 200, result.success?
        assert_equal before, policy.reload.attributes
      end
    end
  end

  test "a successful directory matches effective upstream IDs and preserves manual hiding and unrelated history" do
    with_directory(body: { data: [{ id: "upstream-name" }, { id: "tail-name" }] }.to_json) do |origin, _requests|
      policy = configure(origin)
      add_model("local/alias", model_id: "upstream-name")
      add_model("local/tail-name")
      add_model("local/missing")
      policy.reload.set_model_visibility("local/alias", visible: false)
      policy.set_model_availability("local/alias", available: false)
      policy.set_model_availability("local/tail-name", available: false)
      policy.set_model_availability("local/historical", available: false)
      policy.save!
      before = policy.model_overrides.deep_dup
      version = policy.lock_version

      assert_predicate discover, :success?

      assert_equal version + 1, policy.reload.lock_version
      assert_equal %w[local/historical local/missing], policy.model_overrides.fetch("unavailable_models")
      assert_equal before.except("unavailable_models"), policy.model_overrides.except("unavailable_models")
    end
  end

  test "a successful empty directory marks every current model unavailable" do
    with_directory(body: { data: [] }.to_json) do |origin, _requests|
      policy = configure(origin)
      add_model("local/first")
      add_model("local/second")

      assert_predicate discover, :success?

      assert_equal %w[local/first local/second], policy.reload.model_overrides.fetch("unavailable_models")
    end
  end

  test "a stale directory observation cannot overwrite an intervening provider edit" do
    with_directory(body: { data: [] }.to_json) do |origin, _requests|
      policy = configure(origin)
      add_model("local/first")
      old_version = policy.reload.lock_version
      policy.update!(enabled: true)
      before = policy.attributes

      result = discover(version: old_version)

      assert_equal :stale, result.outcome
      assert_empty result.models
      assert_equal before, policy.reload.attributes
    end
  end

  test "a directory for file-defined models creates one disabled availability anchor when necessary" do
    with_directory(body: { data: [] }.to_json) do |origin, _requests|
      snapshot = ModelCatalog.current.with(
        providers: { "local" => { "base_url" => origin, "api_format" => "openai_compatible_chat", "credentials" => "none" } },
        models: { "local/file-model" => {} }, selectors: {}
      )
      ModelCatalog.stub(:current, snapshot) do
        assert_predicate discover(version: nil), :success?
      end
      policy = ModelProviderConfig.find_by!(account: @account, provider_id: "local")
      assert_equal 0, policy.lock_version
      refute_predicate policy, :enabled?
      assert_nil policy.provider_definition
      assert_equal ["local/file-model"], policy.model_overrides.fetch("unavailable_models")
    end
  end

  test "a successful directory cannot partially save an over-limit availability document" do
    with_directory(body: { data: [] }.to_json) do |origin, _requests|
      policy = configure(origin)
      refs = (0..ModelProviderConfig::MAX_OVERRIDE_REFS).map { |index| "local/model-#{index}" }
      snapshot = ModelCatalog.current.with(models: refs.index_with { {} }, selectors: {})
      before = policy.attributes
      result = ModelCatalog.stub(:current, snapshot) { discover }

      assert_equal :invalid, result.outcome
      assert_empty result.models
      assert_equal before, policy.reload.attributes
    end
  end

  test "a malformed or oversized directory is a bounded failure" do
    ["not-json", { data: ["not-a-model"] }.to_json, "x" * (ModelProviders::DiscoverModels::MAX_BYTES + 1)].each do |body|
      with_directory(body: body) do |origin, _requests|
        configure(origin)
        result = discover
        assert_equal :discovery_failed, result.outcome
        assert_empty result.models
      end
    end
  end

  test "a missing API key refuses before provider IO even when the lane is disabled" do
    configure("http://127.0.0.1:1", credentials: "api_key")
    result = discover
    assert_equal :missing_credential, result.outcome
  end

  private

    def discover(version: ModelProviderConfig.find_by(account: @account, provider_id: "local")&.lock_version)
      ModelProviders::DiscoverModels.call(account: @account, provider_id: "local", expected_lock_version: version)
    end

    def add_model(ref, model_id: nil)
      model = model_id ? { "model_id" => model_id } : {}
      result = ModelProviders::UpsertModelOverride.call(account: @account, provider_id: "local",
        model_ref: ref, model: model, validate_definition: true,
        expected_lock_version: ModelProviderConfig.find_by!(account: @account, provider_id: "local").lock_version)
      assert_predicate result, :done?
    end

    def configure(url, credentials: "none", format: "openai_compatible_chat")
      policy = ModelProviderConfig.find_by(account: @account, provider_id: "local")
      result = ModelProviders::SetDefinition.call(account: @account, provider_id: "local",
        expected_lock_version: policy&.lock_version,
        definition: { "base_url" => url, "api_format" => format, "credentials" => credentials })
      assert_predicate result, :done?
      result.policy
    end

    def with_directory(body:, status: 200, headers: {})
      with_pages([{ body: body, status: status, headers: headers }]) { |origin, requests| yield origin, requests }
    end

    def local_tls_context
      key = OpenSSL::PKey::RSA.new(2048)
      certificate = OpenSSL::X509::Certificate.new
      certificate.version = 2
      certificate.serial = 1
      certificate.subject = OpenSSL::X509::Name.parse("/CN=localhost")
      certificate.issuer = certificate.subject
      certificate.public_key = key.public_key
      certificate.not_before = Time.now - 60
      certificate.not_after = Time.now + 300
      extensions = OpenSSL::X509::ExtensionFactory.new
      extensions.subject_certificate = certificate
      extensions.issuer_certificate = certificate
      certificate.add_extension(extensions.create_extension("basicConstraints", "CA:TRUE", true))
      certificate.add_extension(extensions.create_extension("subjectAltName", "DNS:localhost,IP:127.0.0.1"))
      certificate.sign(key, OpenSSL::Digest::SHA256.new)
      OpenSSL::SSL::SSLContext.new.tap do |context|
        context.cert = certificate
        context.key = key
      end
    end

    def with_pages(responses, tls: nil, handshake_delay: 0)
      server = TCPServer.new("127.0.0.1", 0)
      requests = Queue.new
      worker = Thread.new do
        socket = nil
        responses.each do |response|
          socket = server.accept
          if tls
            socket = OpenSSL::SSL::SSLSocket.new(socket, tls)
            socket.sync_close = true
            sleep handshake_delay
            socket.accept
          end
          request_line = socket.gets.strip
          fields = {}
          while (line = socket.gets) && line != "\r\n"
            name, value = line.split(":", 2)
            fields[name.downcase] = value.strip
          end
          requests << { request_line: request_line, headers: fields }
          body = response.fetch(:body)
          status = response.fetch(:status, 200)
          response_headers = { "Content-Type" => "application/json", "Content-Length" => body.bytesize, "Connection" => "close" }.merge(response.fetch(:headers, {}))
          sleep(response.fetch(:delay, 0))
          socket.write("HTTP/1.1 #{status} Directory\r\n#{response_headers.map { |name, value| "#{name}: #{value}\r\n" }.join}\r\n#{body}")
          socket.close
        end
      rescue Errno::EPIPE, Errno::ECONNRESET, OpenSSL::SSL::SSLError
        nil
      ensure
        socket&.close
      end
      yield "#{tls ? "https" : "http"}://127.0.0.1:#{server.addr[1]}", requests
    ensure
      server&.close
      worker&.kill
      worker&.join
    end
end
