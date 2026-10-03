# A declared tool set's shape and kernel-name rule, beside its bounded_json
# envelope; the rule is the task compiler's, so no declaration the profile
# accepts is refused at a round.
class ToolDeclarationsValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    if !Nexus::ToolDeclarations.entries?(value)
      record.errors.add(attribute, :invalid)
    elsif (refusal = Nexus::ToolDeclarations.refusal(value))
      record.errors.add(attribute, refusal.to_sym)
    end
  end
end
