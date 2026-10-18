# Maps the connection form onto the complete provider declaration. Fields the
# browser does not expose keep their authored values.
class Admin::ModelProviders::DefinitionForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  attribute :provider_id, :string
  attribute :display_name, :string
  attribute :api_format, :string, default: "openai_compatible_chat"
  attribute :base_url, :string
  attribute :credentials, :string, default: "api_key"
  attribute :concurrency_limit, :string
  attribute :expected_lock_version, :string

  validates :provider_id, :base_url, :api_format, :credentials, presence: true
  validates :concurrency_limit, numericality: { only_integer: true, greater_than: 0 }, allow_blank: true

  def initialize(provider_id:, definition: {}, lock_version: nil, attributes: {})
    @definition = definition.deep_dup
    super(definition.slice("display_name", "api_format", "base_url", "credentials", "concurrency_limit").merge(
      "provider_id" => provider_id, "expected_lock_version" => lock_version
    ).merge(attributes.to_h))
  end

  def definition
    @definition.deep_dup.tap do |value|
      %w[display_name api_format base_url credentials].each do |key|
        input = public_send(key).to_s.strip
        input.empty? ? value.delete(key) : value[key] = input
      end
      if concurrency_limit.present?
        value["concurrency_limit"] = Integer(concurrency_limit, 10)
      else
        value.delete("concurrency_limit")
      end
    end
  end
end
