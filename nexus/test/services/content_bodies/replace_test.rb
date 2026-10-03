require "test_helper"
require_relative "../../test_helpers/row_lock_test_helper"

# The first writer allowed to persist a ContentBody. Its reason for existing is reuse: an agentic
# loop re-sends most of its prompt every turn, and only per-message decomposition onto
# content-addressed fragments keeps stored bytes linear in unique content.
class ContentBodies::ReplaceTest < ActiveSupport::TestCase
  include RowLockTestHelper

  # The overlapping-writers proof needs two real connections, which the
  # wrapping test transaction would hide from each other.
  uses_transaction :test_a_same_digest_race_adopts_the_winner_without_poisoning_the_outer_transaction,
    :test_a_stale_orphan_is_pinned_before_its_new_entry_is_inserted,
    :test_two_bodies_taking_the_same_new_fragments_in_opposite_order_both_commit,
    :test_two_first_writes_for_one_owner_and_role_serialize_on_the_owner

  setup do
    @account = accounts(:cybros)
  end

  def replace(owner: one_shot, role: "input", entries: [], uploads: [], seal: false, readable_text: nil)
    ContentBodies::Replace.call(
      owner: owner, role: role, entries: entries, uploads: uploads, seal: seal, readable_text: readable_text
    )
  end

  test "a body decomposes one entry per message and reuses every unchanged fragment" do
    prefix = [{ "role" => "user", "text" => "one" }, { "role" => "assistant", "text" => "two" }]

    first = replace(entries: prefix)
    assert_predicate first, :accepted?
    assert_equal 2, first.body.content_body_entries.count

    prefix_fragment_ids = first.body.content_body_entries.map(&:content_fragment_id)

    # The next turn re-sends the same prefix plus one new message. Only the new
    # message may become a new fragment, and the prefix must land on the SAME
    # rows — a count assertion alone cannot tell reuse from flattening, since
    # a flattened body would also add exactly one (different) fragment.
    second = nil
    assert_difference -> { ContentFragment.count }, +1 do
      second = replace(
        owner: create_one_shot,
        entries: prefix + [{ "role" => "user", "text" => "three" }]
      )
      assert_predicate second, :accepted?
    end

    reused = second.body.content_body_entries.map(&:content_fragment_id)
    assert_equal 3, reused.length, "one entry per message, never one flattened payload"
    assert_equal prefix_fragment_ids, reused.first(2),
      "the unchanged prefix must reference the fragments it already stored"
    assert_not_includes prefix_fragment_ids, reused.last
  end

  test "one canonical address is reused for every occurrence of a payload" do
    payload = { "role" => "user", "text" => "same" }
    calls = []
    address_for = Nexus::ContentAddress.method(:for)

    result = Nexus::ContentAddress.stub(:for, lambda { |**arguments|
      calls << arguments
      address_for.call(**arguments)
    }) do
      replace(entries: [payload, payload])
    end

    assert_predicate result, :accepted?
    assert_equal 1, calls.count
    assert_equal 2, result.body.content_body_entries.count
    assert_equal 1, result.body.content_body_entries.distinct.count(:content_fragment_id)
  end

  test "fragment persistence uses a constant pair of locked fetches around one bulk insert" do
    owner = create_one_shot
    owner.lock!
    entries = Array.new(64) do |index|
      { "role" => "user", "text" => "bulk fragment #{index}" }
    end
    statements = []
    subscriber = lambda do |_name, _started, _finished, _unique_id, payload|
      unless payload[:cached] || payload[:name] == "SCHEMA"
        statements << payload[:sql].to_s
      end
    end
    connection = ApplicationRecord.lease_connection
    connection.clear_query_cache
    connection.materialize_transactions

    result = ActiveSupport::Notifications.subscribed(
      subscriber, "sql.active_record"
    ) do
      replace(owner: owner, entries: entries, seal: true)
    end

    fragment_statements = statements.grep(/\bcontent_fragments\b/)
    assert_predicate result, :accepted?
    assert_equal 3, fragment_statements.length,
      "fragment SQL must remain constant as entry count grows"
    assert_match(/\ASELECT .* FROM "content_fragments"/, fragment_statements.first)
    assert_match(/ORDER BY "content_fragments"\."digest" ASC FOR KEY SHARE\z/,
      fragment_statements.first)
    assert_match(/\AINSERT INTO "content_fragments"/, fragment_statements.second)
    assert_match(/ON CONFLICT \("account_id","digest"\) DO NOTHING/, fragment_statements.second)
    assert_match(/\ASELECT .* FROM "content_fragments"/, fragment_statements.third)
    assert_match(/ORDER BY "content_fragments"\."digest" ASC FOR KEY SHARE\z/,
      fragment_statements.third)
    assert_empty statements.grep(/\ADELETE FROM/),
      "create-and-seal must not delete from an empty aggregate"
    assert_equal 1, statements.grep(/\AUPDATE "content_bodies"/).length,
      "projection and seal commit in one body update"
  end

  # A stale orphan already past its grace must survive the gap between its
  # identity lookup and the new reference. Pause before the entry INSERT and
  # prove the preceding key-share read pins that exact row until commit,
  # including when the request needs no new fragment.
  def test_a_stale_orphan_is_pinned_before_its_new_entry_is_inserted
    payload = { "text" => "stale-adoption-#{SecureRandom.hex(4)}" }
    address = Nexus::ContentAddress.for(account_id: @account.id, payload: payload)
    fragment = @account.content_fragments.create!(payload: payload, digest: address.digest)
    ContentFragment.where(id: fragment.id).update_all(created_at: 50.years.ago)
    owner = create_one_shot
    @stale_adoption_owner_id = owner.id
    @stale_adoption_fragment_id = fragment.id

    reached_entry_insert = Queue.new
    release_entry_insert = Queue.new
    insert_all = ContentBodyEntry.method(:insert_all!)
    writer = start_database_call do
      ContentBodyEntry.stub(:insert_all!, lambda { |rows, **options|
        reached_entry_insert << true
        release_entry_insert.pop
        insert_all.call(rows, **options)
      }) do
        ContentBody.transaction do
          locked_owner = OneShot.lock.find(@stale_adoption_owner_id)
          ContentBodies::Replace.call(
            owner: locked_owner, role: "input", entries: [payload], seal: true
          ).body.content_body_entries.sole.content_fragment_id
        end
      end
    end
    Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { reached_entry_insert.pop }

    reaper = start_database_call { ContentFragment.reap(batch: 1) }
    wait_until_transitively_blocked_by(writer.pid, reaper.pid)
    release_entry_insert << true

    assert_equal fragment.id, finish_database_call(writer),
      "the writer must adopt the original fragment rather than recreate a reaped row"
    writer = nil
    result = finish_database_call(reaper)
    reaper = nil

    assert_equal 1, result[:scanned]
    assert_equal 0, result[:reaped]
    assert ContentFragment.exists?(fragment.id),
      "the fragment must stay pinned until its new reference commits"
  ensure
    release_entry_insert << true if writer&.thread&.alive?
    stop_database_call(reaper) if reaper
    stop_database_call(writer) if writer
    ContentBody.where(one_shot_id: @stale_adoption_owner_id).delete_all
    OneShot.where(id: @stale_adoption_owner_id).delete_all
    ContentFragment.where(id: @stale_adoption_fragment_id).delete_all
  end

  # T1 holds an uncommitted unique-index winner while T2 reuses an existing prefix
  # and blocks inserting the missing payload. Once T1 commits, T2 adopts that row
  # through its locked fetch and keeps its enclosing transaction usable.
  def test_a_same_digest_race_adopts_the_winner_without_poisoning_the_outer_transaction
    prefix_payload = { "text" => "retained-#{SecureRandom.hex(4)}" }
    payload = { "text" => "raced-#{SecureRandom.hex(4)}" }
    proof_payload = { "text" => "post-race-#{SecureRandom.hex(4)}" }
    prefix_fragment = create_fragment(@account, prefix_payload)
    owner = create_one_shot
    @same_digest_owner_id = owner.id
    winner_inserted = Queue.new
    winner_release = Queue.new

    winner = start_database_call do
      ContentFragment.transaction do
        account = Account.find(@account.id)
        fragment = create_fragment(account, payload)
        winner_inserted << fragment.id
        winner_release.pop
        fragment.id
      end
    end
    winner_id = Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { winner_inserted.pop }

    loser = start_database_call do
      account = Account.find(@account.id)
      ContentBody.transaction do
        locked_owner = OneShot.lock.find(@same_digest_owner_id)
        result = ContentBodies::Replace.call(
          owner: locked_owner, role: "input", entries: [prefix_payload, payload], seal: true
        )
        proof = create_fragment(account, proof_payload)
        adopted_ids = result.body.content_body_entries.pluck(:content_fragment_id)
        [adopted_ids, proof.id]
      end
    end

    wait_until_waiting_on_lock(loser.pid)
    winner_release << true

    assert_equal winner_id, finish_database_call(winner)
    adopted_ids, proof_id = finish_database_call(loser)
    assert_equal [prefix_fragment.id, winner_id], adopted_ids,
      "the loser keeps the existing prefix and adopts the committed identical row"
    assert ContentFragment.exists?(proof_id),
      "the outer transaction remains writable after its unique-index loser"
  ensure
    winner_release << true if winner&.thread&.alive?
    stop_database_call(loser) if loser
    stop_database_call(winner) if winner
    ContentBody.where(one_shot_id: @same_digest_owner_id).delete_all
    OneShot.where(id: @same_digest_owner_id).delete_all
    [prefix_payload, payload, proof_payload].compact.each do |fragment_payload|
      address = Nexus::ContentAddress.for(account_id: @account.id, payload: fragment_payload)
      ContentFragment.where(account: @account, digest: address.digest).delete_all
    end
  end

  # Two uncommitted unique-index winners make both writers prove their
  # acquisition order before either can proceed: each must wait on the smaller
  # digest first, then the larger. Submitted order would split them across the
  # two holders and fail at the first barrier.
  test "two bodies taking the same new fragments in opposite order both commit" do
    account = Account.first
    workspace = account.workspaces.first
    creator = account.users.find_by(kind: "human")
    shared = [
      { "text" => "P-#{SecureRandom.hex(4)}" },
      { "text" => "Q-#{SecureRandom.hex(4)}" },
    ]
    @concurrent_fragment_account_id = account.id
    @concurrent_fragment_digests = shared.map do |payload|
      Nexus::ContentAddress.for(account_id: account.id, payload: payload).digest
    end
    # Registered before use: a non-transactional test must be able to clean up
    # rows even when an assertion between here and `ensure` fails.
    @created_one_shots = []
    owners = 2.times.map do
      OneShot.create!(
        account: account, workspace: workspace, creating_user: creator,
        workload: "text_generation"
      ).tap { |owner| @created_one_shots << owner }
    end

    holders = []
    shared.each do |payload|
      inserted = Queue.new
      release = Queue.new
      call = start_database_call do
        signaled = false
        ContentFragment.transaction do
          fragment = create_fragment(Account.find(account.id), payload)
          signaled = true
          inserted << fragment.id
          release.pop
          fragment.id
        end
      rescue StandardError => error
        inserted << error unless signaled
        raise
      end
      holder = {
        digest: Nexus::ContentAddress.for(account_id: account.id, payload: payload).digest,
        call: call,
        release: release,
      }
      holders << holder
      state = Timeout.timeout(ROW_LOCK_WAIT_TIMEOUT) { inserted.pop }
      raise state if state.is_a?(Exception)
    end
    holders.sort_by! { |holder| holder.fetch(:digest) }

    calls = []
    [shared, shared.reverse].each_with_index do |entries, index|
      calls << start_database_call do
        ContentBodies::Replace.call(
          owner: OneShot.find(owners[index].id), role: "input",
          entries: entries, uploads: [], seal: false
        )
      end
    end

    holders.each do |holder|
      wait_until_transitively_blocked_by(holder.fetch(:call).pid, *calls.map(&:pid))
      holder.fetch(:release) << true
      finish_database_call(holder.fetch(:call))
    end
    holders = []
    results = calls.map { |call| finish_database_call(call) }
    calls = []

    assert results.all? { |result| result&.accepted? },
      "opposite submission order must not deadlock either writer"
    assert_equal 2, ContentFragment.where(account: account)
      .where("payload->>'text' like 'P-%' or payload->>'text' like 'Q-%'").count,
      "each distinct payload is stored exactly once"
    assert_equal shared.reverse.map { |p| p["text"] },
      owners[1].content_bodies.sole.content_body_entries.map { |e| e.content_fragment.payload["text"] },
      "submitted position order survives digest-order resolution"
  ensure
    # A non-transactional test owns its own cleanup, and only its own rows:
    # a blunt delete_all here would take fixture-adjacent data with it and
    # strand foreign keys the next test depends on.
    Array(holders).each do |holder|
      holder.fetch(:release) << true if holder.fetch(:call).thread.alive?
    end
    Array(holders).each { |holder| stop_database_call(holder.fetch(:call)) }
    Array(calls).each { |call| stop_database_call(call) }
    Array(@created_one_shots).each do |owner|
      ContentBody.where(one_shot: owner).delete_all
      OneShot.where(id: owner.id).delete_all
    end
    ContentFragment.where(
      account_id: @concurrent_fragment_account_id,
      digest: Array(@concurrent_fragment_digests)
    ).delete_all
  end

  # Upload is the next explicit rank after Fragment. Holding the smaller row
  # makes both writers queue there; a submitted-order writer would instead
  # let the reverse request hold the larger row and form an ABBA cycle when
  # the smaller row is released.
  # There is deliberately no owner-role unique index behind this invariant.
  # Both callers begin before a Body exists and queue on the same owner row;
  # whichever wins may write first, but the loser must then replace that Body
  # rather than form a second singleton.
  def test_two_first_writes_for_one_owner_and_role_serialize_on_the_owner
    owner = create_one_shot
    @first_write_owner_id = owner.id
    payloads = [
      { "text" => "first-#{SecureRandom.hex(4)}" },
      { "text" => "second-#{SecureRandom.hex(4)}" },
    ]
    @first_write_fragment_digests = payloads.map do |payload|
      Nexus::ContentAddress.for(account_id: @account.id, payload: payload).digest
    end

    held = hold_row_lock(OneShot, owner.id)
    calls = payloads.map do |payload|
      start_database_call do
        ContentBodies::Replace.call(
          owner: OneShot.find(owner.id), role: "input",
          entries: [payload], uploads: [], seal: false
        )
      end
    end

    wait_until_waiting_on_lock(*calls.map(&:pid))
    release_row_lock(held)
    held = nil
    results = calls.map { |call| finish_database_call(call) }
    calls = []

    assert results.all?(&:accepted?), "both serialized writes must commit"
    bodies = ContentBody.where(one_shot_id: owner.id, role: "input")
    assert_equal 1, bodies.count, "the owner-role pair remains a singleton"
    assert_equal [bodies.sole.id], results.map { |result| result.body.id }.uniq,
      "both writers must resolve to the same Body row"

    final_payload = bodies.sole.content_body_entries.sole.content_fragment.payload
    assert_includes payloads, final_payload,
      "the final value must match one of the two allowed serial orders"
  ensure
    begin
      release_row_lock(held) if held
    ensure
      Array(calls).each { |call| stop_database_call(call) }
      bodies = ContentBody.where(one_shot_id: @first_write_owner_id)
      bodies.delete_all
      OneShot.where(id: @first_write_owner_id).delete_all
      ContentFragment.where(
        account_id: @account.id,
        digest: Array(@first_write_fragment_digests)
      ).delete_all
    end
  end

  test "replacement swaps the whole entry set atomically and keeps position order" do
    body = replace(entries: [{ "text" => "a" }, { "text" => "b" }]).body

    result = replace(entries: [{ "text" => "c" }])

    assert_predicate result, :accepted?
    assert_equal body.id, result.body.id, "one role per owner: replacement reuses the body"
    assert_equal [0], result.body.content_body_entries.reload.map(&:position)
    assert_equal 1, result.body.content_body_entries.count
  end

  test "sealing is write-once and closes the body to further replacement" do
    sealed = replace(entries: [{ "text" => "a" }], seal: true)
    assert_predicate sealed, :accepted?
    assert_predicate sealed.body, :sealed?

    refused = replace(entries: [{ "text" => "b" }])
    assert_not_predicate refused, :accepted?
    assert_equal :body_sealed, refused.refusal

    first_seal = sealed.body.sealed_at
    sealed.body.update(sealed_at: 1.day.from_now)
    assert_equal first_seal, sealed.body.reload.sealed_at, "a seal is a fact, not a settable field"
  end

  test "a sealed body's projected text cannot be rewritten" do
    result = replace(entries: [{ "text" => "original" }], seal: true)
    assert_predicate result, :accepted?

    body = result.body
    original_text = body.readable_text

    assert_not body.update(readable_text: "rewritten")
    assert_equal original_text, body.reload.readable_text
  end

  # Check the newly formed aggregate exactly once, at the boundary that forms it — which is here,
  # not in a model callback.
  test "the formed aggregate is bounded by count and by bytes" do
    too_many = Array.new(Nexus::SizeBounds.fetch(:body_entry_count_bound) + 1) { { "text" => "x" } }
    refused = replace(entries: too_many)
    assert_not_predicate refused, :accepted?
    assert_equal Nexus::SizeBounds::COUNT_REJECTION, refused.refusal

    oversize = [{ "text" => "x" * (Nexus::SizeBounds.fetch(:snapshot_bound) + 1) }]
    assert_equal Nexus::SizeBounds::REJECTION, replace(entries: oversize).refusal

    # Two entries that are each legal alone and jointly at the line, so only
    # the aggregate check can be the one that answers. One entry sized to the
    # bound would trip the per-entry check first and this would silently stop
    # testing the total.
    bound = Nexus::SizeBounds.fetch(:snapshot_bound)
    entry_overhead = Nexus::SizeBounds.json_bytesize("text" => "")
    half = "x" * (bound / 2 - entry_overhead)
    boundary = replace(
      owner: create_one_shot,
      entries: [{ "text" => half }, { "text" => half }]
    )

    assert_predicate boundary, :accepted?
    assert_equal "#{half}\n#{half}", boundary.body.effective_text,
      "sizing changed; the derived projection readers see did not"

    refused_owner = create_one_shot
    too_large = replace(
      owner: refused_owner,
      entries: [{ "text" => half }, { "text" => "#{half}x" }]
    )
    assert_equal Nexus::SizeBounds::REJECTION, too_large.refusal
    assert_not ContentBody.exists?(one_shot: refused_owner),
      "an oversize aggregate is rejected before any body row is formed"
  end

  # Uploads have their own count and byte bounds, with their own typed rejections.
  test "the formed aggregate is bounded by upload count and by referenced bytes" do
    small = upload
    too_many = Array.new(Nexus::SizeBounds.fetch(:body_upload_count_bound) + 1, small)

    assert_equal Nexus::SizeBounds::COUNT_REJECTION,
      replace(entries: [{ "text" => "a" }], uploads: too_many).refusal

    # Referenced bytes are counted once per binding, so one upload at several
    # positions costs several times — that is the referenced-bytes question,
    # not a dedup question.
    largest = upload
    bindings = (Nexus::SizeBounds.fetch(:body_upload_bytes_bound) /
      Nexus::SizeBounds.fetch(:upload_bound)) + 1

    largest.stub(:byte_size, Nexus::SizeBounds.fetch(:upload_bound)) do
      assert_equal Nexus::SizeBounds::REJECTION,
        replace(
          owner: create_one_shot, entries: [{ "text" => "a" }],
          uploads: Array.new(bindings, largest)
        ).refusal
    end
  end

  # The projection reads only a shape it owns; anything else leaves it null so the readable-text
  # fallback can still derive effective text from the fragments.
  test "readable text is projected from text payloads and null when there are none" do
    spoken = replace(entries: [{ "text" => "one" }, { "text" => "two" }])
    assert_equal "one\ntwo", spoken.body.readable_text

    structured = replace(
      owner: create_one_shot,
      entries: [{ "role" => "user", "parts" => [{ "type" => "text", "text" => "deep" }] }]
    )
    payload = structured.body.content_body_entries.sole.content_fragment.payload
    fallback = Nexus::CanonicalJson.encode(payload)
    assert_nil structured.body.readable_text,
      "a nested shape this projection does not own must not be mined for the word"
    assert_equal fallback, structured.body.effective_text
  end

  # A BODY'S BYTE SIZE IS A STORED FACT: the bytes of its effective text, stamped by the write that
  # forms the entries — whichever projection `effective_text` falls to — so compaction and the
  # presenters read a column and never load a body to measure it. The fragment keeps no measurement:
  # its canonical bytes are its payload.
  test "a body's byte size is stored at the write and equals its effective text under both projections" do
    spoken = replace(entries: [{ "text" => "one" }, { "text" => "two" }])
    assert_equal "one\ntwo".bytesize, spoken.body.byte_size
    assert_equal spoken.body.effective_text.bytesize, spoken.body.byte_size

    structured = replace(
      owner: create_one_shot, seal: true,
      entries: [
        { "role" => "user", "parts" => [{ "type" => "text", "text" => "日本語" }] },
        { "role" => "assistant", "parts" => [{ "type" => "text", "text" => "deep" }] },
      ]
    )
    assert_nil structured.body.readable_text
    assert_equal structured.body.effective_text.bytesize, structured.body.byte_size,
      "the canonical entries joined by a newline — the bytes the sealed request costs"
    assert_operator structured.body.byte_size, :>, "日本語deep".bytesize

    replaced = replace(entries: [{ "text" => "one, then more" }])
    assert_equal "one, then more".bytesize, replaced.body.reload.byte_size,
      "an unsealed replacement rewrites the size with the entries"

    assert_not_includes ContentFragment.column_names, "byte_size"
  end

  test "a sealed body's byte size is as immutable as its text" do
    sealed = replace(entries: [{ "text" => "fixed" }], seal: true).body
    assert_predicate sealed, :sealed?

    sealed.byte_size = 1
    assert_not sealed.valid?
    assert_includes sealed.errors.details.fetch(:byte_size).map { |detail| detail[:error] }, :readonly
  end

  test "effective text reuses preloaded entries and fragments" do
    payloads = [
      { "role" => "user", "parts" => [{ "type" => "text", "text" => "one" }] },
      { "role" => "assistant", "parts" => [{ "type" => "text", "text" => "two" }] },
    ]
    body_ids = payloads.map do |payload|
      replace(owner: create_one_shot, entries: [payload]).body.id
    end
    bodies = ContentBody.where(id: body_ids)
      .includes(content_body_entries: :content_fragment).order(:id).to_a

    assert_no_queries do
      assert_equal payloads.map { |payload| Nexus::CanonicalJson.encode(payload) },
        bodies.map(&:effective_text)
    end
  end

  test "upload replacement stores one liveness join per unique upload" do
    bound_upload = upload
    result = replace(
      entries: [{ "text" => "a" }],
      uploads: [bound_upload, bound_upload]
    )

    assert_predicate result, :accepted?
    assert_equal [bound_upload.id],
      result.body.content_body_uploads.pluck(:content_upload_id)
    assert_equal [result.body.id], bound_upload.content_bodies.pluck(:id)

    released = replace(entries: [{ "text" => "c" }], uploads: [])
    assert_predicate released, :accepted?
    assert_empty released.body.content_body_uploads
  end

  # THE WRITER'S WORD: a door writing a person's message says what its words are — never a
  # projection over the parts here, which would fire on every sealed request body and render an
  # assembled list as `User:`. `""` is a picture with no words; nil keeps the projection.
  test "readable_text is the writer's when given — the words, or the empty word — and projects otherwise" do
    picture = upload
    entry = { "role" => "user", "parts" => [
      { "type" => "text", "text" => "look" },
      { "type" => "upload", "upload_public_id" => picture.public_id },
    ] }

    said = replace(entries: [entry], uploads: [picture], readable_text: "look")
    assert_equal "look", said.body.readable_text
    assert_equal "look".bytesize, said.body.byte_size
    assert_equal "look", said.body.effective_text

    silent = replace(owner: create_one_shot, entries: [entry], uploads: [picture], readable_text: "")
    assert_equal "", silent.body.readable_text
    assert_equal 0, silent.body.byte_size, "the bytes effective_text answers: none"
    assert_equal "", silent.body.effective_text, "never the canonical entry"

    projected = replace(owner: create_one_shot, entries: [entry], uploads: [picture])
    assert_nil projected.body.readable_text, "no writer's word: the top-level projection, nil for a parts entry"
    assert_equal Nexus::CanonicalJson.encode(entry), projected.body.effective_text
  end

  # THE UPLOAD-BYTES BOUND IS A DOOR'S: a composed request — the invocation's `request`, the loop
  # seed sealed as `composed` — binds the placed set history's doors already bounded and is never
  # refused for their sum, or 65 turns of phone photos would refuse turn 66's seal.
  test "the upload-bytes bound is not checked on the request role or a composed seed" do
    largest = upload
    bindings = (Nexus::SizeBounds.fetch(:body_upload_bytes_bound) /
      Nexus::SizeBounds.fetch(:upload_bound)) + 1
    invocation = ModelInvocation.create!(
      one_shot: create_one_shot, provider_id: "dev", model_ref: "mock-text",
      request_options: {}, admission_deadline_seconds: 60
    )

    largest.stub(:byte_size, Nexus::SizeBounds.fetch(:upload_bound)) do
      assert_equal Nexus::SizeBounds::REJECTION,
        replace(owner: create_one_shot, entries: [{ "text" => "a" }], uploads: Array.new(bindings, largest)).refusal,
        "a person's message is bounded"
      sealed = replace(owner: invocation, role: "request", entries: [{ "text" => "a" }],
        uploads: Array.new(bindings, largest), seal: true)
      assert_predicate sealed, :accepted?, "the request role is not"
      composed = ContentBodies::Replace.call(owner: create_one_shot, role: "input", entries: [{ "text" => "a" }],
        uploads: Array.new(bindings, largest), composed: true, seal: true)
      assert_predicate composed, :accepted?, "nor a composed seed under another role"
    end
  end

  private

    def one_shot
      @one_shot ||= create_one_shot
    end

    def create_one_shot
      OneShot.create!(
        account: @account, workspace: workspaces(:shared), creating_user: users(:member),
        workload: "text_generation"
      )
    end

    def upload
      bytes = "bytes-#{SecureRandom.hex(4)}"
      @account.content_uploads.create!(
        creating_user: users(:member),
        file: ActiveStorage::Blob.create_and_upload!(
          io: StringIO.new(bytes), filename: "a.txt", content_type: "text/plain"
        )
      )
    end

    def create_fragment(account, payload)
      address = Nexus::ContentAddress.for(account_id: account.id, payload: payload)
      account.content_fragments.create!(
        payload: payload, digest: address.digest
      )
    end
end
