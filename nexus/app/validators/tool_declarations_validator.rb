# A declared tool set's shape and kernel-name rule, beside its bounded_json
# declaration bound. Profiles and model steps share this declaration grammar.
class ToolDeclarationsValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    if !Nexus::ToolDeclarations.entries?(value)
      record.errors.add(attribute, :invalid)
    elsif (refusal = Nexus::ToolDeclarations.refusal(value))
      record.errors.add(attribute, refusal.to_sym)
    end
  end
end
