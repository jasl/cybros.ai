require "securerandom"
require_relative "base"

module Rho
  module Browser
    module Tools
      # THE PICTURE GOES TO DISK, NOT THROUGH THE TOOL RESULT. A PNG is
      # hundreds of kilobytes that the model cannot read as text, so the
      # result names the file — the model can `read` it if it has vision,
      # a person can open it — exactly what `playwright screenshot` on the
      # command line does. The file is also a CAPTURE: named
      # in `files:`, the run uploads it and links it beside this sentence,
      # so a client fetches the picture and a model that takes pictures is
      # shown it in the next round; the sentence itself is byte-stable.
      class Screenshot
        include Base

        NAME = "browser_screenshot".freeze
        EFFECT_PROFILE = READ_ONLY
        SCHEMA = Ractor.make_shareable({
          "type" => "object",
          "properties" => {
            "full_page" => { "type" => "boolean",
                             "description" => "Capture the whole scrollable page (default: the viewport)" },
          },
        })
        DESCRIPTION =
          "Save a PNG screenshot of the current page and return its path.".freeze
        PROMPT_SNIPPET = "Save a screenshot of the page to a file".freeze
        PROMPT_GUIDELINES = GUIDELINES
        # A shot's name: `browser-<digest>.png`.
        CAPTURE_PREFIX = "browser".freeze

        def call(args)
          full_page = args["full_page"] == true
          on_page do |page, fresh|
            dir = @env.ensure_artifacts_dir!
            # Named by content: identical bytes are one file. Shot under a
            # random name first, then renamed to the PNG's digest, so two
            # shots of an unchanged page are one path and one picture.
            shot = File.join(dir, "#{CAPTURE_PREFIX}-#{SecureRandom.hex(8)}.png")
            page.screenshot(path: shot, fullPage: full_page)
            path = @env.keep_capture(shot, CAPTURE_PREFIX)
            Rho::Runner::Result.ok(noticed("Saved a screenshot of #{page.url} to #{path}", fresh), files: [path])
          end
        end
      end
    end
  end
end
