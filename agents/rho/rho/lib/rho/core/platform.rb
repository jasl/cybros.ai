module Rho
  class Core
    module Platform
      # A running daemon is the only refresh owner for its home. With no
      # daemon, the terminal owns the same lifetime lock for the whole setup.
      def with_platform_client
        daemon = running_daemon
        if daemon
          client = CybrosAgent::PlatformClient.new(base_url: @home.base_url, credential: "local-operator",
            transport: PlatformTransport.new(core: self, daemon: daemon))
          yield client
        else
          lock = Lock.acquire(@home.boot_lock_path)
          owner = ApplicationConnection.new(home: @home)
          client = CybrosAgent::PlatformClient.new(base_url: @home.base_url,
            credential_provider: owner.method(:human_credential).to_proc)
          yield client
        end
      ensure
        lock&.release
      end
    end

    class PlatformTransport
      def initialize(core:, daemon:)
        @core, @daemon = core, daemon
      end

      def call(path, method: :get, credential: nil, body: nil, params: nil, headers: {}, timeout:,
        accept: CybrosAgent::JSON_MEDIA)
        raise ArgumentError, "The Human Platform proxy accepts JSON responses" unless accept == CybrosAgent::JSON_MEDIA

        query = URI.encode_www_form(params || {})
        target = query.empty? ? path : "#{path}?#{query}"
        response = @core.post(@daemon, "/nexus/request", { "path" => target, "method" => method.to_s.upcase,
          "body" => body, "headers" => headers, "timeout" => timeout },
          budget: Budget::KERNEL_ROUND_TRIP)
        document = @core.parse(response)
        if response.code.to_i == 200
          CybrosAgent::Response.new(status: document.fetch("status"), headers: document.fetch("headers"), body: document["body"])
        else
          CybrosAgent::Response.new(status: response.code.to_i, headers: {}, body: document)
        end
      end
    end
  end
end
