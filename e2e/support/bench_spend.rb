require "bigdecimal"
require "json"
require "tempfile"
require_relative "../../nexus/app/services/usage_records/pricing"
require_relative "../../nexus/app/services/usage_records/tokens"
require_relative "manual_client"
require_relative "process_runner"

module E2E
  # A SCREEN'S MONEY, PRICED THE WAY THE RECEIPT PRICES IT. Each lane's schedule is the kernel's own
  # projection, derived once per launch inside the tree's Nexus (`derive`, by `rates_runner.rb`)
  # and stamped in the screen's home as `rates.json`; each recorded call is priced by the
  # receipt's own settlement (`UsageRecords::Pricing.amount`): the provider's reported bill under
  # its contract, else the catalog formula over the counts `ManualClient` recorded. Nothing here
  # reads the catalog's YAML or restates a rate, a class or a rule — a watch's spend stop and a
  # readout's cost table read one price.
  module BenchSpend
    # The unit every screen states its money in: its stop, its planning figures, its readout.
    UNIT = "USD"
    RATES_FILE = "rates.json"
    RUNNER = File.expand_path("bench_spend/rates_runner.rb", __dir__)
    # A Rails boot and a catalog compile, nothing more.
    TIMEOUT_SECONDS = 120
    ZERO = BigDecimal(0)
    # Every class the receipt's reader knows, none reported: a recorded call fills the classes it
    # carries under the same names and the rest stay absent.
    UNREPORTED = UsageRecords::Tokens.read({}, adapter_profile: "").freeze

    # One lane's stamped schedule: its wire, the projection's state, whether settlement would write
    # money for it, its unit and source policy, the rates and served-tier factors as exact
    # BigDecimals, and the native cost contract.
    Schedule = Data.define(:adapter_profile, :state, :reason, :settles_money, :account_unit, :source_policy, :rates,
      :tier_multipliers, :native_cost_contract) do
      def self.from_h(hash)
        row = hash.to_h.transform_keys(&:to_sym)
        new(**row.merge(rates: exact(row.fetch(:rates)), tier_multipliers: exact(row.fetch(:tier_multipliers))))
      end

      def self.exact(values) = values.to_h.transform_values { |value| BigDecimal(value) }.freeze
    end

    module_function

    # THE TREE'S OWN KERNEL PROJECTS EACH LANE: `bin/rails runner` inside `root`'s Nexus, under its
    # own bundle, answers each ref's schedule as settlement would read it; a ref the catalog does
    # not name stops the derivation by name, and so does each lane `stampable` refuses. Returns the
    # document `write` stamps.
    def derive(root:, models:, account_unit: UNIT)
      stampable(project(root, models, account_unit), account_unit: account_unit)
    end

    # THE STAMP'S TWO REFUSALS, each by lane, before a call is paid: a lane settlement would write
    # no money for in `account_unit` — a spend stop would read it as free — and a lane whose
    # provider bills in a field no recorded call carries (`ManualClient::BILLS`) — the bench would
    # price it by the formula while its receipt reads the bill. Returns the document.
    def stampable(document, account_unit: UNIT)
      unpriced = document.reject { |_ref, row| row.fetch("settles_money") }
      unless unpriced.empty?
        named = unpriced.map { |ref, row| "#{ref} is #{row.fetch("state")} (#{row.fetch("reason")})" }
        raise "a screen prices every lane it pays for in #{account_unit}: #{named.join("; ")}"
      end

      unread = document.filter_map do |ref, row|
        field = row.dig("native_cost_contract", "amount_field")
        "#{ref} bills in #{field}" unless field.nil? || ManualClient::BILLS.include?(field)
      end
      unless unread.empty?
        raise "a screen prices a lane by the bill its receipt reads, and no recorded call carries it: #{unread.join("; ")}"
      end

      document
    end

    def write(home, document) = File.write(File.join(home, RATES_FILE), "#{JSON.pretty_generate(document)}\n")

    # The stamped schedules, by model ref.
    def rates(home)
      JSON.parse(File.read(File.join(home, RATES_FILE))).transform_values { |row| Schedule.from_h(row) }.freeze
    end

    # ONE RECORDED CALL'S PRICE: its `usage` as `ManualClient.facts` recorded it, nil when the call
    # raised, settled by the receipt's one precedence (`Pricing.amount`) — the provider's own bill
    # under the lane's contract and its rules (the unit, the broker's BYOK evidence), else the
    # formula over the recorded classes at the served tier. The recorded input is the receipt's
    # normalized, cache-inclusive count, so the cache classes subtract from it and a folded
    # Anthropic input is never charged twice. A call that reported no count adds nothing: its
    # price is unknowable here.
    def price(usage, schedule)
      spent = usage.to_h
      UsageRecords::Pricing.amount(
        usage: exact_cost(spent), contract: schedule.native_cost_contract,
        account_unit: schedule.account_unit, adapter_profile: schedule.adapter_profile,
        tokens: counts(spent), rates: schedule.rates, tier_multipliers: schedule.tier_multipliers
      ) || ZERO
    end

    # ONE DRAW'S PRICE: every call it paid for on its lane's stamped schedule — a task draw's
    # messages, a compose draw's first call and its repair. A lane the stamp never priced raises.
    def record(record, schedules)
      schedule = schedules.fetch(record.fetch("model"))
      paid_calls(record).sum(ZERO) { |usage| price(usage, schedule) }
    end

    # A SCREEN HOME'S ONE PRICE — the smoke's, the watch's spend stop and the readout's cost table:
    # each draw on the schedules stamped in `home`, read when the first draw asks, since a launch
    # builds its pricer before Stage 0 has derived them.
    def pricer(home)
      schedules = nil
      ->(draw) { record(draw, schedules ||= rates(home)) }
    end

    # A task draw's calls are its messages, whatever it copies beside them; a compose draw made one
    # call and, when refused, a repair.
    def paid_calls(record)
      messages = record["messages"]
      messages.nil? ? [record["usage"], record["repaired_usage"]] : messages.map { |message| message["usage"] }
    end
    private_class_method :paid_calls

    # The recorded counts under the receipt reader's names, each through the one boundary a count
    # crosses (`Tokens.wire_count`) — a record is read back from disk.
    def counts(spent)
      UNREPORTED.to_h { |key, _| [key, UsageRecords::Tokens.wire_count(spent[key.to_s])] }
    end
    private_class_method :counts

    # `ManualClient` records the broker's `cost` as a Float, and a small one prints in exponent
    # form; the contract decodes the plain decimal the wire wrote, so it is spelled back exactly.
    def exact_cost(spent)
      cost = spent["cost"]
      cost.nil? ? spent : spent.merge("cost" => BigDecimal(cost.to_s).to_s("F"))
    end
    private_class_method :exact_cost

    # The runner's one JSON line from stdout; on a failure, the head of its stderr, where the
    # exception names what stopped it.
    def project(root, models, account_unit)
      nexus = File.join(root, "nexus")
      input = JSON.generate({ "account_unit" => account_unit, "models" => models })
      Tempfile.create("bench-rates") do |out|
        Tempfile.create("bench-rates-err") do |err|
          status = ProcessRunner.run(File.join(nexus, "bin", "rails"), "runner", RUNNER, env: runner_env(nexus), chdir: nexus,
            stdin: input, out: out, err: err, timeout: TIMEOUT_SECONDS)
          unless status.success?
            raise "the rates runner failed with status #{status.exitstatus.inspect}:\n#{File.read(err.path, encoding: "UTF-8")[0, 600]}"
          end

          JSON.parse(File.read(out.path, encoding: "UTF-8").lines.reverse.find { |line| line.start_with?("{") })
        end
      end
    end
    private_class_method :project

    # The tree's own bundle and the test environment, every inherited bundler and Ruby loader
    # variable stripped; the shipped catalog alone, never an overlay this process was handed.
    def runner_env(nexus)
      ENV.keys.grep(/\ABUNDLE|\ARUBY(?:OPT|LIB)\z/).to_h { |key| [key, nil] }
        .merge("BUNDLE_GEMFILE" => File.join(nexus, "Gemfile"), "RAILS_ENV" => "test", "MODEL_CATALOG_OVERRIDE_DIR" => nil)
    end
    private_class_method :runner_env
  end
end
