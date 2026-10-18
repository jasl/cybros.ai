module ModelSelection
  module Workloads
    # Reads only the submitted selection: a refusal here is decidable
    # before anything is looked up, so nothing downstream can widen it.
    module Selection
      SELECTOR_WORKLOADS = %w[text_generation].freeze
      REASONING_EFFORT_WORKLOADS = %w[text_generation].freeze

      class << self
        def refusal_for(workload:, submitted:)
          return :unsupported_workload unless Nexus::ModelWorkloads::ALL.include?(workload)

          selection_refusal(workload, submitted)
        end

        private

          def selection_refusal(workload, submitted)
            selector = submitted.model_selector
            model = submitted.model

            if selector
              return :invalid_model_selection if selector.blank?
              return :selector_not_supported unless SELECTOR_WORKLOADS.include?(workload)
              return :unexpected_reasoning_effort unless submitted.reasoning_effort.nil?
              return :unexpected_reasoning_enabled unless submitted.reasoning_enabled.nil?

              nil
            elsif exact_model_ref?(model)
              unless REASONING_EFFORT_WORKLOADS.include?(workload)
                return :unexpected_reasoning_effort unless submitted.reasoning_effort.nil?
                return :unexpected_reasoning_enabled unless submitted.reasoning_enabled.nil?
              end

              nil
            elsif model.blank?
              :missing_model_selection
            else
              :invalid_model_selection
            end
          end

          def exact_model_ref?(model) = Nexus::ModelRef.parse(model).complete?
      end
    end
  end
end
