# THE GRAMMAR AND THE LAYOUT of `assembly`:
# an ordered block list
# from a closed vocabulary — every type an existing block class — plus
# root variables the template's own inline text and the profile's
# `system_prompt` may name. `DEFAULT_TEMPLATE` is the fixed order
# `default` compiles, spelled as data; the compiler runs one path for
# both words and only the ORDER is read from here.
#
# The rules, each refused at its JSON-pointer path:
# - `input` exactly once and LAST: a post-history
#   instruction is a `user`/`developer` inline before it or a `tail`.
# - `history` exactly once: the reply keeps the conversation's earlier
#   turns, bounded by the template's history budget. What a template lays
#   BETWEEN `history` and `input` is the turn's PREFACE: sealed with the
#   turn as it was rendered and replayed in place by every later turn's
#   history (ContextAssembly::Preface), so per-turn text there appends to
#   the context; per-turn text ahead of `history` re-renders every turn
#   and moves the prefix — the template's own choice.
# - a `system`-role inline only in the LEADING RUN (slots and system
#   inlines): Anthropic and Gemini peel every system entry wherever it
#   sits, so a mid-list one compiles to two orders and, last, would
#   carry the rolling cache tail (Nexus::PromptCache::Breakpoints).
# - a slot only AHEAD of `history`: the durable documents never ride
#   the turn's preface.
# - `memory`, `skills`, `lead`, `tail` at most once; a slot at most once.
# No strategy word, no priority, no nesting: with one optional child
# (history) no allocation strategy is distinguishable.
class PromptTemplate
  TYPES = %w[slot inline memory skills lead tail history input].freeze
  INLINE_ROLES = (PromptDocument::ROLES + %w[assistant]).freeze
  ONCE = %w[memory skills lead tail history input].freeze
  ROOT_KEYS = %w[blocks variables].freeze
  BLOCK_KEYS = {
    "slot" => %w[type slot], "inline" => %w[type role text], "history" => %w[type max_entries budget],
  }.freeze
  BUDGET_KEYS = %w[share min_tokens max_tokens].freeze
  MAX_BLOCKS = 64
  MAX_VARIABLES = 32
  MAX_ENTRIES = 200
  VARIABLE_NAME = /\A[a-z][a-z0-9_]*\z/

  # The default order: the slots lead — identity, the room, the person —
  # then memory, then the skills catalog (rendered only when the turn
  # declares the `skill` tool, frozen for the loop like memory); all
  # change only when written, history every reply, so the stable cache
  # marker lands after them. The per-turn text — the caller's lead and
  # tail — rides BEHIND history as the turn's preface, so the next turn's
  # request is this one whole plus its own tail.
  DEFAULT_TEMPLATE = {
    "blocks" => [
      { "type" => "slot", "slot" => "system_prompt" },
      { "type" => "slot", "slot" => "character" },
      { "type" => "slot", "slot" => "persona" },
      { "type" => "memory" },
      { "type" => "skills" },
      { "type" => "history" },
      { "type" => "lead" },
      { "type" => "tail" },
      { "type" => "input" },
    ],
  }.freeze

  Block = Data.define(:type, :slot, :role, :text, :max_entries, :budget) do
    def initialize(type:, slot: nil, role: nil, text: nil, max_entries: nil, budget: {}) = super

    # The name the compiler files the block's segments and evidence
    # under: a slot by its slot, an inline by its position, the rest
    # by type (each at most once).
    def key(index)
      case type
      when "slot" then "slot:#{slot}"
      when "inline" then "inline:#{index}"
      else type
      end
    end
  end

  Refusal = Data.define(:path, :detail)

  class << self
    # A trusted value — the stored column, validated at its one
    # writer, or the built-in — into blocks: the grammar is
    # `refusal`'s, and a value it admitted is read as the object it is.
    def parse(value)
      new(
        blocks: value.fetch("blocks", []).map { |raw| block_from(raw) },
        variables: value.fetch("variables", {}).transform_keys(&:to_s)
      )
    end

    # The template a profile compiles under: its own only while its
    # standing word is `assembly`; `default` — and no profile at all,
    # a Human answerer — is the built-in order, a stored template unread.
    def for_profile(profile)
      return DEFAULT unless profile&.prompt_mechanism == "assembly"

      parse(profile.prompt_template)
    end

    # The template a STANDALONE loop's shell compiles under: the shell
    # IS the loop's declaration, so its word wins over the creator
    # profile's standing one — `assembly` reads the creator's stored
    # template whatever its standing word (nil when it stored none, or
    # the creator is a Human: `prompt_template_missing` at the shell),
    # `default` is the built-in order, `raw` compiles nothing.
    def for_shell(mechanism, profile)
      case mechanism
      when "assembly" then (parse(profile.prompt_template) if profile&.prompt_template.present?)
      when "default" then DEFAULT
      else nil
      end
    end

    # The first refusal at its path, else nil.
    def refusal(value)
      root = Hash.try_convert(value)
      return Refusal.new(path: "/", detail: "object") if root.nil?

      stray = (root.keys - ROOT_KEYS).first
      return Refusal.new(path: "/#{stray}", detail: "key") if stray

      variables_refusal(root["variables"]) ||
        blocks_refusal(root["blocks"], (Hash.try_convert(root["variables"]) || {}).keys.map(&:to_s))
    end

    private

      def block_from(raw)
        Block.new(
          type: raw["type"].to_s, slot: raw["slot"], role: raw["role"], text: raw["text"],
          max_entries: raw["max_entries"], budget: raw["budget"] || {}
        )
      end

      def variables_refusal(value)
        return nil if value.nil?

        variables = Hash.try_convert(value)
        return Refusal.new(path: "/variables", detail: "object") if variables.nil? || variables.length > MAX_VARIABLES

        variables.each do |name, default|
          path = "/variables/#{name}"
          return Refusal.new(path: path, detail: "name") unless VARIABLE_NAME.match?(name.to_s)
          return Refusal.new(path: path, detail: "source") if Nexus::PromptMacros::REGISTRY.include?(name.to_s)
          return Refusal.new(path: path, detail: "string") if String.try_convert(default).nil?
        end
        nil
      end

      def blocks_refusal(value, names)
        blocks = Array.try_convert(value)
        if blocks.nil? || blocks.empty? || blocks.length > MAX_BLOCKS
          return Refusal.new(path: "/blocks", detail: "list")
        end

        blocks.each_with_index do |raw, index|
          refusal = block_refusal(raw, index, blocks.take(index), names)
          return refusal if refusal
        end
        types = blocks.map { |raw| raw["type"] }
        return Refusal.new(path: "/blocks", detail: "input") unless types.last == "input"
        return Refusal.new(path: "/blocks", detail: "history") unless types.count("history") == 1

        nil
      end

      def block_refusal(raw, index, before, names)
        path = "/blocks/#{index}"
        block = Hash.try_convert(raw)
        return Refusal.new(path: path, detail: "object") if block.nil?

        type = block["type"]
        return Refusal.new(path: "#{path}/type", detail: "type") unless TYPES.include?(type)

        stray = (block.keys - BLOCK_KEYS.fetch(type, %w[type])).first
        return Refusal.new(path: "#{path}/#{stray}", detail: "key") if stray

        return Refusal.new(path: path, detail: "after_input") if before.any? { |earlier| earlier["type"] == "input" }
        if ONCE.include?(type) && before.any? { |earlier| earlier["type"] == type }
          return Refusal.new(path: path, detail: "once")
        end

        case type
        when "slot" then slot_refusal(block, path, before)
        when "inline" then inline_refusal(block, path, before, names)
        when "history" then history_refusal(block, path)
        else nil
        end
      end

      # A slot is a durable document ahead of history: behind it the slot
      # would ride the turn's preface — sealed and replayed once per turn,
      # a `system` one hoisted into the top system block by Anthropic and
      # Gemini wherever it sits.
      def slot_refusal(block, path, before)
        slot = block["slot"]
        return Refusal.new(path: "#{path}/slot", detail: "slot") unless PromptDocument::ASSEMBLY_SLOTS.include?(slot)
        return Refusal.new(path: path, detail: "once") if before.any? { |earlier| earlier["slot"] == slot }
        return Refusal.new(path: path, detail: "after_history") if before.any? { |earlier| earlier["type"] == "history" }

        nil
      end

      def inline_refusal(block, path, before, names)
        role = block["role"]
        return Refusal.new(path: "#{path}/role", detail: "role") unless INLINE_ROLES.include?(role)
        if role == "system" && !before.all? { |earlier| leading?(earlier) }
          return Refusal.new(path: "#{path}/role", detail: "leading_run")
        end

        text = String.try_convert(block["text"])
        return Refusal.new(path: "#{path}/text", detail: "text") if text.blank?

        unknown = Nexus::PromptMacros.unknown(text, Nexus::PromptMacros::REGISTRY + names)
        return Refusal.new(path: "#{path}/text", detail: unknown) if unknown

        nil
      end

      def leading?(block)
        block["type"] == "slot" || (block["type"] == "inline" && block["role"] == "system")
      end

      def history_refusal(block, path)
        max_entries = block["max_entries"]
        unless max_entries.nil? || integer_within(max_entries, 1..MAX_ENTRIES)
          return Refusal.new(path: "#{path}/max_entries", detail: "range")
        end

        budget_refusal(block["budget"], "#{path}/budget")
      end

      def budget_refusal(value, path)
        return nil if value.nil?

        budget = Hash.try_convert(value)
        return Refusal.new(path: path, detail: "object") if budget.nil?

        stray = (budget.keys - BUDGET_KEYS).first
        return Refusal.new(path: "#{path}/#{stray}", detail: "key") if stray
        return Refusal.new(path: "#{path}/share", detail: "share") unless
          budget["share"].nil? || share_within_unit(budget["share"])

        %w[min_tokens max_tokens].each do |name|
          next if budget[name].nil? || integer_within(budget[name], 0..)

          return Refusal.new(path: "#{path}/#{name}", detail: "tokens")
        end
        if budget["min_tokens"] && budget["max_tokens"] && budget["min_tokens"] > budget["max_tokens"]
          return Refusal.new(path: "#{path}/max_tokens", detail: "below_min")
        end

        nil
      end

      def integer_within(value, range)
        case value
        when Integer then range.cover?(value)
        else false
        end
      end

      def share_within_unit(value)
        case value
        when Numeric then value.positive? && value <= 1
        else false
        end
      end
  end

  attr_reader :blocks, :variables

  def initialize(blocks:, variables:)
    @blocks = blocks.freeze
    @variables = variables.freeze
  end

  DEFAULT = parse(DEFAULT_TEMPLATE)

  def keys = blocks.each_with_index.map { |block, index| block.key(index) }
  def default? = blocks == DEFAULT.blocks && variables.empty?
  def history = blocks.find { |block| block.type == "history" }
  def history_share = history&.budget&.fetch("share", nil)
  def memory? = blocks.any? { |block| block.type == "memory" }
  def skills? = blocks.any? { |block| block.type == "skills" }
  def places?(position) = blocks.any? { |block| block.type == position }
  def slot_names = blocks.filter_map { |block| block.slot if block.type == "slot" }
  def variable_names = variables.keys
  def inline_blocks = blocks.each_with_index.select { |block, _index| block.type == "inline" }

  # The turn's values over the defaults; a name the template does not
  # declare never reaches the render (the door and the drain refuse it first).
  def values(turn_values)
    variables.merge((Hash.try_convert(turn_values) || {}).transform_keys(&:to_s).slice(*variable_names))
  end

  # The three refusals a TURN can earn at compile — the door reads the
  # addressee's template and refuses by name; the drain reads the
  # template of its day and parks by the same name (never literal
  # braces, never a silent drop). Two are this template's: a variable it
  # does not declare, a position it does not place. The third is the
  # intent's own shape whatever the template — a positioned entry's role
  # (`ConversationInput.inline_role_placed?`, the rule the row judges
  # too) — checked here so every compile path refuses it by one name.
  def turn_refusal(variables:, inline:)
    unless variables.nil?
      given = Hash.try_convert(variables)
      return :prompt_template_invalid if given.nil?
      return :prompt_template_invalid unless given.all? do |name, value|
        variable_names.include?(name.to_s) && String.try_convert(value)
      end
    end
    (Array.try_convert(inline) || []).each do |entry|
      return :inline_role_unplaced unless ConversationInput.inline_role_placed?(entry)
      next if entry["slot"]

      return :inline_position_unplaced unless places?(entry["position"] || "lead")
    end
    nil
  end

  # The keys up to and including `history`, and the keys strictly between
  # `history` and `input` (the grammar puts `input` last): the second run
  # is the turn's preface.
  def split_at_history
    index = keys.index("history")
    [keys.first(index + 1), keys[(index + 1)...-1]]
  end
end
