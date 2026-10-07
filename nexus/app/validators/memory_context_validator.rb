class MemoryContextValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    return if value.nil?

    unless MemoryContext.from_h(value).valid?
      record.errors.add(attribute, :invalid)
    end
  rescue NoMethodError, KeyError, TypeError, ArgumentError
    record.errors.add(attribute, :invalid)
  end
end
