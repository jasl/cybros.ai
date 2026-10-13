require "json"
require "puma"
require "puma/server"
require "puma/log_writer"
require "rack"

module E2E
  # A loopback Bot API endpoint. The product Client, polling lifecycle, ingress
  # admission and delivery stay real; only Telegram's HTTP service is replaced.
  class TelegramHttpServer
    TOKEN = "42:synthetic-settings-token".freeze
    BOT = { "id" => 42, "username" => "settings_test_bot", "is_bot" => true }.freeze

    attr_reader :url

    def initialize(bots: { TOKEN => BOT })
      @lock = Mutex.new
      @bots = bots
      @updates = bots.to_h { |token, _bot| [token, []] }
      @calls = bots.to_h { |token, _bot| [token, []] }
      @next_message = 0
    end

    def start
      @server = Puma::Server.new(method(:call), nil, min_threads: 0, max_threads: 8, log_writer: Puma::LogWriter.null)
      @server.add_tcp_listener("127.0.0.1", 0)
      @server.run
      @url = "http://127.0.0.1:#{@server.connected_ports.fetch(0)}"
      self
    end

    def stop = @server&.halt(true)
    def calls(token: TOKEN) = @lock.synchronize { @calls.fetch(token).dup }
    def messages(token: TOKEN) = calls(token: token).select { |method, _params| method == "sendMessage" }.map(&:last)

    def message(id:, user:, text:, token: TOKEN, chat: user, photo: nil, entities: nil, topic: nil)
      @lock.synchronize do
        message = { "message_id" => id, "date" => Time.now.to_i,
          "chat" => { "id" => chat, "type" => chat.positive? ? "private" : "supergroup" },
          "from" => { "id" => user, "first_name" => "Settings tester", "is_bot" => false }, "text" => text }
        message["photo"] = photo if photo
        message["entities"] = entities if entities
        if topic
          message["message_thread_id"] = topic
          message["is_topic_message"] = true
        end
        @updates.fetch(token) << { "update_id" => id, "message" => message }
      end
    end

    def call(env)
      path = env.fetch("PATH_INFO")
      token = path.split("/")[1].to_s.delete_prefix("bot")
      return response(401, "ok" => false, "error_code" => 401, "description" => "Unauthorized") unless @bots.key?(token)

      method = path.split("/").last
      params = Rack::Request.new(env).params
      @lock.synchronize { @calls.fetch(token) << [method, params] }
      result = case method
      when "getMe" then @bots.fetch(token)
      when "getUpdates"
        sleep 0.2
        @lock.synchronize { @updates.fetch(token).select { |update| update.fetch("update_id") >= params.fetch("offset", "0").to_i } }
      when "setMyCommands", "sendMessageDraft", "answerCallbackQuery", "sendChatAction" then true
      when "sendMessage", "editMessageText"
        @lock.synchronize { @next_message += 1; { "message_id" => @next_message } }
      else
        raise "Unexpected synthetic Telegram method: #{method}"
      end
      response(200, "ok" => true, "result" => result)
    end

    private

      def response(status, document)
        [status, { "content-type" => "application/json" }, [JSON.generate(document)]]
      end
  end
end
