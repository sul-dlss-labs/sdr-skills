# frozen_string_literal: true

module SdrOps
  # List and change an object's file sets (structural.contains). Moving files between them is Files#move.
  # File sets are referred to by externalIdentifier or label; a label that matches more than one is an error.
  # Changes follow the same rules as other content changes (a version this run opened; dry run by default).
  class FileSets
    def initialize(context)
      @context = context
    end

    # @return [Array<Hash>] one row per file set, in order
    def list(druid)
      state = @context.state(druid)
      state.cocina.structural.contains.each_with_index.map do |fs, index|
        { druid: state.druid, position: index + 1, id: fs.externalIdentifier, label: fs.label,
          type: fs.type.split('/').last, files: fs.structural.contains.map(&:filename) }
      end
    end

    # Add an empty file set (at `position`, 1-based; default last). Labels must be unique, so they can be referred to.
    def add(druid, label:, type: 'file', position: nil)
      state = editable(druid)
      sets = state.cocina.structural.contains
      raise Skip, "#{state.druid} already has a file set labelled #{label.inspect}" if sets.any? { it.label == label }

      new_set = Cocina::Models::FileSet.new(type: Files.file_set_type(type), externalIdentifier: Files.file_set_id(state.druid),
                                            label:, version: state.version, structural: { contains: [] })
      @context.files.save_file_sets(state, 'filesets.add', insert(sets, new_set, position),
                                    args: { label:, type:, position: }.compact)
    end

    # Rename and/or retype a file set.
    def update(druid, file_set, label: nil, type: nil)
      raise UsageError, 'Give a new --label and/or --type' unless label || type

      state = editable(druid)
      target = find!(state, file_set)
      changed = target.new(label: label || target.label, type: type ? Files.file_set_type(type) : target.type)
      raise Skip, "#{state.druid} #{file_set}: nothing to change" if changed == target

      sets = state.cocina.structural.contains.map { it.externalIdentifier == target.externalIdentifier ? changed : it }
      @context.files.save_file_sets(state, 'filesets.set', sets,
                                    args: { file_set: target.externalIdentifier, label:, type: }.compact)
    end

    # Remove file sets. A file set with files is refused unless `with_files: true`, which removes them too.
    def remove(druid, file_sets, with_files: false)
      state = editable(druid)
      targets = file_sets.map { find!(state, it) }
      nonempty = targets.reject { it.structural.contains.empty? }
      if nonempty.any? && !with_files
        raise Skip, "#{state.druid}: #{nonempty.map(&:label).join(', ')} still contain files; move them first, or pass " \
                    '--with-files to remove them too'
      end

      ids = targets.map(&:externalIdentifier)
      sets = state.cocina.structural.contains.reject { ids.include?(it.externalIdentifier) }
      @context.files.save_file_sets(state, 'filesets.remove', sets,
                                    args: { file_sets: ids, with_files:,
                                            files_removed: nonempty.flat_map { it.structural.contains.map(&:filename) } })
    end

    # Put the file sets in the given order; every file set must be named once.
    def order(druid, file_sets)
      state = editable(druid)
      ordered = file_sets.map { find!(state, it) }
      current = state.cocina.structural.contains
      unless ordered.map(&:externalIdentifier).sort == current.map(&:externalIdentifier).sort &&
             ordered.uniq(&:externalIdentifier).size == ordered.size
        raise UsageError, "Name each of #{state.druid}'s #{current.size} file sets exactly once " \
                          "(#{current.map(&:label).join(', ')})"
      end
      raise Skip, "#{state.druid}: file sets are already in that order" if ordered == current

      @context.files.save_file_sets(state, 'filesets.order', ordered, args: { order: ordered.map(&:externalIdentifier) })
    end

    def find!(state, ref)
      matches = state.cocina.structural.contains.select { it.externalIdentifier == ref || it.label == ref }
      raise Skip, "#{state.druid} has no file set #{ref.inspect}" if matches.empty?
      raise UsageError, "#{ref.inspect} matches #{matches.size} file sets in #{state.druid}; use the ID" if matches.size > 1

      matches.first
    end

    def self.insert(list, item, position)
      index = position ? (position.to_i - 1).clamp(0, list.size) : list.size
      list.dup.insert(index, item)
    end

    private

    def editable(druid)
      @context.fresh_state(druid).tap { @context.versions.require_own_version!(it) }
    end

    def insert(list, item, position) = self.class.insert(list, item, position)
  end
end
