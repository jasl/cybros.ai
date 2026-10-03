require_relative "fake_bench_adapter"
require_relative "manual_client"

module E2E
  # WHICH CLIENT A PAID PROBE DRAWS THROUGH. `E2E_BENCH_CLIENT=real` (or unset) is
  # `ManualClient.for`, the one builder every manual lane uses; `fake` is the same builder over
  # `FakeBenchAdapter`, so a screen's rehearsal runs the probes' real wire and parse with no socket
  # and no key. A fake client carries a placeholder the fake transport never checks — the key the
  # environment holds is never read — and `gate` is `ManualClient.validate!`, the one paid gate,
  # skipped only for a fake job since a fake job pays nothing.
  module BenchClient
    FAKE_KEY = "sk-fake".freeze
    KINDS = %w[real fake].freeze

    module_function

    def route(ref, env: ENV)
      if ref.start_with?("fake/")
        raise ArgumentError, "fake models require E2E_BENCH_CLIENT=fake" unless fake?(env)

        FakeBenchAdapter.route(ref)
      else
        ProviderLanes.route(ref)
      end
    end

    def for(route, env: ENV)
      if fake?(env)
        ManualClient.for(route, env: env.to_h.merge(route.lane.key_name => FAKE_KEY),
          adapter: FakeBenchAdapter.new(inject: FakeBenchAdapter.inject(env), stall_seconds: stall_seconds(env)))
      else
        raise ArgumentError, "fake models require E2E_BENCH_CLIENT=fake" if route.ref.start_with?("fake/")

        ManualClient.for(route, env: env)
      end
    end

    def gate(env, key_names:)
      fake?(env) || ManualClient.validate!(env, key_names: key_names)
    end

    def fake?(env)
      kind = env.fetch("E2E_BENCH_CLIENT", "real")
      raise ArgumentError, "E2E_BENCH_CLIENT is #{kind.inspect}; name one of #{KINDS.join(", ")}" unless KINDS.include?(kind)

      kind == "fake"
    end

    # A rehearsal's stall is seconds, not the hour a real stall stop would wait for.
    def stall_seconds(env) = Float(env.fetch("E2E_BENCH_FAKE_STALL_SECONDS", FakeBenchAdapter::STALL_SECONDS))
    private_class_method :stall_seconds
  end
end
