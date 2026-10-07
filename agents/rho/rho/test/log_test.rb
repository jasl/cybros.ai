require "test_helper"
require "stringio"

# The structured logger. A daemon whose only output is an
# unstructured stream leaves nothing to read after the process is gone, and a
# careless field leaves a live credential in a file that outlives it.
class UtilLogTest < Minitest::Test
  def setup
    @io = StringIO.new
    @clock = -> { Time.at(1_800_000_000).utc }
  end

  def logger(level: :info)
    Rho::Log.new(io: @io, level: level, clock: @clock)
  end

  def lines = @io.string.lines.map(&:chomp)

  def test_a_line_carries_the_time_the_level_and_the_event
    logger.info("daemon.boot")

    assert_equal ["2027-01-15T08:00:00Z level=info event=daemon.boot"], lines
  end

  def test_fields_render_after_the_event_in_the_order_given
    logger.info("connection.phase", from: "idle", to: "pending", attempt: 2)

    assert_equal "2027-01-15T08:00:00Z level=info event=connection.phase from=idle to=pending attempt=2",
      lines.fetch(0)
  end

  # A value with a space would otherwise split into two fields and quietly
  # corrupt every line that carries a human-written name.
  def test_a_value_needing_quotes_gets_them
    logger.info("connect", name: %(My "laptop" at home), empty: "")

    assert_equal %(2027-01-15T08:00:00Z level=info event=connect name="My \\"laptop\\" at home" empty=""),
      lines.fetch(0)
  end

  def test_nil_is_a_dash_rather_than_an_empty_field
    logger.info("status", address: nil)

    assert_equal "2027-01-15T08:00:00Z level=info event=status address=-", lines.fetch(0)
  end

  def test_a_level_below_the_threshold_writes_nothing
    log = logger(level: :warn)
    log.debug("noise")
    log.info("noise")
    log.warn("kept")
    log.error("kept")

    assert_equal 2, lines.length
    assert_includes lines.fetch(0), "level=warn event=kept"
  end

  # The single most valuable rule this class can enforce: a log file outlives
  # the process, so a credential written into one is a credential leaked to
  # every later reader. Both the key's name and the value's own shape are
  # checked, because a token can arrive under any key at all.
  def test_a_secret_never_reaches_the_stream
    logger.info("mint",
      access_token: "sk-cybros-api-v1-abcdefghijklmnop",
      bearer: "rho-local-v1-secret",
      note: "presented sk-cybros-api-v1-zyxwvutsrqponmlk to the kernel")

    line = lines.fetch(0)
    refute_includes line, "abcdefghijklmnop"
    refute_includes line, "rho-local-v1-secret"
    refute_includes line, "zyxwvutsrqponmlk"
    assert_includes line, "access_token=[REDACTED]"
    assert_includes line, "bearer=[REDACTED]"
  end

  # sec-6: the key table is the SDK's one (`CybrosAgent::Redaction::SECRET_KEY`)
  # — `api_key`, `authorization`, `cookie` and a bare `key` are credentials
  # by name; `task_key` is the reader's handle and stays in the clear.
  def test_credential_named_keys_are_redacted_and_the_readers_keys_stay
    logger.info("call", api_key: "literal-1", authorization: "Basic abc", cookie: "sid=1", key: "k-1",
      task_key: "r2t0")

    assert_equal "2027-01-15T08:00:00Z level=info event=call api_key=[REDACTED] authorization=[REDACTED] " \
                 "cookie=[REDACTED] key=[REDACTED] task_key=r2t0", lines.fetch(0)
  end

  def test_an_exception_logs_its_class_and_message_without_a_backtrace_in_the_line
    error = ArgumentError.new("bad address")

    logger.error("connection.failed", error: error)

    assert_equal %(2027-01-15T08:00:00Z level=error event=connection.failed ) +
      %(error="ArgumentError: bad address"), lines.fetch(0)
  end

  def test_a_newline_in_a_value_cannot_forge_a_second_line
    logger.info("note", text: "first\nsecond")

    assert_equal 1, lines.length
    assert_includes lines.fetch(0), %(text="first\\nsecond")
  end

  # Two threads writing at once must not interleave halves of two lines.
  def test_concurrent_writers_produce_whole_lines
    log = logger
    threads = 8.times.map do |index|
      Thread.new { 20.times { log.info("tick", worker: index) } }
    end
    threads.each(&:join)

    assert_equal 160, lines.length
    lines.each { |line| assert_match(/\A\S+ level=info event=tick worker=\d+\z/, line) }
  end

  def test_an_unknown_level_is_refused_rather_than_silently_accepted
    assert_raises(ArgumentError) { Rho::Log.new(io: @io, level: :verbose) }
  end

  # rho points this at a file that must not be world-readable, and opening it
  # is the logger's business rather than every caller's.
  def test_opening_a_file_creates_it_private_and_appends
    Dir.mktmpdir("log") do |directory|
      path = File.join(directory, "rho.log")
      Rho::Log.to_file(path, clock: @clock).info("first")
      Rho::Log.to_file(path, clock: @clock).info("second")

      assert_equal 0o600, File.stat(path).mode & 0o777
      assert_equal 2, File.read(path).lines.length
    end
  end
end

# A logger with standing fields (the claim line names its address).
class LogTaggedTest < Minitest::Test
  def test_tagged_merges_its_fields_into_every_line
    io = StringIO.new
    log = Rho::Log.new(io: io, clock: -> { Time.utc(2026, 9, 7) })

    tagged = log.tagged(address: "runner")
    tagged.info("runner_task_claimed", task: "t1")
    tagged.warn("runner_stop_failed")

    lines = io.string.lines.map(&:chomp)
    assert_equal ["2026-09-07T00:00:00Z level=info event=runner_task_claimed task=t1 address=runner",
                  "2026-09-07T00:00:00Z level=warn event=runner_stop_failed address=runner"], lines
    assert_nil tagged.info("x")
  end
end
