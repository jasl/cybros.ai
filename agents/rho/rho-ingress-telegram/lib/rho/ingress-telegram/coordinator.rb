module Rho
  module IngressTelegram
    # The daemon outlives its member connection. Profile changes replace the
    # cache; channel settings keep it and serialize through the same worker.
    class Coordinator
      Request = Data.define(:kind, :value, :completed)

      def initialize(host:, settings:)
        @host, @settings = host, settings
        @enabled = host.config.extensions.include?(Configuration::EXTENSION)
        @requests = Thread::Queue.new
        @lock = Mutex.new
        @running = @closed = false
      end

      def start
        connection = @lock.synchronize do
          return if @closed

          @running = true
          @connection
        end
        replace(connection)
        while (request = @requests.pop)
          error = result = nil
          begin
            case request.kind
            when :connection then replace(request.value)
            when :configuration then apply(**request.value)
            when :access then result = access.change(**request.value)
            when :close
              retire
              break
            else
              raise ArgumentError, "unknown Telegram coordinator request"
            end
          rescue StandardError => caught
            error = caught
          ensure
            request.completed.push([error, result])
          end
        end
      ensure
        retire
        @lock.synchronize do
          @running = false
          @closed = true
          @requests.close
          while (request = @requests.pop)
            request.completed.push([Rho::ConnectionError.new("Telegram worker stopped"), nil])
          end
        end
      end

      def connection_changed(connection)
        completed = @lock.synchronize do
          return if @closed

          @connection = connection
          enqueue(:connection, connection) if @running
        end
        wait(completed)
      end

      def configure(config)
        settings = Settings.new(config.telegram, home: @host.home)
        values = { settings: settings, enabled: config.extensions.include?(Configuration::EXTENSION),
          default_model: config.default_model }
        completed = @lock.synchronize do
          raise Rho::ConnectionError, "Telegram worker stopped" if @closed

          if @running
            enqueue(:configuration, values)
          else
            @settings, @enabled = settings, values.fetch(:enabled)
            nil
          end
        end
        wait(completed)
      end

      def change_access(**values)
        completed = @lock.synchronize do
          raise Rho::ConnectionError, "Telegram worker is not running" unless @running && !@closed

          enqueue(:access, values)
        end
        wait(completed)
      end

      # Shutdown may originate on the daemon's caller thread. Client cancellation
      # and task retirement still run on the worker's own reactor.
      def close
        completed = @lock.synchronize do
          return if @closed

          @closed = true
          enqueue(:close, nil) if @running
        end
        wait(completed)
      end

      def status
        projection = @runtime ? @runtime.status : state_status.merge("connection" => connection_status)
        projection.merge("enabled" => @enabled, "configuration" => @settings.to_h,
          "token" => { "present" => @settings.enabled?, "source" => @settings.token_source },
          "bot" => @runtime&.bot || @verified_bot, "access" => access_document)
      end

      def remember_bot(token, bot)
        @verified_bot = bot if token == @settings.token && bot
      end

      def bot_id = @state&.read&.fetch("bot_id", nil)

      def binding(conversation_id)
        @state&.binding(conversation_id) unless @closed
      end

      private

        def access
          raise Rho::ConnectionError, "Telegram access needs a connected Agent profile" unless @state

          Access.new(settings: @settings, state: @state)
        end

        def access_document
          @state ? access.document : nil
        rescue Rho::ConnectionError, CybrosAgent::TransportError, CybrosAgent::Api::Error
          nil
        end

        def state_status
          @state ? @state.status : {}
        rescue Rho::ConnectionError, CybrosAgent::TransportError, CybrosAgent::Api::Error
          {}
        end

        def connection_status
          return "stopped" if @closed
          return "disabled" unless @enabled
          return "configuration_error" unless @settings.enabled?

          @connection ? "starting" : "waiting_for_nexus"
        end

        def enqueue(kind, value)
          completed = Thread::Queue.new
          @requests.push(Request.new(kind: kind, value: value, completed: completed))
          completed
        end

        def wait(completed)
          return unless completed

          error, result = completed.pop
          raise error if error

          result
        end

        def replace(connection)
          retire
          @state = nil
          @verified_bot = nil
          return unless connection

          migration = LegacyState.new(home: @host.home, user_public_id: connection.user_public_id)
          @state = State.new(migration: migration, store: Rho::StoreDocument.new(namespace: "rho.telegram", key: "state",
            store: -> { connection.client.profile.store_entries }, initial: migration.method(:call).to_proc))
          activate
        end

        def apply(settings:, enabled:, default_model:)
          changed_token = settings.token != @settings.token
          retire if changed_token || !enabled
          @verified_bot = nil if changed_token
          @settings, @enabled = settings, enabled
          if @runtime
            @runtime.configure(settings: settings, default_model: default_model)
          else
            activate
          end
        end

        def activate
          return unless @state && @enabled && @settings.enabled?

          runtime = Runtime.new(settings: @settings, state: @state, bridge: Bridge.new(host: @host),
            client: Client.new(token: @settings.token), log: @host.log, default_model: @host.config.default_model)
          @runtime = runtime
          @worker = Async::Task.current.async do
            runtime.start
          rescue StandardError => error
            @host.log&.warn("extension_task_failed", extension: NAME, detail: "background:#{NAME}",
              error_class: error.class.name)
          end
        end

        def retire
          runtime, worker = @runtime, @worker
          @runtime = @worker = nil
          begin
            runtime&.close
          ensure
            worker&.stop
            worker&.wait_all
          end
        end
    end
  end
end
