module Executors
  # THE ONE RULE MODEL:
  # opencode's flat triple — a tool glob, a dotted path into `tool_input`,
  # an anchored glob, a verdict — with codex/claude-code's strictness
  # (deny > ask > allow). The kernel interprets no tool argument:
  # the path is the AGENT's, this module reads
  # `tool_input` as opaque JSON through it and never learns what `bash` is.
  #
  # One rule is a Hash of at most six keys: `tool` (required; `|`-separated
  # anchored globs over the wire `tool_name`), `verdict` (required;
  # `allow|ask|deny`), `path` (optional; `command`, `edits.0.path` — a Hash
  # is walked by key, an Array by integer index, anything else answers
  # nil), `match` (optional, needs `path`; an ANCHORED glob over the text
  # at the path), `reason` (optional; a denial's `error_detail`), `origin`
  # (optional, `model|author|kernel`, default `model`: which writer's rows
  # the rule addresses). Only `*` and `?` are special in a glob; every
  # other byte is literal, and `*` crosses a newline. The text at a path: a
  # String as-is; an Array of scalars joined by ONE space; nil, a Hash, a
  # nested Array or a scalar alone NEVER match — and under `bypass` a
  # non-match is a grant, which the doc says out loud. A rule with no
  # `path` matches the tool as a whole; one with a `path` and no `match`
  # matches when there is text at the path.
  #
  # The verdict collects every matching rule: deny wins, then ask, then
  # allow, the FIRST deny's reason riding; unmatched answers a nil word
  # and the mode decides (`rules` refuses it as data).
  module Rules
    KEYS = %w[tool path match verdict reason origin].freeze
    VERDICTS = %w[allow ask deny].freeze
    DEFAULT_ORIGIN = "model".freeze

    Verdict = Data.define(:word, :reason) do
      def deny? = word == "deny"
      def ask? = word == "ask"
      def allow? = word == "allow"
    end
    UNMATCHED = Verdict.new(word: nil, reason: nil)

    # A declaration-time refusal: the code names the rule's fault; `key`
    # rides on `unknown_key` alone, so the message can name the stranger.
    Refusal = Data.define(:code, :key) do
      def self.of(code, key: nil) = new(code: code, key: key)
    end

    module_function

    def verdict(rules, tool_name:, tool_input:, origin:)
      matching = Array(rules).select { |rule| applies?(rule, tool_name, tool_input, origin) }
      return UNMATCHED if matching.empty?

      denial = matching.find { |rule| rule["verdict"] == "deny" }
      return Verdict.new(word: "deny", reason: denial["reason"]) if denial

      word = matching.any? { |rule| rule["verdict"] == "ask" } ? "ask" : "allow"
      Verdict.new(word: word, reason: nil)
    end

    # nil for a well-formed list (nil and `[]` are "no rules"), else the
    # first rule's first fault — the validator adds it by name.
    def refusal(value)
      return nil if value.nil?

      rules = Array.try_convert(value)
      return Refusal.of(:not_a_list) if rules.nil?

      rules.each do |rule|
        fault = rule_refusal(rule)
        return fault if fault
      end
      nil
    end

    def applies?(rule, tool_name, tool_input, origin)
      return false unless (rule["origin"] || DEFAULT_ORIGIN) == origin
      return false unless Glob.tool?(rule["tool"], tool_name)
      return true unless rule.key?("path")

      text = Value.text(Path.walk(tool_input, rule["path"]))
      return false if text.nil?

      !rule.key?("match") || Glob.compile(rule["match"]).match?(text)
    end

    def rule_refusal(rule)
      return Refusal.of(:not_an_object) if Hash.try_convert(rule).nil?

      stranger = rule.keys.find { |key| !KEYS.include?(key) }
      return Refusal.of(:unknown_key, key: stranger.to_s) if stranger
      return Refusal.of(:tool_required) unless Glob.tool_alternatives?(rule["tool"])
      return Refusal.of(:verdict_invalid) unless VERDICTS.include?(rule["verdict"])
      return Refusal.of(:origin_invalid) if rule.key?("origin") && !AgentRunTask::AUTHORS.include?(rule["origin"])
      return Refusal.of(:match_without_path) if rule.key?("match") && !rule.key?("path")
      return Refusal.of(:path_invalid) if rule.key?("path") && !Path.valid?(rule["path"])
      return Refusal.of(:glob_invalid) unless Glob.tool_pattern?(rule["tool"])
      return Refusal.of(:glob_invalid) if rule.key?("match") && !Glob.pattern?(rule["match"])
      return Refusal.of(:reason_invalid) if rule.key?("reason") && String.try_convert(rule["reason"]).nil?

      nil
    end

    # The glob: `*` is `.*`, `?` is `.`, everything else escaped; anchored
    # both ends; MULTILINE so `*` crosses a newline inside a command.
    module Glob
      module_function

      def compile(pattern)
        escaped = pattern.split(/([*?])/).map do |piece|
          case piece
          when "*" then ".*"
          when "?" then "."
          else Regexp.escape(piece)
          end
        end.join
        Regexp.new("\\A#{escaped}\\z", Regexp::MULTILINE)
      end

      def pattern?(value)
        text = String.try_convert(value)
        !text.nil? && compile(text.encode(Encoding::UTF_8)) && true
      rescue RegexpError, ArgumentError, EncodingError
        false
      end

      # `|`-separated alternatives, each non-empty ...
      def tool_alternatives?(value)
        text = String.try_convert(value)
        !text.nil? && !text.empty? && text.split("|", -1).none?(&:empty?)
      end

      # ... and each a glob that compiles.
      def tool_pattern?(value)
        value.split("|", -1).all? { |name| pattern?(name) }
      end

      def tool?(pattern, tool_name)
        pattern.split("|").any? { |alternative| compile(alternative).match?(tool_name.to_s) }
      end
    end

    # The dotted key path: a Hash by key, an Array by integer index,
    # anything else — a leaf, nil — walks nowhere.
    module Path
      INDEX = /\A\d+\z/

      module_function

      def valid?(path)
        text = String.try_convert(path)
        !text.nil? && !text.empty? && text.split(".", -1).none?(&:empty?)
      end

      def walk(input, path)
        path.split(".").reduce(input) do |value, segment|
          case value
          when Hash then value[segment]
          when Array then INDEX.match?(segment) ? value[segment.to_i] : nil
          else nil
          end
        end
      end
    end

    # What a glob reads at a path: a String, or a scalar Array joined by
    # one space; nothing else is text.
    module Value
      module_function

      def text(value)
        case value
        when String then value
        when Array
          parts = value.map { |item| scalar_text(item) }
          parts.join(" ") if parts.none?(&:nil?)
        else nil
        end
      end

      # A scalar as text; anything else — a Hash, an Array, nil — is not text.
      def scalar_text(item)
        case item
        when String then item
        when Numeric, true, false then item.to_s
        else nil
        end
      end
    end
  end
end
