# frozen_string_literal: true

required = Gem::Version.new("3.2.0")
if Gem::Version.new(RUBY_VERSION) < required
  abort "SmartRouter requires Ruby 3.2.0+ (running #{RUBY_VERSION})"
end

task default: :test

desc "Run tests (Ruby >= 3.2)"
task :test do
  sh "ruby -Ilib:test -e \"Dir['test/**/*_test.rb'].each { |f| require './' + f }\""
end
