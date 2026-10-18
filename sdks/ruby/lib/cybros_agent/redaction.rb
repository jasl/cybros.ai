module CybrosAgent
  # Bearer, device, and recovery secrets are opaque after their stable family
  # prefix. One diagnostic scrubber serves every plane, so value objects,
  # translated transport failures, and reflected server errors cannot drift
  # into different redaction rules. A family prefix BEGINS a token: `sk-`
  # inside a word is not one — a model's ask hangs under `r2t0-ask-1`, and
  # a scrubber that read its `sk-1` as a secret erased the one key a
  # person needs from every diagnostic that named it.
  module Redaction
    SECRET_PATTERN = /(?<![[:alnum:]])(?:sk|rt|dc|rc)-[[:alnum:]][[:alnum:]._-]*/i
    # KEYS whose value is a credential BY NAME, whatever its shape — the
    # ONE table every plane's key-redaction reads (rho's log). `key` is bounded on purpose: `api_key`, `x-api-key`
    # and a bare `key` are credentials; `task_key` / `call_key` /
    # `idempotency_key` are the handles a reader needs to find anything in
    # a log, and a table that erased them would hide the one fact every
    # diagnostic names.
    SECRET_KEY = /token|secret|bearer|password|credential|passphrase|authorization|cookie|api_key|apikey|\bkey\b/i
    REPLACEMENT = "[REDACTED]".freeze

    def self.call(value)
      value.to_s.gsub(SECRET_PATTERN, REPLACEMENT)
    end
  end
end
