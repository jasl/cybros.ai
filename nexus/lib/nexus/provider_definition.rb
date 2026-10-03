module Nexus
  # The closed provider declaration shared by file compilation and account settings.
  module ProviderDefinition
    class Invalid < ArgumentError; end

    KEYS = %w[base_url api_format credentials display_name concurrency_limit
      workload_concurrency_limits native_cost_contract wire_options service_tiers].freeze
    REQUIRED_KEYS = %w[base_url api_format].freeze
    CREDENTIALS = { "api_key" => "api_key", "none" => "none", "codex" => "oauth_tokens" }.freeze
    DEFAULT_CREDENTIALS = "api_key".freeze
    DEFAULT_CONCURRENCY_LIMIT = 2
    MAX_BYTES = 64 * 1024
    ID_PATTERN = /\A[a-zA-Z0-9][a-zA-Z0-9_.-]*\z/
    MAX_ID_LENGTH = 64
    MAX_DISPLAY_NAME_LENGTH = 256

    class << self
      def normalize(value, provider_id:)
        unless provider_id.length <= MAX_ID_LENGTH && provider_id.match?(ID_PATTERN)
          raise Invalid, "provider ID must start with a letter or digit and contain only letters, digits, dots, underscores or hyphens"
        end
        declaration = Hash.try_convert(value)
        raise Invalid, "provider #{provider_id.inspect} must be a mapping" if declaration.nil?

        declaration = CanonicalJson.normalize(declaration)
        unknown = declaration.keys - KEYS
        raise Invalid, "provider #{provider_id.inspect} declares unknown facts: #{unknown.sort.join(", ")}" if unknown.any?
        missing = REQUIRED_KEYS - declaration.keys
        raise Invalid, "provider #{provider_id.inspect} is missing required facts: #{missing.sort.join(", ")}" if missing.any?
        raise Invalid, "provider definition is too large" if CanonicalJson.bytesize(declaration) > MAX_BYTES
        unless SimpleInference::ApiFormat.known?(declaration.fetch("api_format"))
          raise Invalid, "provider #{provider_id.inspect} names unknown api_format #{declaration.fetch("api_format").inspect}"
        end
        unless CREDENTIALS.key?(declaration.fetch("credentials", DEFAULT_CREDENTIALS))
          raise Invalid, "provider #{provider_id.inspect} credentials must be one of #{CREDENTIALS.keys.join(", ")}"
        end

        if declaration.key?("display_name")
          name = String.try_convert(declaration.fetch("display_name"))
          unless name && name.length <= MAX_DISPLAY_NAME_LENGTH
            raise Invalid, "provider display_name must be a string of at most #{MAX_DISPLAY_NAME_LENGTH} characters"
          end
          declaration["display_name"] = name.strip
        end
        declaration = declaration.reverse_merge("concurrency_limit" => DEFAULT_CONCURRENCY_LIMIT)
        validate_base_url(provider_id, declaration.fetch("base_url"))
        validate_concurrency(provider_id, declaration)
        declaration
      end

      private

        def validate_base_url(provider_id, value)
          uri = URI.parse(value.to_s)
          valid = %w[http https].include?(uri.scheme) && uri.host.present? && uri.userinfo.nil? &&
            uri.query.nil? && uri.fragment.nil? && !uri.path.end_with?("/")
          return if valid

          raise Invalid, "provider #{provider_id.inspect} base_url must be an absolute http(s) origin with no " \
            "userinfo, query, fragment, or trailing slash"
        rescue URI::InvalidURIError
          raise Invalid, "provider #{provider_id.inspect} base_url is not a URI"
        end

        def validate_concurrency(provider_id, declaration)
          ceiling = positive_integer(declaration.fetch("concurrency_limit"))
          raise Invalid, "provider #{provider_id.inspect} concurrency_limit must be a positive integer" if ceiling.nil?

          limits = Hash.try_convert(declaration.fetch("workload_concurrency_limits", {}))
          raise Invalid, "provider #{provider_id.inspect} workload_concurrency_limits must be a mapping" if limits.nil?
          limits.each do |workload, value|
            unless SimpleInference::ExecutionProfile::WORKLOADS.include?(workload)
              raise Invalid, "provider #{provider_id.inspect} declares a limit for unknown workload #{workload.inspect}"
            end
            limit = positive_integer(value)
            next if limit && limit <= ceiling

            raise Invalid, "provider #{provider_id.inspect} workload_concurrency_limits[#{workload.inspect}] " \
              "must be a positive integer at or under concurrency_limit #{ceiling}"
          end
        end

        def positive_integer(value)
          integer = Integer(value, exception: false)
          integer if !integer.nil? && value.eql?(integer) && integer.positive?
        end
    end
  end
end
