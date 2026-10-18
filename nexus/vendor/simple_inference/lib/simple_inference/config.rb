require_relative "internal/keys"
require_relative "http_adapter"

module SimpleInference
  # The ONE parsed, validated form of the gem's connection settings. Built
  # exactly once per Client (protocols receive it by reference via `config:`);
  # standalone protocol construction builds its own from the same keywords.
  #
  # Fully explicit: no ENV fallbacks, no default endpoint — the caller states
  # where to connect (base_url is required) and with what. A keyword Ruby
  # does not know raises ArgumentError, so a typo'd option never no-ops.
  class Config
    SENSITIVE_HEADER_NAMES = %w[
      authorization
      proxy-authorization
      x-api-key
      x-goog-api-key
      api-key
      cookie
      set-cookie
    ].freeze

    attr_reader :base_url,
                :api_key,
                :api_prefix,
                :timeout,
                :open_timeout,
                :read_timeout,
                :adapter,
                :raise_on_error

    def initialize(base_url:, api_key: nil, api_prefix: "/v1", base_url_included_api_prefix: nil,
                   timeout: nil, open_timeout: nil, read_timeout: nil, adapter: nil,
                   raise_on_error: true, headers: {})
      original_base_url = normalize_base_url(base_url)
      @api_key = api_key.to_s.then { |key| key.empty? ? nil : key }
      @api_prefix = normalize_api_prefix(api_prefix)

      # Avoid the common "/v1/v1" footgun when callers include "/v1" in base_url
      # and also use the default api_prefix of "/v1".
      @base_url_included_api_prefix =
        if base_url_included_api_prefix.nil?
          base_url_ends_with_api_prefix?(original_base_url, @api_prefix)
        else
          !!base_url_included_api_prefix
        end
      @base_url = strip_api_prefix_from_base_url(original_base_url, @api_prefix)

      @timeout = to_float_or_nil(timeout, field_name: "timeout")
      @open_timeout = to_float_or_nil(open_timeout, field_name: "open_timeout")
      @read_timeout = to_float_or_nil(read_timeout, field_name: "read_timeout")

      @adapter = validate_adapter(adapter || HTTPAdapters::Default.new)
      @raise_on_error = !!raise_on_error
      @default_headers = build_default_headers(headers)
    end

    def headers
      @default_headers.dup
    end

    def base_url_included_api_prefix?
      @base_url_included_api_prefix
    end

    # The api_key (and the Authorization header derived from it) must never
    # leak through inspect/logging/error interpolation. Wire code reads the
    # real values via #headers; humans get a redacted view.
    def inspect
      redacted_headers = @default_headers.to_h do |name, value|
        [name, SENSITIVE_HEADER_NAMES.include?(name.downcase) ? "[REDACTED]" : value]
      end

      "#<#{self.class.name} base_url=#{@base_url.inspect} " \
        "api_key=#{@api_key ? "[REDACTED]" : "nil"} " \
        "api_prefix=#{@api_prefix.inspect} headers=#{redacted_headers.inspect}>"
    end
    alias to_s inspect

    private

    def normalize_base_url(value)
      url = value.to_s.strip
      raise SimpleInference::ConfigurationError, "base_url is required" if url.empty?

      url.chomp("/")
    end

    def normalize_api_prefix(value)
      prefix = value.to_s.strip
      return "" if prefix.empty?

      # Ensure it starts with / and does not end with /
      prefix = "/#{prefix}" unless prefix.start_with?("/")
      prefix.chomp("/")
    end

    def strip_api_prefix_from_base_url(base_url, api_prefix)
      return base_url if api_prefix.empty?
      return base_url unless base_url.end_with?(api_prefix)

      base_url[0...-api_prefix.length].chomp("/")
    end

    def base_url_ends_with_api_prefix?(base_url, api_prefix)
      return false if api_prefix.empty?

      base_url.end_with?(api_prefix)
    end

    def to_float_or_nil(value, field_name:)
      return nil if value.nil? || value == ""

      number =
        begin
          Float(value)
        rescue ArgumentError, TypeError
          raise SimpleInference::ConfigurationError, "#{field_name} must be a number"
        end

      unless number.finite? && number.positive?
        raise SimpleInference::ConfigurationError,
              "#{field_name} must be a positive finite number (got #{value.inspect})"
      end

      number
    end

    # The adapter is the gem's plugin seam: a caller-supplied object is
    # checked against the contract once, here.
    def validate_adapter(adapter)
      return adapter if adapter.is_a?(HTTPAdapter)

      raise SimpleInference::ConfigurationError,
            "adapter must be an instance of SimpleInference::HTTPAdapter (got #{adapter.class})"
    end

    # `headers:` is caller input at the gem's door: a Hash, checked once.
    def build_default_headers(extra_headers)
      unless extra_headers.is_a?(Hash)
        raise SimpleInference::ConfigurationError, "headers must be a Hash"
      end

      headers = { "Accept" => "application/json" }
      headers["Authorization"] = "Bearer #{@api_key}" if @api_key

      headers.merge(Internal::Keys.shallow_stringify(extra_headers))
    end
  end
end
