# THE REPLY LANE'S OWN RULES: what a `direct_reply` may carry that a
# message may not — the verbatim mode, its system field, the turn's tool
# subset and its approval tightening — and the fence shapes a caller's
# freshness rides on.
module ConversationInput::Validation
  extend ActiveSupport::Concern

  # THE TURN'S TIGHTENING: each step up removes a grant path — `ask`
  # removes the mode grant, `rules` removes the park — so the order is
  # monotone in strictness and the input may only climb it.
  APPROVAL_RANK = { "bypass" => 0, "ask" => 1, "rules" => 2 }.freeze

  included do
    validate :raw_mode_belongs_to_the_reply_lane
    # The turn's tool subset: the declaring profile's set narrowed by NAME on
    # the reply lane — a subset, never an addition — so the turn's tools ride
    # the input beside its model.
    validate :tool_names_narrow_the_declaration
    # The turn's approval tightening (the `tool_names` precedent): the
    # declaring profile's word made stricter for this reply, never looser,
    # frozen onto the loop row at materialization.
    validate :approval_mode_tightens_the_declaration
    # `raw`'s system field: the one field of the raw grammar outside
    # `entries`, on the reply lane alone; an assembled input's system text is
    # its slots and its inline lead — the list, never this column.
    validate :instructions_belong_to_raw
    validate :steps_belong_to_queued_replies
    validate :uuid_fences_must_parse
  end

  private

    # A message IS content; only the reply lane compiles a prompt, so only
    # it has a compile step to skip.
    def raw_mode_belongs_to_the_reply_lane
      return unless context_mode == "raw" && kind != "direct_reply"

      errors.add(:context_mode, :invalid)
    end

    def instructions_belong_to_raw
      return if instructions.nil?
      return if raw? && kind == "direct_reply"

      errors.add(:instructions, :invalid)
    end

    # These are deferred authored work, not message content or a steer into
    # existing execution. Empty arrays clear a queued reply's previous work.
    def steps_belong_to_queued_replies
      return if steps.nil?
      return if host&.hosts_turns? && kind == "direct_reply" && delivery_mode == "queue"

      errors.add(:steps, :invalid)
    end

    # nil is the whole declaration; an EMPTY list is no tools at all — a
    # reply from context alone under the declaring profile's engine. A
    # list names each declared tool at most once — a name the declaring
    # profile does not declare is refused WITH the name, the same
    # sentence a branch reads (`BranchTools.not_a_tool`) — and a
    # message, which compiles no request, has nothing to narrow.
    def tool_names_narrow_the_declaration
      return if tool_names.nil?
      return unless new_record? || will_save_change_to_tool_names?

      return errors.add(:tool_names, :invalid) if kind != "direct_reply"

      names = Array(tool_names)
      unless names.none?(&:blank?) && names.uniq.length == names.length
        return errors.add(:tool_names, :invalid)
      end
      return if names.empty?

      # Inspect the compiled surface; automatic imports have no stored schema
      # on the profile. The materializer repeats the read when this row drains.
      assembly = tool_assembly(tool_names: nil)
      return errors.add(:tool_names, assembly.refusal) if assembly.refused?

      missing = Nexus::ToolDeclarations.undeclared(assembly.definitions, names)
      errors.add(:tool_names, :not_declared, name: missing) if missing
    end

    # nil is the profile's word. A word outside the vocabulary is refused
    # as such; a message, which compiles no request, has nothing to
    # tighten; a profile that declared no mode leaves nothing to tighten,
    # and a rank below the profile's would loosen it.
    def approval_mode_tightens_the_declaration
      return if approval_mode.nil?
      return errors.add(:approval_mode, :invalid) if kind != "direct_reply"
      return errors.add(:approval_mode, :inclusion) unless APPROVAL_RANK.key?(approval_mode)

      declared = APPROVAL_RANK[declaring_profile&.approval_mode]
      # A tool-less receipt retains the actual originating loop's mode;
      # no effect is granted by its otherwise empty approval shell.
      return if kernel_origin? && declared.nil? && !declaring_profile&.tool_approval_required?

      return errors.add(:approval_mode, :not_tightening) if declared.nil? || APPROVAL_RANK[approval_mode] < declared

      nil
    end

    # PostgreSQL's uuid cast silently nils a malformed string, which would
    # DELETE a caller's freshness fence instead of refusing it: a raw value
    # that casts to nothing is an error, never an absence.
    def uuid_fences_must_parse
      %i[expected_tail_turn_public_id sender_conversation_public_id].each do |column|
        raw = read_attribute_before_type_cast(column)
        next if raw.nil? || public_send(column).present?

        errors.add(column, :invalid)
      end
    end
end
