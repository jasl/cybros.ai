module CybrosUpdater
  class Docker
    # Nexus owns admission and execution clocks. The installation owner only
    # asks it to drain, waits a bounded time, and resumes after image activation.
    def drain(log:, timeout: 300, poll_interval: 1)
      deadline = monotonic + timeout
      status = maintenance("prepare")
      unless status.fetch("supported")
        if status.fetch("active_work")
          raise Error.new("drain_refused", "This Nexus release cannot drain active work for an upgrade. Wait for its active work to finish before upgrading.")
        end
        log.call("The earlier Nexus release is idle; its first upgrade does not provide active-work draining.\n")
        return
      end
      loop do
        if status.fetch("drained")
          log.call("Active work drained; Nexus remains available until services stop.\n")
          return
        end
        if monotonic >= deadline
          resume_execution(log: log)
          raise Error.new("drain_refused", "Active work did not finish within the upgrade drain deadline. Execution resumed; application services were retained.")
        end
        log.call("Waiting for active work: #{status.fetch("model_attempts")} model requests, #{status.fetch("claimed_tools")} claimed tools, #{status.fetch("kernel_tools")} kernel tools, #{status.fetch("authorization_exchanges")} provider authorization exchanges.\n")
        sleep poll_interval
        status = maintenance("status")
      end
    end

    def resume_execution(log:)
      status = maintenance("resume")
      if status.fetch("supported") && status.fetch("active")
        raise Error.new("resume_failed", "Nexus execution remains paused for deployment maintenance. Inspect the upgrade receipt before resuming.")
      end
      log.call("Execution resumed after deployment maintenance.\n")
    end

    def assert_execution_idle
      if maintenance("status").fetch("active_work")
        raise Error.new("active_work", "The full offline installation update requires idle execution. Wait for active work to finish; use Nexus System upgrade for a managed drain of Nexus alone.")
      end
    end

    private

    def maintenance(operation)
      # The fallback is a conservative read on earlier releases. It cannot
      # retrofit a gate into an old execution host, so active work is refused.
      script = <<~RUBY
        result = if defined?(Deployments::Maintenance)
          Deployments::Maintenance.#{operation}.merge(supported: true)
        else
          active = AgentRun.where.not(status: AgentRun::TERMINAL_STATUSES + ["paused"]).exists? ||
            ModelInvocation.where.not(status: ModelInvocation::TERMINAL_STATUSES).exists? ||
            AgentRunTasks::ToolTask.where(status: "running").exists? ||
            AgentRunTasks::ToolTask.where(status: "dispatched").where.not(claimed_at: nil).exists? ||
            ModelProviderOAuthTask.where(state: "dispatching").exists?
          { supported: false, active_work: active }
        end
        puts "CYBROS_MAINTENANCE=" + JSON.generate(result)
      RUBY
      result = run(compose + ["exec", "-T", "nexus", "bin/rails", "runner", script], timeout: 30)
      line = result.output.lines.find { |entry| entry.start_with?("CYBROS_MAINTENANCE=") }
      unless line
        raise Error.new("maintenance_unavailable", "Nexus did not return its deployment maintenance status.")
      end
      JSON.parse(line.delete_prefix("CYBROS_MAINTENANCE="))
    rescue JSON::ParserError, KeyError
      raise Error.new("maintenance_unavailable", "Nexus returned an incomplete deployment maintenance status.")
    end
  end
end
