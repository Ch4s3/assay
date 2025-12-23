#!/bin/bash

# Manual test script for MCP daemon
# This sends JSON-RPC messages to the MCP server

echo "============================================================"
echo "Manual MCP Daemon Test"
echo "============================================================"
echo ""
echo "Starting MCP server and sending test messages..."
echo ""

frame() {
  local payload="$1"
  local len
  len=$(printf '%s' "$payload" | wc -c | tr -d ' ')
  printf 'Content-Length: %d\r\n\r\n%s' "$len" "$payload"
}

# Start the server in the background and capture its PID
mix assay.mcp < <(
  frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"manual-test-client","version":"1.0.0"}}}'
  sleep 0.1

  frame '{"jsonrpc":"2.0","method":"notifications/initialized"}'
  sleep 0.1

  frame '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'
  sleep 0.1

  frame '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"assay.analyze","arguments":{"formats":["text"]}}}'
  sleep 0.1

  frame '{"jsonrpc":"2.0","id":4,"method":"shutdown"}'
  sleep 0.1
) 2>&1
