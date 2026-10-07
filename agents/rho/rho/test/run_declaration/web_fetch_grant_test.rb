require "test_helper"

class RunDeclarationWebFetchGrantTest < Minitest::Test
  Grant = Rho::RunDeclaration::Grant
  INVALID_URL = "the held url must be an HTTP(S) URL with a host, no credentials and no wildcards in its authority".freeze
  INVALID_SITE = "--match for web_fetch must equal the held URL's site, with an optional trailing / and no path, query or fragment".freeze

  def rule(url, match: nil)
    Grant.rule(tool_name: "web_fetch", tool_input: { "url" => url }, match: match)
  end

  # A model controls the held URL. The person's approval must grant its
  # literal site prefix, never turn the host or a query into a broader glob.
  def test_a_site_grant_uses_one_literal_authority_prefix_without_the_path_or_query
    result = rule("https://docs.example.test/guide?q=*#section")

    assert_equal({ "tool" => "web_fetch", "path" => "url", "match" => "https://docs.example.test/*",
                   "verdict" => "allow" }, result)
    assert_predicate result, :frozen?
  end

  def test_scheme_host_and_explicit_port_spelling_are_not_normalized
    {
      "HTTPS://docs.example.test:0443/guide" => "HTTPS://docs.example.test:0443/*",
      "https://docs.example.test:443/guide" => "https://docs.example.test:443/*",
      "https://docs.example.test:/guide" => "https://docs.example.test:/*",
      "https://www.docs.example.test/guide" => "https://www.docs.example.test/*",
      "http://[2001:db8::1]:8080/guide" => "http://[2001:db8::1]:8080/*",
    }.each do |url, expected|
      assert_equal expected, rule(url).fetch("match"), url
    end
  end

  def test_a_held_bare_root_or_root_query_still_derives_the_slash_bounded_prefix
    %w[https://docs.example.test https://docs.example.test?query=* https://docs.example.test#top].each do |url|
      assert_equal "https://docs.example.test/*", rule(url).fetch("match"), url
    end
  end

  def test_match_can_name_only_the_same_literal_site_with_an_optional_slash
    url = "HTTPS://docs.example.test:0443/guide?q=*"
    %w[HTTPS://docs.example.test:0443 HTTPS://docs.example.test:0443/].each do |site|
      assert_equal rule(url), rule(url, match: site)
    end

    %w[
      https://docs.example.test:0443 https://docs.example.test https://docs.example.test:443
      http://docs.example.test:0443 HTTPS://www.docs.example.test:0443
      HTTPS://docs.example.test:0443.evil.test HTTPS://other.example.test:0443
      HTTPS://docs.example.test:0443/guide HTTPS://docs.example.test:0443?query=1
      HTTPS://docs.example.test:0443/#top HTTPS://docs.example.test:0443/*
    ].each do |site|
      assert_equal INVALID_SITE, rule(url, match: site).message, site
    end
    assert_equal INVALID_SITE, rule(url, match: "").message
  end

  def test_urls_that_cannot_make_a_literal_http_authority_are_refused
    [
      "not a URL", "ftp://docs.example.test/", "https:guide", "https:///guide",
      "https://secret-user:secret-password@docs.example.test/guide",
      "https://docs*.example.test/guide", "https://docs.example.test:abc/guide",
      "https://docs.example.test/a b", "https://docs.example.test/Köln",
    ].each do |url|
      result = rule(url)
      assert_kind_of Grant::Refusal, result, url
      assert_equal INVALID_URL, result.message, url
    end
  end

  def test_a_site_grant_preserves_the_existing_held_text_guards
    [nil, [], 3, "", " \n"].each do |url|
      assert_equal "the held call carries no url text to key a grant on", rule(url).message
    end
    result = Grant.rule(tool_name: "web_fetch", tool_input: nil)
    assert_equal "the held call carries no url text to key a grant on", result.message

    result = rule("https://docs.example.test/\xFF".dup.force_encoding(Encoding::UTF_8))
    assert_equal "the held url is not valid UTF-8 text; the kernel would refuse the whole rule list (glob_invalid)",
      result.message
  end
end
