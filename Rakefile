# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'English'
require 'shellwords'

# padded_cell: test classes in parallel workers, every test in its own forked
# cell. Arguments in ARGS:
#   rake test ARGS="-j 4 test/active_matrix/mxid_test.rb:12"
desc 'Run the test suite with padded_cell (arguments in ARGS)'
task :test do
  sh 'bundle', 'exec', 'padded_cell', '--isolation', 'test', *Shellwords.split(ENV.fetch('ARGS', ''))
end

task default: :test

# System tests run the real daemon against the dummy app, served over HTTP,
# and a homeserver; padded_cell leaves test/system out of `rake test`.
namespace :test do
  desc 'System tests: activematrixd, the app over HTTP, activematrix-fakehs (ARGS as for test)'
  task :system do
    sh 'cargo', 'build', '--locked', '-p', 'activematrixd', '-p', 'activematrix-fakehs'
    # The workers' databases (activematrix_system_0...) are copied from it.
    Dir.chdir('test/dummy') do
      sh({ 'RAILS_ENV' => 'test', 'ACTIVEMATRIX_TEST_DATABASE' => 'activematrix_system' }, 'bin/rails', 'db:prepare')
    end
    args = Shellwords.split(ENV.fetch('ARGS', ''))
    args << 'test/system' unless args.any? { it.start_with?('test/') }
    sh({ 'ACTIVEMATRIX_INSTALL_DIR' => File.join(cargo_target_root, 'debug') },
       'bundle', 'exec', 'padded_cell', '--isolation', 'test', '--timeout', '120', *args)
  end

  desc 'The system tests against Synapse: docker compose --profile contract up -d first'
  task :contract do
    ENV['ACTIVEMATRIX_SYNAPSE_URL'] ||= 'http://127.0.0.1:8008'
    ENV['ACTIVEMATRIX_SYNAPSE_SECRET'] ||= 'contract-registration-secret'
    Rake::Task['test:system'].invoke
  end
end

# The daemon's tests load the engine's tables from a SQL snapshot, so the
# Rust suite needs no Ruby. The snapshot is dumped from a database loaded
# from schema.rb (db:test:prepare), never a migrated one, so it is the same
# wherever it is taken; CI fails when it is stale.
#
# pg_dump must be at least the server's major version. The default runs the
# compose container's own; CI points PG_DUMP at the service container.
SCHEMA_SNAPSHOT = 'crates/activematrixd/tests/schema.sql'

namespace :active_matrix do
  desc "Dump the engine's tables into #{SCHEMA_SNAPSHOT}"
  task :schema_snapshot do
    Dir.chdir('test/dummy') { sh({ 'RAILS_ENV' => 'test' }, 'bin/rails', 'db:test:prepare') }
    pg_dump = Shellwords.split(ENV.fetch('PG_DUMP', 'docker compose exec -T postgres pg_dump'))
    sql = IO.popen([*pg_dump, '--username=activematrix', '--schema-only', '--no-owner', '--no-privileges',
                    '--table=active_matrix_*', 'activematrix_test'], &:read)
    abort 'pg_dump failed' unless $CHILD_STATUS.success?

    # Drop what changes between runs: the random \\restrict key and the
    # server and client versions.
    sql = sql.lines.grep_v(/\A(\\(un)?restrict |-- Dumped (from|by) )/).join
    File.write(SCHEMA_SNAPSHOT, sql)
    puts "wrote #{SCHEMA_SNAPSHOT}"
  end
end

# ---------------------------------------------------------------------------
# Packaging: one gem per platform with the activematrixd binary in libexec/,
# plus a platformless gem whose launcher explains how to get a binary.
# Follows stampeded/ruby.
# ---------------------------------------------------------------------------

require 'fileutils'
require 'json'

# musl is not optional: most container images are Alpine, where a gnu binary
# fails at exec with a linker error rather than anything actionable.
PLATFORMS = {
  'arm64-darwin' => 'aarch64-apple-darwin',
  'x86_64-darwin' => 'x86_64-apple-darwin',
  'aarch64-linux-gnu' => 'aarch64-unknown-linux-gnu',
  'x86_64-linux-gnu' => 'x86_64-unknown-linux-gnu',
  'aarch64-linux-musl' => 'aarch64-unknown-linux-musl',
  'x86_64-linux-musl' => 'x86_64-unknown-linux-musl'
}.freeze

LIBEXEC = File.expand_path('libexec', __dir__)

# Ask cargo where it builds: CARGO_TARGET_DIR relocates it, and a hardcoded
# path would copy a missing or stale binary.
def cargo_target_root
  @cargo_target_root ||= JSON.parse(`cargo metadata --no-deps --format-version 1`).fetch('target_directory')
end

# Bundler's environment is stripped: under `bundle exec` it re-resolves the
# gemspec against the lockfile, and a platform gem does not match the running
# platform's full triple. The platform is set inside the block, because
# with_unbundled_env restores the environment Bundler snapshotted at load.
def build_gem(platform = nil)
  FileUtils.mkdir_p('pkg')
  Bundler.with_unbundled_env do
    ENV['ACTIVEMATRIX_GEM_PLATFORM'] = platform
    name = ['activematrix', ActiveMatrix::VERSION, platform].compact.join('-')
    sh 'gem', 'build', 'activematrix.gemspec', '--output', "pkg/#{name}.gem"
  end
end

# 0755 whatever the source's mode: a binary packaged 0700 runs for root only.
def stage_binary(source)
  FileUtils.mkdir_p(LIBEXEC)
  binary = File.join(LIBEXEC, 'activematrixd')
  FileUtils.cp(source, binary)
  FileUtils.chmod(0o755, binary)
end

desc 'Build the daemon binary for one rubygems platform into libexec/'
task :build_binary, [:platform] do |_t, args|
  platform = args[:platform] or abort 'usage: rake build_binary[arm64-darwin]'
  target = PLATFORMS.fetch(platform) { abort "unknown platform #{platform}" }

  sh 'cargo', 'build', '--release', '--locked', '-p', 'activematrixd', '--target', target
  stage_binary(File.join(cargo_target_root, target, 'release', 'activematrixd'))
end

desc 'Package the gem for one platform, binary included'
task :package, [:platform] do |_t, args|
  platform = args[:platform] or abort 'usage: rake package[arm64-darwin]'
  Rake::Task['build_binary'].invoke(platform)
  build_gem(platform)
end

# The release workflow builds each binary on its own runner, then packages
# them all in one job.
desc 'Package the gem for one platform from an already built binary'
task :package_prebuilt, [:platform, :binary] do |_t, args|
  platform, binary = args.values_at(:platform, :binary)
  abort 'usage: rake package_prebuilt[x86_64-linux-gnu,path/to/activematrixd]' unless platform && binary
  abort "unknown platform #{platform}" unless PLATFORMS.key?(platform)
  abort "#{binary} is not a file" unless File.file?(binary)

  stage_binary(binary)
  build_gem(platform)
end

desc 'Package the platformless gem: launcher only, no binary'
task :package_generic do
  build_gem
end

desc 'List shippable platforms'
task :platforms do
  PLATFORMS.each { |gem_platform, rust| puts format('  %<gem>-20s %<rust>s', gem: gem_platform, rust:) }
end
