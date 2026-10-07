require_relative "trace"

module E2E
  module Evals
    # THE DRAWING VOCABULARY for a predicate's unit test: the route's
    # node `{key, kind, status, visibility, deliverable, input_from?,
    # result_from?, mainline?, error_key?, join?, expansion_parent?}`, edge
    # `{from, to}`, the loop row's task rows joined with
    # `tool_input`, the feed's items as `{type, payload}` —
    # `gallery_shapes_test.rb`'s helpers (`:102-121`), moved into support
    # so every task's green/red pair draws with one vocabulary (that test
    # keeps its own copy: a residue line, untouched by this slice).
    module Drawing
      module_function

      # `mainline` rides rounds alone (the kernel's mark): a drawn round is the mainline's unless drawn
      # `mainline: false` — a delegated member's continuation, a summarizer `kN`, a branch's own round.
      # `expansion_parent` is the node that placed it, `input_from` and `result_from` what a model
      # step reads, each carried only when drawn.
      def n(key, kind, status: "completed", deliverable: false, error_key: nil, join: nil, mainline: (kind == "model_task" || nil),
            expansion_parent: nil, input_from: nil, result_from: nil)
        { "key" => key, "kind" => kind, "status" => status, "visibility" => "visible", "deliverable" => deliverable,
          "input_from" => input_from, "result_from" => result_from, "mainline" => mainline, "error_key" => error_key,
          "join" => join, "expansion_parent" => expansion_parent }.compact
      end

      def graph(nodes, edges)
        { "nodes" => nodes, "edges" => edges.map { |from, to| { "from" => from, "to" => to } }, "mermaid" => "flowchart TD" }
      end

      def tool(key, name, after: nil, input: {}, status: "completed")
        { "key" => key, "kind" => "tool_task", "status" => status, "tool_name" => name, "after" => after, "tool_input" => input }.compact
      end

      # A round's row as the trace serves it: the refusal rides `error`
      # ({key, detail}), which the graph node carries as `error_key` alone;
      # `usage` is the round's receipt off the transcript read (measured-2);
      # `model` the row's current model (`{model}`), `result` its summary
      # (`finish_quality`, `refusal_category`, `model_change`) — each carried
      # only when drawn.
      def round(key, status: "completed", error: nil, usage: nil, model: nil, result: nil)
        { "key" => key, "kind" => "model_task", "status" => status, "model" => (model && { "model" => model }),
          "result" => result, "error" => error, "usage" => usage }.compact
      end

      def event(type, payload) = { "type" => type, "payload" => payload }

      # The rounds every drawn graph implies, as task rows, so a trace's
      # counts read off the drawing without a second list.
      def rounds_of(graph)
        Array(graph["nodes"]).select { |node| node["kind"] == "model_task" }
          .map { |node| round(node["key"], status: node["status"]) }
      end

      # `loops` names every loop the run backed (the primary first); the
      # one-loop default takes `status`.
      def trace(graph, tasks, events, facts: {}, status: "completed", spend: nil, loops: nil)
        rows = tasks + rounds_of(graph).reject { |row| tasks.any? { |t| t["key"] == row["key"] } }
        Trace.draw(graph, rows, events, facts: facts, spend: spend,
          loops: loops || [{ "id" => "loop-1", "status" => status }])
      end

      # A drawn RECORD, in the lane's shape (`EvalsLaneTest#build_record`),
      # for the scorecard's and the ledger's unit tests: green by default,
      # any key overridden whole.
      def record(task: "shape-linear", family: "shape", model: "fixture/strong", style: "nexus", run: 1,
                 reached: true, succeeded: true, task_pass: true, driver: "plain", bench_digest: "d" * 64, **rest)
        {
          "task" => task, "family" => family, "capability" => "rho.coding", "driver" => driver,
          "model" => model, "style" => style, "run" => run, "bench_digest" => bench_digest,
          "adaptations" => { "row" => "bench-#{style}", "source" => "local", "tool_style" => style.split("+") },
          "started_at" => "2026-09-10T00:00:00Z", "seconds" => 60, "loops" => [{ "id" => "loop-1", "status" => "completed" }],
          "verdict" => { "reached" => reached, "succeeded" => succeeded, "task_pass" => task_pass, "class" => nil },
          "reason" => nil, "facts" => { "round_errors" => {}, "attention_reasons" => {}, "rounds_settled" => 3 },
          "efficiency" => { "rounds" => 3, "calls" => 2, "cost_amount" => 0.01, "cost_unit" => "USD",
                            "compactions" => {}, "compactions_survived" => 0 },
          "conduct" => {}, "stopped" => nil, "artifact" => "artifacts/evals/x/#{task}.json",
        }.merge(rest.transform_keys(&:to_s))
      end
    end
  end
end
