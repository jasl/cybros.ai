require "digest"

module Rho
  module Mcp
    # THE MODEL-FACING NAME OF A THIRD PARTY'S TOOL:
    # `mcp__<server>__<tool>`, VERBATIM when it already fits the provider's
    # floor (`Extensions::Tool::NAME_FORMAT`, 64 bytes of `[A-Za-z0-9_-]`);
    # otherwise every byte outside that set becomes `_`, the result is cut
    # to leave room, and `_` + the first 12 hex of SHA-256("<server>\0<raw>")
    # is appended — deepseek's `publicToolName` byte for byte (tools.ts),
    # so two raw names that normalize alike never collapse into one. The
    # RAW name is what goes on the wire in `tools/call`; the public name is
    # never parsed to recover it — the tool class holds both.
    #
    # A DOCUMENT rides the SKILL grammar (`Nexus::Skills::NAME_FORMAT`: `[a-z0-9]` and single hyphens, ≤ 64): `<server>-<raw>` after
    # lowercasing and folding every run of bytes outside `[a-z0-9]` to one
    # `-` (trimmed); when that changed the raw name or overran 64, cut to
    # leave room and append `-` + the same 12 hex — the tool rule's shape
    # under the other grammar. A prompt `Summarize Notes` on `fx` is
    # `fx-summarize-notes-<12hex>`; a prompt `summarize` is `fx-summarize`.
    module Naming
      PREFIX = "mcp__".freeze
      MAX_LENGTH = 64
      HASH_LENGTH = 12
      INVALID = /[^A-Za-z0-9_-]/
      DOCUMENT_INVALID = /[^a-z0-9]+/

      module_function

      def tool(server, raw)
        joined = "#{PREFIX}#{server}__#{raw}"
        normalized = joined.gsub(INVALID, "_")
        return normalized if normalized == joined && normalized.length <= MAX_LENGTH

        "#{normalized[0, MAX_LENGTH - HASH_LENGTH - 1]}_#{digest(server, raw)}"
      end

      def document(server, raw)
        plain = "#{server}-#{raw}"
        folded = plain.downcase.gsub(DOCUMENT_INVALID, "-").gsub(/\A-+|-+\z/, "")
        return folded if folded == plain && folded.length <= MAX_LENGTH

        stem = folded[0, MAX_LENGTH - HASH_LENGTH - 1].to_s.sub(/-+\z/, "")
        "#{stem}-#{digest(server, raw)}"
      end

      def digest(server, raw)
        Digest::SHA256.hexdigest("#{server}\0#{raw}")[0, HASH_LENGTH]
      end
    end
  end
end
