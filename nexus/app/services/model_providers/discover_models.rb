require "timeout"

module ModelProviders
  # An explicit administrator directory sync. Definitions, capabilities and prices stay authored.
  class DiscoverModels
    MAX_BYTES = 2 * 1024 * 1024
    MAX_MODELS = 1024
    MAX_PAGES = 16
    TIMEOUT_SECONDS = 20
    MAX_CURSOR_BYTES = 4096
    Result = Data.define(:outcome, :models) do
      def success? = outcome == :discovered
    end
    Page = Data.define(:models, :next_cursor)
    class InvalidDirectory < StandardError; end

    def self.call(...) = new(...).call

    def initialize(account:, provider_id:, expected_lock_version:)
      @account = account
      @provider_id = provider_id.to_s
      @expected_lock_version = expected_lock_version
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
      request_headers = headers(format, credential)
      release_connection
      models = fetch_directory("#{config.base_url}#{config.api_prefix}/models", request_headers, format)
      available_ids = models.pluck(:id).to_set
      own_models = catalog.models.select { |ref, _| Nexus::ModelRef.parse(ref).provider_id == @provider_id }
      missing_refs = own_models.filter_map do |ref, model|
        ref unless available_ids.include?(model["model_id"] || Nexus::ModelRef.parse(ref).model_ref)
      end
      change = SyncModelAvailability.call(
        account: @account, provider_id: @provider_id, expected_lock_version: @expected_lock_version,
        model_refs: own_models.keys, unavailable_model_refs: missing_refs
      )
      change.done? ? Result.new(outcome: :discovered, models: models) : failure(change.outcome)
    rescue HTTPX::Error, JSON::ParserError, InvalidDirectory
      failure(:discovery_failed)
    end

    private

      def release_connection
        return if ApplicationRecord.connection_pool.active_connection?&.transaction_open?

        ApplicationRecord.connection_handler.clear_active_connections!
      end

      def fetch_directory(url, headers, format)
        deadline = monotonic_time + TIMEOUT_SECONDS
        bytes = 0
        models = []
        cursor = nil
        seen_cursors = Set.new
        pages = 0

        # This session has no redirect or retry plugin. Every page uses the same
        # configured endpoint and shares one time, byte and model budget.
        HTTPX.plugin(:stream).wrap do |client|
          # HTTPX starts its request timer after connection setup. Bound the
          # entire read-only fetch here; session cleanup and policy writes stay
          # outside the interruptible block.
          Timeout.timeout(remaining_time(deadline), InvalidDirectory) do
            loop do
              pages += 1
              raise InvalidDirectory if pages > MAX_PAGES

              remaining = remaining_time(deadline)
              response = client.get(url, headers: headers, params: page_parameters(format, cursor), stream: true,
                timeout: { connect_timeout: [5, remaining].min, request_timeout: remaining,
                           read_timeout: remaining, operation_timeout: remaining })
              body = +""
              response.each do |chunk|
                remaining_time(deadline)
                bytes += chunk.bytesize
                raise InvalidDirectory if bytes > MAX_BYTES

                body << chunk
              end
              raise InvalidDirectory unless response.status.between?(200, 299)

              page = directory_page(body, format)
              models.concat(page.models)
              raise InvalidDirectory if models.length > MAX_MODELS

              remaining_time(deadline)
              cursor = page.next_cursor
              break if cursor.nil?

              raise InvalidDirectory unless seen_cursors.add?(cursor)
            end
          end
        end
        models.uniq { |model| model.fetch(:id) }.sort_by { |model| model.fetch(:id) }
      end

      def monotonic_time = Process.clock_gettime(Process::CLOCK_MONOTONIC)

      def remaining_time(deadline)
        remaining = deadline - monotonic_time
        raise InvalidDirectory unless remaining.positive?

        remaining
      end

      def page_parameters(format, cursor)
        case format
        when "anthropic_messages"
          { limit: 1000 }.tap { |params| params[:after_id] = cursor unless cursor.nil? }
        when "gemini_generate_content", "gemini_embeddings"
          { pageSize: 1000 }.tap { |params| params[:pageToken] = cursor unless cursor.nil? }
        when "openrouter_chat"
          # OpenRouter otherwise filters the directory to text output models.
          { output_modalities: "all" }
        else
          {}
        end
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

      def directory_page(body, format)
        payload = Hash.try_convert(JSON.parse(body))
        raise InvalidDirectory if payload.nil?

        gemini = format.start_with?("gemini_")
        rows = Array.try_convert(payload[gemini ? "models" : "data"])
        raise InvalidDirectory if rows.nil? || rows.length > MAX_MODELS

        models = rows.map do |value|
          row = Hash.try_convert(value)
          raise InvalidDirectory if row.nil?

          id = String.try_convert(row[gemini ? "name" : "id"])
          raise InvalidDirectory if id.nil? || id.strip.empty? || id.bytesize > 1024

          id = id.delete_prefix("models/") if gemini
          raise InvalidDirectory if id.strip.empty?

          display_name = String.try_convert(row[gemini ? "displayName" : "display_name"])
          { id: id, display_name: display_name&.first(256) }
        end
        next_cursor = continuation(payload, format)
        raise InvalidDirectory if next_cursor && models.empty?

        Page.new(models: models, next_cursor: next_cursor)
      end

      def continuation(payload, format)
        case format
        when "anthropic_messages"
          case payload["has_more"]
          when true then cursor_value(payload["last_id"])
          when false then nil
          else raise InvalidDirectory
          end
        when "gemini_generate_content", "gemini_embeddings"
          cursor_value(payload["nextPageToken"]) if payload.key?("nextPageToken")
        else
          # These directory contracts return the full list. Never accept an
          # advertised continuation as evidence that an absent model is gone.
          raise InvalidDirectory if payload.key?("has_more") && payload["has_more"] != false
          raise InvalidDirectory if payload["nextPageToken"] || payload["next_page"] || payload["next"]
          if payload.key?("links")
            links = Hash.try_convert(payload["links"])
            raise InvalidDirectory if links.nil? || links["next"]
          end
          if payload.key?("total_count") && payload["total_count"] != payload.fetch("data").length
            raise InvalidDirectory
          end
          nil
        end
      end

      def cursor_value(value)
        cursor = String.try_convert(value)
        raise InvalidDirectory if cursor.nil? || cursor.strip.empty? || cursor.bytesize > MAX_CURSOR_BYTES

        cursor
      end

      def failure(outcome) = Result.new(outcome: outcome, models: [])
  end
end
