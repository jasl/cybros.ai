module CybrosAgent
  # A MODEL PATTERN names the models it covers by their REFERENCE: the kernel's `ref` minus its
  # lane segment (`openrouter/z-ai/glm-5.3` → `z-ai/glm-5.3`), because the lane key is the
  # operator's word and one model on two lanes is one model. An entry is EXACT (`z-ai/glm-5.3`,
  # equal bytes) or a PREFIX (`claude-*`: one trailing `*` whose stem is every byte before it);
  # every other character is literal, `.` included, and the `*` follows a separator so it never
  # runs on from a name — `z-ai/glm-5.3:*` takes the variants and never `z-ai/glm-5.3-flash`.
  # SPECIFICITY ranks the entries matching one reference: exact above every prefix, a longer stem
  # above a shorter one. The stems matching one string are prefixes of it, so two different
  # entries never tie; a `?`, an inner `*` or a regular expression would lose that unique winner,
  # which is why the grammar has none. The helper knows no row, tier or catalog: any consumer
  # asks it on demand.
  module ModelPattern
    STAR = "*".freeze
    DOT_STAR = ".*".freeze
    # A `*` follows one of these, never a letter, a digit or a `.`.
    SEPARATORS = %w[- _ : / @].freeze
    # A regular expression's or a glob's metacharacters: refused rather than loaded as literals
    # that match nothing.
    RESERVED = %w[? [ ] { } ( ) | ^ $ + \\].freeze
    RESERVED_CHARACTER = Regexp.union(RESERVED)
    UNPRINTABLE = /[^!-~]/
    ALPHANUMERIC = /[A-Za-z0-9]/

    module_function

    # The text after a kernel ref's FIRST `/`; `nil` (no model) answers `nil`. A ref without a
    # `/` names no lane, so it is refused rather than read as a reference.
    def reference(ref)
      if ref.nil?
        nil
      else
        text = ref.to_s
        raise ArgumentError, "#{ref.inspect} carries no lane segment; a kernel ref is <lane>/<reference>" unless text.include?("/")

        text.split("/", 2).last
      end
    end

    # Why `entry` is not a model pattern, or nil: the first rule it breaks, as a sentence naming
    # the entry.
    def refusal(entry)
      stem = entry.delete_suffix(STAR)
      if entry.match?(UNPRINTABLE)
        "#{entry.inspect} carries #{entry[UNPRINTABLE].inspect}: an entry is printable ASCII, no whitespace, control character or non-ASCII"
      elsif entry.match?(RESERVED_CHARACTER)
        "#{entry.inspect} carries #{entry[RESERVED_CHARACTER].inspect}, a reserved pattern character (#{RESERVED.join(" ")}): " \
          "the one wildcard is a trailing *"
      elsif stem.include?(STAR)
        "#{entry.inspect} has a * before its end; a pattern's one * is its last character"
      elsif prefix?(entry) && !stem.empty? && !SEPARATORS.include?(stem[-1])
        misplaced_star(entry, stem)
      elsif entry.start_with?("/") || entry.end_with?("/") || entry.include?("//")
        "#{entry.inspect} has an empty segment (a leading, trailing or doubled /)"
      elsif !entry.match?(ALPHANUMERIC)
        "#{entry.inspect} names no letter or digit; a pattern names at least one (a bare * would cover every model)"
      end
    end

    def prefix?(entry) = entry.end_with?(STAR)

    # Exact: its length + 1 on equal bytes. Prefix: its stem's length when the reference begins
    # with the stem. No match: nil. A matching stem is never longer than the reference, so an
    # exact match outranks every prefix.
    def specificity(entry, reference)
      if prefix?(entry)
        stem = entry.delete_suffix(STAR)
        stem.length if reference.start_with?(stem)
      elsif entry == reference
        entry.length + 1
      end
    end

    # The best specificity of `entries` on `reference`, or nil when none matches.
    def rank(entries, reference) = entries.filter_map { |entry| specificity(entry, reference) }.max

    # Whether `entries` cover a kernel ref; no model is covered by nothing.
    def covers?(entries, ref)
      if ref.nil?
        false
      else
        !rank(entries, reference(ref)).nil?
      end
    end

    # A regular expression's `.*` gets its own sentence: the habit is common and the entry would
    # load as a stem ending in a literal `.`, matching nothing. The fix it names is one the grammar
    # accepts; a base ending in a separator that another rule refuses (`/.*`, `-.*`) gets none,
    # and that rule's sentence answers the edited entry.
    def misplaced_star(entry, stem)
      separators = "(#{SEPARATORS.join(" ")})"
      if entry.end_with?(DOT_STAR)
        base = entry.delete_suffix(DOT_STAR)
        fix = if refusal(base + STAR).nil?
          " — write #{(base + STAR).inspect}"
        elsif SEPARATORS.include?(base[-1])
          ""
        else
          ", and a * follows a separator #{separators}"
        end
        %(#{entry.inspect} ends in ".*", a regular expression's "anything"; here * alone takes any characters and . is literal#{fix})
      else
        "#{entry.inspect} puts * right after #{stem[-1].inspect}; a * follows a separator #{separators} so it never splits a token"
      end
    end
    private_class_method :misplaced_star
  end
end
