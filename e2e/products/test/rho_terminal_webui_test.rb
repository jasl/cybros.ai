require "test_helper"
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
require "support/web_fixture"
require "support/webrtc_fixture"

class RhoTerminalWebuiTest < Minitest::Test
  include E2E::RhoWebuiBrowser

  def test_terminal_plugin_enablement_and_shell_through_the_shipped_page
    binary = File.join(@root, "rho-webrtc")
    E2E::WebrtcFixture.build(File.expand_path("../../..", __dir__), "agents/rho/rho-env/transport", binary, ".")
    boot_console(width: 1400, height: 1000, settings: {
      "plugins" => { "rho.terminal" => { "configuration" => { "executable" => binary } } },
    })
    assert @page.has_no_button?("Terminals")
    assert @page.has_no_css?('link[href*="/modules/rho.terminal/"]', visible: :all)
    origin = URI(console_url)
    origin.path = "/plugins/rho.terminal"
    @page.visit(origin.to_s)
    assert @page.has_unchecked_field?("Terminal enabled", visible: :all, wait: WAIT)
    @page.check "Terminal enabled", allow_label_click: true
    assert @page.has_text?("Saved and applied.", wait: WAIT)
    @page.click_button "New conversation"
    assert @page.has_button?("Terminals", wait: WAIT)
    @page.click_button "Terminals", exact: true
    assert @page.has_select?("Terminal Runner", wait: WAIT)
    assert @page.has_css?('link[href*="/modules/rho.terminal/"]', count: 2, visible: :all)
    assert @page.has_no_text?("Running terminals")
    @page.click_button "New terminal"
    assert @page.has_css?('.terminal[data-connection="connected"]', wait: 30)
    assert @page.has_css?('.dock__pane:not([hidden]) .xterm-accessibility', text: "$", visible: :all, wait: 10)
    assert @page.has_no_text?("Output gap:")
    assert @page.has_no_css?(".terminals")
    first_id = @page.find(".terminal-session")["data-terminal-id"]
    first = @page.find('.dock__tab-button[aria-selected="true"]').text
    @page.find(".xterm-screen").click
    @page.driver.browser.action.send_keys("VALUE=first; printf 'TERMINAL_READY:%s\\n' $$; pwd", :enter).perform
    assert @page.has_css?('.dock__pane:not([hidden]) .xterm-accessibility', text: @project, visible: :all, wait: 10)
    pid = @page.find('.dock__pane:not([hidden]) .xterm-accessibility', visible: :all).text(:all).match(/TERMINAL_READY:(\d+)/)[1]
    assert @page.has_no_css?(".terminal > .alert")
    assert @page.has_no_button?("Stop terminal")
    assert @page.has_no_css?(".terminal__keys")
    screenshot("terminal-desktop")
    @page.click_button "New tab", exact: true
    assert @page.has_css?(".dock__guide", wait: WAIT)
    screenshot("terminal-new-tab")
    @page.find(".dock__guide-entry", text: "Terminals").click
    @page.click_button "New terminal"
    assert @page.has_css?('.terminal[data-connection="connected"]', wait: 30)
    second = @page.find('.dock__tab-button[aria-selected="true"]').text
    refute_equal first, second
    second_id = @page.find(".terminal-session")["data-terminal-id"]
    @page.find(".xterm-screen").click
    @page.driver.browser.action.send_keys("printf 'SECOND:%s\\n' $$", :enter).perform
    assert @page.has_css?('.dock__pane:not([hidden]) .xterm-accessibility', text: /SECOND:\d+/, visible: :all, wait: 10)
    other_pid = @page.find('.dock__pane:not([hidden]) .xterm-accessibility', visible: :all).text(:all).match(/SECOND:(\d+)/)[1]
    refute_equal pid, other_pid
    @page.click_button first, exact: true
    @page.find(".xterm-screen").click
    @page.driver.browser.action.send_keys("printf 'SAME_SHELL:%s:%s\\n' $$ $VALUE", :enter).perform
    assert @page.has_css?('.dock__pane:not([hidden]) .xterm-accessibility', text: "SAME_SHELL:#{pid}:first", visible: :all, wait: 10)
    screenshot("terminal-two-tabs")
    @page.click_button "Close #{first}", exact: true
    assert @page.has_no_button?(first, exact: true, wait: 30)
    assert_shell_stopped(first_id, pid)
    @page.click_button second, exact: true
    @page.click_button "Close side panel", exact: true
    @page.click_button "Terminals", exact: true, match: :first
    @page.within(".terminals") { @page.click_button "Refresh" }
    @page.find(%([data-terminal-id="#{second_id}"])).click
    assert @page.has_css?('.terminal[data-connection="connected"]', wait: 30)
    @page.find(".xterm-screen").click
    @page.driver.browser.action.send_keys("printf 'REOPENED:%s\\n' $$", :enter).perform
    assert @page.has_css?('.dock__pane:not([hidden]) .xterm-accessibility', text: "REOPENED:#{other_pid}", visible: :all, wait: 10)
    resize_console(width: 390, height: 844)
    @page.find(".xterm-screen").click
    @page.driver.browser.action.send_keys("printf 'SIZE:'; stty size", :enter).perform
    assert @page.has_css?('.dock__pane:not([hidden]) .xterm-accessibility', text: /SIZE:\d+ \d+/, visible: :all, wait: 10)
    cols = @page.find('.dock__pane:not([hidden]) .xterm-accessibility', visible: :all).text(:all).match(/SIZE:\d+ (\d+)/)[1].to_i
    assert_operator cols, :<, 80
    assert_operator cols, :>, 20
    assert @page.evaluate_script(<<~JS)
      (() => {
        const tab = document.querySelector('.dock__tab--active').getBoundingClientRect();
        return tab.left >= 0 && tab.right <= innerWidth;
      })()
    JS
    @page.click_button "Dismiss terminal notice" if @page.has_button?("Dismiss terminal notice", wait: 0)
    assert @page.has_no_css?(".terminal > .alert")
    assert @page.has_css?(".terminal__keys")
    @page.driver.browser.action.send_keys("sleep 60", :enter).perform
    @page.click_button "Ctrl", exact: true
    @page.driver.browser.action.send_keys("c").perform
    @page.driver.browser.action.send_keys("printf 'MOBILE_%s\\n' KEYS_OK", :enter).perform
    assert @page.has_css?('.dock__pane:not([hidden]) .xterm-accessibility', text: "MOBILE_KEYS_OK", visible: :all, wait: 10)
    @page.driver.browser.action.send_keys("printf 'ARROW_%s\\n' O").perform
    @page.click_button "Left arrow", exact: true
    @page.driver.browser.action.send_keys("K", :enter).perform
    assert @page.has_css?('.dock__pane:not([hidden]) .xterm-accessibility', text: "ARROW_KO", visible: :all, wait: 10)
    screenshot("terminal-mobile")
    resize_console(width: 1400, height: 1000)
    @page.click_button "New tab", exact: true
    assert @page.has_css?(".dock__guide-entry", text: "Terminals")
    @page.click_link "Plugins", exact: true
    @page.click_button "Terminal", exact: true
    @page.uncheck "Terminal enabled", allow_label_click: true
    assert @page.has_text?("Saved and applied.", wait: WAIT)
    @page.click_button "New conversation"
    assert @page.has_no_button?("Terminals")
    assert @page.has_no_css?('link[href*="/modules/rho.terminal/"]', visible: :all)
    assert @page.has_no_css?(".terminals", visible: :all)
    assert @page.has_no_css?(".terminal-session", visible: :all)
    assert @page.has_no_button?(second, exact: true, visible: :all)
    running = @daemon.control(:get, "/terminals").fetch("terminals").find { |row| row.fetch("public_id") == second_id }
    assert_equal "dispatched", running.fetch("status")
    assert @page.has_no_css?(".dock__guide-entry", text: "Terminals", visible: :all)
    screenshot("terminal-disabled")
    # Bounded history survives more than 30 seconds with its viewer unloaded.
    sleep 31
    @page.click_link "Plugins", exact: true
    @page.click_button "Terminal", exact: true
    @page.check "Terminal enabled", allow_label_click: true
    assert @page.has_text?("Saved and applied.", wait: WAIT)
    @page.click_button "New conversation"
    assert @page.has_button?("Terminals", wait: WAIT)
    assert @page.has_css?('link[href*="/modules/rho.terminal/"]', count: 2, visible: :all)
    assert @page.has_css?(".dock__guide-entry", text: "Terminals")
    @page.click_button "Terminals", exact: true
    @page.find(%([data-terminal-id="#{second_id}"])).click
    assert @page.has_css?('.terminal[data-connection="connected"]', wait: 30)
    @page.find(".xterm-screen").click
    @page.driver.browser.action.send_keys("printf 'REACTIVATED:%s\\n' $$", :enter).perform
    assert @page.has_css?('.dock__pane:not([hidden]) .xterm-accessibility', text: "REACTIVATED:#{other_pid}", visible: :all, wait: 10)
    assert @page.has_no_text?("Output gap:")
    assert @page.has_css?('.dock__pane:not([hidden]) .xterm-accessibility', text: "REOPENED:#{other_pid}", visible: :all)
    assert @page.has_css?('.dock__pane:not([hidden]) .xterm-accessibility', text: "MOBILE_KEYS_OK", visible: :all)
    reopened = @page.find('.dock__tab-button[aria-selected="true"]').text
    @page.click_button "Close #{reopened}", exact: true
    assert @page.has_no_button?(reopened, exact: true, wait: 30)
    assert_shell_stopped(second_id, other_pid)
    assert @page.has_no_text?("run_canceled")
    assert @page.has_no_css?(".terminal__head")
    assert_clean_console
  end


  def test_unrecoverable_output_clears_the_screen_and_keeps_the_shell
    binary = File.join(@root, "rho-webrtc")
    E2E::WebrtcFixture.build(File.expand_path("../../..", __dir__), "agents/rho/rho-env/transport", binary, ".")
    boot_console(width: 1400, height: 1000, settings: {
      "plugins" => { "rho.terminal" => { "enabled" => true, "configuration" => { "executable" => binary } } },
    })
    @page.execute_script(<<~JS)
      window.holdTerminalOutput = false;
      const Peer = window.RTCPeerConnection;
      window.RTCPeerConnection = class extends Peer {
        createDataChannel(name, options) {
          const channel = super.createDataChannel(name, options);
          if (name === "terminal") channel.addEventListener("message", (event) => {
            const raw = event.data instanceof ArrayBuffer ? new TextDecoder().decode(event.data) : event.data;
            if (window.holdTerminalOutput && JSON.parse(raw).type === "output") event.stopImmediatePropagation();
          });
          return channel;
        }
      };
    JS
    @page.click_button "Terminals", exact: true
    @page.click_button "New terminal"
    assert @page.has_css?('.terminal[data-connection="connected"]', wait: 30)
    screen = '.dock__pane:not([hidden]) .xterm-accessibility'
    assert @page.has_css?(screen, text: "$", visible: :all, wait: 10)
    id = @page.find(".terminal-session")["data-terminal-id"]
    @page.find(".xterm-screen").click
    @page.driver.browser.action.send_keys("export GAP_CHECK=kept; cd /tmp; printf 'BEFORE_GAP:%s:%s:%s\\n' $$ $GAP_CHECK $PWD", :enter).perform
    assert @page.has_css?(screen, text: /BEFORE_GAP:\d+:kept:\/tmp/, visible: :all, wait: 10)
    pid = @page.find(screen, visible: :all).text(:all).match(/BEFORE_GAP:(\d+)/)[1]
    @page.execute_script("window.holdTerminalOutput = true")
    marker = File.join(@root, "gap-ready")
    @page.driver.browser.action.send_keys("head -c 300000 /dev/zero | tr '\\000' '\\r'; touch #{marker}", :enter).perform
    assert @daemon.await("shell did not finish overflowing retained output") { File.exist?(marker) }
    @page.execute_script("window.holdTerminalOutput = false")
    assert @page.has_text?("Screen cleared because some output could not be restored.", wait: 10)
    assert @page.has_no_text?("Output gap:")
    assert @page.has_no_css?(screen, text: "BEFORE_GAP:", visible: :all)
    @page.find(".xterm-screen").click
    @page.driver.browser.action.send_keys("printf 'AFTER_GAP:%s:%s:%s\\n' $$ $GAP_CHECK $PWD", :enter).perform
    assert @page.has_css?(screen, text: "AFTER_GAP:#{pid}:kept:/tmp", visible: :all, wait: 10)
    screenshot("terminal-gap-desktop")
    resize_console(width: 390, height: 844)
    assert @page.has_text?("Screen cleared because some output could not be restored.")
    screenshot("terminal-gap-mobile")
    @page.click_button "Dismiss terminal notice"
    assert @page.has_no_text?("Screen cleared because some output could not be restored.")
    tab = @page.find('.dock__tab-button[aria-selected="true"]').text
    @page.click_button "Close #{tab}", exact: true
    assert @page.has_no_button?(tab, exact: true, wait: 30)
    assert_shell_stopped(id, pid)
    assert_clean_console
  end

  private

    def assert_shell_stopped(id, pid)
      assert @daemon.await("terminal #{id} did not stop") {
        row = @daemon.control(:get, "/terminals").fetch("terminals").find { |terminal| terminal.fetch("public_id") == id }
        row && row.fetch("status") == "canceled"
      }
      assert @daemon.await("shell #{pid} is still running") {
        begin
          Process.kill(0, Integer(pid))
          false
        rescue Errno::ESRCH
          true
        end
      }
    end
end
