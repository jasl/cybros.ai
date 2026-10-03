# One accounting rule for every stored JSON payload (Nexus::SizeBounds):
# `bound:` names the registry entry, `shape:` is the object-ness a jsonb
# cast cannot enforce, and `allow_nil: true` skips an optional payload.
class BoundedJsonValidator < ActiveModel::EachValidator
  def check_validity!
    raise ArgumentError, "bounded_json needs a :bound naming a Nexus::SizeBounds entry" unless options.key?(:bound)
  end

  def validate_each(record, attribute, value)
    shape = options[:shape]
    if shape && !(shape === value)
      record.errors.add(attribute, :invalid)
    elsif !Nexus::SizeBounds.json_within?(options.fetch(:bound), value)
      record.errors.add(attribute, Nexus::SizeBounds::REJECTION)
    end
  # The encoder's contract is its PARENT class: the two leaves keep their
  # own words, and everything else it refuses — a non-JSON value, a
  # non-String key, a depth past the substrate's — is typed once here, never
  # a raised save.
  rescue Nexus::CanonicalJson::UnsupportedNumber
    record.errors.add(attribute, :unsupported_number)
  rescue Nexus::CanonicalJson::UnsupportedText
    record.errors.add(attribute, :unsupported_text)
  rescue Nexus::CanonicalJson::UnsupportedValue
    record.errors.add(attribute, :unsupported_value)
  end
end
