class DelegationCatalogValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    names = value.map(&:name)
    record.errors.add(attribute, :invalid) if names.uniq.length != names.length
  end
end
