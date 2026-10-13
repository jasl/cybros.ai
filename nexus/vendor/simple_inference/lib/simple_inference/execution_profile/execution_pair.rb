module SimpleInference
  class ExecutionProfile
    # Where a request executes and over which HTTP transport — one of the
    # two closed pairs the platform implements.
    class ExecutionPair < Data.define(:execution_host_kind, :http_transport_kind)
      HOST_KINDS = %w[model_runner solid_queue].freeze
      TRANSPORT_KINDS = %w[async_http httpx].freeze
      CLOSED_PAIRS = [%w[model_runner async_http], %w[solid_queue httpx]].freeze

      def self.from_h(hash, field:) = Facts.ingest(self, hash, label: field, field: field)

      def initialize(execution_host_kind:, http_transport_kind:, field: "execution pair")
        host = Facts.member(execution_host_kind, HOST_KINDS, field: "execution_host_kind")
        transport = Facts.member(http_transport_kind, TRANSPORT_KINDS, field: "http_transport_kind")
        unless CLOSED_PAIRS.include?([host, transport])
          raise SimpleInference::ConfigurationError, "#{field} is not one of the closed execution pairs"
        end

        super(execution_host_kind: host, http_transport_kind: transport)
      end

      MODEL_RUNNER_ASYNC_HTTP = new(execution_host_kind: "model_runner", http_transport_kind: "async_http")
      SOLID_QUEUE_HTTPX = new(execution_host_kind: "solid_queue", http_transport_kind: "httpx")
      ALL = [MODEL_RUNNER_ASYNC_HTTP, SOLID_QUEUE_HTTPX].freeze
    end
  end
end
