module Nexus
  # Built-in macro names are substituted by one gsub at compilation,
  # alongside any variables declared by the profile's template. Unknown
  # names are refused at the input boundary so typos do not reach the model
  # as literal braces. `{{history}}` is an assembly block, not a macro;
  # `char` has no built-in source. Names use `[a-z][a-z0-9_]*`, including
  # digit-bearing declared variables.
  module PromptMacros
    REGISTRY = %w[agent user workspace date conversation_kind].freeze
    PATTERN = /\{\{\s*([a-z][a-z0-9_]*)\s*\}\}/

    module_function

    # The first name outside the registry, else nil. A host with declared
    # variables widens the registry it checks against.
    def unknown(text, registry = REGISTRY)
      text.to_s.scan(PATTERN).flatten.find { |name| !registry.include?(name) }
    end

    # `sources` maps each name to its value; a nil value renders empty,
    # never the braces.
    def render(text, sources)
      text.to_s.gsub(PATTERN) do |match|
        name = Regexp.last_match(1)
        sources.key?(name) ? sources.fetch(name).to_s : match
      end
    end
  end
end
