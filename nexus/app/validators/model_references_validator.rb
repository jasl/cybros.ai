class ModelReferencesValidator < ActiveModel::EachValidator
  def self.valid_value?(value)
    references = Array.try_convert(value)
    references && Nexus::SizeBounds.json_within?(:envelope_bound, references) &&
      references.all? { |ref| ref.to_s.length <= 193 && Nexus::ModelRef.parse(ref).complete? }
  end

  def validate_each(record, attribute, value)
    errors = record.errors
    errors.add(attribute, :invalid) unless self.class.valid_value?(value)
  end
end
