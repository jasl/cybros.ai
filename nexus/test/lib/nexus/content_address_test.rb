require "test_helper"

class Nexus::ContentAddressTest < ActiveSupport::TestCase
  test "content addressing has one account-salted canonical byte contract" do
    payload = { "z" => [{ "β" => "雪" }], "a" => "汉字" }
    address = Nexus::ContentAddress.for(account_id: 42, payload: payload)

    assert_equal "{\"a\":\"汉字\",\"z\":[{\"β\":\"雪\"}]}", address.canonical_payload
    assert_equal 33, address.byte_size
    assert_equal "8ad27d808b3fd23ab9b8c9284021007668bebcaa4743d42b396d6a56f9e563ce",
      address.digest
  end

  test "content addressing ignores object insertion order but not the account scope" do
    first = Nexus::ContentAddress.for(
      account_id: 42, payload: { "z" => [{ "β" => "雪" }], "a" => "汉字" }
    )
    reordered = Nexus::ContentAddress.for(
      account_id: 42, payload: { "a" => "汉字", "z" => [{ "β" => "雪" }] }
    )
    other_account = Nexus::ContentAddress.for(
      account_id: 43, payload: { "a" => "汉字", "z" => [{ "β" => "雪" }] }
    )

    assert_equal first, reordered
    assert_not_equal first.digest, other_account.digest
  end

  test "content addressing gives signed floating-point zero one identity" do
    positive = Nexus::ContentAddress.for(account_id: 42, payload: { "value" => 0.0 })
    negative = Nexus::ContentAddress.for(account_id: 42, payload: { "value" => -0.0 })

    assert_equal positive, negative
  end
end
