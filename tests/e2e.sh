#!/usr/bin/env bash
# End-to-end check of the WAF pipeline and index template: WAF syslog events
# are sent to Logstash on 5144 and each one must be indexed in waf-logs-* and
# queryable by support_id, with the expected source_host.
#
# Uses the official Elasticsearch and Logstash images at the chart's version
# (multi-arch; the all-in-one sebp/elk image is amd64-only and Elasticsearch 8
# does not boot under emulation). Logstash shares the Elasticsearch container's
# network, so the pipeline's hosts => ["localhost:9200"] works unchanged.
# Requires Docker and jq.
#
#   tests/e2e.sh
#   PIPELINE=/path/to/old.conf TEMPLATE=/path/to/old.json tests/e2e.sh   # compare
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/.." && pwd)
VERSION=${VERSION:-8.17.8}
PIPELINE=${PIPELINE:-$ROOT/charts/elk/files/logstash-waf.conf}
TEMPLATE=${TEMPLATE:-$ROOT/charts/elk/files/waf-index-template.json}
ES_PORT=${ES_PORT:-19200}
SYSLOG_PORT=${SYSLOG_PORT:-15144}
NAME=woe-elk-e2e-$$
ES="http://localhost:${ES_PORT}"

cleanup() { docker rm -f "$NAME-ls" "$NAME-es" >/dev/null 2>&1 || true; }
trap cleanup EXIT

docker run -d --name "$NAME-es" \
  -p "${ES_PORT}:9200" -p "${SYSLOG_PORT}:5144" \
  -e discovery.type=single-node -e xpack.security.enabled=false \
  -e ES_JAVA_OPTS="-Xms1g -Xmx1g" \
  "docker.elastic.co/elasticsearch/elasticsearch:${VERSION}" >/dev/null

echo "Waiting for Elasticsearch..."
for _ in $(seq 1 90); do
  curl -sf "${ES}/_cluster/health?wait_for_status=yellow&timeout=5s" >/dev/null 2>&1 && break
  sleep 5
done
curl -sf "${ES}/_cluster/health?wait_for_status=yellow&timeout=5s" >/dev/null

# Same call as the chart's es-setup Job.
curl -sf -X PUT "${ES}/_template/waf-logs" -H "Content-Type: application/json" -d @"${TEMPLATE}" >/dev/null

docker run -d --name "$NAME-ls" --network "container:$NAME-es" \
  -e XPACK_MONITORING_ENABLED=false -e LS_JAVA_OPTS="-Xms512m -Xmx512m" \
  -v "${PIPELINE}:/usr/share/logstash/pipeline/logstash.conf:ro" \
  "docker.elastic.co/logstash/logstash:${VERSION}" >/dev/null

# Docker's port proxy accepts connections before Logstash listens, so wait for
# the syslog input's own startup log line instead of probing the port.
echo "Waiting for Logstash syslog input..."
ready=0
for _ in $(seq 1 90); do
  if docker logs "$NAME-ls" 2>&1 | grep -q "Starting syslog tcp listener"; then
    ready=1
    break
  fi
  sleep 5
done
if [ "$ready" -ne 1 ]; then
  echo "Logstash syslog input did not start"
  docker logs "$NAME-ls" 2>&1 | tail -20
  exit 1
fi
sleep 2

RUN=$(date +%s)
# support_id suffix | x_forwarded_for_header_value | ip_client | expected source_host ("" = unset)
CASES=(
  "single|51.15.0.1|10.0.0.9|51.15.0.1"
  "chain|51.15.0.1,84.108.132.213|10.0.0.9|51.15.0.1"
  "chain-spaces|51.15.0.1, 84.108.132.213, 10.1.2.3|10.0.0.9|51.15.0.1"
  "ipv6-chain|2001:db8::1, 51.15.0.1|10.0.0.9|2001:db8::1"
  "invalid-first|unknown, 84.108.132.213|10.0.0.9|84.108.132.213"
  "no-xff|N/A|10.0.0.9|10.0.0.9"
  "no-valid-ip|N/A|N/A|"
)

for c in "${CASES[@]}"; do
  IFS="|" read -r id xff client _ <<<"$c"
  msg="<134>$(LC_ALL=C date -u '+%b %e %H:%M:%S') waf ASM:unit_hostname=\"e2e\",ip_client=\"${client}\",request_status=\"blocked\",support_id=\"${RUN}-${id}\",violation_details=\"N/A\",x_forwarded_for_header_value=\"${xff}\""
  exec 3<>"/dev/tcp/localhost/${SYSLOG_PORT}"
  printf '%s\n' "$msg" >&3
  exec 3>&-
done

fail=0
for c in "${CASES[@]}"; do
  IFS="|" read -r id _ _ want <<<"$c"
  sid="${RUN}-${id}"
  got="<missing>"
  for _ in $(seq 1 30); do
    curl -sf -X POST "${ES}/waf-logs-*/_refresh" >/dev/null 2>&1 || true
    resp=$(curl -s "${ES}/waf-logs-*/_search" -H "Content-Type: application/json" \
      -d "{\"query\":{\"term\":{\"support_id\":\"${sid}\"}}}")
    if [ "$(printf '%s' "$resp" | jq '.hits.total.value // 0')" -ge 1 ]; then
      got=$(printf '%s' "$resp" | jq -r '.hits.hits[0]._source.source_host // ""')
      break
    fi
    sleep 2
  done
  if [ "$got" = "$want" ]; then
    printf 'PASS  %-14s source_host=%s\n' "$id" "${got:-<unset>}"
  else
    printf 'FAIL  %-14s source_host=%s, want %s\n' "$id" "$got" "${want:-<unset>}"
    fail=1
  fi
done

if [ "$fail" -ne 0 ]; then
  echo "--- Logstash indexing errors:"
  docker logs "$NAME-ls" 2>&1 | grep -o '"reason"=>"[^"]*' | sort -u | tail -5 || true
fi
exit "$fail"
