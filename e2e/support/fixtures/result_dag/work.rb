require "json"

# A local data service exercised through real runner commands. The wait exposes
# an unwanted graph barrier; it is not a scheduler or an injected task result.
class ResultDagWork
  def initialize(root = __dir__)
    @root = root
    @data = JSON.parse(File.read(File.join(root, "data.json")))
  end

  def call(arguments)
    operation, *args = arguments
    event("started", operation, args)
    result =
      case operation
      when "list"
        raise "listing_unavailable" if @data.fetch("case") == "failure"

        { "files" => @data.fetch("case") == "empty" ? [] : records.map { |record| record.fetch("path") } }
      when "discover"
        group = args.fetch(0)
        wait_for("inspected-a") if group == "b"
        { "files" => records.select { |record| record.fetch("group") == group }.map { |record| record.fetch("path") } }
      when "inspect"
        record = records.find { |item| item.fetch("path") == args.fetch(0) }
        raise "unknown_path" unless record

        mark("inspected-#{record.fetch("group")}")
        record.slice("path", "score")
      when "source"
        source = args.fetch(0)
        wait_for("consumed-c") if source == "b"
        { "source" => source, "token" => @data.fetch("tokens").fetch(source), "value" => source == "a" ? 7 : 11 }
      when "consume"
        consumer = args.fetch(0)
        sources = { "c" => ["a"], "d" => %w[a b] }.fetch(consumer)
        expected = sources.map { |source| @data.fetch("tokens").fetch(source) }
        raise "wrong_tokens" unless args.drop(1) == expected

        mark("consumed-#{consumer}")
        { "consumer" => consumer, "value" => consumer == "c" ? 7 : 18 }
      else
        raise "unknown_command"
      end
    event("completed", operation, args)
    result.merge("noise" => @data.fetch("noise"))
  rescue StandardError
    event("failed", operation, args)
    raise
  end

  private

    def records = @data.fetch("records")

    def mark(name) = File.write(File.join(@root, name), "done\n")

    def wait_for(name)
      deadline = Process.clock_gettime(Process::CLOCK_MONOTONIC) + @data.fetch("wait_seconds")
      until File.exist?(File.join(@root, name))
        raise "dependency_wait_expired" if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= deadline

        sleep 0.02
      end
    end

    def event(state, operation, arguments)
      File.open(File.join(@root, "events.jsonl"), "a") do |file|
        file.flock(File::LOCK_EX)
        file.puts(JSON.generate("state" => state, "operation" => operation, "arguments" => arguments))
      end
    end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts JSON.generate(ResultDagWork.new.call(ARGV))
  rescue StandardError => error
    warn error.message
    exit 9
  end
end
