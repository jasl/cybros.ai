# @auth [PlatformBearer, BrowserSession]
class API::V1::Admin::Accounts::RetentionsController < API::V1::Admin::BaseController
  # @oas_include
  # @summary Read retentions
  # @tags Platform, retentions
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminAccountsRetentionsShow
  def show
    render_retention
  end

  # @oas_include
  # @summary Update retentions
  # @tags Platform, retentions
  # @request_body_ref #/components/requestBodies/ApiV1AdminAccountsRetentionsUpdate
  # @response_ref (400) #/components/responses/APIError
  # @response_ref (401) #/components/responses/APIError
  # @response_ref (403) #/components/responses/APIError
  # @response_ref (404) #/components/responses/APIError
  # @response_ref (409) #/components/responses/APIError
  # @response_ref (413) #/components/responses/APIError
  # @response_ref (422) #/components/responses/APIError
  # @response_ref (429) #/components/responses/APIError
  # @response_ref (500) #/components/responses/ServerError
  # @response_ref (200) #/components/responses/ApiV1AdminAccountsRetentionsUpdate
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
