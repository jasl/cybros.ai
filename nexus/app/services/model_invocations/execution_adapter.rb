module ModelInvocations
  # Which HTTP adapter and transport are implemented by each execution host.
  # The host is part of the in-process start/send context; persisting the pair
  # on the Attempt merely duplicated this closed mapping.
  module ExecutionAdapter
    TRANSPORTS = {
      "model_runner" => "async_http",
      "solid_queue" => "httpx",
    }.freeze

    ADAPTERS = {
      "model_runner" => SimpleInference::HTTPAdapters::AsyncHTTP,
      "solid_queue" => SimpleInference::HTTPAdapters::HTTPX,
    }.freeze

    MUTEX = Mutex.new

    def self.transport_for(execution_host_kind) = TRANSPORTS[execution_host_kind]

    # One instance per host for the process: AsyncHTTP's client pool is
    # instance state, so a fresh adapter per send rebuilt TCP and TLS on every call.
    def self.for(execution_host_kind)
      adapter = ADAPTERS[execution_host_kind]
      raise ArgumentError, "no adapter for execution host #{execution_host_kind.inspect}" if adapter.nil?

      # The hash is created under the mutex too, or two threads orphan an
      # adapter with the pool it already built.
      instances = @instances
      return instances[execution_host_kind] if instances&.key?(execution_host_kind)

      MUTEX.synchronize do
        @instances ||= {}
        @instances[execution_host_kind] ||= adapter.new
      end
    end
  end
end
