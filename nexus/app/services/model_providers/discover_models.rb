module ModelProviders
  # An explicit administrator request for upstream IDs; no model facts are inferred.
  class DiscoverModels
    MAX_BYTES = 2 * 1024 * 1024
    MAX_MODELS = 1024
    Result = Data.define(:outcome, :models) do
      def success? = outcome == :discovered
    end
    class InvalidDirectory < StandardError; end

    def self.call(...) = new(...).call

    def initialize(account:, provider_id:)
      @account = account
      @provider_id = provider_id.to_s
    end

    def call
      catalog = ModelSelection::Resolver.effective_provider_catalog(@account, ModelCatalog.current, @provider_id)
      provider = catalog.providers[@provider_id]
      return failure(:not_found) if provider.nil?
      return failure(:unsupported_protocol) if provider.fetch("api_format") == "codex_responses"

      lane = ModelCatalog::ProfileBuilder.credential_lane(provider)
      return failure(:unsupported_protocol) if lane == "oauth_tokens"
      credential = ModelProviderCredential.find_by(account: @account, provider_id: @provider_id) if lane != "none"
      if lane != "none" && (credential.nil? || credential.material_kind != lane || credential.reauthorization_required?)
        return failure(:missing_credential)
      end

      format = provider.fetch("api_format")
      prefix = format.start_with?("gemini_") ? "/v1beta" : "/v1"
      config = SimpleInference::Config.new(base_url: provider.fetch("base_url"), api_prefix: prefix)
      body = fetch_directory("#{config.base_url}#{config.api_prefix}/models", headers(format, credential))
      Result.new(outcome: :discovered, models: directory_models(body, format))
    rescue HTTPX::Error, JSON::ParserError, InvalidDirectory
      failure(:discovery_failed)
    end

    private

      def fetch_directory(url, headers)
        body = +""
        HTTPX.plugin(:stream).with(timeout: { connect_timeout: 5, request_timeout: 20, operation_timeout: 20 }).wrap do |client|
          response = client.get(url, headers: headers, stream: true)
          response.each do |chunk|
            raise InvalidDirectory if body.bytesize + chunk.bytesize > MAX_BYTES

            body << chunk
          end
          raise InvalidDirectory unless response.status.between?(200, 299)
        end
        body
      end

      def headers(format, credential)
        result = { "accept" => "application/json" }
        result["anthropic-version"] = "2023-06-01" if format == "anthropic_messages"
        return result if credential.nil?

        key = credential.secret
        case format
        when "anthropic_messages" then result.merge("x-api-key" => key)
        when "gemini_generate_content", "gemini_embeddings" then result.merge("x-goog-api-key" => key)
        else result.merge("authorization" => "Bearer #{key}")
        end
      end

      def directory_models(body, format)
        payload = Hash.try_convert(JSON.parse(body))
        raise InvalidDirectory if payload.nil?

        gemini = format.start_with?("gemini_")
        rows = Array.try_convert(payload[gemini ? "models" : "data"])
        raise InvalidDirectory if rows.nil? || rows.length > MAX_MODELS

        rows.map do |value|
          row = Hash.try_convert(value)
          raise InvalidDirectory if row.nil?

          id = String.try_convert(row[gemini ? "name" : "id"])
          raise InvalidDirectory if id.nil? || id.strip.empty? || id.bytesize > 1024

          display_name = String.try_convert(row[gemini ? "displayName" : "display_name"])
          { id: gemini ? id.delete_prefix("models/") : id, display_name: display_name&.first(256) }
        end.uniq { |model| model.fetch(:id) }.sort_by { |model| model.fetch(:id) }
      end

      def failure(outcome) = Result.new(outcome: outcome, models: [])
  end
end
