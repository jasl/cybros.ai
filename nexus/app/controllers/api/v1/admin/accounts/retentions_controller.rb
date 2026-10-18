class API::V1::Admin::Accounts::RetentionsController < API::V1::Admin::BaseController
  def show
    render_retention
  end

  def update
    fields = params.expect(account: [:execution_details_retention_days])
    account = Current.account

    if account.update(fields)
      render_retention
    else
      render_error(:validation_failed, account.errors.full_messages.to_sentence, status: :unprocessable_entity)
    end
  end

  private

    def render_retention
      render json: { account: { execution_details_retention_days: Current.account.execution_details_retention_days } }
    end
end
