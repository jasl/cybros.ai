module Nexus
  # A catalog model reference, "provider/model", split once.
  ModelRef = Data.define(:provider_id, :model_ref) do
    def self.parse(ref)
      provider_id, model_ref = ref.to_s.split("/", 2)
      new(provider_id:, model_ref:)
    end

    def complete? = provider_id.present? && model_ref.present?

    def to_s = "#{provider_id}/#{model_ref}"
  end
end
