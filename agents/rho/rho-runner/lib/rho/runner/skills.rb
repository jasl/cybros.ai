require "psych"

module Rho
  class Runner
    # THE RUNNER'S SKILLS: what a checkout's `SKILL.md` files say, read the
    # one way. A skill is a directory
    # holding a `SKILL.md` — YAML frontmatter (`name`, `description`, the
    # rest ignored) over a markdown body — under one of opencode's two
    # external directories, `.agents/skills` and `.claude/skills`, at ONE
    # level on purpose: the agentskills layout is `skills/<name>/SKILL.md`
    # with `name` = the parent directory, and a nested `skills/a/b/SKILL.md`
    # would give one skill two candidate names. No user-scope directory on
    # the machine (`~/.claude/skills`): a person's skills are kernel rows,
    # pushed with `rho skills push`.
    #
    # ONE FRONTMATTER PARSER, `Psych.safe_load` of the `---` block; a file
    # it cannot read is SKIPPED with one `skills.skipped {path, reason}`
    # line — opencode's rule — and an unquoted colon inside a description
    # is the author's to quote. The rules are the agentskills validator's:
    # the name is the DIRECTORY's, a frontmatter `name` that differs, a
    # missing or blank `description`, or a name outside the grammar skips
    # the skill the same way. This module is shared by the runner's scan
    # (the announcement, the `skill` tool) and by rho's `skills push` (the
    # split from `SKILL.md` to path, description, body).
    module Skills
      # The kernel's grammar for a skill name (`Nexus::Skills::NAME_FORMAT`),
      # mirrored so a name the kernel would refuse is never announced or
      # pushed — lowercase alphanumerics and single hyphens, at most 64.
      NAME_FORMAT = /\A[a-z0-9](?:-?[a-z0-9])*\z/
      NAME_MAX_LENGTH = 64
      # The agentskills specification's bound on a description, in bytes.
      DESCRIPTION_MAX_LENGTH = 1024
      DIRECTORIES = %w[.agents/skills .claude/skills].freeze
      FILE_NAME = "SKILL.md".freeze
      FENCE = "---".freeze

      # One skill as its directory states it: the name (the directory's),
      # the one-line-or-more description, the body with the frontmatter
      # stripped, the directory the body's relative paths resolve from, and
      # the 1-indexed line of `SKILL.md` the body starts on — where the
      # `skill` tool's `read` window opens, so its continuation marker names
      # offsets a later `read` of the file can use.
      Skill = Data.define(:name, :description, :body, :dir, :body_line) do
        def path = File.join(dir, FILE_NAME)
      end
      # A `SKILL.md` that is not a skill, and why — the log line's fields.
      Skipped = Data.define(:path, :reason) do
        def skipped? = true
      end

      class << self
        # Every skill under the root's two directories, in directory order
        # then by name; a name met twice keeps the first and logs. Fail-open
        # per file: a skipped skill costs itself, never the list.
        def scan(root:, log: nil)
          found = {}
          DIRECTORIES.each do |directory|
            Dir.glob(File.join(root, directory, "*", FILE_NAME)).sort.each do |path|
              skill = parse(path)
              if skill.is_a?(Skipped)
                log&.warn("skills.skipped", path: skill.path, reason: skill.reason)
              elsif found.key?(skill.name)
                log&.warn("skills.skipped", path: path, reason: "#{skill.name} is already announced from #{found.fetch(skill.name).dir}")
              else
                found[skill.name] = skill
              end
            end
          end
          found.values
        end

        # One directory, as `rho skills push DIR` reads it: the `SKILL.md`
        # inside it, or the reason it is not a skill.
        def read(dir)
          path = File.join(dir, FILE_NAME)
          return Skipped.new(path: path, reason: "no #{FILE_NAME} in #{dir}") unless File.file?(path)

          parse(path)
        end

        # THE SPLIT: frontmatter to (name, description), the rest to the body.
        def parse(path)
          text = File.read(path, encoding: "UTF-8")
          fields, body, body_line = frontmatter(text)
          return Skipped.new(path: path, reason: fields) if fields.is_a?(String)

          name = File.basename(File.dirname(path))
          reason = name_refusal(name, fields["name"]) || description_refusal(fields["description"])
          return Skipped.new(path: path, reason: reason) if reason

          Skill.new(name: name, description: fields.fetch("description").strip, body: body,
            dir: File.dirname(path), body_line: body_line)
        rescue SystemCallError, EncodingError => error
          Skipped.new(path: path, reason: "#{error.class.name}: #{error.message}")
        end

        # THE ONE FRONTMATTER PARSER, public: the `---` block's mapping, the body after it and the
        # 1-indexed line the body starts on — `[fields, body, body_line]`,
        # where `fields` is the reason (a String) when the text has no
        # block, the block is not a mapping, or Psych cannot read it. The
        # skills scan reads it for `SKILL.md`; rho's named-agent scan reads
        # it for `.agents/agents/<name>.md`. No second dialect.
        def frontmatter(text)
          block, body, body_line = split(text)
          return ["no frontmatter block", body, body_line] if block.nil?

          [load_frontmatter(block), body, body_line]
        end

        private

          # `---` on the first line, the block up to the next line that is
          # exactly `---`, the body after it with the line it starts on;
          # nil when there is no block.
          def split(text)
            lines = text.lines
            return [nil, text, 1] unless lines.first&.chomp == FENCE

            close = lines.drop(1).index { |line| line.chomp == FENCE }
            return [nil, text, 1] if close.nil?

            [lines[1, close].join, lines.drop(close + 2).join, close + 3]
          end

          # A mapping, or the reason it is not one.
          def load_frontmatter(frontmatter)
            fields = Psych.safe_load(frontmatter)
            fields.is_a?(Hash) ? fields : "frontmatter is not a mapping"
          rescue Psych::Exception => error
            "frontmatter did not parse: #{error.message.lines.first.to_s.strip}"
          end

          def name_refusal(directory_name, declared)
            return "#{directory_name.inspect} is not a skill name (lowercase alphanumerics and single hyphens, " \
                   "at most #{NAME_MAX_LENGTH})" unless skill_name?(directory_name)
            return nil if declared.nil?
            return "name must be a string" unless declared.is_a?(String)

            "name #{declared.strip.inspect} must match the directory #{directory_name.inspect}" if
              declared.strip != directory_name
          end

          def description_refusal(description)
            return "description is required" if description.nil?
            return "description must be a string" unless description.is_a?(String)
            return "description is required" if description.strip.empty?

            "description exceeds #{DESCRIPTION_MAX_LENGTH} bytes" if
              description.strip.bytesize > DESCRIPTION_MAX_LENGTH
          end

          def skill_name?(name)
            name.length <= NAME_MAX_LENGTH && name.match?(NAME_FORMAT)
          end
      end
    end
  end
end
