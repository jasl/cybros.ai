$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "json"
require "minitest/autorun"
require "tmpdir"
require "support/bench_records"

# THE RECORD STREAM A SCREEN'S WATCH READS: one JSON line per scored draw the moment the probe
# returns it, stamped with the job it came from, and one line per provider call carrying only what
# the watch may see. A lost write is loud — the watch prices spend and counts draws off this stream,
# so a record that silently failed to land would be a draw the stops never saw. Pure Ruby over a
# tmpdir.
class BenchRecordsHarnessTest < Minitest::Test
  R = E2E::BenchRecords
  ENV_OF_A_JOB = { "E2E_BENCH_ARM" => "with", "E2E_BENCH_PROCESS" => "3" }.freeze

  def test_a_record_is_one_json_line_stamped_with_its_job_and_the_record_comes_back
    Dir.mktmpdir("bench-records") do |dir|
      record = { "objective" => "O1", "model" => "openrouter/acme/test-model", "sample" => 2, "first_time_right" => true }
      returned = R.append(dir, record, env: ENV_OF_A_JOB)
      assert_same record, returned, "the caller keeps its own record"

      R.append(dir, record.merge("sample" => 3), env: ENV_OF_A_JOB)
      lines = File.readlines(File.join(dir, R::RECORDS), chomp: true, encoding: Encoding::UTF_8)
      assert_equal 2, lines.size
      written = JSON.parse(lines.first)
      assert_equal record, written.slice(*record.keys)
      assert_equal ["with", "3", Process.pid], written.values_at("arm", "process", "pid")
      assert_match(/\A\d{4}-\d\d-\d\dT\d\d:\d\d:\d\d\.\d{3}Z\z/, written["recorded_at"])
    end
  end

  # A record that holds the NUL a model wrote is still one line: JSON escapes it.
  def test_a_nul_in_a_script_is_written_escaped_on_its_one_line
    Dir.mktmpdir("bench-records") do |dir|
      R.append(dir, { "script" => "g.model({ prompt: \"a\u0000b\" });" }, env: ENV_OF_A_JOB)
      line = File.read(File.join(dir, R::RECORDS), encoding: Encoding::UTF_8)
      assert_equal 1, line.lines.size
      assert_equal "g.model({ prompt: \"a\u0000b\" });", JSON.parse(line)["script"]
    end
  end

  def test_a_write_that_fails_raises_rather_than_warns
    Dir.mktmpdir("bench-records") do |dir|
      missing = File.join(dir, "no-such-dir")
      error = assert_raises(R::WriteFailed) { R.append(missing, { "objective" => "O1" }, env: ENV_OF_A_JOB) }
      assert_includes error.message, "records.jsonl"
      assert_raises(R::WriteFailed) { R.heartbeat(missing, { "model" => "m" }, env: ENV_OF_A_JOB) }
    end
  end

  # No bench directory named (a paid run outside a screen): the report is the run's record and no
  # stream is written.
  def test_no_directory_writes_nothing_and_returns_the_record
    record = { "objective" => "O1" }
    assert_same record, R.append(nil, record, env: ENV_OF_A_JOB)
    assert_same record, R.append("", record, env: ENV_OF_A_JOB)
    assert_nil R.heartbeat(nil, { "model" => "m" }, env: ENV_OF_A_JOB)
  end

  # THE HEARTBEAT IS OUTCOME-BLIND: whatever a caller hands it, only the call's own facts land —
  # never a scorer's reading of the draw.
  def test_a_heartbeat_keeps_only_the_blind_fields_and_names_the_error_by_its_class
    Dir.mktmpdir("bench-records") do |dir|
      facts = { "model" => "anthropic/test-model", "objective" => "O7", "sample" => 4, "index" => 2, "seconds" => 3.25,
                "usage" => { "input_tokens" => 900, "output_tokens" => 40, "cache_read_tokens" => 8_000 },
                "retries" => [{ "error" => "SimpleInference::ConnectionError: reset", "pause_seconds" => 10 }],
                "error" => "SimpleInference::TimeoutError: execution expired",
                "first_time_right" => true, "pass" => false, "door_kind" => "compose_steps", "finish" => "tool_calls",
                "script" => "g.model({ prompt: \"x\" });" }
      R.heartbeat(dir, facts, env: ENV_OF_A_JOB)
      written = JSON.parse(File.read(File.join(dir, R::CALLS), encoding: Encoding::UTF_8))
      assert_equal %w[arm error_class index model objective process recorded_at retries sample seconds usage], written.keys.sort
      assert_equal "SimpleInference::TimeoutError", written["error_class"]
      assert_equal %w[with 3], written.values_at("arm", "process")
      refute written.key?("first_time_right")
    end
  end

  def test_a_heartbeat_without_an_error_carries_no_error_class
    Dir.mktmpdir("bench-records") do |dir|
      R.heartbeat(dir, { "model" => "m", "seconds" => 1.0 }, env: ENV_OF_A_JOB)
      written = JSON.parse(File.read(File.join(dir, R::CALLS), encoding: Encoding::UTF_8))
      refute written.key?("error_class")
    end
  end

  # THE ONE HARNESS-FAULT RULE: a call that failed carries the gem's own class; any other class a
  # record carries — on its call, its repair or any of its messages — is the harness's, and so is
  # the gem's refusal of the request the harness built, raised before a byte was sent.
  def test_a_harness_fault_is_any_recorded_class_but_the_gems_own_call_failure
    refute R.harness_fault?("SimpleInference::TimeoutError: execution expired")
    refute R.harness_fault?("SimpleInference::HTTPError: 529 overloaded")
    refute R.harness_fault?("SimpleInference::Protocols::OpenAIResponses::ResponseFailedError: failed"), "what the provider answered"
    refute R.harness_fault?("SimpleInference::ConnectionError"), "a call line's class alone"
    ["NoMethodError: undefined method 'x'", 'KeyError: key not found: "key"', "E2E::BenchRecords::WriteFailed: x: Errno::ENOENT",
     "SimpleInference::ValidationError: unknown request option(s): prompt_cache_key",
     "SimpleInference::BoundExceededError: max_output_tokens 99999 exceeds 65536", "SimpleInference::ConfigurationError: no base_url",
     "SimpleInference::CapabilityError: tools are not supported", "SimpleInference::ValidationError"]
      .each { |error| assert R.harness_fault?(error), error }

    records = [{ "error" => "SimpleInference::ConnectionError: reset", "repaired_error" => "KeyError: k" },
               { "messages" => [{ "index" => 1 }, { "index" => 2, "error" => "TypeError: nil" }] },
               { "objective" => "O1" }]
    assert_equal ["KeyError: k", "TypeError: nil"], R.faults(records)
  end

  # THE FAKE REHEARSAL'S `blind` INJECTION: a fake job told to go blind appends no record while
  # its progress lines run on, so the watch's BLIND stop meets the case it exists for. A real
  # job never skips a record.
  def test_a_fake_blind_rehearsal_skips_the_records_and_nothing_else_does
    Dir.mktmpdir("bench-records") do |dir|
      blind = ENV_OF_A_JOB.merge("E2E_BENCH_CLIENT" => "fake", "E2E_BENCH_FAKE_INJECT" => "spend,blind")
      R.append(dir, { "objective" => "O1" }, env: blind)
      refute File.exist?(File.join(dir, R::RECORDS))
      R.append(dir, { "objective" => "O1" }, env: blind.merge("E2E_BENCH_CLIENT" => "real"))
      assert File.exist?(File.join(dir, R::RECORDS))
    end
  end
end
