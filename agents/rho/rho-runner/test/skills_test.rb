require "test_helper"
require "json"

# THE ONE READING OF A CHECKOUT'S SKILLS: opencode's two directories at ONE level, the name the directory's,
# one frontmatter parser, a file that is not a skill skipped with a log
# line. The rules are the agentskills validator's (`skills-ref/tests/
# test_validator.py`), ported here as the scanner's tests — the ASCII
# grammar the kernel enforces; the validator's i18n names are outside it.
class SkillsTest < Minitest::Test
  Skills = Rho::Runner::Skills
  # The kernel's published grammar (`contracts/nexus/v1/memory_documents.json`,
  # rendered by the pack generator from `Nexus::Skills`), the Progress
  # mirror's shape (`progress_test.rb`).
  PACK = File.expand_path("../../../../contracts/nexus/v1/memory_documents.json", __dir__)

  Log = Struct.new(:lines) do
    def warn(event, **fields) = lines << [event, fields]
    def info(event, **fields) = lines << [event, fields]
  end

  def with_root
    Dir.mktmpdir("rho-runner-skills") { |root| yield File.realpath(root) }
  end

  def write_skill(root, directory, name, text)
    dir = File.join(root, directory, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"), text, encoding: "UTF-8")
    dir
  end

  def skill_md(name:, description: "A test skill", body: "# My Skill\n", extra: "")
    "---\nname: #{name}\ndescription: #{description}\n#{extra}---\n#{body}"
  end

  # THE PIN: the runner's copy of the skill grammar is a MIRROR
  # of the kernel's — a name the kernel would refuse is never announced or
  # pushed — so the three constants are pinned byte for byte to the ones
  # the kernel publishes; the difference between the two homes is only
  # WHERE the rule is applied (the scanner's skip, the kernel's 422).
  def test_the_mirrored_grammar_equals_the_kernels_published_one
    published = JSON.parse(File.read(PACK, encoding: Encoding::UTF_8))
    assert_equal published.fetch("skill_name_format"), Skills::NAME_FORMAT.source,
      "the runner mirrors nexus's skill-name grammar; update the copy when the kernel moves"
    assert_equal published.fetch("skill_name_max_length"), Skills::NAME_MAX_LENGTH
    assert_equal published.fetch("skill_description_max_length"), Skills::DESCRIPTION_MAX_LENGTH
    assert_equal "skills/", published.fetch("skills_prefix"), "the prefix is the kernel's alone: a runner names the bare directory"
  end

  def scan(root)
    @log = Log.new([])
    Skills.scan(root: root, log: @log)
  end

  def skipped_reasons = @log.lines.select { |event, _| event == "skills.skipped" }.map { |_, fields| fields.fetch(:reason) }

  # test_valid_skill
  def test_a_valid_skill_is_read_as_name_description_and_the_body_without_frontmatter
    with_root do |root|
      dir = write_skill(root, ".agents/skills", "my-skill", skill_md(name: "my-skill"))
      skills = scan(root)

      assert_equal 1, skills.length
      skill = skills.first
      assert_equal "my-skill", skill.name
      assert_equal "A test skill", skill.description
      assert_equal "# My Skill\n", skill.body
      assert_equal dir, skill.dir
      assert_equal 5, skill.body_line, "the body starts on the line after the closing fence"
      assert_equal File.join(dir, "SKILL.md"), skill.path
      assert_empty @log.lines
    end
  end

  # test_valid_with_all_fields, test_allowed_tools_accepted, test_valid_compatibility
  def test_the_optional_fields_ride_the_frontmatter_unread
    with_root do |root|
      write_skill(root, ".agents/skills", "my-skill",
        skill_md(name: "my-skill", extra: "license: MIT\nmetadata:\n  author: Test\nallowed-tools: Bash(jq:*) Bash(git:*)\n" \
                                           "compatibility: Requires Python 3.11+\n"))
      assert_equal ["my-skill"], scan(root).map(&:name)
      assert_empty @log.lines
    end
  end

  # test_invalid_name_uppercase, test_name_too_long, test_name_leading_hyphen,
  # test_name_consecutive_hyphens, test_name_invalid_characters: the NAME IS
  # THE DIRECTORY'S, so the directory carries the refusal.
  def test_a_directory_outside_the_name_grammar_is_skipped_with_the_reason
    with_root do |root|
      ["MySkill", "a" * 70, "-my-skill", "my--skill", "my_skill"].each do |name|
        write_skill(root, ".agents/skills", name, skill_md(name: name))
      end
      assert_empty scan(root)
      assert_equal 5, skipped_reasons.length
      skipped_reasons.each { |reason| assert_includes reason, "is not a skill name" }
    end
  end

  # test_name_directory_mismatch
  def test_a_frontmatter_name_that_differs_from_the_directory_is_skipped
    with_root do |root|
      write_skill(root, ".agents/skills", "wrong-name", skill_md(name: "correct-name"))
      assert_empty scan(root)
      assert_equal ['name "correct-name" must match the directory "wrong-name"'], skipped_reasons
    end
  end

  # test_description_too_long, and the blank case the validator names
  def test_a_missing_blank_or_oversized_description_is_skipped
    with_root do |root|
      write_skill(root, ".agents/skills", "no-description", "---\nname: no-description\n---\nBody\n")
      write_skill(root, ".agents/skills", "blank-description", skill_md(name: "blank-description", description: '"  "'))
      write_skill(root, ".agents/skills", "long-description",
        skill_md(name: "long-description", description: "x" * 1100))
      assert_empty scan(root)
      assert_equal ["description is required", "description exceeds 1024 bytes", "description is required"],
        skipped_reasons
    end
  end

  # opencode's rule: a parse error skips the skill with one log line; an
  # unquoted colon inside a description is the author's to quote.
  def test_a_frontmatter_psych_cannot_parse_is_skipped_and_a_quoted_colon_parses
    with_root do |root|
      write_skill(root, ".agents/skills", "broken", "---\nname: broken\ndescription: a: b: c\n---\nBody\n")
      write_skill(root, ".agents/skills", "quoted", skill_md(name: "quoted", description: '"Review: how I do it."'))
      write_skill(root, ".agents/skills", "list", "---\n- a\n- b\n---\nBody\n")
      write_skill(root, ".agents/skills", "bare", "# No frontmatter\n")

      assert_equal ["quoted"], scan(root).map(&:name)
      assert_equal "Review: how I do it.", scan(root).first.description
      reasons = skipped_reasons
      assert_equal 3, reasons.length
      assert reasons.any? { |reason| reason.start_with?("frontmatter did not parse") }, reasons.inspect
      assert_includes reasons, "frontmatter is not a mapping"
      assert_includes reasons, "no frontmatter block"
    end
  end

  def test_the_two_directories_are_read_in_order_and_a_repeated_name_keeps_the_first
    with_root do |root|
      write_skill(root, ".claude/skills", "claude-only", skill_md(name: "claude-only", description: "from claude"))
      write_skill(root, ".claude/skills", "both", skill_md(name: "both", description: "claude's"))
      write_skill(root, ".agents/skills", "both", skill_md(name: "both", description: "agents'"))
      write_skill(root, ".agents/skills", "agents-only", skill_md(name: "agents-only", description: "from agents"))

      skills = scan(root)
      assert_equal %w[agents-only both claude-only], skills.map(&:name)
      assert_equal "agents'", skills.find { |skill| skill.name == "both" }.description
      assert_equal 1, skipped_reasons.length
      assert_includes skipped_reasons.first, "both is already announced from"
    end
  end

  # ONE level: the agentskills layout names a skill by its parent directory,
  # and a nested SKILL.md would have two candidate names.
  def test_a_nested_skill_md_and_other_directories_are_ignored
    with_root do |root|
      write_skill(root, ".agents/skills/pdf", "extract", skill_md(name: "extract"))
      write_skill(root, ".dsh/skills", "product", skill_md(name: "product"))
      write_skill(root, "skills", "loose", skill_md(name: "loose"))
      FileUtils.mkdir_p(File.join(root, ".agents/skills/empty-dir"))

      assert_empty scan(root)
      assert_empty @log.lines
    end
  end

  def test_read_answers_one_directory_for_the_push_verb
    with_root do |root|
      dir = write_skill(root, ".agents/skills", "review-checklist",
        skill_md(name: "review-checklist", description: '"Review: how I do it."', body: "# Review\n\n- tests\n"))
      skill = Skills.read(dir)
      assert_equal "review-checklist", skill.name
      assert_equal "# Review\n\n- tests\n", skill.body

      missing = Skills.read(File.join(root, "nowhere"))
      assert_predicate missing, :skipped?
      assert_includes missing.reason, "no SKILL.md"
    end
  end

  # THE ONE PARSER, PUBLIC: rho's named
  # agent scan reads `.agents/agents/<name>.md` through the same split and
  # the same `Psych.safe_load` — the mapping, the body and its line, or the
  # reason as a String in the mapping's place.
  def test_frontmatter_answers_the_mapping_the_body_and_its_line_or_the_reason
    assert_equal [{ "name" => "x", "description" => "D" }, "Body\n", 5],
      Skills.frontmatter("---\nname: x\ndescription: D\n---\nBody\n")
    assert_equal ["no frontmatter block", "# Bare\n", 1], Skills.frontmatter("# Bare\n")
    assert_equal ["frontmatter is not a mapping", "Body\n", 4], Skills.frontmatter("---\n- a\n---\nBody\n")
    reason, body, line = Skills.frontmatter("---\ndescription: a: b: c\n---\nBody\n")
    assert reason.start_with?("frontmatter did not parse"), reason
    assert_equal ["Body\n", 4], [body, line]
  end

  def test_the_body_keeps_its_bytes_and_a_frontmatter_left_in_a_later_fence_stays_in_the_body
    with_root do |root|
      body = "Line one\n---\nnot a fence in the body\n"
      write_skill(root, ".agents/skills", "keeps", skill_md(name: "keeps", body: body))
      assert_equal body, scan(root).first.body
    end
  end
end
