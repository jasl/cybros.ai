module ModelRequests
  # Where an invocation's semantic request lives, shared by request
  # construction and usage projection; lowered once, immediately before IO.
  module InputSource
    class << self
      # Every purpose executes the same Invocation-owned request role. Its
      # business source differs, but Prompt Assembly has already closed that
      # distinction before the Invocation becomes queueable.
      def accepted_body(invocation)
        body_for(invocation, "request")
      end

      # Separate from send-time lowering so settlement never walks every
      # bound upload just to count text.
      def accepted_entry_payloads(invocation)
        ContentBodyEntry.joins(:content_fragment)
          .where(
            content_body_id: invocation.content_bodies
              .where(role: "request").select(:id)
          )
          .order(:position)
          .pluck("content_fragments.payload")
      end

      # Whether the request streams is the lane's own declaration, answered
      # by the gem so both ends resolve it identically.
      def streams?(profile) = profile.streams?

      def request_input(invocation:, source:, profile:)
        Nexus::ModelRequestInput.from_invocation(
          invocation: invocation, profile: profile,
          # The stored request facts are lifted out of the generation
          # config: the reserved kwargs, the service tier Build lowers
          # under its own rule, and the cache kind its placement reads.
          generation_config: Nexus::EffectiveGenerationConfig.from_h(
            invocation.request_options.except(*Build::RESERVED_REQUEST_FACTS, Build::SERVICE_TIER_FACT,
              Build::PROMPT_CACHE_FACT)
          ),
          input: Nexus::InputEntries.from(
            entries: entry_payloads(source),
            workload: invocation.workload
          ),
          stream: streams?(profile)
        )
      end

      private

        def entry_payloads(source)
          source.content_body_entries.map { |entry| entry.content_fragment.payload }
        end

        def body_for(owner, role)
          owner.content_bodies
            .includes(
              content_body_entries: :content_fragment,
              content_uploads: { file_attachment: :blob }
            )
            .find_by(role: role)
        end
    end
  end
end
