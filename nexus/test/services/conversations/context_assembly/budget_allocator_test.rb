require "test_helper"

# Alt's BudgetAllocator ported whole: the eight allocator specs (the ninth, "does not echo a child
# basis it never honors", pinned the dropped requested_basis field and goes with it), the four gap
# pins, and the two pins this port adds — the windowless path and the collapsed label.
#
# The trim ORDER is the caller's arrangement: the allocator honours the
# priority and recipe order it is given, funding required floors first, then
# optional floors, then the strategy over the remainder. "History before the
# slots" is the compiler making every slot a required floor — pinned here as
# "atomic children receive reserved budget before optional children".
class Conversations::ContextAssemblyBudgetAllocatorTest < ActiveSupport::TestCase
  ALLOCATOR = Conversations::ContextAssembly::BudgetAllocator

  test "reservation then proportional fill honors reservations and weighted priority" do
    result = allocate(
      parent_budget: 100,
      strategy: "proportional",
      children: [
        child("summary", priority: 60, budget: { "reserved_tokens" => 20 }),
        child("history", priority: 40, budget: {}),
      ],
    )

    assert_equal 68, result.fetch("summary").allocated_tokens
    assert_equal 32, result.fetch("history").allocated_tokens
  end

  test "priority fill exhausts higher priority child first" do
    result = allocate(
      parent_budget: 100,
      strategy: "priority_fill",
      children: [
        child("summary", priority: 60, budget: { "max_tokens" => 30 }),
        child("history", priority: 40, budget: {}),
      ],
    )

    assert_equal 30, result.fetch("summary").allocated_tokens
    assert_equal 70, result.fetch("history").allocated_tokens
  end

  test "proportional uses equal weights when priorities are absent" do
    result = allocate(
      parent_budget: 9,
      strategy: "proportional",
      children: [
        child("a", priority: nil, budget: {}),
        child("b", priority: nil, budget: {}),
      ],
    )

    assert_equal 5, result.fetch("a").allocated_tokens
    assert_equal 4, result.fetch("b").allocated_tokens
  end

  test "child budget share caps allocation inside parent budget" do
    result = allocate(
      parent_budget: 100,
      strategy: "proportional",
      children: [
        child("large_share", priority: nil, budget: { "share" => 0.9 }),
        child("small_share", priority: nil, budget: { "share" => 0.1 }),
      ],
    )

    assert_equal 90, result.fetch("large_share").allocated_tokens
    assert_equal 10, result.fetch("small_share").allocated_tokens
    assert_equal 0.9, result.fetch("large_share").requested_share
    assert_equal 0.1, result.fetch("small_share").requested_share
  end

  test "children can receive zero when minimums exceed parent budget" do
    result = allocate(
      parent_budget: 10,
      strategy: "proportional",
      children: [
        child("required", priority: 100, budget: { "reserved_tokens" => 10, "overflow" => "error" }),
        child("optional", priority: 10, budget: { "min_tokens" => 10 }),
      ],
    )

    assert_equal 10, result.fetch("required").allocated_tokens
    assert_equal 0, result.fetch("optional").allocated_tokens
    assert_equal "budget_exhausted", result.fetch("optional").exclusion_reason
  end

  test "default overflow policy is block policy" do
    result = allocate(
      parent_budget: 10,
      strategy: "proportional",
      children: [
        child("history", priority: nil, budget: {}),
      ],
    )

    assert_equal "block_policy", result.fetch("history").overflow
  end

  # Children are one Data shape, not ducks. The positional-key fallback for
  # keyless children stays.
  test "falls back to positional keys for keyless children" do
    allocations = ALLOCATOR.call(
      parent_budget: 9,
      strategy: "proportional",
      children: [
        child("named", priority: 1, budget: {}),
        child(nil, priority: 1, budget: {}),
        child("", priority: 1, budget: {}),
      ],
    )

    result = allocations.to_h { |allocation| [allocation.key, allocation] }

    assert_equal ["named", "$child_1", "$child_2"], result.keys
    assert_equal 3, result.fetch("named").allocated_tokens
    assert_equal 3, result.fetch("$child_1").allocated_tokens
    assert_equal 3, result.fetch("$child_2").allocated_tokens
    refute_match(/\A[a-z][a-z0-9_]{0,63}\z/, "$child_1")
  end

  test "atomic children receive reserved budget before optional children regardless order" do
    ALLOCATOR::STRATEGIES.each do |strategy|
      [
        [
          child("optional_history", priority: 100, budget: { "min_tokens" => 10 }),
          child(
            "current_input",
            priority: 1,
            budget: {
              "reserved_tokens" => 3,
              "max_tokens" => 3,
              "overflow" => "error",
            },
          ),
        ],
        [
          child(
            "current_input",
            priority: 1,
            budget: {
              "reserved_tokens" => 3,
              "max_tokens" => 3,
              "overflow" => "error",
            },
          ),
          child("optional_history", priority: 100, budget: { "min_tokens" => 10 }),
        ],
      ].each do |children|
        result = allocate(parent_budget: 10, strategy:, children:)

        assert_equal 3, result.fetch("current_input").allocated_tokens, strategy
        assert_nil result.fetch("current_input").exclusion_reason, strategy
        # An unmeetable floor releases its partial funding instead of
        # stranding tokens on a child that will not render.
        assert_equal 0, result.fetch("optional_history").allocated_tokens, strategy
        assert_equal "budget_exhausted", result.fetch("optional_history").exclusion_reason, strategy
      end
    end
  end

  # The four gap pins (alt's budget_allocator_gap_pins_test): min_tokens is a
  # FLOOR under every strategy — proportional and priority_fill run the same
  # reservation pass — and an unmeetable reservation releases its partial
  # funding back to the pool instead of stranding the container's budget on
  # an excluded child.

  test "an unmeetable reservation releases its partial funding back to the siblings" do
    a, b = ALLOCATOR.call(
      parent_budget: 100,
      strategy: "proportional",
      children: [
        child("a", priority: nil, budget: { "min_tokens" => 150 }),
        child("b", priority: nil, budget: {}),
      ],
    )

    assert_equal "budget_exhausted", a.exclusion_reason
    assert_equal 0, a.allocated_tokens
    assert_equal 100, b.allocated_tokens,
      "the whole pool used to strand on the excluded child, silently emptying the container"
  end

  test "min_tokens is a floor under proportional allocation" do
    a, b = ALLOCATOR.call(
      parent_budget: 100,
      strategy: "proportional",
      children: [
        child("a", priority: 1, budget: { "min_tokens" => 60 }),
        child("b", priority: 9, budget: {}),
      ],
    )

    assert_nil a.exclusion_reason,
      "a fundable floor must be funded, not used as an exclusion tripwire"
    assert_operator a.allocated_tokens, :>=, 60
    assert_equal 100 - a.allocated_tokens, b.allocated_tokens
  end

  test "min_tokens is a floor under priority_fill allocation" do
    a, b = ALLOCATOR.call(
      parent_budget: 100,
      strategy: "priority_fill",
      children: [
        child("a", priority: 1, budget: { "min_tokens" => 60 }),
        child("b", priority: 9, budget: {}),
      ],
    )

    assert_nil a.exclusion_reason
    assert_operator a.allocated_tokens, :>=, 60
    assert_equal 100 - a.allocated_tokens, b.allocated_tokens
  end

  test "an unfundable floor under proportional still excludes and releases" do
    a, b = ALLOCATOR.call(
      parent_budget: 100,
      strategy: "proportional",
      children: [
        child("a", priority: 1, budget: { "min_tokens" => 150 }),
        child("b", priority: 1, budget: {}),
      ],
    )

    assert_equal "budget_exhausted", a.exclusion_reason
    assert_equal 100, b.allocated_tokens
  end

  # The two pins this port adds.

  # No window → the allocator does not run. Alt coerced a nil parent to 0 and
  # funded history 0 tokens — every turn `budget_exceeded` on a windowless
  # model that keeps its history whole today. Here every child answers nil,
  # never 0, and nothing is excluded: unbounded is the caller's arm.
  test "a nil parent budget allocates nil to every child and excludes none" do
    result = allocate(
      parent_budget: nil,
      strategy: "proportional",
      children: [
        child("system", priority: nil, budget: { "reserved_tokens" => 40, "overflow" => "error" }),
        child("history", priority: nil, budget: { "share" => 0.5, "min_tokens" => 10 }),
      ],
    )

    assert_equal %w[system history], result.keys
    result.each_value do |allocation|
      assert_nil allocation.allocated_tokens
      assert_nil allocation.exclusion_reason
      refute allocation.to_h.key?(:allocated_tokens)
    end
    assert_equal 40, result.fetch("system").requested_reserved_tokens
    assert_equal "error", result.fetch("system").overflow
    assert_equal 0.5, result.fetch("history").requested_share
    assert_equal 10, result.fetch("history").requested_min_tokens
  end

  # The vocabulary is two behaviours. Alt's third label, reserve_then_fill,
  # was proportional under another name; a closed vocabulary keeps one word
  # per behaviour, so the old label is refused rather than aliased.
  test "the strategy vocabulary is priority_fill and proportional, nothing else" do
    assert_equal %w[priority_fill proportional], ALLOCATOR::STRATEGIES

    error = assert_raises(ArgumentError) do
      ALLOCATOR.call(parent_budget: 10, strategy: "reserve_then_fill", children: [child("a", priority: nil, budget: {})])
    end

    assert_match(/reserve_then_fill/, error.message)
  end

  private

  def allocate(parent_budget:, strategy:, children:)
    ALLOCATOR.call(
      parent_budget:,
      strategy:,
      children:,
    ).to_h { |allocation| [allocation.key, allocation] }
  end

  def child(key, priority:, budget:)
    ALLOCATOR::Child.new(key:, priority:, budget:)
  end
end
