class Admin::RetentionsController < Admin::BaseController
  def show
    @account = Current.account
  end

  def update
    @account = Current.account
    fields = params.expect(account: [:execution_details_retention_days])

    if @account.update(fields)
      redirect_to admin_retention_path, notice: t("admin.retentions.updated")
    else
      render :show, status: :unprocessable_entity
    end
  end
end
