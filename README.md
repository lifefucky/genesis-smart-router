# genesis-smart-router

## Requirements

- **MRI Ruby >= 3.2.0** (macOS system Ruby 2.6 is not supported)
- Standard library only: `json`, `csv`, `date`, `time`

The interpreter version is enforced in three places:

- `lib/smart_router.rb` raises `LoadError` on older Ruby
- `Gemfile` has `ruby ">= 3.2.0"` (Bundler refuses older interpreters)
- `.ruby-version` pins `3.2.11`

Local MRI is Homebrew `ruby@3.2`. After a new terminal session:

```bash
ruby -v   # ruby 3.2.11
ruby -Ilib:test test/smart_router/run_inputs_test.rb
```
