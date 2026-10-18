require "test_helper"
require "json"
require "rho/version"

# THE REGISTRY ENTRY AS A FILE (the file kept in the tree,
# the submission not made): `registry/rho/agent.json` in the registry repo's own layout
# (`<id>/agent.json`, so a submission is a copy of the directory) — the entry harbor's
# `registry_entry_path` and a hand-placed editor entry read TODAY — against the
# registry's draft-07 schema: `id` `^[a-z][a-z0-9-]*$`, `name`, `version` X.Y.Z (rho's
# own: the gem is rho-acp, the agent is rho), `description`, `license_url`, and a
# non-empty `distribution` — here the `local` one harbor reads (the public schema admits
# binary/npx/uvx only, each a public package; `distribution` is the one edit when one
# exists).
class RegistryEntryTest < Minitest::Test
  ENTRY = File.join(RhoAcpTest::ROOT, "registry", "rho", "agent.json")
  ID = /\A[a-z][a-z0-9-]*\z/
  SEMVER = /\A\d+\.\d+\.\d+\z/
  REQUIRED = %w[id name version description distribution license_url].freeze

  def text = @text ||= File.read(ENTRY, encoding: Encoding::UTF_8)
  def entry = @entry ||= JSON.parse(text)

  def test_the_file_parses_with_the_registrys_required_keys_and_the_agents_id
    REQUIRED.each { |key| assert entry.key?(key), "#{key} is required by the registry's schema" }
    assert_match ID, entry["id"]
    assert_equal %w[rho rho], entry.values_at("id", "name")
    assert_equal ["jasl"], entry["authors"]
    assert_equal "MIT", entry["license"]
  end

  def test_the_version_is_rhos_own
    assert_match SEMVER, entry["version"]
    assert_equal Rho::VERSION, entry["version"], "the gem is rho-acp; the agent is rho"
  end

  def test_the_distribution_is_the_local_one_harbor_reads
    refute_empty entry["distribution"]
    assert_equal ["local"], entry["distribution"].keys, "no public package: no binary, npx or uvx"
    assert_equal({ "cmd" => "rho-acp", "args" => [] }, entry.dig("distribution", "local"))
  end

  def test_the_file_is_pretty_json_with_a_trailing_newline
    assert_equal "#{JSON.pretty_generate(entry)}\n", text
  end
end
