require "test_helper"
require "cgi/escape"
require "fileutils"
require "securerandom"
require "tmpdir"
require "uri"
require "support/actor_provisioning"
require "support/ceremony"
require "support/rho_daemon"
require "support/rho_webui_browser"
require "support/secret_hygiene"
require "support/steward_session"

class RhoStructuredQuestionsTest < Minitest::Test
  include E2E::RhoWebuiBrowser

  def test_structured_answers_travel_from_the_browser_to_the_resumed_model
    boot_console(width: 1400, height: 1000, settings: { "conversation_title_model" => nil })
    @artifacts = File.join(Dir.tmpdir, "rho-structured-question-ui-#{Process.pid}")
    new_conversation
    fields = [
      { name: "enabled", label: "Enable delivery", type: "boolean", required: true },
      { name: "count", label: "Retry count", type: "integer", required: true },
      { name: "note", label: "Delivery note", type: "string", required: true },
      { name: "destination", label: "Destination", type: "choice", options: %w[Local Remote], required: true },
      { name: "channels", label: "Channels", type: "multichoice", options: %w[Email Archive], required: true },
      { name: "ratio", label: "Sample ratio", type: "number" },
      { name: "extra", label: "Extra notes", type: "string" },
    ]
    args = CGI.escape(JSON.generate(prompt: "Choose delivery settings", fields: fields))
    send_message("!mock tool_call=ask tool_args=#{args} echo=content -- Ask for delivery settings.")
    assert @page.has_field?("Enable delivery", wait: WAIT)
    @page.refresh
    assert @page.has_field?("Enable delivery", wait: WAIT), "the durable question survives page reload"
    assert_equal "rho", @page.title
    assert_submit_in_view
    screenshot("desktop-form")
    row = @daemon.control(:get, "/asks").fetch("asks").find { |ask| ask.fetch("prompt", nil) == "Choose delivery settings" }
    refute_nil row
    @page.select "No", from: "Enable delivery"
    @page.fill_in "Retry count", with: "1.5"
    @page.select "Local", from: "Destination"
    @page.click_button "Send answer"
    assert @page.has_text?("Enter a whole number", wait: WAIT)
    @page.fill_in "Retry count", with: "0"
    @page.find_field("Retry count").send_keys(:tab)
    assert_equal @page.find_field("Delivery note")[:id], @page.evaluate_script("document.activeElement.id")
    @page.check "Answer Sample ratio"
    @page.fill_in "Sample ratio", with: "0.5"
    resize_console(width: 390, height: 844)
    assert_submit_in_view
    screenshot("narrow-form")
    @console_logs.concat(@browser.console_logs)
    @page.driver.browser.network_conditions = { offline: true }
    @page.click_button "Send answer"
    assert @page.has_css?('[role="alert"]', text: "rho could not be reached", wait: WAIT)
    assert @page.has_field?("Retry count", with: "0")
    assert @page.has_select?("Enable delivery", selected: "No")
    @browser.console_logs.each do |entry|
      if entry.fetch("level") == "SEVERE"
        assert_match(/ERR_INTERNET_DISCONNECTED/, entry.fetch("message"))
        entry["expected_network_failure"] = true
      end
      @console_logs << entry
    end
    @page.driver.browser.delete_network_conditions
    @page.click_button "Send answer"
    assert @page.has_field?("Message", wait: WAIT), "the composer returns after settlement"
    assert @page.has_text?('"enabled":false', wait: WAIT), "the resumed model reads the typed answer"
    assert @page.has_text?('"count":0', wait: WAIT)
    client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
    detail = client.workspace(@workspace_id).run(row.fetch("run_public_id")).task(row.fetch("task_key"))
    expected = { "enabled" => false, "count" => 0, "note" => "", "destination" => "Local", "channels" => [], "ratio" => 0.5 }
    assert_equal expected, detail.structured_content
    assert_equal expected, JSON.parse(detail.output)
    screenshot("narrow-completed")
    assert_clean_console
  ensure
    @page&.driver&.browser&.delete_network_conditions
  end

  private

    def assert_submit_in_view
      assert @page.evaluate_script(<<~JS)
        (() => {
          const button = document.querySelector(".question-form button[type=submit]").getBoundingClientRect();
          const card = document.querySelector(".ask--structured").getBoundingClientRect();
          return button.top >= card.top && button.bottom <= card.bottom && button.bottom <= window.innerHeight;
        })()
      JS
    end
end
