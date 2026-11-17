require_relative "lib/kestra"

Gem::Specification.new do |spec|
  spec.name = "kestra"
  spec.version = Kestra::VERSION
  spec.authors = ["Kestra"]
  spec.email = ["hello@kestra.io"]
  spec.summary = "Send outputs, metrics and logs from Ruby script tasks to Kestra."
  spec.homepage = "https://github.com/kestra-io/libs"
  spec.license = "Apache-2.0"
  spec.required_ruby_version = ">= 2.7"
  spec.files = ["lib/kestra.rb", "README.md"]
  spec.metadata = {
    "source_code_uri" => "https://github.com/kestra-io/libs/tree/main/ruby",
    "bug_tracker_uri" => "https://github.com/kestra-io/libs/issues"
  }
end
