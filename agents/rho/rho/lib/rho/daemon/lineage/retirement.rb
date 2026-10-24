module Rho
  class Daemon
    class Lineage
      # The followers, the shared realtime client and the runners a lineage placed —
      # the "retire" family: reserve or mint
      # inside the monitor, build outside it, install with a CAS on `about`.
      #
      # The single runner slot and executor socket serve every announced role.
      # Replacing or losing the connection owner retires them together.
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
        def executor_realtime_for(about)
          credential = -> { executor_credential_of(about) }
          @monitor.synchronize do
            next nil if about.nil? || !@credentials.equal?(about)

            unless @executor_realtime && @executor_realtime_about.equal?(about)
              @executor_realtime_about = about
              @executor_realtime = @realtime_factory.call(credential)
            end
            @executor_realtime
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

        def reserve_runner(about)
          @monitor.synchronize do
            next false if @stopping || !@credentials.equal?(about)
            next false if @runner && @runner_about.equal?(about)

            @runner_about = about
            true
          end
        end

        # A reservation given back without a runner — the executor plane had
        # no credential to build one on — so a later edge may place one.
        def release_runner(about)
          @monitor.synchronize do
            next false unless @runner.nil? && @runner_about.equal?(about)

            @runner_about = nil
            true
          end
        end

        def install_runner(about, runner)
          @monitor.synchronize do
            next false if @stopping || @runner || !@runner_about.equal?(about)

            @runner = runner
            true
          end
        end

        private

          def retire_for_adoption_locked(credentials)
            return Retired.none if @credentials.nil? || @credentials.equal?(credentials)

            retire_locked
          end

          def retire_locked
            retired = Retired.new(followers: @followers.values, realtime: @realtime,
              executor_realtime: @executor_realtime, runner: @runner)
            @followers = {}
            @realtime = nil
            @realtime_about = nil
            @executor_realtime = nil
            @executor_realtime_about = nil
            @runner = nil
            @runner_about = nil
            retired
          end

          # The endpoint asks at handshake time; a feed already waiting on the
          # shared client's connect cannot reopen a retired lineage.
          def member_credential_of(about)
            current = @monitor.synchronize { @credentials.equal?(about) && @realtime_about.equal?(about) }
            raise CybrosAgent::Error, "the realtime credential lineage was retired" unless current

            about.member_credential
          end

          def executor_credential_of(about)
            current = @monitor.synchronize do
              @credentials.equal?(about) && @executor_realtime_about.equal?(@credentials)
            end
            raise CybrosAgent::Error, "the executor realtime credential lineage was retired" unless current

            about.executor_credential
          end
      end
    end
  end
end
