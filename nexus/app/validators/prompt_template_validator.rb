# The assembly template's grammar (PromptTemplate),
# the refusal named at its JSON-pointer path — the compaction policy's
# precedent, one level deeper.
class PromptTemplateValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    refusal = PromptTemplate.refusal(value)
    return if refusal.nil?

    record.errors.add(attribute, :invalid_template, path: refusal.path, detail: refusal.detail)
  end
end
