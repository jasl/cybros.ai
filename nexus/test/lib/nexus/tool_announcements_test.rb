require "test_helper"

# The announcement door's rules: what an executor SERVES, for delivery only. The door rules on names
# — a reserved kernel namespace is refused, an OVERRIDABLE kernel wire name is admitted and
# stored as announced — and keeps the two declaration keys (`description`,
# `input_schema`) a machine says about itself. The declaration door (ToolDeclarations) is the
# model's fact and does not move.
class Nexus::ToolAnnouncementsTest < ActiveSupport::TestCase
  Door = Nexus::ToolAnnouncements
  Registry = Nexus::ToolRegistry
  READ = Registry::READ_ONLY_CLOSED

  def entry(name, **extra) = { "name" => name, "effect_profile" => READ }.merge(extra)

  def refusal(*entries) = Door.refusal(entries)

  test "the entry shape declares delivery effects and model presentation" do
    assert_equal %w[name effect_profile timeout_ms description input_schema], Door::ENTRY_KEYS
  end

  # ── the three-way split over the kernel's names ────────

  test "a live name under a reserved namespace is refused reserved_namespace in either spelling" do
    { "wait" => "nexus.graph", "nexus.graph.wait" => "nexus.graph", "delegate_task" => "nexus.graph",
      "ask" => "nexus.human", "nexus.human.ask" => "nexus.human" }.each do |name, namespace|
      refused = refusal(entry(name))
      assert_equal "reserved_namespace", refused.code, name
      assert_equal "tools[0].name names a reserved kernel namespace (#{namespace})", refused.detail, name
    end
  end

  # A tool announcement cannot claim the reserved `nexus.conversation` namespace, regardless of
  # whether that particular name is currently registered.
  test "a kernel name under a reserved namespace is refused reserved_namespace" do
    %w[spawn nexus.conversation.spawn send status cancel].each do |name|
      refused = refusal(entry(name))
      assert_equal "reserved_namespace", refused.code, name
      assert_includes refused.detail, "(nexus.conversation)", name
    end
  end

  test "an overridable kernel wire name is admitted and stored as announced" do
    %w[memory_read memory_write memory_edit memory_ls memory_grep memory_delete].each do |name|
      assert_nil refusal(entry(name)), name
      assert_equal [name], Door.canonical([entry(name)]).map { |stored| stored["name"] }
    end
  end

  # The kernel check precedes the format rule, so the DOTTED overridable
  # spelling passes the kernel gate and the FORMAT rule refuses it — a
  # node's `tool_name` carries the wire spelling, so a dotted row would
  # match nothing.
  test "the dotted spelling of an overridable name is refused by the format rule" do
    refused = refusal(entry("nexus.memory.read"))
    assert_equal "invalid_announcement", refused.code
    assert_includes refused.detail, "tools[0].name must match"
  end

  # The source-routed name is the second admitted class: an executor announcing documents must
  # announce `skill` too, because the kernel dispatches a load of its names to it as that row.
  test "the source-routed wire name skill is admitted and stored as announced" do
    assert_nil refusal(entry("skill"))
    assert_equal ["skill"], Door.canonical([entry("skill")]).map { |stored| stored["name"] }
    assert_equal "invalid_announcement", refusal(entry("nexus.skill.load")).code, "the dotted spelling: the format rule"
  end

  test "every kernel name in every spelling lands in exactly one of the three outcomes" do
    names = Registry::LIVE.keys + Registry::WIRE_ALIASES.keys
    outcomes = names.to_h { |name| [name, refusal(entry(name))&.code] }
    admitted, refused = outcomes.partition { |_name, code| code.nil? }
    assert_equal %w[memory_delete memory_edit memory_grep memory_ls memory_read memory_write skill],
      admitted.map(&:first).sort, "the overridable wire spellings and the source-routed one, and nothing else"
    assert_equal %w[invalid_announcement reserved_namespace], refused.map(&:last).uniq.sort
    refused.each do |name, code|
      canonical = Registry.resolve(name)
      expected =
        if Registry.reserved_namespace?(canonical) then "reserved_namespace"
        else "invalid_announcement"
        end
      assert_equal expected, code, name
    end
  end

  # ── the two declaration keys ─────────────────────────────────

  test "description and input_schema survive canonical and are absent when not announced" do
    schema = { "type" => "object", "properties" => { "path" => { "type" => "string" } } }
    stored = Door.canonical([
      entry("read", "description" => "Read a file", "input_schema" => schema, "colour" => "red"),
      entry("bash", "timeout_ms" => 30_000),
    ])

    assert_equal %w[bash read], stored.map { |item| item["name"] }
    read = stored.find { |item| item["name"] == "read" }
    assert_equal "Read a file", read.fetch("description")
    assert_equal schema, read.fetch("input_schema")
    assert_not read.key?("colour"), "a key outside the five is dropped"
    assert_equal %w[name effect_profile timeout_ms], stored.first.keys
  end

  test "a present description must be a non-empty string" do
    ["", "   ", 1, ["x"]].each do |description|
      refused = refusal(entry("read", "description" => description))
      assert_equal "invalid_announcement", refused.code, description.inspect
      assert_includes refused.detail, "tools[0].description", description.inspect
    end
    assert_nil refusal(entry("read", "description" => "Read a file"))
  end

  test "a present input_schema must be a JSON Schema object" do
    [[], "x", { "type" => "array" }, { "type" => "string" }, {}].each do |schema|
      refused = refusal(entry("read", "input_schema" => schema))
      assert_equal "invalid_announcement", refused.code, schema.inspect
      assert_includes refused.detail, "tools[0].input_schema", schema.inspect
    end
    assert_nil refusal(entry("read", "input_schema" => { "type" => "object" }))
  end

  test "the second entry's refusal names its own index" do
    refused = refusal(entry("read"), entry("bash", "description" => ""))
    assert_includes refused.detail, "tools[1].description"
  end

  # ── the environment document ────────────────────────────────────────────

  test "an environment is opaque: nil, an empty object and any object pass, a non-object is refused" do
    assert_nil Door.environment_refusal(nil)
    assert_nil Door.environment_refusal({})
    assert_nil Door.environment_refusal({ "root" => "/w", "fragments" => [{ "extension" => "x", "text" => "t" }] })
    [[], "x", 1].each do |document|
      refused = Door.environment_refusal(document)
      assert_equal "invalid_announcement", refused.code, document.inspect
      assert_equal "environment must be an object", refused.detail, document.inspect
    end
  end

  # ── the documents ─────────────────

  def document(name, description = "How this project is deployed.") = { "name" => name, "description" => description }

  test "the document entry shape is exactly name and description" do
    assert_equal %w[name description], Door::DOCUMENT_KEYS
  end

  test "documents are none when absent, judged when present, and stored canonical by name" do
    assert_nil Door.document_refusal(nil)
    assert_nil Door.document_refusal([])
    assert_nil Door.document_refusal([document("deploy-notes"), document("commit-style")])
    assert_equal [], Door.canonical_documents(nil)
    assert_equal [document("commit-style"), document("deploy-notes")],
      Door.canonical_documents([document("deploy-notes").merge("kind" => "skill"), document("commit-style")]),
      "sorted by name, reduced to the two keys — no kind"
  end

  test "a document's name is judged by the skill grammar and met once" do
    ["PDF", "skills/pdf", "a/b", "-a", "a--b", "a_b", "", "a" * 65, nil, 1].each do |name|
      refused = Door.document_refusal([document(name)])
      assert_equal "invalid_announcement", refused.code, name.inspect
      assert_includes refused.detail, "documents[0].name must match", name.inspect
    end
    assert_nil Door.document_refusal([document("a" * 64), document("a-1")])

    refused = Door.document_refusal([document("deploy-notes"), document("deploy-notes", "twice")])
    assert_equal "documents[1].name repeats deploy-notes", refused.detail
  end

  test "a document's description is a non-empty string within the grammar's byte bound" do
    [nil, "", " ", 1, []].each do |description|
      refused = Door.document_refusal([document("deploy-notes", description)])
      assert_equal "invalid_announcement", refused.code, description.inspect
      assert_equal "documents[0].description must be a non-empty string", refused.detail, description.inspect
    end
    assert_nil Door.document_refusal([document("deploy-notes", "é" * (Nexus::Skills::DESCRIPTION_MAX_LENGTH / 2))])
    refused = Door.document_refusal([document("deploy-notes", "é" * (Nexus::Skills::DESCRIPTION_MAX_LENGTH / 2 + 1))])
    assert_equal "documents[0].description exceeds #{Nexus::Skills::DESCRIPTION_MAX_LENGTH} bytes", refused.detail
  end

  test "the documents list is a list of objects, named by index" do
    refused = Door.document_refusal({ "name" => "x" })
    assert_equal "documents must be a list of entries", refused.detail
    refused = Door.document_refusal([document("deploy-notes"), "commit-style"])
    assert_equal "documents[1] must be an object", refused.detail
  end
end
