module AgentRuns
  module Tasks
    # The cursor every placement is relative to — a value derived under the
    # lock at an envelope boundary or handed in by a kernel author, never a
    # row. Lifetime and completion wake policy belong to the enclosing authoring
    # context, independently of dependencies: a step override does not change its siblings.
    Tip = Data.define(:mainline, :waits, :reads, :mark, :detached, :lifetime, :wake) do
      def self.seed(mark, lifetime: "conversation", wake: "auto")
        new(mainline: nil, waits: [], reads: [], mark: mark, detached: false, lifetime: lifetime, wake: wake)
      end

      def initialize(lifetime: "conversation", wake: "auto", **) = super
    end
  end
end
