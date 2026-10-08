module ModelProviders
  # One fixed administrator diagnostic, through the ordinary catalog and wire
  # adapters. It accepts no member content and retains no generated output.
  class TestConnection
    TIMEOUT_SECONDS = 30
    OUTPUT_TOKENS = 64
    # OpenAI's model_not_found also covers models inaccessible to the current
    # project. That ambiguous code cannot retire an Account-wide declaration.
    MISSING_MODEL_CODES = %w[model_not_exist model_retired model_decommissioned].freeze
    MODEL_ERROR_STATUSES = [400, 404, 410, 422].freeze

    Result = Data.define(:outcome, :duration_ms, :http_status) do
      def success? = outcome == :succeeded
    end

    def self.call(...) = new(...).call

    def initialize(account:, provider_id:, model_ref:)
      @account = account
      @provider_id = provider_id.to_s
      @model_ref = model_ref.to_s
    end

    def call
      @started_at = monotonic
      catalog = ModelSelection::Resolver.effective_provider_catalog(@account, ModelCatalog.current, @provider_id)
      provider = catalog.providers[@provider_id]
      model = catalog.models[@model_ref]
      unless provider && model && ModelProviderConfig.provider_lane_ref?(@provider_id, @model_ref)
        return result(:not_found)
      end
      return result(:provider_disabled) unless catalog.policies[@provider_id]&.enabled
      base_url = ModelCatalog.model_base_url(@model_ref, snapshot: catalog)
      return result(:endpoint_unconfigured) if base_url.nil?

      @profile = bounded_profile(provider, model)
      return result(:test_input_unavailable) unless test_input_available?

      credential = CredentialResolver.resolve(
        account: @account, provider_id: @provider_id, credential_lane: @profile.credential_lane,
        total_execution_deadline_seconds: @profile.total_execution_deadline_seconds, now: DatabaseClock.now
      )
      unless credential.resolved?
        return result(ModelSelection::Resolver::CREDENTIAL_REFUSALS.fetch(credential.outcome))
      end

      client = ModelCatalog::AssembleClient.call(
        profile: @profile, base_url: base_url, credential: credential.credential,
        host: "solid_queue", streaming: @profile.streams?
      )
      release_database_connections
      response = send_test(client)
      result(response_outcome(response), http_status: response.provider_response.status)
    rescue ModelCatalog::Unavailable
      result(:model_plane_unavailable)
    rescue SimpleInference::HTTPError => error
      result(http_outcome(error), http_status: error.status)
    rescue SimpleInference::Protocols::OpenAIResponses::ResponseFailedError => error
      result(structured_error_outcome([error.code]))
    rescue SimpleInference::Protocols::OpenAIResponses::StreamErrorEventError => error
      body = error.payload || {}
      fields = Hash.try_convert(body["error"]) || body
      result(structured_error_outcome([fields["code"], fields["type"]]))
    rescue SimpleInference::TimeoutError
      result(:timed_out)
    rescue SimpleInference::ConnectionError
      result(:connection_failed)
    rescue SimpleInference::DecodeError, SimpleInference::ProviderStreamInterruptedError
      result(:invalid_response)
    rescue SimpleInference::ValidationError, SimpleInference::CapabilityError
      result(:request_invalid)
    rescue SimpleInference::Error
      result(:provider_error)
    end

    private

      def bounded_profile(provider, model)
        profile = ModelCatalog::ProfileBuilder.call(model_ref: @model_ref, provider: provider, model: model)
        timeout = [profile.total_execution_deadline_seconds, TIMEOUT_SECONDS].min
        profile.with(total_execution_deadline_seconds: timeout,
          stream_idle_timeout_seconds: [profile.stream_idle_timeout_seconds, timeout / 2.0].min)
      end

      # The only required choices beyond a model ID are a declared speech
      # voice and audio input. Do not invent a voice or an unsupported codec.
      def test_input_available?
        case @profile.workload
        when "speech_generation" then speech_voice.present?
        when "transcription" then Array(@profile.mime_allowlist("audio")).include?("audio/wav")
        else true
        end
      end

      def speech_voice
        parameter = @profile.generation_parameters["voice"]
        parameter && (parameter.default || parameter.allowed_values&.first)
      end

      # Like ordinary dispatch, release a request's lease before provider IO.
      # Test transactions retain theirs; this operation acquires no locks.
      def release_database_connections
        return if ApplicationRecord.connection_pool.active_connection?&.transaction_open?

        ApplicationRecord.connection_handler.clear_active_connections!
      end

      def send_test(client)
        model = @profile.model_pin
        case @profile.workload
        when "text_generation"
          request = client.responses.compile(model: model, input: "Reply with OK.",
            stream: @profile.streams?, **text_options)
          response = client.execute(request)
          if request.stream?
            response.each { |_event| }
            response.final_result
          else
            response
          end
        when "embedding"
          client.embeddings.create(model: model, input: "Connection test.")
        when "image_generation"
          client.images.generate(model: model, prompt: "A plain blue square.", n: 1)
        when "speech_generation"
          client.audio.speech.create(model: model, input: "Connection test.", voice: speech_voice)
        when "transcription"
          client.audio.transcriptions.create(model: model,
            file: { filename: "connection-test.wav", content_type: "audio/wav", body: silent_audio })
        else
          raise ArgumentError, "unmapped diagnostic workload #{@profile.workload}"
        end
      end

      def text_options
        options = ModelRequests::WireLowering::TABLE.fetch(@profile.adapter_profile).fetch(:options)
        return {} unless options.key?("max_output_tokens")

        parameter = @profile.generation_parameters["max_output_tokens"]
        tokens = if parameter&.allowed_values
          parameter.allowed_values.min
        else
          requested = [OUTPUT_TOKENS, parameter&.minimum || 1].max
          [requested, parameter&.maximum, @profile.local_safety_limits.output_tokens].compact.min
        end
        { max_output_tokens: tokens }
      end

      # One second of mono 16-bit PCM silence is a valid, small transcription
      # request. Its valid response can be an empty transcript.
      def silent_audio
        samples = "\0".b * 32_000
        "RIFF".b + [36 + samples.bytesize].pack("V") + "WAVEfmt ".b +
          [16, 1, 1, 16_000, 32_000, 2, 16].pack("VvvVVvv") +
          "data".b + [samples.bytesize].pack("V") + samples
      end

      def response_outcome(response)
        valid = case @profile.workload
        when "text_generation"
          quality = SimpleInference::FinishQuality.for(
            adapter_profile: @profile.adapter_profile, detail: response.finish_detail
          )
          return :request_rejected if SimpleInference::FinishQuality::DECLINED.include?(quality)
          return :provider_error if quality == SimpleInference::FinishQuality::ERROR

          response.output_text.present? || response.output_items.any?
        when "embedding" then response.embeddings.any?
        when "image_generation" then response.images.any?
        when "speech_generation" then response.audio.present?
        when "transcription" then !response.text.nil?
        else raise ArgumentError, "unmapped diagnostic workload #{@profile.workload}"
        end
        valid ? :succeeded : :invalid_response
      end

      def http_outcome(error)
        case error.status
        when 401, 403 then :authentication_failed
        when 402 then :quota_exceeded
        when 429 then :rate_limited
        else
          return :provider_error unless MODEL_ERROR_STATUSES.include?(error.status)

          body = Hash.try_convert(error.body) || {}
          fields = Hash.try_convert(body["error"]) || {}
          structured_error_outcome([fields["code"], fields["type"]])
        end
      end

      # A generic 404, message fragment, authorization failure or omitted
      # directory entry does not establish that this particular model is gone.
      def structured_error_outcome(codes)
        codes.any? { |code| MISSING_MODEL_CODES.include?(code) } ? :model_not_found : :provider_error
      end

      def result(outcome, http_status: nil)
        Result.new(outcome: outcome, duration_ms: ((monotonic - @started_at) * 1000).round, http_status: http_status)
      end

      def monotonic = Process.clock_gettime(Process::CLOCK_MONOTONIC)
  end
end
