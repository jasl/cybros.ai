require "i18n"
require "json"
require "socket"
require "timeout"
require_relative "../deployment"

module Nexus
  module Deployment
    class Client
      REQUEST_BYTES = 16 * 1024
      RESPONSE_BYTES = 128 * 1024
      LOG_BYTES = 64 * 1024
      LOCAL_TIMEOUT = 5
      CHECK_TIMEOUT = 120
      ERROR_STATUSES = {
        invalid_request: 400, not_found: 404, idempotency_conflict: 409,
        upgrade_in_progress: 409, recovery_required: 409, candidate_changed: 409, preflight_failed: 409,
        release_unavailable: 503, updater_unavailable: 503,
      }.freeze

      class InvalidResponse < StandardError; end

      def initialize(socket_path: ENV["NEXUS_DEPLOYMENT_SOCKET"], timeout: nil)
        @socket_path = socket_path.to_s
        @timeout = timeout
      end

      def status
        if @socket_path.empty?
          Response.new(status: 200, data: State.new(supported: false, sources: [], installed: nil,
            candidate: nil, preflight: nil, active_operation: nil, last_operation: nil), error: nil)
        else
          request(:status)
        end
      end

      def check(tag: "latest", backup: true)
        request(:check, tag: tag, backup: backup)
      end

      def upgrade(idempotency_key:, actor_public_id:, candidate:, backup: true)
        unless candidate.images.map(&:name) == ["nexus"]
          return invalid_request(message: I18n.t("deployment.errors.select_checked_image", brand: I18n.t("brand.name")))
        end

        request(:upgrade, idempotency_key: idempotency_key, actor_public_id: actor_public_id,
          candidate: candidate.to_h, backup: backup)
      end

      def receipt(operation_id:)
        request(:receipt, operation_id: operation_id)
      end

      def log(operation_id:, cursor: nil)
        request(:log, operation_id: operation_id, cursor: cursor, limit: LOG_BYTES)
      end

      private

        def request(operation, **fields)
          return unavailable unless @socket_path.start_with?("/")

          # Nexus administers only its own deployment. The installation owner
          # keeps combined application upgrades on its separate operator path.
          wire = JSON.generate(operation: operation, scope: "nexus", **fields) + "\n"
          return invalid_request if wire.bytesize > REQUEST_BYTES

          # Each command has one bounded connection. A lost response never
          # retries a potentially accepted upgrade; its receipt owns recovery.
          payload = Timeout.timeout(@timeout || (operation == :check ? CHECK_TIMEOUT : LOCAL_TIMEOUT)) do
            UNIXSocket.open(@socket_path) do |socket|
              socket.write(wire)
              socket.gets(RESPONSE_BYTES + 1)
            end
          end
          unless payload && payload.bytesize <= RESPONSE_BYTES && payload.end_with?("\n")
            raise InvalidResponse
          end

          decode(operation, JSON.parse(payload))
        rescue SystemCallError, IOError, Timeout::Error, JSON::ParserError, KeyError, ArgumentError, InvalidResponse
          unavailable
        end

        def decode(operation, envelope)
          status = envelope.fetch("status")
          if (error = envelope["error"])
            error = Error.from_h(error)
            raise InvalidResponse unless ERROR_STATUSES[error.code] == status

            Response.new(status: status, data: nil, error: error)
          else
            raise InvalidResponse unless [200, 202].include?(status)

            data = envelope.fetch("data")
            decoded = case operation
            when :status, :check then State.from_h(data)
            when :upgrade, :receipt then Receipt.from_h(data)
            when :log then Log.from_h(data)
            else raise ArgumentError, "Unknown deployment operation"
            end
            Response.new(status: status, data: decoded, error: nil)
          end
        end

        def invalid_request(message: I18n.t("deployment.errors.request_too_large"))
          Response.new(status: 400, data: nil,
            error: Error.new(code: :invalid_request, message: message, operation_id: nil))
        end

        def unavailable
          Response.new(status: 503, data: nil, error: Error.new(code: :updater_unavailable,
            message: I18n.t("deployment.errors.updater_unavailable"),
            operation_id: nil))
        end
    end
  end
end
