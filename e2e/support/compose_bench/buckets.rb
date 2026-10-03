require_relative "../../../nexus/lib/nexus/compose/evaluator"

module E2E
  module ComposeBench
    # FAILURES GROUPED BY ERROR STRING FIRST (the 2026-08-30 rule): an error every tier shares is
    # ours, not the model's. The loud buckets are the design's scorer columns plus the harness's own
    # lowering refusal for a tool name the round never declared.
    module Buckets
      # The kernel's repair sentences come first: a tool's `results:` refusal also says "is not an
      # option", and its own bucket is the repair, not the deleted word.
      LOUD = [
        ["after_in_input", /goes beside input, not inside it/],
        ["tool_reads", /a tool reads nothing/],
        ["member_order", /listed after it; list a step after the steps it/],
        ["stage_end", /A g\.script stage must end with ONE step/],
        # The evaluator refuses a script whole, in its own words, when it built nothing the kernel can
        # run: a step placed after the script returned, or no step at all.
        ["deferred", /#{Regexp.escape(Nexus::Compose::Evaluator::DEFERRED)}/],
        ["no_step", /#{Regexp.escape(Nexus::Compose::Evaluator::NO_STEP)}/],
        # A reference names one step: a race by its handle in a list, never the list itself, never
        # an "all" group, never a chain a g.parallel returned, never a list nested in the list,
        # never a value. A chain is its own defect: the nested list's repair would tell the author
        # to write what they wrote.
        ["race_member", /a member of (?:the race on line \d+|an earlier race); a race stops the members it did not select/],
        ["race_unwrapped", /takes a list; write (?:after|results): \[race\] to name the race/],
        ["group_reference", /names an "all" group, which is not one step/],
        ["chain_reference", /an entry is a chain \[a, b\], not a step/],
        ["nested_list", /nests a list; write (?:after|results): runs/],
        ["reference_value", /accepts leaf handles and races, not result values or string keys/],
        ["unknown_option", /unknown option/],
        ["edge_word", /is not an option\. A step reads only what you hand it/],
        ["deleted_word", /is not an option|is not a compose option/],
        ["handle_throw", /is not known while the script runs/],
        ["not_a_verb", /is not a compose verb/],
        ["g_join", /g\.join is not a builder/],
        ["tool_name", /is not one of your tools/],
        ["is_not_defined", /is not defined/],
        ["member_not_a_step", /every member must be a step built for this group/],
        ["group_in_group", /cannot be a member of another/],
        ["one_object", /takes one object/],
        ["syntax", /\ASyntaxError|script_syntax_error/],
        ["determinism", /is unavailable: a compose script must build the same/],
        # What the step compiler refuses of the steps a script built, whose sentence names no
        # repair: each under its own code (`Shape.lowering_refusal`). The evaluator refuses a whole
        # script by two of the same words, which mean the same there.
        *%w[
          too_many_steps steps_payload_too_large invalid_task_key invalid_tool_input tool_input_too_large invalid_prompt
          invalid_ask_options invalid_instructions script_required script_too_large invalid_script invalid_script_params
        ].map { |code| [code, /\A#{code}:/] },
      ].freeze

      module_function

      def loud(refusal, detail)
        text = "#{refusal}: #{engine_text(detail)}"
        LOUD.find { |_, pattern| text.match?(pattern) }&.first || "other"
      end

      # The string a group is keyed by: quoted names, keys and numbers
      # collapsed, so `unknown option "command"` and `unknown option
      # "cmd"` land in one line and the table reads as a defect list.
      def normalize(detail)
        engine_text(detail)
          .gsub(/"[^"]*"/, "\"…\"")
          .gsub(/\b(?:tool|model|ask|parallel)-\d+\b/, "step-n")
          .gsub(/\d+/, "n")[0, 160]
      end

      # The refusal's own words. A syntax refusal's position is cut: after
      # " at line " comes the model's own source line, which would make every
      # refusal its own group, and whose text could name an earlier bucket.
      def engine_text(detail) = detail.to_s.lines.first.to_s.strip.partition(" at line ").first
      private_class_method :engine_text
    end
  end
end
