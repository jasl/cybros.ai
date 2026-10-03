# The Agent Profile's standing declaration: what it serves, how its tool
# calls are approved, how a turn is assembled, the model it answers on
# when nothing else names one, and the model a step it answers re-runs on
# once when a provider's classifier declined it — written whole by one
# verb and read once at each turn's materialization (the fallback live,
# at the switch). Humans and the system user declare nothing.
module User::AgentConfiguration
  extend ActiveSupport::Concern

  APPROVAL_MODES = %w[bypass ask rules].freeze
  PROMPT_MECHANISMS = %w[raw assembly default].freeze
  ATTRIBUTES = %i[
    tool_definitions approval_mode approval_rules prompt_mechanism prompt_template compaction_policy default_model
    lifecycle_hooks fallback_model
  ].freeze

  included do
    validates(*ATTRIBUTES, absence: true, if: -> { human? || system? })
    validates :approval_mode, inclusion: { in: APPROVAL_MODES }, allow_nil: true
    # Both model-visible tools and lifecycle hooks use tool approval.
    # Their profile must declare the policy rather than assume a default.
    validates :approval_mode, presence: true, if: -> {
      agent_member? && (tool_definitions.present? || lifecycle_hooks.present?)
    }
    # The fifth column: the rule list under the one grammar (Executors::Rules).
    validates :approval_rules, bounded_json: { bound: :envelope_bound, shape: Array },
      approval_rules: true, allow_nil: true
    validates :prompt_mechanism, inclusion: { in: PROMPT_MECHANISMS }, allow_nil: true
    # The sixth column: the template `assembly` compiles, under the grammar
    # of PromptTemplate. The same no-silent-default rule as the approval
    # mode: `assembly` ⇒ a template, a single-row invariant — so no
    # drain-time park for a vanished template, and a template on a
    # `default` profile is stored unread.
    validates :prompt_template, bounded_json: { bound: :prompt_document_bound, shape: Hash },
      prompt_template: true, allow_nil: true
    validates :prompt_template, presence: true, if: -> { agent_member? && prompt_mechanism == "assembly" }
    validate :slot_macros_stay_declared, if: -> { agent_member? && (prompt_template_changed? || prompt_mechanism_changed?) }
    validates :tool_definitions, bounded_json: { bound: :envelope_bound, shape: Array },
      tool_declarations: true, allow_nil: true
    validates :compaction_policy, bounded_json: { bound: :envelope_bound, shape: Hash },
      compaction_policy: true, allow_nil: true
    validates :lifecycle_hooks, bounded_json: { bound: :envelope_bound, shape: Hash },
      lifecycle_hooks: true, allow_nil: true
  end

  # The variable names a slot document or a turn may use beside the four
  # sources: the template's, and only while `assembly` stands — under
  # `default` the template is unread, so its names are no registry.
  def declared_variable_names
    return [] unless prompt_mechanism == "assembly"

    PromptTemplate.parse(prompt_template).variable_names
  end

  private

    # The authoring-order hole closed at the one writer: the profile's own
    # `system_prompt` was written against the names of its day; a
    # re-declaration that drops one it still uses would render literal
    # braces at the next turn, so it is refused naming the slot.
    def slot_macros_stay_declared
      return if errors.include?(:prompt_template) || errors.include?(:prompt_mechanism)

      document = prompt_documents.find_by(slot: "system_prompt")
      return if document.nil?

      name = Nexus::PromptMacros.unknown(document.content,
        Nexus::PromptMacros::REGISTRY + declared_variable_names)
      errors.add(:prompt_template, :variable_in_use, name: name, slot: document.slot) if name
    end
end
