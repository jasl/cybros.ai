require "test_helper"

class ExtensionResourcesTest < Minitest::Test
  Resources = Rho::Runner::Extensions::Resources

  def test_retirement_waits_for_an_acquired_call_and_disposes_once_on_the_host
    work = []
    disposed = []
    owner = Resources.new(extension: "example")
    owner.own { disposed << :connection }
    owner.own { disposed << :subscription }
    owner.own(on_retire: true) { disposed << :poller }
    owner.dispatch = ->(&cleanup) { work << cleanup }
    owner.acquire

    refute owner.retire
    assert_equal [:poller], disposed
    assert_raises(Rho::Runner::Extensions::RegistrationError) { owner.acquire }
    owner.release
    assert_equal [:poller], disposed
    assert_equal 1, work.length
    work.shift.call
    assert_equal %i[poller subscription connection], disposed
    assert owner.retire
    assert_equal %i[poller subscription connection], disposed
  end

  def test_failed_cleanup_does_not_skip_other_owned_resources
    disposed = []
    owner = Resources.new(extension: "example")
    owner.own { disposed << :first }
    owner.own { raise IOError, "closed incorrectly" }
    owner.own { disposed << :last }

    assert owner.retire
    assert_equal %i[last first], disposed
    assert_equal ["IOError"], owner.failures
  end

  def test_loader_discards_a_failed_candidates_resources
    disposed = []
    broken = Module.new do
      const_set(:NAME, "example")
      define_singleton_method(:register) do |api|
        api.on(:shutdown) { disposed << :closed }
        raise "failed to prepare"
      end
    end

    result = Rho::Runner::Extensions::Loader.call(builtin: [broken])

    refute result.ok?
    assert_empty result.committed
    assert_equal [:closed], disposed
  end
end
