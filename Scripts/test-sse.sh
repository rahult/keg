#!/bin/bash
# Test SSE streaming for Managed Agents API
# Usage: ./test-sse.sh <session-id>

set -e

SESSION_ID="${1:-YOUR_SESSION_ID}"
API_KEY="${ANTHROPIC_API_KEY:-}"

if [ -z "$API_KEY" ]; then
    echo "Error: ANTHROPIC_API_KEY environment variable not set"
    exit 1
fi

echo "Testing SSE streaming for session: $SESSION_ID"
echo "=============================================="

curl -s -N \
    -H "anthropic-version: 2023-06-01" \
    -H "anthropic-beta: managed-agents-2026-04-01" \
    -H "x-api-key: $API_KEY" \
    -H "accept: text/event-stream" \
    "https://api.anthropic.com/v1/sessions/$SESSION_ID/events/stream" | while IFS= read -r line; do
    echo "$line"
done

echo ""
echo "Stream ended."
