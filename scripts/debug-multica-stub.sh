#!/bin/sh
set -eu

echo "$*" >> "@LOG@"
if [ "$1 $2" = "workspace list" ]; then
  echo '[{"id":"workspace-1"}]'
elif [ "$1 $2 $3" = "workspace mcp list" ]; then
  if [ -f "@STATE@/identity-updated" ]; then
    echo '[{"id":"server-1","name":"@SERVER_NAME@","transport":"stdio"}]'
  else
    echo '[{"id":"server-1","name":"@SERVER_NAME@","transport":"stdio","command":"/wrong/helper","args":["wrong-mode"]}]'
  fi
elif [ "$1 $2 $3" = "workspace mcp update" ]; then
  cat > "@CONFIG@"
  touch "@STATE@/identity-updated"
  echo '[{"id":"server-1","name":"@SERVER_NAME@","transport":"stdio"}]'
elif [ "$1 $2" = "agent list" ]; then
  echo '[{"id":"agent-existing","name":"保留 Agent","archived_at":null},{"id":"agent-new","name":"开发｜快修","archived_at":null}]'
elif [ "$1 $2 $3" = "agent mcp list" ]; then
  if [ "$4" = "agent-existing" ] || [ -f "@STATE@/new-assigned" ]; then
    echo '[{"id":"server-1","name":"@SERVER_NAME@","transport":"stdio"}]'
  else
    echo '[]'
  fi
elif [ "$1 $2 $3 $4" = "agent mcp add agent-new" ]; then
  touch "@STATE@/new-assigned"
  echo '{}'
elif [ "$1 $2 $3 $4" = "agent mcp remove agent-new" ]; then
  rm -f "@STATE@/new-assigned"
  echo '{}'
elif [ "$1 $2" = "issue create" ]; then
  cat >/dev/null
  printf '%s' "$4" > "@STATE@/title"
  printf '{"id":"test-issue","status":"todo","title":"%s","assignee_id":"agent-new"}\n' "$4"
elif [ "$1 $2" = "issue list" ]; then
  title=$(cat "@STATE@/title")
  printf '{"has_more":false,"issues":[{"id":"test-issue","status":"todo","title":"%s","assignee_id":"agent-new"}],"limit":100,"offset":0,"total":1}\n' "$title"
elif [ "$1 $2" = "issue get" ]; then
  if [ "@MODE@" = "failure" ]; then
    echo '{"id":"test-issue","status":"blocked"}'
    exit 0
  fi
  printf '%s\n' \
    '{"jsonrpc":"2.0","id":"initialize","method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"multica-debug","version":"1"}}}' \
    '{"jsonrpc":"2.0","id":"tools","method":"tools/list","params":{}}' \
    '{"jsonrpc":"2.0","id":"status","method":"tools/call","params":{"name":"connection_status","arguments":{}}}' \
    | "@HELPER@" mcp > "@EVIDENCE@"
  grep -q '"name":"askkey"' "@EVIDENCE@"
  grep -q 'connection_status' "@EVIDENCE@"
  grep -q 'connected' "@EVIDENCE@"
  echo '{"id":"test-issue","status":"in_review"}'
elif [ "$1 $2 $3" = "issue comment list" ]; then
  printf '%s\n' '[{"content":"ASKKEY_CONNECTION_OK\nhelperVersion=0.1.0\nbrokerProtocolVersion=1"}]'
else
  exit 1
fi
