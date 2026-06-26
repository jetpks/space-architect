# frozen_string_literal: true

module Space::Core
  class Error < StandardError; end
  class NotFoundError < Error; end
  class AmbiguousSpaceError < Error; end
  class InvalidStatusError < Error; end
  class CurrentSpaceMissingError < Error; end
  class InvalidConfigKeyError < Error; end
  class RepoResolutionError < Error; end
  class RepoExistsError < Error; end
  class GitError < Error; end
  class MiseError < Error; end
end
