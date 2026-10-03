module Rho
  module Browser
    # WHAT A MODEL READS BACK FROM A PAGE, and the one rendering every
    # action shares — because the references agree that an action answers
    # with the resulting page state, so a separate snapshot call after
    # every click is a round-trip nobody needs.
    #
    # The body is Playwright's accessibility snapshot in its `ai` mode:
    # the same tree `@playwright/mcp`'s `browser_snapshot` returns, where
    # every interactive element carries an opaque `[ref=eN]` the other
    # tools accept. Refs belong to THIS snapshot — a navigation or a
    # re-render invalidates them, and the guideline on every tool says so.
    #
    # BOUNDED, head-kept, marker inside the bound: a page with ten
    # thousand rows would otherwise arrive as a tool result the size of
    # the runner's whole submit budget.
    module SnapshotText
      MAX_BYTES = Rho::Runner::Truncation::DEFAULT_MAX_BYTES
      # THE HEADER IS CAPPED, so it cannot eat the budget: a page opened
      # from a 60 KB `data:` URL would otherwise answer every action with
      # its own URL and no tree at all — no refs, nothing to click.
      URL_BYTES = 512
      TITLE_BYTES = 256

      module_function

      def call(page, max_bytes: MAX_BYTES)
        header = "Page: #{shorten(page.url.to_s, URL_BYTES)}\n" \
                 "Title: #{shorten(page.title.to_s, TITLE_BYTES)}\n\n"
        tree = page.aria_snapshot(mode: "ai").to_s
        header + clamp(tree, max_bytes - header.bytesize)
      end

      # A HEADER FIELD IS SHORTENED, NOT TRUNCATED-WITH-A-MARKER: the tree's
      # marker says the SNAPSHOT was cut and points at browser_evaluate,
      # which on the Page: line is a lie about the wrong thing and splits
      # the header across three lines. One line, an ellipsis, the count.
      def shorten(text, bytes)
        return text if text.bytesize <= bytes

        tail = format(" …(%d more bytes)", text.bytesize)
        kept = text.byteslice(0, [bytes - tail.bytesize, 0].max).scrub("")
        kept + format(" …(%d more bytes)", text.bytesize - kept.bytesize)
      end

      def clamp(text, room)
        return text if text.bytesize <= room

        marker = "\n\n[snapshot truncated: %d more bytes; use browser_evaluate to read a region]"
        # The marker's own width is reserved inside the room, so the
        # result never overruns what the caller asked for.
        reserve = format(marker, text.bytesize).bytesize
        kept = text.byteslice(0, [room - reserve, 0].max).scrub("")
        kept + format(marker, text.bytesize - kept.bytesize)
      end
    end
  end
end
