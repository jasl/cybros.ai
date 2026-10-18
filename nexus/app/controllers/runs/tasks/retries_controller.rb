class Runs::Tasks::RetriesController < Runs::BaseController
  def create
    adjudicate(Runs::Tasks::Retry)
  end
end
