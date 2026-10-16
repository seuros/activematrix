# frozen_string_literal: true

require 'bundler/gem_tasks'
require 'shellwords'

# padded_cell: test classes in parallel workers, every test in its own forked
# cell. Arguments in ARGS:
#   rake test ARGS="-j 4 test/active_matrix/mxid_test.rb:12"
desc 'Run the test suite with padded_cell (arguments in ARGS)'
task :test do
  sh 'bundle', 'exec', 'padded_cell', '--isolation', 'test', *Shellwords.split(ENV.fetch('ARGS', ''))
end

task default: :test

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

desc 'Build the daemon binary for one rubygems platform into libexec/'
task :build_binary, [:platform] do |_t, args|
  platform = args[:platform] or abort 'usage: rake build_binary[arm64-darwin]'
  target = PLATFORMS.fetch(platform) { abort "unknown platform #{platform}" }

  sh 'cargo', 'build', '--release', '--locked', '-p', 'activematrixd', '--target', target
  FileUtils.mkdir_p(LIBEXEC)
  binary = File.join(LIBEXEC, 'activematrixd')
  FileUtils.cp(File.join(cargo_target_root, target, 'release', 'activematrixd'), binary)
  FileUtils.chmod(0o755, binary)
end

desc 'Package the gem for one platform, binary included'
task :package, [:platform] do |_t, args|
  platform = args[:platform] or abort 'usage: rake package[arm64-darwin]'
  Rake::Task['build_binary'].invoke(platform)
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
