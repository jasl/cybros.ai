require "cybros_agent"
require "json"
require "time"
require "stringio"

module E2E
  # Synthetic tools exercise Nexus delivery without borrowing a product runtime.
  # Tests control when a sweep runs, so they can inspect pending work before claim.
  class FakeExecutor
    ECHO = {
      "name" => "echo", "timeout_ms" => 30_000,
      "effect_profile" => {
        "kind" => "read_only", "destructive" => false, "effect_scope" => "closed",
        "idempotency" => "intrinsic", "reconciliation" => "none",
      },
    }.freeze

    class Cancelled < StandardError; end

    attr_reader :client, :address, :claims

    def initialize(base_url:, credential:, directory: nil, log: ->(_event, **_fields) { })
      @client = CybrosAgent::ExecutorClient.new(base_url: base_url, credential: credential)
      @address = @client.executor.executor
      @claims = []
      @directory, @log = directory, log
      @stopped = false
    end

    def announce(roles: [address.kind], tools: ["echo"])
      declarations = tools.map do |name|
        declaration = ECHO.merge("name" => name, "timeout_ms" => (name.include?("compaction") || name == "compact_history" ? 5_000 : 30_000), "description" => "Synthetic #{name} for protocol tests.",
          "input_schema" => { "type" => "object", "additionalProperties" => true })
        if name == "checkpoint_write"
          declaration["effect_profile"] = ECHO.fetch("effect_profile").merge("kind" => "write")
        end
        declaration
      end
      services = roles.to_h { |role| [role, { "tools" => declarations }] }
      services.each_value { |service| service["environment"] = { "root" => @directory } } if @directory
      client.announce(services: services)
      @log.call("announced", executor_public_id: address.public_id, tools: tools)
      self
    end

    def stop = @stopped = true

    def sweep
      after = nil
      loop do
        page = client.inbox.list(after: after)
        page.items.each do |row|
          next if row.claimed

          door = client.inbox_task(run_public_id: row.run_public_id, task_key: row.task_key)
          claimed = door.claim
          @claims << claimed
          @log.call("claimed", run: row.run_public_id, task: row.task_key, tool: claimed.task.tool_name)
          execute(door, claimed)
        end
        after = page.next_after
        break unless after
      end
    end

    private

      def execute(door, claimed)
        input = claimed.task.tool_input.to_h
        metadata = {}
        content = case claimed.task.tool_name
        when "echo", "pool_echo"
          "echo:#{JSON.generate(input)}"
        when "checkpoint_write"
          metadata["checkpoint"] = input.fetch("checkpoint")
          "synthetic write"
        when "checkpoint_restore"
          @log.call("restored", input: input, executor_public_id: address.public_id)
          "synthetic restore"
        when "read"
          File.read(File.expand_path(input.fetch("path"), @directory))
        when "attachment"
          upload = input.fetch("upload")
          descriptor = door.attachment(upload, claim_token: claimed.claim_token)
          io = StringIO.new
          door.attachment_bytes(descriptor.public_id, io, claim_token: claimed.claim_token)
          io.string
        when "synthetic_wait"
          wait_for(door, claimed, seconds: input.fetch("seconds", 0), release: input["release"])
          input.fetch("text", "wait complete")
        when "compact_history"
          ["Independent summary", input.fetch("history"), input.fetch("retained_tail")].join("\n")
        when "held_compaction"
          wait_for(door, claimed, seconds: 60)
          "held compaction released"
        else
          raise "unexpected synthetic tool #{claimed.task.tool_name}"
        end
        door.commit(claim_token: claimed.claim_token, outcome: "completed", is_error: false, content: content, metadata: metadata)
        @log.call("committed", run: claimed.task.run_public_id, task: claimed.task.task_key)
      rescue Cancelled
        @log.call("cancelled", run: claimed.task.run_public_id, task: claimed.task.task_key)
      end

      # A single controlled wait exercises claim reads and deadline extension.
      # It owns no production queue, resource registry or worker pool.
      def wait_for(door, claimed, seconds:, release: nil)
        finish = Process.clock_gettime(Process::CLOCK_MONOTONIC) + (release ? 60 : seconds)
        extend_at = Process.clock_gettime(Process::CLOCK_MONOTONIC) + 10
        loop do
          raise Cancelled if @stopped
          raise Cancelled unless door.claim_status(claim_token: claimed.claim_token).active

          now = Process.clock_gettime(Process::CLOCK_MONOTONIC)
          break if release ? File.exist?(File.expand_path(release, @directory)) : now >= finish
          raise "synthetic release did not arrive" if now >= finish

          if now >= extend_at
            door.extend(claim_token: claimed.claim_token, timeout_ms: ECHO.fetch("timeout_ms"))
            extend_at = now + 10
          end
          sleep 0.1
        rescue CybrosAgent::TransportError, CybrosAgent::Api::ServerError
          raise if Process.clock_gettime(Process::CLOCK_MONOTONIC) >= finish

          sleep 0.2
        end
      end
  end
end
