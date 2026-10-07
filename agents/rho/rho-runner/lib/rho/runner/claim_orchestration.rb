module Rho
  class Runner
    # The worker retains its execution state while the control reactor accepts
    # operations and records observations under the same live claim.
    class ClaimOrchestration
      POLL_SECONDS = 0.01
      Request = Data.define(:method, :arguments, :answer)
      private_constant :Request

      class Failure < Error; end

      def initialize(task:, claim_token:, log:)
        @task = task
        @claim_token = claim_token
        @log = log
        @pending = Thread::Queue.new
      end

      def run(program:, runtime:)
        context = ExecutionContext.current
        current, trace = snapshot
        unless trace.empty?
          raise Failure, "The previous execution state is unavailable; inspect its accepted work before starting a new invocation"
        end

        position = current.position
        frozen_program = program.to_h.merge("tools" => current.context.tools,
          "model_defaults" => current.context.model_defaults, "environment" => current.context.environment)
        state = runtime.call(program: frozen_program, cancelled: -> { context&.cancelled? || false }) do |pending|
          context&.raise_if_cancelled!
          events = case pending.status
          when "request"
            pending.requests.map { |operation| submit(operation) }
          when "observe"
            observe(after: position)
          else
            raise Failure, "unknown runtime state #{pending.status.inspect}"
          end
          position = events.last.fetch(:position)
          events
        end
        context&.raise_if_cancelled!
        if state.status == "failed"
          raise Failure, "#{state.error.fetch("code")}: #{state.error.fetch("message")}"
        end

        result = state.result
        Result.new(content: result.fetch("content"), structured_content: result["structured_content"],
          structured_content_present: result.key?("structured_content"))
      rescue CybrosAgent::Error => error
        @log.warn("runner_operations_interrupted", code: error.code || error.class.name)
        raise Failure, error.message
      end

      def wait = @pending.empty? ? POLL_SECONDS : 0

      # A native external harness keeps its own live callback while asking a
      # person. Its parent must keep cancellation ownership, so this bounded
      # wait deliberately does not suspend the task. The ask is still ordinary
      # kernel child work, accepted and observed under this exact claim.
      def ask(key:, prompt:, options: nil)
        input = { "prompt" => prompt }
        input["options"] = options unless options.nil?
        operation = { "kind" => "ask", "input" => input }
        current, trace = snapshot
        known = trace.find { |event| event[:type] == "operation" && event[:key] == key }
        if known
          raise Failure, "question changed under an accepted operation key" unless known.fetch(:request) == operation
        else
          accepted = submit({ "key" => key, "request" => operation })
        end
        observed = trace.find { |event| event[:type] == "observation" && event[:key] == key }
        return observed.fetch(:outcome) if observed

        position = accepted ? accepted.fetch(:position) : current.position
        loop do
          events = observe(after: position)
          position = events.last.fetch(:position)
          observed = events.find { |event| event[:type] == "observation" && event[:key] == key }
          return observed.fetch(:outcome) if observed
        end
      end

      def flush
        queued = @pending.pop(timeout: 0)
        return unless queued

        value = @task.public_send(queued.method, claim_token: @claim_token, **queued.arguments)
        queued.answer << { value: value }
      rescue StandardError => error
        queued.answer << { error: error }
      end

      private

        def submit(operation)
          request(:submit, key: operation.fetch("key"), request: operation.fetch("request")).to_h
        rescue CybrosAgent::Api::Conflict => error
          raise unless error.code == "execution_paused"

          # Pause explicitly refused acceptance. Keep the live handler and its
          # exact request while yielding; cancellation still owns the next send.
          ExecutionContext.current&.raise_if_cancelled!
          sleep 0.25
          retry
        rescue CybrosAgent::TransportError => error
          _, trace = snapshot
          accepted = trace.find { |event| event[:type] == "operation" && event[:key] == operation.fetch("key") }
          raise error unless accepted
          unless accepted.fetch(:request) == operation.fetch("request")
            raise Failure, "operation changed under an accepted key"
          end

          accepted
        end

        def observe(after:)
          loop do
            read = request(:observe, after: after)
            return [read.observation.to_h] unless read.waiting?

            sleep 0.25
          end
        rescue CybrosAgent::Api::Conflict, CybrosAgent::TransportError => error
          if error in CybrosAgent::Api::Conflict
            raise unless error.code == "operation_position_changed"
          end
          _, trace = snapshot(after: after)
          raise error if trace.empty?

          trace
        end

        def snapshot(after: nil)
          page = after ? request(:operations, after: after) : request(:operations)
          first = page
          trace = page.trace.map(&:to_h)
          while page.next_after
            page = request(:operations, after: page.next_after)
            trace.concat(page.trace.map(&:to_h))
          end
          [first, trace]
        end

        def request(method, **arguments)
          context = ExecutionContext.current
          context&.raise_if_cancelled!
          answer = Thread::Queue.new
          @pending << Request.new(method: method, arguments: arguments, answer: answer)
          loop do
            context&.raise_if_cancelled!
            response = answer.pop(timeout: POLL_SECONDS)
            next unless response
            raise response.fetch(:error) if response.key?(:error)

            return response.fetch(:value)
          end
        end
    end
  end
end
