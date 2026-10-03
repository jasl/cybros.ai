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

    def initialize
      @lock = Mutex.new
      @updates, @calls = [], []
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
    def calls = @lock.synchronize { @calls.dup }
    def messages = calls.select { |method, _params| method == "sendMessage" }.map(&:last)

    def message(id:, user:, text:)
      @lock.synchronize do
        @updates << { "update_id" => id, "message" => { "message_id" => id, "date" => Time.now.to_i,
          "chat" => { "id" => user, "type" => "private" },
          "from" => { "id" => user, "first_name" => "Settings tester", "is_bot" => false }, "text" => text } }
      end
    end

    def call(env)
      path = env.fetch("PATH_INFO")
      return response(401, "ok" => false, "error_code" => 401, "description" => "Unauthorized") unless path.start_with?("/bot#{TOKEN}/")

      method = path.split("/").last
      params = Rack::Request.new(env).params
      @lock.synchronize { @calls << [method, params] }
      result = case method
      when "getMe" then BOT
      when "getUpdates"
        sleep 0.2
        @lock.synchronize { @updates.select { |update| update.fetch("update_id") >= params.fetch("offset", "0").to_i } }
      when "setMyCommands", "sendMessageDraft", "answerCallbackQuery" then true
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
