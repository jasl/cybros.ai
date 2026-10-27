require "test_helper"
require "rho/env"
require "async"
require "pty"
require "support/realtime_fixture"
require "support/platform_http"
require "support/secret_hygiene"
require "support/webrtc_fixture"
require "support/webrtc_network_fixture"
require "rho/env/webrtc_stream"
require "support/terminal_viewer"
require "support/terminal_flood"
require "support/realtime_concurrent_work"
require "support/browser_certificate_profile"
require "support/turn_recovery_journey"

# Production control plane through ordinary Runner handlers. The queue case
# isolates permission transitions; the WebRTC case exercises real PTY bytes.
class RealtimeSignalingTest < Minitest::Test
  include E2E::RealtimeFixture
  include E2E::TurnRecoveryJourney
  include E2E::RealtimeConcurrentWork

  SDP = "v=0\r\na=fingerprint:sha-256 #{(["AA"] * 32).join(":")}\r\n".freeze

  def test_signaling_and_revocation_keep_one_handler_until_existing_stop_reaps_its_child
    recovery_key = nil
    base_url, _path, _http, _session, member_key, member, transport, executor, key, workspace = prepare_realtime do |http, session, path|
      recovery_key = issue_realtime_key(http, session, "#{path}/api_keys")
    end
    inputs = Thread::Queue.new
    outputs = Thread::Queue.new
    observations = Thread::Queue.new
    tool = Rho::Env::Toolset::Tool.new(name: "realtime_probe", description: "Probe", parameters: { "type" => "object" },
      handler: lambda { |_input, context|
        PTY.spawn(RbConfig.ruby, "-e", '$stdout.sync = true; STDIN.each_line { |line| puts "applied:#{line.strip}" }') do |reader, writer, pid|
          observations << [context, pid]
          begin
            context.realtime.offer(sdp: SDP)
            loop do
              context.raise_if_cancelled!
              if (input = inputs.pop(timeout: 0.01))
                if context.realtime.allowed?
                  writer.puts(input)
                  line = nil
                  line = reader.gets until line&.start_with?("applied:")
                  outputs << line.strip
                else
                  outputs << "refused"
                end
              end
            end
          ensure
            Process.kill("TERM", pid)
            Process.wait(pid)
            observations << :reaped
          end
        end
      })
    @pool = Rho::Env::Pool.new(worker_threads: 1)
    tools = Rho::Env::Toolsets.fixed(toolset: Rho::Env::Toolset.new("realtime_probe" => tool))
    runner_task = Rho::Env::TaskRun.new(executor: executor, pool: @pool, toolsets: tools, log: Log.new)
    Async do |reactor|
      reactor.with_timeout(25) do
        running = reactor.async { runner_task.call(run_public_id: @run.run_public_id, task_key: key, tool_name: "realtime_probe") }
        context, pid = observations.pop
        member_task = @run.tasks_context(key)
        await { member_task.realtime.offer_sdp == SDP }
        offer = member_task.realtime
        assert_equal "waiting", offer.status
        assert_predicate member_task.answer_realtime(connection_id: offer.connection_id, sdp: SDP), :active?
        await { context.realtime.allowed? }
        inputs << "first"
        assert_equal "applied:first", outputs.pop
        transport.unavailable = true
        await { !context.realtime.allowed? }
        await { transport.unavailable_claim_reads.positive? }
        inputs << "offline"
        assert_equal "refused", outputs.pop
        refute context.cancelled?
        assert_equal 1, @pool.in_flight
        assert_equal 1, Process.kill(0, pid)
        transport.unavailable = false
        await { context.realtime.allowed? }
        @run.pause
        await { !context.realtime.allowed? }
        inputs << "paused"
        assert_equal "refused", outputs.pop
        assert_equal 1, @pool.in_flight
        assert_equal 1, Process.kill(0, pid)
        @run.resume
        await { context.realtime.allowed? }
        inputs << "second"
        assert_equal "applied:second", outputs.pop
        CybrosAgent::DeviceFlow::Client.new(base_url: base_url).revoke(token: member_key)
        await { !context.realtime.allowed? }
        inputs << "revoked"
        assert_equal "refused", outputs.pop
        refute context.cancelled?
        assert_equal 1, @pool.in_flight
        claim = executor.inbox_task(run_public_id: @run.run_public_id, task_key: key)
        assert_predicate claim.claim_status(claim_token: context.claim_token), :active?
        member = CybrosAgent::Client.new(base_url: base_url, credential: recovery_key)
        @run = member.workspace(workspace.public_id).run(@run.run_public_id)
        @run.stop(force: true)
        assert_equal :done, running.wait
        assert_equal :reaped, observations.pop
        assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
        assert_equal 0, @pool.in_flight
        refute context.realtime.allowed?
      ensure
        context&.cancel(:canceled)
      end
    end.wait
  ensure
    @pool&.stop
    @run.stop(force: true) if @run && !@run.fetch.terminal?
    @platform&.agents&.agent(@agent_id)&.remove if @agent_id
    @platform&.session&.revoke
  end

  def test_webrtc_direct_and_turn_reconnect_keep_the_existing_pty_and_stop_owner
    _base_url, _path, _http, _session, _member_key, _member, transport, executor, key = prepare_realtime
    # Separate interfaces make host/host an actual network topology, rather
    # than a race among the developer machine's IPv6 and VPN candidates.
    E2E::WebrtcNetworkFixture.open do |fixture|
      observations = Thread::Queue.new
      tool = Rho::Env::Toolset::Tool.new(name: "realtime_probe", description: "Probe", parameters: { "type" => "object" },
        handler: lambda { |_input, context|
          PTY.spawn(RbConfig.ruby, "-e", '$stdout.sync = true; STDIN.each_line { |line| puts "applied:#{line.strip}" }') do |reader, writer, pid|
            peer = nil
            observations << [context, pid]
            begin
              loop do
                peer = fixture.peer(role: "runner", context: context)
                peer.connect(servers: fixture.servers)
                observations << peer.pid
                reconnect = false
                until reconnect
                  context.raise_if_cancelled!
                  packet = peer.poll
                  packet.data.each do |bytes|
                    if bytes == "reconnect"
                      reconnect = true
                    else
                      writer.write(bytes) if context.realtime.allowed?
                    end
                  end
                  if reader.wait_readable(0.01)
                    bytes = reader.read_nonblock(16 * 1024, exception: false)
                    peer.send_bytes(bytes) if bytes && bytes != :wait_readable && packet.ready
                  end
                end
                peer.close
              end
            ensure
              peer&.close
              Process.kill("TERM", pid)
              Process.wait(pid)
              observations << :reaped
            end
          end
        })
      @pool = Rho::Env::Pool.new(worker_threads: 1)
      tools = Rho::Env::Toolsets.fixed(toolset: Rho::Env::Toolset.new("realtime_probe" => tool))
      runner_task = Rho::Env::TaskRun.new(executor: executor, pool: @pool, toolsets: tools, log: Log.new)
      Async do |reactor|
        reactor.with_timeout(45) do
          running = reactor.async { runner_task.call(run_public_id: @run.run_public_id, task_key: key, tool_name: "realtime_probe") }
          context, pid = observations.pop
          task = @run.tasks_context(key)
          peer, connection = answer_webrtc(task, fixture, relay: false)
          helper_pid = observations.pop
          assert_equal ["host", "host"], peer.poll.pair
          assert_webrtc_output(peer, "direct")
          transport.unavailable = true
          await { !context.realtime.allowed? }
          assert peer.send_bytes("offline\n")
          assert_no_webrtc_output(peer)
          assert_equal 1, Process.kill(0, pid)
          assert_equal 1, @pool.in_flight
          refute context.cancelled?
          transport.unavailable = false
          await { context.realtime.allowed? }
          assert_webrtc_output(peer, "resumed", forbidden: "offline")
          assert peer.send_bytes("reconnect")
          # Answerer exposes only TURN candidates; Runner stays in auto mode.
          replacement, second_connection = answer_webrtc(task, fixture, relay: true, previous: connection)
          replacement_pid = observations.pop
          refute_equal connection, second_connection
          assert_raises(Errno::ESRCH) { Process.kill(0, helper_pid) }
          assert_includes replacement.poll.pair, "relay"
          assert_equal 1, Process.kill(0, pid)
          assert_equal 1, @pool.in_flight
          assert_webrtc_output(replacement, "relay")
          @run.stop(force: true)
          assert_equal :done, running.wait
          assert_equal :reaped, observations.pop
          assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
          assert_raises(Errno::ESRCH) { Process.kill(0, replacement_pid) }
          assert_equal 0, @pool.in_flight
          refute context.realtime.allowed?
        ensure
          context&.cancel(:canceled)
          peer&.close
          replacement&.close
        end
      end.wait
      await { fixture.helpers_reaped? }
      assert fixture.helpers_reaped?, "both containers must reap their transport helpers"
    end
  ensure
    @pool&.stop
    @run.stop(force: true) if @run && !@run.fetch.terminal?
    @platform&.agents&.agent(@agent_id)&.remove if @agent_id
    @platform&.session&.revoke
  end

  def test_output_window_recovers_disconnected_pty_bytes_and_reports_overflow_gap
    _base_url, _path, _http, _session, _member_key, _member, _transport, executor, key = prepare_realtime
    E2E::WebrtcNetworkFixture.open do |fixture|
      observations = Thread::Queue.new
      source = <<~RUBY
        require "io/console"
        STDIN.echo = false
        $stdout.sync = true
        STDIN.each_line do |line|
          case line.strip
          when "later"
            puts "armed-later"
            Thread.new { sleep 1; puts "offline-kept" }
          when "burst"
            puts "armed-burst"
            Thread.new { sleep 1; print "x" * (64 * 1024); puts "burst-tail" }
          else
            puts "applied:\#{line.strip}"
          end
        end
      RUBY
      tool = Rho::Env::Toolset::Tool.new(name: "realtime_probe", description: "Probe", parameters: { "type" => "object" },
        handler: lambda { |_input, context|
          PTY.spawn(RbConfig.ruby, "-e", source) do |reader, writer, pid|
            connection = fixture.connection(context: context)
            stream = Rho::Env::WebrtcStream.new(connection: connection, context: context, window_bytes: 16 * 1024)
            observations << [context, pid, connection]
            begin
              loop do
                packet = stream.poll
                packet.data.each { |bytes| stream.acknowledge_input(context.realtime.allowed? ? writer.write(bytes) : 0) }
                if reader.wait_readable(0.01)
                  bytes = reader.read_nonblock(16 * 1024, exception: false)
                  if bytes && bytes != :wait_readable
                    stream.write_output(bytes)
                    observations << :burst_captured if bytes.include?("burst-tail")
                  end
                end
              end
            ensure
              stream.close
              Process.kill("TERM", pid)
              Process.wait(pid)
              observations << :reaped
            end
          end
        })
      @pool = Rho::Env::Pool.new(worker_threads: 1)
      tools = Rho::Env::Toolsets.fixed(toolset: Rho::Env::Toolset.new("realtime_probe" => tool))
      runner_task = Rho::Env::TaskRun.new(executor: executor, pool: @pool, toolsets: tools, log: Log.new)
      Async do |reactor|
        reactor.with_timeout(60) do
          running = reactor.async { runner_task.call(run_public_id: @run.run_public_id, task_key: key, tool_name: "realtime_probe") }
          context, pid, connection = observations.pop
          original_claim = context.claim_token
          task = @run.tasks_context(key)
          receiver = Rho::Env::WebrtcStream::Receiver.new
          member_connection = nil
          peer = nil
          last_request = 0.0
          output = +"".b
          gaps = []
          # This one member loop owns answer, poll and consumption. Retry only
          # the idempotent cursor request if a permission window dropped it.
          step = lambda do
            offer = task.realtime
            if offer.offer_sdp && offer.connection_id != member_connection
              peer&.close
              peer = fixture.peer
              sdp = peer.answer(sdp: offer.offer_sdp, servers: fixture.servers)
              task.answer_realtime(connection_id: offer.connection_id, sdp: sdp)
              member_connection = offer.connection_id
              last_request = 0.0
            end
            if peer
              packet = peer.poll
              packet.data.each do |bytes|
                receiver.receive(bytes).each do |event|
                  case event
                  in Rho::Env::WebrtcStream::Output(bytes: data)
                    output << data
                  in Rho::Env::WebrtcStream::Receipt
                    assert_includes %w[received written], event.status
                  in Rho::Env::WebrtcStream::Gap
                    gaps << event
                  else
                    flunk "Unexpected stream event"
                  end
                end
              end
              now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
              if packet.ready && (packet.data.any? || now - last_request >= 0.5)
                assert peer.send_bytes(receiver.resume)
                last_request = now
              end
              packet.ready
            end
          end
          await { step.call }
          assert_equal ["host", "host"], peer.poll.pair
          assert peer.send_bytes(receiver.input("online\n"))
          await { step.call; output.include?("applied:online") }
          assert peer.send_bytes(receiver.input("later\n"))
          await { step.call; output.include?("armed-later") }
          first_connection = member_connection
          fixture.block_direct
          assert peer.send_bytes(receiver.input("lost-input\n"))
          await(seconds: 25) { step.call; member_connection != first_connection && output.include?("offline-kept") }
          assert_includes peer.poll.pair, "relay"
          assert_equal 1, output.scan("applied:online").size
          assert_equal 1, output.scan("offline-kept").size
          refute_includes output, "lost-input"
          assert_empty gaps
          assert_equal original_claim, context.claim_token
          claim = executor.inbox_task(run_public_id: @run.run_public_id, task_key: key)
          assert_predicate claim.claim_status(claim_token: original_claim), :active?
          assert_equal 1, Process.kill(0, pid)
          assert_equal 1, @pool.in_flight
          assert peer.send_bytes(receiver.input("burst\n"))
          await { step.call; output.include?("armed-burst") }
          fixture.block_relay
          assert peer.send_bytes(receiver.resume)
          # Observe actual PTY capture while the network is blocked; only the
          # later public DataChannel gap establishes the recovery result.
          await { observations.pop(timeout: 0.01) == :burst_captured }
          assert_operator fixture.dropped_packets("runner"), :>, 0
          fixture.unblock_relay
          await { step.call; gaps.any? }
          gap = gaps.first
          assert_operator gap.to - gap.from, :>=, 32 * 1024
          assert_match(/Output gap: \d+ bytes are unavailable\./, gap.message)
          assert_equal 1, Process.kill(0, pid)
          # Stop while retained output still awaits consumption.
          refute_includes output, "burst-tail"
          helper_pid = connection.pid
          @run.stop(force: true)
          assert_equal :done, running.wait
          assert_equal :reaped, observations.pop
          assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
          assert_raises(Errno::ESRCH) { Process.kill(0, helper_pid) }
          assert_equal 0, @pool.in_flight
          refute context.realtime.allowed?
          peer.close
          await(seconds: 12) { fixture.helpers_reaped? }
        ensure
          context&.cancel(:canceled)
          peer&.close
        end
      end.wait
    end
  ensure
    @pool&.stop
    @run.stop(force: true) if @run && !@run.fetch.terminal?
    @platform&.agents&.agent(@agent_id)&.remove if @agent_id
    @platform&.session&.revoke
  end

  def test_browser_terminal_entry_reconnects_reports_gap_detaches_and_stops_original_pty
    viewer = nil
    application_key = nil
    base_url, _path, _http, _session, member_key, _member, _transport, executor, key, workspace = prepare_realtime(detached: true, application_runner: false) do |http, session, path|
      application_key = issue_realtime_key(http, session, "#{path}/executor/api_keys")
    end
    address = Socket.ip_address_list.find { |candidate| candidate.ipv4? && !candidate.ipv4_loopback? }.ip_address
    E2E::WebrtcFixture.open(address: address) do |fixture|
      viewer = E2E::TerminalViewer.new(base_url: base_url, member_key: member_key, application_key: application_key,
        executable: fixture.binary, target: { public_id: @run.run_public_id, task_key: key, workspace_public_id: workspace.public_id })
      # Both peers need TURN candidates when an obscured browser host address
      # cannot be reached from the Runner's relay allocation.
      viewer.configure_ice(fixture.servers)
      observations = Thread::Queue.new
      source = <<~RUBY
        require "io/console"
        STDIN.echo = false
        $stdout.sync = true
        STDIN.each_line do |line|
          if line.strip == "burst"
            print "x" * (64 * 1024)
            puts "burst-tail"
          else
            puts "applied:\#{line.strip}:pid=\#{Process.pid}"
          end
        end
      RUBY
      tool = Rho::Env::Toolset::Tool.new(name: "realtime_probe", description: "Probe", parameters: { "type" => "object" },
        handler: lambda { |_input, context|
          PTY.spawn(RbConfig.ruby, "-e", source) do |reader, writer, pid|
            connection = fixture.connection(context: context)
            stream = Rho::Env::WebrtcStream.new(connection: connection, context: context, window_bytes: 1024)
            observations << [context, pid, connection]
            begin
              loop do
                packet = stream.poll
                packet.data.each { |bytes| stream.acknowledge_input(context.realtime.allowed? ? writer.write(bytes) : 0) }
                if reader.wait_readable(0.01)
                  bytes = reader.read_nonblock(16 * 1024, exception: false)
                  stream.write_output(bytes) if bytes && bytes != :wait_readable
                end
              end
            ensure
              stream.close
              Process.kill("TERM", pid)
              Process.wait(pid)
              observations << :reaped
            end
          end
        })
      @pool = Rho::Env::Pool.new(worker_threads: 1)
      tools = Rho::Env::Toolsets.fixed(toolset: Rho::Env::Toolset.new("realtime_probe" => tool))
      runner_task = Rho::Env::TaskRun.new(executor: executor, pool: @pool, toolsets: tools, log: Log.new)
      Async do |reactor|
        reactor.with_timeout(90) do
          running = reactor.async { runner_task.call(run_public_id: @run.run_public_id, task_key: key, tool_name: "realtime_probe") }
          context, pid, connection = observations.pop
          original_claim = context.claim_token
          page = viewer.page
          page.click_button "Open terminal"
          assert page.has_css?('.terminal[data-connection="connected"]', wait: 20)
          page.find(".xterm-screen").click
          page.driver.browser.action.send_keys("first", :enter).perform
          assert page.has_css?(".xterm-accessibility", text: "applied:first:pid=#{pid}", visible: :all, wait: 10)
          first_connection = connection.connection_id
          # Kill only the replaceable transport helper, not the PTY/handler.
          Process.kill("TERM", connection.pid)
          assert page.has_css?(".terminal .alert", text: "Reconnecting", wait: 10)
          await(seconds: 20) { connection.connection_id != first_connection }
          assert page.has_css?('.terminal[data-connection="connected"]', wait: 20)
          page.find(".xterm-screen").click
          page.driver.browser.action.send_keys("second", :enter).perform
          assert page.has_css?(".xterm-accessibility", text: "applied:second:pid=#{pid}", visible: :all, wait: 10)
          assert_equal original_claim, context.claim_token
          page.find(".xterm-screen").click
          page.driver.browser.action.send_keys("burst", :enter).perform
          assert page.has_css?(".terminal .alert", text: "Screen cleared because some output could not be restored.", wait: 10)
          assert page.has_css?(".xterm-accessibility", text: "burst-tail", visible: :all, wait: 10)
          directory = File.expand_path("../artifacts/terminal/#{Process.pid}", __dir__)
          FileUtils.mkdir_p(directory)
          viewer.screenshot(File.join(directory, "desktop.png"))
          page.current_window.resize_to(390, 844)
          page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: false)
          assert page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")
          viewer.screenshot(File.join(directory, "narrow.png"))
          page.click_button "Close panel"
          assert_equal 1, Process.kill(0, pid)
          refute context.cancelled?
          page.click_button "Reopen task"
          page.click_button "Open terminal"
          assert page.has_css?('.terminal[data-connection="connected"]', wait: 25)
          page.find(".xterm-screen").click
          page.driver.browser.action.send_keys("reattached", :enter).perform
          assert page.has_css?(".xterm-accessibility", text: "applied:reattached:pid=#{pid}", visible: :all, wait: 10)
          page.click_button "Stop terminal"
          assert page.has_css?('.terminal[data-connection="closed"]', wait: 10)
          running.wait
          assert_equal :reaped, observations.pop
          refute_equal "canceled", @run.task("mainline").task.status
          assert_equal original_claim, context.claim_token
          assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
          assert_equal 0, @pool.in_flight
        ensure
          context&.cancel(:canceled)
        end
      end.wait
    end
  ensure
    viewer&.diagnostics if $!
    viewer&.close
    @pool&.stop
    @run.stop(force: true) if @run && !@run.fetch.terminal?
    @platform&.agents&.agent(@agent_id)&.remove if @agent_id
    @platform&.session&.revoke
  end

  def test_browser_creates_production_terminal_reopens_same_claim_and_stops_jobs
    exercise_production_terminal
  end

  def test_browser_turn_tcp_reopens_original_terminal_and_stops_its_jobs
    exercise_production_terminal(transport: "tcp")
  end

  def test_browser_turn_tls_reopens_original_terminal_and_stops_its_jobs
    exercise_production_terminal(transport: "tls")
  end

  def test_browser_terminal_flood_keeps_file_tasks_and_control_http_available
    exercise_production_terminal(transport: "tcp", concurrent_files: true)
  end

  def test_browser_untrusted_turn_tls_recovers_after_configuration_repair
    address = Socket.ip_address_list.find { |candidate| candidate.ipv4? && !candidate.ipv4_loopback? }.ip_address
    E2E::WebrtcFixture.open(address: address, transport: "tls") do |rejected|
      exercise_production_terminal(transport: "tcp", rejected_tls: rejected)
    end
  end

  private

    def exercise_production_terminal(transport: "udp", rejected_tls: nil, concurrent_files: false)
      viewer = nil
      base_url, path, http, session, member_key, member, _transport, executor, key, workspace = prepare_realtime(start: false, application_runner: false)
      application_key = issue_realtime_key(http, session, "#{path}/executor/api_keys")
      address = Socket.ip_address_list.find { |candidate| candidate.ipv4? && !candidate.ipv4_loopback? }.ip_address
      E2E::WebrtcFixture.open(address: address, transport: transport) do |fixture|
        E2E::BrowserCertificateProfile.open(fixture.certificate) do |browser_driver|
          extensions = [Rho::Env::Extensions::Terminal]
          extensions << Rho::Env::Extensions::Coding if concurrent_files
          loaded = Rho::Env::Extensions::Loader.call(builtin: extensions,
            api_options: { configuration: { "executable" => fixture.binary, "ice_servers" => transport == "tls" ? [] : fixture.servers } })
          assert_predicate loaded, :ok?
          Dir.mktmpdir("terminal-work") do |root|
            executor.announce(services: { "runner" => { "tools" => loaded.registry.announcement,
              "environment" => { "root" => root } } })
            env = Rho::Env::ToolEnv.new(root: root, artifacts_dir: File.join(root, "artifacts"))
            toolset = loaded.registry.toolset(env: env)
            original = toolset.fetch("terminal")
            observations = Thread::Queue.new
            observed = original.with(handler: lambda { |input, context|
              observations << context
              original.handler.call(input, context)
            })
            @pool = Rho::Env::Pool.new(worker_threads: concurrent_files ? 2 : 1)
            served = { "terminal" => observed }
            served["read"] = toolset.fetch("read") if concurrent_files
            tools = Rho::Env::Toolsets.fixed(env: env, toolset: Rho::Env::Toolset.new(served))
            task_run = Rho::Env::TaskRun.new(executor: executor, pool: @pool, toolsets: tools, log: Log.new)
            viewer = E2E::TerminalViewer.new(base_url: base_url, member_key: member_key, application_key: application_key,
              executable: fixture.binary, target: { workspace_public_id: workspace.public_id }, create: true,
              ice_servers: fixture.servers, relay_only: transport != "udp", browser_driver: browser_driver)
            page = viewer.page
            assert page.has_button?("New terminal", disabled: false)
            page.click_button "New terminal"
            await { page.evaluate_script("window.terminalTarget || null") }
            target = page.evaluate_script("window.terminalTarget")
            @run = member.workspace(workspace.public_id).runs.run(target.fetch("public_id"))
            assert_equal root, @run.task(key).executor_context.dig("rho.environment", "root")
            replay = page.evaluate_async_script("const done=arguments[0]; window.terminalCall('/terminals',{method:'POST',body:window.terminalRequest}).then(done);")
            assert_equal target, replay.fetch("terminal")
            # Creation accepts work before dispatch; this fixture attempts the claim only once.
            await(message: "The browser-created terminal was never dispatched") { @run.task(key).task.status == "dispatched" }
            Async do |reactor|
              reactor.with_timeout(90) do
                running = reactor.async { task_run.call(run_public_id: @run.run_public_id, task_key: key, tool_name: "terminal") }
                context = observations.pop
                claim = context.claim_token
                assert page.has_css?('.terminal[data-connection="connected"]', wait: 20)
                assert_browser_relay(page, transport: transport) if transport != "udp"
                page.find(".xterm-screen").click
                page.driver.browser.action.send_keys("printf 'SHELL:%s\\n' $$; pwd", :enter).perform
                assert page.has_css?(".xterm-accessibility", text: root, visible: :all, wait: 10)
                assert page.has_css?('.terminal[data-input-receipt="written"]', wait: 10)
                pid = page.find(".xterm-accessibility", visible: :all).text(:all).match(/SHELL:(\d+)/)[1].to_i
                if rejected_tls
                  viewer.configure_ice(rejected_tls.servers)
                  page.click_button "Close panel"
                  page.click_button "Reopen task"
                  page.find("[data-terminal-id=\"#{@run.run_public_id}\"]").click
                  await(seconds: 20, message: "Untrusted TLS gathering did not fail") do
                    page.evaluate_script("terminalPeerEvents.some(e => e.error === 701 && e.peer === terminalPeers.length - 1) && terminalPeers.at(-1).iceGatheringState === 'complete'")
                  end
                  assert_includes rejected_tls.errors, "TLS handshake failed: remote error: tls: unknown certificate"
                  refute page.evaluate_script("terminalPeers.at(-1).connectionState === 'connected'")
                  refute_includes page.evaluate_script("terminalPeers.at(-1).localDescription.sdp"), " typ relay"
                  assert_equal claim, context.claim_token
                  assert_equal 1, Process.kill(0, pid)
                  viewer.configure_ice(fixture.servers)
                end
                page.click_button "Close panel"
                refute context.cancelled?
                assert_equal 1, Process.kill(0, pid)
                page.click_button "Reopen task"
                assert page.has_css?("[data-terminal-id=\"#{@run.run_public_id}\"]", wait: 10)
                page.find("[data-terminal-id=\"#{@run.run_public_id}\"]").click
                assert page.has_css?('.terminal[data-connection="connected"]', wait: 25)
                assert_browser_relay(page, transport: transport) if transport != "udp"
                page.find(".xterm-screen").click
                page.driver.browser.action.send_keys("printf 'SAME:%s\\n' $$", :enter).perform
                assert page.has_css?(".xterm-accessibility", text: "SAME:#{pid}", visible: :all, wait: 10)
                assert_equal claim, context.claim_token
                assert_empty observations
                directory = File.expand_path("../artifacts/terminal/#{Process.pid}", __dir__)
                FileUtils.mkdir_p(directory)
                viewer.screenshot(File.join(directory, "creation-desktop.png"))
                page.current_window.resize_to(390, 844)
                page.driver.browser.execute_cdp("Emulation.setDeviceMetricsOverride", width: 390, height: 844, deviceScaleFactor: 1, mobile: false)
                assert page.evaluate_script("document.documentElement.scrollWidth <= innerWidth")
                viewer.screenshot(File.join(directory, "creation-narrow.png"))
                assert_browser_relay(page, transport: transport) if transport != "udp"
                page.find(".xterm-screen").click
                flood = E2E::TerminalFlood.new(page, root: root)
                metrics = flood.exercise
                assert_operator metrics.fetch("bytes"), :>, 512 * 1024
                assert_operator metrics.fetch("maxFrameMs"), :<, 500
                assert_operator metrics.fetch("heap_live_end_bytes") - metrics.fetch("heap_live_start_bytes"), :<, 32 * 1024 * 1024
                if concurrent_files
                  work = lambda do
                    assert_equal 1, @pool.in_flight
                    assert_realtime_concurrent_read(task_run: task_run, runs: member.workspace(workspace.public_id).runs,
                      executor_id: executor.executor.executor.public_id, root: root)
                    assert_equal claim, context.claim_token
                    assert_equal 1, Process.kill(0, pid)
                    refute context.cancelled?
                    assert_equal "dispatched", @run.task(key).task.status
                    assert_equal 1, @pool.in_flight
                  end
                end
                assert_operator flood.flood_and_reopen(@run.run_public_id, &work), :<, 5
                assert_equal claim, context.claim_token
                assert_empty observations
                assert page.has_css?('.terminal[data-connection="closed"]', wait: 10)
                running.wait
                assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
                assert_equal "canceled", @run.task(key).task.status
                assert_equal 0, @pool.in_flight
              rescue Exception
                viewer.diagnostics
                raise
              ensure
                context&.cancel(:canceled)
              end
            end.wait
          end
        ensure
          viewer&.diagnostics if $!
          viewer&.close
        end
      end
    ensure
      @pool&.stop
      @run.stop(force: true) if @run && !@run.fetch.terminal?
      CybrosAgent::DeviceFlow::Client.new(base_url: base_url).revoke(token: @independent_runner_credential) if @independent_runner_credential
      @platform&.agents&.agent(@agent_id)&.remove if @agent_id
      @platform&.session&.revoke
    end

    def assert_browser_relay(page, transport:)
      candidate = page.evaluate_async_script(<<~JS)
        const done = arguments[0];
        window.terminalPeers.at(-1).getStats().then(stats => {
          const transport = [...stats.values()].find(s => s.type === 'transport' && s.selectedCandidatePairId);
          const pair = stats.get(transport?.selectedCandidatePairId);
          const local = stats.get(pair?.localCandidateId);
          done(local ? {type:local.candidateType, relayProtocol:local.relayProtocol, url:local.url} : null);
        });
      JS
      assert_equal "relay", candidate.fetch("type")
      assert_equal transport, candidate.fetch("relayProtocol")
      scheme = transport == "tls" ? "turns" : "turn"
      assert_match(/\A#{scheme}:.*\?transport=tcp\z/, candidate.fetch("url"))
    end

    def answer_webrtc(task, fixture, relay:, previous: nil)
      offer = nil
      await do
        offer = task.realtime
        offer.offer_sdp && offer.connection_id != previous
      end
      peer = fixture.peer
      sdp = peer.answer(sdp: offer.offer_sdp, servers: fixture.servers, relay: relay)
      assert_predicate task.answer_realtime(connection_id: offer.connection_id, sdp: sdp), :active?
      await { peer.poll.ready }
      [peer, offer.connection_id]
    rescue Exception
      peer&.close
      raise
    end

    def assert_webrtc_output(peer, text, forbidden: nil)
      assert peer.send_bytes("#{text}\n")
      output = +""
      await do
        output << peer.poll.data.join
        output.include?("applied:#{text}")
      end
      refute_includes output, forbidden if forbidden
    end

    def assert_no_webrtc_output(peer)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 0.2
      output = +""
      while Process.clock_gettime(Process::CLOCK_MONOTONIC) < deadline
        output << peer.poll.data.join
        sleep 0.01
      end
      assert_empty output
    end
end
