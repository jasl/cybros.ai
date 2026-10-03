require_relative "base"

module Rho
  module Browser
    module Tools
      class Click
        include Base

        NAME = "browser_click".freeze
        EFFECT_PROFILE = ACTS_ON_PAGE
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "ref" => { "type" => "string",
                       "description" => "The element's handle from the latest snapshot, e.g. e12" },
          },
          "required" => ["ref"],
        })
        DESCRIPTION =
          "Click an element by its [ref=eN] handle from the latest snapshot, and return the " \
          "page that results.".freeze
        PROMPT_SNIPPET = "Click an element by ref".freeze
        PROMPT_GUIDELINES = GUIDELINES

        def call(args)
          missing = required(args, "ref")
          return missing if missing

          ref = args["ref"]
          on_page do |page, fresh|
            locator = locator_for(page, ref)
            acting_on(ref) { locator.click(timeout: ACTION_TIMEOUT_MS) }
            page_result(page, fresh)
          end
        end
      end
    end
  end
end
