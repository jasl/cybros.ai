module E2E
  # Authoring stays on rho's browser surface. Control reads verify reusable
  # configuration and persistent identities after each browser action.
  module RhoBotDefinitions
    WAIT = E2E::RhoDaemon::WATCH_TIMEOUT

    def test_browser_bot_current_history_and_home_keep_their_workspaces
      lane = provider("dev")
      lane.enable(expected_lock_version: lane.fetch.lock_version)
      visit_console
      first_home = @daemon.control(:get, "/workspaces").fetch("workspaces").first.fetch("public_id")
      second_home = @daemon.control(:post, "/workspaces", body: { "name" => "Later Bot home" }).fetch("workspace").fetch("public_id")
      @page.click_link "Bots", exact: true
      @page.click_button "New bot"
      @page.fill_in "Bot name", with: "history-helper", exact: true
      @page.fill_in "Display name", with: "History helper"
      @page.fill_in "Description", with: "Keeps one shared current conversation."
      @page.click_button "Create bot"
      assert @page.has_text?("History helper was created.", wait: WAIT)
      bot = browser_bot_definition("history-helper")
      id = bot.fetch("public_id")
      detail_path = "/bots/detail?#{URI.encode_www_form(agent_public_id: id)}"
      assert_nil @daemon.control(:get, detail_path).fetch("current"), "opening details never creates a conversation"
      assert @page.has_button?("Open current conversation", disabled: true, wait: WAIT)
      assert @page.has_text?("Hello, I'm History helper. Keeps one shared current conversation.")
      save_browser_bot_home(first_home)
      @page.click_button "Open current conversation", exact: true
      first = @daemon.await("the Bot current was not created") { @daemon.control(:get, detail_path).fetch("current") }
      assert_equal first_home, first.fetch("workspace_public_id")
      assert_browser_bot_readonly(first)
      bot_screenshot("bot-current-desktop")
      resize_bot_view(390, 844)
      bot_screenshot("bot-current-narrow")
      resize_bot_view(1400, 1000)

      open_browser_bot("history-helper")
      @page.within(".bots-page__current") { @page.click_button "New conversation", exact: true }
      second = @daemon.await("the Bot current did not change") do
        row = @daemon.control(:get, detail_path).fetch("current")
        row if row && row.fetch("public_id") != first.fetch("public_id")
      end
      refute_equal first.fetch("public_id"), second.fetch("public_id")
      assert_browser_bot_readonly(second)
      open_browser_bot("history-helper")
      assert @page.has_css?(%(li[data-conversation="#{first.fetch("public_id")}"]), text: "Archived", wait: WAIT)
      save_browser_bot_home(second_home)
      assert_equal second, @daemon.control(:get, detail_path).fetch("current"), "Home only affects future conversations"
      @page.within(".bots-page__current") { @page.click_button "New conversation", exact: true }
      third = @daemon.await("the Bot did not use its new Home") do
        row = @daemon.control(:get, detail_path).fetch("current")
        row if row && row.fetch("workspace_public_id") == second_home
      end
      assert_equal second_home, third.fetch("workspace_public_id")
      assert_browser_bot_readonly(third)
      open_browser_bot("history-helper")
      @page.within(%(li[data-conversation="#{first.fetch("public_id")}"])) { @page.click_button "Resume", exact: true }
      assert_browser_bot_readonly(first)
      assert_equal first, @daemon.control(:get, detail_path).fetch("current")
      open_browser_bot("history-helper")
      @page.select "Archived", from: "Show conversations"
      assert @page.has_css?(".bots-page__history-row", count: 2, wait: WAIT)
      assert @page.has_button?("Open current conversation", disabled: false, wait: WAIT)
      bot_screenshot("bot-history-desktop")
      resize_bot_view(390, 844)
      bot_screenshot("bot-history-narrow")
      resize_bot_view(1400, 1000)
      @page.within(%(li[data-conversation="#{third.fetch("public_id")}"])) { @page.find("a").click }
      assert_browser_bot_readonly(third)
      assert_equal first, @daemon.control(:get, detail_path).fetch("current"), "reading history does not resume it"
      [first_home, second_home].each do |workspace|
        listed = @daemon.control(:get, "/conversations?#{URI.encode_www_form(scope: "main", workspace_public_id: workspace)}").fetch("conversations")
        ids = listed.map { |row| row.fetch("public_id") }
        [first, second, third].each { |row| refute_includes ids, row.fetch("public_id") }
      end
      assert_empty console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
    end

    private

      def save_browser_bot_home(public_id)
        @page.find_field("Home Workspace").find(%(option[value="#{public_id}"]), visible: :all, wait: WAIT).select_option
        @page.click_button "Save Home Workspace"
        assert @page.has_text?("Home Workspace was saved.", wait: WAIT)
      end

      def assert_browser_bot_readonly(locator)
        assert @page.has_text?("This Bot conversation is read-only in the WebUI.", wait: WAIT)
        assert @page.has_field?("Message", disabled: true)
        assert_includes URI(@page.current_url).path, locator.fetch("public_id")
        assert_includes URI(@page.current_url).path, locator.fetch("workspace_public_id")
      end

      def resize_bot_view(width, height)
        resize(width, height)
        assert @page.has_css?(".frame__main") { |main|
          (width >= 768 || main.native.rect.x.zero?) &&
            @page.evaluate_script("document.querySelector('.frame').getAnimations().every(animation => animation.playState !== 'running')")
        }, "the responsive frame settles before the screenshot"
      end

      def bot_screenshot(name)
        assert @page.has_no_css?(".toast"), "save feedback leaves the screenshot unobscured"
        assert @page.has_css?("body") {
          @page.evaluate_script("Array.from(document.querySelectorAll('.frame, dialog')).every(node => node.getAnimations().every(animation => animation.playState !== 'running'))")
        }, "dialogs finish appearing before the screenshot"
        screenshot(name)
      end

      def open_browser_bot(name)
        @page.click_link "Bots", exact: true
        @page.within(%(article[data-bot="#{name}"])) { @page.click_button "Settings", exact: true }
        assert @page.has_field?("Bot name", with: name, wait: WAIT)
      end

      def browser_bot_definition(name)
        @daemon.control(:get, "/agents").fetch("bots").find { |bot| bot.fetch("name") == name } ||
          flunk("the saved Bot #{name} is missing")
      end

      def browser_preset(name)
        @daemon.control(:get, "/presets").fetch("presets").find { |preset| preset.fetch("name") == name } ||
          flunk("the saved Preset #{name} is missing")
      end
  end
end
