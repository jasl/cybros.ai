require "test_helper"

# A code is the bearer in a shape a browser can carry. Everything here pins
# one of the three properties that make that sound: it is minted only by a
# bearer-holder (the route's business), it works once, and it dies quickly.
class ConsoleCodesTest < Minitest::Test
  def setup
    @now = 1000.0
    @codes = Rho::ConsoleCodes.new(clock: -> { @now })
  end

  def test_a_minted_code_redeems_once
    assert_equal :ok, @codes.redeem(@codes.mint)
  end

  # Single use is the only theft detector this design has, so a replay must be
  # distinguishable from a link that merely went stale.
  def test_the_same_code_twice_is_spent_rather_than_unknown
    code = @codes.mint

    assert_equal :ok, @codes.redeem(code)
    assert_equal :spent, @codes.redeem(code)
  end

  def test_a_code_dies_at_its_ttl
    code = @codes.mint
    @now += Rho::ConsoleCodes::TTL_SECONDS

    assert_equal :unknown, @codes.redeem(code)
  end

  # Spent entries are kept only long enough to answer a replay; they must not
  # accumulate for the life of the daemon.
  def test_a_spent_code_becomes_unknown_once_it_expires
    code = @codes.mint
    @codes.redeem(code)
    @now += Rho::ConsoleCodes::TTL_SECONDS + 1

    assert_equal :unknown, @codes.redeem(code)
  end

  def test_a_code_from_another_daemon_is_unknown
    other = Rho::ConsoleCodes.new(clock: -> { @now })

    assert_equal :unknown, @codes.redeem(other.mint)
  end

  def test_the_outstanding_set_is_bounded_and_evicts_the_oldest
    oldest = @codes.mint
    (Rho::ConsoleCodes::MAX_OUTSTANDING - 1).times { @codes.mint }
    newest = @codes.mint

    assert_equal :unknown, @codes.redeem(oldest), "the cap must evict rather than grow"
    assert_equal :ok, @codes.redeem(newest)
  end

  # A hostile body must not reach a 500.
  def test_a_candidate_that_is_not_a_code_is_unknown_without_raising
    [nil, "", 123, [], {}].each do |candidate|
      assert_equal :unknown, @codes.redeem(candidate), candidate.inspect
    end
  end

  # Compare-and-burn is one critical section: two racers, exactly one winner.
  def test_two_threads_redeeming_one_code_produce_exactly_one_winner
    code = @codes.mint
    barrier = Queue.new
    results = [nil, nil]

    threads = 2.times.map do |index|
      Thread.new do
        barrier.pop
        results[index] = @codes.redeem(code)
      end
    end
    2.times { barrier << :go }
    threads.each(&:join)

    assert_equal 1, results.count(:ok), results.inspect
    assert_equal 1, results.count(:spent), results.inspect
  end

  # A log line and a heap dump must not carry a live credential.
  def test_nothing_holds_or_prints_the_code_in_plain_form
    code = @codes.mint
    fingerprint = Rho::ConsoleCodes.fingerprint(code)

    assert_equal 12, fingerprint.length
    refute_includes fingerprint, code
    stored = @codes.instance_variable_get(:@entries).map(&:digest)
    refute_includes stored, code
    assert(stored.all? { |digest| digest.encoding == Encoding::BINARY })
  end
end
