class Admin::SsoProvidersController < Admin::BaseController
  include SsoSettingsAudit
  include SsoCallbackAddress
  around_action :require_sso_admin_write, only: [:create, :update, :destroy]
  before_action :set_provider, only: [:show, :edit, :update, :destroy]

  def index
    @providers = Current.account.sso_providers.listed.to_a
    @counts = SsoConnection.where(sso_provider: @providers).group(:sso_provider_id).count
    uncovered = SsoProvider.uncovered_users(Current.account, sso_only: true)
    @uncovered_pagy, @uncovered = pagy(:offset, uncovered.includes(:identity).order(:display_name, :id), limit: 25)
    active = Current.account.users.active.where(kind: :human)
    @active_count = active.count
    @admin_count = active.where(role: %w[owner admin]).count
    @covered_admins = @admin_count - uncovered.where(role: %w[owner admin]).count
    if Current.account.sso_only?
      @password_count = active.joins(:identity).where(identities: { local_recovery_pending_at: nil })
        .where.not(identities: { password_digest: nil }).count
    end
    @policy_mode = Current.account.sso_only? ? "password_and_sso" : "sso_only"
    @policy_verified = Sso::Proof.valid?(session: Current.session, action: "sso_policy", target: @policy_mode)
    @proof_sources = SsoConnection.available.where(identity: Current.identity).includes(:sso_provider)
  end

  def new
    @provider = Current.account.sso_providers.build(protocol: "oidc")
    @authority_editable = true
  end

  def create
    fields = params.expect(sso_provider: [:name, :protocol, :issuer, *SsoProvider::CONFIG_FIELDS])
    @provider = Current.account.sso_providers.build(fields)
    if @provider.save
      audit_sso_setting(:create_provider, @provider.public_id, :saved)
      redirect_to admin_sso_provider_path(@provider), notice: t("sso.saved"), status: :see_other
    else
      audit_sso_setting(:create_provider, @provider.public_id, :refused, reason: @provider.errors.first.type)
      @authority_editable = true
      render :new, status: :unprocessable_entity
    end
  end

  def show
    @bindings = @provider.sso_connections.joins(identity: :user).group("users.status").count
    affected = @provider.uncovered_users_if_disabled.includes(:identity).order(:display_name, :id)
    @affected_pagy, @affected = pagy(:offset, affected, limit: 25)
    pending_group = @provider.pending_configuration&.required_group
    @group_migration_needed = pending_group.present? && pending_group != @provider.required_group && @affected_pagy.count.positive?
    @callback_url = sso_provider_callback_url(@provider)
    @testable = @callback_url.present? && @provider.test_candidate.ready_for_test?
    @last_enabled = Current.account.sso_only? && @provider.enabled? && Current.account.sso_providers.where(enabled: true).where.not(id: @provider.id).none?
  end

  def edit
    @form = @provider.test_candidate
    @authority_editable = @provider.draft_authority_editable?
  end

  def update
    fields = params.expect(sso_provider: [:name, :protocol, :issuer, :lock_version, *SsoProvider::CONFIG_FIELDS])
    if @provider.save_settings(fields.except(:lock_version), expected_version: Integer(fields[:lock_version], exception: false))
      audit_sso_setting(:update_provider, @provider.public_id, :saved)
      redirect_to admin_sso_provider_path(@provider), notice: t("sso.saved"), status: :see_other
    else
      audit_sso_setting(:update_provider, @provider.public_id, :refused, reason: @provider.errors.first.type)
      @form = @provider.test_candidate.dup
      @form.assign_attributes(fields.except(:lock_version, :client_secret))
      @authority_editable = @provider.draft_authority_editable?
      render :edit, status: :unprocessable_entity
    end
  end

  def destroy
    fields = params.permit(:confirmation, :lock_version)
    count = @provider.sso_connections.count
    if @provider.retire(confirmation: fields[:confirmation].to_s, expected_version: Integer(fields[:lock_version], exception: false))
      audit_sso_setting(:delete_provider, @provider.public_id, :deleted, connections: count)
      redirect_to admin_sso_providers_path, notice: t("sso.deleted"), status: :see_other
    else
      audit_sso_setting(:delete_provider, @provider.public_id, :refused, reason: @provider.errors.first.type, connections: count)
      redirect_to admin_sso_provider_path(@provider), alert: @provider.errors.full_messages.to_sentence, status: :see_other
    end
  end

  private

    def set_provider
      @provider = Current.account.sso_providers.find_by!(public_id: params[:id])
    end
end
