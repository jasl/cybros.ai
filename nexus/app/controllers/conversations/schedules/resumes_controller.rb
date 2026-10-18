class Conversations::Schedules::ResumesController < Conversations::Schedules::BaseController
  def create = transition(:resume)
end
