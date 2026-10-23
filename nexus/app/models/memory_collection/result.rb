class MemoryCollection
  Result = Data.define(:outcome, :collection, :errors) do
    def self.accepted(collection) = new(outcome: :accepted, collection: collection, errors: nil)
    def self.refused(code) = new(outcome: code, collection: nil, errors: nil)
    def self.invalid(collection) = new(outcome: :invalid, collection: collection, errors: collection.errors)
    def accepted? = outcome == :accepted
  end
end
