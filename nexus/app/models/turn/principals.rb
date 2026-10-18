# The author and answerer frozen for a turn, shared by queued input and preview.
class Turn::Principals < Data.define(:author, :answerer, :declaration)
  def initialize(author:, answerer:, declaration: nil) = super
  # Whose standing declaration the turn runs under: the ADDRESSEE's —
  # the poster is the speaker; whose engine answers is the row's own
  # resolved fact. The system user is `kind: agent` and declares
  # nothing, so it needs no carve-out; a Human answerer declares nothing.
  def execution_agent = (answerer if answerer&.agent?)
  def execution_configuration = declaration || execution_agent

  # `raw` from either side sends the input's own entries as the request:
  # the per-turn word or the profile's standing mechanism.
  def raw?(context_mode = nil) = context_mode == "raw" || execution_configuration&.prompt_mechanism == "raw"

  # The effective word a turn's loop row records: `raw` when the input
  # goes verbatim, `assembly` under the addressee's own template, else
  # the built-in `default` order.
  def prompt_mechanism(context_mode = nil)
    return "raw" if raw?(context_mode)

    execution_configuration&.prompt_mechanism == "assembly" ? "assembly" : "default"
  end

  # The block order the addressee compiles under: its own template under
  # `assembly`, the built-in one otherwise.
  def template = PromptTemplate.for_configuration(execution_configuration)
end
