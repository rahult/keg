#!/bin/bash
# Autoresearch benchmark: Managed Agents API spec tests
set -e
cd "$(dirname "$0")"
swift test --filter ManagedAgentsSpec 2>&1 | tee /tmp/autoresearch_output.txt
