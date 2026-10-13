require "async/semaphore"

module Rho
  module IngressTelegram
    # The Connection serializes physical updates; Bot runtimes retain their own
    # semantic receipts until the shared offset has acknowledged that update.
    class Connection
      attr_reader :client, :state

      def initialize(public_id:, client:, state:, bindings:, log:, clock: -> { Time.now.to_f }, admit_identity: nil)
        @client, @state, @bindings, @log = client, state, bindings, log
        @public_id, @clock = public_id, clock
        @admit_identity = admit_identity
        @limits = RateLimit.new(clock: clock)
        @sending = Async::Semaphore.new(1)
        @closed = false
        @status = "starting"
      end

      def bot = @bot&.slice("id", "username")
      def status = @status

      def identify(bot)
        @state.bind(bot.fetch("id")) { @admit_identity&.call(bot) }
        @bot = bot
      end

      def start
        safely("identify") { identify(@client.call("getMe")) } until @bot || @closed
        return if @closed

        @status = "running"
        safely("commands") { @client.call("setMyCommands", { commands: Commands::MENU }) }
        safely("poll") { poll } until @closed
      ensure
        @client.close
      end

      def close
        @closed = true
        @status = "stopped"
        @client.close
      end

      def poll
        acknowledge
        if (pending = @state.read["pending_update"])
          consume(pending.fetch("update"))
          return
        end
        options = { timeout: 30, limit: 50, allowed_updates: %w[message callback_query stopped_message_generation] }
        options[:offset] = @state.read["offset"] if @state.read["offset"]
        @client.call("getUpdates", options, poll: true).each { |update| consume(update) }
        @status = "running" unless @closed
      end

      def consume(raw)
        held = @state.read
        return if held["offset"] && raw.fetch("update_id") < held.fetch("offset")

        update = Update.new(raw)
        selected = @bindings.call.find do |_id, runtime|
          runtime.settings.connection_public_id == @public_id && runtime.settings.enabled? && update.supported? && runtime.settings.matches?(update)
        end
        pending = @state.stage(update: raw, agent_public_id: selected&.first)
        id = pending["agent_public_id"]
        if id
          runtime = @bindings.call[id]
          raise Rho::ConnectionError, "Telegram's pending update needs its original Bot binding" unless runtime

          runtime.consume(pending.fetch("update"), connection_public_id: @public_id, bot: @bot)
        end
        @state.consumed(pending.fetch("update").fetch("update_id"))
        acknowledge
      end

      def ready?(entry, progress: false)
        @state.read.fetch("retry_at", 0) <= @clock.call &&
          @limits.ready?(chat_id: entry.fetch("chat_id"), group: entry.fetch("group"), progress: progress)
      end

      def with_send(entry, progress: false)
        @sending.acquire do
          next unless ready?(entry, progress: progress)

          result = yield(@client)
          @limits.sent(chat_id: entry.fetch("chat_id"), group: entry.fetch("group"), progress: progress) if result
          result
        end
      end

      def throttle(seconds)
        @limits.retry_after(seconds)
        @state.change { |document| document["retry_at"] = [document.fetch("retry_at", 0), @clock.call + seconds].max }
      end

      private

        def acknowledge
          offset = @state.read["offset"]
          @bindings.call.each_value { |runtime| runtime.acknowledge(offset, connection_public_id: @public_id) } if offset
        end

        def safely(operation)
          yield
        rescue Rho::ConfigurationError
          @status = "configuration_error"
          raise
        rescue Client::Refused => error
          throttle(error.retry_after) if error.retry_after
          @status = error.code == 401 ? "unauthorized" : "retrying"
          @log&.warn("telegram.refused", operation: operation, code: error.code)
          sleep(error.retry_after || (error.code == 401 ? 30 : 5))
        rescue CybrosAgent::Api::RateLimited => error
          @log&.warn("telegram.nexus_throttled", operation: operation, retry_after: error.retry_after)
          sleep(error.retry_after || 5)
        rescue Rho::Core::Refused => error
          @log&.warn("telegram.core_refused", operation: operation, code: error.code, status: error.status)
          @status = "retrying"
          sleep 5
        rescue Client::Unavailable, Rho::Error, CybrosAgent::TransportError, CybrosAgent::Api::Error => error
          @log&.warn("telegram.unavailable", operation: operation, reason: error.class.name)
          @status = "retrying"
          sleep 5
        end
    end
  end
end
