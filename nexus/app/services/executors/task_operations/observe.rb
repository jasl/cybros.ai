module Executors
  module TaskOperations
    class Observe
      def initialize(access:, after:)
        @access = access
        @after = after
      end

      def call
        @access.mutate(admission: false) do |node|
          current = Trace.position(node)
          if @after < current
            recorded = node.task_operations.where(observed_position: (@after + 1)..).reorder(:observed_position).first
            if recorded
              next Outcome.accepted({ "observation" => Trace.observation(recorded), "position" => recorded.observed_position })
            end
          end
          next Outcome.refused(:operation_position_changed) unless @after == current

          candidate = Observation.pending(node).find(&:ready?)
          if candidate
            Observation.record(candidate, position: current + 1)
            Outcome.accepted({ "observation" => Trace.observation(candidate.operation), "position" => current + 1 })
          else
            Outcome.accepted({ "observation" => nil, "position" => current })
          end
        end
      end
    end
  end
end
