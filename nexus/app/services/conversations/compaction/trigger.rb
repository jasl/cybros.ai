module Conversations
  module Compaction
    # WHY the arm fired, never what it chose (that is `mode`). One closed
    # vocabulary for both hosts: the two pre-send walls are one `wall`
    # (the refusal is already narrated on the round; "the request will
    # not go" is the whole reason), the provider's refusal after the send
    # is `overflow`, a person is `manual`, and the provider's own count
    # is `usage`; a delegate nobody answered expiring at its park is
    # `fallback`. The author a repair is signed by rides beside it: a
    # pending input lends its author to the wall, a person has a session,
    # a loop has its creator. `overshoot` is the number the site had, the
    # prune arm's whole evidence; nil when it had none.
    class Trigger < Data.define(:kind, :authoring_user, :origin, :input_public_id, :overshoot)
      KINDS = %w[wall manual overflow usage fallback].freeze

      def initialize(kind:, overshoot: nil, **)
        raise ArgumentError, "unknown compaction trigger #{kind.inspect}" unless KINDS.include?(kind)

        super
      end

      class << self
        # A pending input between turns, or a queued round mid-turn.
        def wall(source, overshoot: nil) = of("wall", source, overshoot)

        # The provider refused the sent request for length — a round, or a
        # tool-less reply's sample — and never a number: the refusal carries none.
        def overflow(source) = of("overflow", source, nil)

        # The last provider-reported usage plus the tail crossed the bound.
        def usage(source, overshoot: nil) = of("usage", source, overshoot)

        # The delegate row expired unanswered: the kernel's own summarizer
        # runs once in its place. No number — the repair summarizes.
        def fallback(delegate) = of("fallback", delegate, nil)

        # A person asked to shrink: no number, so the repair summarizes.
        def manual(user:)
          new(kind: "manual", authoring_user: user, origin: nil, input_public_id: nil)
        end

        private

          # The two hosts' sources, by class: a value constructor, not a
          # behaviour a row could answer for itself.
          def of(kind, source, overshoot)
            case source
            when AgentLoopNode then on_round(kind, source, overshoot)
            when ConversationInput then on_input(kind, source, overshoot)
            when ConversationTurnVariant then on_reply(kind, source, overshoot)
            else raise ArgumentError, "a compaction trigger needs a round, an input or a reply, not #{source.class}"
            end
          end

          # A reply's sample is signed by the principal its call ran for —
          # the poster of the input it answered, as the wall's input is.
          def on_reply(kind, variant, overshoot)
            new(kind: kind, authoring_user: variant.model_invocation.creating_user, origin: nil,
              input_public_id: nil, overshoot: overshoot)
          end

          def on_input(kind, input, overshoot)
            new(kind: kind, authoring_user: input.authoring_user, origin: input.origin,
              input_public_id: input.public_id, overshoot: overshoot)
          end

          def on_round(kind, node, overshoot)
            new(kind: kind, authoring_user: node.agent_loop.creating_user, origin: nil,
              input_public_id: nil, overshoot: overshoot)
          end
      end
    end
  end
end
