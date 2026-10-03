require "test_helper"

# THE PASSPHRASE GATE. It is what a wider bind has been
# waiting for: `verify_bind` refused a non-loopback bind while a webui
# bundle was present precisely because "the access passphrase that would
# gate it has not landed".
class AccessLockTest < Minitest::Test
  def clock_at(*values)
    queue = values.dup
    -> { queue.length > 1 ? queue.shift : queue.first }
  end

  def test_no_passphrase_is_no_lock
    assert_nil Rho::AccessLock.build(nil)
    assert_nil Rho::AccessLock.build("")
  end

  def test_a_short_passphrase_is_refused_rather_than_pretending_to_lock
    error = assert_raises(Rho::ConfigurationError) { Rho::AccessLock.build("seven77") }
    assert_match(/at least 8 characters/, error.message)
    assert Rho::AccessLock.build("eight888"), "the boundary itself is allowed"
  end

  def test_the_right_passphrase_is_accepted_and_clears_the_throttle
    now = 0.0
    lock = Rho::AccessLock.build("correct horse", clock: -> { now })

    refute_predicate lock.attempt("wrong"), :accepted?
    now += 2
    assert_predicate lock.attempt("correct horse"), :accepted?

    # The window the miss armed is CLEARED by the success, so the next
    # caller does not wait out somebody else's typo.
    refute_predicate lock.attempt("wrong"), :throttled?
  end

  # ONE GUESS PER WINDOW, and the window doubles. The passphrase gates a
  # bearer that grants this host's shell, so an unthrottled endpoint is an
  # offline attack conducted online.
  def test_every_miss_arms_a_window_that_doubles
    now = 0.0
    lock = Rho::AccessLock.build("correct horse", clock: -> { now })

    first = lock.attempt("no")
    refute_predicate first, :accepted?
    refute_predicate first, :throttled?, "the miss itself reports as a miss, not as a lockout"

    throttled = lock.attempt("no")
    assert_predicate throttled, :throttled?
    assert_equal 2, throttled.retry_after_seconds

    now += 2
    refute_predicate lock.attempt("no"), :throttled?, "the window elapsed"
    assert_equal 4, lock.attempt("no").retry_after_seconds, "and the next one is longer"
  end

  # THE CORRECT PASSPHRASE DOES NOT JUMP THE QUEUE. A throttle a right
  # answer walks past is a throttle an attacker walks past on the guess
  # that happens to be right — which is the one guess that matters.
  def test_the_window_holds_even_for_the_right_passphrase
    now = 0.0
    lock = Rho::AccessLock.build("correct horse", clock: -> { now })

    lock.attempt("no")
    assert_predicate lock.attempt("correct horse"), :throttled?

    now += 2
    assert_predicate lock.attempt("correct horse"), :accepted?
  end

  def test_the_delay_is_capped_so_a_typo_cannot_lock_an_operator_out_for_hours
    now = 0.0
    lock = Rho::AccessLock.build("correct horse", clock: -> { now })

    30.times do
      lock.attempt("no")
      now += Rho::AccessLock::MAX_DELAY_SECONDS
    end

    assert_operator lock.attempt("no").retry_after_seconds.to_i, :<=,
      Rho::AccessLock::MAX_DELAY_SECONDS
  end

  def test_a_non_string_candidate_is_a_miss_not_a_crash
    lock = Rho::AccessLock.build("correct horse", clock: clock_at(0.0))
    refute_predicate lock.attempt(nil), :accepted?
    refute_predicate lock.attempt(42), :accepted?
    refute_predicate lock.attempt({ "passphrase" => "correct horse" }), :accepted?
  end
end
