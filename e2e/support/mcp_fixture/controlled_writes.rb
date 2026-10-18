require "json"
require "uri"

module E2E
  module McpFixture
    # The external write happens before its response is released. A journey
    # can kill the caller in that gap and inspect whether it sends again.
    class ControlledWrites
      HOLD_SECONDS = 60
      Write = Struct.new(:count, :waiting, :released, keyword_init: true)
      class HoldExpired < StandardError; end

      def initialize(hold_seconds: HOLD_SECONDS)
        @hold_seconds = hold_seconds
        @mutex = Mutex.new
        @released = ConditionVariable.new
        @writes = {}
      end

      def write(text)
        @mutex.synchronize do
          if (entry = @writes[text])
            entry.count += 1
            entry.waiting += 1
            begin
              deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @hold_seconds
              until entry.released
                remaining = deadline - Process.clock_gettime(Process::CLOCK_MONOTONIC)
                raise HoldExpired, "the MCP fixture write response was not released" unless remaining.positive?

                @released.wait(@mutex, remaining)
              end
            ensure
              entry.waiting -= 1
            end
          end
        end
      end

      # These controls exist only on the separately spawned HTTP fixture.
      # Other requests still reach the ordinary MCP gem transport.
      def response(env)
        case [env.fetch("REQUEST_METHOD"), env.fetch("PATH_INFO")]
        in ["POST", "/fixture/writes/hold"]
          text = JSON.parse(env.fetch("rack.input").read).fetch("text")
          @mutex.synchronize do
            raise ArgumentError, "write marker already armed" if @writes.key?(text)

            @writes[text] = Write.new(count: 0, waiting: 0, released: false)
          end
          json(snapshot(text))
        in ["POST", "/fixture/writes/release"]
          text = JSON.parse(env.fetch("rack.input").read).fetch("text")
          @mutex.synchronize do
            @writes.fetch(text).released = true
            @released.broadcast
          end
          json(snapshot(text))
        in ["GET", "/fixture/writes"]
          text = URI.decode_www_form(env.fetch("QUERY_STRING", "")).to_h.fetch("text")
          json(snapshot(text))
        else nil
        end
      end

      private

        def snapshot(text)
          @mutex.synchronize do
            entry = @writes.fetch(text)
            { "count" => entry.count, "waiting" => entry.waiting }
          end
        end

        def json(value)
          [200, { "content-type" => "application/json" }, [JSON.generate(value)]]
        end
    end
  end
end
