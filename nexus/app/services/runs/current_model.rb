module Runs
  # A loop's main-line selection is its mainline tail's current invocation,
  # or the authored choice before that generation starts. The variant
  # keeps the initial choice; a branch or an older execution cannot replace it.
  module CurrentModel
    module_function

    def for(run, nodes: nil)
      selection_of(run.mainline_tail(nodes: nodes)) || run.retained_model || run.variant
    end

    def for_variant(variant)
      run = variant.run if variant.source == "run"
      run ? self.for(run) : variant
    end

    # Resolve a page's current selections together, retaining nil for loops
    # without a model mainline so the page can use the variant's initial choice.
    def for_loops(loops)
      nodes = ::Tasks::ModelTask.where(run_id: loops.map(&:id))
        .where("continuation_source IS DISTINCT FROM ?", ::Tasks::ModelTask::BRANCH)
        .select(:id, :type, :run_id, :node_key, :continuation_source,
          :input_from_node_keys, :provider_id, :model_ref, :reasoning_effort, :reasoning_enabled,
          :selected_model_invocation_id, :execution_generation)
        .includes(:selected_model_invocation)
        .group_by(&:run_id)
      loops.to_h do |run|
        [run.id, selection_of(run.mainline_tail(nodes: nodes.fetch(run.id, []))) || run.retained_model]
      end
    end

    def selection_of(node)
      return if node.nil?

      invocation = node.selected_model_invocation
      invocation&.internal_creation_key == node.invocation_creation_key ? invocation : node
    end
  end
end
