require_relative "base"

module Rho
  module Browser
    module Tools
      class Navigate
        include Base

        NAME = "browser_navigate".freeze
        # THE SAME GET A CLICK PERFORMS, and declared the same way: a URL can
        # be `/account/delete`, and a gate keyed on `destructive` that
        # refused the click but waved the navigate through would be no gate.
        EFFECT_PROFILE = ACTS_ON_PAGE
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "url" => { "type" => "string", "description" => "The absolute URL to open" },
          },
          "required" => ["url"],
        })
        DESCRIPTION =
          "Open a URL in the browser and return the resulting page as a snapshot.".freeze
        PROMPT_SNIPPET = "Open a URL".freeze
        PROMPT_GUIDELINES = GUIDELINES

        def call(args)
          missing = required(args, "url")
          return missing if missing

          url = args["url"].to_s.strip
          on_page do |page, fresh|
            page.goto(url)
            page_result(page, fresh)
          end
        end
      end
    end
  end
end
