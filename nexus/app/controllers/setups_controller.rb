class SetupsController < ApplicationController
  layout "public"

  allow_uninitialized_access only: %i[ show create ]
  allow_unauthenticated_access only: %i[ show create ]
  rate_limit to: 10, within: 3.minutes, only: :create, with: -> { redirect_to setup_path, alert: t("setups.create.rate_limited") }

  before_action :prevent_reinitialization
  before_action :authorize_setup_secret, only: :create

  helper_method :setup_secret_required?

  def show
    @setup = Setup.new
  end

  def create
    @setup = Setup.new(setup_params)

    if (account = @setup.establish)
      # Session issuance is deliberately outside the founding transaction:
      # if it fails, the Account stays initialized and the owner signs in
      # normally.
      start_new_session_for(account.owner.identity)
      redirect_to after_authentication_url, status: :see_other
    else
      render :show, status: :unprocessable_entity
    end
  end

  private

    def prevent_reinitialization
      redirect_to after_authentication_url if Account.exists?
    end

    # Deployment-configured shared secret, constant-time compared.
    # A miss re-renders with the typed non-secret values preserved, never
    # echoing the secret itself.
    def authorize_setup_secret
      configured = ENV["NEXUS_SETUP_SECRET"]

      if configured.present? && !ActiveSupport::SecurityUtils.secure_compare(params[:setup_secret].to_s, configured)
        @setup = Setup.new(setup_params)
        flash.now[:alert] = t("setups.create.invalid_setup_secret")
        render :show, status: :unprocessable_entity
      end
    end

    def setup_secret_required?
      ENV["NEXUS_SETUP_SECRET"].present?
    end

    def setup_params
      params.expect(setup: [:account_name, :cost_unit, :display_name, :email, :password, :password_confirmation])
    end
end
