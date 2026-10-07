require "test_helper"
require "async"
require "securerandom"
require "cybros_agent/realtime"
require "support/actor_provisioning"

# A CABLE CUT IN THE MIDDLE OF A TURN, BY THE DEPLOYMENT ITSELF.
#
# The design says the socket is opportunistic and the durable window is the
# authority. This lane proves the half of that a deployment can prove: that
# losing the socket mid-turn is survivable end to end — the follower notices,
# reconnects against a real server, and still assembles exactly what an
# uninterrupted follower does, in order, once, with no holes.
#
# A confirmed subscription precedes execution. After the cut, a durable delta
# beyond the follower's cursor must exist before it reconnects, so this lane
# exercises a real deployment gap. Exact barrier branches remain pinned in
# `kernel_feed_test.rb`, where their timing can be controlled independently.
class InferenceRequestRecoveryTest < Minitest::Test
  TURN_TIMEOUT = 90
  # Leave time for the operator's Rails process to cut the socket while the
  # provider is still streaming. The public replay check below, not this
  # delay, proves that a delta was missed during the outage.
  ANSWER_BODY = ("the quick brown fox jumps over the lazy dog. " * 45).strip.freeze
  PROMPT = "!mock usage=4:6 stream_chunk_delay=0.1 -- #{ANSWER_BODY}".freeze
  ANSWER = "Mock: #{ANSWER_BODY}".freeze

  def setup
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    @workspace = @client.workspaces.create(
      name: "InferenceRequest recovery #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    )
    @lane = @client.workspace(@workspace.public_id).inference_requests
  end

  Followed = Data.define(:events, :connects, :gap_sequence)

  def test_a_follower_whose_cable_is_cut_mid_turn_reconnects_and_still_assembles_the_answer
    interrupted = follow(cut: true)
    clean = follow(cut: false)

    # THE CUT MUST HAVE BITTEN, or everything below is a test of nothing. A
    # connect asks the credential source fresh — that is the documented
    # behaviour and its own test — so counting the asks counts the
    # connections, without the pump needing an accessor invented for a test.
    assert_operator interrupted.connects, :>, 1,
      "the cable was cut and the follower did not have to reconnect — " \
      "either the cut missed or the socket was never live"
    assert_equal 1, clean.connects,
      "and an uninterrupted follower connects exactly once, so the count means something"
    assert_includes interrupted.events.map(&:sequence), interrupted.gap_sequence,
      "the follower recovered the durable delta published while its socket was absent"

    assert_equal ANSWER, text_of(interrupted.events),
      "a follower that lost its socket must still assemble the whole answer"
    assert_equal text_of(clean.events), text_of(interrupted.events),
      "and assemble exactly what an uninterrupted follower does"

    sequences = interrupted.events.map(&:sequence)
    assert_equal sequences.sort, sequences, "in order"
    assert_equal sequences.uniq, sequences, "once — a re-drain must not redeliver what was applied"
    assert_equal (1..interrupted.events.length).to_a, sequences,
      "and with no holes: the sequence is contiguous, so one would show here"
    assert_equal "result", interrupted.events.last.type
  end

  def teardown
    E2E.hosts.start
  end

  private

    # Runs one turn to completion through a feed on a real socket, optionally
    # cutting the cable once the narration has started. Returns every event the
    # follower applied, in the order it applied them.
    #
    # Keep both producers stopped until the first subscription is confirmed:
    # KernelFeed drains REST before subscribing, so a delta alone proves no
    # socket was live. The runner then narrates alone; the queue host, which
    # writes the terminal result, joins only after the cut has reconnected.
    def follow(cut:)
      E2E.hosts.stop
      created = @lane.create(
        workload: "text_generation", model: "dev/mock-text", input: PROMPT,
        idempotency_key: SecureRandom.uuid
      )
      seen = []
      connects = 0
      gap_sequence = nil
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + TURN_TIMEOUT

      Sync do |task|
        endpoint = CybrosAgent::Realtime::Endpoint.new(
          base_url: @base_url,
          credential: -> { connects += 1; @actor.member_token }
        )
        realtime = CybrosAgent::Realtime::Client.new(endpoint: endpoint)

        begin
          feed = @lane.feed(created.public_id)
          opener = @lane.realtime_opener(created.public_id, realtime)
          narrating = false
          feed.attach(-> {
            if cut && narrating && gap_sequence.nil?
              gap_sequence = await_unseen_delta(created.public_id, feed.position.cursor, deadline:).sequence
            end
            subscription = opener.call
            E2E.hosts.start(narrating ? :jobs : :runner)
            subscription
          })

          # Enforce the deadline even while the socket has no next frame.
          task.with_timeout(TURN_TIMEOUT, Minitest::Assertion, "the turn never finished") do
            until seen.any? { _1.type == "result" }
              feed.each do |event|
                seen << event
                # THE CUT LANDS MID-NARRATION, once the follower is genuinely live
                # and has something to lose. Cutting before the first delta would
                # only prove that connecting works.
                if event.type == "text_delta" && !narrating
                  narrating = true
                  if cut
                    E2E.disconnect_cable!(@actor.public_id)
                    refute @lane.fetch(created.public_id).finished?, "the cable must be cut before the result"
                  else
                    E2E.hosts.start(:jobs)
                  end
                end
                feed.stop if event.type == "result"
              end
              flunk("the turn never finished") if
                Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
            end
          end
        ensure
          realtime.close
        end
      end
      Followed.new(events: seen, connects: connects, gap_sequence: gap_sequence)
    ensure
      E2E.hosts.start
    end

    def await_unseen_delta(public_id, cursor, deadline:)
      loop do
        delta = @lane.events(public_id, after: cursor).items.find { _1.type == "text_delta" }
        return delta if delta

        flunk("no durable text delta was published while the socket was absent") if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep 0.01
      end
    end

    def text_of(events)
      events.select { _1.type == "text_delta" }.map { _1.payload.fetch("text") }.join
    end
end
