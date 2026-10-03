require "json"
require "socket"

module RhoTest
  # THE SURFACE'S FILE-SYSTEM PORT, SCRIPTED: a loopback HTTP/1.1 server on an ephemeral port, one thread per
  # connection, answering `POST /fs/read` and `POST /fs/write` by a script
  # the test hands in — `->(path, body) { [status, json | raw_string] |
  # :hang | :close | :garbage }` — so every row of the client's error
  # table has a wire behind it: a refused connection (the listener
  # closed), a timeout (a connection that never answers), a 5xx (with a
  # JSON body, or a raw one — a proxy's HTML), a non-JSON body, and the
  # client's own cancel signal cutting a hanging session. Every request
  # is recorded with its headers, so the bearer and the JSON shapes are
  # pinned as bytes.
  class FsPortDouble
    Request = Data.define(:path, :headers, :body)

    attr_reader :requests

    def initialize(&script)
      @script = script
      @requests = []
      @listener = TCPServer.new("127.0.0.1", 0)
      @url = "http://127.0.0.1:#{@listener.local_address.ip_port}"
      @threads = []
      @accept = Thread.new { accept_loop }
      @accept.report_on_exception = false
    end

    attr_reader :url

    # The listener closed: the next connection is refused at once.
    def close
      @listener.close unless @listener.closed?
      @accept.join(1)
      @threads.each { |thread| thread.join(1) }
      nil
    end

    private

      def accept_loop
        loop do
          socket = @listener.accept
          thread = Thread.new(socket) { |client| serve(client) }
          thread.report_on_exception = false
          @threads << thread
        end
      rescue IOError, Errno::EBADF
        nil
      end

      def serve(socket)
        request = read_request(socket)
        return if request.nil?

        @requests << request
        answer = @script.call(request.path, request.body)
        case answer
        when :hang then socket.read(1)
        when :close then nil
        when :garbage then socket.write("HTTP/1.1 200 OK\r\nContent-Length: 9\r\nConnection: close\r\n\r\nnot json!")
        else
          status, body = answer
          payload = body.is_a?(String) ? body : JSON.generate(body)
          type = body.is_a?(String) ? "text/html" : "application/json"
          socket.write("HTTP/1.1 #{status} X\r\nContent-Type: #{type}\r\n" \
                       "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
        end
      rescue IOError, SystemCallError
        nil
      ensure
        socket.close unless socket.closed?
      end

      def read_request(socket)
        line = socket.gets
        return nil if line.nil?

        _verb, path, = line.split(" ")
        headers = {}
        while (header = socket.gets) && header != "\r\n"
          name, value = header.split(":", 2)
          headers[name.downcase] = value.to_s.strip
        end
        body = socket.read(headers.fetch("content-length", "0").to_i).to_s
        Request.new(path: path, headers: headers, body: body.empty? ? nil : JSON.parse(body))
      end
  end
end
