module Runs
  module Images
    # One finite ModelTask, owned by the existing run and invocation lifecycle.
    # The child ownership check and creation share the source run's lock, so job
    # recovery cannot create a second billed request. References are existing
    # run-bound uploads; no host filesystem or executor authority is involved.
    class Generate
      def self.call(node:) = new(node).call

      def initialize(node)
        @node = node
      end

      def call
        run = @node.run
        run.with_lock do
          @node.reload
          next :not_running unless @node.status == "running"
          next :not_mutable unless run.graph_mutable?
          next Parks::Settle.call(node: @node, timeout: true).outcome if @node.deadline_passed?
          next settle("Image task started.") if run.tasks.exists?(expansion_parent: @node, type: ::Tasks::ModelTask.sti_name)

          input = @node.tool_input
          prompt = String.try_convert(input["prompt"])
          configuration = input.fetch("configuration", {})
          ids = Array.try_convert(input.fetch("reference_upload_public_ids", []))
          unless prompt.present? && Hash.try_convert(configuration) && ids &&
              (input.keys - %w[prompt configuration reference_upload_public_ids]).empty?
            next settle("parameter_invalid: prompt must be text, configuration an object, and reference_upload_public_ids a list.", is_error: true)
          end
          model = run.execution_configuration&.image_model
          next settle("image_model_required: this execution declares no image model.", is_error: true) if model.blank?

          uploads = reference_uploads(run, ids)
          next settle("reference_upload_unavailable: every reference must be an image upload bound to this run.", is_error: true) unless uploads

          step = Tasks::Step::Model.new(workload: "image_generation",
            model: { "model" => model }, prompt: prompt, configuration: configuration,
            fallback_models: [], on_failure: "absorb", resolved_uploads: uploads)
          appended = Tasks::Append.call_locked(Tasks::Append::Command.kernel(
            run: run, steps: [step], tip: KernelTool.branch_tip(@node), origin: "kernel",
            key_generator: -> { SecureRandom.uuid_v7 },
            expansion_parent: @node, head: (KernelTool.continuation_of(@node)&.node_key if @node.tool_call_id),
            replaces: (@node.node_key if @node.tool_call_id.nil?)))
          if appended.applied?
            settle("Image task started.")
          else
            detail = appended.errors.first&.fetch("code", nil) || appended.outcome
            settle("image_task_refused: #{detail}.", is_error: true)
          end
        end
      end

      private

        def reference_uploads(run, ids)
          ids.map do |id|
            public_id = ContentUpload.canonical_public_id(id)
            return nil unless public_id

            upload = Executors::Attachments.fetch(run: run, public_id: public_id)
            return nil unless upload.content_type.start_with?("image/")

            upload
          end
        rescue ActiveRecord::RecordNotFound
          nil
        end

        def settle(text, is_error: false)
          KernelTool.settle(@node, text, title: "image generation", is_error: is_error)
        end
    end
  end
end
