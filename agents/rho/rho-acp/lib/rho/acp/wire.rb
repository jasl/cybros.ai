# ACP reference: https://agentclientprotocol.com/protocol/v1/transports
require "json"
require_relative "methods"

module Rho
  module Acp
    # THE FRAMING: JSON-RPC 2.0, one JSON object per line, UTF-8, no embedded newline, over
    # ANY IO pair — a pipe in the tests, the process's stdio under `rho acp` (`over_stdio`),
    # a child's under `delegate_agent`. Reads classify by shape: a `method` with an id is a
    # `Request`, without one (absent or null) a `Notification`; a `result` is a `Response`,
    # an `error` a `Failure`. A line that is not JSON (or not UTF-8) is answered -32700 and
    # the next line is read; a line that parses but is no message — not an object, no method
    # and no result, an id that is neither string nor integer — is answered -32600 with its
    # id when it has one. The wire never dies on a bad line, never writes two lines for one
    # message, and serializes every write under one lock so threads never interleave. EOF
    # reads nil, and keeps reading nil; a trailing unterminated line is still a frame (the
    # reference flushes it too).
    class Wire
      Request = Data.define(:id, :method, :params)
      Notification = Data.define(:method, :params)
      Response = Data.define(:id, :result)
      Failure = Data.define(:id, :error)

      # FD-LEVEL HYGIENE: the ORIGINAL fd 1 becomes the wire
      # — a fresh IO on a dup'd descriptor — and STDOUT is reopened onto
      # stderr with `$stdout` pointed there too, so `puts`, `warn`, Thor,
      # the log and every child spawned with an inherited stdout land on
      # stderr; the wire IO is the one holder of the descriptor.
      def self.over_stdio
        output = STDOUT.dup
        STDOUT.reopen(STDERR)
        $stdout = STDERR
        new(input: STDIN, output: output)
      end

      def initialize(input:, output:)
        @input = input
        @output = output
        @input.set_encoding(Encoding::UTF_8)
        @output.set_encoding(Encoding::UTF_8)
        @output.sync = true
        @lock = Mutex.new
        @closed = false
      end

      def closed? = @closed

      def write_request(id, method, params = nil)
        write(with_params({ "jsonrpc" => Methods::JSONRPC, "id" => id, "method" => method }, params))
      end

      def write_notification(method, params = nil)
        write(with_params({ "jsonrpc" => Methods::JSONRPC, "method" => method }, params))
      end

      def write_result(id, result)
        write({ "jsonrpc" => Methods::JSONRPC, "id" => id, "result" => result })
      end

      def write_error(id, code, message, data: nil)
        error = { "code" => code, "message" => message }
        error["data"] = data unless data.nil?
        write({ "jsonrpc" => Methods::JSONRPC, "id" => id, "error" => error })
      end

      # One message, one line, one write under the lock.
      def write(message)
        line = "#{JSON.generate(message)}\n"
        @lock.synchronize do
          raise Closed, "the wire is closed" if @closed

          @output.write(line)
          @output.flush
        end
        nil
      rescue IOError, Errno::EPIPE, Errno::EBADF => error
        raise Closed, "the wire is closed: #{error.message}"
      end

      # The next frame, or nil at EOF (and nil ever after). Bad lines are
      # answered here and skipped, so the caller only ever sees frames.
      def read
        loop do
          line = read_line
          return nil if line.nil?

          frame = classify(line)
          return frame if frame
        end
      end

      def close
        @lock.synchronize { @closed = true }
        [@input, @output].each do |io|
          io.close unless io.closed?
        rescue IOError
          nil
        end
        nil
      end

      private

        def with_params(frame, params)
          frame["params"] = params unless params.nil?
          frame
        end

        def read_line
          return nil if @closed

          @input.gets
        rescue IOError, Errno::EBADF
          nil
        end

        def classify(line)
          return answer(nil, Methods::ErrorCode::PARSE) unless line.valid_encoding?

          text = line.strip
          return nil if text.empty?

          message = JSON.parse(text)
          shape(message)
        rescue JSON::ParserError
          answer(nil, Methods::ErrorCode::PARSE)
        end

        def shape(message)
          return answer(nil, Methods::ErrorCode::INVALID_REQUEST) unless message.is_a?(Hash)

          id = message["id"]
          return answer(nil, Methods::ErrorCode::INVALID_REQUEST) unless id.nil? || id.is_a?(Integer) || id.is_a?(String)

          if message["method"].is_a?(String)
            id.nil? ? Notification.new(message["method"], message["params"]) : Request.new(id, message["method"], message["params"])
          elsif message.key?("result")
            Response.new(id, message["result"])
          elsif message["error"].is_a?(Hash)
            Failure.new(id, message["error"])
          else
            answer(id, Methods::ErrorCode::INVALID_REQUEST)
          end
        end

        # A bad line's answer; a peer that is already gone gets none and
        # the read goes on to its EOF. Always nil: the line is no frame.
        def answer(id, code)
          write_error(id, code, Methods::ErrorCode::MESSAGES.fetch(code))
          nil
        rescue Closed
          nil
        end
    end
  end
end
