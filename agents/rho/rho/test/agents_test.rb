require "test_helper"

# THE SCANNER: a checkout's
# `.agents/agents/<name>.md` then `.claude/agents/<name>.md` at ONE level,
# the skills' two directories and the skills' one parser; a file that is
# not a definition is SKIPPED with one log line; a name met twice keeps
# the first. The name is the frontmatter's when present, else the
# basename, normalized; the description is squished to one line and
# bounded at the kernel's 1024 characters; `tools` is read raw (the
# narrowing is the declaration's); `model: inherit` means absent; every
# other key is logged as ignored, never refused.
class AgentsTest < Minitest::Test
  Agents = Rho::Agents

  Log = Struct.new(:lines) do
    def warn(event, **fields) = lines << [event, fields]
    def info(event, **fields) = lines << [event, fields]
  end

  def with_root
    Dir.mktmpdir("rho-agents") { |root| yield File.realpath(root) }
  end

  def write_definition(root, directory, file, text)
    dir = File.join(root, directory)
    FileUtils.mkdir_p(dir)
    path = File.join(dir, file)
    File.write(path, text, encoding: "UTF-8")
    path
  end

  def definition_md(name: nil, description: "Reviews a diff.", body: "You review.\n", extra: "")
    "---\n#{name ? "name: #{name}\n" : ""}description: #{description}\n#{extra}---\n#{body}"
  end

  def scan(root)
    @log = Log.new([])
    Agents.scan(root: root, log: @log)
  end

  def logged(event) = @log.lines.select { |name, _| name == event }.map(&:last)

  def test_the_grammar_is_the_kernels_handle_grammar
    assert_equal "\\A[a-z0-9][a-z0-9_-]{1,31}\\z", Agents::NAME_FORMAT.source
    assert_equal %w[.agents/agents .claude/agents], Agents::DIRECTORIES
    assert_equal 1024, Agents::DESCRIPTION_MAX_LENGTH
  end

  # `.agents` beats `.claude`; a name met twice keeps the first and logs.
  def test_agents_beats_claude_and_a_repeated_name_keeps_the_first
    with_root do |root|
      first = write_definition(root, ".agents/agents", "reviewer.md", definition_md(description: "from agents"))
      second = write_definition(root, ".claude/agents", "reviewer.md", definition_md(description: "from claude"))
      write_definition(root, ".claude/agents", "docs.md", definition_md(description: "Writes the docs."))

      scan = scan(root)

      assert_equal %w[reviewer docs], scan.definitions.map(&:name)
      assert_equal "from agents", scan.definitions.first.description
      assert_equal first, scan.definitions.first.path
      assert_equal [{ path: second, reason: "reviewer is already defined by #{first}" }],
        logged("agents.skipped")
      assert_equal [Agents::Skipped.new(path: second, reason: "reviewer is already defined by #{first}")],
        scan.skipped
    end
  end

  # The frontmatter's `name` when present, else the basename, normalized.
  def test_the_name_is_the_frontmatters_else_the_basename_normalized
    with_root do |root|
      write_definition(root, ".agents/agents", "x.md", definition_md(name: "reviewer"))
      write_definition(root, ".agents/agents", "Code-Reviewer.md", definition_md)
      write_definition(root, ".agents/agents", "spaced.md", definition_md(name: "\"  Padded \""))

      assert_equal %w[code-reviewer padded reviewer], scan(root).definitions.map(&:name).sort
      assert_empty @log.lines
    end
  end

  # A name outside the grammar, a missing or blank description, a
  # description over the bound: skipped with the reason, the file loads nothing.
  def test_a_name_outside_the_grammar_or_a_missing_description_is_skipped
    with_root do |root|
      bad_name = write_definition(root, ".agents/agents", "one.md", definition_md(name: "\"a b\""))
      upper = write_definition(root, ".agents/agents", "two.md", definition_md(name: "Reviewer!"))
      no_description = write_definition(root, ".agents/agents", "three.md", "---\nname: three\n---\nBody\n")
      blank = write_definition(root, ".agents/agents", "four.md", definition_md(description: "\"   \""))
      long = write_definition(root, ".agents/agents", "five.md", definition_md(description: "x" * 1025))
      not_a_string = write_definition(root, ".agents/agents", "six.md", "---\ndescription: [a, b]\n---\n")

      scan = scan(root)

      assert_empty scan.definitions
      reasons = scan.skipped.to_h { |skipped| [skipped.path, skipped.reason] }
      assert_equal "\"a b\" is not an agent name (#{Agents::NAME_RULE})", reasons.fetch(bad_name)
      assert_equal "\"reviewer!\" is not an agent name (#{Agents::NAME_RULE})", reasons.fetch(upper)
      assert_equal "description is required", reasons.fetch(no_description)
      assert_equal "description is required", reasons.fetch(blank)
      assert_equal "description exceeds 1024 characters", reasons.fetch(long)
      assert_equal "description must be a string", reasons.fetch(not_a_string)
      assert_equal 6, logged("agents.skipped").length
    end
  end

  # The description is squished to ONE line: the roster and the listing
  # read it, and a newline could forge a line.
  def test_the_description_is_squished_to_one_line
    with_root do |root|
      write_definition(root, ".agents/agents", "reviewer.md",
        "---\ndescription: |\n  Reviews a diff\n  for defects;\t reports\n\n  what matters.\n---\nBody\n")
      assert_equal "Reviews a diff for defects; reports what matters.", scan(root).definitions.first.description
    end
  end

  # `tools` raw: absent nil, `[]` none, a list or a comma-separated string
  # of names; `model`: a ref, `inherit` absent; the body stripped, empty nil.
  def test_tools_model_and_body_are_read_as_written
    with_root do |root|
      write_definition(root, ".agents/agents", "list.md",
        definition_md(extra: "tools:\n  - read\n  - grep\nmodel: dev/text\n", body: "\n  You review.  \n\n"))
      write_definition(root, ".agents/agents", "string.md",
        definition_md(extra: "tools: read, nope ,spawn\nmodel: inherit\n", body: ""))
      write_definition(root, ".agents/agents", "none.md", definition_md(extra: "tools: []\nmodel: sonnet\n"))
      write_definition(root, ".agents/agents", "absent.md", definition_md)

      by_name = scan(root).definitions.to_h { |definition| [definition.name, definition] }

      assert_equal %w[read grep], by_name.fetch("list").tools
      assert_equal "dev/text", by_name.fetch("list").model
      assert_equal "You review.", by_name.fetch("list").body
      assert_equal %w[read nope spawn], by_name.fetch("string").tools
      assert_nil by_name.fetch("string").model, "inherit means absent"
      assert_nil by_name.fetch("string").body, "an empty body is no slot"
      assert_equal [], by_name.fetch("none").tools
      assert_equal "sonnet", by_name.fetch("none").model, "a bare alias is the kernel's to refuse at declaration"
      assert_nil by_name.fetch("absent").tools
      assert_nil by_name.fetch("absent").model
      assert_empty @log.lines
    end
  end

  # `fallback_model` beside `model`, read the same way: a ref, `inherit`
  # or absent nil — never a logged-and-ignored key. What an absent one
  # means (the parent's, when the file names no model) is the derived
  # declaration's.
  def test_fallback_model_is_read_beside_model
    with_root do |root|
      write_definition(root, ".agents/agents", "own.md",
        definition_md(extra: "model: dev/text\nfallback_model: dev/fallback\n"))
      write_definition(root, ".agents/agents", "inherit.md", definition_md(extra: "fallback_model: inherit\n"))
      write_definition(root, ".agents/agents", "absent.md", definition_md)

      by_name = scan(root).definitions.to_h { |definition| [definition.name, definition] }

      assert_equal "dev/fallback", by_name.fetch("own").fallback_model
      assert_nil by_name.fetch("inherit").fallback_model, "inherit means absent"
      assert_nil by_name.fetch("absent").fallback_model
      assert_empty @log.lines, "a known key: nothing ignored"
    end
  end

  # A `tools`, `model` or `fallback_model` of the wrong shape skips the
  # file, never guesses.
  def test_tools_or_model_of_the_wrong_shape_skip_the_file
    with_root do |root|
      tools = write_definition(root, ".agents/agents", "one.md", definition_md(extra: "tools: {a: b}\n"))
      model = write_definition(root, ".agents/agents", "two.md", definition_md(extra: "model: [a]\n"))
      items = write_definition(root, ".agents/agents", "three.md", definition_md(extra: "tools: [read, 3]\n"))
      fallback = write_definition(root, ".agents/agents", "four.md", definition_md(extra: "fallback_model: 3\n"))

      scan = scan(root)

      assert_empty scan.definitions
      reasons = scan.skipped.to_h { |skipped| [skipped.path, skipped.reason] }
      assert_equal "tools must be a list of names or a comma-separated string", reasons.fetch(tools)
      assert_equal "tools must be a list of names or a comma-separated string", reasons.fetch(items)
      assert_equal "model must be a string", reasons.fetch(model)
      assert_equal "fallback_model must be a string", reasons.fetch(fallback)
    end
  end

  # Every other key is logged once per file as ignored, never refused.
  def test_unknown_keys_are_logged_as_ignored_and_the_file_loads
    with_root do |root|
      path = write_definition(root, ".agents/agents", "reviewer.md",
        definition_md(extra: "color: red\npermissionMode: default\nmaxTurns: 3\n"))

      scan = scan(root)

      assert_equal %w[reviewer], scan.definitions.map(&:name)
      assert_equal %w[color permissionMode maxTurns], scan.definitions.first.ignored_keys
      assert_equal [{ path: path, keys: %w[color permissionMode maxTurns] }], logged("agents.ignored_keys")
    end
  end

  # No frontmatter, a frontmatter that is not a mapping, a parse error:
  # the skills parser's reasons, one line each.
  def test_a_file_the_parser_cannot_read_is_skipped_with_its_reason
    with_root do |root|
      write_definition(root, ".agents/agents", "bare.md", "# No frontmatter\n")
      write_definition(root, ".agents/agents", "list.md", "---\n- a\n---\nBody\n")
      write_definition(root, ".agents/agents", "broken.md", "---\ndescription: a: b: c\n---\nBody\n")

      scan = scan(root)

      assert_empty scan.definitions
      reasons = scan.skipped.map(&:reason)
      assert_includes reasons, "no frontmatter block"
      assert_includes reasons, "frontmatter is not a mapping"
      assert reasons.any? { |reason| reason.start_with?("frontmatter did not parse") }, reasons.inspect
    end
  end

  # ONE level, `.md` alone, the two directories alone.
  def test_nested_files_other_extensions_and_other_directories_are_ignored
    with_root do |root|
      write_definition(root, ".agents/agents/nested", "deep.md", definition_md)
      write_definition(root, ".agents/agents", "notes.txt", definition_md)
      write_definition(root, "agents", "loose.md", definition_md)
      write_definition(root, ".agents/skills", "skill.md", definition_md)

      scan = scan(root)

      assert_empty scan.definitions
      assert_empty scan.skipped
      assert_empty @log.lines
    end
  end

  # No root: no file definitions at all — nothing is read from nowhere.
  def test_no_root_reads_nothing
    scan = scan(nil)
    assert_empty scan.definitions
    assert_empty scan.skipped
    assert_empty @log.lines
    assert_predicate Agents.scan(root: nil), :empty?
  end

  # A root with no definition directory reads nothing and logs nothing.
  def test_a_root_without_the_directories_reads_nothing
    with_root do |root|
      assert_predicate scan(root), :empty?
      assert_empty @log.lines
    end
  end
end
