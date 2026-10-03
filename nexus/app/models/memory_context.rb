# A database-backed memory context is an ordered set of logical path bindings.
# Persisted JSON is decoded once; internal readers share these closed values.
class MemoryContext < Data.define(:bindings)
  MAX_BINDINGS = 16
  NAME = /\A[a-z][a-z0-9_-]{0,31}\z/
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  SCOPES = %i[conversation workspace user].freeze

  Binding = Data.define(:name, :scope, :access, :conversation_public_id) do
    def self.from_h(value)
      raise ArgumentError, "unknown memory binding fields" unless
        (value.keys - %w[name scope access conversation_public_id]).empty?

      new(name: value.fetch("name").to_s, scope: value.fetch("scope").to_s.to_sym,
        access: value.fetch("access").to_s.to_sym, conversation_public_id: value["conversation_public_id"]&.to_s)
    end

    def valid?
      name.match?(MemoryContext::NAME) && MemoryContext::SCOPES.include?(scope) &&
        %i[read read_write].include?(access) &&
        (!MemoryContext::SCOPES.include?(name.to_sym) || name.to_sym == scope) &&
        (conversation_public_id.nil? || (scope == :conversation && name != "conversation" &&
          conversation_public_id.match?(MemoryContext::UUID)))
    end
  end

  def self.from_h(value)
    fields = value.to_h
    raise ArgumentError, "memory context requires bindings" unless fields.keys == ["bindings"]

    entries = fields.fetch("bindings").to_ary
    raise ArgumentError, "too many memory bindings" if entries.length > MAX_BINDINGS

    new(bindings: entries.map { |binding| Binding.from_h(binding) })
  end

  def valid?
    bindings.length <= self.class::MAX_BINDINGS && bindings.map(&:name).uniq.length == bindings.length &&
      bindings.all?(&:valid?) && (bindings.empty? || bindings.any? do |binding|
        binding.name == "conversation" && binding.scope == :conversation && binding.conversation_public_id.nil?
      end)
  end
end
MemoryContext::DEFAULT = MemoryContext.new(bindings: MemoryContext::SCOPES.map do |scope|
  MemoryContext::Binding.new(name: scope.to_s, scope: scope, access: :read_write, conversation_public_id: nil)
end.freeze)
