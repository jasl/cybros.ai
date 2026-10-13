module Rho
  module Extensions
    module Compaction
      # The one tool: `history` and `retained_tail` in, the summary text
      # out, through one InferenceRequest on the member plane followed under the
      # runner's clamp.
      class SummarizeHistory
        NAME = Compaction::TOOL_NAME
        DESCRIPTION = "Summarize a run's earlier history for compaction; addressed by the kernel's " \
                      "delegate policy, never offered to a model.".freeze
        # The delegate's `tool_input` as the kernel's arm freezes it: the address fields ride along and constrain nothing here.
        SCHEMA = {
          "type" => "object",
          "properties" => {
            "history" => { "type" => "string" },
            "retained_tail" => { "type" => "string" },
            "conversation" => { "type" => "string" },
            "turn" => { "type" => "string" },
            "run" => { "type" => "string" },
            "task" => { "type" => "string" },
          },
          "required" => ["history"],
        }.freeze
        # REPLAYABLE: a summary is a read of history and a re-run costs one
        # InferenceRequest — so the arm freezes this on the row and its expiry is
        # `timed_out`, never `uncertain`.
        EFFECT_PROFILE = {
          "kind" => "pure", "destructive" => false, "effect_scope" => "closed",
          "idempotency" => "intrinsic", "reconciliation" => "none",
        }.freeze
        # Two minutes: a flash-tier summary runs ten to forty seconds; the
        # park bounds a dead rho's cost to the kernel's fallback.
        TIMEOUT_MS = 120_000
        WORKLOAD = "text_generation".freeze

        class << self
          attr_reader :member_plane, :model, :sleeper

          # Bound at registration (the process table's pattern): the plane
          # callable and the settings; the sleeper is the follow's cadence,
          # injectable so a test does not wait.
          def bind(member_plane:, model:, sleeper: ->(seconds) { sleep(seconds) })
            @member_plane = member_plane
            @model = model
            @sleeper = sleeper
          end

          attr_writer :sleeper
        end

        def initialize(env:)
          @env = env
        end

        def call(args)
          context = Rho::Runner::ExecutionContext.current
          plane = self.class.member_plane&.call(host_public_id: context&.conversation_public_id || context&.run_public_id,
            workspace_public_id: context&.workspace_public_id)
          return Rho::Runner::Result.error("no member plane: this rho holds no adopted workspace, " \
                                           "so it cannot place the summary InferenceRequest") if plane.nil?

          model = self.class.model
          return Rho::Runner::Result.error("no model: compaction.model or default_model must name one") if model.nil?

          lane = plane.client.workspace(plane.workspace_public_id).inference_requests
          accepted = lane.create(workload: WORKLOAD, model: model, input: input_for(args),
            idempotency_key: idempotency_key(context))
          inference_request = follow(lane, accepted.inference_request, context)
          summary(inference_request)
        end

        private

          # Rho's prompt, then the history, then the tail; a missing tail
          # adds nothing.
          def input_for(args)
            [INSTRUCTIONS, args["history"].to_s, args["retained_tail"].to_s].reject(&:empty?).join("\n\n")
          end

          # THE ROW'S KEY: a transport retry replays the standing InferenceRequest
          # instead of billing twice; a second claim cannot happen.
          def idempotency_key(context)
            "#{NAME}:#{context&.run_public_id}:#{context&.task_key}"
          end

          # Under the clamp's checkpoint: the runner's deadline is the park's
          # minus headroom, and a cancel lands at the next poll.
          def follow(lane, inference_request, context)
            until inference_request.finished?
              context&.raise_if_cancelled!
              self.class.sleeper.call(Rho::InferenceRequestRun::POLL_SECONDS)
              context&.raise_if_cancelled!
              inference_request = lane.fetch(inference_request.public_id)
            end
            inference_request
          end

          def summary(inference_request)
            result = inference_request.result
            return Rho::Runner::Result.ok(inference_request.output_text.to_s, title: "summarized") if result.status == "completed"

            raise NoSummary, "the summarizer InferenceRequest #{result.status}: #{result.error&.code || "no error code"}"
          end
      end
    end
  end
end
