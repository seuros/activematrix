# ActiveMatrix Test Suite

## Running Tests

```bash
# Run all tests
bin/rails test

# Run with verbose output (shows full backtraces)
bin/rails test -v

# Run specific test file
bin/rails test test/client_test.rb

# Run specific test by line number
bin/rails test test/client_test.rb:52

# Using mtest (maxitest executable)
bundle exec mtest test/client_test.rb:52
```

## Maxitest Features

This test suite uses maxitest for enhanced testing capabilities:

### Thread Leak Detection
Maxitest automatically detects thread leaks. If a test creates threads that aren't properly cleaned up, you'll see warnings like:
```
ThreadLeak: Test left 1 thread(s) behind!
```

### Timeout Detection
Tests that hang will be detected and reported.

### Better Output
- Red-green colored test output
- Ctrl+C interrupts tests and shows failures with pastable rerun snippet
- Use `-v` flag for full backtraces on errors

### Test Helpers

```ruby
# Temporarily change environment variables
with_env FOO: "bar" do
  # test code
end

# Capture stdout/stderr
output = capture_stdout { puts "hello" }
assert_equal "hello\n", output

# Skip tests conditionally
pending "broken on CI", if: ENV["CI"] do
  # test code
end
```

## VCR Testing

To run tests against real Matrix server:
```bash
USE_VCR_FOR_PROTOCOL_TESTS=true VCR_MODE=new_episodes bin/rails test
```

See `docs/vcr-testing.md` for details.

## Cache Management

The test suite automatically clears Rails cache before each test to ensure isolation.