require "test_helper"

# A locale is declared only when it has strings and a switch; neither
# exists for anything but English (a locale switch is the UI round's).
class AvailableLocalesTest < ActiveSupport::TestCase
  test "English is the only available locale" do
    assert_equal [:en], I18n.available_locales
  end
end
