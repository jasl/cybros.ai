require "uri"

module Rho
  module RunDeclaration
    # THE SESSION-SCOPED APPROVAL GRANT: `rho
    # approve RUN KEY --always [--match PREFIX]` approves the held call
    # AND grants its shape for the rest of this daemon's life — one allow
    # rule in the kernel's own grammar (`Executors::Rules`: a tool, a
    # dotted path into `tool_input`, an anchored glob), appended to rho's
    # declared `approval_rules` and re-declared (`Daemon::HostFollowers::Bindings`).
    #
    # The record: the rule the kernel sees, and the provenance `rho rules`
    # prints — the run and the key it was made on, the conversation when
    # the run backed one, the time. The kernel sees `rule` alone.
    Grant = Data.define(:rule, :run_public_id, :task_key, :conversation, :granted_at)

    class Grant
      # The kernel's `envelope_bound` on the declared list (the SDK's
      # constant; `lib/nexus/size_bounds.rb`): `rho rules` prints the
      # declared size against it. Never enforced here — the kernel's
      # refusal relays as itself (no second ceiling).
      DECLARED_BOUND = CybrosAgent::SizeBounds::ENVELOPE_BOUND

      # The derivation keeps each tool's approval scope in rho:
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
      # `web_fetch` grants the held URL's literal scheme and authority,
      # ending in `/*`. `match:` may name that same site with an optional
      # trailing slash. A bare root is approved once by the caller, but
      # subsequent URLs without the slash need another decision. Alternate
      # host, scheme and port spellings are never silently widened.
      #
      # EVERY OTHER TOOL (a kernel verb, an `mcp__server__tool`, a read) is
      # granted whole — the coding pair's MCP shape; `match:` is refused.
      #
      # No grant names a `reason` or an `origin`: the default `model`
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
        def text_key(tool_name)
          tool_name.to_s == "web_fetch" ? "url" : TEXT_KEYS[tool_name.to_s]
        end

        # The rule, or a `Refusal`: a held text that is not valid UTF-8
        # would cost the whole declaration (`glob_invalid`), so it is
        # refused before the approval is sent.
        def rule(tool_name:, tool_input:, match: nil)
          key = text_key(tool_name)
          return whole(tool_name, match) if key.nil?

          text = held_text(tool_input, key)
          return text if text in Refusal

          if key == "url"
            site(tool_name, text, match)
          else
            match.nil? ? exact(tool_name, key, text) : prefix(tool_name, key, text, match)
          end
        end

        private

          def held_text(tool_input, key)
            text = String.try_convert(tool_input&.fetch(key, nil))
            no_text = Refusal.new(message: "the held call carries no #{key} text to key a grant on")
            return no_text if text.nil?
            return Refusal.new(message: "the held #{key} is not valid UTF-8 text; the kernel would refuse the whole " \
                                        "rule list (glob_invalid)") unless text.valid_encoding?

            text.strip.empty? ? no_text : text
          end

          def site(tool_name, text, match)
            invalid = Refusal.new(message: "the held url must be an HTTP(S) URL with a host, no credentials " \
                                          "and no wildcards in its authority")
            # URI.split retains explicit default/zero-padded ports and the
            # scheme's case. Rebuilding a URI would normalize bytes the
            # kernel's literal matcher must continue to distinguish.
            scheme, userinfo, host, port = URI.split(text)
            authority = port.nil? ? host.to_s : "#{host}:#{port}"
            return invalid unless %w[http https].include?(scheme.to_s.downcase) && !host.to_s.empty? &&
                                  userinfo.nil? && !WILDCARD.match?(authority)

            origin = "#{scheme}://#{authority}"
            unless match.nil? || match == origin || match == "#{origin}/"
              return Refusal.new(message: "--match for web_fetch must equal the held URL's site, with an " \
                                          "optional trailing / and no path, query or fragment")
            end

            { "tool" => tool_name, "path" => "url", "match" => "#{origin}/*", "verdict" => VERDICT }.freeze
          rescue URI::InvalidURIError
            invalid
          end

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
