require "test_helper"

# THE RECORD'S TWO SPELLINGS ARE PINNED ONCE: nothing reserves `rho.environment`/`binding` kernel-side, so rho
# pins them in exactly one constant pair — `Extensions::Environment::
# STORE_NAMESPACE`/`STORE_KEY` — and every reader and writer names the
# constants, never the strings. And rho announces its boot instant in the
# environment document: the key a host elsewhere re-asserts on.
class EnvironmentRecordTest < Minitest::Test
  LIB = File.expand_path("../../lib", __dir__)

  def code_lines(path)
    File.read(path, encoding: "UTF-8").lines.map { |line| line.chomp.sub(/(?<!["'\\])#.*\z/, "") }
  end

  def occurrences(pattern)
    Dir.glob(File.join(LIB, "**", "*.rb")).sort.flat_map do |path|
      code_lines(path).each_with_index.filter_map { |code, index| "#{path}:#{index + 1}" if code.match?(pattern) }
    end
  end

  def test_the_namespace_and_the_key_are_spelled_in_one_constant_pair
    assert_equal "rho.environment", Rho::Extensions::Environment::STORE_NAMESPACE
    assert_equal "binding", Rho::Extensions::Environment::STORE_KEY
    assert_equal Rho::Extensions::Environment::NAME, Rho::Extensions::Environment::STORE_NAMESPACE,
      "the extension's NAME is the namespace, as HostStore notes are keyed"
    assert_equal 1, occurrences(/"rho\.environment"/).length, occurrences(/"rho\.environment"/).inspect
    assert_equal 1, occurrences(/"binding"/).length, occurrences(/"binding"/).inspect
    assert_equal 1, occurrences(/STORE_NAMESPACE\s*=/).length
    assert_equal 1, occurrences(/STORE_KEY\s*=/).length
  end

  def test_rho_announces_its_boot_instant_in_the_environment_document
    registry = Rho::Runner::Extensions::Loader.call(builtin: [Rho::Runner::Extensions::Coding]).registry
    environment = Rho::Runner::Environment.local(root: Dir.tmpdir)

    document = Rho::RunDeclaration.environment_document(registry: registry, environment: environment,
      booted_at: "2026-09-17T08:00:00Z")

    assert_equal "2026-09-17T08:00:00Z", document.fetch("booted_at")
    refute Rho::RunDeclaration.environment_document(registry: registry, environment: environment).key?("booted_at"),
      "a document with no boot announces none: TreeSync reads an unannounced field as unknown"
    assert_match(/booted_at/, File.read(File.join(LIB, "rho", "daemon", "executor_plane.rb"), encoding: "UTF-8"),
      "the executor plane announces it")
  end
end
