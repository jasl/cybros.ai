require "test_helper"
require "securerandom"
require "time"
require "support/actor_provisioning"

# THE PROVIDER ADMISSION FLOOR, THROUGH A DEPLOYED SYSTEM (owner 2026-09-15,
# item 11). A provider that answers 429 with `Retry-After` is stating a fact
# about its LANE, and the kernel now keeps that fact in one place: the
# (account, provider) row `AdmitQueuedWork` reads before it offers a row,
# rendered on the lane as `unavailable_until`. This lane proves the four
# halves only a deployment can: THE WRITER (the header becomes the row, off a
# real socket, in another process), THE READER (two plain one-shots on the
# same lane stay `queued` until the time the listing named — the deadline is
# the listing's, never a sleep), THE WAKE (once that time passes every due
# row on the lane re-enters in arrival order and the held pair completes
# within seconds — the requeue arm's kick AT the floor; the minute pass is
# the backstop), and THE CLOCK CLEARING IT (no sweep, no writer; the row is
# inert once its time passes). The per-attempt path is asserted UNCHANGED:
# the mock is stateless, so every attempt answers 429, and the budget's hard
# stop terminalizes the floored one-shot `attempt_budget_spent` as before —
# each later attempt raising the floor again, which is why the clock's
# clearing is read only after the LAST floor's time, the listing's own.
#
# The unit facts — the terminal arm's timed wake (nothing is queued behind
# the last floor here), the same-transaction write, the transient set — are
# ApplyResultTest / ExecuteAttemptTest / AdmitQueuedWorkTest's.
class ProviderFloorTest < Minitest::Test
  # 120 requests a minute per identity (AgentAPI::V1::BaseController::
  # RATE_LIMIT): one read a second, round-robin over what this lane watches.
  POLL = 1.0
  MOCK_TURN = { workload: "text_generation", model: "dev/mock-text" }.freeze
  RETRY_AFTER = 10
  FLOOR_WRITE_TIMEOUT = 10
  TERMINAL_TIMEOUT = 40
  WAKE_MARGIN = 10
  OVERALL_TIMEOUT = 90

  def setup
    @base_url = E2E.base_url
    @actor = E2E::ActorProvisioning.world(@base_url).shared_human
    @client = CybrosAgent::Client.new(base_url: @base_url, credential: @actor.member_token)
    E2E.enable_dev_lane!
    E2E.hosts.start
    @workspace = @client.workspaces.create(
      name: "Provider floor #{SecureRandom.hex(4)}", idempotency_key: SecureRandom.uuid
    )
    @lane = @client.workspace(@workspace.public_id).one_shots
  end

  def test_a_retry_after_floors_the_lane_holds_its_queue_and_the_clock_lifts_it
    assert_nil dev_lane.unavailable_until, "no floor stands on the dev lane before this journey"
    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)

    floored = @lane.create(**MOCK_TURN, input: "!mock error=429 retry_after=#{RETRY_AFTER} -- hold",
                           idempotency_key: SecureRandom.uuid)
    assert_equal "queued", floored.status

    # THE WRITER: the header the fake provider sent became the lane's floor,
    # read back as the ISO time the provider named.
    floor_at = Time.iso8601(await_floor)
    assert_operator floor_at, :<=, Time.now + RETRY_AFTER + 1,
      "the floor is now + Retry-After — the header's seconds, never a computed backoff"

    # THE READER: two plain one-shots on the floored lane are accepted and
    # stay queued until the time the listing named; polled to one second
    # before it, round-robin, so no read outruns the identity's budget.
    waiting = 2.times.map do |index|
      @lane.create(**MOCK_TURN, input: "say #{index}", idempotency_key: SecureRandom.uuid)
    end
    waiting.each { |shot| assert_equal "queued", shot.status }
    held_reads = 0
    while Time.now < floor_at - 1
      shot = @lane.fetch(waiting.fetch(held_reads % 2).public_id)
      assert_equal "queued", shot.status,
        "a row on a floored lane must not be admitted before the provider's time (read #{held_reads + 1})"
      held_reads += 1
      sleep POLL
    end
    assert_operator held_reads, :>=, 1, "the floor held long enough to be observed holding"

    # THE WAKE: at the floor's time every due row on the lane re-enters in
    # arrival order — the floored one-shot's retry and the two held rows —
    # so the pair completes within seconds of it, on the kick scheduled AT
    # the floor, never on the minute pass alone.
    waiting.each do |shot|
      done = await_terminal(shot.public_id, deadline: started + OVERALL_TIMEOUT,
                                            patience: floor_at + WAKE_MARGIN - Time.now)
      assert_equal "completed", done.result.status,
        "a row held by the floor runs once the floor ends: #{done.inspect}"
    end

    # THE PER-ATTEMPT PATH, UNCHANGED: every attempt met a 429, and the third
    # spent the budget — the hard stop, with the provider's word on the row.
    final = await_terminal(floored.public_id, deadline: started + OVERALL_TIMEOUT, patience: TERMINAL_TIMEOUT)
    assert_predicate final.result, :failed?
    assert final.result.error.attempt_budget_spent,
      "three attempts, each floored, then the budget's terminal — as before the floor existed"

    # THE CLOCK CLEARS IT: the last attempt's floor stands until its time,
    # then the listing says nothing — no writer nulled it. Polled to the
    # listing's own time plus a margin, never to a fixed sleep.
    last_floor = dev_lane.unavailable_until
    unless last_floor.nil?
      assert_operator Time.iso8601(last_floor), :<=, Time.now + RETRY_AFTER + 1,
        "the last floor is the last attempt's Retry-After, no further"
      clear_deadline = Time.iso8601(last_floor) + WAKE_MARGIN
      sleep POLL until Time.now > Time.iso8601(last_floor) || Time.now > clear_deadline
      sleep POLL while !dev_lane.unavailable_until.nil? && Time.now < clear_deadline
    end
    assert_nil dev_lane.unavailable_until, "a floor whose time has passed says nothing"
  end

  private

    def dev_lane
      @client.model_providers.list.find { |lane| lane.id == "dev" } ||
        flunk("the dev lane is not listed")
    end

    def await_floor
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + FLOOR_WRITE_TIMEOUT
      loop do
        until_at = dev_lane.unavailable_until
        return until_at unless until_at.nil?

        flunk("the 429's Retry-After never became the lane's floor") if
          Process.clock_gettime(Process::CLOCK_MONOTONIC) > deadline
        sleep POLL
      end
    end

    # `patience` is this wait's own bound in seconds; `deadline` the
    # journey's monotonic ceiling — whichever comes first flunks.
    def await_terminal(public_id, deadline:, patience:)
      own = Process.clock_gettime(Process::CLOCK_MONOTONIC) + [patience, 0].max
      last = nil
      loop do
        last = @lane.fetch(public_id)
        return last if last.finished?

        now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
        flunk("#{public_id} never reached a terminal state in time; last read: #{last.inspect}") if
          now > own || now > deadline
        sleep POLL
      end
    end
end
