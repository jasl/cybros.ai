module CybrosUpdater
  module Transport
    def self.read_line(socket, limit:, timeout:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      buffer = +""
      loop do
        wait(socket, :read, deadline)
        chunk = socket.read_nonblock([4096, limit + 1 - buffer.bytesize].min, exception: false)
        next if chunk == :wait_readable
        if chunk.nil?
          raise Error.new("invalid_request", "A complete JSON request line is required.", status: 400)
        end
        buffer << chunk
        if buffer.bytesize > limit
          raise Error.new("invalid_request", "The deployment message exceeds its size limit.", status: 400)
        end
        if buffer.include?("\n")
          return buffer
        end
      end
    end

    def self.write_line(socket, line, timeout:)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + timeout
      remaining = line
      until remaining.empty?
        wait(socket, :write, deadline)
        written = socket.write_nonblock(remaining, exception: false)
        next if written == :wait_writable
        remaining = remaining.byteslice(written..)
      end
    end

    def self.wait(socket, direction, deadline)
      remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
      ready = if remaining.positive?
        direction == :read ? IO.select([socket], nil, nil, remaining) : IO.select(nil, [socket], nil, remaining)
      end
      unless ready
        raise Error.new("updater_unavailable", "The deployment connection exceeded its deadline.")
      end
    end
  end

  class Server
    def initialize(engine:, socket_path:, group: 1000)
      @engine = engine
      @socket_path = socket_path
      @group = group
      @slots = SizedQueue.new(8)
    end

    def run
      directory = File.dirname(@socket_path)
      FileUtils.mkdir_p(directory, mode: 0o750)
      File.chown(Process.uid, @group, directory)
      File.chmod(0o750, directory)
      FileUtils.rm_f(@socket_path)
      @server = UNIXServer.new(@socket_path)
      File.chown(nil, @group, @socket_path)
      File.chmod(0o660, @socket_path)
      loop do
        socket = @server.accept
        begin
          @slots.push(true, true)
          Thread.new(socket) do |connection|
            begin
              handle(connection)
            ensure
              connection.close
              @slots.pop
            end
          end
        rescue ThreadError
          socket.close
        end
      end
    ensure
      @server&.close unless @server&.closed?
    end

    def close
      @server&.close
    end

    private

    def handle(socket)
      begin
        bytes = Transport.read_line(socket, limit: REQUEST_LIMIT, timeout: 5)
        request = JSON.parse(bytes)
        result = @engine.call(request)
      rescue JSON::ParserError
        result = { "status" => 400, "error" => { "code" => "invalid_request", "message" => "The deployment request is not valid JSON." } }
      rescue Error => error
        result = { "status" => error.status, "error" => error.to_h }
      rescue StandardError
        result = { "status" => 503, "error" => { "code" => "updater_unavailable", "message" => "The updater could not complete this request." } }
      end
      line = JSON.generate(result) + "\n"
      if line.bytesize > RESPONSE_LIMIT
        line = JSON.generate({ "status" => 503, "error" => { "code" => "updater_unavailable", "message" => "The deployment response exceeds its size limit." } }) + "\n"
      end
      Transport.write_line(socket, line, timeout: 5)
    rescue Error, IOError, SystemCallError
      # Disconnecting an observer does not cancel an accepted upgrade.
      nil
    end
  end

  class Client
    def initialize(socket_path)
      @socket_path = socket_path
    end

    def call(request)
      line = JSON.generate(request) + "\n"
      if line.bytesize > REQUEST_LIMIT
        raise Error.new("invalid_request", "The deployment request exceeds its size limit.", status: 400)
      end
      socket = Socket.new(Socket::AF_UNIX, Socket::SOCK_STREAM)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 5
      connected = socket.connect_nonblock(Socket.sockaddr_un(@socket_path), exception: false)
      if connected == :wait_writable
        Transport.wait(socket, :write, deadline)
        result = socket.getsockopt(Socket::SOL_SOCKET, Socket::SO_ERROR).int
        raise SystemCallError.new("Deployment connection failed", result) unless result.zero?
      end
      Transport.write_line(socket, line, timeout: 5)
      timeout = { "check" => 120, "refresh_installed" => 15, "resume" => 10 }.fetch(request.fetch("operation"), 5)
      bytes = Transport.read_line(socket, limit: RESPONSE_LIMIT, timeout: timeout)
      JSON.parse(bytes)
    rescue SystemCallError, IOError, JSON::ParserError
      raise Error.new("updater_unavailable", "The installation updater is unavailable.")
    ensure
      socket&.close
    end
  end
end
