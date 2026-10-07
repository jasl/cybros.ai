# The one front door over HTTP, over a host: typed fields through Strong
# Parameters, raw mode's free-shape entry list through the parsed body. A per-host
# subclass names the host; nothing else differs. No sender field is ever read from
# a caller — the kernel stamp is the kernel's alone.
class AgentAPI::V1::Workspaces::InputsController < AgentAPI::V1::Workspaces::BaseController
  include AgentAPI::AssemblyIntents

  def index
    host = self.host

    # READ order: the order the drain will take — the kernel's own rows
    # first, then arrival; `queue_position` stays the arrival number.
    inputs = host.conversation_inputs
      .where(state: ConversationInput::STATES)
      .in_read_order
      .includes(:content_bodies).to_a
    ContentBody.preload_for_render(inputs.flat_map(&:content_bodies))

    render json: {
      inputs: inputs.map { |input| AgentAPI::ConversationPresenter.input(input) },
      input_queue: {
        limit: host.input_queue_limit,
        held: host.conversation_inputs.caller_authored.count,
      },
    }
  end

  def update
    host = self.host
    fields = params.permit(input: [
      :text, :visible_in_context, :context_mode, :expected_lock_version, :approval_mode, :instructions,
      :deliver_at, :deliver_in,
      { model: %i[model reasoning_effort reasoning_enabled], configuration: {} },
    ]).fetch(:input)
    provider_id, model_ref, reasoning_effort, reasoning_enabled = split_model(fields[:model])
    attachments = submitted_attachments
    # THE CLOCK ON THE EDIT: absent keeps the row's time (nil is
    # untouched); a time reschedules; `deliver_in: "0s"` is the clear —
    # the one parser resolves it, the door re-judges the bounds.
    deliver_at = deliver_at_time(fields)
    return if performed?

    expected_lock_version = fields[:expected_lock_version].nil? ? nil :
      bounded_integer(fields[:expected_lock_version], :expected_lock_version, range: 0..(2**31))
    result = ::Conversations::Inputs::Update.call(::Conversations::Inputs::Update::Command.new(
      host: host,
      input_public_id: params.fetch(:public_id),
      acting_user: acting_user,
      expected_lock_version: expected_lock_version,
      entries: update_entries(fields),
      attachments: attachments,
      visible_in_context: cast_boolean(fields[:visible_in_context]),
      context_mode: fields[:context_mode],
      context_options: submitted_context_options,
      provider_id: provider_id,
      model_ref: model_ref,
      reasoning_effort: reasoning_effort, reasoning_enabled: reasoning_enabled,
      request_options: fields[:configuration]&.to_h,
      tool_names: submitted_tool_names,
      approval_mode: fields[:approval_mode],
      instructions: fields[:instructions],
      deliver_at: deliver_at,
      steps: submitted_steps,
    ))

    if result.accepted?
      render json: { input: AgentAPI::ConversationPresenter.input(result.value.reload) }
    else
      render_refused(result)
    end
  end

  def destroy
    result = ::Conversations::Inputs::Destroy.call(::Conversations::Inputs::Destroy::Command.new(
      host: host,
      input_public_id: params.fetch(:public_id),
      acting_user: acting_user,
    ))

    if result.accepted?
      head :no_content
    else
      render_refusal(result.outcome)
    end
  end

  def create
    key = required_idempotency_key
    return if performed?

    host = self.host

    envelope = create_envelope
    return if performed?

    outcome = ConversationCommandReceipt::Idempotent.call(
      account: current_account,
      workspace: host.workspace,
      acting_user: acting_user,
      operation: :input_create,
      idempotency_key: key,
      request_digest: ConversationCommandReceipt.digest_for(
        operation: :input_create, envelope: envelope
      ),
      host: host,
    ) do
      result = ::Conversations::Inputs::Create.call(command(host, envelope))
      if result.accepted?
        ConversationCommandReceipt::Idempotent::Success.new(
          status: 202,
          body: { input: AgentAPI::ConversationPresenter.input(result.value) },
          host: host,
        )
      else
        result
      end
    end

    render_idempotent_outcome(outcome)
  end

  private

    def command(host, envelope)
      provider_id, model_ref, reasoning_effort, reasoning_enabled = split_model(envelope["model"])
      ::Conversations::Inputs::Create::Command.new(
        host: host,
        acting_user: acting_user,
        kind: envelope["kind"] || "message",
        role: envelope["role"] || "user",
        entries: envelope["entries"],
        # Absent stays nil: the host decides whether the field is admitted
        # at all, and the door defaults an absent one to visible.
        visible_in_context: cast_boolean(envelope["visible_in_context"]),
        delivery_mode: envelope["delivery_mode"] || "queue",
        context_mode: envelope["context_mode"],
        context_options: envelope["context_options"],
        expected_context_revision: envelope["expected_context_revision"],
        expected_tail_turn_public_id: envelope["expected_tail_turn_public_id"],
        expected_steering_run_public_id: envelope["expected_steering_run_public_id"],
        provider_id: provider_id,
        model_ref: model_ref,
        reasoning_effort: reasoning_effort, reasoning_enabled: reasoning_enabled,
        request_options: envelope["configuration"],
        tool_names: envelope["tool_names"],
        approval_mode: envelope["approval_mode"],
        instructions: envelope["instructions"],
        answering_user_public_id: envelope["answering_user_public_id"],
        speaker_public_id: envelope["speaker_public_id"],
        attachments: envelope["attachments"],
        # The resolved time, read back off the envelope's own canonical
        # string: the row holds exactly what the digest fenced.
        deliver_at: envelope["deliver_at"] && Time.iso8601(envelope["deliver_at"]),
        steps: envelope["steps"],
      )
    end

    def submitted_speaker
      value = request.request_parameters.fetch("input")["speaker_public_id"]
      return nil if value.nil?
      raise ParameterInvalid.new(:speaker_public_id) unless ConversationInput.uuid_shaped?(value)

      value.to_s.downcase
    end

    def create_envelope
      # permit-then-fetch, not expect: an entries-only body (raw mode's
      # legitimate minimal shape) filters to an empty typed set.
      fields = params.permit(input: [
        :kind, :role, :text, :visible_in_context, :delivery_mode, :context_mode,
        :expected_context_revision, :expected_tail_turn_public_id, :approval_mode, :instructions,
        :answering_user_public_id, :deliver_at, :deliver_in,
        { model: %i[model reasoning_effort reasoning_enabled], configuration: {} },
      ]).fetch(:input)
      deliver_at = deliver_at_time(fields)
      return {} if performed?

      {
        "kind" => fields[:kind],
        "role" => fields[:role],
        "entries" => submitted_entries(fields),
        "visible_in_context" => fields[:visible_in_context],
        "delivery_mode" => fields[:delivery_mode],
        "context_mode" => fields[:context_mode],
        "context_options" => submitted_context_options,
        "expected_context_revision" => expected_revision(fields),
        "expected_tail_turn_public_id" => expected_tail(fields),
        "expected_steering_run_public_id" => expected_steering_loop,
        "model" => fields[:model]&.to_h,
        "configuration" => fields[:configuration]&.to_h,
        "tool_names" => submitted_tool_names,
        "approval_mode" => fields[:approval_mode],
        # `raw`'s system field: the one field outside `entries`.
        "instructions" => fields[:instructions],
        # The addressee: `@handle` or a public id, the create door's word; in
        # the digest, so a replay naming another is a mismatch.
        "answering_user_public_id" => fields[:answering_user_public_id],
        "speaker_public_id" => submitted_speaker,
        # The pictures beside the words: canonical upload ids in order; in
        # the digest, so a replay naming another set is a mismatch.
        "attachments" => submitted_attachments,
        # THE CLOCK: the CANONICAL ISO string of the resolved time, in the
        # digest — a replay naming another time is a mismatch, and a
        # `deliver_in` replay resolves to a later instant and mismatches
        # too: a retry after a delay is not the same word.
        "deliver_at" => deliver_at&.iso8601,
        "steps" => submitted_steps,
      }.compact
    end

    # conversations.md: authored steps contain open tool inputs and nested
    # step trees. Preserve their parsed JSON for the queued row and append
    # digest; the model bounds the array, the existing compiler accepts it.
    def submitted_steps
      request.request_parameters.dig("input", "steps")
    end

    # THE ONE PARSER, at this door: `deliver_at` (ISO 8601 WITH an offset
    # or `Z`) or `deliver_in` (`90s`, `20m`, `2h`, `1d`), resolved against
    # this boundary's clock and canonicalized to whole seconds in UTC —
    # the string the envelope digests and the row holds. A malformed value
    # is `400 parameter_invalid` naming its field (the
    # `expected_tail_turn_public_id` precedent); both at once is the
    # door's `422 deliver_at_ambiguous`. Absent is nil: the door defaults
    # a create to now and an update to untouched.
    def deliver_at_time(fields)
      reading = ::Conversations::Inputs::DeliverAt.parse(
        at: fields[:deliver_at], in_: fields[:deliver_in], now: Time.current
      )
      case reading.refusal
      when nil then reading.time&.utc&.floor
      when :deliver_at_invalid then raise APIErrors::ParameterInvalid, :deliver_at
      when :deliver_in_invalid then raise APIErrors::ParameterInvalid, :deliver_in
      else render_refusal(reading.refusal)
      end
    end

    # `attachments` beside `text`: a list of upload public ids, read from the
    # parsed body like `entries`, each canonicalized through the uuid
    # column's own type — a malformed id is a refusal here, never a miss
    # downstream that reads as another creator's. Never beside `entries`:
    # the raw grammar places its own parts.
    def submitted_attachments
      value = request.request_parameters.dig("input", "attachments")
      return nil if value.nil?

      ids = Array.try_convert(value)
      raise APIErrors::ParameterInvalid, :attachments if ids.nil? ||
        request.request_parameters.dig("input", "entries")

      ids.map do |id|
        ContentUpload.canonical_public_id(id) || raise(APIErrors::ParameterInvalid, :attachments)
      end
    end

    # The turn's tool subset, read from the parsed body like `entries`: a
    # list of flat names or nothing. A scalar or a non-string member is a
    # refusal at the parameter boundary, never a narrowing silently dropped
    # — the host decides whether the field is admitted at all.
    def submitted_tool_names
      value = request.request_parameters.dig("input", "tool_names")
      return nil if value.nil?

      names = Array.try_convert(value)
      raise APIErrors::ParameterInvalid, :tool_names unless
        names&.all? { |name| String.try_convert(name) }

      names
    end

    # A fence the caller asked for must FENCE: a mis-typed value that
    # silently dropped or never matched would defeat the very staleness
    # check the caller opted into.
    def expected_revision(fields)
      value = fields[:expected_context_revision]
      return nil if value.nil?

      bounded_integer(value, :expected_context_revision, range: 0..(2**62))
    end

    # A malformed opt-in target must refuse, never disappear through scalar filtering.
    def expected_steering_loop
      value = params.fetch(:input)[:expected_steering_run_public_id]
      return nil if value.nil?
      raise APIErrors::ParameterInvalid, :expected_steering_run_public_id unless ConversationInput.uuid_shaped?(value)

      value.to_s.downcase
    end

    def expected_tail(fields)
      value = fields[:expected_tail_turn_public_id]
      return nil if value.nil?
      raise APIErrors::ParameterInvalid, :expected_tail_turn_public_id unless
        ConversationInput.uuid_shaped?(value)

      value
    end

    # The estimate surface's exact vocabulary. nil means untouched; naming
    # either key replaces the whole stored intent (`history: null` alone clears
    # everything); the closed vocabularies refuse at the body read.
    def submitted_context_options
      history = history_intent(:input)
      replay = reasoning_replay_intent(:input)
      inline = inline_intent(:input)
      variables = variables_intent(:input)
      return nil if history.nil? && replay.nil? && inline.nil? && variables.nil?

      intent = {}
      intent["history"] = history if history.present?
      intent["reasoning_replay"] = replay if replay.present?
      intent["inline"] = inline if inline.present?
      intent["variables"] = variables if variables.present?
      intent
    end

    # An update touches content only when the caller sent some: nil means
    # untouched, matching every other optional change.
    def update_entries(fields)
      raw = Array.try_convert(request.request_parameters.dig("input", "entries"))
      if raw
        unless raw.all? { |element| Hash.try_convert(element) }
          raise APIErrors::ParameterInvalid, :entries
        end

        return raw
      end

      fields[:text].nil? ? nil : [{ "text" => fields[:text] }]
    end

    # `entries` is raw mode's message array, read from the parsed body because
    # Strong Parameters cannot express free-shape hashes; closed to object
    # elements here so a bare scalar is a refusal, not a 500 downstream.
    def submitted_entries(fields)
      raw = Array.try_convert(request.request_parameters.dig("input", "entries"))
      if raw
        unless raw.all? { |element| Hash.try_convert(element) }
          raise APIErrors::ParameterInvalid, :entries
        end

        return raw
      end

      fields[:text].present? ? [{ "text" => fields[:text] }] : []
    end
end
