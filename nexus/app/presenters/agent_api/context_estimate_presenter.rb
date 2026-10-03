module AgentAPI
  # The estimate's one projection: the count and the history evidence as
  # before; with `render`, what the send would seal — the entries verbatim
  # (read exactly as the sealed-request door reads them), the storage line
  # from the one measure, and the thin evidence envelope: per block its
  # state (`selected | empty | floor_unmet`), its fill cost and the
  # allocator's grant (null where no window sized anything). No per-block
  # bytes (no wire carries a pre-merge number), no `excluded` (the request
  # sends whole; the window gate alone refuses).
  class ContextEstimatePresenter
    class << self
      def full(estimate, render: false)
        base = {
          input_tokens: estimate.input_tokens,
          tokenizer_exact: estimate.tokenizer_exact,
          catalog_input_token_limit: estimate.catalog_input_token_limit,
          advisory_input_token_limit: estimate.advisory_input_token_limit,
          message_count: estimate.message_count,
          history: history(estimate),
        }
        render ? base.merge(rendered(estimate.rendered)) : base
      end

      private

        def history(estimate)
          {
            selected: estimate.history_selected,
            skipped: estimate.history_skipped,
            skipped_reason: estimate.history_skipped_reason,
            # What a summary stands in for, apart from `skipped`: skipped
            # history is lost, compacted history is carried. Zero elides.
            compacted: estimate.history_compacted&.positive? ? estimate.history_compacted : nil,
          }.compact
        end

        def rendered(rendered)
          {
            mechanism: rendered.mechanism,
            entries: rendered.entries,
            storage: storage(rendered.storage),
            blocks: rendered.blocks.map { |block| block_evidence(block) },
            memory: { included: rendered.memory.included, omitted: rendered.memory.omitted },
            # The registered documents compiled, by slot — an override
            # carries none, an unfilled slot is absent.
            slots: rendered.slots.versions,
          }
        end

        # Over the bound the preview still answers, with the seal's own
        # refusal word beside the number: showing the overflow is the point.
        def storage(measured)
          {
            bytes: measured.bytes,
            bound: measured.bound,
            within_bound: measured.within_bound?,
            refusal: measured.refusal&.to_s,
          }.compact
        end

        def block_evidence(block)
          {
            block: block.key,
            index: block.index,
            type: block.type,
            role: block.role,
            state: block.state,
            tokens: block.tokens,
            allocated_tokens: block.allocated_tokens,
          }
        end
    end
  end
end
