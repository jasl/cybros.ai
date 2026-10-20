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
      tails = Run.mainline_tails(loops.map(&:id))
      ActiveRecord::Associations::Preloader.new(records: tails, associations: :selected_model_invocation).call
      by_run = tails.index_by(&:run_id)
      loops.to_h do |run|
        [run.id, selection_of(by_run[run.id]) || run.retained_model]
      end
    end

    def selection_of(node)
      return if node.nil?

      invocation = node.selected_model_invocation
      invocation&.internal_creation_key == node.invocation_creation_key ? invocation : node
    end
  end
end
