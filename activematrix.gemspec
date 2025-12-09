# frozen_string_literal: true

require_relative 'lib/active_matrix/version'

Gem::Specification.new do |spec|
  spec.name             = 'activematrix'
  spec.version          = ActiveMatrix::VERSION
  spec.authors          = ['Abdelkader Boudih', 'Alexander Olofsson']
  spec.email            = ['terminale@gmail.com', 'ace@haxalot.com']

  spec.summary          = 'Rails-native Matrix SDK for building multi-agent bot systems and real-time communication'
  spec.description      = <<~DESC
    ActiveMatrix is a comprehensive Rails-native Matrix SDK that enables developers to build sophisticated multi-agent bot systems
    and real-time communication features. This gem provides deep Rails integration with ActiveRecord models, state machines for
    bot lifecycle management, multi-tiered memory systems, intelligent event routing, connection pooling, and built-in
    inter-agent communication. Perfect for building chatbots, automation systems, monitoring agents, and collaborative AI
    systems within Rails applications. Features include command handling, room management, media support, end-to-end encryption
    capabilities, and extensive protocol support (CS, AS, IS, SS).
  DESC
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

  spec.add_dependency 'activejob', '>= 8.0', '< 9'
  spec.add_dependency 'activerecord', '>= 8.0', '< 9'
  spec.add_dependency 'async', '>= 2.21'
  spec.add_dependency 'bcrypt', '~> 3.1'
  spec.add_dependency 'railties', '>= 8.0', '< 9'
  spec.add_dependency 'state_machines-activerecord', '>= 0.100.0'
  spec.add_dependency 'zeitwerk', '~> 2.6'

  spec.metadata = {
    'rubygems_mfa_required' => 'true',
    'homepage_uri' => spec.homepage,
    'source_code_uri' => 'https://github.com/seuros/activematrix',
    'changelog_uri' => 'https://github.com/seuros/activematrix/blob/master/CHANGELOG.md',
    'documentation_uri' => 'https://rubydoc.info/gems/activematrix',
    'bug_tracker_uri' => 'https://github.com/seuros/activematrix/issues',
    'wiki_uri' => 'https://github.com/seuros/activematrix/wiki'
  }

  # Tags for better discoverability on RubyGems
  spec.metadata['tags'] = [
    'matrix', 'matrix-protocol', 'matrix-sdk', 'matrix-api', 'matrix-client',
    'rails', 'rails-engine', 'activerecord', 'activejob', 'rails-integration',
    'bot', 'chatbot', 'multi-agent', 'agent-system', 'bot-framework',
    'real-time', 'messaging', 'communication', 'chat', 'state-machine'
  ].join(', ')
end
