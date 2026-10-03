module E2E
  # THE LONG LANE'S ONE SCRIPTED HUMAN, DECIDING. Under `--approval ask` every runner call with an
  # effect parks for a person; `live_exit_long` answers each through rho's own verbs. It approves
  # everything except a shell read of the vector corpus: the index line needs the whole file, and
  # the only single call that certainly finds a marker at an unpredictable line is one bare `read` —
  # while a `head`/`tail` loop in bash hands over all 56 first-and-marker pairs in ONE park, so the
  # composed request never nears the wall the lane exists to cross. check.sh verifies the LINE, not
  # how it was produced; the person at the terminal is the one who can say "use the read tool" —
  # which is what the denial's reason says, in the tool result the model reads next.
  #
  # VERB-ANCHORED on purpose: only a reading verb followed on the same
  # line by a vector path is a bypass. The suite (`ruby -Ilib -Itest
  # test/all.rb`), the server (`ruby server/app.rb PORT`), an append to
  # VECTORS.md (`printf '…' >> VECTORS.md`), `ls spec/vectors` and
  # `sh check.sh` all pass — a pump that denied the port's own test run
  # would end the lane at its own hand. The read-only tools (`read`,
  # `ls`, `grep`, `find`) never park (rho's READ_ONLY_TOOLS rule), so
  # only `bash` and `start_process` — the two that carry a `command` —
  # are ever asked.
  module ExitLongPump
    GUARDED_TOOLS = %w[bash start_process].freeze
    VECTOR_BYPASS = %r{\b(?:head|tail|cat|grep|sed|awk|wc|cut|tac|less|more|xargs|find|for|while)\b[^\n]*(?:spec/vectors|vec-\d\d\.txt|vec-\*)}
    REASON = "read the vector files with the read tool, one file per call".freeze

    module_function

    def bypass?(tool_name, input)
      return false unless GUARDED_TOOLS.include?(tool_name)

      command = input.is_a?(Hash) ? input["command"] : nil
      command.is_a?(String) && VECTOR_BYPASS.match?(command)
    end
  end
end
