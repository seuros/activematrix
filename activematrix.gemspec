# frozen_string_literal: true

require_relative 'lib/active_matrix/version'

Gem::Specification.new do |spec|
  spec.name             = 'activematrix'
  spec.version          = ActiveMatrix::VERSION
  spec.authors          = ['Abdelkader Boudih', 'Alexander Olofsson']
  spec.email            = ['terminale@gmail.com', 'ace@haxalot.com']

  spec.summary          = 'Rails gem for connecting to Matrix protocol'
  spec.description      = 'A Ruby on Rails gem that provides seamless integration with the Matrix protocol, enabling Rails applications to connect and communicate with Matrix servers.'
  spec.homepage         = 'https://github.com/seuros/activematrix'
  spec.license          = 'MIT'

  spec.extra_rdoc_files = %w[CHANGELOG.md LICENSE.txt README.md]
  spec.files            = Dir['lib/**/*', 'app/**/*'] + spec.extra_rdoc_files

  spec.add_development_dependency 'maxitest'
  spec.add_development_dependency 'mocha'
  spec.add_development_dependency 'ostruct'
  spec.add_development_dependency 'rake'
  spec.add_development_dependency 'rubocop'
  spec.add_development_dependency 'rubocop-minitest'
  spec.add_development_dependency 'rubocop-performance'
  spec.add_development_dependency 'rubocop-rails'
  spec.add_development_dependency 'simplecov'
  spec.add_development_dependency 'sqlite3', '~> 2.0'
  spec.add_development_dependency 'syslog'
  spec.add_development_dependency 'test-unit'
  spec.add_development_dependency 'vcr', '~> 6.2'
  spec.add_development_dependency 'webmock', '~> 3.19'

  spec.required_ruby_version = '>= 3.4'

  spec.add_dependency 'activerecord', '~> 8.0'
  spec.add_dependency 'bcrypt', '~> 3.1'
  spec.add_dependency 'concurrent-ruby', '~> 1.2'
  spec.add_dependency 'railties', '~> 8.0'
  spec.add_dependency 'state_machines-activerecord', '~> 0.40.0'
  spec.add_dependency 'zeitwerk', '~> 2.6'

  spec.metadata['rubygems_mfa_required'] = 'true'
end
