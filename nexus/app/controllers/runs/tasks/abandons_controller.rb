class Runs::Tasks::AbandonsController < Runs::BaseController
  def create
    adjudicate(Runs::Tasks::Abandon)
  end
end
