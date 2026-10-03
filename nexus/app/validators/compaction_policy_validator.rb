# The compaction policy's shape, the same one the task compiler accepts.
class CompactionPolicyValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    record.errors.add(attribute, :invalid) unless Nexus::CompactionPolicy.well_formed?(value)
  end
end
