#!/bin/bash
set -e
apt-get update -qq > /dev/null && apt-get install -y -qq curl > /dev/null
cp -r /src /work && cd /work/integration/vapor-smoke
FLAGS="-Xswiftc -disable-upcoming-feature -Xswiftc MemberImportVisibility"
swift build $FLAGS > /tmp/v.log 2>&1 && echo "VAPOR BUILD OK" || { echo "VAPOR BUILD FAILED"; grep error /tmp/v.log | head -6; exit 1; }
swift run $FLAGS > /tmp/v-run.log 2>&1 &
for i in $(seq 1 30); do curl -s --max-time 2 http://127.0.0.1:8080/healthz | grep -q ok && break; sleep 2; done
curl -s --max-time 2 http://127.0.0.1:8080/healthz | grep -q ok && echo "VAPOR HEALTH OK" || { echo "VAPOR HEALTH FAILED"; tail -5 /tmp/v-run.log; exit 1; }
R=$(curl -s --max-time 180 "http://127.0.0.1:8080/ask?q=Reply%20with%20one%20word:%20ready")
echo "VAPOR LLM response: ${R:0:80}"
[ -n "$R" ] && echo "VAPOR SMOKE PASSED"
