class Agents::WorkReportsController < Agents::BaseController
  def show
    @agent = agent
    now = Time.current
    @analysis = WorkReports::Analysis.call(user: Current.user, agent: @agent,
      from: now - 7.days, to: now).report
  end
end
