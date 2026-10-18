require_relative "base"

module Rho
  module Browser
    module Tools
      class Type
        include Base

        NAME = "browser_type".freeze
        EFFECT_PROFILE = ACTS_ON_PAGE
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "ref" => { "type" => "string",
                       "description" => "The field's handle from the latest snapshot, e.g. e7" },
            "text" => { "type" => "string",
                        "description" => "The text to put in the field; an empty string clears it" },
            "submit" => { "type" => "boolean",
                          "description" => "Press Enter afterwards (default false)" },
          },
          "required" => ["ref", "text"],
        })
        DESCRIPTION =
          "Replace a field's contents by its [ref=eN] handle, optionally pressing Enter, and " \
          "return the page that results.".freeze
        PROMPT_SNIPPET = "Type into a field by ref".freeze
        PROMPT_GUIDELINES = GUIDELINES

        def call(args)
          missing = required(args, "ref")
          return missing if missing
          # `text` must be SENT — an empty string clears the field, which is
          # a real intent, but an absent one is a mistake that would clear
          # somebody's half-written input silently.
          unless args.key?("text") && !args["text"].nil?
            return Rho::Runner::Result.error('text is required (send "" to clear the field)')
          end

          ref = args["ref"]
          text = args["text"].to_s
          submit = args["submit"] == true
          on_page do |page, fresh|
            field = locator_for(page, ref)
            acting_on(ref) do
              field.fill(text, timeout: ACTION_TIMEOUT_MS)
              field.press("Enter", timeout: ACTION_TIMEOUT_MS) if submit
            end
            page_result(page, fresh)
          end
        end
      end
    end
  end
end
