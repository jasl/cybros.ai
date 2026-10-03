require "fileutils"
require "json"
require "securerandom"
require "yaml"
require_relative "manual_client"
require_relative "live_journey"

module E2E
  # A small paid diagnostic over the existing rho journey. The model receives a
  # command interface and an objective, never a successful compose program.
  module ResultDag
    CASES = %w[dependencies dynamic pipeline empty failure].freeze
    PIPELINE_FEEDBACK = <<~TEXT.freeze
      Feedback from the earlier diagnostic: the authored graph serialized the
      discoveries. Both discovery tasks must start independently. Source B's wait
      belongs inside the fixture; remove the authored dependency from A's
      inspection to B's discovery. Keep the two per-group pipelines concurrent.
    TEXT
    FIXTURE = File.expand_path("fixtures/result_dag/work.rb", __dir__)
    INSTRUCTIONS = <<~TEXT.freeze
      Exercise the available compose tool with wait:true. Author the complete
      workflow yourself, using its declared after/results references and g.script
      stages where results determine later work. Use synchronous JavaScript; no
      async/await or promises. Issue one compose call before any environment tool.
      A rejected program may be corrected, but do not replace the workflow with
      sequential calls in the main conversation. After it settles, briefly report
      its result and stop. You may validate your JavaScript on your own scratch
      files. Every fixture business command must run inside the authored workflow.
      Do not read or modify the fixture implementation or its private data; access
      the fixture only through the command interface described below.

      The compose call's initial `script` builds top-level tasks; it is not a
      result boundary. Make that builder declare one outer `g.script` task, and
      let this task create all source, consumer and reduction work. Only that
      task's final output should reach the main conversation. Nested stages may
      declare their own result inputs and generated work.

      The real bash tool runs `ruby work.rb COMMAND ...` in this project. Successful
      stdout is a JSON object. Parse the selected tool result's output only after
      checking status, is_error and error; bash structured_content contains exit
      metadata, not the JSON stdout. Every internal result contains diagnostic
      noise that must be omitted from the final reduction.
    TEXT

    module_function

    def validate!(env = ENV)
      model = env.fetch("E2E_LIVE_MODEL") { LiveJourney.default_model }
      key_name = ProviderLanes.key_name_for(model)
      raise ArgumentError, "no diagnostic provider lane is configured for #{model.inspect}" unless key_name

      ManualClient.validate!(env, key_names: [key_name])
      effort = env.fetch("E2E_RESULT_DAG_EFFORT", "")
      unless effort.empty? || (model == "openrouter/z-ai/glm-5.3-flash" && effort == "low")
        raise ArgumentError, "E2E_RESULT_DAG_EFFORT supports only low with openrouter/z-ai/glm-5.3-flash"
      end
      correction = env.fetch("E2E_RESULT_DAG_PIPELINE_CORRECTION", "")
      unless correction.empty? || (correction == "1" && selected(env) == ["pipeline"])
        raise ArgumentError, "pipeline correction requires E2E_RESULT_DAG_ONLY=pipeline"
      end
      selected(env)
    end

    # A fresh world's ordinary catalog overlay owns this diagnostic setting.
    # Catalog entries replace whole rows, so retain every shipped fact.
    def model_overrides(nexus_root:, env: ENV)
      effort = env.fetch("E2E_RESULT_DAG_EFFORT", "")
      return {} if effort.empty?

      model = env.fetch("E2E_LIVE_MODEL")
      fragment = YAML.safe_load_file(File.join(nexus_root, "config/model_catalog/50_openrouter.yml"))
      row = fragment.fetch("models").fetch(model)
      row.fetch("capabilities").fetch("reasoning")["default_effort"] = effort
      { model => row }
    end

    def selected(env = ENV)
      names = env.fetch("E2E_RESULT_DAG_ONLY", "").split(",").map(&:strip).reject(&:empty?)
      names = CASES if names.empty?
      unknown = names - CASES
      raise ArgumentError, "unknown result DAG cases: #{unknown.join(", ")}" unless unknown.empty?

      names
    end

    def prepare(project, name)
      FileUtils.mkdir_p(project)
      FileUtils.cp(FIXTURE, File.join(project, "work.rb"))
      nonce = SecureRandom.hex(6)
      records = [
        { "path" => "a-#{nonce}.rb", "score" => 7, "group" => "a" },
        { "path" => "b-#{nonce}.rb", "score" => 11, "group" => "b" },
        { "path" => "notes-#{nonce}.md", "score" => 101, "group" => "a" },
      ]
      data = { "case" => name, "records" => records, "tokens" => { "a" => SecureRandom.hex(8), "b" => SecureRandom.hex(8) },
               "noise" => "internal-only-#{SecureRandom.hex(16)}", "wait_seconds" => 25 }
      File.write(File.join(project, "data.json"), JSON.generate(data))
      data
    end

    def prompt(name)
      objective =
        case name
        when "dependencies"
          <<~TEXT
            Use `source a` and `source b` to obtain independent values and opaque
            tokens as {"source":...,"token":...,"value":...}. `consume c TOKEN_A`
            needs only A; `consume d TOKEN_A TOKEN_B` needs both. Each consumer
            returns {"consumer":...,"value":...}. Source B deliberately
            waits for C to consume A, so waiting for both sources before C creates
            a dependency error. Put the sources and their result-driven consumer
            scripts as peers: C references only A, D references A and B. Each
            script passes its received tokens to its consume command, never guesses
            them. Reduce the two consumer results to exactly {"c":7,"d":18}.
            Enclose all source/consumer/reduction work inside one outer g.script task so
            the main conversation receives only that reduction.
          TEXT
        when "pipeline"
          <<~TEXT
            `discover a` and `discover b` return {"files":[...]} for each group.
            `inspect PATH` returns {"path":...,"score":...}. For each group,
            select only .rb paths, inspect those paths concurrently and reduce to
            {"items":[{"path":...,"score":...}],"total":...}, with total equal
            to the sum of the selected scores. Let each group's
            inspections start as soon as its discovery finishes; B's discovery
            waits for the first A inspection, so a global discovery barrier fails.
            Run the two per-group sequences concurrently, then combine their
            reductions into the same items/total shape, sorted by path.
            Put the whole pipeline inside one outer g.script task; only the final combined
            reduction returns to the main conversation.
          TEXT
        when "dynamic", "empty", "failure"
          <<~TEXT
            `list` returns {"files":[...]}; `inspect PATH` returns a path and score.
            Select only .rb paths, inspect the selected files concurrently, and
            return exactly {"items":[{"path":...,"score":...}],"total":...}, sorted
            by path, with total equal to the sum of the selected scores. Empty
            selection must return {"items":[],"total":0} without
            constructing an empty parallel group. A failed listing must make the
            selection script fail visibly, without any inspection or fabricated
            successful reduction; report that failure and stop, without retrying
            the data source. Put listing, dynamic selection, inspections and
            reduction inside one outer g.script task so only the reduction (or failure)
            returns to the main conversation.
          TEXT
        else
          raise ArgumentError, "unknown result DAG case: #{name}"
        end
      prompt = INSTRUCTIONS + "\n" + objective
      prompt += "\n" + PIPELINE_FEEDBACK if name == "pipeline" && ENV["E2E_RESULT_DAG_PIPELINE_CORRECTION"] == "1"
      prompt
    end

    def expected(name, data)
      return { "c" => 7, "d" => 18 } if name == "dependencies"

      records = name == "empty" ? [] : data.fetch("records").select { |record| record.fetch("path").end_with?(".rb") }
      { "items" => records.map { |record| record.slice("path", "score") }.sort_by { |record| record.fetch("path") },
        "total" => records.sum { |record| record.fetch("score") } }
    end
  end
end
