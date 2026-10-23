# Author selection and execution capture share one codec. A capture fixes
# kernel identity without changing whether the author selected a scope or UUID.
class MemoryContext < Data.define(:bindings, :automatic)
  def initialize(automatic: false, **) = super

  MAX_BINDINGS = 16
  NAME = /\A[a-z][a-z0-9_-]{0,31}\z/
  UUID = /\A\h{8}-\h{4}-\h{4}-\h{4}-\h{12}\z/
  SCOPES = %i[conversation workspace user agent speaker].freeze
  DEFAULT_SCOPES = %i[conversation workspace agent speaker].freeze

  Capture = Data.define(:collection_public_id, :owner_public_id, :scope, :speaker_public_id) do
    def self.from_h(value)
      new(collection_public_id: value.fetch("collection_public_id"), owner_public_id: value.fetch("owner_public_id"),
        scope: value.fetch("scope").to_sym, speaker_public_id: value["speaker_public_id"])
    end

    def to_h = super.transform_values { |value| value&.to_s }.stringify_keys
  end

  Binding = Data.define(:name, :scope, :access, :conversation_public_id, :speaker_public_id, :collection_public_id, :capture) do
    def initialize(conversation_public_id: nil, speaker_public_id: nil, collection_public_id: nil, capture: nil, scope: nil, **) = super

    def self.from_h(value)
      source = value.fetch("source")
      new(name: value.fetch("name").to_s, scope: source["scope"]&.to_sym,
        access: value.fetch("access").to_s.to_sym, conversation_public_id: source["conversation_public_id"],
        speaker_public_id: source["speaker_public_id"], collection_public_id: source["collection_public_id"],
        capture: (Capture.from_h(value["capture"]) if value["capture"]))
    end

    def valid?
      name.match?(NAME) && %i[read read_write].include?(access) &&
        (collection_public_id ? scope.nil? && collection_public_id.match?(UUID) && conversation_public_id.nil? && speaker_public_id.nil? :
          SCOPES.include?(scope) && (!SCOPES.include?(name.to_sym) || name.to_sym == scope)) &&
        (conversation_public_id.nil? || (scope == :conversation && conversation_public_id.match?(UUID))) &&
        (speaker_public_id.nil? || (scope == :speaker && speaker_public_id.match?(UUID)))
    end

    def to_h
      source = if collection_public_id
        { "collection_public_id" => collection_public_id }
      else
        { "scope" => scope.to_s, "conversation_public_id" => conversation_public_id,
          "speaker_public_id" => speaker_public_id }.compact
      end
      { "name" => name, "access" => access.to_s, "source" => source,
        "capture" => capture&.to_h }.compact
    end

    def natural_scope
      capture&.scope || scope || MemoryCollection.find_by(public_id: collection_public_id)&.natural_scope
    end
  end

  def self.from_h(value)
    fields = value.to_h
    raise ArgumentError, "memory context requires bindings" unless (fields.keys - %w[bindings automatic]).empty? && fields.key?("bindings")

    entries = fields.fetch("bindings").to_ary
    raise ArgumentError, "too many memory bindings" if entries.length > MAX_BINDINGS

    new(bindings: entries.map { |binding| Binding.from_h(binding) }, automatic: fields["automatic"] == true)
  end

  def self.capture(configuration:, speaker:)
    selected = configuration.nil? ? DEFAULT : from_h(configuration)
    new(automatic: selected.automatic, bindings: selected.bindings.map do |binding|
      if binding.scope == :speaker && binding.speaker_public_id.nil?
        binding.with(speaker_public_id: speaker&.public_id)
      else
        binding
      end
    end).to_h
  end

  def self.inherit(configuration:, source:, conversation_public_id:)
    selected = configuration.nil? ? DEFAULT : from_h(configuration)
    inherited = from_h(source).bindings.group_by(&:natural_scope)
    new(automatic: selected.automatic, bindings: selected.bindings.filter_map do |binding|
      candidates = inherited.fetch(binding.natural_scope, [])
      if binding.collection_public_id
        candidates = candidates.select { |entry| entry.collection_public_id == binding.collection_public_id }
      elsif binding.scope == :conversation
        public_id = binding.conversation_public_id == conversation_public_id ? nil : binding.conversation_public_id
        candidates = candidates.select { |entry| entry.collection_public_id.nil? && entry.conversation_public_id == public_id }
      elsif binding.scope == :speaker
        subject = candidates.find { |entry| entry.name == binding.name } || candidates.find { |entry| entry.name == "speaker" }
        next unless subject

        binding = binding.with(speaker_public_id: subject.speaker_public_id)
        candidates = candidates.select { |entry| entry.collection_public_id.nil? && entry.speaker_public_id == subject.speaker_public_id }
      else
        candidates = candidates.reject(&:collection_public_id)
      end
      next if candidates.empty?

      access = binding.access == :read || candidates.none? { |entry| entry.access == :read_write } ? :read : :read_write
      binding.with(access: access, capture: nil)
    end).to_h
  end

  def self.constrain(configuration:, limit:, conversation_public_id: nil)
    return configuration if limit.nil?

    selected = configuration.nil? ? DEFAULT : from_h(configuration)
    ceiling = from_h(limit).bindings.index_by(&:scope)
    new(automatic: selected.automatic, bindings: selected.bindings.filter_map do |binding|
      scope = binding.natural_scope
      allowed = ceiling[scope]
      next unless allowed
      if scope == :conversation
        target = binding.capture&.owner_public_id || binding.conversation_public_id
        target ||= MemoryCollection.find_by(public_id: binding.collection_public_id)&.conversation&.public_id if binding.collection_public_id
        next if target && target != conversation_public_id
      end
      access = binding.access == :read || allowed.access == :read ? :read : :read_write
      binding.with(access: access)
    end).to_h
  end

  def to_h = { "bindings" => bindings.map(&:to_h), "automatic" => (true if automatic) }.compact

  def valid?
    bindings.length <= MAX_BINDINGS && bindings.map(&:name).uniq.length == bindings.length && bindings.all?(&:valid?)
  end

  def natural_roots?
    bindings.all? { |binding| binding.name == binding.scope.to_s && binding.conversation_public_id.nil? && binding.speaker_public_id.nil? && binding.collection_public_id.nil? && binding.capture.nil? }
  end

  def default_roots?
    bindings.map { |binding| binding.with(speaker_public_id: nil, capture: nil) } == DEFAULT.bindings
  end
end
MemoryContext::DEFAULT = MemoryContext.new(automatic: true, bindings: MemoryContext::DEFAULT_SCOPES.map do |scope|
  MemoryContext::Binding.new(name: scope.to_s, scope: scope, access: :read_write)
end.freeze)
