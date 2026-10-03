require "test_helper"

class HostRunStreamLifecycleTest < Minitest::Test
  class Socket
    attr_reader :closed, :reads

    def initialize
      @closed = false
      @reads = 0
    end

    def each
      @reads += 1
      Fiber.yield until @closed
    end

    def unsubscribe = @closed = true
  end

  class Context
    attr_reader :socket

    def feed(realtime: nil, items: nil, **options)
      CybrosAgent::KernelFeed.new(replay: ->(_cursor) { raise "the event follower was not started" },
        subscribe: realtime_opener(realtime, items: items), **options)
    end

    def realtime_opener(_realtime, items: nil) = -> { Socket.new }

    def transcript(realtime:) = opening
    def progress(realtime:) = opening

    def opening
      -> do
        @socket = Socket.new
        Fiber.yield # The SDK waits for the server's subscribe confirmation.
        @socket
      end
    end
  end

  class Realtime
    def rebind = true
    def close = nil
  end

  def teardown
    @run&.stop
    @follower.resume if @follower&.alive?
  end

  def test_stopping_during_transcript_subscribe_closes_the_late_handle
    interrupt_open(:follow_transcript, :stop)
  end

  def test_stopping_during_progress_subscribe_closes_the_late_handle
    interrupt_open(:follow_progress, :stop)
  end

  def test_narrowing_during_transcript_subscribe_closes_the_late_handle
    interrupt_open(:follow_transcript, :detach_socket)
  end

  def test_narrowing_during_progress_subscribe_closes_the_late_handle
    interrupt_open(:follow_progress, :detach_socket)
  end

  private

    def interrupt_open(follower, command)
      context = Context.new
      @run = Rho::HostRun.new(host: Rho::Host::Conversation.new(public_id: "c-1"),
        context: context, realtime: Realtime.new, sleeper: ->(_seconds) { Fiber.yield })
      @follower = Fiber.new { @run.public_send(follower) }
      @follower.resume
      @run.public_send(command)
      @follower.resume

      assert context.socket.closed, "a handle confirmed after #{command} must be released"
      assert_equal 0, context.socket.reads, "the discarded stream must not deliver frames"
      refute @follower.alive? if command == :stop
    end
end
