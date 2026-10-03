module Rho
  module LoopRequest
    # THE SESSION-SCOPED APPROVAL GRANT: `rho
    # approve LOOP KEY --always [--match PREFIX]` approves the held call
    # AND grants its shape for the rest of this daemon's life — one allow
    # rule in the kernel's own grammar (`Executors::Rules`: a tool, a
    # dotted path into `tool_input`, an anchored glob), appended to rho's
    # declared `approval_rules` and re-declared (`Daemon::Loops::Bindings`).
    #
    # The record: the rule the kernel sees, and the provenance `rho rules`
    # prints — the loop and the key it was made on, the conversation when
    # the loop backed one, the time. The kernel sees `rule` alone.
    Grant = Data.define(:rule, :loop, :task_key, :conversation, :granted_at)

    class Grant
      # The kernel's `envelope_bound` on the declared list (the SDK's
      # constant; `lib/nexus/size_bounds.rb`): `rho rules` prints the
      # declared size against it. Never enforced here — the kernel's
      # refusal relays as itself (no second ceiling).
      DECLARED_BOUND = CybrosAgent::SizeBounds::ENVELOPE_BOUND

      # THE DERIVATION — exactly TWO shapes:
      #
      # A TEXT-KEYED TOOL, the tools rho guards by one text argument under
      # rho's own argument names: `bash`/`start_process` on `command`
      # (`GUARDED_TOOLS`; the Guard reads the same key), `write`/`edit` on
      # `path` (`EDIT_TOOLS`; the runner's tools). Exact by default — the
      # RAW bytes, byte for byte (codex's letter; a re-quoted argument or a
      # trailing newline re-parks; no canonicalization, no whitespace
      # normalization — accepted, S28). A held text carrying `*` or `?` is
      # REFUSED exact: an "exact" grant that is silently a glob would be the
      # wider reading. `match:` grants a word-bounded PREFIX instead:
      # `"PREFIX *"` for a command (claude-code's `Bash(prefix:*)`,
      # opencode's `prefix + " *"`), `"PREFIX/*"` for a path (claude-code's
      # `addDirectories`) — the held text must continue past the prefix
      # with that separator, the prefix is literal (no wildcard, not blank;
      # a trailing separator is accepted stripped).
      #
      # EVERY OTHER TOOL (a kernel verb, an `mcp__server__tool`, a read) is
      # granted whole — the coding pair's MCP shape; `match:` is refused.
      #
      # Neither shape names a `reason` or an `origin`: the default `model`
      # is the writer the mode governs. The width is the grammar's: a prefix is raw text with no shell in it.
      TEXT_KEYS = {
        "bash" => "command", "start_process" => "command",
        "write" => "path", "edit" => "path",
      }.freeze
      SEPARATORS = { "command" => " ", "path" => "/" }.freeze
      WILDCARD = /[*?]/
      VERDICT = "allow".freeze

      # A derivation refusal: the sentence the route answers as 400
      # `malformed_body`, before anything moves.
      Refusal = Data.define(:message)

      class << self
        # The key a tool is granted on, or nil for a whole-tool grant.
        def text_key(tool_name) = TEXT_KEYS[tool_name.to_s]

        # The rule, or a `Refusal` — the five public validation messages, and the encoding check
        # (decisions R): a held text that is not valid UTF-8 would cost the WHOLE declaration
        # (`glob_invalid`), so it is refused here.
        def rule(tool_name:, tool_input:, match: nil)
          key = text_key(tool_name)
          return whole(tool_name, match) if key.nil?

          text = tool_input&.fetch(key, nil)
          no_text = Refusal.new(message: "the held call carries no #{key} text to key a grant on")
          return no_text unless text.is_a?(String)
          return Refusal.new(message: "the held #{key} is not valid UTF-8 text; the kernel would refuse the whole " \
                                      "rule list (glob_invalid)") unless text.valid_encoding?
          return no_text if text.strip.empty?

          match.nil? ? exact(tool_name, key, text) : prefix(tool_name, key, text, match)
        end

        private

          def whole(tool_name, match)
            return Refusal.new(message: "--match narrows a text-keyed tool (#{TEXT_KEYS.keys.join(", ")}); " \
                                        "#{tool_name} is granted whole") unless match.nil?

            { "tool" => tool_name, "verdict" => VERDICT }.freeze
          end

          def exact(tool_name, key, text)
            return Refusal.new(message: "the held #{key} contains * or ?, which the kernel reads as wildcards; " \
                                        "grant a prefix with --match instead") if WILDCARD.match?(text)

            { "tool" => tool_name, "path" => key, "match" => text, "verdict" => VERDICT }.freeze
          end

          def prefix(tool_name, key, text, match)
            separator = SEPARATORS.fetch(key)
            prefix = match.to_s.chomp(separator)
            return Refusal.new(message: "--match is literal text and cannot be blank; the kernel reads * and ? as " \
                                        "wildcards") if prefix.strip.empty? || WILDCARD.match?(prefix)
            return Refusal.new(message: "--match must be a whole-token prefix of the held #{key}, followed by " \
                                        "#{separator.inspect}: #{text.inspect}") unless text.start_with?("#{prefix}#{separator}")

            { "tool" => tool_name, "path" => key, "match" => "#{prefix}#{separator}*", "verdict" => VERDICT }.freeze
          end
      end
    end
  end
end
