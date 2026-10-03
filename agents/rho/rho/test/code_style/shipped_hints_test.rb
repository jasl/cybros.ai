require "test_helper"

# THE SHIPPED-HINT LAW: every verb a shipped line
# names is a verb the shipped product has. A product install carries the
# management verbs, `run`, and the verbs of the default extensions — the
# thirty-seven of rho-dev (`do`, `say`, `watch`, `retry`, …) are a
# development gem's, loaded only where a home names `rho/dev` — so a
# refusal, a hint or a description under `lib` + `exe` that says
# "`rho watch` follows it" would name a verb the reader cannot type. The
# law is mechanical: every non-comment `` `rho <word>` `` literal names a
# verb `exe/rho` or a `DEFAULT_EXTENSIONS` member registers (aliases
# counted), and no shipped literal names a rho-dev verb at all, backticked
# or bare. A line that needs the capability names it ("attach it first",
# "stop it first"); rho-dev's own renderers name its verbs.
class ShippedHintsTest < Minitest::Test
  LIB = File.expand_path("../../lib/rho", __dir__)
  EXE = File.expand_path("../../exe/rho", __dir__)

  # `exe/rho`'s own verbs, Thor's `help` among them.
  CORE_VERBS = %w[version doctor update uninstall connect disconnect status server run help].freeze
  # rho-dev's verbs (`agents/rho/rho-dev`): the thirty-three of the old
  # Ops set and the four that left the core.
  DEV_VERBS = %w[
    loops providers watch result pause resume answer follow transcript task relay fetch graph request prompt
    append phases attach retry abandon compact approve deny rules delete btw side inputs skills rewind
    regenerate variant activate conversation do say stop adaptations
  ].freeze

  BACKTICKED = /`rho ([a-z][a-z_-]*)/
  BARE_DEV = /\brho (#{DEV_VERBS.join("|")})\b/

  # The verbs a product home lists: `exe/rho`'s and every default
  # extension's, with the aliases, read off the loader the way the binary
  # reads them (`serving_tools: false`: this process learns the verbs and
  # serves nothing).
  def shipped_verbs
    host = Rho::Extensions::Host.new(
      home: Rho::Home.resolve(base_url: "https://nexus.example", root: File.join(Dir.tmpdir, "rho-shipped-hints")),
      log: nil, clock: -> { Time.now }, config: Rho::Config.from_hash({}), processes: nil, serving_tools: false
    )
    loaded = Rho::Extensions.load(host: host)
    assert_predicate loaded, :ok?, loaded.failures.inspect
    (CORE_VERBS + loaded.commands.flat_map { |command| [command.name, *command.aliases] }).uniq
  end

  def files = Dir.glob(File.join(LIB, "**", "*.rb")).sort + [EXE]

  # Source lines with the comment stripped (an interpolation's `#{` is
  # not a comment, so a hint after one on the same line is still read):
  # a law about code, not prose.
  def code_lines(path)
    File.read(path, encoding: "UTF-8").lines.map.with_index(1) do |line, number|
      [number, line.chomp.sub(/(?<!["'\\])#(?!\{).*\z/, "")]
    end
  end

  def test_every_shipped_backticked_verb_is_a_verb_the_product_has
    verbs = shipped_verbs
    refute_includes verbs, "watch", "rho-dev's verbs are not the product's"
    offenders = files.flat_map do |path|
      code_lines(path).flat_map do |number, code|
        code.scan(BACKTICKED).flatten.reject { |word| verbs.include?(word) }
            .map { |word| "#{path.delete_prefix("#{LIB}/")}:#{number} `rho #{word}`" }
      end
    end
    assert_empty offenders, "a shipped line names a verb the product does not have"
  end

  def test_no_shipped_line_names_a_rho_dev_verb_bare_or_backticked
    offenders = files.flat_map do |path|
      code_lines(path).flat_map do |number, code|
        code.scan(BARE_DEV).flatten.map { |word| "#{path.delete_prefix("#{LIB}/")}:#{number} rho #{word}" }
      end
    end
    assert_empty offenders, "a shipped line names a rho-dev verb; name the capability instead"
  end
end
