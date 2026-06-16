# frozen_string_literal: true

require "fileutils"
require "async"
require "async/semaphore"
require "pathname"
require "time"

module SpaceCadet
  class SpaceStore
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

    def create(title)
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
      state.touch_recent(id)
      space
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
        return Space.load(File.expand_path(value))
      end

      matches = matching_spaces(value)
      return matches.first if matches.length == 1

      if matches.empty?
        raise NotFoundError, "Could not find space matching '#{value}' in #{spaces_dir}"
      end

      raise AmbiguousSpaceError, "Space '#{value}' is ambiguous: #{matches.map(&:id).join(', ')}"
    end

    def current(from: Dir.pwd)
      space = current_from_pwd(from:)
      return space if space

      raise CurrentSpaceMissingError, "No current space found from #{from}. Run this inside a space or pass a space id."
    end

    def current_from_pwd(from: Dir.pwd)
      path = Pathname.new(File.expand_path(from.to_s))
      path = path.dirname if path.file?

      loop do
        return Space.load(path) if path.join(Space::METADATA_FILE).exist?
        break if path.root?

        path = path.parent
      end

      nil
    end

    def path_for(identifier = nil)
      find(identifier).path
    end

    def use(identifier)
      space = find(identifier)
      state.touch_recent(space.id)
      space
    end

    def add_repo(spec, from: Dir.pwd, git_client: GitClient.new, mise_client: MiseClient.new)
      add_repos([spec], from:, git_client:, mise_client:).first
    end

    def add_repos(specs, from: Dir.pwd, git_client: GitClient.new, mise_client: MiseClient.new, reporter: nil)
      add_repos_to(current(from:), specs, git_client:, mise_client:, reporter:)
    end

    def add_repos_to(space, specs, git_client: GitClient.new, mise_client: MiseClient.new, reporter: nil)
      additions = prepare_repo_additions(space, specs)

      Warnings.without_experimental do
        Async do |task|
          semaphore = Async::Semaphore.new(MAX_CONCURRENT_CLONES, parent: task)

          tasks = additions.map do |addition|
            semaphore.async do
              clone_addition(addition, git_client:, mise_client:, reporter:)
            end
          end

          wait_for_clone_tasks(tasks)
        end.wait
      end

      additions.map do |addition|
        repo_data = space.add_repo(addition.fetch(:reference), relative_path: addition.fetch(:relative_path), now: now.call)
        { space: space, repo: repo_data, reference: addition.fetch(:reference), path: addition.fetch(:path) }
      end
    end

    def repos(from: Dir.pwd)
      current(from:).repos
    end

    private

    def clone_addition(addition, git_client:, mise_client:, reporter: nil)
      reporter&.start(addition)
      fetch_addition(addition, git_client:)
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
    def fetch_addition(addition, git_client:)
      source = addition.fetch(:evergreen_source)
      if source&.directory?
        git_client.copy(source, addition.fetch(:path))
      else
        git_client.clone(addition.fetch(:reference).clone_url, addition.fetch(:path))
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

    def wait_for_clone_tasks(tasks)
      errors = []
      tasks.each do |task|
        task.wait
      rescue StandardError => e
        errors << e
      end

      raise errors.first unless errors.empty?
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
      README
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
