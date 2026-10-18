class Conversations::Schedules::CancelsController < Conversations::Schedules::BaseController
  def create = transition(:cancel)
end
