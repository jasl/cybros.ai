require "test_helper"

# THE SESSION-SCOPED APPROVAL GRANT'S DERIVATION: ONE pure function from the held
# call — its tool and the text argument the tool is guarded by — to ONE
# allow rule in the kernel's grammar: a
# text-keyed tool (`bash`/`start_process` on `command`, `write`/`edit` on
# `path`) keyed on the RAW text byte for byte, or a word-bounded prefix
# under `match:`; web_fetch's site shape has its own tests, and every
# other tool is granted whole. The five text-key refusal
# sentences are the route's 400s, pinned here byte for byte.
class RunDeclarationGrantTest < Minitest::Test
  Grant = Rho::RunDeclaration::Grant

  def rule(tool, input, match: nil) = Grant.rule(tool_name: tool, tool_input: input, match: match)

  # ---- the exact shape ----

  def test_a_text_keyed_tool_is_keyed_on_its_raw_text_exactly
    assert_equal({ "tool" => "bash", "path" => "command", "match" => "npm test", "verdict" => "allow" },
      rule("bash", { "command" => "npm test" }))
    assert_equal({ "tool" => "start_process", "path" => "command", "match" => "npm run dev", "verdict" => "allow" },
      rule("start_process", { "command" => "npm run dev" }))
    assert_equal({ "tool" => "write", "path" => "path", "match" => "/Users/me/project/notes.md", "verdict" => "allow" },
      rule("write", { "path" => "/Users/me/project/notes.md", "content" => "x" }))
    assert_equal({ "tool" => "edit", "path" => "path", "match" => "src/a.rb", "verdict" => "allow" },
      rule("edit", { "path" => "src/a.rb", "edits" => [] }))
    assert_predicate rule("bash", { "command" => "npm test" }), :frozen?
  end

  # THE RAW BYTES (S28): a trailing newline, a tab, a re-quoted argument
  # are different text — the grant is what the model sent, byte for byte;
  # no canonicalization, no whitespace normalization.
  def test_the_exact_grant_keeps_every_byte
    assert_equal "npm test\n", rule("bash", { "command" => "npm test\n" }).fetch("match")
    assert_equal "npm\ttest", rule("bash", { "command" => "npm\ttest" }).fetch("match")
    assert_equal "npm \"test\"", rule("bash", { "command" => "npm \"test\"" }).fetch("match")
    assert_equal "  npm test", rule("bash", { "command" => "  npm test" }).fetch("match")
  end

  # ---- the prefix shape ----

  def test_a_prefix_grant_is_word_bounded_on_the_keys_own_separator
    assert_equal({ "tool" => "bash", "path" => "command", "match" => "npm *", "verdict" => "allow" },
      rule("bash", { "command" => "npm test" }, match: "npm"))
    assert_equal "npm run *", rule("bash", { "command" => "npm run dev" }, match: "npm run").fetch("match")
    assert_equal({ "tool" => "write", "path" => "path", "match" => "/Users/me/project/*", "verdict" => "allow" },
      rule("write", { "path" => "/Users/me/project/notes.md" }, match: "/Users/me/project"))
    assert_equal "/d/*", rule("edit", { "path" => "/d/x.rb" }, match: "/d").fetch("match")
    # A PREFIX that ends with the separator is accepted with it stripped.
    assert_equal "npm *", rule("bash", { "command" => "npm test" }, match: "npm ").fetch("match")
    assert_equal "/Users/me/project/*",
      rule("write", { "path" => "/Users/me/project/notes.md" }, match: "/Users/me/project/").fetch("match")
  end

  # ---- the whole-tool shape ----

  def test_every_other_tool_is_granted_whole
    assert_equal({ "tool" => "mcp__fs__read_file", "verdict" => "allow" },
      rule("mcp__fs__read_file", { "path" => "/etc/hosts" }))
    assert_equal({ "tool" => "stop_process", "verdict" => "allow" }, rule("stop_process", { "id" => "p3" }))
    assert_equal({ "tool" => "memory_write", "verdict" => "allow" }, rule("memory_write", {}))
    assert_equal({ "tool" => "ask", "verdict" => "allow" }, rule("ask", nil))
  end

  # ---- the five refusals, byte for byte ----

  def test_refusal_1_the_held_call_carries_no_text_to_key_on
    refused = rule("bash", { "workdir" => "/tmp" })
    assert_kind_of Grant::Refusal, refused
    assert_equal "the held call carries no command text to key a grant on", refused.message
    assert_equal "the held call carries no path text to key a grant on", rule("write", {}).message
    assert_equal "the held call carries no command text to key a grant on", rule("bash", nil).message
    # A non-String at the key, and a blank one, carry no text either.
    assert_equal "the held call carries no command text to key a grant on", rule("bash", { "command" => ["ls"] }).message
    assert_equal "the held call carries no command text to key a grant on", rule("bash", { "command" => 3 }).message
    assert_equal "the held call carries no path text to key a grant on", rule("edit", { "path" => "  \n" }).message
  end

  def test_refusal_2_a_held_text_with_a_wildcard_is_refused_exact
    refused = rule("bash", { "command" => "ls *.rb" })
    assert_kind_of Grant::Refusal, refused
    assert_equal "the held command contains * or ?, which the kernel reads as wildcards; grant a prefix with --match instead",
      refused.message
    assert_equal "the held path contains * or ?, which the kernel reads as wildcards; grant a prefix with --match instead",
      rule("write", { "path" => "/tmp/what?.md" }).message
    # Under `--match` the held text may carry them: the prefix is what the
    # kernel reads, and it is checked for wildcards on its own.
    assert_equal "ls *", rule("bash", { "command" => "ls *.rb" }, match: "ls").fetch("match")
  end

  def test_refusal_3_a_blank_or_wildcarded_prefix
    sentence = "--match is literal text and cannot be blank; the kernel reads * and ? as wildcards"
    assert_equal sentence, rule("bash", { "command" => "npm test" }, match: "").message
    assert_equal sentence, rule("bash", { "command" => "npm test" }, match: "   ").message
    assert_equal sentence, rule("bash", { "command" => "printf held" }, match: "print*").message
    assert_equal sentence, rule("bash", { "command" => "npm test" }, match: "n?m").message
    # A prefix that is only the separator is blank once stripped.
    assert_equal sentence, rule("write", { "path" => "/x.md" }, match: "/").message
  end

  def test_refusal_4_a_prefix_must_be_a_whole_token_of_the_held_text
    sentence = "--match must be a whole-token prefix of the held command, followed by \" \": \"printf held > held.txt\""
    assert_equal sentence, rule("bash", { "command" => "printf held > held.txt" }, match: "echo").message
    assert_equal sentence, rule("bash", { "command" => "printf held > held.txt" }, match: "p").message, "not a whole token"
    assert_equal sentence, rule("bash", { "command" => "printf held > held.txt" }, match: "printf held > held.txt").message,
      "the whole text is not a prefix followed by the separator"
    assert_equal "--match must be a whole-token prefix of the held path, followed by \"/\": \"/Users/me/project/notes.md\"",
      rule("write", { "path" => "/Users/me/project/notes.md" }, match: "/Users/me/proj").message
  end

  def test_refusal_5_match_narrows_a_text_keyed_tool_only
    refused = rule("mcp__fs__read_file", { "path" => "/etc/hosts" }, match: "/etc")
    assert_kind_of Grant::Refusal, refused
    assert_equal "--match narrows a text-keyed tool (bash, start_process, write, edit); mcp__fs__read_file is granted whole",
      refused.message
    assert_equal "--match narrows a text-keyed tool (bash, start_process, write, edit); stop_process is granted whole",
      rule("stop_process", { "id" => "p3" }, match: "p").message
  end

  # THE ENCODING CHECK (decisions R): the kernel answers `glob_invalid` for
  # the WHOLE declaration on a non-UTF-8 text (`rules.rb:118-123`), which
  # would cost every rule; so a held text that is not valid UTF-8 is
  # refused here, exact or prefix, before anything moves.
  def test_a_held_text_that_is_not_valid_utf8_is_refused_before_the_kernel_sees_it
    bad = "npm \xFF test".dup.force_encoding(Encoding::UTF_8)
    refute_predicate bad, :valid_encoding?
    refused = rule("bash", { "command" => bad })
    assert_kind_of Grant::Refusal, refused
    assert_equal "the held command is not valid UTF-8 text; the kernel would refuse the whole rule list (glob_invalid)",
      refused.message
    assert_equal refused.message, rule("bash", { "command" => bad }, match: "npm").message
  end

  # ---- the record ----

  def test_the_record_carries_the_rule_and_its_provenance_and_names_the_key
    grant = Grant.new(rule: rule("bash", { "command" => "npm test" }), run_public_id: "al-9", task_key: "r1t0",
      conversation: "c-1", granted_at: "2026-09-15T10:11:12Z")
    assert_equal %i[rule run_public_id task_key conversation granted_at], grant.to_h.keys
    assert_equal "command", Grant.text_key("bash")
    assert_equal "command", Grant.text_key("start_process")
    assert_equal "path", Grant.text_key("write")
    assert_equal "path", Grant.text_key("edit")
    assert_equal "url", Grant.text_key("web_fetch")
    assert_nil Grant.text_key("mcp__fs__read_file")
    # The kernel's `envelope_bound` on the declared list, the SDK's own
    # constant — printed beside the declared size, never enforced here.
    assert_equal CybrosAgent::SizeBounds::ENVELOPE_BOUND, Grant::DECLARED_BOUND
  end
end
