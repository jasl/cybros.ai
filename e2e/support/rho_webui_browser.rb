module E2E
  # Browser lifecycle and interactions shared by the WebUI journeys.
  module RhoWebuiBrowser
    MODEL = "dev/mock-text".freeze
    WAIT = E2E::RhoDaemon::WATCH_TIMEOUT

    def setup
      @base_url = E2E.base_url
      @people = E2E::ActorProvisioning.world(@base_url)
      @steward = @people.rho_steward
      @ceremony_actor = E2E::StewardSession.actor(base_url: @base_url, human: @steward)
      @root = Dir.mktmpdir("rho-webui-e2e")
      @project = File.join(@root, "project")
      @agent_project = File.join(@root, "agent-project")
      FileUtils.mkdir_p([@project, @agent_project])
      @artifacts = File.expand_path("../artifacts/rho_webui/#{name}-#{Process.pid}", __dir__)
      @console_logs = []
      configure_provider
      E2E.hosts.start
    end

    def teardown
      if @browser
        @console_logs.concat(@browser.console_logs)
        FileUtils.mkdir_p(@artifacts)
        File.write(File.join(@artifacts, "browser-console.json"),
          E2E::SecretHygiene.redact(JSON.pretty_generate(@console_logs)))
        E2E::SecretHygiene.save_screenshot(@browser, File.join(@artifacts, "failure.png")) unless passed?
        unless passed?
          File.write(File.join(@artifacts, "page.html"), E2E::SecretHygiene.redact(@page.html))
          resources = @page.evaluate_script('performance.getEntriesByType("resource").map(({name, duration, responseStatus}) => ({name, duration, responseStatus}))')
          File.write(File.join(@artifacts, "browser-requests.json"), E2E::SecretHygiene.redact(JSON.pretty_generate(resources)))
        end
      end
      capture_failure_logs unless passed?
    rescue StandardError => error
      warn "Could not capture rho WebUI diagnostics: #{error.class}: #{E2E::SecretHygiene.redact(error.message)}"
    ensure
      @browser&.close
      dispose_daemon(@runner)
      dispose_daemon(@daemon)
      @web_fixture&.stop
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end

    private

      def dispose_daemon(daemon)
        if (result = daemon&.dispose_connection)
          output, status = result
          assert_predicate status, :success?, "rho disconnect failed during cleanup:\n#{output}"
        end
      end

      def configure_provider
        E2E::SessionSignInBudget.consume
        grant = CybrosAgent::Platform::Sessions.new(base_url: @base_url)
          .create(email: @people.owner_email, password: @people.owner_password)
        operator = CybrosAgent::PlatformClient.new(base_url: @base_url, credential: grant.token)
        lane = operator.model_providers.provider("dev")
        lane.enable(expected_lock_version: lane.fetch.lock_version)
      ensure
        operator&.session&.revoke
      end

      def boot_console(mode:, width:, height:, settings: {}, gate: :nexus)
        @daemon = boot_daemon("agent", mode: mode, project: mode == "full" ? @project : @agent_project, settings: settings)
        @workspace_id = @daemon.await("rho never adopted its workspace") do
          workspace = @daemon.status.fetch("workspace")
          workspace.fetch("public_id") if workspace.fetch("state") == "adopted"
        end
        if mode == "agent"
          @runner = boot_daemon("runner", mode: "runner", project: @project)
          @runner.await_announced(address: "runner")
          @runner_id = @runner.status.dig("identity", "runner_executor_public_id")
        else
          @daemon.await_announced(address: "runner")
          @runner_id = @daemon.status.dig("identity", "runner_executor_public_id")
        end
        refute_nil @runner_id
        visit_console(width: width, height: height, authenticate: gate == :nexus, gate: gate)
        configure_console_model
        show_conversations
        assert @page.has_button?("New conversation", wait: WAIT)
      end

      def console_url
        output, status = @daemon.cli("console")
        assert_predicate status, :success?, E2E::SecretHygiene.redact(output)
        url = output[/^console:\s+(\S+)/, 1]
        refute_nil url
        url
      end

      # `gate: :open` expects the page to open by itself; the default expects
      # the Nexus sign-in page.
      def visit_console(width:, height:, authenticate: true, gate: :nexus)
        url = console_url
        @browser = E2E::BrowserActor.new(url)
        @page = @browser.page
        resize_console(width: width, height: height)
        @browser.visit(url)
        if gate == :open
          assert @page.has_field?("Message", wait: WAIT)
          assert @page.has_no_button?("Connect to Nexus")
          return
        end
        assert @page.has_button?("Connect to Nexus", wait: WAIT)
        assert_equal width, @page.evaluate_script("window.innerWidth")
        if authenticate
          @page.click_button "Connect to Nexus"
          @page.fill_in "Email", with: @steward.email
          @page.fill_in "Password", with: @steward.password
          E2E::SessionSignInBudget.consume
          previous_body = @page.find("body", visible: :all).native
          @page.click_button "Sign in"
          # OAuth redirects replace the document; inspect the heading only after Turbo finishes.
          @page.assert_selector("html:not([aria-busy]) > body", visible: :all, wait: WAIT) { |body| body.native != previous_body }
          assert @page.has_css?("h1", text: "Sign in to your application", wait: WAIT)
          @page.click_button "Continue"
          assert @page.has_field?("Message", wait: WAIT)
          assert_nil URI(@page.current_url).query, "OAuth code is removed after login"
        end
      end

      def resize_console(width:, height:)
        @page.current_window.resize_to(width, height)
        @page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride",
          width: width, height: height, deviceScaleFactor: 1, mobile: false)
      end

      # The console journeys sign in with Nexus (`webui_access: nexus`); on
      # loopback the gate would otherwise open by itself, which has its own journey.
      def boot_daemon(name, mode:, project:, connect: true, settings: {})
        home = File.join(@root, name)
        FileUtils.mkdir_p(home)
        File.open(File.join(home, "settings.json"), File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |file|
          file.write(JSON.generate({ "settings_version" => 1, "plugins" => {}, "webui_access" => "nexus" }.merge(settings)))
        end
        daemon = E2E::RhoDaemon.new(base_url: @base_url, home: home, tools_root: project,
          browser_url: mode == "runner" ? nil : E2E.handle.fetch("rho_browser_url"), env: { "RHO_MODE" => mode })
        daemon.start
        E2E::Ceremony.confirm(actor: @ceremony_actor, started: daemon.start_ceremony, status: -> { daemon.status }) if connect
        daemon
      rescue StandardError
        daemon&.stop
        raise
      end

      APPROVAL_LABELS = { "ask" => "Ask before changes", "bypass" => "Bypass permissions", "rules" => "Rules only" }.freeze

      def new_conversation(approval: "ask")
        show_conversations
        @page.click_button "New conversation"
        close_sidebar
        assert @page.has_css?('[role="group"][aria-label="Runner"]', wait: WAIT)
        assert @page.has_button?("Model: Automatic", wait: WAIT)
        choose_menu "Model", model_label(MODEL)
        choose_menu "Runner", runner_choice(@runner_id), runner_name(@runner_id)
        assert @page.has_no_button?("Working directory: #{@project}"), "the runner supplies its working directory"
        choose_menu "Permissions", APPROVAL_LABELS.fetch(approval)
      end

      # The composer's choices are menus: open the one named `name`, pick `label`.
      def choose_menu(name, label, chip = label)
        @page.find("button[aria-label^='#{name}: ']").click
        # Items carry a label and a detail line; the label alone is the choice's name.
        @page.find('[role="menuitemradio"] .menu__label', text: label, exact_text: true, wait: WAIT).click
        assert @page.has_button?("#{name}: #{chip}", wait: WAIT)
      end

      def menu_choices(name)
        @page.find("button[aria-label^='#{name}: ']").click
        labels = @page.all('[role="menuitemradio"] .menu__label', wait: WAIT).map(&:text)
        @page.send_keys :escape
        assert @page.has_no_css?('[role="menu"]', wait: WAIT)
        labels
      end

      def menu_items(name, scope: ".conversation__header")
        @page.within(scope) { @page.click_button name }
        labels = @page.all('[role="menuitem"]', wait: WAIT).map(&:text)
        @page.send_keys :escape
        assert @page.has_no_css?('[role="menu"]', wait: WAIT)
        labels
      end

      # The header menu; the list rows have one of the same name.
      def conversation_action(label)
        @page.within(".conversation__header") { @page.click_button "Conversation actions" }
        @page.find('[role="menuitem"]', text: label, exact_text: true, wait: WAIT).click
      end

      def model_label(ref)
        row = @daemon.control(:get, "/models?workload=text_generation").fetch("models").find { |model| model.fetch("ref") == ref }
        row&.fetch("display_name", nil) || ref
      end

      def runner_row(id) = @daemon.control(:get, "/runners").fetch("runners").find { |runner| runner.fetch("public_id") == id }

      def runner_name(id) = runner_row(id).fetch("display_name", nil) || id

      # The menu names a runner with its ownership and presence; the chip shows its name.
      def runner_choice(id)
        row = runner_row(id)
        [runner_name(id), row["own"] ? "This machine" : nil, row["presence"]].compact.join(" · ")
      end

      # The selected Main Preset owns the model for new WebUI conversations.
      def configure_console_model
        open_settings
        @page.click_button "Agent Presets", exact: true
        assert @page.has_css?(".presets-section", wait: WAIT)
        catalog = @daemon.control(:get, "/presets")
        @page.within(%(article[data-preset="#{catalog.fetch("main_preset_public_id")}"])) do
          @page.find(".preset-catalog__name").click
        end
        @page.find_field("Initial model").find("option[value='#{MODEL}']", visible: :all, wait: WAIT).select_option
        @page.within(".preset-editor") { @page.click_button "Save", exact: true }
        assert @page.has_text?("Preset settings saved.", wait: WAIT)
        close_settings
      end

      # Settings is a main page, reached by the sidebar's link.
      def open_settings
        open_sidebar unless @page.has_link?("Settings", exact: true, wait: 0)
        @page.click_link "Settings", exact: true
        assert @page.has_css?(".settings-page", wait: WAIT)
        @page.click_button "General", exact: true
      end

      # Back to the conversation panel: the sidebar's new conversation.
      def close_settings
        open_sidebar unless @page.has_css?(".sidebar__new", wait: 0)
        @page.find(".sidebar__new").click
        assert @page.has_field?("Message", wait: WAIT)
        close_sidebar
      end

      def open_sidebar
        @page.click_button "Open sidebar"
        assert @page.has_button?("Close sidebar", wait: WAIT)
      end

      # A drawer left open keeps the page behind it inert.
      def close_sidebar
        return unless @page.has_button?("Close sidebar", wait: 0)

        @page.click_button "Close sidebar"
        assert @page.has_no_button?("Close sidebar", wait: WAIT)
      end

      # Below the narrow breakpoint the sidebar is a drawer behind one button.
      def show_conversations
        return if @page.has_button?("New conversation", wait: 0)

        open_sidebar
        assert @page.has_button?("New conversation", wait: WAIT)
      end

      # The send circle is named for what it will do: Send, or while a turn
      # runs, the steer or queue hint.
      def send_message(text)
        # Rapid filling assigns the middle of long text without input events;
        # a live render can overwrite those bytes before the final keystrokes.
        @page.fill_in "Message", with: text, fill_options: { rapid: false }
        assert @page.has_field?("Message", with: text)
        @page.find("button.send:not([disabled])", wait: WAIT).click
      end

      def reply_prompt(text, usage: nil)
        "!mock reply=#{CGI.escape(text)}#{" usage=#{usage}" if usage} -- Give the requested report."
      end

      def send_after_network_failure(text)
        @console_logs.concat(@browser.console_logs)
        @page.driver.browser.network_conditions = { offline: true }
        send_message(text)
        assert @page.has_css?('[role="alert"]', text: "rho could not be reached. Check that it is running, then refresh.", exact_text: true)
        assert @page.has_field?("Message", with: text), "a failed request retains the text"
        offline_logs = @browser.console_logs
        offline_logs.each do |entry|
          next unless entry.fetch("level") == "SEVERE"

          assert_match(/ERR_INTERNET_DISCONNECTED/, entry.fetch("message"))
          entry["expected_network_failure"] = true
        end
        @console_logs.concat(offline_logs)
        @page.driver.browser.delete_network_conditions
        conversation_action "Refresh"
        assert @page.has_field?("Message", with: text)
        @page.find("button.send:not([disabled])", wait: WAIT).click
      ensure
        @page.driver.browser.delete_network_conditions
      end

      def tool_prompt(name, arguments, reply)
        "!mock tool_call=#{name} tool_args=#{CGI.escape(JSON.generate(arguments))} reply=#{CGI.escape(reply)} -- Do the requested work."
      end

      # The address is `/workspaces/<id>/conversations/<id>`.
      def conversation_id
        URI(@page.current_url).path[%r{/conversations/([^/]+)\z}, 1] || flunk("no conversation in #{@page.current_url}")
      end

      # Usage lives in the side panel: the header chip opens it beside the
      # conversation (over it on a phone) and the facts read as a definition list.
      def assert_conversation_usage(requests:, input:, output:, context:)
        assert_equal "rho", @page.title
        assert_match %r{\A/workspaces/[^/]+/conversations/[^/]+\z}, URI(@page.current_url).path
        assert @page.has_no_css?("dialog[open]"), "usage is read in the conversation, without a settings overlay"
        assert @page.has_css?(%(.usage-chip[aria-label^="Usage · #{input + output} tokens"]), wait: WAIT)
        @page.find(".usage-chip").click unless @page.has_css?(".dock .usage__summary", wait: 0)
        @page.within(".dock") do
          assert @page.has_css?(".usage__summary", text: "Usage · #{input + output} tokens", wait: WAIT)
          assert @page.has_css?(".usage__summary", text: "Cost 0.0 USD", wait: WAIT),
            "the configured free model has an exact known zero cost"
          { "Requests" => requests, "Input tokens" => input, "Output tokens" => output,
            "Total tokens" => input + output }.each do |label, count|
            assert @page.has_xpath?(".//dt[normalize-space(.) = '#{label}']/following-sibling::dd[1]",
              exact_text: count.to_s, wait: WAIT), "#{label} must show the conversation's cumulative usage"
          end
          assert @page.has_css?(".usage__summary", text: "Context · #{context} /", wait: WAIT),
            "context occupancy stays the latest request's usage, not the sum of both requests"
          assert @page.has_text?("Latest successful request")
          assert @page.has_text?(MODEL)
        end
      end

      # On a phone the side panel takes the screen; closing it must bring the
      # composer back inside the viewport.
      def assert_expanded_usage_keeps_composer_in_view
        @page.within(".dock") { assert @page.has_css?("dd", text: MODEL, wait: WAIT) }
        @page.click_button "Close side panel"
        assert @page.has_no_css?(".dock", visible: true, wait: WAIT)
        layout = @page.evaluate_script(<<~JS)
          (() => {
            const rect = (selector) => document.querySelector(selector).getBoundingClientRect().toJSON();
            return {
              viewport: { width: window.innerWidth, height: window.innerHeight },
              controls: { Message: rect(".composer__draft"), Send: rect(".send"), "Conversation history": rect(".conversation__scroller") }
            };
          })()
        JS
        viewport = layout.fetch("viewport")
        layout.fetch("controls").each do |label, rect|
          assert rect.fetch("width").positive? && rect.fetch("height").positive? &&
            rect.fetch("left") >= 0 && rect.fetch("top") >= 0 &&
            rect.fetch("right") <= viewport.fetch("width") && rect.fetch("bottom") <= viewport.fetch("height"),
            "#{label} must remain inside the viewport after the side panel closes: #{rect.inspect}"
        end
      end

      def assert_long_history(conversation)
        client = CybrosAgent::Client.new(base_url: @base_url, credential: @steward.member_token)
        chat = client.workspace(@workspace_id).conversations.conversation(conversation)
        # Ordinary message inputs make durable history without forty model calls.
        # The browser still owns reopening, paging and displaying that history.
        44.times do |index|
          chat.inputs.create(kind: "message", text: "History message #{index + 1}", idempotency_key: SecureRandom.uuid)
        end
        @page.refresh
        assert @page.has_text?("History message 44", wait: WAIT)
        refute @page.has_css?("article[data-turn-id] h2", text: "Browser report", wait: 0)
        @page.click_button "Load earlier messages"
        assert @page.has_css?("article[data-turn-id] h2", text: "Browser report", wait: WAIT)
        assert @page.has_text?("History message 44")
        assert_equal 48, @page.all("article[data-turn-id]").length
      end

      def within_assistant_report(&block)
        @page.within("article[data-turn-id]", text: "Browser report", &block)
      end

      def screenshot(name)
        assert @page.evaluate_script("document.documentElement.scrollWidth <= window.innerWidth"),
          "the page must fit the viewport without horizontal scrolling"
        E2E::SecretHygiene.save_screenshot(@browser, File.join(@artifacts, "#{name}.png"))
      end

      def assert_clean_console
        @console_logs.concat(@browser.console_logs)
        errors = @console_logs.select { |entry| entry.fetch("level") == "SEVERE" && !entry["expected_network_failure"] }
        assert_empty errors, E2E::SecretHygiene.redact(JSON.pretty_generate(errors))
      end

      def capture_failure_logs
        FileUtils.mkdir_p(@artifacts)
        [@daemon, @runner].compact.each_with_index do |daemon, index|
          [daemon.log_path, daemon.rho_log_path].each do |path|
            next unless File.file?(path)

            File.write(File.join(@artifacts, "#{index}-#{File.basename(path)}"), E2E::SecretHygiene.redact(File.read(path)))
          end
        end
        rails_log = File.join(E2E.handle.fetch("log_dir"), "rails.log")
        if File.file?(rails_log)
          File.write(File.join(@artifacts, "rails.log"), E2E::SecretHygiene.redact(File.read(rails_log)))
        end
        warn "rho WebUI failure artifacts: #{@artifacts}"
      end
  end
end
