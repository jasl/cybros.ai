require "json"
require "securerandom"
require "time"
require_relative "store_document"
require_relative "memory_review/state"
require_relative "memory_review/review"

module Rho
  # Selection belongs to rho. A dedicated side conversation owns the model
  # request under the source's inherited access, and the source's scoped store
  # owns submission recovery. No workspace-wide execution contains private text.
  class MemoryReview
    NAMESPACE = "rho.memory_review".freeze
    KEY = "settings".freeze
    SOURCE_KEY = "source".freeze
    DOCUMENT_BYTES = 6 * 1024
    SOURCE_BYTES = 16 * 1024
    # Create keys expire after 24 hours. Older ambiguous submissions are
    # discarded instead of becoming new work under an expired key.
    SUBMISSION_SECONDS = 23 * 60 * 60
    INITIAL_CONTENT = "# Memory\n\nStable notes and a dated index of past work.\n".freeze

    # The plugin's defaults: whether a conversation that never chose joins
    # at its first completed reply, and with which document and model.
    Defaults = Data.define(:auto_enable, :path, :model) do
      def self.none = new(auto_enable: false, path: "speaker/review.md", model: nil)

      # The plugin configuration carries the schema's defaults for the two
      # required fields; the model is nullable.
      def self.from_configuration(configuration)
        new(auto_enable: configuration.fetch("auto_enable") == true, path: configuration.fetch("path").to_s,
          model: configuration["model"])
      end
    end

    def self.source_for(workspace:, conversation_public_id:)
      document = StoreDocument.new(store: -> { workspace.conversation(conversation_public_id).store_entries },
        namespace: NAMESPACE, key: SOURCE_KEY).read
      return conversation_public_id if document.nil?

      source = Source.from_h(document)
      source.review_conversation_public_id == conversation_public_id ? source.conversation_public_id : conversation_public_id
    end

    def self.context_snapshot(conversation)
      { "memory_context" => conversation.effective_memory_context, "memory_configuration" => conversation.memory_context,
        "answering_user_public_id" => conversation.answering_user_public_id }
    end

    def self.unbound_speakers(conversation)
      Array(conversation.memory_context&.fetch("bindings")).select do |binding|
        binding.fetch("scope") == "speaker" && binding["speaker_public_id"].nil?
      end
    end

    def initialize(workspace:, conversation_public_id:, clock: -> { Time.now }, follow: nil, forget: nil, defaults: Defaults.none)
      @workspace, @conversation_public_id, @clock = workspace, conversation_public_id, clock
      @conversation = workspace.conversation(conversation_public_id)
      @follow, @forget, @defaults = follow, forget, defaults
      @document = StoreDocument.new(store: -> { @conversation.store_entries }, namespace: NAMESPACE, key: KEY)
    end

    def status
      current = state
      { "enabled" => current.enabled, "path" => current.path, "model" => current.model, "speaker_public_id" => current.speaker_public_id,
        "run_public_id" => current.last_run_public_id, "review_conversation_public_id" => current.last_review_conversation_public_id,
        "pending" => !current.pending.nil?, "outcome" => current.outcome }
    end

    # Only an explicit enable may create or adopt a destination. Automatic
    # review never recreates a deleted document or adopts a replacement ID.
    # `after_position` is the last turn left unreviewed; omitted, the newest.
    def enable(path:, model: nil, after_position: nil, speaker_public_id: nil)
      path = path.to_s
      raise Rho::Error, "memory review needs a scoped document path" if path.empty?
      root, name = path.split("/", 2)
      raise Rho::Error, "memory review cannot write skills" if name.to_s.start_with?("skills/")
      conversation = @conversation.fetch
      raise Rho::Error, "memory review needs a main conversation" if conversation.side?
      bindings = conversation.effective_memory_context.fetch("bindings")
      selected = bindings.find { |binding| binding.fetch("name") == root }
      if selected.nil? && speaker_public_id
        selected = self.class.unbound_speakers(conversation).find { |binding| binding.fetch("name") == root }
      else
        speaker_public_id = nil
      end
      unless selected && selected.fetch("access") == "read_write"
        raise Rho::Error, "memory review needs a writable root in this conversation"
      end

      document = read_memory(path, speaker_public_id: speaker_public_id)
      document ||= @conversation.memory(speaker_public_id: speaker_public_id).write(path, INITIAL_CONTENT,
        expected_public_id: nil, expected_lock_version: nil)
      after_position ||= @conversation.turns.list(before_position: 2_147_483_647, limit: 1).items.last&.position || -1
      change do |current|
        current.with(enabled: true, path: path, document_public_id: document.public_id, speaker_public_id: speaker_public_id,
          model: model&.to_s, after_position: after_position)
      end
      status
    end

    def disable
      change { |current| current.with(enabled: false) }
      resume
    end

    # Recover the same fork and input, then either attach their follower or
    # apply their already settled answer. This never selects old source work.
    def resume
      current = state
      return status unless current.pending

      pending = current.pending
      unless current.enabled && Review.new(workspace: @workspace, input: pending.input, clock: @clock).current?
        cancel_side(pending)
        finish(pending, outcome: current.enabled ? "skipped" : "canceled")
        return status
      end

      pending = submit(pending)
      side = @workspace.conversation(pending.review_conversation_public_id)
      materialized = side.inputs.materialization(pending.input_public_id, include_hidden: true)
      if materialized
        turn = side.turns.fetch(materialized.turn_public_id, include_hidden: true)
        if %w[completed failed canceled].include?(turn.status)
          settle_review(pending, turn, materialized)
          return status
        end
      elsif side.inputs.list.items.any? { |row| row.public_id == pending.input_public_id && row.state == "blocked" }
        cancel_side(pending)
        finish(pending, outcome: "failed")
        return status
      end
      @follow&.call(pending.review_conversation_public_id)
      status
    rescue CybrosAgent::Api::NotFound
      raise unless pending

      finish(pending, outcome: "canceled")
      status
    end

    def settled(settlement)
      if settlement.conversation_public_id != @conversation_public_id
        pending = state.pending
        resume if pending&.review_conversation_public_id == settlement.conversation_public_id
        return
      end
      return unless settlement.status == "completed"
      adopt_defaults(settlement) if @defaults.auto_enable && @document.read.nil?
      return unless state.enabled

      resume if state.pending
      turn = @conversation.turns.fetch(settlement.turn_public_id)
      current = state
      return if turn.position <= current.after_position

      # A running review owns its one snapshot. Busy arrivals advance the
      # watermark without replacing it or being reconsidered later.
      input = review_input(settlement, turn, current) unless current.pending
      change do |value|
        pending = input && Submission.new(idempotency_key: SecureRandom.uuid, input_idempotency_key: SecureRandom.uuid,
          prepared_at: @clock.call.utc.iso8601, input: input, review_conversation_public_id: nil, input_public_id: nil)
        value.with(after_position: turn.position, pending: value.pending || pending,
          outcome: pending ? nil : value.outcome, last_run_public_id: pending ? nil : value.last_run_public_id)
      end
      resume if input
    end

    # Forked settings snapshots do not opt the child into further review.
    def state
      value = @document.read
      return State.empty(@conversation_public_id) if value.nil?

      decoded = State.from_h(value)
      decoded.conversation_public_id == @conversation_public_id ? decoded : State.empty(@conversation_public_id)
    end

    private

      # The plugin's default for a conversation that never chose: review from
      # this first completed reply on. One that cannot — a side, no writable
      # root for the document, a kernel door that refuses it — is recorded
      # as off, so the question is not asked again at every reply; an
      # explicit enable still works later. A transport or server failure
      # records nothing and the next reply asks again.
      def adopt_defaults(settlement)
        turn = @conversation.turns.fetch(settlement.turn_public_id)
        root = @defaults.path.split("/", 2).first
        selected = settlement.memory_context&.fetch("bindings")&.find { |binding| binding.fetch("name") == root }
        raise Rho::Error, "memory review needs a writable root in this execution" unless selected && selected.fetch("access") == "read_write"

        enable(path: @defaults.path, model: @defaults.model, after_position: turn.position - 1,
          speaker_public_id: selected["speaker_public_id"])
      rescue Rho::Error, CybrosAgent::Api::Forbidden, CybrosAgent::Api::Conflict, CybrosAgent::Api::NotFound,
             CybrosAgent::Api::InvalidRequest
        change { |current| current.with(enabled: false) }
      end

      def change
        value = @document.change do |document|
          current = document.empty? ? State.empty(@conversation_public_id) : State.from_h(document)
          current = State.empty(@conversation_public_id) if current.conversation_public_id != @conversation_public_id
          document.replace(yield(current).to_h)
        end
        State.from_h(value)
      end

      def review_input(settlement, turn, current)
        variant = turn.active_variant
        return unless turn.status == "completed" && turn.kind == "direct_reply" && turn.visibility != "hidden" &&
          !turn.inherited? && variant&.run_public_id == settlement.run_public_id && variant.status == "completed"
        return unless variant.memory_context == settlement.memory_context

        conversation = @conversation.fetch
        snapshot = self.class.context_snapshot(conversation)
        memory_context = snapshot.fetch("memory_context")
        bindings = memory_context.fetch("bindings")
        captured = settlement.memory_context&.fetch("bindings")
        # Execution captures selectors; the management read adds resolved
        # anchors but omits unbound Speaker roots. Only those still-configured
        # roots may be absent; recovery also checks the raw selection and owner.
        unbound = self.class.unbound_speakers(conversation)
        resolved = captured&.reject { |selection| unbound.include?(selection.except("speaker_public_id")) }
        return unless resolved && resolved.length == bindings.length && resolved.zip(bindings).all? do |selection, binding|
          binding.slice(*selection.keys) == selection
        end
        root = current.path.split("/", 2).first
        destination = if current.speaker_public_id
          captured.find do |binding|
            binding.fetch("name") == root && binding.fetch("scope") == "speaker" &&
              binding["speaker_public_id"] == current.speaker_public_id
          end
        else
          bindings.find { |binding| binding.fetch("name") == root }
        end
        return unless destination && destination.fetch("access") == "read_write"

        document = read_memory(current.path, speaker_public_id: current.speaker_public_id)
        return unless document && document.public_id == current.document_public_id && document.content.bytesize <= DOCUMENT_BYTES

        model = current.model || settlement.model
        return if model.to_s.empty? || variant.content.to_s.strip.empty?

        snapshot.merge(
          "conversation_public_id" => @conversation_public_id, "turn_public_id" => turn.public_id,
          "run_public_id" => variant.run_public_id, "model" => model, "speaker_public_id" => current.speaker_public_id,
          "source_date" => turn.created_at, "expires_at" => (@clock.call + SUBMISSION_SECONDS).utc.iso8601,
          "prompt" => bounded(variant.prompt_text.to_s, SOURCE_BYTES / 2),
          "answer" => bounded(variant.content.to_s, SOURCE_BYTES / 2),
          "path" => document.path, "document_public_id" => document.public_id,
          "lock_version" => document.lock_version, "content" => document.content,
        )
      end

      def read_memory(path, speaker_public_id: nil)
        @conversation.memory(speaker_public_id: speaker_public_id).read(path)
      rescue CybrosAgent::Api::NotFound => error
        raise unless error.code == "memory_not_found"

        nil
      end

      def submit(pending)
        if pending.review_conversation_public_id.nil?
          created = @conversation.fork(side: true, title: "Memory review", idempotency_key: pending.idempotency_key)
          pending = pending.with(review_conversation_public_id: created.conversation.public_id)
          change do |value|
            value.with(pending: pending, last_review_conversation_public_id: pending.review_conversation_public_id)
          end
        end
        side = @workspace.conversation(pending.review_conversation_public_id)
        source = Source.new(conversation_public_id: @conversation_public_id,
          review_conversation_public_id: pending.review_conversation_public_id, idempotency_key: pending.idempotency_key)
        StoreDocument.new(store: -> { side.store_entries }, namespace: NAMESPACE, key: SOURCE_KEY).change do |document|
          document.replace(source.to_h)
        end
        return pending if pending.input_public_id

        accepted = side.inputs.create(idempotency_key: pending.input_idempotency_key, kind: "direct_reply",
          context_mode: "raw", instructions: Review::INSTRUCTIONS,
          entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => Review.prompt(pending.input) }] }],
          model: pending.input.fetch("model"), configuration: { "max_output_tokens" => Review::OUTPUT_TOKENS },
          tool_names: [], delivery_mode: "queue", visible_in_context: false)
        pending = pending.with(input_public_id: accepted.public_id)
        change { |value| value.with(pending: pending) }
        pending
      end

      def settle_review(pending, turn, materialized)
        variant = turn.active_variant
        outcome = if turn.status == "canceled"
          "canceled"
        elsif turn.status != "completed"
          cancel_side(pending)
          "failed"
        elsif variant&.public_id != materialized.variant_public_id || variant.run_public_id != materialized.run_public_id
          "skipped"
        else
          Review.new(workspace: @workspace, input: pending.input, clock: @clock).apply(variant.content.to_s)
        end
        finish(pending, outcome: outcome, run_public_id: materialized.run_public_id)
      rescue Rho::Error
        finish(pending, outcome: "failed", run_public_id: materialized.run_public_id)
      end

      def cancel_side(pending)
        return if pending.review_conversation_public_id.nil?

        side = @workspace.conversation(pending.review_conversation_public_id)
        # Conversation Stop retains ordinary queued inputs. This side owns
        # one review, so cancel its queued input before cutting live execution.
        side.inputs.list.items.each { |input| side.inputs.delete(input.public_id) }
        side.cancel
      rescue CybrosAgent::Api::NotFound
        nil
      rescue CybrosAgent::Api::Conflict => error
        raise unless error.code == "not_running"
      end

      def finish(pending, outcome:, run_public_id: nil)
        change do |value|
          if value.pending&.idempotency_key == pending.idempotency_key
            value.with(pending: nil, outcome: outcome, last_run_public_id: run_public_id || value.last_run_public_id)
          else
            value
          end
        end
        @forget&.call(pending.review_conversation_public_id) if pending.review_conversation_public_id
      end

      def bounded(text, limit)
        return text if text.bytesize <= limit

        result = +""
        text.each_char do |character|
          break if result.bytesize + character.bytesize > limit - 16

          result << character
        end
        "#{result}\n[truncated]"
      end
  end
end
