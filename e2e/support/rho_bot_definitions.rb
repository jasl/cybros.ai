module E2E
  # Authoring stays on rho's browser surface. Control reads verify reusable
  # configuration and persistent identities after each browser action.
  module RhoBotDefinitions
    WAIT = E2E::RhoDaemon::WATCH_TIMEOUT

    def test_browser_presets_and_bot_identities_use_separate_owners
      visit_console
      lane = provider("dev")
      lane.enable(expected_lock_version: lane.fetch.lock_version)
      open_settings
      @page.click_button "Agent Presets", exact: true
      @page.click_button "New Preset"
      @page.fill_in "Preset name", with: "browser-preset"
      @page.within(".preset-editor") do
        @page.fill_in "Description", with: "Reusable browser test behavior."
        @page.fill_in "System prompt", with: "Keep the reply brief.\nRemember the current person's preferences."
        @page.find_field("Initial model").find('option[value="dev/mock-text"]', visible: :all, wait: WAIT).select_option
        @page.select "No fallback", from: "Fallback models"
        @page.click_button "Create Preset"
      end
      assert @page.has_text?("Preset settings saved.", wait: WAIT)
      preset = browser_preset("browser-preset")
      assert_equal "dev/mock-text", preset.dig("configuration", "model")
      assert_equal [], preset.dig("configuration", "fallback_models")
      @page.find(".page").scroll_to(@page.find(".preset-editor"), align: :top)
      bot_screenshot("preset-editor-desktop")
      resize_bot_view(390, 844)
      @page.find(".page").scroll_to(@page.find(".preset-editor"), align: :top)
      bot_screenshot("preset-editor-narrow")
      resize_bot_view(1400, 1000)

      @page.click_link "Bots", exact: true
      @page.click_button "New bot"
      @page.fill_in "Bot name", with: "browser-helper", exact: true
      @page.fill_in "Display name", with: "Browser helper"
      @page.fill_in "Description", with: "Helps with browser test requests."
      @page.select "browser-preset", from: "Agent Preset"
      @page.select "Custom introduction", from: "Introduction"
      @page.fill_in "Welcome message", with: "Welcome to the browser helper."
      assert @page.has_select?("Purpose", selected: "Personal")
      @page.click_button "Create bot"
      assert @page.has_text?("Browser helper was created.", wait: WAIT)
      original = browser_bot_definition("browser-helper")
      assert_equal "owner", original.fetch("audience")
      assert_equal preset.fetch("public_id"), original.fetch("preset_public_id")
      assert_equal "Welcome to the browser helper.", original.fetch("welcome_message")
      bot_screenshot("bot-detail-desktop")
      resize_bot_view(390, 844)
      bot_screenshot("bot-detail-narrow")
      resize_bot_view(1400, 1000)

      @page.select "External requests", from: "Purpose"
      @page.within(".bots-page__editor") { @page.click_button "Save", exact: true }
      assert @page.has_select?("Purpose", selected: "External requests", disabled: true, wait: WAIT)
      assert @page.has_text?("Duplicate this bot for personal use.")
      assert_equal "external", browser_bot_definition("browser-helper").fetch("audience")
      @page.find(".bots-page").scroll_to(:top)
      bot_screenshot("bot-purpose-desktop")
      resize_bot_view(390, 844)
      @page.find(".bots-page").scroll_to(:top)
      bot_screenshot("bot-purpose-narrow")
      resize_bot_view(1400, 1000)

      @page.click_button "Duplicate", exact: true
      @page.within("dialog") do
        assert @page.has_select?("Purpose", selected: "External requests")
        @page.fill_in "Bot name", with: "browser-personal", exact: true
        @page.fill_in "Display name", with: "Personal helper"
        @page.select "Personal", from: "Purpose"
      end
      bot_screenshot("bot-duplicate-desktop")
      resize_bot_view(390, 844)
      bot_screenshot("bot-duplicate-narrow")
      @page.within("dialog") { @page.click_button "Duplicate", exact: true }
      assert @page.has_no_css?("dialog[open]", wait: WAIT)
      assert @page.has_field?("Bot name", with: "browser-personal", wait: WAIT)
      copied = browser_bot_definition("browser-personal")
      refute_equal original.fetch("public_id"), copied.fetch("public_id")
      assert_equal "owner", copied.fetch("audience")
      assert_equal original.fetch("preset_public_id"), copied.fetch("preset_public_id")
      assert_equal original.fetch("welcome_message"), copied.fetch("welcome_message")
      assert_nil copied.fetch("home_workspace_public_id")
      resize_bot_view(1400, 1000)

      # Both identities reference one Preset; editing its instructions changes
      # future behavior without replacing either identity or copying the Preset.
      @page.click_button "Edit selected Preset"
      assert @page.has_field?("Preset name", with: "browser-preset", wait: WAIT)
      prompt = "  Use the shared updated instructions.\n保留这段文字。\n"
      @page.fill_in "System prompt", with: prompt
      @page.within(".preset-editor") { @page.click_button "Save", exact: true }
      assert @page.has_text?("Preset settings saved.", wait: WAIT)
      preset = browser_preset("browser-preset")
      assert_equal prompt, preset.dig("configuration", "system_prompt")
      [original, copied].each do |before|
        after = browser_bot_definition(before.fetch("name"))
        assert_equal before.fetch("public_id"), after.fetch("public_id")
        assert_equal preset.fetch("public_id"), after.fetch("preset_public_id")
        assert_equal before.fetch("welcome_message"), after.fetch("welcome_message")
      end
      exercise_portable_presets(preset)
      errors = console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
      assert_empty errors, E2E::SecretHygiene.redact(JSON.pretty_generate(errors))
    end

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

    def test_browser_subagent_roles_publish_presets_without_creating_identities
      visit_console
      bots = @daemon.control(:get, "/agents").fetch("bots").map { |row| row.fetch("public_id") }.sort
      reviewer = browser_preset("reviewer")
      open_settings
      @page.click_button "Subagent roles", exact: true
      assert @page.has_css?("article[data-role]", count: 4, wait: WAIT)
      @page.within(%(article[data-role="#{reviewer.fetch("public_id")}"])) { @page.click_button "reviewer", exact: true }
      assert @page.has_field?("Role name", with: "reviewer", wait: WAIT)
      assert @page.has_no_field?("System prompt")
      assert @page.has_no_field?("Initial model")
      @page.fill_in "Role name", with: "browser-reviewer"
      @page.fill_in "When to use this role", with: "Review browser changes and their verification."
      @page.click_button "Save role"
      assert @page.has_css?(%(article[data-role="#{reviewer.fetch("public_id")}"]), text: "browser-reviewer", wait: WAIT)
      saved = browser_preset("reviewer")
      assert_equal reviewer.fetch("configuration"), saved.fetch("configuration")
      assert_equal({ "name" => "browser-reviewer", "description" => "Review browser changes and their verification." }, saved.fetch("role"))
      @page.find(".page").scroll_to(@page.find(".role-editor"), align: :top)
      bot_screenshot("role-editor-desktop")
      resize_bot_view(390, 844)
      @page.find(".page").scroll_to(@page.find(".role-editor"), align: :top)
      bot_screenshot("role-editor-narrow")
      resize_bot_view(1400, 1000)

      @page.within(".role-editor") { @page.click_button "Edit Preset" }
      assert @page.has_field?("Preset name", with: "reviewer", wait: WAIT)
      @page.fill_in "System prompt", with: "Review the supplied browser change and verify the reported behavior."
      @page.within(".preset-editor") { @page.click_button "Save", exact: true }
      assert @page.has_field?("System prompt", with: "Review the supplied browser change and verify the reported behavior.", disabled: false, wait: WAIT)
      @page.click_button "Manage Subagent role"
      assert @page.has_field?("Role name", with: "browser-reviewer", wait: WAIT)
      assert_equal saved.fetch("role"), browser_preset("reviewer").fetch("role")
      @page.click_button "Unpublish role"
      assert @page.has_no_css?(%(article[data-role="#{reviewer.fetch("public_id")}"]), wait: WAIT)
      assert_nil browser_preset("reviewer").fetch("role")

      @page.click_button "New role"
      @page.select "reviewer", from: "Agent Preset"
      @page.fill_in "Role name", with: "browser-reviewer"
      @page.fill_in "When to use this role", with: "Review browser changes."
      @page.click_button "Publish role"
      assert @page.has_css?(%(article[data-role="#{reviewer.fetch("public_id")}"]), text: "browser-reviewer", wait: WAIT)
      assert_equal "Review the supplied browser change and verify the reported behavior.", browser_preset("reviewer").dig("configuration", "system_prompt")
      assert_equal bots, @daemon.control(:get, "/agents").fetch("bots").map { |row| row.fetch("public_id") }.sort
      errors = console_logs.select { |entry| entry.fetch("level") == "SEVERE" }
      assert_empty errors, E2E::SecretHygiene.redact(JSON.pretty_generate(errors))
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

      def exercise_portable_presets(preset)
        bot_ids = @daemon.control(:get, "/agents").fetch("bots").map { |row| row.fetch("public_id") }.sort
        downloads = File.join(@root, "downloads")
        FileUtils.mkdir_p(downloads)
        @page.driver.browser.download_path = downloads
        %w[md json].each do |format|
          label = format == "md" ? "Markdown" : "JSON"
          @page.click_button "Export #{label}"
          path = File.join(downloads, "browser-preset.#{format}")
          @daemon.await("the browser never downloaded the #{label} Preset") { File.file?(path) && File.size?(path) }
          text = File.read(path)
          assert_includes text, preset.fetch("configuration").fetch("system_prompt").lines.first.chomp
          if format == "json"
            exported = JSON.parse(text)
            assert_equal %w[name description configuration].sort, exported.keys.sort
            assert_equal preset.fetch("configuration"), exported.fetch("configuration")
          else
            assert text.start_with?("---\n")
          end
        end

        %w[md json].each do |format|
          @page.click_button "Import Preset", exact: true
          @page.within("dialog") do
            @page.attach_file "Preset file", File.join(downloads, "browser-preset.#{format}")
            assert @page.has_select?("Format", selected: format == "md" ? "Markdown" : "JSON")
            @page.fill_in "Preset name override", with: "browser-import-#{format}"
          end
          bot_screenshot("preset-import-#{format}-desktop")
          resize_bot_view(390, 844)
          bot_screenshot("preset-import-#{format}-narrow")
          @page.within("dialog") { @page.click_button "Import Preset", exact: true }
          assert @page.has_no_css?("dialog[open]", wait: WAIT)
          assert @page.has_field?("Preset name", with: "browser-import-#{format}", wait: WAIT)
          imported = browser_preset("browser-import-#{format}")
          refute_equal preset.fetch("public_id"), imported.fetch("public_id")
          assert_equal preset.fetch("configuration"), imported.fetch("configuration")
          assert_nil imported.fetch("role")
          resize_bot_view(1400, 1000)
        end

        @page.within(%(article[data-preset="#{preset.fetch("public_id")}"])) { @page.click_button "Duplicate" }
        @page.within("dialog") do
          @page.fill_in "Preset name", with: "browser-preset-copy"
          @page.click_button "Duplicate"
        end
        assert @page.has_no_css?("dialog[open]", wait: WAIT)
        assert @page.has_field?("Preset name", with: "browser-preset-copy", wait: WAIT)
        copied = browser_preset("browser-preset-copy")
        refute_equal preset.fetch("public_id"), copied.fetch("public_id")
        assert_equal preset.fetch("configuration"), copied.fetch("configuration")
        assert_nil copied.fetch("role")
        @page.within(%(article[data-preset="#{copied.fetch("public_id")}"])) { @page.click_button "Remove" }
        @page.within("dialog") { @page.click_button "Remove", exact: true }
        assert @page.has_no_css?(%(article[data-preset="#{copied.fetch("public_id")}"]), wait: WAIT)
        refute @daemon.control(:get, "/presets").fetch("presets").any? { |entry| entry.fetch("public_id") == copied.fetch("public_id") }
        assert_equal bot_ids, @daemon.control(:get, "/agents").fetch("bots").map { |row| row.fetch("public_id") }.sort,
          "importing, copying and removing Presets never creates or removes a Bot identity"
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
