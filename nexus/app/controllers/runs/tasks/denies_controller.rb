class Runs::Tasks::DeniesController < Runs::BaseController
  def create
    adjudicate(Runs::Tasks::Deny, reason: nil)
  end
end
