require "json"

module CybrosAgent
  module Platform
    DeploymentImage = Data.define(:name, :reference)
    DeploymentRelease = Data.define(:release, :images)
    DeploymentCandidate = Data.define(:release, :images, :checked_at, :source_revision, :source_url)
    DeploymentCheck = Data.define(:name, :status, :message, :next_step, :available_bytes, :required_bytes)
    DeploymentPreflight = Data.define(:checked_at, :ready, :backup, :checks)
    DeploymentBackup = Data.define(:created_at, :size_bytes, :available)
    DeploymentError = Data.define(:code, :message, :operation_id)
    DeploymentUpgrade = Data.define(:id, :idempotency_key, :actor_public_id, :target, :previous,
      :phase, :status, :accepted_at, :updated_at, :completed_at, :error, :recovery, :log_cursor, :backup, :database_backup)
    DeploymentState = Data.define(:supported, :sources, :installed, :candidate, :preflight, :active_operation, :last_operation)
    DeploymentLogEntry = Data.define(:cursor, :text)
    DeploymentLog = Data.define(:entries, :next_cursor, :operation)
    DeploymentEvent = Data.define(:event, :id, :log, :error, :data)
    DeploymentAccepted = Data.define(:upgrade, :status, :location)

    module DeploymentProjections
      include Api::WorkspaceProjections
      include Api::Fields

      SHAPES = {
        DeploymentImage => { name: :string, reference: :string },
        DeploymentRelease => { release: :string, images: [:shapes, DeploymentImage] },
        DeploymentCandidate => { release: :string, images: [:shapes, DeploymentImage], checked_at: :string,
          source_revision: :nullable_string, source_url: :nullable_string },
        DeploymentCheck => { name: :string, status: :string, message: :nullable_string, next_step: :nullable_string,
          available_bytes: :optional_integer, required_bytes: :optional_integer },
        DeploymentPreflight => { checked_at: :string, ready: :boolean, backup: :boolean, checks: [:shapes, DeploymentCheck] },
        DeploymentBackup => { created_at: :string, size_bytes: :integer, available: :boolean },
        DeploymentError => { code: :string, message: :string, operation_id: :optional_string },
        DeploymentUpgrade => { id: :string, idempotency_key: :string, actor_public_id: :nullable_string,
          target: [:shape, DeploymentRelease], previous: [:optional_shape, DeploymentRelease], phase: :string,
          status: :string, accepted_at: :string, updated_at: :string, completed_at: :nullable_string,
          error: [:optional_shape, DeploymentError], recovery: :nullable_string, log_cursor: :nullable_string,
          backup: :boolean, database_backup: [:optional_shape, DeploymentBackup] },
        DeploymentState => { supported: :boolean, sources: [:shapes, DeploymentImage], installed: [:optional_shape, DeploymentRelease],
          candidate: [:optional_shape, DeploymentCandidate], preflight: [:optional_shape, DeploymentPreflight],
          active_operation: [:optional_shape, DeploymentUpgrade], last_operation: [:optional_shape, DeploymentUpgrade] },
        DeploymentLogEntry => { cursor: :string, text: :optional_string },
        DeploymentLog => { entries: [:shapes, DeploymentLogEntry], next_cursor: :nullable_string, operation: [:shape, DeploymentUpgrade] },
      }.freeze
    end

    class Deployment
      include DeploymentProjections

      PATH = "/api/v1/admin/deployment".freeze

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def fetch
        shape(DeploymentState, @dispatch.call(PATH), "deployment")
      end

      def check_release(tag: omitted_field, backup: omitted_field, timeout: 130)
        timeout = Float(timeout)
        raise ArgumentError, "timeout must be finite and positive" unless timeout.finite? && timeout.positive?

        shape(DeploymentState, @dispatch.call("#{PATH}/release_check", method: :post,
          body: { "release_check" => fields(tag:, backup:) }, timeout:), "deployment")
      end

      def upgrade(candidate:, idempotency_key:, backup: omitted_field)
        answer = @dispatch.call_accepting("#{PATH}/upgrades", method: :post, success: 202,
          body: fields(candidate:, backup:), headers: { "Idempotency-Key" => required_string(idempotency_key, "idempotency_key") })
        location = answer.headers.find { |name, _value| name.casecmp?("Location") }&.last
        DeploymentAccepted.new(upgrade: shape(DeploymentUpgrade, answer.body, "upgrade"), status: answer.status, location:)
      end

      def operation(public_id)
        DeploymentOperation.new(dispatch: @dispatch, path: "#{PATH}/upgrades/#{path_segment(public_id, "public_id")}")
      end
    end

    class DeploymentOperation
      include DeploymentProjections

      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = path.freeze
      end

      def fetch
        shape(DeploymentUpgrade, @dispatch.call(@path), "upgrade")
      end

      def log(cursor: nil)
        shape(DeploymentLog, @dispatch.call("#{@path}/log", params: query(cursor:)), "log")
      end

      # One bounded SSE observation. Reconnection is an explicit new call with
      # the cursor the application successfully consumed; it never starts work.
      def stream(cursor: nil, last_event_id: nil, &consumer)
        raise ArgumentError, "a deployment event consumer is required" unless consumer

        sink = DeploymentEventStream.new do |event, id, data|
          log = shape(DeploymentLog, data) if event == "deployment.progress.v1"
          error = shape(DeploymentError, data) if event == "deployment.error.v1"
          consumer.call(DeploymentEvent.new(event:, id:, log:, error:, data: json_snapshot(data)))
        end
        @dispatch.download("#{@path}/stream", params: query(cursor:), accept: "text/event-stream", sink:,
          headers: last_event_id.nil? ? {} : { "Last-Event-ID" => last_event_id })
        sink.finish
        nil
      end
    end

    # The transport writes arbitrary byte chunks; SSE framing is independent of
    # those boundaries and callbacks see only complete, JSON-decoded events.
    class DeploymentEventStream
      def initialize(&consumer)
        @consumer = consumer
        @buffer = +"".b
        @event = nil
        @id = nil
        @data = []
      end

      def write(bytes)
        @buffer << bytes.b
        while (line_end = @buffer.index(/[\r\n]/))
          break if @buffer.getbyte(line_end) == 13 && line_end == @buffer.bytesize - 1

          line = @buffer.slice!(0, line_end)
          separator = @buffer.slice!(0)
          @buffer.slice!(0) if separator == "\r" && @buffer.start_with?("\n")
          consume_line(line.force_encoding(Encoding::UTF_8))
        end
        bytes.bytesize
      end

      def finish
        # A final CR is a complete line ending once no following LF can
        # arrive. An event without its empty separator remains incomplete.
        write("\n") if @buffer.end_with?("\r")
      end

      private

        def consume_line(line)
          if line.empty?
            unless @data.empty?
              @consumer.call(@event || "message", @id, JSON.parse(@data.join("\n")))
            end
            @event = nil
            @data = []
          elsif !line.start_with?(":")
            field, value = line.split(":", 2)
            value = value.to_s.delete_prefix(" ")
            case field
            when "event" then @event = value
            when "id" then @id = value unless value.include?("\0")
            when "data" then @data << value
            else nil
            end
          end
        rescue JSON::ParserError
          raise Api::MalformedResponse, "invalid deployment event JSON", cause: nil
        end
    end
    private_constant :DeploymentEventStream
  end
end
