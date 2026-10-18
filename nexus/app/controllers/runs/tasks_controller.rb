class Runs::TasksController < Runs::BaseController
  def index
    @page = keyset_page(task_scope, columns: { node_key: :text })
    live_ids = NexusServer.live_ids
    @tasks = @page.records.map { |task| AgentAPI::RunPresenter.task(task, live_server_ids: live_ids) }
  end

  def show
    @task = task_scope.find_by!(node_key: params.fetch(:id))
    @detail = AgentAPI::RunPresenter.task_detail(@task)
    @attachments = task_attachments
    @usage = Runs::Transcript.round_snapshot(@task)[:usage] if @task.model_task?
    @cancel_branch = cancel_branch_available?
    @compaction_step = compaction_step
    @compaction_state = compaction_state if @compaction_step
    @compact = @compaction_step.nil? && Runs::Tasks::Compact.refusal_for(
      run: @run, node: @task, acting_user: acting_user).nil?
  end

  private

    def cancel_branch_available?
      return false unless @run.writable_by?(acting_user) && Run::ADJUDICABLE_STATUSES.include?(@run.status)

      Runs::BranchClosure.members(@task).any? { |member| !member.terminal? }
    end

    def compaction_step
      return unless @task.model_task?

      key = @task.compaction.to_h[Tasks::ModelTask::SUMMARY_SOURCE].presence
      if key
        @run.tasks.find_by(node_key: key)
      elsif @task.pruned_before.nil? && !Runs::LifecycleHooks.summary_loop?(@run)
        Runs::LifecycleHooks.find(@run, "pre_compact", @task)
      end
    end

    def compaction_state
      if @compaction_step.lifecycle_event == "pre_compact"
        if @compaction_step.status == "completed" || @compaction_step.failure_resolution.present?
          :hook_finished
        else
          @compaction_step.terminal? ? :unavailable : :hook
        end
      elsif @compaction_step.usable_summary?
        :ready
      else
        @compaction_step.terminal? ? :unavailable : :waiting
      end
    end

    def task_attachments
      public_ids = @detail.fetch(:content, []).filter_map do |block|
        block.fetch(:uri).delete_prefix(Runs::Parks::ResultContent::URI_PREFIX) if
          block.fetch(:type) == Runs::Parks::ResultContent::RESOURCE_LINK
      end.uniq
      return [] if public_ids.empty? || @task.output_body.nil?

      # The readable Task supplies the reference authority; the bytes route
      # checks it again. Link labels are opaque, so display the bound blob facts.
      uploads = @task.output_body.content_uploads.joins(file_attachment: :blob)
        .with_attached_file.index_by(&:public_id)
      public_ids.filter_map do |public_id|
        upload = uploads[public_id]
        if upload
          { public_id: upload.public_id, filename: upload.filename.to_s,
            content_type: upload.content_type, byte_size: upload.byte_size }
        end
      end
    end
end
