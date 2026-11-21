class SsoProvider < ApplicationRecord
  include PublicIdentified
  include Management

  CONFIG_FIELDS = Configuration.attribute_types.keys.freeze
  SUBJECT_AUTHORITY_FIELDS = %w[client_id authorization_endpoint token_endpoint userinfo_endpoint subject_field].freeze

  belongs_to :account
  has_many :sso_attempts
  has_many :sso_connections, dependent: :delete_all, inverse_of: :sso_provider
  attr_readonly :account_id, :public_id
  attribute :public_id, default: -> { SecureRandom.uuid_v7 }
  attribute :pending_configuration, Configuration.to_type
  encrypts :pending_configuration
  encrypts :client_secret

  normalizes :required_group, with: ->(group) { group.strip.presence }
  normalizes :name, with: ->(name) { name.strip }
  validates :name, presence: true, length: { maximum: 100 }
  validates :protocol, inclusion: { in: %w[oidc oauth2] }
  validates :issuer, presence: true, uniqueness: { scope: :account_id }, length: { maximum: 1024 }
  validates :client_id, :scopes, :required_group, :subject_field, :email_field,
    :email_verified_field, :name_field, length: { maximum: 255 }
  validates :client_secret, length: { maximum: 4096 }
  validates :token_auth_method, inclusion: { in: %w[client_secret_basic client_secret_post] }
  validates :subject_field, presence: true, if: -> { protocol == "oauth2" }
  validate :endpoint_configuration
  validate :admission_configuration
  validate :preserve_identity_authority, on: :update
  scope :listed, -> { order(:name, :id) }

  def draft_authority_editable?
    !enabled? && !tested_at? && admission_version.zero? && !sso_connections.exists?
  end

  def ready_for_test?
    client_id.present? && client_secret.present? &&
      (protocol == "oidc" || [authorization_endpoint, token_endpoint, userinfo_endpoint].all?(&:present?))
  end

  private

    def preserve_identity_authority
      authority_fields = ["protocol", "issuer", *SUBJECT_AUTHORITY_FIELDS]
      if (changed_attribute_names_to_save & authority_fields).any? && !draft_authority_editable?
        errors.add(:base, :immutable_authority)
      end
    end

    def endpoint_configuration
      %i[issuer authorization_endpoint token_endpoint userinfo_endpoint].each do |attribute|
        value = public_send(attribute)
        next if value.blank?

        unless valid_url?(value, issuer: attribute == :issuer)
          errors.add(attribute, :invalid)
        end
      end
      origins = trusted_origins.to_s.split
      if origins.size > 12 || origins.any? { |value| !valid_url?(value, origin: true) }
        errors.add(:trusted_origins, :invalid)
      end
      if protocol == "oidc" && !scopes.to_s.split.include?("openid")
        errors.add(:scopes, :openid_required)
      end
    end

    def valid_url?(value, issuer: false, origin: false)
      return false if value.bytesize > 2048

      uri = URI.parse(value)
      schemes = Rails.env.local? ? %w[http https] : %w[https]
      schemes.include?(uri.scheme) && uri.host.present? && uri.port.between?(1, 65_535) &&
        !uri.userinfo && !uri.fragment && (!(issuer || origin) || !uri.query) &&
        (!origin || uri.path.empty?)
    rescue URI::InvalidURIError, URI::InvalidComponentError
      false
    end

    def admission_configuration
      if required_group.present? && protocol != "oidc"
        errors.add(:required_group, :oidc_required)
      end
      if jit? && required_group.blank? && URI.parse(issuer.to_s).host.to_s.downcase == "gitlab.com"
        errors.add(:required_group, :gitlab_group_required)
      end
    rescue URI::InvalidURIError
      # endpoint_configuration reports the invalid issuer.
    end
end
