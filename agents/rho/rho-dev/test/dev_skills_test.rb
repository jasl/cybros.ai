require "test_helper"
require "tmpdir"

# The registered skill command talks to the daemon, including the observation
# that conditions a whole-file push or removal. The endpoint keeps requests
# so a stale response cannot quietly trigger another read or mutation.
class DevSkillsTest < Minitest::Test
  include RhoTest::CliHarness

  def self.handler
    @handler ||= begin
      api = Rho::Extensions::Api.new(host: RhoTest.host, extension_name: Rho::Dev::NAME, source: "<test>")
      Rho::Dev::Skills.register(api)
      api.commands.fetch(0).handler
    end
  end

  def skills(*args, **options) = self.class.handler.call(cli, args, options)

  # SKILLS FROM A TERMINAL: `push`
  # splits the SKILL.md HERE with the runner's own parser — a quoted colon
  # in the description is the split's pin — and posts the row's fields;
  # mutations send the version observed once at command start.
  def skill_dir(root, name, description)
    dir = File.join(root, name)
    FileUtils.mkdir_p(dir)
    File.write(File.join(dir, "SKILL.md"),
      "---\nname: #{name}\ndescription: #{description}\n---\n# #{name}\n\n- first\n", encoding: "UTF-8")
    dir
  end

  def test_skills_push_splits_the_skill_md_here_and_posts_the_row_to_the_named_rung
    seen = []
    row = { "path" => "skills/review-checklist", "bytesize" => 28, "description" => "Review: how I do it.",
            "written_at" => "2026-09-15T00:00:00Z", "content" => "# review-checklist\n\n- first\n" }
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /skills/show" => [[404, { "error" => { "code" => "memory_not_found", "message" => "Missing" } }]],
      "GET /skills" => [[200, { "skills" => { "collections" => { "agent" => { "public_id" => "collection-agent" } } } }]],
      "POST /skills/push" => [[201, { "memory" => row }]]))

    Dir.mktmpdir do |root|
      dir = skill_dir(root, "review-checklist", '"Review: how I do it."')
      pushed = skills("push", dir)
      assert_equal row, pushed
    end

    body = JSON.parse(seen.grep(%r{\APOST /skills/push}).fetch(0).partition("\r\n\r\n").last)
    assert_equal({ "scope" => "agent", "name" => "review-checklist", "description" => "Review: how I do it.",
                   "content" => "# review-checklist\n\n- first\n", "expected_collection_public_id" => "collection-agent", "expected_public_id" => nil,
                   "expected_lock_version" => nil }, body,
      "the frontmatter is split off here: name, description, and the body without it")
    assert_equal "pushed:    skills/review-checklist (28 bytes)\n", @out.string
  end

  # The workspace rung is the adopted workspace's own door: the body names the rung, never a conversation.
  def test_skills_push_names_the_workspace_rung_and_refuses_a_bad_scope
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /skills/show" => [[200, { "memory" => { "public_id" => "019a0000-0000-7000-8000-000000000001",
                                                 "collection_public_id" => "collection-agent", "lock_version" => 4, "content" => "previous" } }]],
      "POST /skills/push" => [[201, { "memory" => { "path" => "skills/commit-style", "bytesize" => 3 } }]]))
    Dir.mktmpdir do |root|
      dir = skill_dir(root, "commit-style", "How commits are written.")
      skills("push", dir, scope: "workspace")
      body = JSON.parse(seen.grep(%r{\APOST /skills/push}).fetch(0).partition("\r\n\r\n").last)
      assert_equal %w[scope name description content expected_collection_public_id expected_public_id expected_lock_version], body.keys
      assert_equal "019a0000-0000-7000-8000-000000000001", body.fetch("expected_public_id")
      assert_equal 4, body.fetch("expected_lock_version")
      assert_equal "workspace", body.fetch("scope")

      error = assert_raises(Rho::Error) { skills("push", dir, scope: "project") }
      assert_includes error.message, "--scope must be agent or workspace"
    end
  end

  def test_skills_push_refuses_a_directory_that_is_not_a_skill_before_the_wire
    announce(endpoint: routed_endpoint({}))
    Dir.mktmpdir do |root|
      error = assert_raises(Rho::Error) { skills("push", root, scope: "agent") }
      assert_includes error.message, "no SKILL.md"

      dir = skill_dir(root, "Bad-Name", "d")
      error = assert_raises(Rho::Error) { skills("push", dir, scope: "agent") }
      assert_includes error.message, "is not a skill name"
    end
    assert_raises(Rho::Error) { skills("push", nil, scope: "agent") }
  end

  def test_skills_push_relays_the_kernels_refusal_word
    announce(endpoint: routed_endpoint(
      "GET /skills/show" => [[404, { "error" => { "code" => "memory_not_found", "message" => "Missing" } }]],
      "GET /skills" => [[200, { "skills" => { "collections" => { "agent" => { "public_id" => "collection-agent" } } } }]],
      "POST /skills/push" => [[422, { "error" => { "code" => "skill_description_required", "message" => "Refused: skill_description_required" } }]]))
    Dir.mktmpdir do |root|
      dir = skill_dir(root, "commit-style", "d")
      error = assert_raises(Rho::Error) { skills("push", dir, scope: "agent") }
      assert_equal "Refused: skill_description_required", error.message
    end
  end

  def test_skills_show_prints_the_body_and_rm_prints_nothing
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /skills/show" => [[200, { "memory" => { "path" => "skills/commit-style",
                                                    "content" => "# Commits\n\nOne line.\n",
                                                    "public_id" => "019a0000-0000-7000-8000-000000000001",
                                                    "collection_public_id" => "collection-agent", "lock_version" => 4 } }]],
      "POST /skills/rm" => [[200, { "deleted" => { "path" => "skills/commit-style" } }]]))

    skills("show", "commit-style", scope: "workspace")
    assert_equal "# Commits\n\nOne line.\n", @out.string
    assert_match(%r{\AGET /skills/show\?scope=workspace&name=commit-style },
      seen.grep(%r{\AGET /skills/show}).fetch(0))

    @out.truncate(0)
    @out.rewind
    deleted = skills("rm", "commit-style", scope: "workspace")
    assert_equal({ "path" => "skills/commit-style" }, deleted)
    assert_equal "", @out.string
    body = JSON.parse(seen.grep(%r{\APOST /skills/rm}).fetch(0).partition("\r\n\r\n").last)
    assert_equal({ "scope" => "workspace", "name" => "commit-style",
                   "expected_collection_public_id" => "collection-agent", "expected_public_id" => "019a0000-0000-7000-8000-000000000001",
                   "expected_lock_version" => 4 }, body)

    assert_raises(Rho::Error) { skills("show", nil, scope: "agent") }
    assert_raises(Rho::Error) { skills("rm", nil, scope: "agent") }
    assert_raises(Rho::Error) { skills("announce", "x", scope: "agent") }
  end

  def test_skills_lists_the_three_sections_and_says_when_no_root_is_set
    listing = { "skills" => {
      "agent" => [{ "name" => "review-checklist", "path" => "skills/review-checklist",
                   "description" => "Review: how I do it.", "bytesize" => 28, "written_at" => "2026-09-15T00:00:00Z" }],
      "workspace" => [],
      "project" => [{ "name" => "deploy-notes", "description" => "How this project is deployed." }],
    } }
    announce(endpoint: routed_endpoint("GET /skills" => [[200, listing]]))
    skills(nil, {})
    assert_equal ["agent/", "  review-checklist: Review: how I do it.", "workspace/", "  (none)",
                  "project (announced by this runner)", "  deploy-notes: How this project is deployed."],
      @out.string.lines.map(&:chomp)

    @out.truncate(0)
    @out.rewind
    none = { "skills" => { "agent" => [], "workspace" => [], "project" => nil } }
    announce(endpoint: routed_endpoint("GET /skills" => [[200, none]]))
    skills(nil, {})
    assert_equal ["agent/", "  (none)", "workspace/", "  (none)",
                  "project (no root set; `rho env ROOT` points the runner at one)"],
      @out.string.lines.map(&:chomp)
  end

  def test_mutations_do_not_read_again_or_retry_after_a_version_conflict
    %w[push rm].each do |verb|
      seen = []
      announce(endpoint: recording_routed_endpoint(seen,
        "GET /skills/show" => [[200, { "memory" => { "public_id" => "019a0000-0000-7000-8000-000000000001",
                                                   "collection_public_id" => "collection-agent", "lock_version" => 4, "content" => "previous" } }]],
        "POST /skills/#{verb}" => [[409, { "error" => { "code" => "stale_object", "message" => "Changed" } }]]))
      Dir.mktmpdir do |root|
        target = verb == "push" ? skill_dir(root, "commit-style", "d") : "commit-style"
        error = assert_raises(Rho::Core::Refused) { skills(verb, target, scope: "workspace") }
        assert_equal "stale_object", error.code
      end
      reads = seen.grep(%r{\AGET /skills/show})
      writes = seen.grep(%r{\APOST /skills/})
      assert_equal 1, reads.length, verb
      assert_equal 1, writes.length, verb
      assert_operator seen.index(reads.first), :<, seen.index(writes.first), verb
      body = JSON.parse(writes.first.partition("\r\n\r\n").last)
      assert_equal "019a0000-0000-7000-8000-000000000001", body.fetch("expected_public_id")
      assert_equal 4, body.fetch("expected_lock_version")
    end
  end

  def test_push_does_not_treat_other_read_refusals_as_an_absent_skill
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /skills/show" => [[404, { "error" => { "code" => "workspace_not_found", "message" => "Missing" } }]]))
    Dir.mktmpdir do |root|
      error = assert_raises(Rho::Core::Refused) { skills("push", skill_dir(root, "commit-style", "d")) }
      assert_equal "workspace_not_found", error.code
    end
    assert_empty seen.grep(%r{\APOST /skills/})
  end

  def test_removing_an_absent_skill_does_not_send_a_null_delete
    seen = []
    announce(endpoint: recording_routed_endpoint(seen,
      "GET /skills/show" => [[404, { "error" => { "code" => "memory_not_found", "message" => "Missing" } }]]))
    error = assert_raises(Rho::Core::Refused) { skills("rm", "commit-style") }
    assert_equal "memory_not_found", error.code
    assert_empty seen.grep(%r{\APOST /skills/})
  end
end
