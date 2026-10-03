module Rho
  module Browser
    module Tools
      # THE POLICY LAYER, as prompt fragments. In the references this is a
      # SKILL beside the tools — openclaw ships `browser-automation/SKILL.md`
      # next to the plugin that registers the verbs. rho assembles every
      # tool's guidelines into the instructions block, so the skill IS
      # these strings; they are shared constants because the assembler
      # dedupes identical lines, and a guideline stated on four tools must
      # read once.
      GUIDELINES = Ractor.make_shareable([
        "Start with browser_snapshot and act on the [ref=eN] handles it shows; never guess a selector.",
        "Refs belong to the latest snapshot: after a navigation or an action that changes the page, " \
          "use the refs from the page that came back, not from an earlier one.",
        "Every action returns the resulting page, so a second snapshot after it is rarely needed.",
        "Prefer navigating straight to a URL over clicking through menus to reach it.",
        "browser_evaluate runs arbitrary JavaScript on the page; reach for it only when no other " \
          "browser tool can express the action.",
        "An idle browser tab may be closed; a new-tab notice means earlier snapshot refs no longer apply.",
      ])

      READ_ONLY = Ractor.make_shareable({
        "kind" => "read_only", "destructive" => false, "world" => "closed",
        "idempotency" => "intrinsic", "reconciliation" => "none",
      })
      # A click or a keystroke can submit, purchase, or delete — the tool
      # cannot know, so it declares the worst honest case.
      ACTS_ON_PAGE = Ractor.make_shareable({
        "kind" => "write", "destructive" => true, "world" => "open",
        "idempotency" => "none", "reconciliation" => "none",
      })

      # Playwright's `ai` snapshot mode names elements `e1`, `e2`, … A
      # selector arriving here instead of a ref is the common mistake, and
      # it gets a message naming the expected shape rather than whatever
      # the driver would say about an unknown engine.
      REF_FORMAT = /\A[a-z]+\d+\z/i

      # How long an action waits for its element to become actionable.
      # The gem's default is thirty seconds, which for a ref that is
      # simply gone is thirty seconds of a held browser and a message
      # about waiting; a stale ref is caught before this even starts.
      ACTION_TIMEOUT_MS = 10_000

      # What every tool shares: the session, the environment, the one
      # rendering of a page, and the rescue that turns a driver failure
      # into an error the model can read and act on.
      module Base
        def initialize(env:)
          @env = env
        end

        private

          # WHOSE TAB: the loop this call belongs to, which the execution
          # context carries; nil (a test, a standalone probe) is the one
          # default owner. The block receives the page and `fresh` — true
          # on the first call to a new tab, including a replacement after
          # idle cleanup or a failure. Earlier refs cannot apply to it.
          #
          # `fresh` RIDES THE BLOCK, NEVER AN IVAR: one tool instance serves
          # every worker thread, and instance state here would be one
          # loop's reset notice delivered to another loop's answer.
          # The notice is owed on EVERY answer the model reads after a drop,
          # an error included — a navigate that failed DNS must still say
          # the refs are gone, or the model's next click is on a ghost.
          def on_page
            fresh = false
            Rho::Browser.session.with_page(owner) do |page, seen|
              fresh = seen
              Rho::Runner::ExecutionContext.current&.raise_if_cancelled!
              yield page, seen
            end
          rescue Rho::Runner::ExecutionContext::Cancelled
            raise
          rescue Rho::Browser::Closed, Rho::Browser::CallTimedOut,
                 Rho::Browser::Driver::Failure => error
            Rho::Runner::Result.error(noticed(error.message, fresh))
          rescue StandardError => error
            Rho::Runner::Result.error(noticed("#{error.class.name}: #{error.message}", fresh))
          end

          # THE ELEMENT WAS THERE WHEN CHECKED AND GONE WHEN ACTED ON — a
          # re-rendering page between the two round-trips. The gem's text
          # is about waiting; the model needs the word "stale" and the
          # remedy, or it retries the same ref.
          def acting_on(ref)
            yield
          rescue StandardError => error
            raise unless playwright_timeout?(error)

            raise ArgumentError,
              "ref #{ref} was on the page but the element changed before the action " \
              "could run (the page re-rendered); take a new browser_snapshot and act on a " \
              "ref from it"
          end

          def playwright_timeout?(error)
            defined?(Playwright::TimeoutError) && error.is_a?(Playwright::TimeoutError)
          end

          # A MISSING REQUIRED ARGUMENT IS THE MODEL'S TO FIX, so it answers
          # as an error result it can read rather than a failed task that
          # takes the round's failure policy. Checked BEFORE the page is
          # touched, so an argument mistake never costs a browser probe.
          def required(args, *keys)
            missing = keys.select { |key| args[key].to_s.strip.empty? }
            return nil if missing.empty?

            Rho::Runner::Result.error("#{missing.join(", ")} #{missing.one? ? "is" : "are"} required")
          end

          def owner
            Rho::Runner::ExecutionContext.current&.agent_loop_public_id || Session::DEFAULT_OWNER
          end

          def page_result(page, fresh)
            Rho::Runner::Result.ok(noticed(SnapshotText.call(page), fresh))
          end

          NEW_TAB_NOTICE = "NOTE: this loop has a new browser tab; any refs from an earlier tab " \
                           "are invalid. Use the current page's snapshot before acting on a ref.\n\n".freeze

          def noticed(text, fresh)
            fresh ? NEW_TAB_NOTICE + text : text
          end

          # Query without waiting so stale refs fail promptly. The Ruby
          # client's Locator#count evaluates in the main world, which
          # cannot see the utility world's snapshot ref map. A selector
          # query uses the matching world; dispose its temporary handle
          # before returning the locator that performs the action.
          def locator_for(page, ref)
            ref = ref.to_s.strip
            unless ref.match?(REF_FORMAT)
              raise ArgumentError,
                "ref must be a handle from browser_snapshot such as e12, not #{ref.inspect}"
            end

            selector = "aria-ref=#{ref}"
            element = page.query_selector(selector)
            if element.nil?
              raise ArgumentError,
                "ref #{ref} is not on the current page; refs belong to the latest snapshot — " \
                "call browser_snapshot and use a ref from what it returns"
            end
            element.dispose
            page.locator(selector)
          end
      end
    end
  end
end
