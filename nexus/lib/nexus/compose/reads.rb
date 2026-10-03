module Nexus
  module Compose
    # THE READ RULE of the one lowering, in the one place both the kernel's
    # Tasks::Compile and the bench's Shape call and neither restates: an
    # authored step reads exactly the results it names — a model or a script
    # its `results`, in that order; a tool, an ask and a wait nothing. Position
    # hands a step a wait, never a read. The loop's own continuation of a round
    # (a spine the kernel's tip hands in, the round's paired calls) is
    # Tasks::Compile's and no authored step's.
    module Reads
      module_function

      def reads?(verb) = Grammar.compose_options(verb).include?("results")

      def of(verb, results) = reads?(verb) ? Array(results) : []

      # WHAT COMES BACK TO THE CALLER, over plain values: `keys` in placement
      # order; `named` the union of every node's input_from and result_from;
      # `members` every key placed in a race's arms (the barrier stands for
      # them); `internal` the keys inside a stage's expansion that are not
      # its final leaf; `retired` the keys an expansion replaced. WHEN it
      # comes back is a fact about live rows (AgentLoops::Delivery.ready).
      # One consumer is the rows' alone: a turn-owned spawn's short await,
      # which never comes back beside the delegation that owns the child's
      # report — both are expansion children no plan holds before the call
      # runs, so the rows' loader decides it (AgentLoops::WakeContinuation).
      def unread(keys, named:, members:, internal:, retired:)
        keys - named.to_a - members.to_a - internal.to_a - retired.to_a
      end
    end
  end
end
