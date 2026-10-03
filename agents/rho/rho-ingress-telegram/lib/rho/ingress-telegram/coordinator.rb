module Rho
  module IngressTelegram
    # The daemon outlives its member connection. Each connected Profile gets a
    # fresh worker and cache, and every retired worker finishes before its successor.
    class Coordinator
      Request = Data.define(:kind, :connection, :completed)

      def initialize(host:, settings:)
        @host, @settings = host, settings
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
          error = nil
          begin
            case request.kind
            when :connection
              replace(request.connection)
            when :close
              retire
              break
            else
              raise ArgumentError, "unknown Telegram coordinator request"
            end
          rescue StandardError => caught
            error = caught
          ensure
            request.completed.push(error)
          end
        end
      ensure
        retire
        @lock.synchronize do
          @running = false
          @closed = true
          @requests.close
          while (request = @requests.pop)
            request.completed.push(Rho::ConnectionError.new("Telegram worker stopped"))
          end
        end
      end

      def connection_changed(connection)
        completed = @lock.synchronize do
          return if @closed

          if @running
            enqueue(:connection, connection)
          else
            @connection = connection
            nil
          end
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
        @runtime ? @runtime.status : {
          "enabled" => true, "connection" => @closed ? "stopped" : "waiting_for_nexus",
        }
      end

      def binding(conversation_id)
        @runtime&.state&.binding(conversation_id)
      end

      private

        def enqueue(kind, connection)
          completed = Thread::Queue.new
          @requests.push(Request.new(kind: kind, connection: connection, completed: completed))
          completed
        end

        def wait(completed)
          error = completed&.pop
          raise error if error
        end

        def replace(connection)
          retire
          return unless connection

          migration = LegacyState.new(home: @host.home, user_public_id: connection.user_public_id)
          state = State.new(migration: migration, store: Rho::StoreDocument.new(namespace: "rho.telegram", key: "state",
            store: -> { connection.client.profile.store_entries },
            initial: migration.method(:call)))
          runtime = Runtime.new(settings: @settings, state: state, bridge: Bridge.new(host: @host),
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
