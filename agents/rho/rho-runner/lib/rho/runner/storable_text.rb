module Rho
  # Reopened by `rho/runner.rb`, which holds the loop itself.
  class Runner
    # THE RUNNER OWNS THE BYTES IT SUBMITS. PostgreSQL text and jsonb store no U+0000, so
    # the kernel refuses a result that carries one (`result_unstorable`) — AFTER the tool
    # has run, paid for and done — and the answer was dropped on this side, the park left to
    # its deadline while the model waited on a probe that had printed a NUL. Invalid UTF-8
    # the tools already scrub at the read; the NUL is legal UTF-8 and reaches this door
    # whole.
    #
    # THE ESCAPE, NOT THE REPLACEMENT CHARACTER: a NUL in a tool's text is
    # a fact about the output (a binary `cat`, a `find -print0`'s
    # separators), and the six characters `\u0000` say exactly which byte
    # stood there — the JSON spelling of it, the one the model already
    # reads in every wire. U+FFFD is what the scrub writes for bytes that
    # were NOT valid, and reusing it would tell the model two different
    # things with one glyph. The substitution is said ONCE at the end of
    # the text, so a changed byte never reads as the tool's own output.
    # Every string of the answer goes through here — the text, a failed
    # tool's message, and the strings inside `structured_content`, which
    # the kernel stores through the same door — BEFORE the size bound is
    # measured, since the escape grows one byte into six.
    module StorableText
      UNSTORABLE = "\u0000".freeze
      ESCAPE = "\\u0000".freeze
      NOTE = "\n\n[U+0000 bytes in this output are written as \\u0000: the kernel stores none]".freeze

      class << self
        # The text with every NUL escaped and the note appended when any
        # was; the text itself, untouched, when none.
        def text(text)
          text = text.to_s
          return text unless text.include?(UNSTORABLE)

          "#{text.gsub(UNSTORABLE, ESCAPE)}#{NOTE}"
        end

        # Structured content walked: every string escaped in place, no
        # note (a client reads typed data, not prose); anything else as it
        # is.
        def value(data)
          case data
          when String then data.include?(UNSTORABLE) ? data.gsub(UNSTORABLE, ESCAPE) : data
          when Hash then data.to_h { |key, entry| [key, value(entry)] }
          when Array then data.map { |entry| value(entry) }
          else data
          end
        end
      end
    end
  end
end
