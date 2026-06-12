#!/bin/bash
set -e
apt-get update -qq > /dev/null && apt-get install -y -qq curl > /dev/null
cp -r /src /work && cd /work/integration/hummingbird-smoke
swift build > /tmp/hb.log 2>&1 && echo "HB BUILD OK" || { echo "HB BUILD FAILED"; grep error /tmp/hb.log | head -6; exit 1; }
swift run > /tmp/hb-run.log 2>&1 &
for i in $(seq 1 30); do curl -s --max-time 2 http://127.0.0.1:8081/healthz | grep -q ok && break; sleep 2; done
curl -s --max-time 2 http://127.0.0.1:8081/healthz | grep -q ok && echo "HB HEALTH OK" || { echo "HB HEALTH FAILED"; tail -5 /tmp/hb-run.log; exit 1; }
R=$(curl -s --max-time 180 "http://127.0.0.1:8081/ask?q=Reply%20with%20one%20word:%20ready")
echo "HB LLM response: ${R:0:80}"
[ -n "$R" ] && echo "HUMMINGBIRD SMOKE PASSED"
