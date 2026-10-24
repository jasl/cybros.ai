module E2E
  module Evals
    Expected = Data.define(:reach, :success, :conduct, :facts) do
      def initialize(reach:, success:, conduct: {}, facts: {})
        super(reach: reach, success: success, conduct: conduct.transform_keys(&:to_s).freeze,
          facts: facts.transform_keys(&:to_s).freeze)
      end

      def verdict(trace)
        return unread(trace) if reach.nil?

        reached = Expected.answer(reach, trace)
        succeeded = reached == true ? Expected.answer(success, trace) : nil
        checks = conduct.transform_values { |check| Expected.answer(check, trace) }
        Verdict.new(reached: reached == true, succeeded: (succeeded == true if !succeeded.nil?),
          reason: [reached, succeeded].find { |answer| answer in String }, conduct: checks,
          facts: facts.transform_values { |column| Expected.column(column, trace) })
      end

      # No reach dimension: the conduct and the columns are read, the two
      # predicate dimensions are not.
      def unread(trace)
        Verdict.new(reached: nil, succeeded: nil, reason: nil, conduct: conduct.transform_values { |check| Expected.answer(check, trace) },
          facts: facts.transform_values { |column| Expected.column(column, trace) })
      end

      # `true` is green; a String is the reason handed up in its place;
      # anything else is a predicate bug spelled out, never a silent pass.
      def self.answer(check, trace)
        value = check.call(trace)
        return value if value == true || (value in String)

        "the predicate answered #{value.inspect}, not true or a String"
      end

      # A column that raises is its error, spelled, never a lost record.
      def self.column(column, trace)
        column.call(trace)
      rescue StandardError => error
        "#{error.class}: #{error.message[0, 120]}"
      end
    end

    Verdict = Data.define(:reached, :succeeded, :reason, :conduct, :facts) do
      def initialize(reached:, succeeded:, reason:, conduct:, facts: {})
        super
      end

      def green? = reached && succeeded == true && conduct_ok?

      # THE WORK SURVIVED (the compactions-survived column): the predicate's
      # success where one was read, else the verification's pass — a family
      # with no reach dimension counts its compactions off task pass.
      def work_survived?(task_pass) = succeeded == true || (succeeded.nil? && task_pass == true)

      def conduct_ok? = conduct.values.all?(true)

      # `name => true|false` for the record; the Strings are the reasons.
      def conduct_facts = conduct.transform_values { |answer| answer == true }

      def conduct_reasons = conduct.reject { |_name, answer| answer == true }
    end
  end
end
