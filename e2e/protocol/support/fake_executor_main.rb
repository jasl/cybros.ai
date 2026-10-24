require_relative "fake_executor"

options = JSON.parse($stdin.read).transform_keys(&:to_sym)
kind, tools = options.delete(:kind), options.delete(:tools)
$stdout.sync = true
executor = E2E::FakeExecutor.new(**options, log: ->(event, **fields) { puts JSON.generate(event: event, **fields) })
executor.announce(roles: [kind], tools: tools)
stopped = false
Signal.trap("TERM") { stopped = true; executor.stop }
Signal.trap("INT") { stopped = true; executor.stop }
until stopped
  begin
    executor.sweep
  rescue CybrosAgent::TransportError, CybrosAgent::Api::ServerError
    # A kernel restart leaves the same executor address and inbox authoritative.
  end
  sleep 0.2 unless stopped
end
