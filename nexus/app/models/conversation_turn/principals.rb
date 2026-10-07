# The author and answerer frozen for a turn, shared by queued input and preview.
class ConversationTurn::Principals < Data.define(:author, :answerer)
  # Whose standing declaration the turn runs under: the ADDRESSEE's —
  # the poster is the speaker; whose engine answers is the row's own
  # resolved fact. The system user is `kind: agent` and declares
  # nothing, so it needs no carve-out; a Human answerer declares nothing.
  def declaring_profile = (answerer if answerer&.agent?)

  # `raw` from either side sends the input's own entries as the request:
  # the per-turn word or the profile's standing mechanism.
  def raw?(context_mode = nil) = context_mode == "raw" || declaring_profile&.prompt_mechanism == "raw"

  # The effective word a turn's loop row records: `raw` when the input
  # goes verbatim, `assembly` under the addressee's own template, else
  # the built-in `default` order.
  def prompt_mechanism(context_mode = nil)
    return "raw" if raw?(context_mode)

    declaring_profile&.prompt_mechanism == "assembly" ? "assembly" : "default"
  end

  # The block order the addressee compiles under: its own template under
  # `assembly`, the built-in one otherwise.
  def template = PromptTemplate.for_profile(declaring_profile)
end
