# Reusable execution configuration has no member identity or transport address.
# The accepting input owns this value; materialization compiles it for that
# input's real principal and captures the resulting execution authority.
class ExecutionDeclaration
  include StoreModel::Model

  def self.capture(profile, **overrides)
    return if profile.nil? || !profile.agent_member?

    documents = profile.prompt_documents.index_by(&:slot)
    configuration = User::AgentConfiguration::ATTRIBUTES.to_h { |name| [name, profile.public_send(name)] }
    new(**configuration,
      fallback_models: profile.fallback_models || [],
      system_prompt: documents["system_prompt"]&.attributes&.slice("content", "role"),
      summarizer: documents["summarizer"]&.attributes&.slice("content", "role"), **overrides)
  end


  class Document
    include StoreModel::Model

    attribute :content, :string
    attribute :role, :string, default: "system"

    validates :content, exclusion: { in: [nil] }
    validates :role, inclusion: { in: PromptDocument::ROLES }
    validate :content_must_be_bounded

    private

      def content_must_be_bounded
        return if content.nil?

        unless Nexus::SizeBounds.bytes_within?(:prompt_document_bound, content.bytesize)
          errors.add(:content, Nexus::SizeBounds::REJECTION)
        end
        errors.add(:content, :unsupported_text) if content.include?("\u0000")
      end
  end

  attribute :tool_definitions
  attribute :kernel_tools
  attribute :runner_executor_public_ids
  attribute :runner_tool_names
  attribute :approval_mode, :string
  attribute :approval_rules
  attribute :prompt_mechanism, :string
  attribute :prompt_template
  attribute :compaction_policy
  attribute :lifecycle_hooks
  attribute :memory_context_limit
  attribute :conversation_reach, :string
  attribute :default_model, :string
  attribute :fallback_models, default: -> { [] }
  attribute :system_prompt, Document.to_type
  attribute :summarizer, Document.to_type
  attribute :delegation_catalog, Delegation.to_array_type

  validates :tool_definitions, bounded_json: { bound: :tool_definitions_bound, shape: Array }, allow_nil: true
  validates :tool_definitions, tool_declarations: true, allow_blank: true
  validates :kernel_tools, :runner_executor_public_ids, :runner_tool_names, tool_imports: true, allow_nil: true
  validates :approval_mode, inclusion: { in: %w[bypass ask rules] }, allow_nil: true
  validates :approval_mode, presence: true, if: :tool_approval_required?
  validates :approval_rules, bounded_json: { bound: :envelope_bound, shape: Array }, approval_rules: true, allow_nil: true
  validates :prompt_mechanism, inclusion: { in: %w[raw assembly default] }, allow_nil: true
  validates :prompt_template, bounded_json: { bound: :prompt_document_bound, shape: Hash }, prompt_template: true, allow_nil: true
  validates :prompt_template, presence: true, if: -> { prompt_mechanism == "assembly" }
  validates :compaction_policy, bounded_json: { bound: :envelope_bound, shape: Hash }, compaction_policy: true, allow_nil: true
  validates :lifecycle_hooks, bounded_json: { bound: :envelope_bound, shape: Hash }, lifecycle_hooks: true, allow_nil: true
  validates :memory_context_limit, memory_context: { limit: true }
  validates :conversation_reach, inclusion: { in: %w[workspace subtree] }, allow_nil: true
  validates :default_model, length: { maximum: 193 }, allow_nil: true
  validates :fallback_models, model_references: true
  validates :system_prompt, :summarizer, store_model: true, allow_nil: true
  validates :delegation_catalog, store_model: true, delegation_catalog: true, allow_nil: true
  validate :default_model_is_complete
  validate :prompt_macros_are_declared

  def declared_variable_names
    prompt_mechanism == "assembly" ? PromptTemplate.parse(prompt_template).variable_names : []
  end

  # An accepted turn keeps exactly the tools compiled for it. Edits and forks
  # can regenerate without importing tools that its input deliberately omitted.
  # Concrete Runner routes still pass the live eligibility checks on later use.
  def with_tools(definitions, approval_mode: self.approval_mode)
    self.class.new(attributes.merge("tool_definitions" => definitions, "kernel_tools" => nil,
      "runner_tool_names" => [], "approval_mode" => approval_mode))
  end

  def tool_approval_required?
    tool_definitions.present? || kernel_tools.present? || lifecycle_hooks.present? ||
      (runner_executor_public_ids.present? && runner_tool_names != [])
  end

  private

    def default_model_is_complete
      errors.add(:default_model, :invalid) if default_model.present? && !Nexus::ModelRef.parse(default_model).complete?
    end

    def prompt_macros_are_declared
      return if system_prompt.nil? || errors.include?(:prompt_template) || errors.include?(:system_prompt)

      unknown = Nexus::PromptMacros.unknown(system_prompt.content,
        Nexus::PromptMacros::REGISTRY + declared_variable_names)
      errors.add(:system_prompt, :invalid) if unknown
    end
end
