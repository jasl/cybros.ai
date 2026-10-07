module Rho
  class Daemon
    class Lineage
      # The followers, the shared realtime client and the runners a lineage placed —
      # the "retire" family: reserve or mint
      # inside the monitor, build outside it, install with a CAS on `about`.
      #
      # TWO RUNNER SLOTS: `:runner` is the run on the
      # in-process runner's own address and credential, `:agent_runner` the
      # run on the agent-application address (the agent's own tools). Each
      # slot has its own executor socket on its own credential; a holder
      # replacement retires them together, and each lineage's loss retires
      # only its own slot.
      module Retirement
        # Minted through the factory, so construction stays pure; the credential
        # lambda re-checks currency outside the monitor at handshake time.
        # `about` is recorded BEFORE the mint so a factory that reads the
        # credential at once (a test double keyed by plane) finds the
        # lineage current.
        def realtime_for(about)
          credential = -> { member_credential_of(about) }
          @monitor.synchronize do
            next nil if about.nil? || !@credentials.equal?(about)

            unless @realtime && @realtime_about.equal?(about)
              @realtime_about = about
              @realtime = @realtime_factory.call(credential)
            end
            @realtime
          end
        end

        # The executor socket's twin: one more client per slot,
        # on the slot's transport credential, for the runner's inbox channel.
        # It is shared with nothing, held here so every edge closes it.
        def executor_realtime_for(about, slot: :runner)
          credential = -> { executor_credential_of(about, slot) }
          @monitor.synchronize do
            next nil if about.nil? || !@credentials.equal?(about)

            unless @executor_realtimes[slot] && @executor_realtime_abouts[slot].equal?(about)
              @executor_realtime_abouts[slot] = about
              @executor_realtimes[slot] = @realtime_factory.call(credential)
            end
            @executor_realtimes[slot]
          end
        end

        # A follower is added only while `about` is the current lineage; the caller
        # still gets a follower to answer with (on both lanes).
        def install_follower(about, follower)
          public_id = follower.public_id
          @monitor.synchronize do
            current = !about.nil? && @credentials.equal?(about)
            existing = @followers[public_id]
            next [existing, false] if current && existing
            next [follower, false] unless current

            @followers[public_id] = follower
            [follower, true]
          end
        end

        # One follower out of the set, by id — the follower is handed back for
        # its caller to stop outside the monitor (a stop reaches a socket);
        # nil when nobody here follows that id.
        def drop_follower(public_id) = @monitor.synchronize { @followers.delete(public_id) }

        def rebind_runs
          followers = @monitor.synchronize { @followers.values }
          followers.filter_map(&:realtime).uniq
        end

        def retire_runs = @monitor.synchronize { retire_locked }

        def reserve_runner(about, slot: :runner)
          @monitor.synchronize do
            next false if @stopping || !@credentials.equal?(about)
            next false if @runners[slot] && @runner_abouts[slot].equal?(about)

            @runner_abouts[slot] = about
            true
          end
        end

        # A reservation given back without a runner — the executor plane had
        # no credential to build one on — so a later edge may place one.
        def release_runner(about, slot: :runner)
          @monitor.synchronize do
            next false unless @runners[slot].nil? && @runner_abouts[slot].equal?(about)

            @runner_abouts.delete(slot)
            true
          end
        end

        def install_runner(about, runner, tool_env, slot: :runner)
          @monitor.synchronize do
            next false if @stopping || @runners[slot] || !@runner_abouts[slot].equal?(about)

            @runners[slot] = runner
            @tool_envs[slot] = tool_env
            true
          end
        end

        def take_runner(about, slot: :runner)
          @monitor.synchronize do
            next nil unless @runners[slot] && @runner_abouts[slot].equal?(about)

            pair = [@runners[slot], @tool_envs[slot]]
            @runners.delete(slot)
            @tool_envs.delete(slot)
            @runner_abouts.delete(slot)
            pair
          end
        end

        # THE RUNNER HALF, ATTACHED: the runner-only ceremony
        # on a live agent lineage hands its OAuth here; the slot writer is
        # pure, the identity moves with it, and the lineage's about is the
        # same object it was.
        def adopt_runner(about, identity:, runner:, authority_report: nil)
          # Read outside the monitor: the section holds the slot writers only.
          runner_plane = authority_report&.dig(:planes, :runner_transport)
          @monitor.synchronize do
            next false if @stopping || !@credentials.equal?(about)

            @credentials.attach_runner(runner)
            @identity = identity
            @observation = observation_with_runner_plane(about, runner_plane)
            @generation += 1
            true
          end
        end

        # The independent runner remains usable when the Agent's refresh
        # lineage is fenced. Its OAuth object still owns the loss; this edge
        # retires only the Agent's followers and handler.
        def lose_agent(about, unless_stopping: false, report: nil)
          @monitor.synchronize do
            next nil if unless_stopping && @stopping
            next nil if about.nil? || !@credentials.equal?(about)

            @observation = observation_after_agent_loss(about, report)
            @workspace = Workspace.pending
            @connection = nil if @connection&.phase == :active && @connection.oauth.equal?(about)
            @generation += 1
            retire_agent_locked
          end
        end

        # The runner half dropped — its lineage answered terminally, or
        # `rho disconnect --runner` — with the `:runner` slot and its socket
        # handed back to be stopped outside the monitor; the agent's own
        # run and the lineage stand. `identity:` replaces the identity when
        # the pointer was rewritten with it.
        def lose_runner(about, identity: nil)
          @monitor.synchronize do
            next nil if about.nil? || !@credentials.equal?(about)
            next nil if @credentials.drop_runner.nil?

            @identity = identity unless identity.nil?
            @observation = observation_with_runner_plane(about, :absent)
            @generation += 1
            retire_slot_locked(:runner)
          end
        end

        private

          def retire_for_adoption_locked(credentials)
            return Retired.none if @credentials.nil? || @credentials.equal?(credentials)
            return retire_locked if credentials.runner.nil? || !@credentials.runner.equal?(credentials.runner)

            retired = retire_agent_locked
            @runner_abouts[:runner] = credentials if @runner_abouts[:runner]
            @executor_realtime_abouts[:runner] = credentials if @executor_realtime_abouts[:runner]
            retired
          end

          def observation_after_agent_loss(about, report)
            previous = @observation&.report || { planes: {} }
            report ||= previous.merge(lost: true,
              planes: previous.fetch(:planes).merge(member: :unauthorized, executor_transport: :unauthorized))
            Observation.new(about: about, report: report, measured_at: @clock.call)
          end

          def retire_agent_locked
            retired = retire_slot_locked(:agent_runner).with(followers: @followers.values, realtime: @realtime)
            @followers = {}
            @realtime = nil
            @realtime_about = nil
            retired
          end

          # The last observation with the runner plane rewritten: a slot
          # attached or dropped is a fact status must show before the next
          # probe, and a stale observation about this about is the one
          # rewritten (none: none).
          def observation_with_runner_plane(about, state)
            return @observation if state.nil? || @observation.nil? || !@observation.about.equal?(about)

            report = @observation.report
            Observation.new(
              about: about, measured_at: @clock.call,
              report: report.merge(planes: report.fetch(:planes).merge(runner_transport: state))
            )
          end

          def retire_locked
            retired = Retired.new(followers: @followers.values, realtime: @realtime,
              executor_realtimes: SLOTS.filter_map { |slot| @executor_realtimes[slot] },
              runners: SLOTS.filter_map { |slot| @runners[slot] })
            @followers = {}
            @realtime = nil
            @realtime_about = nil
            @executor_realtimes = {}
            @executor_realtime_abouts = {}
            @runners = {}
            @tool_envs = {}
            @runner_abouts = {}
            retired
          end

          def retire_slot_locked(slot)
            retired = Retired.new(followers: [], realtime: nil,
              executor_realtimes: [@executor_realtimes[slot]].compact, runners: [@runners[slot]].compact)
            @executor_realtimes.delete(slot)
            @executor_realtime_abouts.delete(slot)
            @runners.delete(slot)
            @tool_envs.delete(slot)
            @runner_abouts.delete(slot)
            retired
          end

          # The endpoint asks at handshake time; a feed already waiting on the
          # shared client's connect cannot reopen a retired lineage.
          def member_credential_of(about)
            current = @monitor.synchronize { @credentials.equal?(about) && @realtime_about.equal?(about) }
            raise CybrosAgent::Error, "the realtime credential lineage was retired" unless current

            about.member_credential
          end

          def executor_credential_of(about, slot)
            current = @monitor.synchronize do
              executor_lineage_current?(about, slot) && @executor_realtime_abouts[slot].equal?(@credentials)
            end
            raise CybrosAgent::Error, "the executor realtime credential lineage was retired" unless current

            slot == :runner ? about.runner_credential : about.executor_credential
          end

          def executor_lineage_current?(about, slot)
            return @credentials.equal?(about) unless slot == :runner

            @credentials && @credentials.runner && @credentials.runner.equal?(about.runner)
          end
      end
    end
  end
end
