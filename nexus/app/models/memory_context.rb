# A database-backed memory context is an ordered set of logical path bindings.
# Persisted JSON is decoded once; internal readers share these closed values.
# Defaults are conversation, workspace, Agent-private and Agent-plus-Speaker
# memory. Human-owned user documents remain an explicit scope. Speaker UUIDs
# select the subject; the answering Agent supplies that memory's owner.
class MemoryContext < Data.define(:bindings)
  MAX_BINDINGS = 16
  NAME = /\A[a-z][a-z0-9_-]{0,31}\z/
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  SCOPES = %i[conversation workspace user agent speaker].freeze
  DEFAULT_SCOPES = %i[conversation workspace agent speaker].freeze

  Binding = Data.define(:name, :scope, :access, :conversation_public_id, :speaker_public_id) do
    def initialize(conversation_public_id: nil, speaker_public_id: nil, **) = super
    def self.from_h(value)
      raise ArgumentError, "unknown memory binding fields" unless
        (value.keys - %w[name scope access conversation_public_id speaker_public_id]).empty?

      new(name: value.fetch("name").to_s, scope: value.fetch("scope").to_s.to_sym,
        access: value.fetch("access").to_s.to_sym, conversation_public_id: value["conversation_public_id"]&.to_s,
        speaker_public_id: value["speaker_public_id"]&.to_s)
    end

    def valid?
      name.match?(MemoryContext::NAME) && MemoryContext::SCOPES.include?(scope) &&
        %i[read read_write].include?(access) &&
        (!MemoryContext::SCOPES.include?(name.to_sym) || name.to_sym == scope) &&
        (conversation_public_id.nil? || (scope == :conversation && name != "conversation" &&
          conversation_public_id.match?(MemoryContext::UUID))) &&
        (speaker_public_id.nil? || (scope == :speaker && speaker_public_id.match?(MemoryContext::UUID)))
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

  def natural_roots?
    bindings.all? { |binding| binding.name == binding.scope.to_s && binding.conversation_public_id.nil? && binding.speaker_public_id.nil? }
  end

  def default_roots?
    bindings.map { |binding| binding.with(speaker_public_id: nil) } == self.class::DEFAULT.bindings
  end

  def self.capture(configuration:, speaker:)
    selected = configuration.nil? ? DEFAULT : from_h(configuration)
    { "bindings" => selected.bindings.map do |binding|
      binding = binding.with(speaker_public_id: speaker&.public_id) if binding.scope == :speaker && binding.speaker_public_id.nil?
      binding.to_h.transform_values { |value| value&.to_s }.compact.stringify_keys
    end }
  end

  # Delivery intersects actual anchors, unlike a profile's scope-only limit.
  # Relative conversation roots follow the receiver; explicit aliases keep
  # their UUID. A Speaker alias carries its own subject and that subject's
  # access ceiling, never another subject's write permission.
  def self.inherit(configuration:, source:, conversation_public_id:)
    selected = configuration.nil? ? DEFAULT : from_h(configuration)
    inherited = from_h(source).bindings.group_by(&:scope)
    { "bindings" => selected.bindings.filter_map do |binding|
      candidates = inherited.fetch(binding.scope, [])
      if binding.scope == :conversation
        public_id = binding.conversation_public_id == conversation_public_id ? nil : binding.conversation_public_id
        candidates = candidates.select { |entry| entry.conversation_public_id == public_id }
      elsif binding.scope == :speaker
        subject = candidates.find { |entry| entry.name == binding.name } ||
          candidates.find { |entry| entry.name == "speaker" } ||
          (candidates.first if candidates.map(&:speaker_public_id).uniq.one?)
        next unless subject

        binding = binding.with(speaker_public_id: subject.speaker_public_id)
        candidates = candidates.select { |entry| entry.speaker_public_id == subject.speaker_public_id }
      end
      next if candidates.empty?

      access = binding.access == :read || candidates.none? { |entry| entry.access == :read_write } ? :read : :read_write
      binding.with(access: access).to_h.transform_values { |value| value&.to_s }.compact.stringify_keys
    end }
  end

  # A standing profile can only narrow the host's selected anchors. Relative
  # conversation bindings follow a spawned child; an alias to another room does
  # not become that child's own memory merely because its scope word matches.
  def self.constrain(configuration:, limit:, conversation_public_id: nil)
    return configuration if limit.nil?

    selected = configuration.nil? ? DEFAULT : from_h(configuration)
    ceiling = from_h(limit).bindings.index_by(&:scope)
    bindings = selected.bindings.filter_map do |binding|
      allowed = ceiling[binding.scope]
      next unless allowed
      if binding.scope == :conversation && binding.conversation_public_id &&
          binding.conversation_public_id != conversation_public_id
        next
      end

      access = binding.access == :read || allowed.access == :read ? :read : :read_write
      binding.with(access: access).to_h.transform_values { |value| value&.to_s }.compact
    end
    { "bindings" => bindings.map(&:stringify_keys) }
  end
end
MemoryContext::DEFAULT = MemoryContext.new(bindings: MemoryContext::DEFAULT_SCOPES.map do |scope|
  MemoryContext::Binding.new(name: scope.to_s, scope: scope, access: :read_write, conversation_public_id: nil)
end.freeze)
