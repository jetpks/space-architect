# frozen_string_literal: true

module Space
  module Server
    # Pure-Ruby markdown section extractor. Splits on ## headers and returns a
    # hash of section_name => raw_content. Also extracts the first H1/H2 heading.
    module SectionParser
      SECTION_RE  = /^## (.+)/.freeze
      HEADING_RE  = /^[#]{1,2} (.+)/.freeze

      # Returns hash of section name => content string for every ## header found.
      # Missing canonical sections are absent from the hash; callers should tolerate.
      def self.parse(markdown)
        sections = {}
        current  = nil
        markdown.each_line do |line|
          m = line.match(SECTION_RE)
          if m
            current = m[1].strip
            sections[current] ||= +""
          elsif current
            sections[current] << line
          end
        end
        sections
      end

      # Returns the text of the first H1 or H2 heading, or nil if none found.
      def self.first_heading(markdown)
        markdown.each_line do |line|
          m = line.match(HEADING_RE)
          return m[1].strip if m
        end
        nil
      end
    end
  end
end
