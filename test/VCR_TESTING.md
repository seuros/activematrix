# VCR Testing Guide for ActiveMatrix

This guide explains how to use VCR (Video Cassette Recorder) for testing ActiveMatrix with real Matrix server interactions.

## Overview

VCR records HTTP interactions with the Matrix server and replays them during test runs. This provides:
- Realistic test data from actual server responses
- Fast, deterministic tests without network dependencies
- Documentation of the Matrix API through recorded cassettes

## Test Credentials

The following test accounts are available on arena.seuros.net:

- **testuser**: `@testuser:arena.seuros.net` (password: `testuser12345678`)
- **seuros**: `@seuros:arena.seuros.net` (password: `seuros12345678`)

## Environment Variables

Configure testing with these environment variables:

```bash
# VCR recording mode
VCR_MODE=once          # Default: replay existing cassettes
VCR_MODE=new_episodes  # Record new interactions
VCR_MODE=record        # Re-record all interactions
VCR_MODE=none          # Disable VCR

# Test server configuration
MATRIX_TEST_SERVER=https://arena.seuros.net
MATRIX_TEST_USER=testuser
MATRIX_TEST_PASSWORD=testuser12345678

# Enable VCR tests
RUN_VCR_TESTS=true     # Run tests that use real server
USE_REAL_SERVER=true   # Force real server connections
```

## Running VCR Tests

### Run all tests with existing cassettes
```bash
rake test
```

### Record new cassettes for VCR tests
```bash
RUN_VCR_TESTS=true VCR_MODE=new_episodes rake test
```

### Re-record all cassettes
```bash
RUN_VCR_TESTS=true VCR_MODE=record rake test
```

### Run specific VCR test
```bash
RUN_VCR_TESTS=true ruby -Ilib:test test/vcr_integration_test.rb
```

## Writing VCR Tests

### Basic VCR test
```ruby
def test_matrix_operation_with_vcr
  with_vcr_cassette('descriptive_name') do
    client = create_vcr_client
    # Perform Matrix operations
    response = client.some_method
    assert response.success?
  end
end
```

### Custom cassette options
```ruby
def test_with_custom_options
  options = vcr_options_for_test(:my_test)
  with_vcr_cassette('custom_test', options) do
    # Test code
  end
end
```

### Test with real server (no cassette)
```ruby
def test_real_server_interaction
  skip unless use_real_matrix_server?
  
  without_vcr do
    # Direct server interaction
  end
end
```

## Cassette Organization

Cassettes are organized by functionality:

```
test/fixtures/vcr_cassettes/
├── api/
│   ├── cs_protocol/    # Client-Server API
│   ├── ss_protocol/    # Server-Server API
│   └── creation/       # API creation/discovery
├── client/
│   ├── auth/          # Authentication
│   ├── sync/          # Sync operations
│   └── rooms/         # Room operations
└── bot/               # Bot functionality
```

## Refreshing Cassettes

To update cassettes when the Matrix API changes:

```ruby
# In your test file
VCRHelper.refresh_cassettes_for(MyTestClass) do
  # Run tests
end
```

Or manually:
```bash
rm -rf test/fixtures/vcr_cassettes/path/to/cassette
RUN_VCR_TESTS=true VCR_MODE=record ruby -Ilib:test test/specific_test.rb
```

## Security Notes

VCR automatically filters sensitive data:
- Access tokens are replaced with `<ACCESS_TOKEN>`
- Passwords are replaced with `<PASSWORD>`
- Server URLs can be anonymized
- User IDs are preserved for test accounts only

## Debugging VCR

### Enable debug output
```ruby
VCR.configure do |c|
  c.debug_logger = $stderr
end
```

### Inspect cassette contents
```bash
cat test/fixtures/vcr_cassettes/my_cassette.json | jq .
```

### Common issues

1. **Cassette not found**: Run with `VCR_MODE=record` to create it
2. **Request doesn't match**: Check URI, method, and body matching
3. **Sensitive data in cassette**: Add filters in `test_helper.rb`

## Best Practices

1. **Name cassettes descriptively**: Use the pattern `feature/action_context`
2. **Keep cassettes small**: Record focused interactions
3. **Version control cassettes**: Commit them for consistent CI builds
4. **Update cassettes regularly**: Re-record when API changes
5. **Use test prefixes**: Mark test rooms/data with `[TEST]`
6. **Clean up test data**: Use `cleanup_test_rooms` after tests