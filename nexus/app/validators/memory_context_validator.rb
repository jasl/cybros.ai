class MemoryContextValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    return if value.nil?

    context = MemoryContext.from_h(value)
    unless context.valid? && (!options[:limit] || context.natural_roots?)
      record.errors.add(attribute, :invalid)
    end
  rescue NoMethodError, KeyError, TypeError, ArgumentError
    record.errors.add(attribute, :invalid)
  end
end
