# ACP reference: https://agentclientprotocol.com/protocol/v1/cancellation
require_relative "wire"

module Rho
  module Acp
    # THE TWO-WAY LOOP: one connection per wire, both roles at once. Outbound: `request`
    # mints an id of our own and answers a `Pending` the caller waits on; `notify` sends a
    # one-way message. Inbound: the READER THREAD ONLY PARSES — it resolves our pendings by
    # id, flags cancels, and queues every request and notification for the caller, who
    # drains with `receive` or `run` on a thread of its own (`ExecutionContext` is
    # thread-local in the runner; the park thread of `rho acp` answers later). An `Inbound`
    # is the way to answer later: `respond`, `fail`, `fail_cancelled`, from any thread,
    # once.
    #
    # `$/cancel_request` BOTH WAYS: `Pending#cancel` sends
    # the notice for a request WE issued and the peer answers -32800 (a
    # `RemoteError` of that code) or a result; the peer's notice marks OUR
    # inbound request `cancelled?` and fires its `on_cancel` hooks on the
    # reader thread — a hook must not block (set a flag, push a queue),
    # the same rule as the runner's cancel signal. The notice itself is
    # protocol-level and never reaches the drainer; one for an unknown or
    # already-answered id is ignored.
    #
    # EOF either way closes cleanly: `receive` answers nil, every waiting
    # `Pending` raises `Closed`, later sends raise `Closed`; `close` is
    # idempotent and may be called from any thread.
    class Connection
      CLOSED = Object.new.freeze
      private_constant :CLOSED

      # A request we issued, awaiting the peer.
      class Pending
        attr_reader :id

        def initialize(id, connection)
          @id = id
          @connection = connection
          @queue = Queue.new
          @outcome = nil
          @cancelled = false
        end

        # The result, or `RemoteError` for the peer's error, `Closed` when
        # the connection ended first, `Unanswered` past `timeout`.
        def wait(timeout: nil)
          outcome = @outcome
          if outcome.nil?
            outcome = @queue.pop(timeout: timeout)
            raise Unanswered, "no answer to request #{@id} within #{timeout}s" if outcome.nil?

            @outcome = outcome
          end
          kind, value = outcome
          raise value unless kind == :result

          value
        end

        def done? = !@outcome.nil? || !@queue.empty?

        # Sends `$/cancel_request {requestId}`; the peer still answers.
        def cancel
          @cancelled = true
          @connection.notify(Methods::CANCEL_REQUEST, { "requestId" => @id })
          nil
        rescue Closed
          nil
        end

        def cancelled? = @cancelled

        # The reader's: one outcome, once.
        def resolve(outcome)
          @queue << outcome
          nil
        end
      end

      # A request the peer issued, answered once from any thread.
      class Inbound
        attr_reader :id, :method, :params

        def initialize(id, method, params, wire, release)
          @id = id
          @method = method
          @params = params
          @wire = wire
          @release = release
          @lock = Mutex.new
          @answered = false
          @cancelled = false
          @hooks = []
        end

        def answered? = @lock.synchronize { @answered }

        def cancelled? = @lock.synchronize { @cancelled }

        # Runs when the peer cancels this request — at once when it already
        # has. On the reader thread: never block in it.
        def on_cancel(&block)
          run_now = @lock.synchronize do
            @hooks << block unless @cancelled
            @cancelled
          end
          block.call if run_now
          nil
        end

        def respond(result)
          answer { @wire.write_result(@id, result) }
        end

        def fail(code, message, data: nil)
          answer { @wire.write_error(@id, code, message, data: data) }
        end

        def fail_cancelled
          code = Methods::ErrorCode::REQUEST_CANCELLED
          fail(code, Methods::ErrorCode::MESSAGES.fetch(code))
        end

        # The reader's: flag, then the hooks, each shielded from the others.
        def mark_cancelled
          hooks = @lock.synchronize do
            @cancelled = true
            @hooks.shift(@hooks.length)
          end
          hooks.each do |hook|
            hook.call
          rescue StandardError
            nil
          end
          nil
        end

        private

          def answer
            @lock.synchronize do
              raise Error, "request #{@id} (#{@method}) was already answered" if @answered

              @answered = true
            end
            @release.call(@id)
            yield
            nil
          end
      end

      def initialize(wire)
        @wire = wire
        @events = Queue.new
        @pending = {}
        @inbound = {}
        @lock = Mutex.new
        @next_id = 0
        @closed = false
        @reader = Thread.new { read_loop }
        @reader.name = "rho-acp-reader"
      end

      def closed? = @closed

      def request(method, params = nil)
        pending = @lock.synchronize do
          raise Closed, "the connection is closed" if @closed

          id = @next_id
          @next_id += 1
          @pending[id] = Pending.new(id, self)
        end
        begin
          @wire.write_request(pending.id, method, params)
        rescue Closed
          @lock.synchronize { @pending.delete(pending.id) }
          raise
        end
        pending
      end

      def notify(method, params = nil)
        raise Closed, "the connection is closed" if @closed

        @wire.write_notification(method, params)
      end

      # The next inbound event — an `Inbound` request or a
      # `Wire::Notification` — or nil at the timeout or once closed
      # (`closed?` tells which).
      def receive(timeout: nil)
        event = @events.pop(timeout: timeout)
        return nil if event.nil?
        return event unless event.equal?(CLOSED)

        @events << CLOSED
        nil
      end

      # Drains on the caller's thread until the connection closes. A
      # handler that raises on a request it has not answered gets the
      # peer a -32603 naming the exception, and the loop goes on.
      def run
        while (event = receive)
          begin
            yield event
          rescue StandardError => error
            raise unless event.is_a?(Inbound) && !event.answered?

            event.fail(Methods::ErrorCode::INTERNAL, "#{error.class}: #{error.message}")
          end
        end
        nil
      end

      def close
        finish
        @reader.join(1) unless Thread.current == @reader
        nil
      end

      private

        def read_loop
          while (frame = @wire.read)
            case frame
            when Wire::Request then enqueue_request(frame)
            when Wire::Notification then notification(frame)
            when Wire::Response then resolve(frame.id, [:result, frame.result])
            when Wire::Failure then resolve(frame.id, [:error, RemoteError.from(frame.error)])
            else nil
            end
          end
        ensure
          finish
        end

        def enqueue_request(frame)
          inbound = Inbound.new(frame.id, frame.method, frame.params, @wire, ->(id) { release(id) })
          @lock.synchronize { @inbound[frame.id] = inbound }
          @events << inbound
        end

        def notification(frame)
          return @events << frame unless frame.method == Methods::CANCEL_REQUEST

          id = frame.params.is_a?(Hash) ? frame.params["requestId"] : nil
          inbound = @lock.synchronize { @inbound[id] }
          inbound&.mark_cancelled
        end

        def resolve(id, outcome)
          pending = @lock.synchronize { @pending.delete(id) }
          pending&.resolve(outcome)
        end

        def release(id)
          @lock.synchronize { @inbound.delete(id) }
        end

        # The one ending, from EOF, a read error or `close`: the wire
        # closed, every waiting pending failed, the drainer told.
        def finish
          pendings = @lock.synchronize do
            return if @closed

            @closed = true
            @pending.values.tap { @pending.clear }
          end
          @wire.close
          error = Closed.new("the connection is closed")
          pendings.each { |pending| pending.resolve([:error, error]) }
          @events << CLOSED
        end
    end
  end
end
