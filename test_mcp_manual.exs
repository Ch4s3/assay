#!/usr/bin/env elixir

# Manual test script for MCP daemon
# This script sends JSON-RPC messages to the MCP server and displays responses

messages = [
  # 1. Initialize
  %{
    "jsonrpc" => "2.0",
    "id" => 1,
    "method" => "initialize",
    "params" => %{
      "clientInfo" => %{
        "name" => "manual-test-client",
        "version" => "1.0.0"
      }
    }
  },
  # 2. Notification (no response expected)
  %{
    "jsonrpc" => "2.0",
    "method" => "notifications/initialized"
  },
  # 3. List tools
  %{
    "jsonrpc" => "2.0",
    "id" => 2,
    "method" => "tools/list"
  },
  # 4. Call the analyze tool
  %{
    "jsonrpc" => "2.0",
    "id" => 3,
    "method" => "tools/call",
    "params" => %{
      "name" => "assay.analyze",
      "arguments" => %{"formats" => ["text"]}
    }
  },
  # 5. Shutdown
  %{
    "jsonrpc" => "2.0",
    "id" => 4,
    "method" => "shutdown"
  }
]

IO.puts("=" <> String.duplicate("=", 60))
IO.puts("Manual MCP Daemon Test")
IO.puts("=" <> String.duplicate("=", 60))
IO.puts("")

# Send each message
Enum.each(messages, fn message ->
  json = Jason.encode!(message)
  header = "Content-Length: #{byte_size(json)}\r\n\r\n"
  IO.write(header <> json)
  IO.flush()

  # Small delay to allow processing
  Process.sleep(50)
end)
