module ModelSelection
  module Projection
    def self.intent(selection)
      return if selection.nil?

      { source: selection.source, model: selection.model,
        constraint: selection.constraint, alternatives: selection.alternatives }
    end
  end
end
