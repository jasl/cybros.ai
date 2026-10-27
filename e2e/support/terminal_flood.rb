module E2E
  # Bounded overload diagnostic using the shipped PTY, transport and renderer.
  class TerminalFlood
    def initialize(page, root:)
      @page = page
      # Keep the typed command short under CPU throttling. A long WebDriver
      # key burst can outlive the input batch's permission window before flush.
      source = '$stdout.sync=true; finish=Process.clock_gettime(Process::CLOCK_MONOTONIC)+8; block=("abc\\r\\n\\e[31mred\\e[0m\\r\\n"*512); while Process.clock_gettime(Process::CLOCK_MONOTONIC)<finish; print block; end; puts "FLOOD_"+"DONE"'
      File.write(File.join(root, "terminal-flood"), "#!#{RbConfig.ruby}\n#{source}\n", perm: 0o700)
    end

    def exercise
      @page.driver.browser.execute_cdp("HeapProfiler.collectGarbage")
      heap_start = @page.driver.browser.execute_cdp("Runtime.getHeapUsage").fetch("usedSize")
      @page.driver.browser.execute_cdp("Emulation.setCPUThrottlingRate", rate: 4)
      @page.execute_script(<<~JS)
        window.flood = {frames: 0, maxFrameMs: 0, bytes: 0, start: performance.now(),
          heapStart: performance.memory?.usedJSHeapSize};
        let last = performance.now();
        function tick(now) {
          flood.frames++; flood.maxFrameMs = Math.max(flood.maxFrameMs, now - last); last = now;
          if (!flood.done) requestAnimationFrame(tick);
        }
        requestAnimationFrame(tick);
        const peer = terminalPeers.at(-1);
        peer.getStats().then(stats => { flood.bytesStart = [...stats.values()].find(s => s.type === 'data-channel' && s.label === 'terminal')?.bytesReceived || 0; });
      JS
      start = Process.times
      rss_start = IO.popen(["ps", "-o", "rss=", "-p", Process.pid.to_s], &:read).to_i
      @page.find(".xterm-screen").click
      @page.driver.browser.action.send_keys("./terminal-flood", :enter).perform
      raise "flood did not complete" unless @page.has_css?(".xterm-accessibility", text: "FLOOD_DONE", visible: :all, wait: 20)

      metrics = @page.evaluate_async_script(<<~JS)
        const done = arguments[0]; flood.done = true;
        terminalPeers.at(-1).getStats().then(stats => {
          const bytes = [...stats.values()].find(s => s.type === 'data-channel' && s.label === 'terminal')?.bytesReceived || 0;
          done({...flood, elapsedMs: performance.now()-flood.start, bytes: bytes-flood.bytesStart,
            heapEnd: performance.memory?.usedJSHeapSize,
            notice: [...document.querySelectorAll('.terminal .alert:not([hidden])')].map(element => element.textContent).join(' ')});
        });
      JS
      finish = Process.times
      metrics["runner_cpu_seconds"] = finish.utime + finish.stime - start.utime - start.stime
      metrics["runner_rss_start_kib"] = rss_start
      metrics["runner_rss_end_kib"] = IO.popen(["ps", "-o", "rss=", "-p", Process.pid.to_s], &:read).to_i
      @page.driver.browser.execute_cdp("HeapProfiler.collectGarbage")
      metrics["heap_live_start_bytes"] = heap_start
      metrics["heap_live_end_bytes"] = @page.driver.browser.execute_cdp("Runtime.getHeapUsage").fetch("usedSize")
      warn "TERMINAL_FLOOD #{JSON.generate(metrics)}"
      metrics
    ensure
      @page.driver.browser.execute_cdp("Emulation.setCPUThrottlingRate", rate: 1)
    end

    def flood_and_reopen(run_id, &work)
      before = received_bytes
      @page.find(".xterm-screen").click
      @page.driver.browser.action.send_keys("yes FLOOD", :enter).perform
      await_bytes(before + 128 * 1024)
      during_output(&work) if work
      @page.click_button "Close panel"
      @page.click_button "Reopen task"
      @page.find("[data-terminal-id=\"#{run_id}\"]").click
      raise "flood reconnect failed" unless @page.has_css?('.terminal[data-connection="connected"]', wait: 25)

      await_bytes(128 * 1024)
      during_output(&work) if work
      started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
      @page.click_button "Stop terminal"
      raise "flood Stop failed" unless @page.has_css?('.terminal[data-connection="closed"]', wait: 10)

      seconds = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started
      warn "TERMINAL_FLOOD_STOP_SECONDS #{seconds}"
      seconds
    end

    private

      def during_output
        before = received_bytes
        yield
        delivered = received_bytes - before
        raise "terminal output stalled during ordinary work" unless delivered.positive?

        warn "TERMINAL_CONCURRENT_OUTPUT_BYTES #{delivered}"
      end

      def received_bytes
        @page.evaluate_async_script(<<~JS)
          const done = arguments[0];
          terminalPeers.at(-1).getStats().then(stats => {
            done([...stats.values()].find(s => s.type === 'data-channel' && s.label === 'terminal')?.bytesReceived || 0);
          });
        JS
      end

      def await_bytes(target)
        deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        until received_bytes >= target
          raise "terminal flood did not reach the browser" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

          sleep 0.05
        end
      end
  end
end
