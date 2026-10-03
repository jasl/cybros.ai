require_relative "records"

module E2E
  module Screen
    # THE PER-CELL COUNTS OF A BATCH: one row per (arm, instrument, model, objective) carrying counts
    # and summed spend, and never a script's bytes — the form a readout promotes, so a later screen
    # prices its cells and reads its per-cell base rates from tracked counts, not from the scratch
    # the records sat in.
    module Cells
      KEY = %w[arm instrument model objective].freeze
      # What each instrument's cell counts, by the record's own facts. `right` is the static reading:
      # first-time-right on a plan whose expansion could be read — an opaque plan is scored on its
      # visible steps and counts as not right. `rehearsed_right` (right″) is the rehearsed one: the
      # valid first script's plan right in every world it was rehearsed in, uncredited, with no
      # closing value dropped on a race member; a refused script has no rehearsal and is not right″.
      # A task draw's door is its scored message's kind (`door_kind`): `acceptable_door` the door
      # objective's own fact (a `task` fan as wide as the fan it asks for), `compose_flat` a compose
      # whose model leaves go unread, `built` a compose script the builder built.
      COUNTS = {
        "compose" => {
          "reached" => ->(draw) { draw["reached"] == true },
          "valid_first" => ->(draw) { draw["valid_first"] == true },
          "first_time_right" => ->(draw) { draw["first_time_right"] == true },
          "right" => ->(draw) { draw["first_time_right"] == true && draw["opaque"] != true },
          "rehearsed_right" => lambda do |draw|
            draw["valid_first"] == true && draw.dig("rehearsed", "first_time_right") == true &&
              draw.dig("rehearsed", "dropped_value_on_race_member") == 0
          end,
          "opaque" => ->(draw) { draw["opaque"] == true },
          "usable" => ->(draw) { draw["usable"] == true },
          "expanded_right" => ->(draw) { draw.dig("expanded", "first_time_right") == true },
          "valid_after_repair" => ->(draw) { draw["valid_after_repair"] == true },
        },
        "task" => {
          "pass" => ->(draw) { draw["pass"] == true },
          "right_door" => ->(draw) { draw["right_door"] == true },
          "scout" => ->(draw) { draw["scout"] == true },
          "scout_then_door" => ->(draw) { draw["scout_then_door"] == true },
          "acceptable_door" => ->(draw) { draw["acceptable_door"] == true },
          "compose_flat" => ->(draw) { draw["door_kind"] == "compose_flat" },
          "built" => ->(draw) { draw["built"] == true },
        },
      }.freeze

      module_function

      def extract(draws)
        draws.group_by { |draw| draw.values_at(*KEY) }.sort_by { |key, _| key.map(&:to_s) }.map do |key, cell|
          instrument = key[1]
          KEY.zip(key).to_h
            .merge("draws" => cell.length, "lost" => cell.count { |draw| Records.lost?(draw) }, "no_call" => no_calls(instrument, cell))
            .merge(COUNTS.fetch(instrument).transform_values { |test| cell.count(&test) })
            .merge("calls" => cell.sum { |draw| Records.calls(draw) }, "retries" => cell.sum { |draw| Records.retries(draw) })
            .merge(spend(cell))
            .merge("seconds" => cell.sum { |draw| Records.seconds(draw) }.round(3))
        end
      end

      # A compose draw that reached no compose call and lost no call: the model answered otherwise.
      # A task draw always has its messages' calls to read, so it has no such count.
      def no_calls(instrument, cell)
        case instrument
        when "compose" then cell.count { |draw| draw["reached"] != true && !Records.lost?(draw) }
        when "task" then 0
        else raise ArgumentError, "no instrument #{instrument.inspect}"
        end
      end

      # The cell's tokens per class and the provider-reported charge, summed over every call.
      def spend(cell)
        usages = cell.flat_map { |draw| Records.usages(draw) }
        Records::TOKENS.to_h { |name| [name, usages.sum { |usage| usage[name].to_i }] }
          .merge("cost" => usages.sum { |usage| usage["cost"].to_f }.round(6))
      end

      private_class_method :no_calls, :spend
    end
  end
end
