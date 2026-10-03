module Rho
  class Core
    # Scheduled work is persisted and advanced by Nexus. These methods expose
    # that resource to every rho surface without a local clock or job store.
    module ScheduledJobs
      UNSET = Object.new.freeze

      def scheduled_jobs(public_id, after: nil, limit: nil, workspace_public_id: nil)
        scheduled_job_read(public_id, nil, nil, after: after, limit: limit, workspace_public_id: workspace_public_id)
      end

      def scheduled_job(public_id, job_public_id, workspace_public_id: nil)
        scheduled_job_read(public_id, job_public_id, "detail", workspace_public_id: workspace_public_id).fetch("scheduled_job")
      end

      def scheduled_job_executions(public_id, job_public_id, after: nil, limit: nil, workspace_public_id: nil)
        scheduled_job_read(public_id, job_public_id, "executions", after: after, limit: limit, workspace_public_id: workspace_public_id)
      end

      def create_scheduled_job(public_id, prompt:, rule:, idempotency_key:, name: nil, model: nil, reasoning_effort: nil,
                               configuration: nil, tool_names: nil, approval_mode: nil, to: nil, speaker_actor_public_id: nil,
                               workspace_public_id: nil)
        fields = { prompt: prompt, rule: rule, idempotency_key: idempotency_key, name: name, model: model,
          reasoning_effort: reasoning_effort, configuration: configuration, tool_names: tool_names, approval_mode: approval_mode,
          to: to, speaker_actor_public_id: speaker_actor_public_id }.compact
        scheduled_job_write(public_id, nil, "create", fields, workspace_public_id: workspace_public_id)
      end

      def update_scheduled_job(public_id, job_public_id, expected_lock_version:, prompt: UNSET, rule: UNSET, name: UNSET,
                               model: UNSET, reasoning_effort: UNSET, configuration: UNSET, tool_names: UNSET,
                               approval_mode: UNSET, to: UNSET, speaker_actor_public_id: UNSET, workspace_public_id: nil)
        fields = { expected_lock_version: expected_lock_version, prompt: prompt, rule: rule, name: name, model: model,
          reasoning_effort: reasoning_effort, configuration: configuration, tool_names: tool_names, approval_mode: approval_mode,
          to: to, speaker_actor_public_id: speaker_actor_public_id }.reject { |_key, value| UNSET.equal?(value) }
        scheduled_job_write(public_id, job_public_id, "update", fields, workspace_public_id: workspace_public_id)
      end

      def pause_scheduled_job(public_id, job_public_id, workspace_public_id: nil)
        scheduled_job_write(public_id, job_public_id, "pause", {}, workspace_public_id: workspace_public_id)
      end

      def resume_scheduled_job(public_id, job_public_id, workspace_public_id: nil)
        scheduled_job_write(public_id, job_public_id, "resume", {}, workspace_public_id: workspace_public_id)
      end

      def cancel_scheduled_job(public_id, job_public_id, workspace_public_id: nil)
        scheduled_job_write(public_id, job_public_id, "cancel", {}, workspace_public_id: workspace_public_id)
      end

      private

        def scheduled_job_read(public_id, job_public_id, operation, after: nil, limit: nil, workspace_public_id:)
          query = { public_id: public_id, job_public_id: job_public_id, after: after, limit: limit,
            workspace_public_id: workspace_public_id }.compact
          path = ["/conversations/scheduled_jobs", operation].compact.join("/")
          response = get(require_daemon, "#{path}?#{URI.encode_www_form(query)}", budget: Budget::KERNEL_ROUND_TRIP)
          document = parse(response)
          refuse(response, document, "the daemon refused to read scheduled jobs") unless response.code.to_i == 200

          document
        end

        def scheduled_job_write(public_id, job_public_id, operation, fields, workspace_public_id:)
          body = fields.merge(public_id: public_id, job_public_id: job_public_id, workspace_public_id: workspace_public_id)
          body.delete(:job_public_id) if job_public_id.nil?
          body.delete(:workspace_public_id) if workspace_public_id.nil?
          response = post(require_daemon, "/conversations/scheduled_jobs/#{operation}", body, budget: Budget::KERNEL_ROUND_TRIP)
          document = parse(response)
          refuse(response, document, "the daemon refused to #{operation} the scheduled job") unless [200, 201].include?(response.code.to_i)

          document.fetch("scheduled_job")
        end
    end
  end
end
