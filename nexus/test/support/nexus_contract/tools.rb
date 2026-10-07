module Nexus
  module Contract
    class << self
      private

        # THE SETTLED FIXTURE FOR A PACK ROW'S RENDER: the profile read a kernel answers after an
        # application declared the SDK pack's `claude` row over the six canonicals the tables spell
        # — the plain entries the row keeps, then its preset's aliases, each a full function block
        # with its resolution facts beside it, the `Agent` recut rendered against the kernel's own
        # template. The pack's YAML is read as DATA here (the kernel never loads the gem); the SDK's
        # test renders the same row through its own loader and compares, so the two implementations
        # cannot drift apart unseen.
        PACK_DIR = Rails.root.join("../sdks/ruby/lib/cybros_agent/model_adaptations")

        ALIAS_RENDER_ROW = "claude".freeze

        def alias_render
          presets = YAML.safe_load_file(PACK_DIR.join("presets.yml"))
          row = YAML.safe_load_file(PACK_DIR.join("rows", "#{ALIAS_RENDER_ROW}.yml"))
          plain = presets.fetch("plain")
          styles = row.fetch("tool_style")
          superseded = styles.flat_map { |word| presets.dig("presets", word, "supersedes") }
          kept = plain.reject { |canonical, _name| superseded.include?(canonical) && !styles.include?("nexus") }
          aliases = presets.fetch("words").select { |word| styles.include?(word) }
            .flat_map { |word| presets.dig("presets", word, "aliases") }
          entries = kept.keys.map { |canonical| Nexus::ToolRegistry.function_definition(canonical) } +
            aliases.map { |spec| alias_entry(spec) }
          refusal = Nexus::ToolDeclarations.refusal(entries)
          raise ArgumentError, "the kernel refuses the #{ALIAS_RENDER_ROW} row's set: #{refusal}" if refusal

          Nexus::ToolDeclarations.render(entries)
        end

        # The SDK's compact alias shape (`ToolCatalog#alias`): empty facts
        # dropped; a `recut` is the kernel's template with its anchor replaced.
        def alias_entry(spec)
          facts = {
            "canonical" => spec.fetch("canonical"),
            "params" => spec.fetch("params", {}),
            "omit" => spec.fetch("omit", []),
            "description" => spec["description"] || recut(spec),
          }.reject { |_key, value| value.nil? || value.empty? }
          { "type" => "function", "function" => { "name" => spec.fetch("name") } }.merge(facts)
        end

        def recut(spec)
          edit = spec["recut"] or return nil
          template = Nexus::ToolRegistry.entry(spec.fetch("canonical")).template
          unless template.include?(edit.fetch("anchor"))
            raise ArgumentError, "#{spec.fetch("name")}: the anchor moved; re-cut the pack's entry"
          end

          template.sub(edit.fetch("anchor")) { edit.fetch("replacement") }
        end

        # THE KERNEL TOOL CATALOG as `GET /agent_api/v1/tools` serves it: the whole listing through
        # the one presenter the route renders, so an SDK's reader of `template` — the macro-bearing
        # source an adaptation pack's recut edits — is settled against the kernel's own bytes rather
        # than a hand-written sample. The registry is a constant of the process, so the fixture is
        # deterministic and regenerates the day a description is re-cut.
        def tools
          listing = { "tools" => AgentAPI::ToolPresenter.index.select { |row| row.fetch(:canonical_name) == TOOLS_FIXTURE_ENTRY } }

          {
            "listing_envelope" => listing.keys,
            "entry_keys" => listing.fetch("tools").fetch(0).keys.map(&:to_s),
            "valid_listing_fixture" => listing,
            "valid_memory_listing_fixture" => { "tools" => AgentAPI::ToolPresenter.index.select do |row|
              row.fetch(:canonical_name).start_with?("nexus.memory.")
            end },
            "valid_history_listing_fixture" => { "tools" => AgentAPI::ToolPresenter.index.select do |row|
              %w[nexus.conversation.search nexus.conversation.read].include?(row.fetch(:canonical_name))
            end },
            "valid_discovery_listing_fixture" => { "tools" => AgentAPI::ToolPresenter.index.select do |row|
              %w[nexus.tools.search nexus.tools.call].include?(row.fetch(:canonical_name))
            end },
            "valid_assembly_fixture" => tool_assembly,
            "unknown_field_behavior" => "ignore",
          }
        end

        # The same Runner announcement consumed by executor discovery supplies
        # an exact callable schema and target-qualified environment to assembly.
        def tool_assembly
          executor = task_executors.fetch("discovery_fixture")
          offered = executor.fetch("served_tools").find { |entry| entry.fetch("name") == "read" }
          runner = { "runner_executor_public_id" => executor.fetch("public_id"),
            "display_name" => executor.fetch("display_name"), "environment" => executor.fetch("environment") }
          {
            "tool_definitions" => [{
              "type" => "function",
              "function" => { "name" => offered.fetch("name"), "description" => offered.fetch("description"),
                "parameters" => offered.fetch("input_schema") },
              "route" => { "kind" => "runner", "runner_executor_public_id" => runner.fetch("runner_executor_public_id"),
                "tool_name" => offered.fetch("name") },
              "defer_loading" => true,
            }],
            "environment" => {
              "default_runner_executor_public_id" => runner.fetch("runner_executor_public_id"),
              "executors" => [runner], "runner_candidates" => [runner],
            },
          }
        end
    end
  end
end
