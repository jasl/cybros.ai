require "fileutils"
require "json"
require "securerandom"
require "socket"

module E2E
  # This in-process loopback server stands in for an editor's filesystem port. It serves the same
  # authenticated `/fs/read` and `/fs/write` shapes as rho's client. An in-memory buffer may differ
  # from disk; writes update that buffer and a journey-owned disk mirror. The journey therefore
  # proves that reads see unsaved editor content and writes reach the editor's filesystem rather
  # than rho's.
  #
  # MODES, the lane's dials: `serve` (the buffers as they are), `refuse`
  # (every write is the editor's refusal; reads serve), `slow` (every
  # answer waits `delay` seconds — past the client's clock, a timeout),
  # `die` (the listener closes; the next connection is refused at once),
  # `beyond_eof` (every read answers the editor's beyond-EOF error). Every
  # request is recorded, so a write the port made is observed as a fact.
  class FsPortServer
    MODES = %w[serve refuse slow die beyond_eof].freeze
    Request = Data.define(:path, :headers, :body)

    attr_reader :requests, :mirror, :token, :buffers, :mode

    def initialize(mirror:, token: SecureRandom.hex(16), delay: 35)
      @mirror = mirror
      @token = token
      @delay = delay
      @mode = "serve"
      @buffers = {}.freeze
      @requests = []
      @listener = nil
      @threads = []
    end

    def start
      @listener = TCPServer.new("127.0.0.1", 0)
      # Named at the start and kept: a dead server's URL still points at
      # the closed port, which is what a refused connection needs.
      @url = "http://127.0.0.1:#{@listener.local_address.ip_port}"
      @accept = Thread.new { accept_loop }
      @accept.report_on_exception = false
      self
    end

    attr_reader :url

    def stop
      @listener.close if @listener && !@listener.closed?
      @accept&.join(1)
      @threads.each { |thread| thread.join(1) }
      nil
    end

    # `die` closes the listener at once; every other mode is read per
    # request.
    def mode=(mode)
      raise ArgumentError, "no such mode: #{mode.inspect}" unless MODES.include?(mode)

      @mode = mode
      stop if mode == "die"
    end

    # The editor's buffer for an ABSOLUTE path, as `ToolEnv#resolve` will
    # spell it; nil forgets it.
    def set_buffer(path, text)
      @buffers = text.nil? ? @buffers.except(path).freeze : @buffers.merge(path => text).freeze
      text
    end

    def mirror_path(path) = File.join(@mirror, path.delete_prefix("/"))

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
        sleep @delay if @mode == "slow"
        status, body = answer(request)
        payload = JSON.generate(body)
        socket.write("HTTP/1.1 #{status} #{status == 200 ? "OK" : "Refused"}\r\nContent-Type: application/json\r\n" \
                     "Content-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      rescue IOError, SystemCallError
        nil
      ensure
        socket.close unless socket.closed?
      end

      def read_request(socket)
        line = socket.gets
        return nil if line.nil?

        verb, path, = line.split(" ")
        headers = {}
        while (header = socket.gets) && header != "\r\n"
          name, value = header.split(":", 2)
          headers[name.downcase] = value.to_s.strip
        end
        raw = socket.read(headers.fetch("content-length", "0").to_i).to_s
        body = raw.empty? ? nil : JSON.parse(raw)
        Request.new(path: "#{verb} #{path}", headers: headers, body: body)
      rescue JSON::ParserError
        Request.new(path: "#{verb} #{path}", headers: headers, body: :malformed)
      end

      def answer(request)
        return refusal(401, "unauthorized", "the bearer is not this surface's") unless
          request.headers["authorization"] == "Bearer #{@token}"
        return refusal(400, "malformed", "the body is not a JSON object") unless request.body.is_a?(Hash)

        case request.path
        when "POST /fs/read" then read(request.body)
        when "POST /fs/write" then write(request.body)
        else refusal(404, "no_route", request.path)
        end
      end

      def read(body)
        return refusal(409, "beyond_eof", "line #{body["line"]} is past the end of the buffer") if @mode == "beyond_eof"

        text = @buffers[body.fetch("path")]
        return refusal(404, "not_found", "the editor holds no buffer for #{body.fetch("path")}") if text.nil?

        lines = text.lines
        line = Integer(body.fetch("line", 1))
        limit = Integer(body.fetch("limit", lines.length))
        return refusal(409, "beyond_eof", "line #{line} is past the end of the buffer") if line > lines.length && !(line == 1 && lines.empty?)

        [200, { "text" => lines[line - 1, limit].to_a.join }]
      end

      def write(body)
        return refusal(409, "editor_refused", "the editor refused the write") if @mode == "refuse"

        path = body.fetch("path")
        text = body.fetch("text")
        set_buffer(path, text)
        FileUtils.mkdir_p(File.dirname(mirror_path(path)))
        File.write(mirror_path(path), text, encoding: Encoding::UTF_8)
        [200, { "ok" => true }]
      end

      def refusal(status, code, message) = [status, { "error" => { "code" => code, "message" => message } }]
  end
end
