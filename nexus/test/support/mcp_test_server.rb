require "socket"

# An independent HTTP peer: it observes actual serialized requests and may
# disconnect after recording an operation, before any response reaches Nexus.
class McpTestServer
  attr_reader :requests, :endpoint_url

  def initialize(&handler)
    @server = TCPServer.new("127.0.0.1", 0)
    @endpoint_url = "http://127.0.0.1:#{@server.addr[1]}/mcp"
    @requests = []
    @worker = Thread.new do
      loop do
        socket = @server.accept
        begin
          line = socket.gets&.strip
          next unless line

          headers = {}
          while (header = socket.gets) && header != "\r\n"
            key, value = header.split(":", 2)
            headers[key.downcase] = value.strip
          end
          body = socket.read(headers.fetch("content-length", "0").to_i)
          parsed = if body.empty?
            nil
          elsif headers.fetch("content-type", "").start_with?("application/json")
            JSON.parse(body)
          else
            body
          end
          request = { line: line, headers: headers, body: parsed }
          @requests << request
          response = handler.call(request)
          next unless response

          sleep(response.fetch(:delay, 0))
          status = response.fetch(:status, 200)
          payload = response.key?(:json) ? JSON.generate(response.fetch(:json)) : response.fetch(:body, "")
          fields = { "Content-Type" => "application/json", "Content-Length" => payload.bytesize.to_s,
                     "Connection" => "close" }.merge(response.fetch(:headers, {}))
          socket.write("HTTP/1.1 #{status} Result\r\n#{fields.map { |key, value| "#{key}: #{value}\r\n" }.join}\r\n")
          socket.write(payload)
          sleep(response.fetch(:keep_open, 0))
        rescue Errno::EPIPE, Errno::ECONNRESET
          nil
        ensure
          socket.close
        end
      end
    rescue IOError, Errno::EBADF
      nil
    end
  end

  def close
    @server.close
    @worker.join(2)
    @worker.kill if @worker.alive?
  end
end
