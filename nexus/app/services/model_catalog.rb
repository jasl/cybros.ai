# The catalog facade: one strict file base compiles into one immutable
# snapshot, and every consumer refuses with zero provider IO when none is
# current. `api_format` selects the protocol adapter.
module ModelCatalog
  class CompileError < StandardError; end

  # Raised when a consumer cannot read a booted snapshot or requests a
  # provider absent from it. Selection, quotes, admission, and provider starts
  # then stop before provider IO.
  class Unavailable < StandardError; end

  class << self
    attr_reader :runtime

    def boot(root: default_root, override_dir: default_override_dir)
      @runtime = Runtime.new(root: root, override_dir: override_dir).tap(&:boot)
    end

    # `MODEL_CATALOG_OVERRIDE_DIR` moves the operator overlay so a harness can
    # hand this process a catalog without writing into its checkout. A path,
    # not a policy: it compiles and fails closed exactly as `config.d` does.
    def default_override_dir
      from_env = ENV["MODEL_CATALOG_OVERRIDE_DIR"].to_s
      return Rails.root.join("config.d") if from_env.strip.empty?

      Pathname.new(from_env)
    end

    def current = require_runtime.current
    def ready? = @runtime ? @runtime.ready? : false

    # Read at send time, never frozen into the selection, so a moved
    # endpoint moves for work already queued.
    def provider_base_url(provider_id, snapshot: current)
      provider_declaration(provider_id, snapshot: snapshot).fetch("base_url")
    end

    def model_base_url(model_ref, snapshot: current)
      provider_id = Nexus::ModelRef.parse(model_ref).provider_id
      entry = snapshot.models.fetch(model_ref)
      entry.fetch("base_url") { provider_base_url(provider_id, snapshot: snapshot) }
    end

    # Operator capacity, not a wire fact; a workload with no entry inherits
    # the provider's ceiling, so a new workload is bounded from day one.
    def provider_concurrency_limit(provider_id, workload: nil, snapshot: current)
      declaration = provider_declaration(provider_id, snapshot: snapshot)
      ceiling = declaration.fetch("concurrency_limit")
      return ceiling if workload.nil?

      declaration.fetch("workload_concurrency_limits", {}).fetch(workload.to_s, ceiling)
    end

    def provider_declaration(provider_id, snapshot: current)
      snapshot.providers.fetch(provider_id.to_s) do
        raise Unavailable, "provider #{provider_id.inspect} is not in the current catalog"
      end
    end

    # Shared immutability helper for every published catalog value.
    def deep_freeze(value)
      case value
      when Hash
        value.each do |key, nested|
          deep_freeze(key)
          deep_freeze(nested)
        end
      when Array
        value.each { |nested| deep_freeze(nested) }
      else
        value
      end
      value.freeze
    end

    private

    def default_root
      Rails.root.join("config/model_catalog")
    end

    def require_runtime
      @runtime or raise Unavailable, "the model catalog has not booted in this process"
    end
  end
end
