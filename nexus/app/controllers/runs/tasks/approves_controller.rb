class Runs::Tasks::ApprovesController < Runs::BaseController
  def create
    adjudicate(Runs::Tasks::Approve)
  end
end
