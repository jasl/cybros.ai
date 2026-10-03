# Platform administration is Human-owned: a demoted AccessToken already
# died at authentication (401); an authenticated non-admin Human Session
# earns the honest 403 here.
class API::V1::Admin::BaseController < API::V1::BaseController
  before_action :require_administrator

  # THE ONE REFUSAL → STATUS MAP of the admin family. The member
  # lifecycle's symbols are the model's and the web console reads them
  # too, so this plane's wire words for them live here, once
  # (`REFUSAL_CODES`); the budget ledger's symbols likewise. Nothing
  # conceals: an absent member or budget is the finder's 404.
  ABSENCE_REFUSALS = [].freeze
  REFUSAL_CODES = {
    owner_protected: :installation_owner_protected,
    not_administrable: :user_not_administrable,
    not_authorized: :user_not_administrable,
    last_admin: :last_active_admin,
    not_active: :user_not_active,
    invalid: :validation_failed,
    unit_unconfigured: :account_unit_unconfigured,
    overlap: :budget_window_overlap,
    starts_at_taken: :budget_window_overlap,
    insufficient_headroom: :budget_insufficient_headroom,
    already_revoked: :budget_already_revoked,
    conflict: :idempotency_envelope_mismatch,
    oauth_session_in_progress: :authorization_in_progress,
  }.freeze
  REFUSAL_STATUSES = {
    installation_owner_protected: :forbidden,
    user_not_administrable: :forbidden,
    installation_owner: :conflict,
    last_active_admin: :conflict,
    user_not_active: :conflict,
    workspace_ownership_transfer_required: :conflict,
    budget_window_overlap: :conflict,
    budget_insufficient_headroom: :conflict,
    budget_already_revoked: :conflict,
    material_kind_conflict: :conflict,
    authorization_in_progress: :conflict,
    authorization_not_supported: :conflict,
    provider_disabled: :conflict,
    # The report's window refusals are caller bugs worth hearing about — a
    # reject, never a clamp, exactly like the replay window's limit.
    unit_unsupported: :bad_request,
    filter_unsupported: :bad_request,
    filter_invalid: :bad_request,
    window_invalid: :bad_request,
    window_too_wide: :bad_request,
  }.freeze
  REFUSAL_DEFAULT_STATUS = :unprocessable_content
  REFUSAL_MESSAGES = {
    installation_owner: "Transfer installation ownership before removing this account",
    installation_owner_protected: "The installation owner cannot be removed",
    user_not_administrable: "This member cannot be administered",
    last_active_admin: "The last active administrator cannot be removed",
    user_not_active: "This member is already removed",
    workspace_ownership_transfer_required: "Transfer or delete this member's workspaces first",
    account_unit_unconfigured: "Configure the account cost unit before opening budgets",
    budget_window_overlap: "The window overlaps an existing usable budget",
    budget_insufficient_headroom: "The debit exceeds the budget's remaining headroom",
    budget_already_revoked: "This budget is already revoked",
    idempotency_envelope_mismatch: "This Idempotency-Key was used with a different request",
    material_kind_conflict: "This lane authenticates with something other than an api key",
    authorization_in_progress: "Another authorization is pending; explicitly restart to replace it",
    authorization_not_supported: "This provider has no subscription authorization flow",
    provider_disabled: "Enable this provider before starting authorization",
  }.freeze

  private

    def require_administrator
      user = Current.user
      unless user && user.human? && user.active? && user.admin?
        render_error(:administrator_required, "Administrator role required", status: :forbidden)
      end
    end

    # Strict ISO 8601 read in the app zone: a lenient cast would turn
    # "yesterday" into nil instead of a 400, and Time.iso8601 would read a
    # zone-less stamp in the process zone.
    def parse_time(value, name)
      Time.zone.iso8601(value.to_s)
    rescue ArgumentError
      raise APIErrors::ParameterInvalid, name
    end
end
