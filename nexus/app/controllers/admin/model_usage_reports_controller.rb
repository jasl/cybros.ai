class Admin::ModelUsageReportsController < Admin::BaseController
  def show
    now = Time.current
    @analysis = ModelUsageRollups::Analysis.call(account: Current.account, from: now - 7.days, to: now).report
  end
end
