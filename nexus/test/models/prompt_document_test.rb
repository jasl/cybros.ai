require "test_helper"

# THE THREE SLOTS ON MEMORY'S ANCHOR SHAPE: exactly one of workspace, user anchors a document; the
# slot names WHOSE row it may stand on (`character` the room's, `system_prompt` an agent profile's,
# `persona` a Human's). No CHECK — the validation is the arbiter, the two partial unique indexes the
# structural backstop.
class PromptDocumentTest < ActiveSupport::TestCase
  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @human = users(:owner)
    @agent = users(:agent)
  end

  def build(slot:, content: "You are here.", **anchor)
    PromptDocument.new(account: @account, slot: slot, role: "system", content: content, **anchor)
  end

  test "the slots and roles are closed words, and each slot names its anchor" do
    assert_equal %w[system_prompt character persona], PromptDocument::ASSEMBLY_SLOTS, "the three placed slots"
    assert_equal %w[system_prompt character persona summarizer], PromptDocument::SLOTS
    assert_equal %w[system developer user], PromptDocument::ROLES
    assert_equal({ "character" => :workspace, "system_prompt" => :agent, "persona" => :human, "summarizer" => :agent },
      PromptDocument::SLOT_ANCHORS)
    assert_equal %w[system_prompt summarizer], PromptDocument.slots_anchored(:agent)
    assert_equal %w[persona], PromptDocument.slots_anchored(:human)
  end

  # THE SUMMARIZER SLOT: the agent profile's own row like `system_prompt`, never placed by a
  # template, and content-only — its reader is a raw `instructions` string on a kernel loop with no
  # macro sources, so every `{{…}}` is refused by name.
  test "summarizer stands on an agent profile alone and admits no macro" do
    assert_predicate build(slot: "summarizer", user: @agent), :valid?
    [build(slot: "summarizer", user: @human), build(slot: "summarizer", workspace: @workspace)].each do |document|
      assert_not document.valid?
      assert document.errors.of_kind?(:slot, :anchor_mismatch)
    end

    braces = build(slot: "summarizer", user: @agent, content: "Summarize for {{agent}}.")
    assert_equal [], braces.macro_registry
    assert_not braces.valid?
    assert braces.errors.of_kind?(:content, :macro_unknown)
    assert_equal "agent", braces.unknown_macro
  end

  test "exactly one anchor: two are invalid, none is invalid, one is valid" do
    both = build(slot: "character", workspace: @workspace, user: @agent)
    assert_not both.valid?
    assert both.errors.of_kind?(:base, :exactly_one_anchor)
    assert_not build(slot: "character").valid?
    assert_predicate build(slot: "character", workspace: @workspace), :valid?
    assert_predicate build(slot: "system_prompt", user: @agent), :valid?
    assert_predicate build(slot: "persona", user: @human), :valid?
  end

  test "a slot on the wrong anchor is anchor_mismatch: character on a user, persona on an agent, system_prompt on a Human" do
    [
      build(slot: "character", user: @human),
      build(slot: "persona", user: @agent),
      build(slot: "system_prompt", user: @human),
      build(slot: "persona", workspace: @workspace),
    ].each do |document|
      assert_not document.valid?, document.slot
      assert document.errors.of_kind?(:slot, :anchor_mismatch), document.slot
    end
  end

  test "a stranger slot or role is refused by inclusion" do
    mood = build(slot: "mood", workspace: @workspace)
    assert_not mood.valid?
    assert mood.errors.of_kind?(:slot, :inclusion)

    tool = build(slot: "character", workspace: @workspace).tap { |d| d.role = "tool" }
    assert_not tool.valid?
    assert tool.errors.of_kind?(:role, :inclusion)
  end

  # `bytesize` is the database's own count (a stored generated column), and
  # a created row reads it back — the door's presenter renders it at once.
  test "the bound is 64 KiB of content; the database derives bytesize and a created row carries it" do
    fits = build(slot: "character", workspace: @workspace, content: "é" * 32_768)
    assert_predicate fits, :valid?
    fits.save!
    assert_equal 65_536, fits.bytesize
    assert_not_predicate fits, :changed?

    fits.update!(content: "é")
    assert_equal 2, fits.bytesize
    assert_not_predicate fits, :changed?

    over = build(slot: "character", workspace: @workspace, content: "x" * 65_537)
    assert_not over.valid?
    assert over.errors.of_kind?(:content, Nexus::SizeBounds::REJECTION)
  end

  test "a macro outside the registry is refused naming the word; spaces inside the braces are fine" do
    stranger = build(slot: "character", workspace: @workspace, content: "Recall {{history}} first")
    assert_not stranger.valid?
    assert stranger.errors.of_kind?(:content, :macro_unknown)
    assert_includes stranger.errors.full_messages.join, "history"

    assert_predicate build(slot: "character", workspace: @workspace,
      content: "Today is {{ date }} in {{workspace}} with {{user}} and {{agent}}."), :valid?
  end

  # The registry at write time is the four names ∪ the profile's declared template variables — for
  # `system_prompt` on an assembly profile; `character` and `persona` stand on other anchors and see
  # the four alone.
  test "a system_prompt on an assembly profile may name a declared variable; the other slots may not" do
    template = { "blocks" => [{ "type" => "history" }, { "type" => "input" }], "variables" => { "scene" => "x" } }
    assert_not build(slot: "system_prompt", user: @agent, content: "Scene {{scene}}").valid?, "undeclared under default"

    @agent.update!(prompt_mechanism: "assembly", prompt_template: template)
    assert_predicate build(slot: "system_prompt", user: @agent, content: "Scene {{scene}} on {{date}}"), :valid?
    mood = build(slot: "system_prompt", user: @agent, content: "{{mood}}")
    assert_not mood.valid?
    assert_equal "mood", mood.unknown_macro
    assert_not build(slot: "character", workspace: @workspace, content: "Scene {{scene}}").valid?
    assert_not build(slot: "persona", user: @human, content: "Scene {{scene}}").valid?
  end

  test "version starts at 1 and the anchor and slot are creation-frozen" do
    document = build(slot: "character", workspace: @workspace).tap(&:save!)
    assert_equal 1, document.version

    assert_raises ActiveRecord::ReadonlyAttributeError do
      document.update!(workspace: workspaces(:personal))
    end
    assert_raises ActiveRecord::ReadonlyAttributeError do
      document.update!(slot: "persona")
    end
  end

  test "one document per slot per anchor — the partial index decides" do
    build(slot: "character", workspace: @workspace).save!
    assert_raises ActiveRecord::RecordNotUnique do
      build(slot: "character", workspace: @workspace).save!(validate: false)
    end
    assert_nothing_raised { build(slot: "character", workspace: workspaces(:personal)).save! }

    build(slot: "persona", user: @human).save!
    assert_raises ActiveRecord::RecordNotUnique do
      build(slot: "persona", user: @human).save!(validate: false)
    end
  end

  test "the owner associations list one anchor's rows only" do
    mine = build(slot: "character", workspace: @workspace).tap(&:save!)
    build(slot: "persona", user: @human).save!

    assert_equal [mine.id], @workspace.prompt_documents.pluck(:id)
    assert_equal ["persona"], @human.prompt_documents.pluck(:slot)
  end
end
