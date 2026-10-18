require_relative "../support/runner_affinity_smoke"

smoke = E2E::RunnerAffinitySmoke.new
if ARGV == ["--preflight"]
  puts JSON.pretty_generate(smoke.preflight)
elsif ARGV.empty?
  summary = smoke.run
  puts JSON.generate(summary)
  exit(1) unless summary.fetch("summary").values_at("failed", "skipped").all?(&:zero?)
else
  abort "usage: bundle exec ruby manual/runner_affinity_smoke.rb [--preflight]"
end
