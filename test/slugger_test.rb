# frozen_string_literal: true

require_relative "test_helper"

class SluggerTest < Space::ArchitectTest
  def test_slugifies_titles
    assert_equal "name-of-space", Space::Core::Slugger.slug("Name of Space")
    assert_equal "rx-1234-fix-profile-loading", Space::Core::Slugger.slug("RX-1234: Fix profile loading")
    assert_equal "space", Space::Core::Slugger.slug("!!!")
  end
end
