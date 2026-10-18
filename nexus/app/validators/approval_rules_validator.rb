# The approval rule list's grammar, beside its bounded_json envelope: one
# evaluator (Executors::Rules) refuses at declaration exactly what it
# would not read at the stage, so no rule a profile or a shell accepts is
# a surprise at a tool row's start.
class ApprovalRulesValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    refusal = Executors::Rules.refusal(value)
    record.errors.add(attribute, refusal.code, key: refusal.key) if refusal
  end
end
