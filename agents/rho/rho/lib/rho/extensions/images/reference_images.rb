module Rho
  module Extensions
    module Images
      # Resolve only the source pictures for an image edit. Conversation reads
      # stop at the invoking loop's turn, so a background call cannot pick up
      # a picture a person submitted after that execution began.
      class ReferenceImages
        TURN_LIMIT = 50
        TURN_POSITION_CEILING = 2_147_483_647

        def initialize(plane:, env:, context:)
          @plane = plane
          @env = env
          @context = context
        end

        def resolve(arguments)
          paths = Array(arguments["referenced_image_paths"])
          count = arguments["num_last_images_to_include"]
          if paths.any? && count
            raise ArgumentError, "give referenced_image_paths or num_last_images_to_include, never both"
          end
          if count
            recent(Integer(count))
          else
            local(paths)
          end
        end

        private

          def recent(count)
            raise ArgumentError, "num_last_images_to_include must be between 1 and 5" unless (1..5).cover?(count)
            if @context&.conversation_public_id.nil? || @context.agent_loop_public_id.nil?
              raise ArgumentError, "recent images require a conversation; supply referenced_image_paths instead"
            end

            workspace = @plane.client.workspace(@plane.workspace_public_id)
            turns = workspace.conversation(@context.conversation_public_id).turns
            page = turns.list(before_position: TURN_POSITION_CEILING, limit: TURN_LIMIT)
            variants = page.items.map(&:active_variant)
            anchor = variants.index { |variant| variant&.agent_loop_public_id == @context.agent_loop_public_id }
            unless anchor
              raise ArgumentError, "the source turn is outside the recent image window; attach the pictures again or use local paths"
            end

            images = variants.take(anchor + 1).flat_map { |variant| Array(variant&.attachments) }
              .select { |upload| upload.content_type.start_with?("image/") }
            if images.length < count
              raise ArgumentError, "not enough recent user image attachments; attach the pictures again or use local paths"
            end

            images.last(count).map(&:public_id)
          end

          def local(paths)
            files = paths.map { |path| @env.resolve(path) }
            missing = files.find { |path| !File.file?(path) }
            raise ArgumentError, "no such reference image: #{missing}" if missing

            files.map { |path| @plane.client.uploads.create(path).public_id }
          end
      end
    end
  end
end
