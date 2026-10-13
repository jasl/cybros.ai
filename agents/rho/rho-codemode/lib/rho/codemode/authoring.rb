module Rho
  module Codemode
    class Authoring
      Declaration = Data.define(:name, :canonical, :input_schema)

      INSTRUCTIONS = <<~TEXT.freeze
        Write an ordinary JavaScript async function body, without Markdown fences.
        Parameters are immutable JSON in params. Call tools[name](arguments) to request
        a declared tool. For example, with read declared:
        const result = await tools.read({path: "README.md"}); text(result.output ?? "");
        Await the complete outcome envelope: is_error is a value,
        while a recorded bridge refusal rejects and exposes error.refusal.
        Use Promise.all for independent work. Promise.race does not cancel losers.
        Settle every operation before returning. text(string) selects final text;
        value(json) or a returned JSON value selects structured output; resource({uri,
        name, mimeType?}) selects a resource reference already authorized by its owner.
        Intermediate outcomes stay out of the final result unless explicitly selected.
        There is no filesystem, network, module loader, clock or randomness in this VM.
        nexus.model(input), nexus.ask(input), nexus.steps(input), nexus.replace(input),
        nexus.cancel(input), nexus.join(input) and nexus.background(input) request host
        operations. Their Promise has a readonly operation_key for referring to it.
        Use nexus.model({prompt, model?, tools?}) for model work and nexus.ask({prompt,
        options?, multi?}) for a question. nexus.steps(steps) atomically accepts public
        steps such as {tool:{name,input,key}} or {model:{prompt,key,after,results}}.
        Fan out with {parallel:[stepOrSequence,...]}; a sequence is an array of
        steps. It waits for all by default. To race, add until:"any"|k, optionally
        losers:"cancel"|"run_out" and key. A model's results:[key,...] includes
        outputs; after:[key,...] only waits. Read a race's key for its selected results.
        nexus.replace({operation_key,tasks,steps}) replaces only unstarted authored task
        keys. nexus.cancel({operation_key,tasks?}) requests settled cancellation.
        nexus.join({operations:[operation_key],until:"all"|"any"|number,losers?}) uses
        losers:"cancel" or "run_out". nexus.background({operation_key,lifetime?,wake?})
        explicitly transfers existing work; {steps,lifetime,wake} launches background
        steps. lifetime is "conversation" or "turn"; wake is "auto" or "passive".
      TEXT

      # Nexus declarations support flat functions and the nested Chat shape.
      # The route keeps a Runner's served identity separate from its callable
      # alias. Normalize once before exposing names and schemas to the interpreter.
      def self.catalog(tools:)
        tools.map do |tool|
          entry = tool.to_h.transform_keys(&:to_s)
          function = entry.fetch("function", entry)
          name = function.fetch("name")
          canonical = entry.dig("route", "tool_name") || entry.fetch("canonical", function.fetch("canonical", name))
          Declaration.new(name: name, canonical: canonical,
            input_schema: function.fetch("parameters", {}))
        end
      end
    end
  end
end
