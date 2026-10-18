class RunsController < Work::BaseController
  def show
    @run = find_visible_run
    @current_model = Runs::CurrentModel.for(@run)
    @actions = Run::AvailableActions.new(run: @run, user: acting_user)
    return if @run.details_pruned_at

    @result_tasks = @run.tasks.joins(:output_body).order(id: :desc).limit(5).to_a.reverse
    @attention_tasks = Run::AvailableActions.attention_tasks(runs: Run.writable_by(acting_user).where(id: @run.id))
      .order(:id).limit(5).to_a
  end
end
