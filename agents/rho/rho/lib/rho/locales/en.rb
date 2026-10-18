module Rho
  module Locales
    ENGLISH = {
      "conversation_cost_limit_reached" => "The Conversation cost limit has been reached. Raise or clear that limit, " \
        "then retry the held model task to continue from its existing graph. Changing the limit does not restart work.",
      "provider_context_overflow" => "Context exceeds the model server's limit. In Nexus Settings > Model providers > Edit model > " \
        "Context and capabilities, match Input token limit or Combined context window to the server's actual limit (use only one), and check Output token limit. " \
        "If needed, lower the requested output budget, shorten the input, or start a new conversation.",
    }.freeze
  end
end
