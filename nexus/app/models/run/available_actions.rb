class Run
  # A read snapshot for the console and attention lists. Commands still recheck
  # standing, state and park deadlines under their existing locks.
  class AvailableActions
    def self.attention_tasks(runs:)
      adjudicable = runs.where(status: Run::ADJUDICABLE_STATUSES, details_pruned_at: nil)
        .left_joins(variant: :turn)
        .where("runs.variant_id IS NULL OR turns.active_variant_id = variants.id OR " \
          "(variants.status IN (?) AND variants.origin_variant_id = turns.active_variant_id)",
          Variant::ACTIVE_STATUSES)
      tasks = Task.joins(:run).where(run_id: adjudicable.select(:id))
      maintenance_now = Deployments::Maintenance.effective_now(Time.current)
      clock = "CASE WHEN runs.status = 'paused' AND runs.paused_at IS NOT NULL " \
        "THEN LEAST(runs.paused_at, ?) ELSE ? END"
      parks = tasks.where(status: "needs_approval").or(
        tasks.where(type: Tasks::AwaitTask.sti_name, status: "awaiting_input", resolution_token: [nil, ""]))
      parks = parks.where("tasks.await_started_at IS NULL OR #{Tasks::ParkDeadline::DEADLINE_SQL} > (#{clock})",
        *Tasks::ParkDeadline.deadline_binds, maintenance_now, maintenance_now)
      failures = tasks.where(status: Task::FAILURE_STATUSES, failure_resolution: nil)
        .where("tasks.on_failure != 'absorb' OR (tasks.type = ? AND tasks.error_key = ?)",
          Tasks::ModelTask.sti_name, Conversation::COST_LIMIT_REACHED)
      parks.or(failures)
    end

    def initialize(run:, user:)
      @run = run
      @writable = run.writable_by?(user) && !run.tombstoned? && run.details_pruned_at.nil?
      @now = run.effective_now
    end

    def pause? = @writable && @run.running?
    def resume? = @writable && @run.paused?
    def stop? = @writable && (!@run.terminal? || !@run.stopped?)
    def approve?(task) = deny?(task) && !Deployments::Maintenance.active?
    def deny?(task) = adjudicable? && task.held? && !task.deadline_passed?(@now)
    def answer?(task) = adjudicable? && task.asking? && task.status == "awaiting_input" && !task.deadline_passed?(@now)
    def abandon?(task) = adjudicable? && task.unresolved_failure?
    def retry?(task)
      abandon?(task) && task.join_mode.nil? && task.task_kind != "delegation_task" &&
        !(@run.delivered? && task.lifetime == "turn")
    end

    private

      def adjudicable? = @writable && Run::ADJUDICABLE_STATUSES.include?(@run.status) && !@run.overridden?
  end
end
