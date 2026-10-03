module CybrosAgent
  module Api
    # What the authenticated clients share: one credential, one transport, and one status
    # ladder in which every HTTP class maps to exactly one typed error. The
    # planes differ only in which credential they carry and which resources
    # they expose, which is the whole point of the split.
    class BaseClient
      include Parsing

      DEFAULT_REQUEST_TIMEOUT = 30

      # A transport implements CybrosAgent::Response's contract (transport.rb).
      # A provider belongs to the caller's credential owner. Dispatch reads
      # it once per request; the SDK neither refreshes nor replaces it.
      def initialize(base_url:, credential: nil, credential_provider: nil, transport: nil,
                     request_timeout: DEFAULT_REQUEST_TIMEOUT)
        if credential.nil? == credential_provider.nil?
          raise ArgumentError, "provide exactly one of credential or credential_provider"
        end
        if credential_provider.nil?
          raise ArgumentError, "credential must be a nonempty String" unless credential.is_a?(String) && !credential.empty?

          credential_provider = -> { credential }
        end
        initialize_dispatch(base_url:, credential_provider:, transport:, request_timeout:)
      end

      include Redacted

      def inspect = redacted(hidden: %i[credential])

      private

        attr_reader :dispatch

        # Session creation has no bearer yet. It uses this same transport and
        # status ladder, with its own explicitly unauthenticated constructor.
        def initialize_dispatch(base_url:, credential_provider:, transport:, request_timeout:)
          unless request_timeout.is_a?(Numeric) && request_timeout.finite? && request_timeout.positive?
            raise ArgumentError, "request_timeout must be finite and positive"
          end

          @dispatch = Dispatch.new(
            credential_provider: credential_provider,
            transport: transport || HttpTransport.new(base_url: base_url),
            request_timeout: request_timeout
          )
        end
    end
  end
end
