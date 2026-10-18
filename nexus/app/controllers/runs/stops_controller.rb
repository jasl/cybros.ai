class Runs::StopsController < Runs::BaseController
  def create
    lifecycle(Runs::Stop, force: true)
  end
end
