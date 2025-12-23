# Testing the MCP Daemon

The MCP (Model Context Protocol) server in Assay communicates over stdio using JSON-RPC. This guide explains how to test it.

## Current Testing Approach

### Unit Tests (Existing)

The existing tests in `test/assay_mcp_test.exs` test the `MCP.handle_rpc/2` function directly, which is the core request handler. These are fast and don't require stdio simulation:

```elixir
test "initialize handshake", %{state: state} do
  request = %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{"clientInfo" => %{"name" => "test"}}
  }

  {reply, new_state, :continue} = MCP.handle_rpc(request, state)
  
  assert reply["result"]["protocolVersion"] == "2024-11-05"
  assert new_state.initialized?
end
```

### Integration Tests (New)

For testing the full stdio-based server loop, you can use the integration test helper in `test/assay_mcp_integration_test.exs`. This simulates stdio communication by:

1. Spawning a process that simulates the server's stdio loop
2. Sending JSON-RPC messages via message passing
3. Collecting responses

## Running Tests

### Unit Tests Only
```bash
mix test test/assay_mcp_test.exs
```

### Integration Tests
```bash
mix test test/assay_mcp_integration_test.exs
```

### All MCP Tests
```bash
mix test test/assay_mcp*
```

## Manual Testing

You can also test the MCP server manually by running it and sending JSON-RPC messages. The server
uses the same framing as LSP/MCP: every JSON object must be preceded by
`Content-Length: <bytes>\r\n\r\n`.

### 1. Start the MCP Server

```bash
mix assay.mcp
```

### 2. Send JSON-RPC Messages

Define a helper to emit framed JSON and pipe requests into the server:

```bash
# In one terminal
mix assay.mcp

# In another terminal
frame() {
  local json="$1"
  local len
  len=$(printf '%s' "$json" | wc -c | tr -d ' ')
  printf 'Content-Length: %d\r\n\r\n%s' "$len" "$json"
}

frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"test"}}}' \
  | mix assay.mcp
```

### 3. Example MCP Client Script

Create a simple test script:

```elixir
# test_mcp_client.exs
messages = [
  %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{"clientInfo" => %{"name" => "test-client"}}
  },
  %{
    "jsonrpc" => "2.0",
    "method" => "notifications/initialized"
  },
  %{
    "jsonrpc" => "2.0",
    "id" => 2,
    "method" => "tools/list"
  },
  %{
    "jsonrpc" => "2.0",
    "id" => 3,
    "method" => "tools/call",
    "params" => %{
      "name" => "assay.analyze",
      "arguments" => %{"formats" => ["text"]}
    }
  }
]

# Send each message with MCP framing
Enum.each(messages, fn msg ->
  json = JSON.encode!(msg)
  IO.write("Content-Length: #{byte_size(json)}\r\n\r\n#{json}")
end)
```

Then run:
```bash
elixir test_mcp_client.exs | mix assay.mcp
```

## Testing with Real MCP Clients

You can also test with actual MCP clients:

### Using the MCP Inspector

1. Install the MCP Inspector tool
2. Configure it to connect to `mix assay.mcp`
3. Test the full protocol

### Using Claude Desktop or Other MCP Clients

Configure your MCP client to use:
- Command: `mix assay.mcp`
- Args: `[]`
- Working directory: Your project root

## Test Coverage

The tests cover:

- ✅ Initialize handshake
- ✅ Tools listing
- ✅ Tool invocation
- ✅ Error handling (invalid JSON, unknown methods)
- ✅ Shutdown requests
- ✅ Notification handling
- ✅ Tool call ID preservation
- ✅ Argument forwarding

## Adding New Tests

When adding new MCP functionality:

1. **Unit tests first**: Test `MCP.handle_rpc/2` directly for fast feedback
2. **Integration tests**: Test the full stdio loop if the feature involves I/O
3. **Manual testing**: Verify with real MCP clients before merging

Example unit test pattern:

```elixir
test "new feature", %{state: state} do
  request = %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "new/method",
    "params" => %{}
  }

  {reply, new_state, action} = MCP.handle_rpc(request, state)
  
  # Assertions
  assert reply["result"]["key"] == "expected_value"
  assert action == :continue
end
```
