require "json"
require "time"

module E2E
  # Each scored draw is appended to records.jsonl and each provider call to calls.jsonl.
  # Writes fail loudly so a run cannot silently lose measurements. With no output directory,
  # the probe's final report remains the record of the run.
  module BenchRecords
    RECORDS = "records.jsonl".freeze
    CALLS = "calls.jsonl".freeze
    # What a call line may carry: the call's own facts, never a scorer's reading of the draw, so the
    # watch that prints it stays blind to outcomes.
    HEARTBEAT = %w[model objective sample index seconds usage retries].freeze

    WriteFailed = Class.new(StandardError)

    # A FAILED CALL, as every bench records its error (`ManualClient.error_text`: the class, then the
    # message): the gem's own error vocabulary, since its transports wrap every timeout, socket and
    # TLS failure in it, and its protocols name what a provider answered. Any other class a record
    # carries came from the harness — a scorer's KeyError as much as a NoMethodError, an emulator
    # that raised, a stream line that failed to land — and is a HARNESS FAULT, never the provider
    # or the model; so are the gem's own refusals of the request the harness built
    # (`REQUEST_REFUSED`: its validation classes
    # and its capability check), raised before a byte is sent. The one rule every reader of a record
    # applies: the probes' own gate, the watch, the smoke and the analysis.
    CALL_FAILURE = "SimpleInference::".freeze
    REQUEST_REFUSED = %w[
      SimpleInference::ValidationError SimpleInference::BoundExceededError SimpleInference::ConfigurationError
      SimpleInference::CapabilityError
    ].freeze

    module_function

    # `error` is a record's error text or a call line's class alone; the class is what precedes the
    # first ": ".
    def harness_fault?(error)
      name = error.partition(": ").first
      !name.start_with?(CALL_FAILURE) || REQUEST_REFUSED.include?(name)
    end

    # Include the per-call messages and any repair error recorded by a historical draw.
    def errors(record) = [record["error"], record["repaired_error"], *Array(record["messages"]).map { |message| message["error"] }].compact

    # The harness faults among the records' errors: a paid run asserts there are none.
    def faults(records) = records.flat_map { |record| errors(record) }.select { |error| harness_fault?(error) }

    def progress_line(record)
      "draw #{record.values_at("model", "objective").join(" ")} ##{record["sample"]}"
    end

    def append(dir, record, env: ENV)
      if dir.to_s.empty? || blind_rehearsal?(env)
        record
      else
        write(File.join(dir, RECORDS), record.merge(stamp(env)))
        record
      end
    end

    # `facts` may hold anything the caller has at hand; `error` (a bench's error text, its class
    # first) is kept as its class alone.
    def heartbeat(dir, facts, env: ENV)
      return if dir.to_s.empty?

      error_class = facts["error"]&.split(": ", 2)&.first
      write(File.join(dir, CALLS), facts.slice(*HEARTBEAT).merge(stamp(env).except("pid"), { "error_class" => error_class }.compact))
    end

    def stamp(env)
      { "arm" => env["E2E_BENCH_ARM"], "process" => env["E2E_BENCH_PROCESS"],
        "recorded_at" => Time.now.utc.iso8601(3), "pid" => Process.pid }
    end

    # THE FAKE REHEARSAL'S `blind` INJECTION (`FakeBenchAdapter`): a fake job told to go blind
    # appends no record while it keeps printing its progress, which is the case the watch's BLIND
    # stop exists for. Only a fake job reads it.
    def blind_rehearsal?(env)
      env["E2E_BENCH_CLIENT"] == "fake" && env["E2E_BENCH_FAKE_INJECT"].to_s.split(",").include?("blind")
    end

    def write(path, fields)
      line = JSON.generate(fields)
      File.open(path, "a", encoding: Encoding::UTF_8) do |file|
        file.write("#{line}\n")
        file.flush
      end
      nil
    rescue SystemCallError, IOError, JSON::GeneratorError, Encoding::UndefinedConversionError => error
      raise WriteFailed, "#{path}: #{error.class}: #{error.message[0, 200]}"
    end
    private_class_method :stamp, :blind_rehearsal?, :write
  end
end
