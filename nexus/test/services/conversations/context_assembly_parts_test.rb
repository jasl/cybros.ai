require "test_helper"

# THE PART TAIL: a Segment carries its person's words and pictures in the order written; merges
# concatenate part lists, replayed text leads the first text part, a picture alone is still a
# message; placement is decided where the segments are built against ONE predicate from the
# selection — native on a row that takes the type, the index line IN POSITION on one that cannot;
# the fill cost funds a native picture at the wire's declared price.
class Conversations::ContextAssemblyPartsTest < ActiveSupport::TestCase
  Assembly = Conversations::ContextAssembly
  Segment = Assembly::Segment
  Line = Assembly::AttachmentLine

  PNG = Base64.decode64(
    "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg=="
  )

  setup do
    @account = accounts(:cybros)
    @workspace = workspaces(:shared)
    @user = users(:member)
    DevModelLane.ensure_enabled!(@account)
    @conversation = Conversation.create!(workspace: @workspace, creating_user: @user)
  end

  def upload(filename, content_type: "image/png")
    @account.content_uploads.create!(
      creating_user: @user,
      file: ActiveStorage::Blob.create_and_upload!(
        io: StringIO.new(PNG), filename: filename, content_type: content_type, identify: false
      )
    )
  end

  def picture(upload) = Segment::Attachment.new(upload: upload)
  def text(words) = Segment.text_part(words)
  def segment(role, *parts) = Segment.plain(role, nil, parts: parts)

  def merged(*segments) = Assembly.send(:merge_adjacent_roles, segments)
  def materialized(*segments) = Assembly.send(:materialize, merged(*segments))
  def wire(message) = message.parts.map { |part| part.type == "upload" ? [:upload, part.upload_public_id] : [:text, part.text] }

  test "two merged user segments keep each picture beside its words" do
    one = upload("one.png")
    two = upload("two.png")
    seed = segment("user", text("the diagram below"), picture(one))
    input = segment("user", text("and this one"), picture(two))

    messages = materialized(seed, input)

    assert_equal 1, messages.length, "adjacent same-role segments merge into one wire message"
    assert_equal [[:text, "the diagram below"], [:upload, one.public_id], [:text, "and this one"], [:upload, two.public_id]],
      wire(messages.sole), "occurrence order survives the merge: no picture drifts past the next words"
  end

  # A round's several user items ride the loop lane as several messages and the wire merges them
  # into one of several blocks; history merging the same items must land on the same blocks, so a
  # seam never folds two texts into one.
  test "texts meeting at a merge seam stay their own parts: the wire merges, nothing folds" do
    first = merged(Segment.plain("user", "a"), Segment.plain("user", "b")).sole
    assert_equal [text("a"), text("b")], first.parts
    assert_equal "a\n\nb", first.text, "reading the words still joins them as merged texts read"

    around = merged(segment("user", text("a"), picture(upload("p.png"))), Segment.plain("user", "b")).sole
    assert_equal %w[text upload text], around.parts.map(&:type)

    blank = materialized(Segment.plain("user", "a"),
      Segment.round("user", "", calls: [], trailing: [], first_slot: nil, results: [])).sole
    assert_equal [[:text, "a"]], wire(blank), "a blank text at the seam contributes nothing to the wire"
  end

  test "a picture with no words is a message; a blank text alone is none" do
    only = materialized(segment("user", picture(upload("alone.png"))))
    assert_equal 1, only.length
    assert_equal %w[upload], only.sole.parts.map(&:type)

    assert_empty materialized(Segment.plain("user", ""))
    assert_empty materialized(segment("user"))
  end

  # A SEGMENT CARRYING REPLAYED REASONING NEVER MERGES, on either side: under the default every
  # round's reasoning rides as the request that first carried it did, and a merge would move a later
  # segment's thinking ahead of the earlier words (concatenated parts) or keep only one side's items
  # — both edits of what an earlier request sent.
  test "a segment carrying replayed reasoning never merges with a neighbour, on either side" do
    thinking = Nexus::ReasoningInputPart.new(type: Nexus::InputParts::REASONING,
      payload: { "type" => "thinking", "thinking" => "plan", "signature" => "sig" })
    item = Nexus::ReasoningInputItem.new(type: "reasoning_item",
      payload: { "type" => "reasoning", "encrypted_content" => "blob", "summary" => [] })
    plain = Segment.plain("assistant", "earlier words")
    parts = Segment.plain("assistant", "later words").with(reasoning_parts: [thinking])
    items = Segment.plain("assistant", "later words").with(reasoning_items: [item])

    assert_equal 2, merged(plain, parts).length, "thinking never moves ahead of the earlier words"
    assert_equal 2, merged(parts, plain).length
    assert_equal 2, merged(plain, items).length, "no side's items are dropped"
    assert_equal 2, merged(items, plain).length
    assert_equal 1, merged(plain, Segment.plain("assistant", "more words")).length, "plain neighbours still merge"
  end

  test "the placed set is the distinct native rows in first-occurrence order, never the lines" do
    one = upload("one.png")
    two = upload("two.png")
    carries = Line.carries_for(DevModelLane.selection(workload: "text_generation", account: @account))
    segments = [
      Segment.plain("user", nil, parts: [text("a")] + Line.parts([two, one, two], carries: carries)),
      Segment.plain("assistant", "reply"),
      Segment.plain("user", nil, parts: Line.parts([one], carries: carries)),
    ]
    assembled_uploads = Assembly.send(:placed_uploads, segments)

    assert_equal [two, one].map(&:public_id), assembled_uploads.map(&:public_id)
  end

  # PLACEMENT (must-fix #5): one predicate from the selection — the
  # workload's modality, the row's `input_modalities`, the wire's allowlist.
  test "a vision row keeps the part; a text-only row gets the line in position; an allowlist miss names the type" do
    vision = Line.carries_for(DevModelLane.selection(workload: "text_generation", account: @account))
    text_only = Line.carries_for(DevModelLane.selection(workload: "text_generation", account: @account,
      model: "dev/mock-text-only"))
    diagram = upload("diagram.png")
    heic = upload("photo.heic", content_type: "image/heic")

    native = Line.parts([diagram], carries: vision)
    assert_equal [Segment::Attachment.new(upload: diagram)], native

    lined = Line.parts([diagram], carries: text_only)
    assert_equal [text("[Attachment: diagram.png (image/png, 70 bytes) — image content omitted: this model does not support image input]")], lined,
      "the index line, the design's spelling: filename, type, delimited bytes, the reason"

    refused_type = Line.parts([heic], carries: vision)
    assert_equal [text("[Attachment: photo.heic (image/heic, 70 bytes) — this model does not take image/heic]")],
      refused_type, "the row takes images; the OpenAI wire's allowlist does not take HEIC"

    assert_equal [Segment::Attachment.new(upload: heic)], Line.parts([heic], carries: nil),
      "nil keeps every part: the estimate's and history's read with no selection"
  end

  test "the loop lane's placement rewrites upload parts in place and answers the rows still placed" do
    one = upload("one.png")
    two = upload("two.png")
    message = Nexus::TextInputMessage.new(role: "user", parts: [
      text("look"),
      Nexus::UploadInputPart.new(type: "upload", upload_public_id: one.public_id),
      Nexus::UploadInputPart.new(type: "upload", upload_public_id: two.public_id),
      Nexus::UploadInputPart.new(type: "upload", upload_public_id: one.public_id),
    ])
    text_only = Line.carries_for(DevModelLane.selection(workload: "text_generation", account: @account,
      model: "dev/mock-text-only"))

    messages, placed = Line.place([message], [one, two], carries: text_only)
    assert_empty placed
    assert_equal %w[text text text text], messages.sole.parts.map(&:type)
    assert_includes messages.sole.parts[1].text, "one.png"

    kept, rows = Line.place([message], [one, two], carries: nil)
    assert_equal wire(message), wire(kept.sole)
    assert_equal [one, two].map(&:public_id), rows.map(&:public_id), "distinct, first occurrence"
  end

  # THE FILL COST (r2 Q-A2): a native picture is priced at the wire's own
  # per-image figure, 0 where the register says the host's accounting is
  # not knowable; the line is text and priced as text.
  test "FillCost.attachment reads the wire's declared token cost per profile, and the segment sums it" do
    dev = DevModelLane.profile_for("dev/mock-text")
    assert_equal 2500, Assembly::FillCost.attachment(dev), "the dev lane speaks openai_responses"
    facts = lambda do |token_cost|
      SimpleInference::ExecutionProfile::InputMediaFacts.from_h("image",
        { "mime_allowlist" => ["image/png"], "max_dimension" => 1568, "token_cost" => token_cost }.compact)
    end
    assert_equal 3279, Assembly::FillCost.attachment(dev.with(input_media: { "image" => facts.call(3279) }))
    assert_equal 258, Assembly::FillCost.attachment(dev.with(input_media: { "image" => facts.call(258) }))
    assert_equal 0, Assembly::FillCost.attachment(dev.with(input_media: { "image" => facts.call(nil) })),
      "the OpenRouter/OpenAI-compatible wires declare no cost: not knowable from here"
    assert_equal 0, Assembly::FillCost.attachment(dev.with(input_media: {}))
    assert_equal 0, Assembly::FillCost.attachment(nil)

    one = upload("one.png")
    with_picture = segment("user", text("x" * 40), picture(one))
    words_only = segment("user", text("x" * 40))
    assert_equal Assembly::FillCost.segment(words_only, dev) + 2500, Assembly::FillCost.segment(with_picture, dev)
  end

  # ── the guards through history (must-fix #7) ─────────────────────────

  def settle_turn!(text, position:, kind: "message", role: "user", uploads: [], readable_text: nil, prompt: nil)
    turn = ConversationTurn.create!(
      account: @account, conversation: @conversation, position: position,
      kind: kind, role: role, status: "completed",
      speaker_actor: Actors::Resolve.member(account: @account, user: @user),
      control_owner_user: @user, visibility: "visible"
    )
    variant = ConversationTurnVariant.create!(
      account: @account, conversation_turn: turn, position: 0, status: "completed", source: "manual"
    )
    entries = uploads.empty? ? [{ "text" => text }] : [{
      "role" => "user",
      "parts" => (text.empty? ? [] : [{ "type" => "text", "text" => text }]) +
        uploads.map { |u| { "type" => "upload", "upload_public_id" => u.public_id } },
    }]
    ContentBodies::Replace.call(owner: variant, role: "content", entries: entries, uploads: uploads,
      readable_text: readable_text, seal: true)
    if prompt
      ContentBodies::Replace.call(owner: variant, role: "prompt", **prompt, seal: true)
    end
    turn.update!(active_variant: variant)
    @conversation.reload.update!(timeline_position_head: position + 1)
    turn
  end

  test "a picture-only message turn and a picture-only seed reach later history; a text-only row reads the lines" do
    alone = upload("alone.png")
    settle_turn!("", position: 0, uploads: [alone], readable_text: "")
    seed_picture = upload("seed.png")
    seed_entries = [{ "role" => "user", "parts" => [{ "type" => "upload", "upload_public_id" => seed_picture.public_id }] }]
    settle_turn!("the answer", position: 1, kind: "direct_reply", role: "assistant",
      prompt: { entries: seed_entries, uploads: [seed_picture], readable_text: "" })

    history = Assembly::ChatHistory.call(conversation: @conversation)
    assert_equal [%w[upload], %w[upload], %w[text]], history.segments.map { |s| s.parts.map(&:type) },
      "the message turn's picture, the reply's picture-only seed, then the reply — none dropped as blank"
    assert_equal [alone, seed_picture].map(&:public_id),
      history.segments.first(2).map { |s| s.attachments.sole.upload.public_id }

    text_only = Line.carries_for(DevModelLane.selection(workload: "text_generation", account: @account,
      model: "dev/mock-text-only"))
    lined = Assembly::ChatHistory.call(conversation: @conversation, carries: text_only)
    assert_equal [%w[text], %w[text], %w[text]], lined.segments.map { |s| s.parts.map(&:type) }
    assert_match(/\A\[Attachment: alone\.png \(image\/png, 70 bytes\) — image content omitted: this model does not support image input\]\z/,
      lined.segments.first.text)

    assembled = Assembly.assemble(conversation: @conversation, principal: @user, prompt: "and now?")
    assert_equal [%w[upload upload], %w[text], %w[text]], assembled.messages.map { |m| m.parts.map(&:type) },
      "the message turn and the next reply's seed are adjacent user segments: one wire message, both pictures"
    assert_equal [alone, seed_picture].map(&:public_id), assembled.uploads.map(&:public_id)
  end

  test "a raw seed with no readable text renders nothing, pictures included" do
    raw_picture = upload("raw.png")
    seed_entries = [{ "role" => "user", "parts" => [
      { "type" => "text", "text" => "verbatim" },
      { "type" => "upload", "upload_public_id" => raw_picture.public_id },
    ] }]
    settle_turn!("the answer", position: 0, kind: "direct_reply", role: "assistant",
      prompt: { entries: seed_entries, uploads: [raw_picture] })

    history = Assembly::ChatHistory.call(conversation: @conversation)
    assert_equal [%w[text]], history.segments.map { |s| s.parts.map(&:type) }, "raw is never enriched: no seed"
  end

  test "the input's own pictures ride the assembled prompt, funded ahead of history" do
    one = upload("one.png")
    settle_turn!("older", position: 0)
    profile = DevModelLane.profile_for("dev/mock-text")
    limits = DevModelLane.selection(workload: "text_generation", account: @account).capabilities.limits

    with_picture = Assembly.assemble(conversation: @conversation, principal: @user, prompt: "look",
      attachments: [one], profile: profile, limits: limits)
    words_only = Assembly.assemble(conversation: @conversation, principal: @user, prompt: "look",
      profile: profile, limits: limits)

    assert_equal [%w[text text upload]], with_picture.messages.map { |m| m.parts.map(&:type) },
      "the older user turn and the prompt merge; the picture stays beside the prompt's words"
    assert_equal %w[older look], with_picture.messages.sole.parts.first(2).map(&:text)
    assert_equal [one.public_id], with_picture.uploads.map(&:public_id)
    assert_empty words_only.uploads

    alone = Assembly.assemble(conversation: @conversation, principal: @user, prompt: nil, attachments: [one])
    assert_equal %w[text upload], alone.messages.last.parts.map(&:type), "a picture with no words is the input"
    assert_equal "older", alone.messages.last.parts.first.text, "merged behind the older user turn, nothing else"
  end
end
