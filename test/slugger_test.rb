# frozen_string_literal: true

require_relative "test_helper"

class SluggerTest < SpaceArchitectTest
  def test_slugifies_titles
    assert_equal "name-of-space", SpaceArchitect::Slugger.slug("Name of Space")
    assert_equal "rx-1234-fix-profile-loading", SpaceArchitect::Slugger.slug("RX-1234: Fix profile loading")
    assert_equal "space", SpaceArchitect::Slugger.slug("!!!")
  end
end
