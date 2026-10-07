module CybrosAgent
  module Api
    # THE LANES BEHIND THE MODELS. A model runs only when its provider is
    # both ENABLED and CREDENTIALED, and those are independent facts: a
    # caller that installed a key and never enabled the lane has done half
    # the job, and a surface that hid the difference would leave them
    # staring at a listing that still says nothing will run.
    #
    # THE SECRET IS WRITE-ONLY. Nothing here reads one back, in any shape,
    # and a lane's `configured` is the whole of what a caller may learn.
    #
    # THE PROVIDER'S OWN CLOCK. `unavailable_until` is the ISO 8601 time the
    # lane's provider last named in a `Retry-After` on an overloaded answer,
    # nil once it has passed or when it never said one — a DELAY on queued
    # work, never a readiness fact, so `ready?` ignores it. The gem parses
    # no time: the string is the fact, and a caller compares it to its own clock.
    class ModelProviders
      Lane = Data.define(
        :id, :display_name, :credentials, :enabled, :lock_version, :configured, :material_kind,
        :reauthorization_required, :models, :unavailable_until
      ) do
        def initialize(display_name: nil, lock_version: nil, material_kind: nil, reauthorization_required: false,
                       models: 0, unavailable_until: nil, **) = super

        def enabled? = enabled
        def configured? = configured
        # BOTH, which is the only question worth asking of a lane.
        def ready? = enabled? && configured? && !reauthorization_required
        def api_key? = credentials == "api_key"
      end
    end

    # A lane as both doors serve it: the listing's row and the singular
    # `model_provider` a command answers. The three flags compact away when
    # false; `models` counts the catalog rows the lane serves.
    module ModelProviderProjections
      include Parsing

      SHAPES = {
        ModelProviders::Lane => {
          id: :string,
          display_name: :optional_string,
          credentials: :nullable_string,
          enabled: :flag,
          lock_version: :raw,
          configured: :flag,
          material_kind: :raw,
          reauthorization_required: :flag,
          models: :count,
          unavailable_until: :nullable_string,
        },
      }.freeze
    end

    class ModelProviders
      include ModelProviderProjections

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      def list
        body = @dispatch.call(self.class::PATH)
        shapes(Lane, body, "model_providers")
      end

      PATH = "/agent_api/v1/model_providers".freeze
    end
  end
end
