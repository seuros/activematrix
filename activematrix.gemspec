# frozen_string_literal: true

require_relative 'lib/active_matrix/version'

Gem::Specification.new do |spec|
  spec.name             = 'activematrix'
  spec.version          = ActiveMatrix::VERSION
  spec.authors          = ['Abdelkader Boudih', 'Alexander Olofsson']
  spec.email            = ['terminale@gmail.com', 'ace@haxalot.com']

  spec.summary          = 'Rails-native Matrix bot framework backed by a Rust daemon'
  spec.description      = <<~DESC
    ActiveMatrix runs Matrix bots inside Rails applications. The activematrixd daemon (Rust) owns every
    Matrix connection: it syncs, mirrors room state into PostgreSQL, and sends what bots write to an outbox.
    Bot handlers run as ActiveJob jobs and read room state through Active Record models.
  DESC
  spec.homepage         = 'https://github.com/seuros/activematrix'
  spec.license          = 'MIT'

  spec.required_ruby_version = '>= 4.0'

  spec.files            = Dir['{app,config,db,lib}/**/*', 'exe/*', 'LICENSE.txt', 'README.md', 'CHANGELOG.md']
                          .select { File.file?(it) }
  spec.bindir           = 'exe'
  spec.executables      = ['activematrix']

  # Platform gems carry the prebuilt daemon; the ruby-platform gem carries
  # only the launcher, which explains how to get a binary.
  if (gem_platform = ENV.fetch('ACTIVEMATRIX_GEM_PLATFORM', nil))
    spec.platform = gem_platform
    spec.files += ['libexec/activematrixd']
  end

  spec.add_dependency 'activejob', '>= 8.1', '< 9'
  spec.add_dependency 'activerecord', '>= 8.1', '< 9'
  spec.add_dependency 'bcrypt', '~> 3.1'
  spec.add_dependency 'pg', '~> 1.6'
  spec.add_dependency 'railties', '>= 8.1', '< 9'
  spec.add_dependency 'state_machines-activerecord', '>= 0.100.0'
  spec.add_dependency 'zeitwerk', '~> 2.7'

  spec.metadata = {
    'rubygems_mfa_required' => 'true',
    'source_code_uri' => 'https://github.com/seuros/activematrix',
    'changelog_uri' => 'https://github.com/seuros/activematrix/blob/master/CHANGELOG.md',
    'bug_tracker_uri' => 'https://github.com/seuros/activematrix/issues'
  }
end
