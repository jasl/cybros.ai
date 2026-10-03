# The only database catalog overlay: one row per (Account, lane), retained as
# the lane's lock anchor; `model_overrides` is a bounded document of `upsert`
# and `remove` entries plus independent hidden model refs. The reader validates
# and warns on the document; an optional provider definition replaces file facts.
class ModelProviderPolicy < ApplicationRecord
  OVERRIDES_SCHEMA_VERSION = "cybros.model_provider_overrides.v1".freeze
  MAX_OVERRIDE_REFS = 256
  MAX_OVERRIDES_BYTES = 2 * 1024 * 1024
  # THE DOCUMENT GRAMMAR, spelled once: the reader (`ModelCatalog::PolicyOverlay`)
  # closes the same document and entry key sets this validation closes.
  DOCUMENT_KEYS = %w[schema_version entries hidden_models].freeze
  ENTRY_OPS = %w[upsert remove].freeze
  ENTRY_KEYS = %w[op model].freeze
  PROVIDER_ID_MAX_LENGTH = Nexus::ProviderDefinition::MAX_ID_LENGTH

  belongs_to :account
  attr_readonly :account_id, :provider_id

  validates :provider_id, presence: true, length: { maximum: PROVIDER_ID_MAX_LENGTH }
  validate :overrides_document_is_bounded_and_closed
  validate :provider_definition_is_bounded_and_closed

  def self.empty_overrides
    { "schema_version" => OVERRIDES_SCHEMA_VERSION, "entries" => {} }
  end

  # Normalize-and-trust: garbage refs simply fail the lane-prefix test.
  def self.provider_lane_ref?(provider_id, ref)
    ref.to_s.start_with?("#{provider_id}/")
  end

  def self.valid_document_shape?(document, provider_id:)
    document = Hash.try_convert(document)
    return false if document.nil? || (document.keys - DOCUMENT_KEYS).any?
    return false unless document["schema_version"] == OVERRIDES_SCHEMA_VERSION

    entries = Hash.try_convert(document["entries"])
    hidden = Array.try_convert(document.fetch("hidden_models", []))
    return false if entries.nil? || hidden.nil?
    return false unless valid_hidden_models?(hidden, provider_id: provider_id)
    return false if (entries.keys | hidden).length > MAX_OVERRIDE_REFS

    Nexus::CanonicalJson.bytesize(document) <= MAX_OVERRIDES_BYTES
  rescue ArgumentError, JSON::GeneratorError
    false
  end

  def self.valid_hidden_models?(hidden, provider_id:)
    hidden.uniq == hidden && hidden.all? { |ref|
      Nexus::ModelRef.parse(ref).complete? && provider_lane_ref?(provider_id, ref)
    }
  end

  def set_model_visibility(ref, visible:)
    hidden = model_overrides.fetch("hidden_models", [])
    hidden = visible ? hidden - [ref] : (hidden | [ref]).sort
    self.model_overrides = if hidden.empty?
      model_overrides.except("hidden_models")
    else
      model_overrides.merge("hidden_models" => hidden)
    end
  end

  def put_entry(ref, entry)
    self.model_overrides = model_overrides.merge("entries" => override_entries.merge(ref => entry))
  end

  def delete_entry(ref)
    self.model_overrides = model_overrides.merge("entries" => override_entries.except(ref))
  end

  def override_entries
    case model_overrides
    when Hash then model_overrides.fetch("entries", {})
    else {}
    end
  end

  private

  def provider_definition_is_bounded_and_closed
    return if provider_definition.nil?

    self.provider_definition = Nexus::ProviderDefinition.normalize(provider_definition, provider_id: provider_id)
  rescue Nexus::ProviderDefinition::Invalid, ArgumentError, JSON::GeneratorError => error
    errors.add(:provider_definition, error.message)
  end

  def overrides_document_is_bounded_and_closed
    document = model_overrides
    case document
    when Hash then nil
    else return errors.add(:model_overrides, :not_a_mapping)
    end

    unless document["schema_version"] == OVERRIDES_SCHEMA_VERSION
      return errors.add(:model_overrides, :schema_version, version: OVERRIDES_SCHEMA_VERSION)
    end
    unknown = document.keys - DOCUMENT_KEYS
    return errors.add(:model_overrides, :unknown_keys, keys: unknown.sort.join(", ")) unless unknown.empty?

    entries = document.fetch("entries", nil)
    case entries
    when Hash then nil
    else return errors.add(:model_overrides, :entries_not_a_mapping)
    end

    if entries.length > MAX_OVERRIDE_REFS
      errors.add(:model_overrides, :too_many_refs, limit: MAX_OVERRIDE_REFS)
    end
    bytesize = begin
      Nexus::CanonicalJson.bytesize(document)
    rescue ArgumentError, JSON::GeneratorError
      return errors.add(:model_overrides, :not_canonical)
    end
    if bytesize > MAX_OVERRIDES_BYTES
      errors.add(:model_overrides, :too_many_bytes, limit: MAX_OVERRIDES_BYTES)
    end

    entries.each { |ref, entry| validate_entry(ref, entry) }
    hidden = Array.try_convert(document.fetch("hidden_models", []))
    unless hidden && self.class.valid_hidden_models?(hidden, provider_id: provider_id)
      return errors.add(:model_overrides, :invalid_hidden_models)
    end
    if (entries.keys | hidden).length > MAX_OVERRIDE_REFS
      errors.add(:model_overrides, :too_many_refs, limit: MAX_OVERRIDE_REFS)
    end
  end

  def validate_entry(ref, entry)
    unless self.class.provider_lane_ref?(provider_id, ref)
      errors.add(:model_overrides, :entry_outside_lane, ref: ref.inspect)
    end

    case entry
    when Hash then nil
    else return errors.add(:model_overrides, :entry_not_a_mapping, ref: ref.inspect)
    end

    unknown = entry.keys - ENTRY_KEYS
    errors.add(:model_overrides, :entry_unknown_keys, ref: ref.inspect) unless unknown.empty?

    case entry["op"]
    when "upsert"
      case entry["model"]
      when Hash then nil
      else errors.add(:model_overrides, :entry_upsert_without_model, ref: ref.inspect)
      end
    when "remove"
      errors.add(:model_overrides, :entry_remove_with_payload, ref: ref.inspect) if entry.key?("model")
    else
      errors.add(:model_overrides, :entry_unknown_op, ref: ref.inspect, ops: ENTRY_OPS.join(", "))
    end
  end
end
