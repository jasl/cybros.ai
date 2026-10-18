class Conversations::Schedules::PausesController < Conversations::Schedules::BaseController
  def create = transition(:pause)
end
