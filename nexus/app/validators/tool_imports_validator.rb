class ToolImportsValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    refusal = Nexus::ToolImports.field_refusal(field: attribute, value: value)
    record.errors.add(attribute, refusal) if refusal
  end
end
