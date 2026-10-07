require "test_helper"

# THE ERROR MAPPING BY CODE: the daemon's refusal reaches the wire
# by its CODE — `Core::Refused` — never by its sentence.
class AcpErrorsTest < Minitest::Test
  Errors = Rho::Acp::Agent::Errors

  def refused(code, status, message = "the sentence")
    Rho::Core::Refused.new(message, code: code, status: status)
  end

  def test_a_refusal_is_internal_with_its_code_as_data
    error = Errors.translate(refused("workspace_unavailable", 409))
    assert_equal [-32603, "the sentence", { "code" => "workspace_unavailable" }], [error.code, error.message, error.data]
  end

  def test_an_envelope_less_refusal_carries_no_code
    error = Errors.translate(refused(nil, 500, "the daemon refused to read the task"))
    assert_equal [-32603, "the daemon refused to read the task", nil], [error.code, error.message, error.data]
  end

  def test_the_request_faulting_codes_are_invalid_params_with_the_sentence
    %w[input_blocked not_a_directory protected_root malformed_body].each do |code|
      error = Errors.translate(refused(code, 422, "#{code}'s sentence"))
      assert_equal [-32602, "#{code}'s sentence", nil], [error.code, error.message, error.data], code
    end
  end

  # The sentence is carried, never read: a plain `Rho::Error` spelling a
  # code word gets none invented, and a refusal's sentence shaped like a
  # validation word does not make it one.
  def test_a_sentence_is_never_read_for_a_code
    error = Errors.translate(Rho::Error.new("not_a_directory: /nowhere is not a directory"))
    assert_equal [-32603, nil], [error.code, error.data]
    error = Errors.translate(refused("workspace_unavailable", 409, "/nowhere is not a directory"))
    assert_equal [-32603, { "code" => "workspace_unavailable" }], [error.code, error.data]
  end
end
