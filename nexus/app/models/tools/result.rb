module Tools
  Result = Data.define(:definitions, :environment, :refusal) do
    def initialize(definitions: [], environment: nil, refusal: nil) = super

    def accepted? = refusal.nil?
    def refused? = !accepted?
  end
end
