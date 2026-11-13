# Descriptive metadata

Scripts change an object's description with `descriptive.update`, inside a version the run opened (or adopted with `versions.adopt`), like any other content change.

```ruby
sdr.versions.open(druid, description: 'Trim title whitespace') do
  sdr.descriptive.update(druid) do |description|        # a deep copy, as a Hash with symbol keys
    description[:title].each { it[:value] = it[:value].strip }
  end
end
```

- The block edits the Hash in place or returns a new one. The result is validated as `Cocina::Models::Description` before anything is saved; an invalid description stops the item.
- A block that changes nothing skips the item.
- The report lists the changed leaf paths (e.g. `title[0].value`) with before and after values, the first 20 of them. Paths are positional, so inserting into a list shows every later element as changed.
- The update is saved with the run's user and the `--reason` (or the version description) as the event description.
- There's no CLI command: description edits are specific enough that they belong in a reviewed script.
