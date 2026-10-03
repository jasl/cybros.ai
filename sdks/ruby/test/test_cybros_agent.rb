require "test_helper"

class TestCybrosAgent < Minitest::Test
  def test_that_it_has_a_version_number
    refute_nil ::CybrosAgent::VERSION
  end

  def test_the_gem_packages_the_validated_rbs_surface
    gemspec = Gem::Specification.load(File.expand_path("../cybros_agent.gemspec", __dir__))

    assert_includes gemspec.files, "sig/cybros_agent.rbs"
  end

  # A family prefix begins a token: every Cybros secret is scrubbed from
  # its first byte, and a task key whose bytes happen to carry `sk-`
  # mid-word (`r2t0-ask-1`, a model's ask) is diagnostic text, not a secret.
  def test_redaction_scrubs_a_secret_from_its_family_prefix_and_leaves_a_word_that_merely_contains_one
    %w[sk rt dc rc].each do |family|
      assert_equal "bearer [REDACTED] end", CybrosAgent::Redaction.call("bearer #{family}-cybros-api-v1-secret.value end")
      assert_equal "[REDACTED]", CybrosAgent::Redaction.call("#{family.upcase}-cybros-api-v1-SECRET")
      assert_equal "{\"token\":\"[REDACTED]\"}", CybrosAgent::Redaction.call("{\"token\":\"#{family}-cybros-api-v1-x\"}")
    end
    assert_equal "task=r2t0-ask-1 loop=al-1", CybrosAgent::Redaction.call("task=r2t0-ask-1 loop=al-1")
    assert_equal "a desk-1 and a chart-2", CybrosAgent::Redaction.call("a desk-1 and a chart-2")
  end

  # The key table (sec-6): credentials by name, the reader's handles spared.
  def test_the_key_table_names_credentials_and_spares_the_readers_keys
    %w[api_key X-Api-Key apiKey Authorization Cookie key access_token client_secret bearer].each do |name|
      assert_match CybrosAgent::Redaction::SECRET_KEY, name, name
    end
    %w[task_key call_key idempotency_key public_key keys task loop address].each do |name|
      refute_match CybrosAgent::Redaction::SECRET_KEY, name, name
    end
  end

  def test_the_httpx_floor_supports_the_absolute_deadline_hook
    gemspec = Gem::Specification.load(File.expand_path("../cybros_agent.gemspec", __dir__))
    dependency = gemspec.runtime_dependencies.find { |candidate| candidate.name == "httpx" }

    assert dependency.requirement.satisfied_by?(Gem::Version.new("1.8.1"))
    refute dependency.requirement.satisfied_by?(Gem::Version.new("1.8.0"))
  end
end
