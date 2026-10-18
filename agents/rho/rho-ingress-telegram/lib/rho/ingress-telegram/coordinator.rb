module Rho
  module IngressTelegram
    # Configuration and connection changes have one worker. Every physical
    # Connection polls once, while each Bot follows its original task receipts.
    class Coordinator
      Request = Data.define(:kind, :value, :completed)
      Binding = Struct.new(:settings, :state, :runtime, :worker, keyword_init: true)
      Transport = Struct.new(:settings, :state, :connection, :worker, :verified_bot, keyword_init: true)

      def initialize(host:, settings:, connections:)
        @host = host
        @bindings = settings.transform_values { |value| Binding.new(settings: value) }
        @transports = connections.transform_values { |value| Transport.new(settings: value) }
        @enabled = host.config.plugin_enabled?(NAME)
        @identities = {}
        @requests = Thread::Queue.new
        @lock = Mutex.new
        @running = @closed = false
      end

      def start
        connection = @lock.synchronize do
          return if @closed

          @running = true
          @member_connection
        end
        replace(connection)
        while (request = @requests.pop)
          error = result = nil
          begin
            case request.kind
            when :connection then replace(request.value)
            when :configuration then apply(**request.value)
            when :access
              values = request.value.dup
              result = access(values.delete(:agent_public_id)).change(**values)
            when :close
              retire_all
              break
            else raise ArgumentError, "unknown Telegram coordinator request"
            end
          rescue StandardError => caught
            error = caught
          ensure
            request.completed.push([error, result])
          end
        end
      ensure
        retire_all
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

          if @running
            enqueue(:connection, connection)
          else
            @member_connection = connection
            nil
          end
        end
        wait(completed)
      end

      def configure(config)
        document = config.plugin_configuration(NAME)
        values = { settings: Settings.bindings(document), connections: Settings.connections(document), enabled: config.plugin_enabled?(NAME) }
        completed = @lock.synchronize do
          raise Rho::ConnectionError, "Telegram worker stopped" if @closed

          if @running
            enqueue(:configuration, values)
          else
            @bindings = values.fetch(:settings).transform_values { |value| Binding.new(settings: value) }
            @transports = values.fetch(:connections).transform_values { |value| Transport.new(settings: value) }
            @enabled = values.fetch(:enabled)
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

      def admit_connection(connection_public_id:, token:, bot:)
        @lock.synchronize do
          duplicate = @transports.any? { |other, row| other != connection_public_id && !token.empty? && row.settings.token == token }
          owner = bot && @identities[bot.fetch("id").to_s]
          if duplicate || (owner && owner != connection_public_id)
            raise Rho::ConfigurationError, Locales::ENGLISH.fetch("identity_in_use")
          end
        end
      end

      def close
        completed = @lock.synchronize do
          return if @closed

          @closed = true
          enqueue(:close, nil) if @running
        end
        wait(completed)
      end

      def connections = @transports.keys.map { |id| connection_status(id) }

      def connection_status(public_id)
        row = @transports.fetch(public_id)
        state = row.state&.read.to_h
        row.settings.to_h.merge("public_id" => public_id, "token" => { "present" => row.settings.configured? },
          "bot" => row.connection&.bot || row.verified_bot, "connection" => transport_status(row),
          "offset" => state["offset"], "bot_count" => @bindings.count { |_id, binding| binding.settings.connection_public_id == public_id })
      end

      def status(agent_public_id:, audience: nil)
        row = @bindings[agent_public_id] || Binding.new(settings: Settings.new({}))
        transport = @transports[row.settings.connection_public_id]
        owner_only = audience ? audience == "owner" : !row.runtime&.external_bot?
        state_status(row).merge("enabled" => row.settings.enabled?, "plugin_enabled" => @enabled,
          "agent_public_id" => agent_public_id, "owner_only" => owner_only,
          "configuration" => row.settings.to_h, "connection_public_id" => row.settings.connection_public_id,
          "connection" => row.settings.enabled? ? transport ? transport_status(transport) : "configuration_error" : "disabled",
          "bot" => transport&.connection&.bot || transport&.verified_bot,
          "access" => (access_document(row) unless owner_only))
      end

      def remember_bot(token, bot, connection_public_id:)
        row = @transports[connection_public_id]
        row.verified_bot = bot if row && token == row.settings.token && bot
      end

      def bot_id(connection_public_id:) = @transports[connection_public_id]&.state&.read&.fetch("bot_id", nil)
      def connection_bot(public_id) = @transports[public_id]&.connection&.bot || @transports[public_id]&.verified_bot

      def transport(public_id)
        row = @transports[public_id]
        unless row&.connection && row.settings.enabled? && @enabled && !@closed
          raise Delivery::Unavailable, Locales::ENGLISH.fetch("destination_unavailable")
        end
        row.connection
      end

      def binding(conversation_id)
        return if @closed

        @bindings.each do |key, row|
          projection = row.state&.binding(conversation_id)
          return projection.merge("agent_public_id" => key) if projection
        end
        nil
      end

      def result_destination(agent_public_id:, owner_id:, source_route:, source_agent_public_id: nil)
        return if agent_public_id == source_agent_public_id

        row = @bindings[agent_public_id]
        return unless row&.settings&.configured?

        unless row.runtime && row.settings.enabled? && @enabled && !@closed
          raise Delivery::Unavailable, Locales::ENGLISH.fetch("destination_unavailable")
        end
        row.runtime.result_destination(owner_id: owner_id, source_route: source_route)
          .merge("destination_agent_public_id" => agent_public_id)
      end

      def delivery_sender(entry)
        row = @bindings[entry.fetch("destination_agent_public_id")]
        unless row&.runtime && row.settings.enabled? && @enabled && !@closed
          raise Delivery::Unavailable, Locales::ENGLISH.fetch("destination_unavailable")
        end
        row.runtime.delivery_sender(entry)
      end

      def delivered_copy?(agent_public_id, update)
        return false unless update.reply_id

        @bindings.each_value.any? do |row|
          row.state && row.state.read.fetch("deliveries").values.any? do |entry|
            entry["destination_agent_public_id"] == agent_public_id && entry["connection_public_id"] == update.connection_public_id &&
              entry["chat_id"] == update.chat_id && entry["topic_id"] == update.topic_id && entry.fetch("message_ids", []).include?(update.reply_id)
          end
        end
      end

      private

        def access(agent_public_id)
          row = @bindings.fetch(agent_public_id)
          raise Rho::ConnectionError, "Telegram access needs a connected Agent profile" unless row.state

          Access.new(settings: row.settings, state: row.state)
        end

        def access_document(row)
          row.state ? Access.new(settings: row.settings, state: row.state).document : nil
        rescue Rho::ConnectionError, CybrosAgent::TransportError, CybrosAgent::Api::Error
          nil
        end

        def state_status(row)
          row.state ? row.state.status : { "chats" => 0, "delivery_issues" => [] }
        rescue Rho::ConnectionError, CybrosAgent::TransportError, CybrosAgent::Api::Error
          { "chats" => 0, "delivery_issues" => [] }
        end

        def transport_status(row)
          return "stopped" if @closed
          return "disabled" unless @enabled && row.settings.enabled?
          return "configuration_error" unless row.settings.configured?

          row.connection&.status || (@member_connection ? "starting" : "waiting_for_nexus")
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
          retire_all
          # A queued reconnect cannot change the active state while the previous
          # connection is still retiring its followers and transport workers.
          @member_connection = connection
          @transports.each do |key, row|
            row.state = connection && ConnectionState.new(store: store_for("connection:#{key}", connection))
            row.verified_bot = nil
          end
          @bindings.each { |key, row| row.state = connection && State.new(store: store_for("bot:#{key}", connection)) }
          activate_all
        end

        def store_for(key, connection)
          Rho::StoreDocument.new(namespace: "rho.telegram", key: key, store: -> { connection.client.profile.store_entries })
        end

        def apply(settings:, connections:, enabled:)
          @bindings.each do |key, row|
            retire_bot(row) unless settings.key?(key) && enabled
          end
          @transports.each do |key, row|
            replacement = connections[key]
            retire_transport(key, row) if !replacement || replacement.token != row.settings.token || !enabled || !replacement.enabled? || row.connection&.status == "configuration_error"
          end
          @bindings.delete_if { |key, _row| !settings.key?(key) }
          @transports.delete_if { |key, _row| !connections.key?(key) }
          @enabled = enabled
          connections.each do |key, value|
            row = @transports[key] ||= Transport.new(settings: value,
              state: (@member_connection && ConnectionState.new(store: store_for("connection:#{key}", @member_connection))))
            row.verified_bot = nil if row.settings.token != value.token
            row.settings = value
          end
          settings.each do |key, value|
            row = @bindings[key] ||= Binding.new(settings: value,
              state: (@member_connection && State.new(store: store_for("bot:#{key}", @member_connection))))
            row.settings = value
            row.runtime&.configure(settings: value, default_model: nil)
          end
          activate_all
        end

        def activate_all
          return unless @enabled && @member_connection

          @bindings.each do |key, row|
            next if row.runtime || !row.settings.configured?

            row.runtime = Runtime.new(settings: row.settings, state: row.state,
              bridge: Bridge.new(host: @host, agent_public_id: key), client: nil, log: @host.log,
              agent_public_id: key, coordinator: self)
          end
          @transports.each do |key, row|
            next if row.connection || !row.settings.enabled? || !row.settings.configured?

            row.connection = Connection.new(public_id: key, state: row.state, client: Client.new(token: row.settings.token),
              bindings: -> { @bindings.filter_map { |id, binding| [id, binding.runtime] if binding.runtime }.to_h },
              log: @host.log, admit_identity: ->(bot) { claim_identity(key, bot) })
          end
          @transports.each_value { |row| row.worker ||= run_worker { row.connection.start } if row.connection }
          @bindings.each_value { |row| row.worker ||= run_worker { row.runtime.start } if row.runtime }
        end

        def run_worker
          Async::Task.current.async do
            yield
          rescue StandardError => error
            @host.log&.warn("telegram.worker_failed", reason: error.class.name)
          end
        end

        def claim_identity(key, bot)
          @lock.synchronize do
            identity = bot.fetch("id").to_s
            if @identities[identity] && @identities[identity] != key
              raise Rho::ConfigurationError, Locales::ENGLISH.fetch("identity_in_use")
            end
            @identities[identity] = key
          end
        end

        def retire_all
          @bindings.each_value { |row| retire_bot(row) }
          @transports.each { |key, row| retire_transport(key, row) }
        end

        def retire_bot(row)
          row.runtime&.close
          row.worker&.stop
          row.worker&.wait_all
          row.runtime = row.worker = nil
        end

        def retire_transport(key, row)
          row.connection&.close
          row.worker&.stop
          row.worker&.wait_all
          row.connection = row.worker = nil
          @lock.synchronize { @identities.delete_if { |_identity, owner| owner == key } }
        end
    end
  end
end
