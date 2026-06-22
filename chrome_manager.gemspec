# frozen_string_literal: true

Gem::Specification.new do |spec|
  spec.name = 'chrome_manager'
  spec.version = '0.1.0'
  spec.summary = 'Lease visible Chrome instances for agents'
  spec.authors = ['foobar']
  spec.files = Dir['lib/**/*.rb'] + Dir['bin/*']
  spec.executables = ['chrome-manager']
  spec.require_paths = ['lib']
  spec.required_ruby_version = '>= 3.0'
  spec.add_dependency 'bg_chrome'
end
