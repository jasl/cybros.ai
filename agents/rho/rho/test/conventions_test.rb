require "test_helper"
require "tmpdir"

# REPOSITORY CONVENTIONS reach the model: nearest last and kept whole, a
# shared budget spent farthest-first, and an honest notice when it runs out.
class ConventionsTest < Minitest::Test
  def with_tree
    Dir.mktmpdir("rho-conventions") do |root|
      root = File.realpath(root)
      FileUtils.mkdir_p(File.join(root, "app", "billing"))
      yield root
    end
  end

  def test_files_walk_from_the_working_directory_up_to_the_root_nearest_last
    with_tree do |root|
      File.write(File.join(root, "AGENTS.md"), "root rules")
      File.write(File.join(root, "app", "CLAUDE.md"), "app rules")
      File.write(File.join(root, "app", "billing", "AGENTS.md"), "billing rules")
      File.write(File.join(File.dirname(root), "AGENTS.md"), "outside") rescue nil

      found = Rho::Conventions.files(working_directory: File.join(root, "app", "billing"), root: root)
      assert_equal ["billing rules", "app rules", "root rules"], found.map(&:text)
    ensure
      FileUtils.rm_f(File.join(File.dirname(root), "AGENTS.md"))
    end
  end

  def test_the_block_names_each_file_and_is_absent_when_there_are_none
    with_tree do |root|
      assert_nil Rho::Conventions.block(working_directory: root, root: root)
      File.write(File.join(root, "AGENTS.md"), "No type probes.")
      block = Rho::Conventions.block(working_directory: root, root: root)
      assert_includes block, "--- #{File.join(root, "AGENTS.md")} ---\nNo type probes."
      assert block.start_with?("Repository conventions")
    end
  end

  # The budget is spent farthest-first, so the NEAREST file is the one
  # that survives whole; the cut file says so, and by how much.
  def test_the_budget_cuts_the_farthest_file_and_says_so
    with_tree do |root|
      File.write(File.join(root, "AGENTS.md"), "R" * 3000)
      File.write(File.join(root, "app", "AGENTS.md"), "A" * 500)
      block = Rho::Conventions.block(working_directory: File.join(root, "app"), root: root, budget: 1200)
      preamble, sections = block.split("\n\n", 2)
      assert_operator sections.bytesize, :<=, 1200 + 2, "the files overran the budget: #{sections.bytesize}"
      assert block.start_with?("Repository conventions"), preamble
      assert_includes block, "A" * 500, "the nearest file was not kept whole"
      assert_match(/\[…\d+ more bytes of AGENTS\.md omitted/, block)
      refute_includes block, "R" * 3000
    end
  end

  # THE HOME'S FILE: `$RHO_HOME/AGENTS.md` is the FARTHEST
  # section — last in `files`, first in the block, the first the budget
  # cuts — read once when the walk already passed through the home, and
  # absent without a home.
  def test_the_homes_agents_md_is_the_farthest_section_of_the_block
    with_tree do |root|
      home = File.join(File.dirname(root), "rho-home-#{File.basename(root)}")
      FileUtils.mkdir_p(home)
      File.write(File.join(home, "AGENTS.md"), "home rules")
      File.write(File.join(home, "CLAUDE.md"), "claude at the home")
      File.write(File.join(root, "AGENTS.md"), "root rules")
      File.write(File.join(root, "app", "AGENTS.md"), "app rules")

      found = Rho::Conventions.files(working_directory: File.join(root, "app"), root: root, home: home)
      assert_equal ["app rules", "root rules", "home rules"], found.map(&:text),
        "nearest first, the home's last; the home section is AGENTS.md alone"
      assert_equal File.join(home, "AGENTS.md"), found.last.path
      assert_equal ["app rules", "root rules"],
        Rho::Conventions.files(working_directory: File.join(root, "app"), root: root).map(&:text), "no home, no section"

      block = Rho::Conventions.block(working_directory: File.join(root, "app"), root: root, home: home)
      sections = block.split("\n\n").drop(1)
      assert_equal ["--- #{File.join(home, "AGENTS.md")} ---\nhome rules", "--- #{File.join(root, "AGENTS.md")} ---\nroot rules",
                    "--- #{File.join(root, "app", "AGENTS.md")} ---\napp rules"], sections, "general first, nearest last"

      File.write(File.join(home, "AGENTS.md"), "H" * 3000)
      cut = Rho::Conventions.block(working_directory: File.join(root, "app"), root: root, home: home, budget: 1200)
      assert_includes cut, "app rules"
      assert_includes cut, "root rules"
      assert_match(/\[…\d+ more bytes of AGENTS\.md omitted/, cut)
      refute_includes cut, "H" * 3000, "the home's file is the first the budget cuts"

      # A root under the home: the walk passes through the home as a
      # directory like any other (both names read there), and the home
      # section does not read AGENTS.md a second time.
      File.write(File.join(home, "AGENTS.md"), "home rules")
      under = File.join(home, "work", "project")
      FileUtils.mkdir_p(under)
      File.write(File.join(under, "AGENTS.md"), "project rules")
      once = Rho::Conventions.files(working_directory: under, root: home, home: home)
      assert_equal ["project rules", "home rules", "claude at the home"], once.map(&:text),
        "a walk that reached the home reads its AGENTS.md once"
    ensure
      FileUtils.rm_rf(home) if home
    end
  end

  # The block reaches the seed as the Conventions extension's fragment,
  # after the coding tools' own — the home's section too, from the host's
  # home; a standalone runner (no host) carries the walk alone.
  def test_a_run_declaration_carries_the_conventions_in_its_instructions
    with_tree do |root|
      File.write(File.join(root, "AGENTS.md"), "Always run the tests.")
      registry = Rho::Runner::Extensions::Loader.call(
        builtin: [Rho::Runner::Extensions::Coding, Rho::Extensions::Conventions]
      ).registry
      environment = Rho::Runner::Environment.local(root: root, working_directory: root)
      step = Rho::RunDeclaration.steps(runner_executor_public_id: "own-runner", prompt: "p", model: "dev/mock-text", registry: registry,
        environment: environment).first
      assert_includes step.instructions, "Always run the tests."
      assert_equal %w[rho.coding rho.conventions],
        registry.environment_fragments(environment).map { |fragment| fragment.fetch("extension") }

      home_dir = File.join(root, "home")
      FileUtils.mkdir_p(home_dir)
      File.write(File.join(home_dir, "AGENTS.md"), "Never force-push.")
      home = Rho::Home.resolve(base_url: "https://nexus.example", root: home_dir)
      # The host's contract: a home and the daemon's environment tables (none here).
      host = Struct.new(:home, :environments).new(home, nil)
      hosted = Rho::Runner::Extensions::Loader.call(
        builtin: [Rho::Runner::Extensions::Coding, Rho::Extensions::Conventions], api_options: { host: host }
      ).registry
      hosted_step = Rho::RunDeclaration.steps(runner_executor_public_id: "own-runner", prompt: "p", model: "dev/mock-text", registry: hosted,
        environment: environment).first
      assert_includes hosted_step.instructions, "--- #{File.join(home.root, "AGENTS.md")} ---\nNever force-push."
      assert_operator hosted_step.instructions.index("Never force-push."), :<, hosted_step.instructions.index("Always run the tests."),
        "the home's section is the farthest: before the root's"
      refute_includes step.instructions, "Never force-push.", "no host, no home section"
    end
  end
end
