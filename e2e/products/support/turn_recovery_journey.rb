module E2E
  module TurnRecoveryJourney
    def test_network_loss_automatically_recovers_via_turn_and_stop_interrupts_recovery
      assert_turn_recovery(transport: "udp")
    end

    def test_udp_block_automatically_recovers_via_turn_tcp_and_stop_interrupts_recovery
      assert_turn_recovery(transport: "tcp")
    end

    def test_udp_block_automatically_recovers_via_turn_tls_and_stop_interrupts_recovery
      assert_turn_recovery(transport: "tls")
    end

    def test_turn_tls_requires_a_trusted_certificate
      E2E::WebrtcNetworkFixture.open(transport: "tls") do |fixture|
        fixture.block_udp
        assert_match(/\Aturns:.*\?transport=tcp\z/, fixture.servers.first.fetch("urls").first)
        peer = fixture.peer(trusted: false)
        refute_includes peer.offer(servers: fixture.servers, relay: true), " typ relay"
        peer.close
        peer = fixture.peer
        assert_includes peer.offer(servers: fixture.servers, relay: true), " typ relay"
        peer.close
        await(seconds: 12, message: "TLS trust-control helpers survived close") { fixture.helpers_reaped? }
      ensure
        peer&.close
      end
    end

    private

      def assert_turn_recovery(transport:)
        _base_url, _path, _http, _session, _member_key, _member, _transport, executor, key = prepare_realtime
        E2E::WebrtcNetworkFixture.open(transport: transport) do |fixture|
          observations = Thread::Queue.new
          tool = Rho::Env::Toolset::Tool.new(name: "realtime_probe", description: "Probe", parameters: { "type" => "object" },
            handler: lambda { |_input, context|
              PTY.spawn(RbConfig.ruby, "-e", '$stdout.sync = true; STDIN.each_line { |line| puts "applied:#{line.strip}" }') do |reader, writer, pid|
                connection = fixture.connection(context: context)
                observations << [context, pid, connection]
                begin
                  loop do
                    packet = connection.poll
                    packet.data.each { |bytes| writer.write(bytes) if context.realtime.allowed? }
                    if reader.wait_readable(0.01)
                      bytes = reader.read_nonblock(16 * 1024, exception: false)
                      connection.send_bytes(bytes) if bytes && bytes != :wait_readable && packet.ready
                    end
                  end
                ensure
                  connection.close
                  Process.kill("TERM", pid)
                  Process.wait(pid)
                  observations << :reaped
                end
              end
            })
          @pool = Rho::Env::Pool.new(worker_threads: 1)
          tools = Rho::Env::Toolsets.fixed(toolset: Rho::Env::Toolset.new("realtime_probe" => tool))
          runner_task = Rho::Env::TaskRun.new(executor: executor, pool: @pool, toolsets: tools, log: self.class::Log.new)
          Async do |reactor|
            reactor.with_timeout(70) do
              running = reactor.async { runner_task.call(run_public_id: @run.run_public_id, task_key: key, tool_name: "realtime_probe") }
              context, pid, connection = observations.pop
              claim_token = context.claim_token
              task = @run.tasks_context(key)
              # The member follows new offers continuously, never requesting a reconnect.
              member_peer = nil
              member_connection = nil
              answer_enabled = true
              answering = reactor.async do
                loop do
                  offer = task.realtime
                  if answer_enabled && offer.offer_sdp && offer.connection_id != member_connection
                    member_peer&.close
                    candidate = fixture.peer
                    sdp = candidate.answer(sdp: offer.offer_sdp, servers: fixture.servers)
                    task.answer_realtime(connection_id: offer.connection_id, sdp: sdp)
                    member_peer = candidate
                    member_connection = offer.connection_id
                  end
                  sleep 0.05
                end
              end
              await(message: "Initial direct peer did not connect") { member_peer && member_peer.poll.ready }
              first_connection = member_connection
              first_helper = connection.pid
              assert_equal ["host", "host"], member_peer.poll.pair
              assert_webrtc_output(member_peer, "direct-network")
              transport == "udp" ? fixture.block_direct : fixture.block_udp
              assert member_peer.send_bytes("lost-before-reconnect\n")
              await(seconds: 25, message: "Peer did not recover through TURN") { member_connection != first_connection && member_peer.poll.ready }
              assert_includes member_peer.poll.pair, "relay"
              assert_raises(Errno::ESRCH) { Process.kill(0, first_helper) }
              assert_operator fixture.dropped_packets("runner"), :>, 0
              assert_operator fixture.dropped_packets("member"), :>, 0
              if transport != "udp"
                assert_operator fixture.relay_tcp_packets("runner"), :>, 0
                assert_operator fixture.relay_tcp_packets("member"), :>, 0
              end
              assert_equal claim_token, context.claim_token
              claim = executor.inbox_task(run_public_id: @run.run_public_id, task_key: key)
              assert_predicate claim.claim_status(claim_token: claim_token), :active?
              assert_equal 1, Process.kill(0, pid)
              assert_equal 1, @pool.in_flight
              assert_webrtc_output(member_peer, "automatic-relay", forbidden: "lost-before-reconnect")
              # TCP blackholing stalls candidate gathering; UDP can publish an
              # unanswered offer. Original Stop must cancel either recovery phase.
              answer_enabled = false
              second_connection = member_connection
              relay_helper = connection.pid
              fixture.block_relay
              if transport != "udp"
                await(seconds: 25, message: "TURN outage did not replace the helper") { connection.pid && connection.pid != relay_helper }
                assert_equal second_connection, connection.connection_id
                assert_raises(Errno::ESRCH) { Process.kill(0, relay_helper) }
              else
                await(seconds: 25, message: "TURN outage did not publish a new offer") { connection.connection_id != second_connection }
              end
              recovery_helper = connection.pid
              refute_nil recovery_helper
              assert_equal 1, Process.kill(0, pid)
              @run.stop(force: true)
              assert_equal :done, running.wait
              assert_equal :reaped, observations.pop
              assert_raises(Errno::ESRCH) { Process.kill(0, pid) }
              assert_raises(Errno::ESRCH) { Process.kill(0, recovery_helper) }
              assert_nil connection.pid
              assert_equal 0, @pool.in_flight
              refute context.realtime.allowed?
              assert_empty observations
              answering.stop
              member_peer.close
              await(seconds: 12, message: "Container transport helpers survived Stop") { fixture.helpers_reaped? }
            ensure
              context&.cancel(:canceled)
              answering&.stop
              member_peer&.close
            end
          end.wait
        end
      ensure
        @pool&.stop
        @run.stop(force: true) if @run && !@run.fetch.terminal?
        @platform&.agents&.agent(@agent_id)&.remove if @agent_id
        @platform&.session&.revoke
      end
  end
end
