# frozen_string_literal: true

require_relative "test_helper"
require "rack/mock"

# Regression guard for the OmniAuth request-phase CSRF check wired in config/app.rb.
#
# OmniAuth.config.request_validation_phase validates POST /auth/github against Hanami's
# own session :_csrf_token — the token the SPA sign-in form (Nav.tsx) submits as
# authenticity_token / X-CSRF-Token — replacing OmniAuth's default rack-protection
# AuthenticityToken (a separate :csrf key the frontend never sends). A matching token
# passes; a missing or mismatched token raises OmniAuth::AuthenticityError, which routes
# to on_failure → /auth/failure. Driven directly (OmniAuth test_mode bypasses the request
# phase, so a full-stack POST would assert nothing).
class OmniAuthRequestCsrfTest < Minitest::Test
  TOKEN = "csrf-token-deadbeef0123456789"

  def validate(session:, authenticity_token: nil, header: nil)
    env = Rack::MockRequest.env_for(
      "/auth/github",
      method: "POST",
      params: authenticity_token ? {"authenticity_token" => authenticity_token} : {}
    )
    env["rack.session"] = session
    env["HTTP_X_CSRF_TOKEN"] = header if header
    OmniAuth.config.request_validation_phase.call(env)
  end

  def test_matching_form_token_passes
    assert_nil validate(session: {_csrf_token: TOKEN}, authenticity_token: TOKEN)
  end

  def test_matching_token_via_x_csrf_token_header_passes
    assert_nil validate(session: {_csrf_token: TOKEN}, header: TOKEN)
  end

  def test_string_keyed_session_token_passes
    # the session may round-trip through the cookie with a string key
    assert_nil validate(session: {"_csrf_token" => TOKEN}, authenticity_token: TOKEN)
  end

  def test_mismatched_token_is_rejected
    assert_raises(OmniAuth::AuthenticityError) do
      validate(session: {_csrf_token: TOKEN}, authenticity_token: "wrong-token")
    end
  end

  def test_missing_submitted_token_is_rejected
    assert_raises(OmniAuth::AuthenticityError) do
      validate(session: {_csrf_token: TOKEN})
    end
  end

  def test_missing_session_token_is_rejected
    assert_raises(OmniAuth::AuthenticityError) do
      validate(session: {}, authenticity_token: TOKEN)
    end
  end

  def test_empty_strings_are_rejected
    assert_raises(OmniAuth::AuthenticityError) do
      validate(session: {_csrf_token: ""}, authenticity_token: "")
    end
  end
end
