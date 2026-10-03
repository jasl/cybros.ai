require "socket"
require "uri"

module TelegramTest
  # Real HTTP/1.1 sockets exercise the gem and HTTPX adapter, including broken
  # responses. This server accepts only the synthetic token used by the suite.
  class FakeTelegram
    TOKEN = "12345:FAKE_TELEGRAM_TEST"

    attr_reader :url

    def initialize
      @listener = TCPServer.new("127.0.0.1", 0)
      @url = "http://127.0.0.1:#{@listener.addr[1]}"
      @mutex = Mutex.new
      @requests = []
      @workers = []
      @sockets = []
      @gates = Hash.new { |hash, key| hash[key] = Queue.new }
      @acceptor = Thread.new { accept_connections }
    end

    def count(method, hold: nil)
      @mutex.synchronize do
        @requests.count { |row| row[:method] == method && (!hold || row[:params]["hold"] == hold) }
      end
    end

    def release(hold)
      @gates[hold] << true
    end

    def stop
      @listener.close
      @acceptor.join(1)
      @gates.each_value { |gate| gate << true }
      @sockets.each { |socket| socket.close unless socket.closed? }
      @workers.each { |worker| worker.join(1) || worker.kill }
    end

    private

    def accept_connections
      loop do
        socket = @listener.accept
        @sockets << socket
        @workers << Thread.new(socket) { |client| serve(client) }
      end
    rescue IOError, Errno::EBADF
      nil
    end

    def serve(socket)
      request_line = socket.gets
      return unless request_line

      headers = {}
      while (line = socket.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.downcase] = value.strip
      end
      body = socket.read(headers.fetch("content-length", "0").to_i)
      params = if headers.fetch("content-type", "").start_with?("multipart/")
        { "multipart_body" => body, "content_type" => headers.fetch("content-type") }
      else
        URI.decode_www_form(body).to_h
      end
      path = URI.parse(request_line.split[1]).path
      unless path.start_with?("/bot#{TOKEN}/") || path.start_with?("/file/bot#{TOKEN}/")
        raise "Unexpected test credential"
      end

      method = path.split("/").last
      @mutex.synchronize { @requests << { method: method, params: params } }
      answer(socket, method, params)
    rescue IOError, Errno::EPIPE, Errno::ECONNRESET
      nil
    ensure
      socket.close unless socket.closed?
    end

    def answer(socket, method, params)
      case method
      when "getUpdates"
        @gates[params.fetch("hold")].pop
        respond(socket, 200, ok: true, result: [{
          update_id: 42,
          stopped_message_generation: { chat: { id: 123 }, draft_id: 9, future_field: "preserved" },
          future_update_field: { value: 7 },
        }])
      when "sendMessage", "sendMessageDraft", "futureTelegramMethod", "sendPhoto", "sendDocument", "sendVoice"
        respond(socket, 200, ok: true, result: { message_id: 99, received: params })
      when "file.jpg"
        raw_response(socket, 200, "image-bytes", { "Content-Type" => "image/jpeg" })
      when "large.jpg"
        raw_response(socket, 200, "x" * 65_536)
      when "file-redirect.jpg"
        raw_response(socket, 302, "", { "Location" => "#{url}/file/bot#{TOKEN}/file.jpg" })
      when "rateLimited"
        respond(socket, 429, ok: false, error_code: 429,
          description: "Too Many Requests", parameters: { retry_after: 7 })
      when "badFormatting"
        respond(socket, 400, ok: false, error_code: 400,
          description: "Bad Request: cannot parse #{TOKEN}")
      when "serverError"
        respond(socket, 500, ok: false, error_code: 500, description: "Failed #{TOKEN}")
      when "invalidResponse"
        raw_response(socket, 200, "not JSON #{TOKEN}")
      when "nonJsonError"
        raw_response(socket, 502, "upstream unavailable")
      when "redirect"
        respond(socket, 302, { ok: false }, { "Location" => "#{url}/bot#{TOKEN}/redirectTarget" })
      when "redirectTarget"
        respond(socket, 200, ok: true, result: true)
      when "ambiguousSend"
        socket.close
      else
        respond(socket, 404, ok: false, error_code: 404, description: "Unknown fake method")
      end
    end

    def respond(socket, status, payload, headers = {})
      raw_response(socket, status, JSON.generate(payload), headers)
    end

    def raw_response(socket, status, body, headers = {})
      headers = { "Content-Type" => "application/json", "Content-Length" => body.bytesize.to_s,
        "Connection" => "close" }.merge(headers)
      socket.write("HTTP/1.1 #{status} Fake\r\n")
      headers.each { |name, value| socket.write("#{name}: #{value}\r\n") }
      socket.write("\r\n#{body}")
    end
  end
end
