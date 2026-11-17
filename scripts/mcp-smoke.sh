#!/bin/bash
#
#  mcp-smoke.sh — end-to-end smoke test for the cinch-mcp server.
#
#  Builds the package, then drives the MCP stdio server through the JSON-RPC
#  handshake and every tool, verifying results with the system zip/tar tools.
#
#  Usage: scripts/mcp-smoke.sh
#

set -euo pipefail
cd "$(dirname "$0")/.."

swift build
BIN="${MCP_BIN:-$(swift build --show-bin-path)/cinch-mcp}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

WORK="$TMP/work"
mkdir -p "$WORK/src/nested"
echo "hello world" > "$WORK/src/a.txt"
echo "nested file" > "$WORK/src/nested/b.txt"
printf '\x00\x01\x02\xFF' > "$WORK/src/blob.bin"

# One JSON-RPC request; prints the server's reply.
call() {
    printf '%s\n' "$1" | "$BIN"
}

fail() {
    echo "FAIL: $*" >&2
    exit 1
}

expect() {
    # expect <haystack-file> <needle>  (prints the tool text, unescaped)
    local unescaped
    unescaped="$(python3 -c '
import json, sys
d = json.load(open(sys.argv[1]))
if "error" in d:
    print(d["error"])
else:
    text = d.get("result", {}).get("content", [{}])[0].get("text")
    print((text if text is not None else str(d)).replace("\\/", "/"))
' "$1")"
    grep -qF "$2" <<<"$unescaped" || fail "\"$2\" not found in: $(cat "$1")"
}

REPLY="$TMP/reply.json"

echo "== initialize =="
call '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"0"}}}' > "$REPLY"
expect "$REPLY" 'cinch-mcp'
call '{"jsonrpc":"2.0","method":"notifications/initialized"}' > /dev/null

echo "== tools/list =="
call '{"jsonrpc":"2.0","id":2,"method":"tools/list"}' > "$REPLY"
for t in archive_list archive_read archive_extract archive_create archive_add archive_write_file archive_delete archive_rename archive_new_folder archive_set_password; do
    expect "$REPLY" "$t"
done

echo "== archive_create (zip from folder) =="
call '{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"archive_create","arguments":{"path":"'"$WORK"'/test.zip","files":["'"$WORK"'/src"]}}}' > "$REPLY"
expect "$REPLY" "Created test.zip"
unzip -t "$WORK/test.zip" > /dev/null

echo "== archive_create (tar.gz from folder) =="
call '{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"archive_create","arguments":{"path":"'"$WORK"'/test.tar.gz","files":["'"$WORK"'/src"]}}}' > "$REPLY"
expect "$REPLY" "Created test.tar.gz"
tar -tzf "$WORK/test.tar.gz" | grep -q "src/nested/b.txt"

echo "== archive_list =="
call '{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"archive_list","arguments":{"path":"'"$WORK"'/test.zip"}}}' > "$REPLY"
expect "$REPLY" "src/a.txt"
expect "$REPLY" "src/blob.bin"

echo "== archive_read (text) =="
call '{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"archive_read","arguments":{"path":"'"$WORK"'/test.zip","entry":"src/a.txt"}}}' > "$REPLY"
expect "$REPLY" "hello world"

echo "== archive_read (binary -> base64) =="
call '{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"archive_read","arguments":{"path":"'"$WORK"'/test.zip","entry":"src/blob.bin"}}}' > "$REPLY"
expect "$REPLY" "base64"

echo "== archive_write_file =="
call '{"jsonrpc":"2.0","id":8,"method":"tools/call","params":{"name":"archive_write_file","arguments":{"path":"'"$WORK"'/test.zip","entry":"notes/readme.md","content":"# notes\n"}}}' > "$REPLY"
expect "$REPLY" "Wrote notes/readme.md"
unzip -p "$WORK/test.zip" notes/readme.md | grep -q "# notes"

echo "== archive_rename (folder) =="
call '{"jsonrpc":"2.0","id":9,"method":"tools/call","params":{"name":"archive_rename","arguments":{"path":"'"$WORK"'/test.zip","mappings":[{"from":"src","to":"source"}]}}}' > "$REPLY"
expect "$REPLY" "Renamed entries"
unzip -l "$WORK/test.zip" | grep -q "source/a.txt"

echo "== archive_new_folder + archive_add =="
call '{"jsonrpc":"2.0","id":10,"method":"tools/call","params":{"name":"archive_new_folder","arguments":{"path":"'"$WORK"'/test.zip","folder":"extra"}}}' > "$REPLY"
call '{"jsonrpc":"2.0","id":11,"method":"tools/call","params":{"name":"archive_add","arguments":{"path":"'"$WORK"'/test.zip","files":["'"$WORK"'/src/a.txt"],"folder":"extra"}}}' > "$REPLY"
expect "$REPLY" "Added 1 top-level item"
unzip -l "$WORK/test.zip" | grep -q "extra/a.txt"

echo "== archive_delete (folder, recursive) =="
call '{"jsonrpc":"2.0","id":12,"method":"tools/call","params":{"name":"archive_delete","arguments":{"path":"'"$WORK"'/test.zip","entries":["source"]}}}' > "$REPLY"
if unzip -l "$WORK/test.zip" | grep -q "source/"; then fail "source/ still present after delete"; fi

echo "== archive_extract =="
call '{"jsonrpc":"2.0","id":13,"method":"tools/call","params":{"name":"archive_extract","arguments":{"path":"'"$WORK"'/test.zip","dest_dir":"'"$WORK"'/out"}}}' > "$REPLY"
expect "$REPLY" "Extracted"
grep -q "# notes" "$WORK/out/notes/readme.md"
grep -q "hello world" "$WORK/out/extra/a.txt"

echo "== archive_set_password (AES-256) =="
call '{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"archive_set_password","arguments":{"path":"'"$WORK"'/test.zip","password":"secret"}}}' > "$REPLY"
expect "$REPLY" "AES-256"
call '{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"archive_list","arguments":{"path":"'"$WORK"'/test.zip"}}}' > "$REPLY"
expect "$REPLY" "AES-256"
call '{"jsonrpc":"2.0","id":16,"method":"tools/call","params":{"name":"archive_read","arguments":{"path":"'"$WORK"'/test.zip","entry":"notes/readme.md","password":"secret"}}}' > "$REPLY"
expect "$REPLY" "# notes"

echo "== tar.gz mutations =="
call '{"jsonrpc":"2.0","id":17,"method":"tools/call","params":{"name":"archive_write_file","arguments":{"path":"'"$WORK"'/test.tar.gz","entry":"new/c.txt","content":"tar content\n"}}}' > "$REPLY"
call '{"jsonrpc":"2.0","id":18,"method":"tools/call","params":{"name":"archive_delete","arguments":{"path":"'"$WORK"'/test.tar.gz","entries":["src/nested"]}}}' > "$REPLY"
expect "$REPLY" "Deleted entries"
gzip -t "$WORK/test.tar.gz"
tar -xzOf "$WORK/test.tar.gz" new/c.txt | grep -q "tar content"
if tar -tzf "$WORK/test.tar.gz" | grep -q "src/nested"; then fail "src/nested still present"; fi

echo "== unknown tool -> JSON-RPC error =="
call '{"jsonrpc":"2.0","id":19,"method":"tools/call","params":{"name":"nope","arguments":{}}}' > "$REPLY"
expect "$REPLY" "unknown tool"

echo
echo "ALL SMOKE TESTS PASSED"
