module ModelInvocations
  # ONE spelling of a provider's word in a `key=value` log line: whitespace
  # becomes `_`, so the field never splits under a parser, and the length is
  # bounded. The replay's transformation lines and a refusal's two lines —
  # the apply's `model_refused`, the switch's `model_fallback` — spell a word
  # the same way, so a reader pairs them by it.
  module LogField
    LIMIT = 128

    module_function

    def token(value) = value.to_s.strip.gsub(/\s+/, "_")[0, LIMIT]
  end
end
