module Sso
  class RecoveriesController < ApplicationController
    include CapabilityPageResponse
    layout "public"
    require_unauthenticated_access only: :show

    def show
      @token = params.permit(:token)[:token].to_s
      authorization = MemberRecoveryAuthorization.find_by_secret(@token)
      if authorization&.sso_connection? && authorization.consumable?
        @providers = authorization.account.sso_providers.where(enabled: true).order(:name)
      else
        head :not_found
      end
    end
  end
end
