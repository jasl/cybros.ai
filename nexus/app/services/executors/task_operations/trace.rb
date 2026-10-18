module Executors
  module TaskOperations
    module Trace
      PAGE_SIZE = 100
      MAX_PAGE_SIZE = 200

      module_function

      def position(node)
        [node.task_operations.maximum(:position).to_i, node.task_operations.maximum(:observed_position).to_i].max
      end

      def operation(record)
        { "type" => "operation", "position" => record.position, "key" => record.operation_key,
          "request" => record.request }.merge(record.response)
      end

      def observation(record)
        { "type" => "observation", "position" => record.observed_position, "key" => record.operation_key }
          .merge(Observation.project(record))
      end

      def snapshot(node, after: 0, limit: PAGE_SIZE)
        limit = limit.clamp(1, MAX_PAGE_SIZE)
        accepted = node.task_operations.where(position: (after + 1)..).order(:position).limit(limit).to_a
        observed = node.task_operations.where(observed_position: (after + 1)..)
          .reorder(:observed_position).limit(limit).to_a
        events = (accepted.map { |record| [record.position, record] } +
          observed.map { |record| [record.observed_position, record] }).sort_by(&:first).first(limit)
        observations = events.filter_map { |position, record| record if position == record.observed_position }
        # Paginate the lightweight facts before loading sealed payloads. An
        # operation-only page never reads bodies, and trace pages batch them.
        ActiveRecord::Associations::Preloader.new(records: observations,
          associations: { observation_body: { content_body_entries: :content_fragment } }).call
        page = events.map do |position, record|
          position == record.observed_position ? observation(record) : operation(record)
        end
        current = position(node)
        { "context" => Context.projection(node), "trace" => page, "position" => current,
          "next_after" => (page.last.fetch("position") if page.any? && page.last.fetch("position") < current) }
      end
    end
  end
end
