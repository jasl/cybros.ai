require_relative "base"

module Rho
  module Browser
    module Tools
      class Snapshot
        include Base

        NAME = "browser_snapshot".freeze
        EFFECT_PROFILE = READ_ONLY
        SCHEMA = Ractor.make_shareable({ "type" => "object", "properties" => {} })
        DESCRIPTION =
          "Read the current page as an accessibility tree. Every interactive element carries " \
          "a [ref=eN] handle that browser_click and browser_type accept. Call this first; it is " \
          "also what every action returns.".freeze
        PROMPT_SNIPPET = "Read the current page as a tree of [ref=eN] handles".freeze
        PROMPT_GUIDELINES = GUIDELINES

        def call(_args)
          on_page { |page, fresh| page_result(page, fresh) }
        end
      end
    end
  end
end
