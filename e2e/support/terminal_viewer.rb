require "support/rho_daemon"

module E2E
  # Mount the shipped task tab against a real daemon for a standalone tool
  # fixture. No model call or conversation authoring is needed for this boundary.
  class TerminalViewer
    def initialize(base_url:, member_key:, application_key:, target:, create: false, ice_servers: [], relay_only: false, browser_driver: :e2e_headless_chrome)
      @relay_only = relay_only
      @root = Dir.mktmpdir("rho-terminal-viewer")
      home = File.join(@root, "home")
      webui = File.join(@root, "webui")
      FileUtils.mkdir_p(home)
      FileUtils.cp_r(File.expand_path("../../agents/rho/rho-webui/webui", __dir__), webui)
      File.write(File.join(webui, "terminal_fixture.js"), create ? creation_script_source(target) : script_source(target))
      File.write(File.join(webui, "index.html"), page_source)
      File.write(File.join(home, "settings.json"), JSON.generate(
        settings_version: 1, webui_root: webui, webui_access: "open", conversation_title_model: nil,
        plugins: { "rho.webui" => { "configuration" => { "ice_servers" => ice_servers } } }
      ), perm: 0o600)
      @daemon = RhoDaemon.new(base_url: base_url, home: home, env: { "RHO_MODE" => "agent" })
      @daemon.start
      output, status = @daemon.cli("connect", "--api-key-stdin", stdin: JSON.generate(
        access_token: member_key, executor_access_token: application_key
      ))
      raise "terminal viewer import failed: #{SecretHygiene.redact(output)}" unless status.success?

      @daemon.await("terminal viewer did not adopt a workspace") { @daemon.status.dig("workspace", "state") == "adopted" }
      output, status = @daemon.cli("console")
      raise "terminal viewer URL failed" unless status.success?

      @url = output[/^console:\s+(\S+)/, 1]
      @browser = BrowserActor.new(@url, driver: browser_driver)
      @browser.visit(@url)
    rescue Exception
      close
      raise
    end

    def page = @browser.page

    def screenshot(path)
      SecretHygiene.save_screenshot(@browser, path)
    end

    def configure_ice(servers)
      output, status = @daemon.cli("extensions", "configure", "rho.webui", JSON.generate([
        { op: "set", path: ["ice_servers"], value: servers },
      ]))
      raise "browser ICE configuration failed: #{SecretHygiene.redact(output)}" unless status.success?
    end

    def diagnostics
      return if @diagnosed

      @diagnosed = true
      directory = File.expand_path("../artifacts/terminal/#{Process.pid}", __dir__)
      FileUtils.mkdir_p(directory)
      states = page.evaluate_async_script(<<~JS)
        const done = arguments[0];
        Promise.all(window.terminalPeers.map(async p => ({state:p.connectionState, ice:p.iceConnectionState,
          stats:[...(await p.getStats()).values()].filter(s => ['candidate-pair','local-candidate','remote-candidate','data-channel'].includes(s.type))}))).then(done);
      JS
      File.write(File.join(directory, "peers.json"), JSON.pretty_generate(states))
      File.write(File.join(directory, "peer-events.json"), JSON.pretty_generate(page.evaluate_script("window.terminalPeerEvents")))
      File.write(File.join(directory, "page.html"), SecretHygiene.redact(page.html))
      File.write(File.join(directory, "console.json"), SecretHygiene.redact(JSON.pretty_generate(@browser.console_logs)))
      File.write(File.join(directory, "daemon.log"), SecretHygiene.redact(File.read(@daemon.log_path)))
      screenshot(File.join(directory, "failure.png"))
    rescue StandardError => error
      warn "Terminal diagnostics failed: #{error.class}"
    end

    def close
      @browser&.close
      @daemon&.stop
      FileUtils.remove_entry(@root) if @root && File.directory?(@root)
    end

    private

      def page_source
        <<~HTML
          <!doctype html><html><head><link rel="icon" href="data:,"><meta name="viewport" content="width=device-width,initial-scale=1">
          <link rel="stylesheet" href="/styles/tokens.css"><link rel="stylesheet" href="/styles/base.css">
          <link rel="stylesheet" href="/styles/primitives.css"><link rel="stylesheet" href="/styles/panels.css">
          <link rel="stylesheet" href="/vendor/xterm/xterm.css"></head><body><main></main>
          <button id="detach">Close panel</button><button id="attach">Reopen task</button>
          <script type="module" src="/terminal_fixture.js"></script></body></html>
        HTML
      end

      def peer_script_source
        <<~JS
          window.terminalPeers = []; window.terminalPeerEvents = [];
          const record = (event) => { terminalPeerEvents.push({time:performance.now(), ...event}); if (terminalPeerEvents.length > 128) terminalPeerEvents.shift(); };
          const NativePeer = RTCPeerConnection;
          window.RTCPeerConnection = class extends NativePeer {
            constructor(configuration) {
              super(#{@relay_only ? "{...configuration, iceTransportPolicy: 'relay'}" : "configuration"});
              this.index = terminalPeers.length; terminalPeers.push(this);
              this.addEventListener('connectionstatechange', () => record({peer:this.index, state:this.connectionState}));
              this.addEventListener('icecandidateerror', (e) => record({peer:this.index, error:e.errorCode}));
            }
            createDataChannel(...args) {
              const data = super.createDataChannel(...args);
              data.addEventListener('message', e => {
                const frame = JSON.parse(e.data instanceof ArrayBuffer ? new TextDecoder().decode(e.data) : e.data);
                if (frame.type === 'receipt') record({peer:this.index, ...frame});
              });
              return data;
            }
          };
        JS
      end

      def creation_script_source(target)
        <<~JS
          import { call, bearer } from '/kernel/api.js';
          import { terminalsPanel } from '/features/terminals/index.js';
          #{peer_script_source}
          const scope = #{JSON.generate(target)};
          bearer.set((await call('/auth/unlock', {method:'POST', body:{}})).bearer);
          window.terminalCall = async (path, options) => {
            const result = await call(path, options);
            if (path === '/terminals' && options?.method === 'POST') {
              window.terminalRequest = options.body;
              window.terminalTarget = result.terminal;
            }
            return result;
          };
          let panel;
          function attach() {
            panel = terminalsPanel({call: window.terminalCall}, {conversation:{workspace:scope.workspace_public_id}});
            document.querySelector('main').replaceChildren(panel.element);
          }
          document.querySelector('#detach').onclick = () => { panel.dispose(); document.querySelector('main').replaceChildren(); };
          document.querySelector('#attach').onclick = attach;
          attach();
        JS
      end

      def script_source(target)
        <<~JS
          import { call, bearer } from '/kernel/api.js';
          import { register } from '/features/task/index.js';
          #{peer_script_source}
          const target = #{JSON.generate(target)};
          bearer.set((await call('/auth/unlock', {method:'POST', body:{}})).bearer);
          let factory, panel;
          register({slots:{register(_name, _meta, component) { factory = component; }}}, {call});
          function attach() {
            panel = factory({conversation:{id:target.public_id,workspace:target.workspace_public_id},
              params:{runId:target.public_id,taskKey:target.task_key}});
            document.querySelector('main').replaceChildren(panel.element);
          }
          document.querySelector('#detach').onclick = () => { panel.dispose(); document.querySelector('main').replaceChildren(); };
          document.querySelector('#attach').onclick = attach;
          attach();
        JS
      end
  end
end
