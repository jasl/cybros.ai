module Rho
  module Codemode
    State = Data.define(:status, :requests, :pending, :result, :error)

    class Runtime
      DRIVER = File.read(File.join(__dir__, "runtime.js")).freeze
      DEFAULT_TIMEOUT_MS = 1_000
      DEFAULT_HEAP_BYTES = 64 * 1024 * 1024
      MAX_PROGRAM_BYTES = 256 * 1024
      MAX_CONTEXT_BYTES = 8 * 1024 * 1024
      MAX_EVENTS_BYTES = 8 * 1024 * 1024
      MAX_RESULT_BYTES = 1024 * 1024

      def initialize(timeout_ms: DEFAULT_TIMEOUT_MS, heap_bytes: DEFAULT_HEAP_BYTES)
        @timeout_ms = Integer(timeout_ms)
        @heap_bytes = Integer(heap_bytes)
        unless @timeout_ms.positive? && @heap_bytes.positive?
          raise ArgumentError, "timeout_ms and heap_bytes must be positive"
        end
      end

      # The interpreter lives for one invocation. Host IO happens between V8
      # calls, so a waiting Promise retains its stack without spending the VM's
      # computation budget. The host supplies only accepted operation events.
      def call(program:, cancelled: -> { false })
        program_json = JSON.generate(program.to_h)
        program = JSON.parse(program_json)
        if program.fetch("source").bytesize > MAX_PROGRAM_BYTES || program_json.bytesize > MAX_CONTEXT_BYTES
          return failure("input_limit", "Program exceeds the runtime limit")
        end

        # Accepted work retains its declarations across an agent upgrade.
        # Refuse an unsupported language contract before evaluating source.
        binding, tools = Authoring.catalog(tools: program.fetch("tools", []))
          .partition { |declaration| declaration.canonical == Code::NAME }
        unless binding.any? && binding.all? { |declaration| declaration.input_schema["$id"] == Code::BINDING_ID }
          return failure("unsupported_binding", "The task's frozen code binding is unsupported; create new work with the current declaration")
        end

        # The first binding exposes control flow within one interpreter. Its
        # own tool is absent from the same catalog used to validate raw steps.
        program["tools"] = tools.map { |declaration| { "name" => declaration.name, "input_schema" => declaration.input_schema } }

        capability = SecureRandom.hex(32)
        context = MiniRacer::Context.new(timeout: @timeout_ms, max_memory: @heap_bytes)
        context.eval(DRIVER)
        invoke(context, capability, "start", program, cancelled:)
        loop do
          snapshot = invoke(context, capability, "snapshot", nil, cancelled:)
          if JSON.generate(snapshot).bytesize > MAX_RESULT_BYTES
            return failure("output_limit", "Program output or pending requests exceed the runtime limit")
          end

          state = State.new(**snapshot.transform_keys(&:to_sym))
          return state if %w[finished failed].include?(state.status)

          events_json = JSON.generate(yield(state))
          if events_json.bytesize > MAX_EVENTS_BYTES
            return failure("input_limit", "Operation events exceed the runtime limit")
          end
          JSON.parse(events_json).each do |event|
            invoke(context, capability, "event", event, cancelled:)
          end
        end
      rescue Interrupted
        failure("cancelled", "Execution was cancelled")
      rescue MiniRacer::ScriptTerminatedError
        failure("execution_limit", "JavaScript execution exceeded its time limit")
      rescue MiniRacer::V8OutOfMemoryError
        failure("heap_limit", "JavaScript execution exceeded its V8 heap limit")
      rescue MiniRacer::RuntimeError => error
        failure("host_event_error", error.message.lines.first.to_s.strip)
      ensure
        context&.dispose
      end

      private

      Interrupted = Class.new(StandardError)
      def invoke(context, capability, command, value, cancelled:)
        raise Interrupted if cancelled.call

        # Context#call drains resulting Promise microtasks under the same V8
        # timeout. An explicit unbounded microtask checkpoint is never used.
        result = context.call("__rho_codemode", capability, command, value)
        raise Interrupted if cancelled.call
        result
      end

      def failure(code, message)
        State.new(status: "failed", requests: [], pending: [], result: nil,
          error: { "code" => code, "message" => message })
      end
    end
  end
end
