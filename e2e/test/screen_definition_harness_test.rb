$LOAD_PATH.unshift File.expand_path("..", __dir__)

require "fileutils"
require "minitest/autorun"
require "tmpdir"
require "yaml"
require "support/screen/definition"

# A SCREEN IS ITS DEFINITION: one tracked `screen.yml` names the design section it registers, the
# arms and the tree each runs in, the allowlist and transport lists the trees are checked against,
# the cells, the lane caps, the smoke, the watch's parameters and the budget — and the job table
# follows from it by rule (floors first, a split cell into sample halves). Trees are arguments,
# never roots written into the file. Pure Ruby over the tracked fake definition and tmpdir copies.
class ScreenDefinitionHarnessTest < Minitest::Test
  S = E2E::Screen
  FAKE = File.expand_path("../support/fixtures/screen/fake", __dir__)
  LAUNCHED = Time.utc(2026, 9, 28, 10, 0, 0)

  def test_the_fake_definition_loads_its_sections
    definition = S::Definition.load(FAKE)
    assert_equal "fake-rehearsal", definition.name
    assert_equal ["e2e/support/fixtures/screen/fake/design.md", "§1 The rehearsal"], definition.design.values_at("path", "section")
    assert_equal %w[base candidate], definition.arms.map(&:id)
    assert_equal "base", definition.base_arm.id
    assert_equal %w[without with], definition.arms.map(&:tree)
    assert_includes definition.transport, "e2e/support/manual_client.rb"
    assert_equal %w[compose task], definition.instruments
    assert_equal 16_384, definition.max_output_tokens
    assert_equal 25.0, definition.watch.fetch("spend_stop_usd")
  end

  # THE JOB TABLE: every (arm, cell, model) a job, a split cell one job per part with its own first
  # sample index; the floors first, then the definition's order; each job its own directory.
  def test_the_jobs_follow_from_the_cells_floors_first_and_splits_by_sample_halves
    jobs = S::Definition.load(FAKE).jobs
    assert_equal (1..jobs.size).to_a, jobs.map(&:index)
    assert_equal 2 * (3 + 2), jobs.size, "two arms × (three compose models + one task model in two halves)"
    assert_equal ["fake/responses"] * 2, jobs.first(2).map(&:model), "the floors start first"

    halves = jobs.select { |job| job.instrument == "task" && job.arm == "candidate" }
    assert_equal [[2, 1], [2, 3]], halves.map { |job| [job.n, job.sample_first] }
    assert_equal %w[candidate/task/fake_chat-b.1 candidate/task/fake_chat-b.2], halves.map(&:dir)
    assert_equal [[%w[G0 T5 SP3A D1P], 4 * 2]] * 2, halves.map { |job| [job.objectives, job.planned] }, "objectives × n, the claims door among them"

    messages = jobs.find { |job| job.model == "fake/messages" && job.arm == "base" }
    assert_equal ["compose", %w[O1 O7], 2, 1, "base/compose/fake_messages", "fake", "shipped", "nexus"],
      [messages.instrument, messages.objectives, messages.n, messages.sample_first, messages.dir, messages.lane, messages.row, messages.style],
      "the rehearsal names each tree's own shipped row, so it runs on any tree"
    assert_nil halves.first.row, "the task probe has no compose row"
    assert_equal 2 * 2, messages.planned, "objectives × n"
  end

  # ONE MODEL IN TWO CELLS OF ONE INSTRUMENT — a clause at one n on some objectives, another at a
  # larger n on others — is two jobs, each writing its own directory: a shared one would hand each
  # job the other's draws. Registering one objective in both would draw it twice under one name.
  def test_a_model_in_two_cells_of_an_instrument_draws_into_a_directory_per_cell
    cells = [{ "instrument" => "compose", "models" => %w[fake/chat-a], "objectives" => %w[O1 O3], "n" => 8 },
             { "instrument" => "compose", "models" => %w[fake/chat-a fake/responses], "objectives" => %w[O7b], "n" => 12 }]
    with_definition("cells" => cells) do |dir|
      base = S::Definition.load(dir).jobs.select { |job| job.arm == "base" }
      assert_equal [["fake/responses", %w[O7b], 12, "base/compose/fake_responses"],
                    ["fake/chat-a", %w[O1 O3], 8, "base/compose/fake_chat-a.cell1"],
                    ["fake/chat-a", %w[O7b], 12, "base/compose/fake_chat-a.cell2"]],
        base.map { |job| [job.model, job.objectives, job.n, job.dir] }
    end

    twice = [cells.first, cells.last.merge("objectives" => %w[O3 O7b])]
    with_definition("cells" => twice) do |dir|
      error = assert_raises(ArgumentError) { S::Definition.load(dir) }
      assert_includes error.message, "compose fake/chat-a O3"
    end
  end

  # A RELAUNCH AFTER A STORM runs the registered post-storm layout: the lower caps, and the split
  # cells merged back into one job per (arm, model).
  def test_the_post_storm_layout_lowers_the_caps_and_merges_the_splits
    definition = S::Definition.load(FAKE).after_storm
    assert_equal 6, definition.caps.fetch("fake/chat-a")
    assert_equal 14, definition.caps.fetch("fake/"), "the caps it does not name stand"
    halves = definition.jobs.select { |job| job.instrument == "task" && job.arm == "candidate" }
    assert_equal [[4, 1, "candidate/task/fake_chat-b"]], halves.map { |job| [job.n, job.sample_first, job.dir] }
    assert_equal 60.0, definition.stagger_seconds
    assert_raises(ArgumentError, "the merged layout is checked like any other") { definition.with(arms: []) }
  end

  def test_a_job_names_its_tree_through_its_arm
    definition = S::Definition.load(FAKE)
    trees = { "with" => "/trees/w", "without" => "/trees/wo" }
    assert_equal %w[/trees/wo /trees/w], %w[base candidate].map { |arm| definition.tree_root(arm, trees) }
  end

  def test_a_job_round_trips_through_its_stamp_line
    job = S::Definition.load(FAKE).jobs.last
    assert_equal job, S::Job.from_stamp_line(job.index, job.stamp_line)
  end

  # EVERY MODEL THE LAUNCH DRAWS is priced and keyed: a smoke lane no cell names is one of them.
  def test_the_drawn_models_are_the_cells_then_the_smokes
    assert_equal S::Definition.load(FAKE).models, S::Definition.load(FAKE).drawn_models, "the fake smoke draws cell models only"
    smoke = { "instrument" => "compose", "objective" => "O1", "models" => %w[fake/chat-a fake/chat-control],
              "timeout_seconds" => 600 }
    with_definition("smoke" => smoke) do |dir|
      definition = S::Definition.load(dir)
      assert_equal [*definition.models, "fake/chat-control"], definition.drawn_models
    end
  end

  # THE COUNT holds for exactly the registered draws: each objective at each index once, the job's
  # own model, arm, process and style, nothing recorded before the launch. Every other reading is
  # a sentence naming what broke.
  def test_the_count_holds_for_exactly_the_registered_draws
    job = counted_job
    assert_equal [], job.count_problems(draws(job), launched_at: LAUNCHED)
    assert_equal [], job.count_problems(draws(job).map { |draw| draw.except("style") }, launched_at: LAUNCHED),
      "a record without a style is the job's own style"
  end

  def test_the_count_names_each_way_a_job_breaks_it
    job = counted_job
    exact = draws(job)
    {
      "a duplicate sample" => [exact.first(3) + [exact[2]], ["O7 holds samples [1, 1], not [1, 2]"]],
      "a missing index" => [exact.first(3), ["3 records of 4", "O7 holds samples [1], not [1, 2]"]],
      "an index outside the job" => [exact.first(3) + [exact[3].merge("sample" => 3)], ["O7 holds samples [1, 3], not [1, 2]"]],
      "an objective not the job's" => [exact.first(3) + [exact[3].merge("objective" => "O9")],
                                        ["O7 holds samples [1], not [1, 2]", "\"O9\" is not one of the job's objectives"]],
      "another model" => [exact.first(3) + [exact[3].merge("model" => "fake/responses")], ["1 records of another model, arm, process or style"]],
      "another arm" => [exact.first(3) + [exact[3].merge("arm" => "candidate")], ["1 records of another model, arm, process or style"]],
      "another process" => [exact.first(3) + [exact[3].merge("process" => "99")], ["1 records of another model, arm, process or style"]],
      "another style" => [exact.first(3) + [exact[3].merge("style" => "claude")], ["1 records of another model, arm, process or style"]],
      "a record before the launch" => [exact.first(3) + [exact[3].merge("recorded_at" => (LAUNCHED - 1).utc.iso8601(3))],
                                       ["1 records before launched_at"]],
    }.each do |why, (records, problems)|
      assert_equal problems, job.count_problems(records, launched_at: LAUNCHED), why
    end
  end

  def test_the_definition_and_its_design_section_are_hashed_for_the_stamp
    definition = S::Definition.load(FAKE)
    repo = File.expand_path("../..", __dir__)
    assert_match(/\A[0-9a-f]{64}\z/, definition.sha256)
    section = definition.design_section(repo)
    assert section.start_with?("## §1 The rehearsal")
    refute_includes section, "Not registered", "the section ends at the next heading of its level"
  end

  # THE DEFINITION IS ITS WHOLE DIRECTORY: the clauses the analysis decides by are hashed with
  # `screen.yml`, so a rule edited after the stamp is another definition; a dotfile is not.
  def test_the_definitions_sha_covers_every_file_beside_screen_yml
    Dir.mktmpdir("screen-definition") do |scratch|
      dir = File.join(scratch, "definition")
      FileUtils.cp_r(FAKE, dir)
      stamped = S::Definition.load(dir).sha256
      File.write(File.join(dir, ".DS_Store"), "x")
      assert_equal stamped, S::Definition.load(dir).sha256
      File.write(File.join(dir, "clauses.rb"), File.read(File.join(dir, "clauses.rb")).sub('name: "REHEARSAL"', 'name: "LAND"'))
      refute_equal stamped, S::Definition.load(dir).sha256, "a verdict rule edited after the stamp"
      File.write(File.join(dir, "clauses.rb"), File.read(File.join(FAKE, "clauses.rb")))
      File.write(File.join(dir, "wire", "chat.json"), "{}")
      refute_equal stamped, S::Definition.load(dir).sha256, "a file in a subdirectory"
    end
  end

  def test_a_design_without_the_section_is_refused
    with_definition("design" => { "path" => "e2e/support/fixtures/screen/fake/design.md", "section" => "§9 Absent" }) do |dir|
      definition = S::Definition.load(dir)
      error = assert_raises(ArgumentError) { definition.design_section(File.expand_path("../..", __dir__)) }
      assert_includes error.message, "§9 Absent"
    end
  end

  def test_the_refusals_at_load
    { "no base arm" => { "arms" => [{ "id" => "a", "tree" => "with", "row" => "R-WO" }] },
      "a tree that is not with or without" => { "arms" => [{ "id" => "a", "tree" => "main", "base" => true }] },
      "a split that does not divide n" => { "cells" => [{ "instrument" => "task", "models" => ["fake/chat-b"],
                                                         "objectives" => ["G0"], "n" => 3, "split" => 2 }] },
      "an instrument the launcher does not know" => { "cells" => [{ "instrument" => "door", "models" => ["fake/chat-a"],
                                                                      "objectives" => ["D1"], "n" => 2 }] },
      "a model the catalog does not name" => { "cells" => [{ "instrument" => "compose", "models" => ["openrouter/nobody/none"],
                                                            "objectives" => ["O1"], "n" => 2 }] },
      "a smoke model the catalog does not name" => { "smoke" => { "instrument" => "compose", "objective" => "O1",
                                                                  "models" => ["openrouter/nobody/none"], "timeout_seconds" => 600 } },
      "a watch parameter the watch does not know" => { "watch" => { "spend_stop" => 25 } } }.each do |why, change|
      with_definition(change) do |dir|
        assert_raises(ArgumentError, why) { S::Definition.load(dir) }
      end
    end
  end

  private

    # The base arm's Messages compose job: O1 and O7 at samples 1 and 2.
    def counted_job = S::Definition.load(FAKE).jobs.find { |job| job.arm == "base" && job.model == "fake/messages" }

    # The job's registered draws as its probe records them, in draw order.
    def draws(job)
      job.objectives.product(job.samples).map do |objective, sample|
        { "objective" => objective, "sample" => sample, "model" => job.model, "arm" => job.arm, "process" => job.index.to_s,
          "style" => job.style, "recorded_at" => (LAUNCHED + 60).utc.iso8601(3) }
      end
    end

    # A copy of the fake definition with `change` merged over its top level.
    def with_definition(change)
      Dir.mktmpdir("screen-definition") do |dir|
        yaml = YAML.safe_load_file(File.join(FAKE, "screen.yml")).merge(change)
        File.write(File.join(dir, "screen.yml"), YAML.dump(yaml))
        yield dir
      end
    end
end
