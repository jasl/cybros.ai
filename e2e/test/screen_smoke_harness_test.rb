$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "fileutils"
require "json"
require "minitest/autorun"
require "tmpdir"
require "support/screen/definition"
require "support/screen/smoke"

# THE SMOKE IS A FAULT AND CACHE CHECK, NEVER A PRICER: one paid draw per (smoke lane, arm) through
# the real probe, two serial draws where the cache is checked, before the stamp. It passes only when
# every job exited 0, wrote its draws with their usage, and carried no harness-fault class — and on
# a cache lane the second draw read at least nine tenths of the first draw's prompt from the cache
# (the prompt as the receipt counts it: input with the cache classes folded in). A failed smoke is
# no stamp and no relaunch spent. Pure Ruby over tmpdir homes and recorded usage.
class ScreenSmokeHarnessTest < Minitest::Test
  S = E2E::Screen
  FAKE = File.expand_path("../support/fixtures/screen/fake", __dir__)

  # The Opus pair the probe records on the Anthropic wire: the first draw writes the prefix
  # (creation, folded into input), the second reads it.
  WRITTEN = { "input_tokens" => 9_020, "output_tokens" => 300, "cache_creation_tokens" => 9_000 }.freeze
  READ = { "input_tokens" => 9_020, "output_tokens" => 310, "cache_read_tokens" => 9_000 }.freeze

  def test_the_cache_holds_when_the_second_draw_reads_nine_tenths_of_the_first_prompt
    assert S::Smoke.cache_holds?(WRITTEN, READ)
    refute S::Smoke.cache_holds?(WRITTEN, READ.merge("cache_read_tokens" => 8_000)), "8,000 < 0.9 × 9,020"
    refute S::Smoke.cache_holds?(WRITTEN, READ.except("cache_read_tokens")), "a silent miss reads nothing"
  end

  def test_the_smoke_jobs_are_one_draw_per_lane_and_arm_and_two_on_a_cache_lane
    jobs = S::Smoke.jobs(definition)
    assert_equal [["base", "fake/chat-a", 1], ["base", "fake/messages", 2],
                  ["candidate", "fake/chat-a", 1], ["candidate", "fake/messages", 2]],
      jobs.map { |job| [job.arm, job.model, job.n] }
    assert_equal [%w[O1]], jobs.map(&:objectives).uniq
    assert_equal "smoke/base/compose/fake_messages", jobs[1].dir
  end

  def test_a_clean_smoke_passes_and_prints_its_draws_and_cache_line
    with_smoke do |home, jobs|
      jobs.each { |job| ended(home, job, 0, Array.new(job.n) { |i| draw(job, i + 1, i.zero? ? WRITTEN : READ) }) }
      result = S::Smoke.read(home, jobs, pricer: ->(_record) { 0.02 })
      assert result.ok, result.lines.join("\n")
      assert_in_delta 0.12, result.spend_usd
      assert_includes result.lines, "smoke.cache.fake_messages.base=9000 ≥ 0.9 × 9020 ok"
      assert_equal 6, result.ids.size
    end
  end

  def test_each_way_a_smoke_fails
    {
      "a non-zero exit" => ->(home, job) { ended(home, job, 1, [draw(job, 1, WRITTEN)]) },
      "a harness-fault class" => ->(home, job) { ended(home, job, 0, [draw(job, 1, WRITTEN).merge("error" => "NoMethodError: x")]) },
      "no usage" => ->(home, job) { ended(home, job, 0, [draw(job, 1, nil)]) },
      "a missing draw" => ->(home, job) { ended(home, job, 0, []) },
      "a silent cache miss" => lambda do |home, job|
        ended(home, job, 0, [draw(job, 1, WRITTEN), draw(job, 2, READ.merge("cache_read_tokens" => 0))])
      end,
    }.each do |why, spoil|
      with_smoke do |home, jobs|
        messages = jobs.find { |job| job.model.start_with?("fake/messages") && job.arm == "base" }
        (jobs - [messages]).each { |job| ended(home, job, 0, Array.new(job.n) { |i| draw(job, i + 1, i.zero? ? WRITTEN : READ) }) }
        spoil.call(home, messages)
        result = S::Smoke.read(home, jobs, pricer: ->(_record) { 0.02 })
        refute result.ok, why
      end
    end
  end

  private

    def definition = S::Definition.load(FAKE)

    def with_smoke
      Dir.mktmpdir("screen-smoke") do |home|
        jobs = S::Smoke.jobs(definition)
        jobs.each { |job| FileUtils.mkdir_p(job.path(home)) }
        FileUtils.mkdir_p(File.join(home, "smoke", "logs"))
        yield home, jobs
      end
    end

    def draw(job, sample, usage)
      { "arm" => job.arm, "process" => job.index.to_s, "model" => job.model, "objective" => "O1", "sample" => sample,
        "recorded_at" => Time.now.utc.iso8601(3), "usage" => usage }.compact
    end

    def ended(home, job, status, records)
      File.write(File.join(job.path(home), "records.jsonl"), records.map { |record| "#{JSON.generate(record)}\n" }.join)
      File.write(S::Smoke.log(home, job), "exit=#{status}\n")
    end
end
