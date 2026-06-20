# frozen_string_literal: true

require "fileutils"
require "async"
require "async/semaphore"
require "pathname"
require "time"
require "dry/monads"
require "space_architect/pristine/scm/git"
require "space_architect/pristine/cloner"

module SpaceArchitect
  class SpaceStore
    include Dry::Monads[:result, :maybe]

    MAX_CONCURRENT_CLONES = 5

    attr_reader :config, :state, :now

    def initialize(config:, state:, now: -> { Time.now })
      @config = config
      @state = state
      @now = now
    end

    def spaces_dir
      config.spaces_dir
    end

    def create(title, git: true, git_client: GitClient.new)
      FileUtils.mkdir_p(spaces_dir)
      timestamp = now.call
      id = unique_id("#{timestamp.strftime('%Y%m%d')}-#{Slugger.slug(title)}")
      path = spaces_dir.join(id)

      FileUtils.mkdir_p(path.join("repos"))
      FileUtils.mkdir_p(path.join("notes"))
      FileUtils.mkdir_p(path.join("artifacts"))
      FileUtils.mkdir_p(path.join("tmp"))

      space = Space.new(path, metadata_for(id:, title:, timestamp:))
      space.save
      write_readme(path:, title:, id:, timestamp:)
      init_git(path:, id:, git_client:) if git
      state.touch_recent(id)
      Success(space)
    rescue SpaceArchitect::Error => e
      Failure(e)
    end

    def list
      return [] unless spaces_dir.directory?

      spaces_dir.children.select(&:directory?).filter_map do |child|
        Space.load(child)
      rescue NotFoundError, Error
        nil
      end.sort_by(&:id)
    end

    def find(identifier = nil, from: Dir.pwd)
      value = identifier.to_s.strip
      return current(from:) if value.empty?

      if looks_like_path?(value)
        begin
          return Success(Space.load(File.expand_path(value)))
        rescue SpaceArchitect::Error => e
          return Failure(e)
        end
      end

      matches = matching_spaces(value)
      return Success(matches.first) if matches.length == 1

      if matches.empty?
        return Failure(NotFoundError.new("Could not find space matching '#{value}' in #{spaces_dir}"))
      end

      Failure(AmbiguousSpaceError.new("Space '#{value}' is ambiguous: #{matches.map(&:id).join(', ')}"))
    end

    def current(from: Dir.pwd)
      current_from_pwd(from:).to_result(CurrentSpaceMissingError.new("No current space found from #{from}. Run this inside a space or pass a space id."))
    end

    def current_from_pwd(from: Dir.pwd)
      path = Pathname.new(File.expand_path(from.to_s))
      path = path.dirname if path.file?

      loop do
        return Some(Space.load(path)) if path.join(Space::METADATA_FILE).exist?
        break if path.root?

        path = path.parent
      end

      None()
    end

    def path_for(identifier = nil)
      find(identifier).fmap(&:path)
    end

    def use(identifier)
      find(identifier).fmap { |space| state.touch_recent(space.id); space }
    end

    def add_repo(spec, from: Dir.pwd, scm: Pristine::SCM::Git.new, cloner: nil, mise_client: MiseClient.new)
      add_repos([spec], from:, scm:, cloner:, mise_client:).fmap(&:first)
    end

    def add_repos(specs, from: Dir.pwd, scm: Pristine::SCM::Git.new, cloner: nil, mise_client: MiseClient.new, reporter: nil)
      current(from:).bind { |space| add_repos_to(space, specs, scm:, cloner:, mise_client:, reporter:) }
    end

    def add_repos_to(space, specs, scm: Pristine::SCM::Git.new, cloner: nil, mise_client: MiseClient.new, reporter: nil)
      additions = prepare_repo_additions(space, specs)
      first_error = nil

      Warnings.without_experimental do
        Async do |task|
          semaphore = Async::Semaphore.new(MAX_CONCURRENT_CLONES, parent: task)

          clone_tasks = additions.map do |addition|
            semaphore.async(finished: false) do
              clone_addition(addition, scm:, cloner:, mise_client:, reporter:)
            end
          end

          # Collect results without raising inside the reactor so the outer task
          # succeeds and async does not log "Task may have ended" for our errors.
          clone_tasks.each do |ct|
            ct.wait
          rescue StandardError => e
            first_error ||= e
          end
        end.wait
      end

      return Failure(first_error) if first_error

      Success(additions.map do |addition|
        repo_data = space.add_repo(addition.fetch(:reference), relative_path: addition.fetch(:relative_path), now: now.call)
        { space: space, repo: repo_data, reference: addition.fetch(:reference), path: addition.fetch(:path) }
      end)
    end

    def repos(from: Dir.pwd)
      current(from:).fmap(&:repos)
    end

    private

    def clone_addition(addition, scm:, cloner:, mise_client:, reporter: nil)
      reporter&.start(addition)
      fetch_addition(addition, scm:, cloner:)
      reporter&.trust(addition)
      mise_client.trust(addition.fetch(:path))
      reporter&.finish(addition)
      addition
    rescue StandardError
      reporter&.fail(addition)
      raise
    end

    # Prefer a fast local copy of the evergreen repo; fall back to a network
    # clone only when no evergreen copy is available.
    def fetch_addition(addition, scm:, cloner:)
      reference = addition.fetch(:reference)
      destination = addition.fetch(:path)
      source = addition.fetch(:evergreen_source)

      if source&.directory?
        actual_cloner = cloner || Pristine::Cloner.new(base_dir: config.evergreen_dir)
        result = actual_cloner.call(name: reference.full_name, into: destination.dirname.to_s)
        raise GitError, "clone failed (copy): #{result.failure}" if result.failure?
      else
        result = scm.clone(reference.clone_url, destination.to_s)
        raise GitError, "clone failed: #{result.failure[:stderr]}" if result.failure?
      end
    end

    def prepare_repo_additions(space, specs)
      evergreen_dir = config.evergreen_dir
      additions = specs.map do |spec|
        reference = RepoResolver.new(config).resolve(spec)
        relative_path = Pathname.new("repos").join(reference.directory_name)
        destination = space.path.join(relative_path)

        ensure_repo_can_be_added!(space, reference, relative_path, destination)

        {
          reference: reference,
          relative_path: relative_path,
          path: destination,
          evergreen_source: evergreen_dir && reference.evergreen_path(evergreen_dir)
        }
      end

      duplicate_paths = additions
        .map { |addition| addition.fetch(:path).to_s }
        .tally
        .select { |_path, count| count > 1 }
        .keys
      unless duplicate_paths.empty?
        raise RepoExistsError, "Multiple repos resolve to the same destination: #{duplicate_paths.join(', ')}"
      end

      additions
    end

    def ensure_repo_can_be_added!(space, reference, relative_path, destination)
      raise RepoExistsError, "Repo destination already exists: #{destination}" if destination.exist?

      existing = space.repos.find do |repo|
        repo["full_name"] == reference.full_name ||
          repo["path"] == relative_path.to_s ||
          repo["name"] == reference.name
      end
      return unless existing

      raise RepoExistsError, "Repo '#{reference.full_name}' already exists in #{space.id}"
    end

    def metadata_for(id:, title:, timestamp:)
      iso_timestamp = timestamp.iso8601
      {
        "version" => 1,
        "id" => id,
        "title" => title,
        "status" => "active",
        "created_at" => iso_timestamp,
        "updated_at" => iso_timestamp,
        "repos" => [],
        "notes" => [],
        "tickets" => [],
        "tags" => []
      }
    end

    def write_readme(path:, title:, id:, timestamp:)
      AtomicWrite.write(path.join("README.md"), <<~README)
        # #{title}

        Space: `#{id}`
        Created: #{timestamp.iso8601}

        ## Organization

        - `.space.yml` tracks the space identity, status, and associated metadata.
        - `repos/` contains cloned Git repositories for this work.
        - `notes/` is for task notes, scratch docs, and thinking-in-progress.
        - `artifacts/` is for logs, screenshots, generated files, and other ephemera.
        - `tmp/` is the workspace-local scratch directory. Use it instead of `/tmp` or
          `/var/tmp`; when using `mktemp`, use `tmp/` as the base directory.
        - The space is a Git repository so notes and artifacts are versioned.
          `repos/` and `tmp/` are gitignored, keeping the cloned repos and scratch
          out of the space's history (each clone keeps its own Git repo).
      README
    end

    # Make the space itself a Git repo so its notes/artifacts are versioned.
    # `repos/` and `tmp/` are ignored: the clones keep their own `.git`, and a
    # space-level `git add` must never pull them in as embedded-repo gitlinks.
    def init_git(path:, id:, git_client:)
      write_gitignore(path)
      git_client.init(path)
      git_client.commit_all(path, "Initialize space #{id}")
    end

    def write_gitignore(path)
      AtomicWrite.write(path.join(".gitignore"), <<~GITIGNORE)
        repos/
        tmp/
      GITIGNORE
    end

    def unique_id(base_id)
      candidate = base_id
      counter = 2

      while spaces_dir.join(candidate).exist?
        candidate = "#{base_id}-#{counter}"
        counter += 1
      end

      candidate
    end

    def looks_like_path?(value)
      value.include?(File::SEPARATOR) || value.start_with?("~") || value.start_with?(".")
    end

    def matching_spaces(value)
      all = list
      exact = all.select { |space| space.id == value }
      return exact unless exact.empty?

      suffix = all.select { |space| space.id.end_with?("-#{value}") }
      return suffix unless suffix.empty?

      prefix = all.select { |space| space.id.start_with?(value) }
      return prefix unless prefix.empty?

      all.select { |space| space.id.include?(value) }
    end
  end
end
