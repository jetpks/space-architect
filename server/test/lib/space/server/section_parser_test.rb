# frozen_string_literal: true

require_relative "../../../test_helper"
require "space/server/section_parser"

class SectionParserTest < Minitest::Test
  FULL_MARKDOWN = <<~MD
    # I01: Full Iteration

    ## Grounds

    The grounds content here.

    ## Specification

    The specification.

    ## Acceptance Criteria

    - AC-1: Something

    ## Builder Prompt

    Prompt content.

    ## Builder Report

    Report content.

    ## Verdict

    continue
  MD

  PARTIAL_MARKDOWN = <<~MD
    # I02: Partial

    ## Grounds

    Only grounds section present.
  MD

  def test_parses_all_six_canonical_sections
    sections = Space::Server::SectionParser.parse(FULL_MARKDOWN)
    %w[Grounds Specification Verdict].each do |name|
      assert sections.key?(name), "expected section #{name}"
    end
    assert sections.key?("Acceptance Criteria")
    assert sections.key?("Builder Prompt")
    assert sections.key?("Builder Report")
  end

  def test_section_content_contains_expected_text
    sections = Space::Server::SectionParser.parse(FULL_MARKDOWN)
    assert_match "The grounds content here.", sections["Grounds"]
    assert_match "continue",                  sections["Verdict"]
    assert_match "AC-1",                      sections["Acceptance Criteria"]
  end

  def test_tolerates_missing_sections
    sections = Space::Server::SectionParser.parse(PARTIAL_MARKDOWN)
    assert sections.key?("Grounds"), "Grounds must be present"
    refute sections.key?("Specification"), "Specification must be absent"
    refute sections.key?("Verdict"),       "Verdict must be absent"
  end

  def test_empty_document_returns_empty_hash
    assert_equal({}, Space::Server::SectionParser.parse(""))
  end

  def test_document_with_only_h1_returns_empty_hash
    md = "# Just a title\n\nNo sections.\n"
    assert_equal({}, Space::Server::SectionParser.parse(md))
  end

  def test_first_heading_extracts_h1
    assert_equal "I01: Full Iteration", Space::Server::SectionParser.first_heading(FULL_MARKDOWN)
  end

  def test_first_heading_extracts_h2_when_no_h1
    md = "## Section Only\n\nContent.\n"
    assert_equal "Section Only", Space::Server::SectionParser.first_heading(md)
  end

  def test_first_heading_returns_nil_for_empty_string
    assert_nil Space::Server::SectionParser.first_heading("")
  end

  def test_first_heading_returns_nil_when_no_headings
    assert_nil Space::Server::SectionParser.first_heading("Just plain text.\n")
  end
end
