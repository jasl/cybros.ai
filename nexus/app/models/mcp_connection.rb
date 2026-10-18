# A Human-owned external account. The target and authentication kind never move:
# changing services or accounts requires another connection.
class McpConnection < ApplicationRecord
  include PublicIdentified
  include Management
  include Authorization

  NAME_MAX_LENGTH = 100
  ACCOUNT_LABEL_MAX_LENGTH = 256
  TOKEN_MAX_LENGTH = 4096
  EFFECT_PROFILE = {
    "kind" => "write", "destructive" => true, "effect_scope" => "open",
    "idempotency" => "none", "reconciliation" => "none",
  }.freeze
  Result = Data.define(:outcome, :connection) do
    def success? = outcome == :saved
  end

  belongs_to :owner, class_name: "User", inverse_of: :mcp_connections
  belongs_to :account, default: -> { owner.account }

  attr_readonly :account_id, :owner_id, :public_id, :endpoint_url, :auth_type
  attribute :public_id, default: -> { SecureRandom.uuid_v7 }
  attribute :oauth_data, OAuthData.to_type
  encrypts :bearer_token
  encrypts :oauth_data

  normalizes :name, :account_label, with: ->(value) { value.strip }
  validates :name, presence: true, length: { maximum: NAME_MAX_LENGTH }
  validates :account_label, length: { maximum: ACCOUNT_LABEL_MAX_LENGTH }, allow_nil: true
  validates :auth_type, inclusion: { in: %w[none bearer oauth] }
  validates :enabled, inclusion: { in: [true, false] }
  validates :bearer_token, length: { maximum: TOKEN_MAX_LENGTH }, allow_nil: true,
    if: :will_save_change_to_bearer_token?
  validates :bearer_token, absence: true, if: -> { auth_type != "bearer" && will_save_change_to_bearer_token? }
  validates :oauth_data, store_model: true, allow_nil: true
  validates :catalog, bounded_json: { bound: :tool_definitions_bound, shape: Array }
  validate :owner_is_human
  validate :valid_endpoint
  validate :bearer_token_is_header_value, if: :will_save_change_to_bearer_token?

  scope :for_agent, ->(agent) { where(account_id: agent.account_id, owner_id: agent.steward_id) }

  def credential_configured?
    case auth_type
    when "none" then true
    when "bearer" then bearer_token_before_type_cast.present?
    when "oauth" then %w[authorized refreshing].include?(authorization_status)
    else false
    end
  end

  def usable_by?(agent)
    enabled? && credential_configured? && owner.active? &&
      agent.execution_principal_eligible? && agent.account_id == account_id &&
      agent.steward_id == owner_id
  end

  def tool_available?(agent:, name:)
    usable_by?(agent) && tools_catalog.any? { |tool| tool.fetch("name") == name }
  end

  def tools_catalog = catalog

  private

    def owner_is_human
      unless owner&.human? && owner.account_id == account_id
        errors.add(:owner, :invalid)
      end
    end

    def valid_endpoint
      Nexus::McpEndpoint.parse(endpoint_url)
    rescue Nexus::McpEndpoint::Invalid
      errors.add(:endpoint_url, :invalid)
    end

    def bearer_token_is_header_value
      if bearer_token && (bearer_token.blank? || bearer_token.match?(/[\r\n\0]/))
        errors.add(:bearer_token, :invalid)
      end
    end
end
