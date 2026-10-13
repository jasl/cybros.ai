module Nexus
  module PromptCache
    # WHAT KIND OF REQUEST a cache marker is placed on — a fact of the
    # request, stamped where it is minted into the options it is sealed with,
    # never derived at the send. The kind decides the tier and whether the
    # rolling tail is written:
    #
    # - `mainline`: a round of a conversation's own turn, a direct reply, a
    #   regeneration — paced by a person, so its prefix is written for an hour;
    # - `branch`: a composed member, a detached step, a `task` delegate — read
    #   back by its own later rounds within seconds;
    # - `child`: every request of a subagent's conversation;
    # - `standalone`: a standalone loop's rounds; `inference_request`: a InferenceRequest;
    # - `summary`: the summarizer's request, which writes no marker at all —
    #   its instructions sit below every cacheable minimum and nobody reads
    #   its serialized history back.
    #
    # A request minted without the fact reads `unstated`: five minutes with
    # its tail.
    class RequestKind < Data.define(:kind, :tier, :tail)
      FACT = "prompt_cache".freeze
      TIERS = {
        "mainline" => "1h", "branch" => "5m", "child" => "5m",
        "standalone" => "5m", "inference_request" => "5m", "summary" => nil,
      }.freeze
      UNSTATED = "unstated".freeze

      # The fact a mint writes for `kind`: `{"kind", "tier", "tail"}`, the
      # kind alone for a request that carries no marker.
      def self.stamp(kind)
        tier = TIERS.fetch(kind)
        tier ? { "kind" => kind, "tier" => tier, "tail" => true } : { "kind" => kind }
      end

      def self.of(request_options)
        fact = request_options[FACT]
        return new(kind: UNSTATED, tier: "5m", tail: true) if fact.nil?

        new(kind: fact.fetch("kind"), tier: fact["tier"], tail: fact["tail"] == true)
      end

      # The one kind of a conversation's request: a subagent's conversation
      # is read back by its parent within seconds, every other one is paced
      # by a person.
      def self.for_conversation(conversation) = conversation.subagent? ? "child" : "mainline"

      def marked? = !tier.nil?
    end
  end
end
