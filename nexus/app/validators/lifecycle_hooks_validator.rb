class LifecycleHooksValidator < ActiveModel::EachValidator
  def validate_each(record, attribute, value)
    record.errors.add(attribute, :invalid) unless Nexus::LifecycleHooks.well_formed?(value)
  end
end
