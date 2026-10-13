module Rho
  # Explicit publications are shared by every reply surface. Callback results
  # name the accepted sample; a worker's later active variant is unrelated.
  class PublishedArtifacts
    def initialize(workspace)
      @workspace = workspace
    end

    def collect(run_public_id:, results: [])
      files = run_public_id ? run_files(run_public_id) : []
      files.concat(results.flat_map { |result| result_files(result) })
      files.uniq(&:public_id)
    end

    private

      def run_files(public_id)
        run = @workspace.runs.run(public_id)
        tasks = run.fetch.tasks.select do |task|
          task.status == "completed" && !task.result&.fetch("is_error", false) &&
            %w[file_publish image_generate imagegen].include?(task.tool_name)
        end
        tasks.flat_map do |task|
          capture_blocks(run.task(task.key).content).filter_map do |block|
            next unless block.fetch("type") == "resource_link"
            next unless task.tool_name == "file_publish" || block.fetch("mimeType", "").start_with?("image/")

            CybrosAgent::Api::UploadRef.new(
              public_id: block.fetch("uri").delete_prefix(CybrosAgent::Api::ResourceLink::URI_PREFIX),
              filename: block.fetch("name"), content_type: block.fetch("mimeType"), byte_size: block.fetch("size")
            )
          end
        end
      end

      def result_files(result)
        turns = @workspace.conversation(result.conversation_public_id).turns
        turn = turns.fetch(result.turn_public_id)
        variant = turn.active_variant
        unless variant&.public_id == result.variant_public_id
          variant = turns.variants(result.turn_public_id).items.find { |row| row.public_id == result.variant_public_id }
        end
        if variant && variant.status == "completed" && !variant.details_pruned_at
          collect(run_public_id: variant.run_public_id, results: turn.callback_sources.map(&:result))
        else
          []
        end
      rescue CybrosAgent::Api::NotFound, CybrosAgent::Api::Forbidden
        # A retained parent answer can outlive the readable worker details.
        []
      end

      def capture_blocks(content)
        case content
        in Array then content
        in String | nil then []
        else raise Rho::Error, "Invalid tool result content"
        end
      end
  end
end
