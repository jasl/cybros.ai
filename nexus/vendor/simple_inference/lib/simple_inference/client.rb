module SimpleInference
  class Client
    attr_reader :config, :execution_profile

    # The connection settings (parsed once into the Config every protocol
    # receives by reference) plus the one audited execution profile the
    # client is bound to. A keyword Ruby does not know raises ArgumentError.
    def initialize(execution_profile:, **connection)
      @execution_profile = validated_execution_profile(execution_profile)
      @config = Config.new(**connection)
    end

    def adapter
      @config.adapter
    end

    def responses
      @responses ||= Resources::Responses.new(client: self)
    end

    def images
      @images ||= Resources::Images.new(client: self)
    end

    def audio
      @audio ||= Resources::Audio.new(client: self)
    end

    def embeddings
      @embeddings ||= Resources::Embeddings.new(client: self)
    end

    def execute(compiled_request)
      compiled_request.execute(config)
    end

    private

    # The profile is the caller's boundary value: composed by the catalog,
    # never a Hash — checked once at the client's door.
    def validated_execution_profile(profile)
      return profile if profile.is_a?(ExecutionProfile)

      raise SimpleInference::ConfigurationError,
            "execution_profile is required and must be a SimpleInference::ExecutionProfile " \
            "(compose one from an api_format and your own model configuration)"
    end
  end
end
