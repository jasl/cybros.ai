# The HTML form owns only its visible fields. Rebuilding from the full
# declaration preserves provider-specific reasoning and wire configuration.
class Admin::ModelProviders::ModelForm
  include ActiveModel::Model
  include ActiveModel::Attributes

  LIMIT_FIELDS = %w[input_tokens output_tokens combined_input_output_tokens effective_input_tokens].freeze
  BOOLEAN_FIELDS = %w[tool_calls streaming].freeze
  MEDIA_FIELDS = %w[image audio video file].freeze
  RATE_FIELDS = (
    ModelCatalog::PricingValidation::BASIC_TEXT_RATE_KEYS +
    ModelCatalog::PricingValidation::BASIC_TEXT_OPTIONAL_RATE_KEYS +
    ModelCatalog::PricingValidation::CACHED_TEXT_RATE_KEYS +
    ModelCatalog::PricingValidation::IMAGE_RATE_KEYS +
    ModelCatalog::PricingValidation::IMAGE_TOKEN_RATE_KEYS +
    ModelCatalog::PricingValidation::IMAGE_TOKEN_OPTIONAL_RATE_KEYS +
    ModelCatalog::PricingValidation::SPEECH_RATE_KEYS +
    ModelCatalog::PricingValidation::TRANSCRIPTION_RATE_KEYS
  ).uniq.freeze

  attribute :model, :string
  attribute :model_id, :string
  attribute :inherit, :string
  attribute :display_name, :string
  attribute :expected_lock_version, :string
  attribute :pricing_mode, :string, default: "none"
  attribute :pricing_unit, :string
  attribute :reset_limits, :boolean, default: false
  attribute :limits_edited, :boolean, default: false
  attribute :input_modalities_mode, :string, default: "inherit"
  attribute :input_modalities, default: -> { [] }
  LIMIT_FIELDS.each { |key| attribute key, :string }
  BOOLEAN_FIELDS.each { |key| attribute key, :string }
  RATE_FIELDS.each { |key| attribute key, :string }

  validates :model_id, presence: true
  validates(*LIMIT_FIELDS, numericality: { only_integer: true, greater_than: 0 }, allow_blank: true)
  validates(*BOOLEAN_FIELDS, inclusion: { in: %w[true false] }, allow_blank: true)
  validates :pricing_mode, inclusion: { in: %w[preserve none custom] }
  validates :input_modalities_mode, inclusion: { in: %w[inherit custom] }

  attr_reader :model_definitions

  def initialize(provider_id:, provider_definition:, definition: {}, model_definitions: {}, model: nil, lock_version: nil, cost_unit: nil, attributes: {})
    @provider_id = provider_id
    @model_definitions = model_definitions
    @definition = definition.deep_dup
    @format = definition["api_format"] || provider_definition.fetch("api_format")
    caps = definition.fetch("capabilities", {})
    pricing = definition["pricing"] || {}
    super({
      "model" => model, "model_id" => definition["model_id"] || model&.delete_prefix("#{provider_id}/"),
      "inherit" => definition["inherit"],
      "input_modalities_mode" => caps.key?("input_modalities") ? "custom" : "inherit",
      "input_modalities" => caps.fetch("input_modalities", []),
      "display_name" => definition["display_name"], "expected_lock_version" => lock_version,
      "pricing_mode" => pricing.empty? ? "none" : "preserve", "pricing_unit" => pricing["account_unit"] || cost_unit,
    }.merge(caps.slice(*BOOLEAN_FIELDS).transform_values(&:to_s)).merge(caps.fetch("limits", {}).slice(*LIMIT_FIELDS))
      .merge(pricing.dig("schedule", "rates") || {}).merge(attributes.to_h))
    self.input_modalities = input_modalities.reject { |kind| kind == "" }
  end

  def model_ref
    model.presence || "#{@provider_id}/#{model_id.to_s.strip}"
  end

  def inheritance_choices
    @model_definitions.sort.map { |name, definition| [definition["display_name"] || name, name] }
  end

  def original_limits
    @definition.fetch("capabilities", {}).fetch("limits", {})
  end

  def empty_limits_override?
    @definition.fetch("capabilities", {}).key?("limits") && original_limits.empty?
  end

  def rate_fields
    validation = ModelCatalog::PricingValidation
    case SimpleInference::ApiFormat.workload(@format)
    when "text_generation"
      if @format == "deepseek_responses"
        validation::CACHED_TEXT_RATE_KEYS
      else
        validation::BASIC_TEXT_RATE_KEYS + validation::BASIC_TEXT_OPTIONAL_RATE_KEYS
      end
    when "image_generation"
      existing = @definition.dig("pricing", "schedule", "rates") || {}
      if (existing.keys & validation::IMAGE_TOKEN_RATE_KEYS).any?
        validation::IMAGE_TOKEN_RATE_KEYS + validation::IMAGE_TOKEN_OPTIONAL_RATE_KEYS
      else
        validation::IMAGE_RATE_KEYS
      end
    when "speech_generation" then validation::SPEECH_RATE_KEYS
    when "transcription" then validation::TRANSCRIPTION_RATE_KEYS
    when "embedding" then validation::EMBEDDING_RATE_KEYS
    else raise ArgumentError, "unsupported pricing workload"
    end
  end

  def definition
    @definition.deep_dup.tap do |value|
      value["model_id"] = model_id.to_s.strip
      inherit.present? ? value["inherit"] = inherit.strip : value.delete("inherit")
      display_name.present? ? value["display_name"] = display_name.strip : value.delete("display_name")
      write_capabilities(value)
      write_pricing(value)
    end
  end

  private

    def write_capabilities(value)
      caps = value.fetch("capabilities", {}).deep_dup
      write_limits(caps)
      BOOLEAN_FIELDS.each do |key|
        input = public_send(key)
        input.present? ? caps[key] = input == "true" : caps.delete(key)
      end
      if input_modalities_mode == "custom"
        caps["input_modalities"] = input_modalities
      else
        caps.delete("input_modalities")
      end
      caps.empty? ? value.delete("capabilities") : value["capabilities"] = caps
    end

    def write_limits(caps)
      limits = reset_limits ? {} : original_limits.deep_dup
      LIMIT_FIELDS.each do |key|
        input = public_send(key)
        input.present? ? limits[key] = Integer(input, 10) : limits.delete(key)
      end
      # An authored empty block clears the complete inherited window. Only
      # an actual edit or the explicit reset should remove that saved choice.
      keep_empty = empty_limits_override? && !reset_limits && !limits_edited
      if limits.any? || keep_empty
        caps["limits"] = limits
      else
        caps.delete("limits")
      end
    end

    def write_pricing(value)
      case pricing_mode
      when "preserve" then nil
      when "none" then value.delete("pricing")
      when "custom"
        rates = rate_fields.each_with_object({}) do |key, result|
          input = public_send(key).to_s.strip
          result[key] = input unless input.empty?
        end
        schedule = value.dig("pricing", "schedule").to_h.except("kind", "rates")
        value["pricing"] = {
          "account_unit" => pricing_unit.to_s.strip,
          "schedule" => schedule.merge("kind" => "catalog_only", "rates" => rates),
        }
      else raise ArgumentError, "unsupported pricing choice"
      end
    end
end
