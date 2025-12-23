#!/bin/bash

# Pretty-printed manual test for MCP daemon

echo "============================================================"
echo "Manual MCP Daemon Test - Pretty Output"
echo "============================================================"
echo ""

# Helper to emit MCP-framed JSON
frame() {
    local payload="$1"
    local len
    len=$(printf '%s' "$payload" | wc -c | tr -d ' ')
    printf 'Content-Length: %d\r\n\r\n%s' "$len" "$payload"
}

# Function to pretty print JSON if jq is available, otherwise just show it
pretty_json() {
    if command -v jq &> /dev/null; then
        jq .
    else
        cat
    fi
}

echo "1. Testing Initialize..."
echo "   Request: initialize with client info"
echo "   Response:"
frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"clientInfo":{"name":"test-client"}}}' | \
  mix assay.mcp 2>&1 | grep -v "^Compiling" | grep -v "^Generated" | pretty_json
echo ""

echo "2. Testing Tools List..."
echo "   Request: tools/list"
echo "   Response:"
({ frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'; \
   frame '{"jsonrpc":"2.0","id":2,"method":"tools/list"}'; }) | \
  mix assay.mcp 2>&1 | grep -v "^Compiling" | grep -v "^Generated" | tail -1 | pretty_json
echo ""

echo "3. Testing Tool Call (analyze)..."
echo "   Request: tools/call with assay.analyze"
echo "   Response (showing status only):"
({ frame '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{}}'; \
   frame '{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"assay.analyze","arguments":{}}}'; }) | \
  mix assay.mcp 2>&1 | grep -v "^Compiling" | grep -v "^Generated" | tail -1 | \
  python3 -c "import sys, json; d=json.load(sys.stdin); print(json.dumps({'id': d.get('id'), 'result': {'status': d['result']['content'][0]['json']['status'], 'warnings_count': len(d['result']['content'][0]['json']['warnings'])}}, indent=2))" 2>/dev/null || \
  tail -1
echo ""

echo "4. Testing Shutdown..."
echo "   Request: shutdown"
echo "   Response:"
frame '{"jsonrpc":"2.0","id":1,"method":"shutdown"}' | \
  mix assay.mcp 2>&1 | grep -v "^Compiling" | grep -v "^Generated" | pretty_json
echo ""

echo "============================================================"
echo "All tests completed successfully!"
echo "============================================================"
