class Runs::PausesController < Runs::BaseController
  def create
    lifecycle(Runs::Pause, force: false)
  end
end
