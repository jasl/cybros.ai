module Rho
  class Runner
    module Extensions
      # THE TWO HOOKS AROUND A TOOL CALL, and the only two this side owns.
      # Everything about the conversation — provider requests, model
      # selection, compaction, turn lifecycle — belongs to the kernel, so
      # a hook for it here would be a seam into somebody else's core. What
      # is executor-local is exactly what the boundary doc names: tool
      # processes, file mutation, working directories.
      #
      # THE TWO POSTURES ARE OPPOSITE, deliberately.
      #
      # `tool_call` is FAIL-CLOSED: it runs before anything happens and a
      # handler that raises means "I could not decide", which for a gate
      # is a refusal. A hook that could be bypassed by throwing is not a
      # gate.
      #
      # `tool_result` is FAIL-OPEN: the tool already ran, the work is
      # done, and losing a real answer because a formatter raised would
      # turn an observer into a destroyer.
      #
      # A VETO IS DATA, NOT A FAILURE. It answers `Result.error`, which
      # the runner submits as `completed` with `is_error: true` — so the
      # model reads why it was refused and can correct itself. Failing the
      # task instead takes the round's failure policy and tells the model
      # nothing.
      #
      # THE CONTRACT: a handler takes THREE arguments —
      # `(tool_name, arguments, tool)` on `tool_call`, `(tool_name, result,
      # tool)` on `tool_result` — the third the `Toolset::Tool` being run,
      # whose `effect_profile` is the profile the tool ANNOUNCED. A BLOCK
      # that names two (`|name, arguments|`) still runs: a proc drops what
      # it does not name (pinned). A two-parameter LAMBDA raises on the
      # third, which `tool_call` turns into a Veto. THE CHAIN RUNS ON THE
      # WORKER, inside the pool block (`TaskRun#run_handler`): a hook may
      # BLOCK (the checkpoint capture, thirty seconds of `git add`) and
      # costs its own call's park, never the reactor; `ExecutionContext.
      # current` is bound there, so a hook reads the loop off it.
      module Hooks
        EVENTS = %i[tool_call tool_result].freeze

        Registration = Data.define(:event, :extension, :handler, :owner) do
          def initialize(owner: nil, **) = super

          # Daemon callbacks own one invocation. Runner hooks instead keep
          # their existing TaskRun lease across both the before/after chain.
          def call(*arguments)
            lease = owner&.acquire
            handler.call(*arguments)
          ensure
            lease&.release
          end
        end

        # What a `tool_call` handler may answer. Anything else — nil
        # included — means "no opinion", so the ordinary hook is a
        # one-liner that returns nothing.
        Veto = Data.define(:extension, :reason)
        Rewrite = Data.define(:arguments)

        class Host
          attr_reader :owners

          def initialize(registrations = [], log: nil)
            @by_event = registrations.group_by(&:event).freeze
            @owners = registrations.filter_map(&:owner).uniq.freeze
            @log = log
            freeze
          end

          def any?(event) = @by_event.key?(event)

          def names(event) = Array(@by_event[event]).map(&:extension)

          # Returns the arguments to run with, or a Veto. Handlers run in
          # registration order and the FIRST veto stops the chain: a
          # refusal is not something a later hook gets to overturn. `tool`
          # is the `Toolset::Tool` being run (nil from a caller that has
          # none — a unit driving the chain by name).
          def before_call(tool_name, arguments, tool = nil)
            return arguments unless any?(:tool_call)

            @by_event.fetch(:tool_call).reduce(arguments) do |current, registration|
              case invoke_closed(registration, tool_name, current, tool)
              in Veto => veto then return veto
              in Rewrite(arguments: rewritten) then rewritten
              else current
              end
            end
          end

          # Returns the result to submit. A handler that raises is logged
          # and skipped, and a handler answering something that is not a
          # Result is ignored rather than substituted.
          def after_result(tool_name, result, tool = nil)
            return result unless any?(:tool_result)

            @by_event.fetch(:tool_result).reduce(result) do |current, registration|
              case invoke_open(registration, tool_name, current, tool)
              in Result => answer then answer
              else current
              end
            end
          end

          private

            # A CANCELLATION IS THE TASK'S, NEVER A HOOK'S OPINION: the chain
            # runs on the worker under the task's context now, so a hook
            # that blocks (the capture's git) meets the deadline or a stop
            # through `raise_if_cancelled!` — passed through whole, so the
            # run answers it as it answers a handler's (`timed_out` data,
            # `failed` interrupted), never "blocked by rho.checkpoints".
            def invoke_closed(registration, tool_name, arguments, tool)
              registration.handler.call(tool_name, arguments, tool)
            rescue ExecutionContext::Cancelled
              raise
            rescue StandardError => error
              @log&.warn("extension_hook_failed", extension: registration.extension,
                event: "tool_call", tool: tool_name, error_class: error.class.name)
              Veto.new(extension: registration.extension,
                reason: "#{error.class}: #{error.message}")
            end

            def invoke_open(registration, tool_name, result, tool)
              registration.handler.call(tool_name, result, tool)
            rescue ExecutionContext::Cancelled
              raise
            rescue StandardError => error
              @log&.warn("extension_hook_failed", extension: registration.extension,
                event: "tool_result", tool: tool_name, error_class: error.class.name)
              nil
            end
        end
      end
    end
  end
end
