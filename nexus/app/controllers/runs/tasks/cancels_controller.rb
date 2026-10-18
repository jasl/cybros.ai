class Runs::Tasks::CancelsController < Runs::BaseController
  def create
    adjudicate(Runs::CancelBranch, notice: "runs_console.branch_cancel_accepted")
  end
end
