# The aggregate root of the timeline plane: a position-ordered timeline of
# local Turns plus every ancestor's turns through the materialized fork
# closure. Fork never copies content; overrides carry the child's view-state.
# A SIDE conversation is a fork taken at the live head from the last settled
# turn, flagged so assembly renders what it inherited behind a boundary item:
# reference-only, hidden from the working list, reaped at once.
class Conversation < ApplicationRecord
  include Searchable

  validates :memory_context, memory_context: true
  include InputHost
  include EventHost
  include StoreHost

  # The frozen 30-day physical-reap clock a tombstone starts, mirroring
  # InferenceRequest::RETENTION_PERIOD — one number, named, on the model.
  RETENTION_PERIOD = 30.days

  # `answering_user_id` is create-frozen here; a handoff of the answerer is a
  # later verb that will drop it from this list.
  attr_readonly :account_id, :workspace_id, :creating_user_id, :answering_user_id, :public_id,
    :billing_subject_key, :billing_subject_public_id,
    :parent_conversation_public_id, :side, :spawn_node_id, :spawn_label,
    :schedule_public_id, :scheduled_for,
    :forked_from_turn_public_id, :forked_from_variant_public_id

  # THE CHILD LABEL: the name `spawn` gave this child, unique among one
  # parent's children — how `send`/`status`/ `cancel` may address it
  # beside the public id, which stays the wire's one truth. Normalized
  # at the door's edge: stripped, lowercased, empty is none.
  SPAWN_LABEL_FORMAT = /\A[a-z0-9][a-z0-9_-]*\z/
  normalizes :spawn_label, with: ->(value) { value.to_s.strip.downcase.presence }

  attribute :public_id, default: -> { SecureRandom.uuid_v7 }
  attribute :last_activity_at, default: -> { Time.current }

  belongs_to :account, default: -> { workspace&.account }
  belongs_to :workspace
  belongs_to :creating_user, class_name: "User"
  # THE ANSWERING PROFILE AS A STORED FACT: the User whose engine answers
  # every reply head, whose `system_prompt` slot leads every assembled
  # turn, whose standing the runner is judged for. Chosen at create — the
  # creator by default, whatever its kind: an agent creator brings its
  # engine, a Human creator has the plain chat — frozen, and copied by a
  # fork. The input's author is only the speaker.
  belongs_to :answering_user, class_name: "User", default: -> { creating_user }
  # The live FK nullifies on parent reap; the public-id snapshot beside it
  # survives. Subagent grouping, never authority.
  belongs_to :parent_conversation, class_name: "Conversation", optional: true
  # THE SPAWN LINK: the `spawn` call that minted this child — the unique
  # recovery key of the spawn job and the relay's way back to the parent's
  # waiting await. Nullifies when the spawning loop is reaped; the child
  # outlives it as it outlives its parent.
  belongs_to :spawn_node, class_name: "AgentRunTask", optional: true, inverse_of: :spawned_conversation
  belongs_to :schedule, optional: true
  belongs_to :active_turn, class_name: "ConversationTurn", optional: true
  has_many :schedules, dependent: :destroy

  has_many :conversation_turns, dependent: :destroy
  has_many :conversation_turn_variants, through: :conversation_turns
  has_many :conversation_turn_overrides, dependent: :destroy
  # Pointer rows only. The versions they name are shared with whatever
  # forked from here and are reclaimed by their own sweep, never by this
  # cascade — deleting them here would take a sibling's content with it.
  has_many :memory_documents, dependent: :destroy
  # The closure THIS conversation holds (its ancestors). The inverse —
  # closures pinning this row — blocks destroy through the RESTRICT FK, which
  # is the leaves-first reap guarantee.
  has_many :conversation_ancestries, dependent: :destroy
  has_many :ancestor_conversations, through: :conversation_ancestries
  # The access carrier's named principals: pure rows with no dependents of
  # their own, deleted in-graph with the row (StoreHost's spelling); a fork
  # copies them at the fork instant (Conversations::Fork).
  has_many :conversation_access_entries, dependent: :delete_all
  # No dependent teardown: a destroy path that forgot the leaves-first
  # invocation drain (InferenceRequests::Drain order) fails loudly here instead of leaking.
  has_many :model_invocations

  # THE ACCESS DEFAULT: what every principal the entries do not name may
  # do here — `full` at birth (every member, not create-frozen), `read`,
  # or `none`, which conceals. Prefixed because a bare `read?` on a
  # conversation would read as something else; no scopes, as on every
  # house enum. Not readonly: a later verb changes it.
  enum :access_default, %w[full read none].index_by(&:itself),
    default: :full, validate: true, scopes: false, prefix: :access

  validates :title, length: { maximum: 255 }, allow_nil: true
  validates :spawn_label, length: { maximum: 64 }, format: { with: SPAWN_LABEL_FORMAT },
    uniqueness: { scope: :parent_conversation_id }, allow_nil: true
  validates :input_queue_limit, numericality: { only_integer: true, greater_than: 0 }
  validates :timeline_position_head,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validates :context_revision,
    numericality: { only_integer: true, greater_than_or_equal_to: 0 }
  validate :creator_must_share_the_account
  validate :answerer_must_share_the_account
  validate :parent_must_share_the_workspace
  validate :active_turn_is_local
  validates :metadata, bounded_json: { bound: :conversation_metadata_bound, shape: Hash }

  # Tombstoned is gone from every product surface; a descendant's lineage
  # read is the one carve-out, and its pin defers physical reap.
  scope :listable, -> { where(tombstoned_at: nil) }
  scope :tombstoned_before, ->(cutoff) { where(tombstoned_at: ..cutoff) }
  # Archived is the recycle bin: read-only, reversible, out of the
  # default list; archive -> tombstone -> reap.
  scope :archived, -> { where.not(archived_at: nil) }
  scope :unarchived, -> { where(archived_at: nil) }
  # The working surface hides sides; `?side=1` is the one way to list them.
  scope :working, -> { where(side: false) }
  scope :sides, -> { where(side: true) }
  # THE ONE READ FUNNEL: what a principal may know exists —
  # `access_level_for` spelled in SQL. Four arms over one correlated EXISTS
  # on the entries (the Reap#candidates form): the creator, the answerer,
  # an entry short of `none`, or a default short of `none` with no entry
  # naming this principal. Every `where` here is the receiver's own, which
  # is what keeps `Relation#or` structurally compatible — compose it under
  # the workspace filter and `listable`, and add a reader's own filters
  # AFTER it, never before an arm. `none` reads as absence exactly as a
  # tombstone does; no owner carve-out, no system-user carve-out.
  scope :readable_by, ->(user) {
    entry = ConversationAccessEntry
      .where("conversation_access_entries.conversation_id = conversations.id")
      .where(user_id: user.id)
    where(creating_user_id: user.id)
      .or(where(answering_user_id: user.id))
      .or(where(entry.where.not(level: "none").arel.exists))
      .or(where.not(access_default: "none").where.not(entry.arel.exists))
  }

  # The member plane's one funnel over a workspace: the controllers, the
  # events channel and the tool plane's addressing all read through it,
  # so no door can open while another closes. Tombstones and `none` both
  # read as absence.
  def self.visible_to(user, workspace:)
    where(workspace_id: workspace.id).listable.readable_by(user)
  end

  # Direct fork provenance, including an empty Side. The closure owns this
  # fact; the current read funnel decides whether the caller may name it.
  def self.readable_source_public_ids(conversation_ids, user:, workspace:)
    return {} if conversation_ids.empty?

    ConversationAncestry.where(conversation_id: conversation_ids, depth: 1)
      .joins(:ancestor_conversation)
      .merge(visible_to(user, workspace: workspace))
      .pluck(:conversation_id, "conversations.public_id").to_h
  end

  # The live sides forked directly off any of these conversations — what a
  # parent's archive or tombstone reaps FIRST (leaves-first; a side is
  # never a subagent, so the tree walk does not reach it).
  def self.sides_of(conversation_ids)
    sides.listable.joins(:conversation_ancestries)
      .where(conversation_ancestries: { depth: 1, ancestor_conversation_id: conversation_ids })
  end

  def tombstoned? = tombstoned_at.present?

  # A child `spawn` minted: it names the call. Distinct from `subagent?`
  # only until the parent's reap nullifies the pair — the public-id
  # snapshot survives, the node link does not.
  def spawned? = spawn_node_id.present?

  # THE `user/` PRINCIPAL of a turn here: the POSTER — a Human's own
  # notes, an agent's steward's — except on a spawned child, where every
  # turn anchors on the ANSWERER: the spawner briefs it and a parent
  # `send` posts into it, but the notes the child reads and writes are the
  # child agent's steward's, never each poster's.
  def memory_principal(poster) = (spawned? || scheduled_execution?) ? answering_user : poster
  def scheduled_execution? = schedule_public_id.present?

  # The ordinary drain records this exact accepted input before deleting it.
  # Later messages or regenerated variants never become the scheduled result.
  def record_scheduled_turn(input, turn)
    update!(scheduled_turn_public_id: turn.public_id) if input.public_id == scheduled_input_public_id
  end
  def archived? = archived_at.present?

  # The one shared assembled-read funnel (Conversation::Timeline).
  def timeline = Timeline.new(self)

  # Callers hold this conversation's lock and append after their content
  # writes, since the event cursor is the last lock. The failed turn owns
  # attribution even when a background task finishes after a newer turn.
  def downgrade_reasoning_replay(turn:)
    return false if reasoning_replay_downgraded_at

    update!(reasoning_replay_downgraded_at: Time.current)
    ConversationEvent::Append.call(host: self, items: [{
      type: "reasoning_replay_downgraded",
      payload: { "turn_public_id" => turn.public_id },
    }])
    true
  end

  # A subagent is a lifecycle follower: the parent's verbs stamp the tree. The
  # snapshot is the marker — the FK nullifies on parent reap.
  def subagent? = parent_conversation_public_id.present?

  # The Windows rule without groups, the ONE Ruby derivation: the creator
  # and the answerer are FULL by derivation (never a row); an entry names
  # a level; else the conversation's default. `none` conceals — the read
  # funnel is the same rule spelled in SQL.
  def access_level_for(user)
    return "full" if user.id == creating_user_id || user.id == answering_user_id

    conversation_access_entries.find_by(user_id: user.id)&.level || access_default
  end

  def readable_by?(user) = access_level_for(user) != "none"

  # `visible_to`, answered for ONE row: the member plane's funnel — a
  # browsable workspace the principal can read, no tombstone, a level
  # other than `none` — for a reader that holds the row and not the
  # relation (the bytes read's owner walk).
  def visible_to?(user)
    !tombstoned? && workspace.browsable? && workspace.data_accessible_by?(user) && readable_by?(user)
  end

  # `read` is read: what write standing means on this row — the
  # workspace's data rule, still, conjoined with `full` here. Every
  # service conjunct and every controller gate over a conversation reads
  # this one name; the kernel's own acts never do.
  def writable_by?(user) = workspace.writable_by?(user) && access_level_for(user) == "full"

  # ── InputHost: the conversation door's answers ──────────────────────────

  # A tombstone reads as absence; the archived bin refuses caller mail by
  # name (the kernel's stamped mail passes it — the row's own carve-out).
  def input_refusal
    return :not_found if tombstoned?

    :conversation_archived if archived?
  end

  def input_kinds = ConversationInput::KINDS
  def admitted_input_fields = ConversationInput::DOOR_FIELDS
  def hosts_turns? = true

  # A steer binds only to the reply in flight: a between-turn compaction
  # summary is the one active turn while its summarizer runs, and a person's
  # words must never bind to it. No such turn means queue.
  def steer_binding = conversation_turns.active.where(kind: "direct_reply").first

  # The kick, now or at a time: a scheduled row rides the receipt's own
  # path, `DrainJob` set to run when the row is due; `at: nil` is the
  # immediate kick every other acceptance sends. Level-triggered, so a kick
  # that outlives its row drains a room with nothing due.
  def wake_drain(at: nil) = Conversations::Inputs::DrainJob.set(wait_until: at).perform_later(id)
  def note_activity = update!(last_activity_at: Time.current)

  # ONE declaring-profile rule: the stored answerer, when it is an agent; a
  # Human-answered conversation declares nothing of its own, whoever posts.
  # The system user is `kind: agent` and declares nothing, so it needs no
  # carve-out. The DEFAULT: a turn's is its own column.
  def declaring_profile = (answering_user if answering_user.agent?)
  # WHO MAY ANSWER A TURN HERE: the create door's rule — an agent member
  # that may write in the workspace — conjoined with `full` on this row:
  # the addressee writes a reply turn, and `read` cannot post. No
  # dedication fence of its own: a room has none, a dedicated home's
  # fence is the workspace's word.
  def answerer_eligible?(user) = workspace.answerer_eligible?(user) && access_level_for(user) == "full"
  def default_runner = default_runner_executor
  # The loops whose runner-kind rows this host's binding addresses:
  # every loop a turn of this conversation materialized.
  def hosted_agent_runs
    AgentRun.joins(conversation_turn_variant: :conversation_turn)
      .where(conversation_turns: { conversation_id: id })
  end

  # ── StoreHost: the conversation's answers ───────────────────

  # The conversation's own store is client state that forks with it and
  # that no prompt reads. A tombstone reads as absence; the workspace's
  # refusals (access, the dedication fence, liveness) come first; then the
  # row's own fence — `read` cannot write, `none` was concealed at the
  # funnel already; the archived bin is read-only like every content verb
  # (Memory::Apply). Concealment, fence, operability.
  def store_write_refusal(user)
    return :not_found if tombstoned?

    workspace.store_write_refusal(user) ||
      (:not_authorized unless access_level_for(user) == "full") ||
      (:conversation_archived if archived?)
  end

  # Users ABOVE conversations: the writer's rows first, then this row — the
  # cap count's serialization point and the fork's (Conversations::Fork),
  # so a create and a fork's copy never interleave. The workspace is read
  # lock-free (rung 4: never a recursive ancestor chain); its operability
  # is re-read under the users locks by `store_write_refusal`.
  def with_store_create_lock(writer)
    transaction do
      lock_writer(writer)
      with_lock { yield writer }
    end
  end

  # `conversation_command_receipts` under the existing member index: the
  # `operation` column keeps `store_entry_create` apart from `input_create`
  # and `fork` on one conversation, and one key on two conversations is two
  # receipts — no new index.
  def store_create_receipts(acting_user:, idempotency_key:, request_digest:)
    ConversationCommandReceipt::Idempotent.new(
      account: account, workspace: workspace, acting_user: acting_user,
      operation: :store_entry_create, host: self,
      idempotency_key: idempotency_key, request_digest: request_digest
    )
  end

  def store_receipt_success(status:, body:)
    ConversationCommandReceipt::Idempotent::Success.new(status: status, body: body, host: self)
  end

  # Every write that changes what the next reply assembles from owes this
  # fence — the revision clients CAS on (conversations.md, "A WRITE BUMPS").
  def note_context_change
    update!(context_revision: context_revision + 1, last_activity_at: Time.current)
  end

  private

    def creator_must_share_the_account
      return if creating_user.nil? || creating_user.account_id == account_id

      errors.add(:creating_user, :invalid)
    end

    def answerer_must_share_the_account
      return if answering_user.nil? || answering_user.account_id == account_id

      errors.add(:answering_user, :invalid)
    end

    def parent_must_share_the_workspace
      return if parent_conversation.nil?
      return if parent_conversation.workspace_id == workspace_id

      errors.add(:parent_conversation, :invalid)
    end

    # A foreign conversation's turn as the active pointer would splice two
    # timelines; the counterpart of active_variant_is_a_sibling.
    def active_turn_is_local
      return if active_turn.nil? || active_turn.conversation_id == id

      errors.add(:active_turn, :invalid)
    end
end
