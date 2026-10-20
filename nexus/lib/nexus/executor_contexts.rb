module Nexus
  # Opaque application values, indexed by concrete executor identity. Paths and
  # all other payload semantics belong to their executor implementation.
  module ExecutorContexts
    module_function

    def normalize(value) = value.transform_keys { |key| key.to_s.downcase }

    def valid?(value)
      fields = Hash.try_convert(value)
      fields && fields.keys.map { |key| key.to_s.downcase }.uniq.length == fields.length && fields.all? { |id, context| ToolRoute::UUID.match?(id.to_s) && Hash.try_convert(context) } &&
        SizeBounds.json_within?(:snapshot_bound, fields)
    end
  end
end
