module Nexus
  ModelCapabilityLimits = Data.define(
    :input_tokens, :output_tokens, :combined_input_output_tokens, :effective_input_tokens,
    :input_bytes, :input_characters, :audio_duration_seconds, :result_count, :embedding_dimensions
  ) do
    def self.from_h(hash) = new(**hash.transform_keys(&:to_sym))

    # Discovery and selection share the same bounds. The advisory threshold
    # belongs to Nexus; every other bound comes from the compiled profile.
    def self.from_catalog(entry:, profile:)
      capabilities = entry.fetch("capabilities", {})
      authored = capabilities["limits"] || entry["limits"] || {}
      new(effective_input_tokens: authored["effective_input_tokens"],
        **profile.local_safety_limits.deconstruct_keys(nil))
    end

    # The necessary bound on input, whichever way the lane spells its window.
    # A shared-window provider checks input + requested output; this input
    # ceiling alone does not reserve the requested output tokens.
    def input_token_bound = input_tokens || combined_input_output_tokens

    # The SOFT threshold, where a lane has one: below the hard window, and
    # exceeding it is a warning rather than a refusal (a subscription's own
    # effective cap). Nil for every lane whose only bound is the hard one.
    def advisory_input_bound = effective_input_tokens

    # THE WINDOW THE KERNEL PLANS TO: the advisory bound where a lane has
    # one, else the hard one — what assembly fits history to and what the
    # compaction arms read, so a lane fitted short of its hard window
    # compacts at the fit instead of sliding under it forever.
    def planning_input_bound = advisory_input_bound || input_token_bound

    def to_h = super.transform_keys(&:to_s)
  end
end
