module Rho
  # Installed extensions register their own definitions. Portable authored
  # configuration is imported through AgentPresets and creates no identity.
  module Agents
    NAME_FORMAT = /\A[a-z0-9][a-z0-9_-]{1,31}\z/
    NAME_RULE = "lowercase alphanumerics, `_` and `-`, 2 to 32 characters, starting with a letter or digit".freeze
    INFER_RUNNER_TOOLS = Object.new.freeze

    Definition = Data.define(:name, :description, :tools, :model, :body, :path, :ignored_keys, :prompt_template, :display_name, :audience, :runner_tool_names) do
      def initialize(prompt_template: nil, display_name: nil, audience: nil, runner_tool_names: INFER_RUNNER_TOOLS, **) = super
    end
  end
end
