module ModelCatalog
  # The process-local snapshot publisher. `boot` compiles the whole current
  # file candidate or fails fast; consumers then share that immutable snapshot
  # for the lifetime of this runtime.
  class Runtime
    def initialize(root:, override_dir: nil, env: Rails.env)
      @root = root
      @override_dir = override_dir
      @env = env
      @snapshot = nil
    end

    def boot
      @snapshot = compile
      true
    end

    # The consumer read: selection/quote/admission/provider-start. Refuses
    # with zero provider IO while unbooted.
    def current
      @snapshot or raise Unavailable, "the model catalog has not booted in this process"
    end

    def ready? = !@snapshot.nil?

    private

    def compile
      # No cohort gate: the catalog is the only place a model exists, and an
      # operator who removes one meant to.
      candidate = FileBase.compile(root: @root, override_dir: @override_dir, env: @env)
      Snapshot.new(
        providers: candidate.providers,
        models: candidate.models,
        selectors: candidate.selectors
      ).freeze
    end
  end
end
