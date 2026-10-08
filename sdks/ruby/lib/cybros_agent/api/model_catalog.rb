module CybrosAgent
  module Api
    # WHICH MODELS THIS ACCOUNT CAN RUN, and what each one would cost.
    #
    # Every Agent reads the account's configured, available models. The
    # server applies availability before returning this member listing;
    # the administrator listing shares its row and pricing projections.
    #
    # It hangs off the client rather than a Workspace for the same reason
    # the tool catalog does: which models exist is not a workspace's fact.
    class ModelCatalog
      include Parsing
      include Fields

      PATH = "/agent_api/v1/models".freeze

      Pricing = Data.define(:state, :unit, :input_per_mtok, :output_per_mtok) do
        def initialize(unit: nil, input_per_mtok: nil, output_per_mtok: nil, **) = super
        def priced? = state == "priced"
        def free? = state == "known_free_candidate"
      end

      Model = Data.define(
        :ref, :provider, :workload, :visible, :available, :unavailable_reason, :capabilities, :pricing
      ) do
        # Capability descriptors retain the server's semantic names and
        # absent/null/false values; clients need not infer controls from refs.
        def initialize(capabilities: {}, unavailable_reason: nil, **) = super

        def available? = available
        def visible? = visible
        # THE ONE A TOOL-DRIVEN RUN DEPENDS ON: a model that cannot make
        # a call cannot drive one, and choosing it burns a round to learn
        # that.
        def tool_calls? = capabilities["tool_calls"] == true
      end

      def initialize(dispatch:)
        @dispatch = dispatch
      end

      # Availability is the member endpoint's fixed contract. A caller
      # may narrow by workload but cannot request unavailable models.
      def list(workload: nil)
        read_models(query(workload:))
      end

      SHAPES = {
        Model => {
          ref: :string,
          provider: :string,
          workload: :string,
          visible: :flag,
          available: :flag,
          unavailable_reason: :raw,
          capabilities: :json_object_or_empty,
          pricing: [:shape_or_empty, Pricing],
        },
        # `state` is the one word the row always carries; the numbers ride
        # only a priced row, as the decimal strings the server stored.
        Pricing => { state: :raw, unit: :raw, input_per_mtok: :raw, output_per_mtok: :raw },
      }.freeze

      private

        def read_models(params)
          body = @dispatch.call(self.class::PATH, params: params)
          shapes(Model, body, "models")
        end
    end
  end
end
