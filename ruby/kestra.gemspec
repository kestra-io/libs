Gem::Specification.new do |spec|
  spec.name = "kestra"
  # Set from the release tag in CI, like the Python package.
  spec.version = ENV.fetch("VERSION", "0.0.0").delete_prefix("v")
  spec.authors = ["Kestra"]
  spec.email = ["hello@kestra.io"]
  spec.summary = "Send outputs, metrics, logs and assets from Ruby script tasks to Kestra, and read the execution context."
  spec.homepage = "https://github.com/kestra-io/libs"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 2.7"
  spec.files = ["lib/kestra.rb", "README.md"]
  # logger stops being a default gem in Ruby 3.5, so Bundler needs it declared.
  spec.add_dependency "logger", "~> 1.4"
  spec.metadata = {
    "source_code_uri" => "https://github.com/kestra-io/libs/tree/main/ruby",
    "bug_tracker_uri" => "https://github.com/kestra-io/libs/issues"
  }
end
