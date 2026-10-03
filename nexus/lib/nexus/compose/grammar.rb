module Nexus
  module Compose
    # The isomorphism law, executable: the step tree a script places is the
    # tree the append door reads. Compose's option set per verb is CLOSED;
    # the door's extra fields are the round's inherited surface, refused at the line.
    module Grammar
      VERBS = %w[tool model ask wait script parallel].freeze

      # What a built script carries on each verb. No step carries a WHEN
      # word: `wait` is on the compose CALL; the fan's join word is `until` —
      # how many successes end it. A race's `key` is the builder's to MINT,
      # never the script's to write — the name a later step's `after` or
      # `results` carries for it — so it is carried here and refused at the
      # line like any option the builder does not take.
      COMPOSE_OPTIONS = {
        "tool" => %w[name input key timeout_ms after].freeze,
        "model" => %w[prompt model tools instructions key after results].freeze,
        "ask" => %w[prompt options multi key timeout_ms after].freeze,
        "wait" => %w[task agent_loop key timeout_ms after].freeze,
        "script" => %w[script params key after results].freeze,
        "parallel" => %w[until key].freeze,
      }.freeze

      # What the door and the SDK may write beyond that: policies and the
      # request surface a branch inherits, a race's spend control, and the
      # per-step `detached` — the node column's word — a client authors for a
      # step the envelope does not wait for. A tool step has no `retry`. A
      # model step's `attachments` is the door's alone: the agent user holds
      # no uploads, so a script naming one is refused at the line. Per-step
      # lifetime and wake are also door-only; compose selects them on the whole call.
      DOOR_OPTIONS = {
        "tool" => %w[detached lifetime wake on_failure visibility].freeze,
        "model" => %w[detached configuration compaction fan_on_failure retry on_failure visibility attachments lifetime wake].freeze,
        "ask" => %w[detached lifetime wake on_failure visibility].freeze,
        "wait" => %w[detached lifetime wake on_failure visibility].freeze,
        "script" => %w[model_defaults detached lifetime wake on_failure visibility].freeze,
        "parallel" => %w[losers on_failure lifetime wake].freeze,
      }.freeze

      module_function

      def verbs = VERBS

      def compose_options(verb) = COMPOSE_OPTIONS.fetch(verb.to_s)

      def door_options(verb) = DOOR_OPTIONS.fetch(verb.to_s)

      # Every field the door reads for a verb, in one list.
      def fields_for(verb) = compose_options(verb) + door_options(verb)
    end
  end
end
