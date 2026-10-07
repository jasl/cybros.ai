require "securerandom"

module Rho
  module Extensions
    module Processes
      # THE TABLE ON ANOTHER RUNNER, read through the call_tool: a
      # host this daemon follows runs its tools on a runner that is not this
      # process, so its `start_process` filled a table THERE. Each read here
      # is ONE SDK request — a one-task standalone run on that runner,
      # created, started, polled and (behind a failure) stopped by the SDK's
      # own composition — asking the runner's own person-facing tools:
      # `list_processes` for the rows, `process_log` for one row's tail (the model's `read_process` refuses a call_tool caller by ownership; this one has no owner gate). The rules the verb passes are the same list
      # `rho do` authors, re-addressed to the seed's origin.
      #
      # BOUNDED FOR AN OFFLINE RUNNER: the step's own clock is short and the
      # SDK's `patience` is shorter than the sweep's minute — a runner that
      # never claims costs a person these seconds, never the kernel's
      # settle, and answers as `Unreachable` with the error the task read
      # carries (`tool_timeout` once patience stops the run: `canceled`).
      module Remote
        # A read of a table elsewhere: seconds, not the kernel's default park.
        TIMEOUT_MS = 10_000
        PATIENCE_SLACK_SECONDS = 5.0
        POLL_SECONDS = 0.5

        # The runner could not answer: its id and the error key the terminal
        # task carried (`tool_not_served`, `tool_timeout`, `canceled`…).
        class Unreachable < Rho::Error
          attr_reader :runner, :key

          def initialize(runner, key)
            @runner = runner
            @key = key
            super("runner #{runner} could not answer: #{key}")
          end
        end

        class << self
          # The rows of that runner's table, each naming the runner it lives on.
          def list(ctx, runner)
            detail = call_tool(ctx, runner, Tools::ListProcesses::NAME, {})
            Array(detail.structured_content&.dig("processes")).map { |row| row.merge("runner" => runner) }
          end

          # One row's tail as the daemon's own log door shapes it, or nil for
          # an id that runner does not know.
          def log(ctx, runner, id, lines)
            detail = call_tool(ctx, runner, Tools::ProcessLog::NAME, { "id" => id, "lines" => lines })
            document = detail.structured_content
            return nil unless document.is_a?(Hash) && document["process"].is_a?(Hash)

            document.merge("process" => document.fetch("process").merge("runner" => runner))
          end

          private

            # The one SDK request. A daemon with no member plane (runner mode)
            # follows no host and never reaches here; said as `Unreachable`
            # rather than a nil a caller would read as "no rows".
            def call_tool(ctx, runner, tool, input)
              answer = ctx.member_plane do |client, workspace_public_id|
                context = ctx.runs_for(client, workspace_public_id).start_tool_call(
                  runner_executor_public_id: runner, tool: tool, input: input, timeout_ms: TIMEOUT_MS,
                  approval_rules: Rho::RunDeclaration.request_rules(guard: ctx.config.plugin_enabled?("rho.guard"), roots: Rho.protected_roots(ctx.home)),
                  idempotency_key: SecureRandom.uuid
                )
                context.wait_for_tool_result(poll: POLL_SECONDS, patience: (TIMEOUT_MS / 1000.0) + PATIENCE_SLACK_SECONDS)
              end
              raise Unreachable.new(runner, answer.code) if answer in Rho::Daemon::Refusal
              raise Unreachable.new(runner, answer.task.error&.dig("key") || answer.task.status) unless
                answer.task.status == "completed"
              # The tool RAN and refused (`is_error`, the model's data): the
              # runner's own words are the answer, under one key.
              raise Unreachable.new(runner, "tool_error: #{answer.output}") if answer.task.result&.dig("is_error")

              answer
            end
        end
      end
    end
  end
end
