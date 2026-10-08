require "test_helper"

# THE SECOND LINK OF THE EFFORT CHAIN. A catalog row may only offer the
# efforts its api_format declares (the catalog's own validation holds that
# link), and a format may only declare efforts its protocol's WIRE GATE
# accepts — the local refusal each protocol applies before any IO. Without
# this second link a model could be offered an effort at selection that
# its own wire then refuses at send. The protocols' gate comments point
# here.
class TestReasoningWireGates < Minitest::Test
  GATES = %i[REASONING_EFFORTS REASONING_EFFORT_VOCABULARY THINKING_LEVELS].freeze

  # These formats pass efforts through to a host that decides them — a
  # broker, or any server speaking the OpenAI-compatible dialect — so they
  # have no local gate to exceed. A new format without a gate must be named
  # here on purpose.
  PASS_THROUGH = %w[openrouter_chat openai_compatible_chat mistral_chat].freeze

  def formats_with_efforts
    SimpleInference::ApiFormat::PROTOCOL_CLASSES.filter_map do |format, klass|
      efforts = Array(SimpleInference::ApiFormat.defaults(format).dig(:reasoning_options, "efforts"))
      [format, klass, efforts] unless efforts.empty?
    end
  end

  def gate_of(klass)
    name = GATES.find { |gate| klass.const_defined?(gate) }
    name && klass.const_get(name)
  end

  def test_every_gated_formats_efforts_are_inside_its_wire_gate
    formats_with_efforts.each do |format, klass, efforts|
      gate = gate_of(klass)
      next if gate.nil?

      assert_empty efforts - gate,
        "#{format} declares efforts #{klass.name} refuses on the wire: a model could be offered them and then fail at send"
    end
  end

  def test_only_the_named_pass_through_formats_have_no_wire_gate
    gateless = formats_with_efforts.filter_map { |format, klass, _| format if gate_of(klass).nil? }

    assert_equal PASS_THROUGH.sort, gateless.sort,
      "a format that declares efforts either gates them locally or is named as pass-through here"
  end
end
