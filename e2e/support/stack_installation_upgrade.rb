require "cgi/escape"

module E2E
  # The installed-product upgrade journey shares the ordinary browser, CLI and
  # public API actors from StackInstallationTest. It owns no kernel mutations.
  module StackInstallationUpgrade
    private

      def assert_upgrade_preserves_installation
        release = ENV.fetch("E2E_STACK_UPGRADE_RELEASE", "")
        return if release.empty?

        assert_match(/\A[0-9]{10}\z/, release, "E2E_STACK_UPGRADE_RELEASE must be a UTC yyMMddHHmm release tag")
        selected = URI(@page.current_url).path.match(%r{\A/workspaces/([^/]+)/conversations/([^/]+)\z})
        refute_nil selected, "the conversation must have its canonical route"
        workspace, conversation = selected.captures
        history = completed_conversation_turns(conversation, workspace: workspace)
        refute_empty history
        settings = rho_api("/settings").fetch("settings")
        assert_equal self.class::MODEL, settings.fetch("default_model")
        provider = cmctl("provider", "show", self.class::PROVIDER)
        assert provider.fetch("model_provider").fetch("configured")
        assert provider.fetch("model_provider").fetch("enabled")
        model = configured_model
        private_files = %w[.env secrets.env].to_h do |name|
          [name, Digest::SHA256.file(File.join(@stack, name)).digest]
        end

        filename = "stack-upgrade-#{SecureRandom.hex(8)}.txt"
        fixture = File.join(@stack, "data", "rho", "work", filename)
        bytes = "Synthetic upgrade attachment\n#{SecureRandom.hex(16)}\n"
        File.binwrite(fixture, bytes)
        File.chmod(0o644, fixture)
        attached = JSON.parse(command_output("rho", "run",
          "!mock reply=Upgrade+attachment+stored. -- Keep this synthetic attachment.",
          "--model", self.class::MODEL, "--no-code-mode", "--attach", "/home/runner/#{filename}", "--output-format", "json"))
        assert_equal "success", attached.fetch("subtype")
        attached_conversation = attached.fetch("conversation_id")
        attached_history = completed_conversation_turns(attached_conversation)
        attachment = attached_history.flat_map { |turn| turn.fetch("active_variant").fetch("attachments", []) }
          .find { |entry| entry.fetch("filename") == filename }
        refute_nil attachment, "the public transcript must retain the uploaded attachment"
        assert_equal bytes.bytes, rho_artifact_bytes(attachment)
        # The saved upload must supply these bytes independently of its sender's file.
        File.unlink(fixture)

        %w[nexus rho].each do |target|
          upgrade_from_browser(release, target: target)
          if target == "nexus"
            assert_active_upgrade_run_completed
            finish_active_upgrade_run
          end
          private_files.each do |name, digest|
            assert digest == Digest::SHA256.file(File.join(@stack, name)).digest,
              "#{name} changed during the #{target} upgrade"
          end
          restore_installation_if_requested if target == "rho"
          assert private_files.fetch("secrets.env") == Digest::SHA256.file(File.join(@stack, "secrets.env")).digest,
            "restoration must retain the original deployment secrets"
          assert_equal @identity, assert_connected_status, "upgrading preserves the profile and both executor IDs"
          assert_equal @executors, executor_snapshot, "upgrading must not re-pair the Agent or Runner"
          @page.refresh
          assert @page.has_field?("Message", wait: self.class::WAIT), "the existing rho tab keeps its Human session after upgrade"
          assert @page.has_no_button?("Connect to Nexus")
          assert @page.has_text?("Mock: Installation is ready.", wait: self.class::WAIT)
          assert_equal history, conversation_turns(conversation, workspace: workspace)
          assert_equal attached_history, conversation_turns(attached_conversation)
          assert_equal bytes.bytes, rho_artifact_bytes(attachment)
          assert_equal settings, rho_api("/settings").fetch("settings")
          assert_equal provider, cmctl("provider", "show", self.class::PROVIDER)
          assert_equal model, configured_model
          assert_model_discovery
        end
        use_upgraded_webui
      ensure
        FileUtils.rm_f(fixture) if fixture
        finish_active_upgrade_run
      end

      def restore_installation_if_requested
        destination = ENV.fetch("E2E_STACK_RESTORE_DIR", "")
        return if destination.empty?

        assert_equal File.expand_path(destination), destination, "restore requires an absolute disposable directory"
        assert !File.exist?(destination) || (File.directory?(destination) && Dir.empty?(destination)), "restore must not overwrite an existing installation"
        FileUtils.mkdir_p(destination, mode: 0o700)
        destination = File.realpath(destination)
        refute_equal @stack, destination
        configuration = File.readlines(File.join(@stack, ".env")).reject { |line| line.start_with?("CYBROS_POSTGRES_IMAGE=", "CYBROS_UPDATER_IMAGE=") }
        work = File.join(@stack, "data", "rho", "work")
        contents = "Backup recovery fixture #{SecureRandom.hex(16)}\n"
        File.write(File.join(work, "backup-fixture.txt"), contents)
        File.symlink("backup-fixture.txt", File.join(work, "backup-fixture-link"))
        # A full offline restore restarts rho, whose HTTP listener precedes stored
        # credential adoption. Keep this tab's session, but resume its conversation
        # reads only after that existing readiness check succeeds. The component
        # upgrades above keep the live rho page throughout their separate restarts.
        rho_page = @page.current_url
        @page.visit("about:blank")
        command_output("stop")
        backup = JSON.parse(command_output("backup"))
        assert_operator backup.fetch("size_bytes"), :>, 0
        assert JSON.parse(command_output("backups")).fetch("installations").any? { |row| row.fetch("id") == backup.fetch("id") }
        File.write(File.join(work, "backup-fixture.txt"), "Changed after the snapshot\n")
        restored = JSON.parse(command_output("restore", backup.fetch("id"), destination))
        assert_equal backup.fetch("id"), restored.fetch("id")
        assert_equal destination, restored.fetch("directory")
        refute restored.fetch("started"), "restoration leaves services stopped for inspection"
        restored_configuration = File.readlines(File.join(destination, ".env")).reject { |line| line.start_with?("CYBROS_POSTGRES_IMAGE=", "CYBROS_UPDATER_IMAGE=") }
        assert configuration == restored_configuration, "restoration preserves deployment configuration apart from frozen image references"
        assert_equal contents, File.read(File.join(destination, "data", "rho", "work", "backup-fixture.txt"))
        assert_equal "backup-fixture.txt", File.readlink(File.join(destination, "data", "rho", "work", "backup-fixture-link"))
        # The copied configuration retains its Compose project and ports. Remove
        # the old stopped containers before that project starts at a new path.
        command_output("compose", "down")
        command_output("manager", "down")
        @stack = File.realpath(destination)
        @command = File.join(@stack, "cybros")
        command_output("up")
        assert_equal @identity, assert_connected_status
        @page.visit(rho_page)
      end

      def configured_model
        model = cmctl("models", "--available").fetch("models").find { |row| row.fetch("ref") == self.class::MODEL }
        refute_nil model, "the configured fake model must remain available"
        model
      end

      def upgrade_from_browser(release, target:)
        before = %w[nexus jobs model_runner rho].to_h { |service| [service, service_snapshot(service)] }
        refute_equal release, before.fetch(target).fetch("version"), "start #{target} on an earlier fixture release"
        label = target == "nexus" ? "Nexus" : "rho"
        card = "section[data-upgrade-target='#{target}']"
        conversation_url = @page.current_url
        @page.visit("#{@rho_url}/panels/settings")
        @page.find("[role='tab']", text: "System upgrade", exact_text: true).click
        @page.within(card) do
          if target == "nexus"
            assert @page.has_checked_field?("Back up the database before upgrading")
            @page.uncheck "Back up the database before upgrading" unless upgrade_backup?
          else
            assert @page.has_no_field?("Back up the database before upgrading")
          end
          @page.fill_in "Release", with: release
          @page.click_button "Check for updates"
          assert @page.has_button?("Upgrade #{label}", disabled: false, wait: self.class::WAIT)
          if target == "nexus"
            assert @page.has_field?("Back up the database before upgrading", checked: upgrade_backup?),
              "the checked preflight must retain the chosen backup behavior"
          end
          assert @page.has_css?(".upgrade-check")
          assert @page.has_text?(release)
        end
        resize(1400, 1000)
        screenshot("rho-#{target}-upgrade-ready-desktop")
        resize(390, 844)
        screenshot("rho-#{target}-upgrade-ready-narrow")
        start_active_upgrade_runs if target == "nexus"
        @page.within(card) { @page.click_button "Upgrade #{label}" }
        @page.within("dialog[open]") { @page.click_button "Upgrade #{label}" }
        progress = @page.find("#{card} .upgrade-progress", text: "Upgrade receipt:", wait: self.class::WAIT)
        operation_id = progress.text[/Upgrade receipt: ([0-9a-f-]+)/, 1]
        refute_nil operation_id, "the browser must retain the accepted upgrade receipt"
        receipt = await_upgrade(operation_id, release, target: target)
        image = receipt.fetch("target").fetch("images").fetch(0)
        image_id = JSON.parse(run_command("docker", "image", "inspect", "--format", "{{json .Id}}", image.fetch("reference")))
        replaced = target == "nexus" ? %w[nexus jobs model_runner] : %w[rho]
        replaced.each do |service|
          after = service_snapshot(service)
          refute_equal before.fetch(service).fetch("id"), after.fetch("id"), "the #{target} upgrade must replace #{service}"
          refute_equal before.fetch(service).fetch("started_at"), after.fetch("started_at"), "#{service} must start anew"
          refute_equal before.fetch(service).fetch("image"), after.fetch("image"), "#{service} must use the new #{target} image"
          assert_equal image_id, after.fetch("image"), "#{service} must run the selected #{target} image"
          assert_equal release, after.fetch("version")
        end
        (before.keys - replaced).each do |service|
          assert_equal before.fetch(service), service_snapshot(service),
            "a #{target} upgrade must retain #{service}'s container, image and start time"
        end
        installed = JSON.parse(command_output("manager", "exec", "-T", "updater", "ruby", "/app/updater.rb", "status")).fetch("installed")
        expected_versions = %w[nexus rho].to_h { |name| [name, before.fetch(name).fetch("version")] }.merge(target => release)
        if expected_versions.values.uniq.size == 1
          assert_equal release, installed.fetch("release")
        else
          assert_nil installed.fetch("release"), "independent component versions must not be reported as one installation release"
        end
        assert_equal %w[nexus rho], installed.fetch("images").map { |entry| entry.fetch("name") }.sort
        versions = installed.fetch("images").to_h { |entry| [entry.fetch("name"), entry.fetch("version")] }
        assert_equal expected_versions, versions
        assert_equal @identity, assert_connected_status
        @page.within(card) do
          assert @page.has_text?("Succeeded", wait: self.class::WAIT), "rho must reconnect to the same successful #{target} receipt"
          assert @page.has_text?("Upgrade receipt: #{operation_id}")
          assert @page.has_css?(".settings-facts dd", text: release, exact_text: true)
          assert @page.has_text?("Database backup created at") if target == "nexus" && upgrade_backup?
        end
        @page.scroll_to(@page.find("#{card} .upgrade-progress", text: "Upgrade receipt: #{operation_id}"), align: :center)
        screenshot("rho-#{target}-upgrade-complete-narrow")
        resize(1400, 1000)
        @page.scroll_to(@page.find("#{card} .upgrade-progress", text: "Upgrade receipt: #{operation_id}"), align: :center)
        screenshot("rho-#{target}-upgrade-complete-desktop")
        @page.visit(conversation_url)
        assert @page.has_field?("Message", wait: self.class::WAIT)
      end

      # An ordinary model-authored tool does real work on the surviving Runner.
      # Its file gate holds the drain until the journey observes it; the
      # test never writes a task result or alters a kernel row.
      def start_active_upgrade_runs
        name = "stack-upgrade-active-#{SecureRandom.hex(8)}"
        @active_directory = File.join(@stack, "data", "rho", "work", name)
        FileUtils.mkdir_p(@active_directory, mode: 0o777)
        File.chmod(0o777, @active_directory)
        @active_gate = File.join(@active_directory, "release")
        @active_effect = File.join(@active_directory, "effects")
        tool = <<~BASH
          printf 'started\n' > started
          until test -f release; do sleep 0.1; done
          printf 'upgrade-tool-finished\n' >> effects
          printf 'upgrade-tool-finished\n'
        BASH
        arguments = { command: tool, workdir: "/home/runner/#{name}", timeout: 540 }
        prompt = "!mock tool_call=bash tool_args=#{CGI.escape(JSON.generate(arguments))} reply=Active+loop+survived+the+upgrade. -- Complete the tool and continue this loop."
        @active_run = Thread.new do
          JSON.parse(command_output("rho", "run", prompt, "--model", self.class::MODEL,
            "--no-code-mode", "--timeout", self.class::UPGRADE_WAIT.to_s, "--output-format", "json", timeout: self.class::UPGRADE_WAIT + self.class::WAIT))
        end
        deadline = monotonic + self.class::WAIT
        until File.exist?(File.join(@active_directory, "started"))
          @active_run.value unless @active_run.alive?
          assert_operator monotonic, :<, deadline, "the real Runner never started the model-authored tool"
          sleep 0.1
        end
        @provider_run = Thread.new do
          JSON.parse(command_output("rho", "run",
            "!mock reply=Provider+request+finished. -- stack-upgrade-provider",
            "--model", self.class::MODEL, "--no-code-mode", "--timeout", self.class::UPGRADE_WAIT.to_s,
            "--output-format", "json", timeout: self.class::UPGRADE_WAIT + self.class::WAIT))
        end
        until File.exist?(File.join(@provider_directory, "requests"))
          @provider_run.value unless @provider_run.alive?
          assert_operator monotonic, :<, deadline, "Nexus never issued the held provider request"
          sleep 0.1
        end
        @work_released_during_drain = false
        @nexus_outage_observed = false
      end

      def release_active_work_during_drain(receipt)
        @nexus_outage_observed ||= !nexus_available?
        return if @work_released_during_drain || receipt.fetch("phase") != "draining"

        assert nexus_available?, "Nexus must stay online while active work drains"
        File.write(@active_gate, "finish before Nexus stops\n")
        File.write(File.join(@provider_directory, "release"), "finish the existing provider request\n")
        @work_released_during_drain = true
      end

      def nexus_available?
        uri = URI.join(@base_url, "/up")
        Net::HTTP.start(uri.host, uri.port, open_timeout: 1, read_timeout: 1) do |http|
          http.get(uri.request_uri).code == "200"
        end
      rescue IOError, SystemCallError, Timeout::Error
        false
      end

      def assert_active_upgrade_run_completed
        assert @work_released_during_drain, "active work must finish through the managed drain"
        assert @nexus_outage_observed, "the upgrade must include an observed Nexus outage"
        assert @provider_run.join(self.class::WAIT), "the original provider request did not finish"
        provider_answer = @provider_run.value
        assert_equal "success", provider_answer.fetch("subtype"), provider_answer.inspect
        assert_equal "Mock: Provider request finished.", provider_answer.fetch("result").strip
        assert_equal ["started"], File.readlines(File.join(@provider_directory, "requests"), chomp: true),
          "the model request must not be reissued during upgrade recovery"
        assert @active_run.join(self.class::WAIT), "the original Agent loop did not resume after Nexus returned"
        answer = @active_run.value
        assert_equal "success", answer.fetch("subtype"), answer.inspect
        assert_equal "completed", answer.fetch("status")
        assert_equal "Mock: Active loop survived the upgrade.", answer.fetch("result").strip
        assert_equal ["upgrade-tool-finished"], File.readlines(@active_effect, chomp: true),
          "the tool's external effect must happen exactly once"
        rounds = rho_api("/runs/transcript?public_id=#{answer.fetch("run_id")}").fetch("transcript").fetch("rounds")
        calls = rounds.flat_map { |round| round.fetch("calls").fetch("items") }
        tools = calls.select { |call| call.fetch("name") == "bash" }
        assert_equal 1, tools.size, "the recovered loop must consume the original tool result once"
        tool = tools.fetch(0)
        assert_equal "completed", tool.fetch("status")
        refute tool["is_error"]
        assert_includes tool.fetch("output_preview"), "upgrade-tool-finished"
        turns = completed_conversation_turns(answer.fetch("conversation_id"))
        assert_equal [answer.fetch("run_id")], turns.filter_map { |turn| turn.dig("active_variant", "run_public_id") }.uniq
      end

      def finish_active_upgrade_run
        return unless @active_run

        primary_error = $!
        cleanup_error = nil
        File.write(@active_gate, "cleanup\n") if File.directory?(@active_directory)
        File.write(File.join(@provider_directory, "release"), "cleanup\n")
        [@active_run, @provider_run].compact.each do |thread|
          begin
            unless thread.join(5)
              thread.kill
              thread.join
            end
          rescue StandardError, Minitest::Assertion => error
            # Joining reports a CLI failure, but the other worker still owns
            # its child command and must finish its ProcessRunner cleanup.
            cleanup_error ||= error
          end
        end
        FileUtils.rm_rf(@active_directory)
        @active_run = @provider_run = nil
        raise cleanup_error if cleanup_error && !primary_error
      end

      def service_snapshot(service)
        id = command_output("compose", "ps", "--quiet", service).strip
        refute_empty id, "#{service} must be running"
        format = "{\"id\":{{json .Id}},\"image\":{{json .Image}},\"started_at\":{{json .State.StartedAt}},\"version\":{{json (index .Config.Labels \"org.opencontainers.image.version\")}}}"
        JSON.parse(run_command("docker", "inspect", "--format", format, id))
      end

      def await_upgrade(operation_id, release, target:)
        deadline = monotonic + self.class::UPGRADE_WAIT
        loop do
          receipt = JSON.parse(command_output("upgrade-status", operation_id))
          release_active_work_during_drain(receipt) if target == "nexus"
          assert_equal operation_id, receipt.fetch("id")
          assert_equal release, receipt.fetch("target").fetch("release")
          assert_equal target == "nexus" && upgrade_backup?, receipt.fetch("backup")
          assert_equal [target], receipt.fetch("target").fetch("images").map { |image| image.fetch("name") }
          case receipt.fetch("status")
          when "succeeded"
            assert_equal "completed", receipt.fetch("phase")
            backup = receipt.fetch("database_backup")
            if target == "nexus" && upgrade_backup?
              assert backup.fetch("available"), "the pre-migration database backup must remain available"
              assert_operator backup.fetch("size_bytes"), :>, 0
              refute_empty backup.fetch("created_at")
            else
              assert_nil backup, "an upgrade without database backup must not create an export receipt"
              if target == "nexus"
                backups = Dir.glob(File.join(@stack, "backups", "databases", "*.sql"))
                assert_empty backups, "the fresh disposable installation must have no SQL backup"
              end
            end
            return receipt
          when "running"
            assert_operator monotonic, :<, deadline, "upgrade did not finish within #{self.class::UPGRADE_WAIT} seconds"
            sleep 1
          else
            flunk "upgrade #{receipt.fetch("status")} during #{receipt.fetch("phase")}: #{receipt["error"]}"
          end
        end
      end

      def upgrade_backup? = ENV.fetch("E2E_STACK_UPGRADE_BACKUP", "true") != "false"

      def use_upgraded_webui
        resize(1400, 1000)
        @page.click_button "New conversation"
        assert_default_model_selected
        send_message("!mock reply=Upgrade+preserved+configuration. -- Confirm the upgraded installation works.")
        assert @page.has_text?("Mock: Upgrade preserved configuration.", wait: self.class::WAIT)
        screenshot("rho-after-upgrade-desktop")
        resize(390, 844)
        screenshot("rho-after-upgrade-narrow")
      end
  end
end
