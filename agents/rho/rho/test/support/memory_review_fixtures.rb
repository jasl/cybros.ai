require_relative "environment_fixtures"

module RhoTest
  module MemoryReviewFixtures
    def self.memory_context
      { "bindings" => %w[conversation workspace agent speaker].map do |scope|
        source = { "scope" => scope }
        source["speaker_public_id"] = "speaker-1" if scope == "speaker"
        { "name" => scope, "source" => source, "access" => "read_write" }
      end }
    end

    def self.resolve(binding)
      source = binding.fetch("source")
      scope = source.fetch("scope")
      owner = { "conversation" => source.fetch("conversation_public_id", "conversation-1"), "workspace" => "workspace",
        "agent" => "agent-1", "speaker" => "agent-1" }.fetch(scope)
      speaker = source["speaker_public_id"]
      binding.merge("scope" => scope, "collection_public_id" => "collection-#{scope}-#{owner}-#{speaker}",
        "owner_public_id" => owner, "speaker_public_id" => speaker, "state" => "active")
    end

    def self.projection(selection)
      { "bindings" => selection.fetch("bindings").map { |binding| resolve(binding) } }
    end

    def self.capture(selection)
      { "bindings" => selection.fetch("bindings").map do |binding|
        binding.merge("capture" => resolve(binding).slice("collection_public_id", "owner_public_id", "scope", "speaker_public_id"))
      end }
    end

    def self.effective_memory_context = projection(memory_context)

    Row = Data.define(:collection_public_id, :public_id, :path, :lock_version, :content)
    Page = Data.define(:items)
    Variant = Data.define(:public_id, :run_public_id, :status, :memory_context, :prompt_text, :content, :model) do
      def initialize(public_id: "variant", **) = super
    end
    Turn = Data.define(:public_id, :position, :kind, :status, :visibility, :inherited, :active_variant, :created_at, :reference) do
      def initialize(reference: false, **) = super
      def inherited? = inherited
      def reference? = reference
    end

    class Memory
      attr_accessor :before_write, :speaker_public_id
      attr_reader :rows, :writes, :reads

      def initialize(conversation)
        @conversation = conversation
        @rows, @writes, @reads = {}, [], []
        @serial = 0
      end

      def bindings = @conversation.memory_bindings(speaker_public_id: speaker_public_id)

      def read(path)
        @reads << path
        @rows.fetch(path) { raise CybrosAgent::Api::NotFound.new("missing", code: "memory_not_found") }
      end

      def write(path, content, expected_collection_public_id:, expected_public_id:, expected_lock_version:)
        callback, @before_write = @before_write, nil
        callback&.call
        current = @rows[path]
        selected = bindings.fetch("bindings").find { |binding| binding.fetch("name") == path.split("/", 2).first }
        unless selected&.fetch("collection_public_id") == expected_collection_public_id && current&.public_id == expected_public_id && current&.lock_version == expected_lock_version
          raise CybrosAgent::Api::Conflict.new("changed", code: "stale_object")
        end

        @serial += 1
        @writes << [path, content, expected_public_id, expected_lock_version]
        @rows[path] = Row.new(collection_public_id: expected_collection_public_id, public_id: current&.public_id || "document-#{@serial}", path: path,
          lock_version: current ? current.lock_version + 1 : 0, content: content)
      end

      def correct(path, content)
        row = @rows.fetch(path)
        @rows[path] = row.with(content: content, lock_version: row.lock_version + 1)
      end
    end

    class Turns
      attr_reader :rows
      def initialize = @rows = {}
      def fetch(id, include_hidden: nil) = @rows.fetch(id)
      def list(before_position:, limit:)
        Page.new(items: @rows.values.select { |row| row.position < before_position }.sort_by(&:position).last(limit))
      end
    end

    class Inputs
      Input = Data.define(:public_id, :state)
      Accepted = Data.define(:public_id)
      attr_reader :creates, :records, :deletions
      attr_accessor :lose_create, :materialized

      def initialize
        @creates, @records, @deletions, @keys = [], {}, [], {}
      end

      def create(**fields)
        @creates << fields
        key = fields.fetch(:idempotency_key)
        input = JSON.generate(fields)
        if @keys.key?(key)
          previous, public_id = @keys.fetch(key)
          raise CybrosAgent::Api::Conflict.new("mismatch", code: "idempotency_envelope_mismatch") unless previous == input
        else
          public_id = "input-#{@records.length + 1}"
          @records[public_id] = Input.new(public_id: public_id, state: "pending")
          @keys[key] = [input, public_id]
        end
        if @lose_create
          @lose_create = false
          raise CybrosAgent::TransportError, "lost input response"
        end
        Accepted.new(public_id: public_id)
      end

      def list = Page.new(items: @records.values)
      def delete(id) = (@deletions << id; @records.delete(id))
      def materialization(_id, include_hidden: nil) = @materialized
    end

    class Conversation
      attr_reader :public_id, :store_entries, :turns, :inputs, :cancellations
      attr_accessor :memory_context, :effective_memory_context, :answering_user_public_id
      attr_reader :fetches, :memory_selectors

      def initialize(workspace: nil, public_id: "conversation-1", side: false, rows: [])
        @workspace, @public_id, @side = workspace, public_id, side
        @memory_context = MemoryReviewFixtures.memory_context
        @effective_memory_context = MemoryReviewFixtures.effective_memory_context
        @answering_user_public_id = "agent-1"
        @store_entries = EnvironmentFixtures::FakeStore.new(rows)
        @memory, @turns, @inputs = Memory.new(self), Turns.new, Inputs.new
        @memory_selectors = []
        @cancellations = 0
        @fetches = 0
      end

      def fetch
        @fetches += 1
        self
      end
      def side? = @side
      def cancel = @cancellations += 1
      def fork(**fields) = @workspace.fork(self, **fields)

      def memory(speaker_public_id: nil)
        @memory_selectors << speaker_public_id
        @memory.speaker_public_id = speaker_public_id
        @memory
      end

      def memory_bindings(speaker_public_id:)
        bindings = effective_memory_context.fetch("bindings").dup
        if speaker_public_id
          memory_context.fetch("bindings").each do |binding|
            source = binding.fetch("source")
            if source["scope"] == "speaker" && source["speaker_public_id"].nil? && !bindings.any? { |row| row.fetch("name") == binding.fetch("name") }
              bindings << MemoryReviewFixtures.resolve(binding.merge("source" => source.merge("speaker_public_id" => speaker_public_id)))
            end
          end
        end
        { "bindings" => bindings }
      end

      def settle(content:, status: "completed")
        input = @inputs.records.values.first
        @inputs.records.clear
        run_id = "#{public_id}-run"
        variant = Variant.new(public_id: "#{public_id}-variant", run_public_id: run_id, status: status,
          memory_context: memory_context, prompt_text: "", content: content,
          model: CybrosAgent::Api::ConversationModel.new(provider_id: "test", model_ref: "review", reasoning_effort: nil))
        turn = Turn.new(public_id: "#{public_id}-turn", position: 1, kind: "direct_reply", status: status,
          visibility: "excluded_from_context", inherited: false, active_variant: variant, created_at: "2026-10-07T01:00:00Z")
        @turns.rows[turn.public_id] = turn
        @inputs.materialized = CybrosAgent::Api::InputMaterialization.new(input_public_id: input.public_id,
          turn_public_id: turn.public_id, variant_public_id: variant.public_id, run_public_id: run_id)
        turn
      end
    end

    class Workspace
      Forked = Data.define(:conversation)
      attr_reader :rows, :forks
      attr_accessor :lose_fork, :lose_input

      def initialize
        @rows, @forks, @keys = {}, [], {}
        @rows["conversation-1"] = Conversation.new(workspace: self)
      end

      def public_id = "workspace"
      def runs = nil
      def conversation_row = @rows.fetch("conversation-1")
      def conversation(public_id)
        @rows.fetch(public_id) { raise CybrosAgent::Api::NotFound.new("missing", code: "not_found") }
      end

      def fork(source, **fields)
        @forks << fields
        key = fields.fetch(:idempotency_key)
        unless @keys.key?(key)
          id = "side-#{@keys.length + 1}"
          rows = source.store_entries.rows.map { |row| row.with(value: JSON.parse(JSON.generate(row.value))) }
          side = Conversation.new(workspace: self, public_id: id, side: true, rows: rows)
          side.inputs.lose_create = @lose_input
          side.memory_context = source.memory_context
          side.effective_memory_context = source.effective_memory_context
          @rows[id] = side
          @keys[key] = id
        end
        if @lose_fork
          @lose_fork = false
          raise CybrosAgent::TransportError, "lost fork response"
        end
        Forked.new(conversation: @rows.fetch(@keys.fetch(key)))
      end
    end
  end
end
