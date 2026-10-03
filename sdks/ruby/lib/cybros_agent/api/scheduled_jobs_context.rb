module CybrosAgent
  module Api
    # Durable scheduled work owned by one conversation. Nexus runs each
    # occurrence in a fresh child; clients only author and inspect its intent.
    class ScheduledJobsContext
      include ScheduledJobProjections
      include Fields

      attr_reader :path

      def initialize(dispatch:, path:)
        @dispatch = dispatch
        @path = required_string_snapshot(path, "path")
      end

      def list(after: nil, limit: nil)
        page(ScheduledJob, @dispatch.call(path, params: query(after:, limit:)), "scheduled_jobs")
      end

      def fetch(public_id)
        shape(ScheduledJob, @dispatch.call(job_path(public_id)), "scheduled_job")
      end

      def create(prompt:, rule:, idempotency_key:, name: UNSET, model: UNSET, reasoning_effort: UNSET,
                 configuration: UNSET, tool_names: UNSET, approval_mode: UNSET, to: UNSET, speaker_actor_public_id: UNSET,
                 source_agent_loop_public_id: UNSET, source_task_key: UNSET)
        required_string(idempotency_key, "idempotency_key")
        body = fields(prompt:, rule:, name:, model: field(model) { fields(model:, reasoning_effort:) },
          configuration:, tool_names:, approval_mode:, answering_user_public_id: to, speaker_actor_public_id:,
          source_agent_loop_public_id:, source_task_key:)
        result = @dispatch.call_accepting(path, method: :post, body: { "scheduled_job" => body },
          headers: { "Idempotency-Key" => idempotency_key }, success: 201)
        Created.new(scheduled_job: shape(ScheduledJob, result.body, "scheduled_job"), replayed: result.replayed)
      end

      # Omission keeps a field. Explicit nil is sent for Nexus to judge.
      # A stale version remains a conflict; the SDK never retries a mutation.
      def update(public_id, expected_lock_version:, prompt: UNSET, rule: UNSET, name: UNSET,
                 model: UNSET, reasoning_effort: UNSET, configuration: UNSET, tool_names: UNSET,
                 approval_mode: UNSET, to: UNSET, speaker_actor_public_id: UNSET)
        body = fields(expected_lock_version:, prompt:, rule:, name:,
          model: field(model) { fields(model:, reasoning_effort:) }, configuration:,
          tool_names:, approval_mode:, answering_user_public_id: to, speaker_actor_public_id:)
        shape(ScheduledJob, @dispatch.call(job_path(public_id), method: :patch,
          body: { "scheduled_job" => body }), "scheduled_job")
      end

      def pause(public_id) = command(public_id, "pause")
      def resume(public_id) = command(public_id, "resume")
      def cancel(public_id) = command(public_id, "cancel")

      def executions(public_id, after: nil, limit: nil)
        shape(ScheduledJobExecutionPage, @dispatch.call("#{job_path(public_id)}/executions", params: query(after:, limit:)))
      end

      private

        def command(public_id, operation)
          shape(ScheduledJob, @dispatch.call("#{job_path(public_id)}/#{operation}", method: :post), "scheduled_job")
        end

        def job_path(public_id) = "#{path}/#{path_segment(public_id, "public_id")}"

      Created = Data.define(:scheduled_job, :replayed) do
        def public_id = scheduled_job.public_id
        def replayed? = replayed
      end
    end
  end
end
