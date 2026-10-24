require "test_helper"
require "rho/env/webrtc_transport"

class WebrtcTransportTest < Minitest::Test
  def test_cancel_during_partial_response_reaps_helper
    with_helper('$stdout.sync = true; STDIN.gets; print "{"; sleep 30') do |executable|
      context = Rho::Env::ExecutionContext.new
      peer = Rho::Env::WebrtcTransport.new(executable: executable, context: context)
      pid = peer.pid
      worker = Thread.new do
        assert_raises(Rho::Env::ExecutionContext::Cancelled) { peer.offer }
      ensure
        peer.close
      end
      sleep 0.05
      context.cancel
      assert worker.join(2), "cancellation must interrupt a partial IPC response"
      assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
      peer.close
    end
  end

  def test_oversized_output_is_rejected_and_helper_is_closeable
    with_helper('$stdout.sync = true; STDIN.gets; print "x" * (130 * 1024); sleep 30') do |executable|
      peer = Rho::Env::WebrtcTransport.new(executable: executable)
      assert_raises(Rho::Env::Error) { peer.offer }
      assert_nil peer.pid
      assert_raises(Rho::Env::Error) { peer.poll }
      assert_raises(ArgumentError) { peer.send_bytes("x" * (16 * 1024 + 1)) }
    ensure
      peer&.close
    end
  end

  def test_closed_permission_discards_received_input_and_refuses_output
    with_helper('STDIN.each_line { puts %q({"data":[{"bytes":"aW5wdXQ=","age_seconds":0.0}],"state":"connected","ready":true}); STDOUT.flush }') do |executable|
      gate = Rho::Env::ClaimRealtime.new(task: nil, claim_token: "fixture", clock: -> { 0 }, log: nil)
      context = Rho::Env::ExecutionContext.new(realtime: gate)
      peer = Rho::Env::WebrtcTransport.new(executable: executable, context: context)
      refute peer.send_bytes("output")
      assert_empty peer.poll.data
    ensure
      peer&.close
    end
  end

  def test_permission_probe_relays_remaining_window_even_when_input_is_paused
    source = <<~RUBY
      require "json"
      STDOUT.sync = true
      STDIN.each_line do |line|
        command = JSON.parse(line)
        if command.fetch("op") == "poll"
          puts JSON.generate(data: [], state: "connected", ready: true, permission: 7)
        else
          File.write(File.join(__dir__, "reply"), line)
          puts "{}"
        end
      end
    RUBY
    with_helper(source) do |executable|
      gate = Rho::Env::ClaimRealtime.new(task: nil, claim_token: "fixture", clock: -> { 0 }, log: nil)
      context = Rho::Env::ExecutionContext.new(realtime: gate)
      peer = Rho::Env::WebrtcTransport.new(executable: executable, context: context)
      assert_empty peer.poll.data
      assert_equal({ "op" => "permission", "nonce" => 7, "max_age_ms" => 0 },
        JSON.parse(File.read(File.join(File.dirname(executable), "reply"))))
    ensure
      peer&.close
    end
  end

  private

    def with_helper(source)
      Dir.mktmpdir("webrtc-helper") do |directory|
        executable = File.join(directory, "peer")
        File.write(executable, "#!#{RbConfig.ruby}\n#{source}\n")
        File.chmod(0o700, executable)
        yield executable
      end
    end
end
