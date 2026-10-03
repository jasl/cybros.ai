# A named, ordered content projection owned by exactly one record. The
# populated typed foreign key identifies the owner; a second discriminator
# would only repeat that fact and create another value to keep consistent.
class ContentBody < ApplicationRecord
  include Searchable
  ROLE_MAX_LENGTH = 32
  OWNER_ROLES = {
    one_shot: %w[input],
    model_invocation: %w[request response reasoning reasoning_trace tool_calls],
    conversation_input: %w[input],
    # `prompt` is the input that opened a reply turn, cloned at
    # materialization; assembly renders it, the presenter does not.
    # `preface` is what the turn's request placed between history and
    # that input, sealed as sent (ContextAssembly::Preface).
    conversation_turn_variant: %w[content prompt preface reasoning reasoning_trace steers],
    # `input` is authored at append; `output` is the kernel's entry-copy
    # of the step answer at terminal apply — the deliverable read;
    # `steers` is the steer tail a round read, kept at the landing
    # (AgentLoops::Steers::Landed).
    agent_loop_node: %w[input output steers],
  }.freeze

  attr_readonly :account_id, :role, :one_shot_id, :model_invocation_id,
    :conversation_input_id, :conversation_turn_variant_id, :agent_loop_node_id

  belongs_to :account, default: -> { owner&.account }
  belongs_to :one_shot, optional: true, inverse_of: :content_bodies
  belongs_to :model_invocation, optional: true, inverse_of: :content_bodies
  belongs_to :conversation_input, optional: true, inverse_of: :content_bodies
  belongs_to :conversation_turn_variant, optional: true, inverse_of: :content_bodies
  belongs_to :agent_loop_node, optional: true, inverse_of: :content_bodies

  has_many :content_body_entries, -> { order(:position) }, inverse_of: :content_body
  has_many :content_body_uploads, inverse_of: :content_body
  has_many :content_uploads, through: :content_body_uploads

  validates :role, presence: true, length: { maximum: ROLE_MAX_LENGTH }
  validate :owner_and_role_must_match
  validate :seal_is_write_once
  validate :sealed_content_is_immutable

  # Nil-safe, not presence-based: a door-written `""` is a message with no
  # words — a picture alone — never its canonical `{"role":…,
  # "parts":[{"type":"upload",…}]}` in a prompt, a preview or a presenter.
  def effective_text
    readable_text || canonical_entry_text
  end

  # Reuses preloaded entries and fragments; loads them once otherwise.
  def entry_payloads
    entries = content_body_entries.to_a
    ActiveRecord::Associations::Preloader.new(
      records: entries, associations: :content_fragment
    ).call
    entries.map { |entry| entry.content_fragment.payload }
  end

  # Native replay may contain model-bound signatures or encrypted items:
  # a role-less reasoning item (Responses, DeepSeek's plain-text item) or a
  # reasoning part (Anthropic's and Gemini's blocks, the chat field).
  def native_reasoning?
    entry_payloads.any? do |payload|
      payload["type"] == "reasoning_item" ||
        Array(payload["parts"]).any? { |part| part["type"] == "reasoning" }
    end
  end

  # THE PARTS (one projection for every reader): the ordered part stream
  # of the entries written as messages, restored through the row's own
  # inverse (`Nexus::TextInputMessage.from_h`, the OneShot's grammar); a
  # body of plain text entries answers none. The entries are the ORDER,
  # the join is the LIVENESS.
  def parts
    entry_payloads.flat_map do |payload|
      payload.key?("parts") ? Nexus::TextInputMessage.from_h(payload).parts : []
    end
  end

  # Each `upload` part's bound row, in ENTRY order — the same row at every
  # occurrence when a picture is placed twice. ChatHistory, the presenter,
  # the summarizer's rendering and rho's `inputs` line all read this, so
  # the wire and every rendering agree on which pictures a turn carried.
  # A bound row cannot be reaped (`ContentUpload.unbound`; the join is
  # RESTRICT), so a placed id without its row is an invariant broken, not
  # a case: `fetch` says so loudly.
  def upload_parts
    return [] if content_uploads.empty?

    rows = content_uploads.index_by(&:public_id)
    parts.filter_map do |part|
      rows.fetch(part.upload_public_id) if part.type == Nexus::InputParts::UPLOAD
    end
  end

  # The uploads a sealed request carries for its workload: an image edit's
  # ordered source-image occurrences (the join keeps bytes alive, not their
  # order), every other workload's bound set. The send and a re-check of the
  # same input for another model read the one rule.
  def request_uploads(workload)
    workload == "image_generation" ? upload_parts : content_uploads.to_a
  end

  # Prepare a page of bodies for text and ordered-attachment rendering.
  # Plain text uses its stored projection; only raw or attachment-bearing
  # bodies need their entries and fragments.
  def self.preload_for_render(bodies)
    bodies = bodies.to_a
    ActiveRecord::Associations::Preloader.new(
      records: bodies, associations: { content_uploads: { file_attachment: :blob } }
    ).call
    ActiveRecord::Associations::Preloader.new(
      records: bodies.select { |body| body.readable_text.nil? || body.content_uploads.any? },
      associations: { content_body_entries: :content_fragment }
    ).call
    bodies
  end

  # THE STORED SIZES: each node's output body's `byte_size` keyed by node
  # id — one SQL sum, never a body load. A node with no output body (a
  # call still live, an expired park) is absent, and a reader treats
  # absent as zero, as it did when it loaded nothing.
  def self.output_bytes_by_node(node_ids)
    return {} if node_ids.empty?

    where(agent_loop_node_id: node_ids, role: "output")
      .group(:agent_loop_node_id).sum(:byte_size)
      .transform_values(&:to_i)
  end

  def sealed? = sealed_at.present?

  # THE OWNER'S FUNNEL, for the bytes read: a principal reads an upload
  # this body names when they can read the row that owns the body — each
  # of the five owners answering `readable_by?(user)` through the funnel
  # its own REST door uses. One polymorphic predicate per owner; the
  # populated typed key picks it, never a class probe.
  def owner_readable_by?(user)
    owner = OWNER_ROLES.keys.find { |name| public_send(:"#{name}_id").present? }
    return false if owner.nil?

    public_send(owner).readable_by?(user)
  end

  # A seal is a write-once adoption fact. It carries no digest: callers trust
  # the sealed internal value and retries read this same body.
  def seal(at: Time.current)
    return self if sealed?

    update!(sealed_at: at)
    self
  end

  private

    def canonical_entry_text
      entry_payloads.map { |payload| Nexus::CanonicalJson.encode(payload) }.join("\n").presence
    end

    def sealed_content_is_immutable
      return unless sealed_at_was.present?

      %i[readable_text role byte_size].each do |attribute|
        errors.add(attribute, :readonly) if public_send(:"#{attribute}_changed?")
      end
    end

    def seal_is_write_once
      return unless sealed_at_changed? && sealed_at_was.present?

      errors.add(:sealed_at, :readonly)
    end

    # The populated typed foreign key names the owner; nil until one is set
    # (the validation below refuses a body with none or with two).
    def owner
      one_shot || model_invocation || conversation_input || conversation_turn_variant || agent_loop_node
    end

    def owner_and_role_must_match
      owners = OWNER_ROLES.keys.select do |owner|
        public_send(:"#{owner}_id").present?
      end
      unless owners.one?
        errors.add(:base, :not_exactly_one_owner)
        return
      end

      errors.add(:role, :inclusion) unless OWNER_ROLES.fetch(owners.first).include?(role)
    end
end
