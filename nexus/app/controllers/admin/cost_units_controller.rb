class Admin::CostUnitsController < Admin::BaseController
  before_action :no_store
  before_action :set_account

  def show
  end

  def update
    fields = params.expect(account: [:cost_unit])
    @cost_unit_input = fields[:cost_unit].to_s
    result = Accounts::ConfigureCostUnit.call(account: @account, cost_unit: @cost_unit_input)
    if result.configured? || result.already_configured?
      redirect_to admin_cost_unit_path, notice: t("admin.cost_units.updated"), status: :see_other
    else
      @account.reload
      flash.now[:alert] = t("admin.cost_units.#{result.conflict? ? :conflict : :invalid}")
      render :show, status: result.conflict? ? :conflict : :unprocessable_entity
    end
  end

  private

    def set_account
      @account = Current.account
      @cost_unit_input = @account.cost_unit
    end
end
