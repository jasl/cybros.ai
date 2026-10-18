require "application_system_test_case"

module WorkReadingJourney
  extend ActiveSupport::Concern

  included do
    test "readable results keep Markdown, exact code copy and original text usable" do
      human = users(:member)
      conversation = Conversation.create!(workspace: workspaces(:shared), creating_user: human,
        answering_user: users(:agent), title: "Reading review")
      seam = create_run_backed_turn(conversation: conversation, acting_user: human,
        turn_status: "completed", variant_status: "completed", run_status: "completed")
      code = "<script>window.untrustedReadingExecuted = true</script>\n  exact & spaced\n#{"x" * 500}\n"
      text = "\n\n# Readable result\r\n\r\n**A useful answer**\rMixed line endings\n\n| Item | Value |\n| --- | --- |\n| Long | #{"value" * 100} |\n\n```html\n#{code}```\n\n<script>window.untrustedReadingExecuted = true</script>\n\n![Remote diagram](https://example.invalid/diagram.png)"
      ContentBodies::Replace.call(owner: seam.variant, role: "content", entries: [{ "text" => text }], seal: true)

      sign_in_directly(human)
      visit conversation_turn_variant_path(conversation, seam.turn.public_id, seam.variant.public_id)
      assert_selector "h1", text: "Execution result"
      assert_selector "h2", text: "Readable result"
      assert_selector "strong", text: "A useful answer"
      assert_selector "table tbody td", text: "Long"
      first_column_text_height = find("table tbody td", text: "Long", exact_text: true).evaluate_script(<<~JS)
        (() => {
          const range = document.createRange()
          range.selectNodeContents(this)
          return range.getBoundingClientRect().height
        })()
      JS
      assert_operator first_column_text_height, :<=, 48
      assert_no_selector "article img, article iframe, article svg, article script", visible: :all
      assert page.evaluate_script("window.untrustedReadingExecuted === undefined")
      page.execute_script(<<~JS)
        Object.defineProperty(navigator, "clipboard", { configurable: true, value: {
          writeText: text => { window.readingCopied = text; return Promise.resolve() }
        } })
      JS
      within("article[data-turn-id='#{seam.turn.public_id}']") do
        click_button "Copy code"
        assert_button "Copied"
        assert_equal code, page.evaluate_script("window.readingCopied")
        find("summary", text: "Original text").click
        within("details") do
          assert_selector "pre", text: "# Readable result"
          click_button "Copy original"
          assert_button "Copied"
          assert_equal text, page.evaluate_script("window.readingCopied")
        end
      end
      assert_operator page.evaluate_script("document.documentElement.scrollWidth"), :<=,
        page.evaluate_script("document.documentElement.clientWidth") + 1
      page.save_screenshot(Rails.root.join("tmp/screenshots/#{self.class.name.underscore}.png"))
      # sign_in_directly visits the headless health page first; Chrome asks
      # that page for /favicon.ico. The application declares /icon.svg instead.
      favicon = URI.join(page.current_url, "/favicon.ico").to_s
      failures = page.driver.browser.logs.get(:browser).select { |entry| entry.level == "SEVERE" }
        .reject { |entry| entry.message.match?(/\A#{Regexp.escape(favicon)} - Failed to load resource: .*\b404\b/) }
      assert_empty failures
    end
  end
end

class WorkReadingJourneyTest < ApplicationSystemTestCase
  include WorkReadingJourney
end

class MobileWorkReadingJourneyTest < MobileSystemTestCase
  include WorkReadingJourney
end
