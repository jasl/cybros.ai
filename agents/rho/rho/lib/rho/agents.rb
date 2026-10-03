require "rho/runner"

module Rho
  # Named definitions come from committed extensions or local files. A file
  # is YAML frontmatter over a markdown body, read through the skills'
  # ONE parser (`Rho::Runner::Skills.frontmatter`) under the skills' two
  # directories at ONE level — `.agents/agents` then `.claude/agents` —
  # at the daemon's environment root; a file that is not a definition is
  # SKIPPED with one log line, a name met twice keeps the first. No
  # user-scope directory on the machine: the durable form is a kernel
  # row, `rho agents publish`.
  #
  # The keys: `name` (the frontmatter's when present, else the basename,
  # normalized `strip.downcase`, then the kernel's HANDLE grammar);
  # `description` (required, squished to one line, at most the kernel's
  # 1024 characters); `tools` (optional: a list or a comma-separated
  # string of names, read RAW — the narrowing is `LoopRequest
  # .derived_declaration`'s); `model` (a catalog ref; `inherit` means
  # absent); `fallback_model` (a catalog ref, the same reading — the model
  # a step the row answers re-runs on once when a provider declined it;
  # what an absent one means is the derived declaration's); `prompt_template`
  # optionally selects the kernel's assembly mechanism; the BODY is
  # the row's `system_prompt`. Every other key is logged as ignored, never
  # refused: a definition written for another harness loads with what
  # matches.
  module Agents
    # `User::Handle::FORMAT`, mirrored: a name the kernel would refuse as
    # a handle is never declared.
    NAME_FORMAT = /\A[a-z0-9][a-z0-9_-]{1,31}\z/
    NAME_RULE = "lowercase alphanumerics, `_` and `-`, 2 to 32 characters, starting with a letter or digit".freeze
    DIRECTORIES = %w[.agents/agents .claude/agents].freeze
    # The kernel's bound on a profile's description, in characters.
    DESCRIPTION_MAX_LENGTH = 1024
    KEYS = %w[name description tools model fallback_model prompt_template].freeze
    # claude-code's default `model`: the initiator's, which is absent here.
    INHERIT = "inherit".freeze
    EXTENSION = ".md".freeze

    # One definition as its file states it. `tools` is nil (absent: the
    # whole universe), `[]` (none) or the names listed; `model` and
    # `fallback_model` nil or the ref; `body` nil when empty (no slot);
    # `ignored_keys` the keys logged.
    Definition = Data.define(:name, :description, :tools, :model, :fallback_model, :body, :path, :ignored_keys, :prompt_template) do
      def initialize(fallback_model: nil, prompt_template: nil, **) = super
    end
    # A file that is not a definition, and why — the log line's fields and
    # `rho agents`' `skipped:` lines.
    Skipped = Data.define(:path, :reason) do
      def skipped? = true
    end
    # The scan's whole answer: the definitions in directory order then by
    # file name, and every file skipped.
    Scan = Data.define(:definitions, :skipped) do
      def self.none = new(definitions: [].freeze, skipped: [].freeze)
      def empty? = definitions.empty? && skipped.empty?
      def names = definitions.map(&:name)
      def find(name) = definitions.find { |definition| definition.name == name }
    end

    class << self
      # Extensions own their registered names. Files follow in directory
      # order; a nil root still returns registered definitions. Fail-open per file.
      def scan(root:, log: nil, definitions: [])
        found = definitions.to_h { |definition| [definition.name, definition] }
        skipped = []
        return Scan.new(definitions: found.values.freeze, skipped: skipped.freeze) if root.nil?

        DIRECTORIES.each do |directory|
          Dir.glob(File.join(root, directory, "*#{EXTENSION}")).sort.each do |path|
            next unless File.file?(path)

            outcome = admit(parse(path), found, log)
            skipped << outcome if outcome.is_a?(Skipped)
          end
        end
        Scan.new(definitions: found.values.freeze, skipped: skipped.freeze)
      end

      # One file to a Definition, or the reason it is not one.
      def parse(path)
        text = File.read(path, encoding: "UTF-8")
        fields, body, = Rho::Runner::Skills.frontmatter(text)
        return Skipped.new(path: path, reason: fields) if fields.is_a?(String)

        build(path, fields.transform_keys(&:to_s), body)
      rescue SystemCallError, EncodingError => error
        Skipped.new(path: path, reason: "#{error.class.name}: #{error.message}")
      end

      private

        # The first-wins rule, and the one log line per skipped file or
        # per file with keys nobody reads.
        def admit(parsed, found, log)
          if parsed.is_a?(Skipped)
            log&.warn("agents.skipped", path: parsed.path, reason: parsed.reason)
            return parsed
          end
          if found.key?(parsed.name)
            skipped = Skipped.new(path: parsed.path,
              reason: "#{parsed.name} is already defined by #{found.fetch(parsed.name).path}")
            log&.warn("agents.skipped", path: skipped.path, reason: skipped.reason)
            return skipped
          end

          log&.info("agents.ignored_keys", path: parsed.path, keys: parsed.ignored_keys) unless parsed.ignored_keys.empty?
          found[parsed.name] = parsed
        end

        def build(path, fields, body)
          name = name_of(path, fields["name"])
          reason = name_refusal(name) || description_refusal(fields["description"]) ||
            tools_refusal(fields["tools"]) || model_refusal("model", fields["model"]) ||
            model_refusal("fallback_model", fields["fallback_model"])
          return Skipped.new(path: path, reason: reason) if reason

          template = fields["prompt_template"]
          template = Hash(template) unless template.nil?
          Definition.new(
            name: name, description: squish(fields.fetch("description")), tools: tools_of(fields["tools"]),
            model: model_of(fields["model"]), fallback_model: model_of(fields["fallback_model"]),
            body: body.strip.then { |text| text.empty? ? nil : text },
            prompt_template: template,
            path: path, ignored_keys: (fields.keys - KEYS).freeze
          )
        rescue TypeError
          Skipped.new(path: path, reason: "prompt_template must be an object")
        end

        # The frontmatter's `name` when present, else the basename without
        # `.md`; normalized — a mismatch between the two is never a refusal.
        def name_of(path, declared)
          raw = declared.nil? ? File.basename(path, EXTENSION) : declared
          raw.to_s.strip.downcase
        end

        def name_refusal(name)
          "#{name.inspect} is not an agent name (#{NAME_RULE})" unless name.match?(NAME_FORMAT)
        end

        def description_refusal(description)
          return "description is required" if description.nil?
          return "description must be a string" unless description.is_a?(String)
          return "description is required" if description.strip.empty?

          "description exceeds #{DESCRIPTION_MAX_LENGTH} characters" if squish(description).length > DESCRIPTION_MAX_LENGTH
        end

        # A list of names or a comma-separated string; anything else is
        # the author's to fix, never guessed at.
        def tools_refusal(tools)
          return nil if tools.nil? || tools.is_a?(String)
          return nil if tools.is_a?(Array) && tools.all? { |name| name.is_a?(String) }

          "tools must be a list of names or a comma-separated string"
        end

        def model_refusal(key, model)
          "#{key} must be a string" unless model.nil? || model.is_a?(String)
        end

        def tools_of(tools)
          return nil if tools.nil?

          names = tools.is_a?(String) ? tools.split(",") : tools
          names.map(&:strip).reject(&:empty?).freeze
        end

        def model_of(model)
          ref = model.to_s.strip
          ref.empty? || ref == INHERIT ? nil : ref
        end

        # Whitespace runs to one space: one printable line.
        def squish(text) = text.split.join(" ")
    end
  end
end
