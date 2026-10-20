# The accepting input owns the execution declaration and its captured conditions.
# Materialization compiles it for the input's real principal; executor contexts
# select values for existing addresses without granting execution authority.
class AgentConfiguration
  include StoreModel::Model

  def self.capture(agent, **overrides)
    return if agent.nil? || !agent.agent_member?

    documents = agent.prompt_documents.index_by(&:slot)
    configuration = User::Configurable::ATTRIBUTES.to_h { |name| [name, agent.public_send(name)] }
    new(**configuration,
      fallback_models: agent.fallback_models || [],
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

  # Execution captures only; this field is not part of User::Configurable.
  attribute :executor_contexts
  validate { errors.add(:executor_contexts, :invalid) if executor_contexts && !Nexus::ExecutorContexts.valid?(executor_contexts) }

  def executor_contexts=(value)
    super(Nexus::ExecutorContexts.valid?(value) ? Nexus::ExecutorContexts.normalize(value) : value)
  end

  attribute :tool_definitions
  attribute :kernel_tools
  attribute :runner_executor_public_ids
  attribute :mcp_tools
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
  attribute :image_model, :string
  attribute :fallback_models, default: -> { [] }
  attribute :system_prompt, Document.to_type
  attribute :summarizer, Document.to_type
  attribute :delegation_catalog, Delegation.to_array_type

  validates :tool_definitions, bounded_json: { bound: :tool_definitions_bound, shape: Array }, allow_nil: true
  validates :tool_definitions, tool_declarations: true, allow_blank: true
  validates :kernel_tools, :runner_executor_public_ids, :runner_tool_names, :mcp_tools, tool_imports: true, allow_nil: true
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
  validates :default_model, :image_model, length: { maximum: 193 }, allow_nil: true
  validates :fallback_models, model_references: true
  validates :system_prompt, :summarizer, store_model: true, allow_nil: true
  validates :delegation_catalog, store_model: true, delegation_catalog: true, allow_nil: true
  validate :model_references_are_complete
  validate :prompt_macros_are_declared

  def declared_variable_names
    prompt_mechanism == "assembly" ? PromptTemplate.parse(prompt_template).variable_names : []
  end

  # An accepted turn keeps exactly the tools compiled for it. Edits and forks
  # can regenerate without importing tools that its input deliberately omitted.
  # Concrete Runner and MCP routes still pass live eligibility checks on later use.
  def with_tools(definitions, approval_mode: self.approval_mode)
    self.class.new(attributes.merge("tool_definitions" => definitions, "kernel_tools" => nil,
      "runner_tool_names" => [], "mcp_tools" => [], "approval_mode" => approval_mode))
  end

  def tool_approval_required?
    tool_definitions.present? || kernel_tools.present? || mcp_tools.present? || lifecycle_hooks.present? ||
      (runner_executor_public_ids.present? && runner_tool_names != [])
  end

  private

    def model_references_are_complete
      errors.add(:default_model, :invalid) if default_model.present? && !Nexus::ModelRef.parse(default_model).complete?
      errors.add(:image_model, :invalid) if image_model.present? && !Nexus::ModelRef.parse(image_model).complete?
    end

    def prompt_macros_are_declared
      return if system_prompt.nil? || errors.include?(:prompt_template) || errors.include?(:system_prompt)

      unknown = Nexus::PromptMacros.unknown(system_prompt.content,
        Nexus::PromptMacros::REGISTRY + declared_variable_names)
      errors.add(:system_prompt, :invalid) if unknown
    end
end
