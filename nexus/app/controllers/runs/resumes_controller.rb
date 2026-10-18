class Runs::ResumesController < Runs::BaseController
  def create
    lifecycle(Runs::Resume)
  end
end
