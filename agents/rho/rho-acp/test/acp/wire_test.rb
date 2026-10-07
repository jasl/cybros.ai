require "test_helper"
require "rho/acp"
require "tmpdir"

# THE FRAMING: one JSON object per line, UTF-8, no embedded newline, over ANY IO pair —
# a pipe here, the process's stdio under `rho acp`, a child's under `delegate_agent`. A
# request carries an id; a notification carries none; a malformed line is answered
# -32700 and the next line is read; a line that parses but is no JSON-RPC message is
# answered -32600. The wire never dies on a bad line and never writes a second line for
# one message.
class AcpWireTest < Minitest::Test
  Wire = Rho::Acp::Wire

  def setup
    @peer_reads, wire_writes = IO.pipe
    wire_reads, @peer_writes = IO.pipe
    # UTF-8 BY NAME on the peer's side: the test process inherits the
    # machine's empty locale, and a `gets` there would tag the wire's
    # bytes US-ASCII — the peer reads as the spec says the bytes are.
    @peer_reads.set_encoding(Encoding::UTF_8)
    @wire = Wire.new(input: wire_reads, output: wire_writes)
  end

  def teardown
    [@peer_reads, @peer_writes].each { |io| io.close unless io.closed? }
    @wire.close
  end

  # A line the WIRE writes on its own (an answer to a bad line), bounded:
  # a wire that stops answering must red the pin, never hang the suite.
  def answer_line
    flunk "the wire wrote no answer within 2 s" unless IO.select([@peer_reads], nil, nil, 2)
    @peer_reads.gets
  end

  def test_a_request_is_one_json_object_on_one_line_with_jsonrpc_first
    @wire.write_request(0, "initialize", { "protocolVersion" => 1 })

    assert_equal %({"jsonrpc":"2.0","id":0,"method":"initialize","params":{"protocolVersion":1}}\n), @peer_reads.gets
  end

  def test_a_notification_carries_no_id_and_a_result_and_an_error_carry_no_method
    @wire.write_notification("session/update", { "sessionId" => "s" })
    @wire.write_result(3, { "stopReason" => "end_turn" })
    @wire.write_error(4, -32602, "Invalid params", data: { "field" => "cwd" })
    @wire.write_error(5, -32800, "Request cancelled")

    assert_equal %({"jsonrpc":"2.0","method":"session/update","params":{"sessionId":"s"}}\n), @peer_reads.gets
    assert_equal %({"jsonrpc":"2.0","id":3,"result":{"stopReason":"end_turn"}}\n), @peer_reads.gets
    assert_equal %({"jsonrpc":"2.0","id":4,"error":{"code":-32602,"message":"Invalid params","data":{"field":"cwd"}}}\n),
      @peer_reads.gets
    assert_equal %({"jsonrpc":"2.0","id":5,"error":{"code":-32800,"message":"Request cancelled"}}\n), @peer_reads.gets
  end

  def test_a_result_of_null_is_written_as_null_and_read_back_as_nil
    @wire.write_result(8, nil)
    assert_equal %({"jsonrpc":"2.0","id":8,"result":null}\n), @peer_reads.gets

    @peer_writes.puts %({"jsonrpc":"2.0","id":8,"result":null})
    frame = @wire.read
    assert_instance_of Wire::Response, frame
    assert_equal 8, frame.id
    assert_nil frame.result
  end

  def test_an_embedded_newline_in_a_value_never_breaks_the_line
    @wire.write_notification("session/update", { "text" => "one\ntwo\r\nthree" })

    line = @peer_reads.gets
    assert_equal "one\ntwo\r\nthree", JSON.parse(line).dig("params", "text")
    assert_equal 1, line.count("\n")
  end

  def test_reads_are_classified_by_shape
    @peer_writes.puts %({"jsonrpc":"2.0","id":1,"method":"session/new","params":{"cwd":"/p","mcpServers":[]}})
    @peer_writes.puts %({"jsonrpc":"2.0","method":"session/cancel","params":{"sessionId":"s"}})
    @peer_writes.puts %({"jsonrpc":"2.0","id":"abc","result":{"sessionId":"s"}})
    @peer_writes.puts %({"jsonrpc":"2.0","id":2,"error":{"code":-32601,"message":"Method not found"}})
    @peer_writes.puts %({"jsonrpc":"2.0","id":3,"method":"authenticate"})

    request = @wire.read
    assert_instance_of Wire::Request, request
    assert_equal [1, "session/new", { "cwd" => "/p", "mcpServers" => [] }], [request.id, request.method, request.params]

    notification = @wire.read
    assert_instance_of Wire::Notification, notification
    assert_equal ["session/cancel", { "sessionId" => "s" }], [notification.method, notification.params]

    response = @wire.read
    assert_instance_of Wire::Response, response
    assert_equal ["abc", { "sessionId" => "s" }], [response.id, response.result]

    failure = @wire.read
    assert_instance_of Wire::Failure, failure
    assert_equal [2, -32601, "Method not found"], [failure.id, failure.error.fetch("code"), failure.error.fetch("message")]
    assert_nil failure.error["data"]

    without_params = @wire.read
    assert_instance_of Wire::Request, without_params
    assert_nil without_params.params
  end

  def test_a_request_whose_id_is_null_is_a_notification
    @peer_writes.puts %({"jsonrpc":"2.0","id":null,"method":"session/cancel","params":{}})

    assert_instance_of Wire::Notification, @wire.read
  end

  def test_blank_lines_and_surrounding_whitespace_are_skipped
    @peer_writes.write "\n   \n  {\"jsonrpc\":\"2.0\",\"method\":\"ping\"}  \n\n"

    frame = @wire.read
    assert_equal "ping", frame.method
  end

  def test_a_malformed_line_is_answered_parse_error_and_the_wire_reads_on
    @peer_writes.puts "this is not json"
    @peer_writes.puts %({"jsonrpc":"2.0","method":"ping"})

    frame = @wire.read
    assert_equal "ping", frame.method
    assert_equal %({"jsonrpc":"2.0","id":null,"error":{"code":-32700,"message":"Parse error"}}\n), answer_line
  end

  def test_invalid_utf8_bytes_are_a_parse_error_not_a_death
    @peer_writes.write "{\"jsonrpc\":\"2.0\",\"method\":\"\xFF\xFE\"}\n".b
    @peer_writes.puts %({"jsonrpc":"2.0","method":"ping"})

    assert_equal "ping", @wire.read.method
    assert_equal(-32700, JSON.parse(answer_line).dig("error", "code"))
  end

  def test_a_line_that_is_no_message_is_answered_invalid_request_with_its_id_when_it_has_one
    @peer_writes.puts "[1,2,3]"
    @peer_writes.puts "42"
    @peer_writes.puts %({"jsonrpc":"2.0"})
    @peer_writes.puts %({"jsonrpc":"2.0","id":7})
    @peer_writes.puts %({"jsonrpc":"2.0","id":{"nested":true},"method":"x"})
    @peer_writes.puts %({"jsonrpc":"2.0","method":"ping"})

    assert_equal "ping", @wire.read.method
    answers = Array.new(5) { JSON.parse(answer_line) }
    assert_equal [-32600] * 5, answers.map { |answer| answer.dig("error", "code") }
    assert_equal ["Invalid Request"] * 5, answers.map { |answer| answer.dig("error", "message") }
    assert_equal [nil, nil, nil, 7, nil], answers.map { |answer| answer.fetch("id") }
  end

  def test_utf8_round_trips_both_ways
    text = "héllo — 日本語 \u{1F600}"
    @wire.write_notification("session/update", { "text" => text })
    line = @peer_reads.gets
    assert_equal Encoding::UTF_8, line.encoding
    assert line.valid_encoding?, "the wire's bytes are valid UTF-8"
    assert_equal text, JSON.parse(line).dig("params", "text")

    @peer_writes.puts JSON.generate({ "jsonrpc" => "2.0", "method" => "m", "params" => { "text" => text } })
    read = @wire.read.params.fetch("text")
    assert_equal text, read
    assert_equal Encoding::UTF_8, read.encoding
  end

  def test_eof_reads_nil_and_keeps_reading_nil_and_a_trailing_unterminated_line_is_still_a_frame
    @peer_writes.write %({"jsonrpc":"2.0","method":"last"})
    @peer_writes.close

    assert_equal "last", @wire.read.method
    assert_nil @wire.read
    assert_nil @wire.read
  end

  def test_writing_after_the_peer_went_away_raises_closed
    @peer_reads.close

    assert_raises(Rho::Acp::Closed) { @wire.write_notification("m", {}) }
  end

  def test_writing_after_close_raises_closed_and_reading_answers_nil
    @wire.close

    assert_raises(Rho::Acp::Closed) { @wire.write_notification("m", {}) }
    assert_nil @wire.read
  end

  def test_writes_from_many_threads_never_interleave
    threads = Array.new(8) do |n|
      Thread.new { 50.times { |i| @wire.write_notification("m", { "n" => n, "i" => i, "pad" => "x" * 2000 }) } }
    end
    lines = []
    reader = Thread.new { lines << @peer_reads.gets while lines.length < 400 }
    threads.each(&:join)
    reader.join(5)

    assert_equal 400, lines.length
    assert lines.all? { |line| JSON.parse(line).fetch("method") == "m" }
  end

  # FD HYGIENE: `Wire.over_stdio` takes the ORIGINAL fd 1
  # for the wire and points STDOUT and `$stdout` at stderr, so a `puts`
  # anywhere in the process — and a child spawned with an inherited
  # stdout — lands on stderr and the wire stays JSON.
  def test_over_stdio_keeps_the_wire_json_while_prints_and_children_go_to_stderr
    Dir.mktmpdir("acp-wire") do |dir|
      script = File.join(dir, "child.rb")
      File.write(script, <<~RUBY)
        $LOAD_PATH.unshift #{File.expand_path("../../lib", __dir__).inspect}
        require "rho/acp"
        wire = Rho::Acp::Wire.over_stdio
        puts "junk on stdout"
        $stdout.puts "junk on $stdout"
        STDOUT.puts "junk on STDOUT"
        warn "a warning"
        system(#{Gem.ruby.inspect}, "-e", "puts 'junk from a child'")
        wire.write_result(0, { "protocolVersion" => Rho::Acp::Methods::PROTOCOL_VERSION })
        frame = wire.read
        wire.write_result(frame.id, { "echo" => frame.params })
      RUBY
      stderr_path = File.join(dir, "stderr")
      io = IO.popen([Gem.ruby, script], "r+", err: stderr_path)
      io.puts %({"jsonrpc":"2.0","id":1,"method":"m","params":{"k":"v"}})
      io.close_write
      lines = io.readlines
      io.close

      assert_equal 2, lines.length, lines.inspect
      assert_equal({ "jsonrpc" => "2.0", "id" => 0, "result" => { "protocolVersion" => 1 } }, JSON.parse(lines[0]))
      assert_equal({ "echo" => { "k" => "v" } }, JSON.parse(lines[1]).fetch("result"))
      stderr = File.read(stderr_path)
      %w[junk\ on\ stdout junk\ on\ $stdout junk\ on\ STDOUT a\ warning junk\ from\ a\ child].each do |line|
        assert_includes stderr, line
      end
    end
  end
end
