# WAF on Envoy - ELK Dashboards

Helm chart for deploying an all-in-one ELK stack (Elasticsearch + Logstash + Kibana)
pre-configured for [F5 WAF on Envoy](https://www.f5.com/) security log aggregation.

This chart uses the community [sebp/elk](https://hub.docker.com/r/sebp/elk) image
and adds WAF-specific configuration via ConfigMaps:

- **Logstash pipeline** -- parses WAF syslog messages on port 5144, extracts
  security fields (attack type, violations, signatures, GeoIP), and indexes
  into `waf-logs-YYYY.MM.dd`
- **Elasticsearch index template** -- proper field mappings for WAF log fields
  including `ip` and `geo_point` types
- **Kibana dashboards** -- two pre-built dashboards (Overview and False Positives)
  with 15+ visualizations are automatically imported on startup via a sidecar
  container

> **Community-supported, best-effort.**
> This repository contains community-contributed Helm charts that wrap
> third-party open-source software. They are provided as-is for development
> and demo environments without official F5 support or warranty.

## Prerequisites

- Kubernetes 1.25+
- Helm 3.8+
- At least 2 GiB of allocatable memory on the target node
- Privileged init containers must be allowed (required for `vm.max_map_count` sysctl)

## Quick Start

```sh
# Add the Helm repo
helm repo add woe-elk https://f5devcentral.github.io/woe-elk-dashboards
helm repo update

# Install into the f5-waf namespace
helm install elk woe-elk/elk -n f5-waf --create-namespace
```

ELK takes 60-120 seconds to fully start. Monitor readiness:

```sh
kubectl get pods -n f5-waf -l app.kubernetes.io/name=elk -w
```

Once the pod shows `2/2 Running`, both ELK and the dashboard importer sidecar
are healthy. The sidecar waits for Kibana to become available, then creates the
`waf-logs-*` index pattern and imports the bundled dashboards.

## Install with Gateway Integration

Expose Elasticsearch through an existing Envoy gateway (e.g. `woe-plm-envoy`)
so the traffic cluster's UI backend can query WAF logs:

```sh
helm install elk woe-elk/elk -n f5-waf \
  --set gateway.enabled=true \
  --set gateway.name=woe-plm-envoy
```

The chart's post-install Job patches the gateway to add an `elasticsearch`
listener on port 9200 and creates an HTTPRoute to forward traffic to the
ELK service.

Verify:

```sh
GW_IP=$(kubectl get gateway woe-plm-envoy -n f5-waf -o jsonpath='{.status.addresses[0].value}')
curl "http://${GW_IP}:9200/"
```

## Install with Persistence

For data retention across pod restarts:

```sh
helm install elk woe-elk/elk -n f5-waf \
  --set persistence.enabled=true \
  --set persistence.size=20Gi
```

## Configuration

| Parameter | Default | Description |
|---|---|---|
| `image.repository` | `sebp/elk` | Container image |
| `image.tag` | `""` | Image tag (defaults to `appVersion`: `8.17.8`) |
| `elasticsearch.javaOpts` | `-Xms1g -Xmx1g` | ES JVM heap settings |
| `logstash.javaOpts` | `-Xms512m -Xmx512m` | Logstash JVM heap settings |
| `logstash.pipeline` | `""` | Override the bundled WAF Logstash pipeline |
| `kibana.importDashboards` | `true` | Deploy sidecar to import dashboards and create index pattern |
| `kibana.sidecar.image` | `curlimages/curl:8.11.1` | Container image for the dashboard importer sidecar |
| `service.type` | `ClusterIP` | Service type |
| `service.elasticsearch` | `9200` | Elasticsearch port |
| `service.kibana` | `5601` | Kibana port |
| `service.syslog` | `5144` | Syslog input port for WAF logs |
| `gateway.enabled` | `false` | Expose ES through an Envoy gateway |
| `gateway.name` | `woe-plm-envoy` | Gateway to patch |
| `gateway.listenerPort` | `9200` | Listener port on the gateway |
| `persistence.enabled` | `false` | Enable PVC for ES data |
| `persistence.size` | `10Gi` | PVC size |
| `resources.requests.memory` | `2Gi` | Memory request |
| `resources.limits.memory` | `4Gi` | Memory limit |

## Bundled WAF Configuration

### Kibana Dashboards

The chart bundles two Kibana dashboards that are automatically imported on
startup by a sidecar container:

**Overview Dashboard** (10 visualizations):
- Requests Rate (time series)
- Requests Distribution (donut: clean / blocked / alerted)
- Response Codes Rate and Distribution
- Top Talkers, Top URLs, Top Violator IPs
- Signatures Distribution, Violations Distribution
- GEO map (source IP geolocation)
- All Requests saved search

**False Positives Dashboard** (5 visualizations):
- Interpretation guide (how to read the graphs)
- Rate of Unique IPs per Violation (time series)
- Rate of Unique IPs per Signature (time series)
- Violations Stats Table (violation name, unique IPs, hit count, outcome)
- Signatures Stats Table

The dashboards are stored as Kibana NDJSON exports in `files/dashboards/` and
mounted into the pod via a ConfigMap. The sidecar uses the Kibana saved objects
`_import` API with `overwrite=true`, so dashboards are re-applied on every pod
restart.

To disable dashboard import:

```sh
helm install elk woe-elk/elk -n f5-waf --set kibana.importDashboards=false
```

### Logstash Pipeline

The chart includes a Logstash pipeline (`files/logstash-waf.conf`) that:

1. Listens for syslog on port 5144
2. Parses WAF security log fields using grok (attack_type, violations,
   signatures, policy_name, request_status, bot fields, gRPC fields, etc.)
3. Parses XML violation details
4. Splits multi-value fields (sig_ids, sig_names, violations, etc.)
5. Resolves GeoIP from client IP (with ECS compatibility disabled for
   legacy field name compatibility)
6. Writes to daily `waf-logs-YYYY.MM.dd` indices

To override with a custom pipeline:

```sh
helm install elk woe-elk/elk -n f5-waf \
  --set-file logstash.pipeline=./my-custom-pipeline.conf
```

### Elasticsearch Index Template

The chart applies an index template (`files/waf-index-template.json`) via a
post-install Job that:

- Maps `ip_client` and `source_host` as `ip` type
- Maps `geoip.location` as `geo_point` for map visualizations
- Maps security fields (attack_type, violations, etc.) as `keyword` for
  aggregations
- Sets single shard, zero replicas (appropriate for single-node)

### Init Container

The chart includes a privileged init container that sets
`vm.max_map_count=262144`, which is required by Elasticsearch. Without this,
Elasticsearch will fail the bootstrap check and exit.

## Architecture

The Deployment runs three containers:

| Container | Image | Purpose |
|---|---|---|
| `elk` | `sebp/elk:8.17.8` | All-in-one Elasticsearch + Logstash + Kibana |
| `import-dashboards` | `curlimages/curl:8.11.1` | Sidecar: waits for Kibana, imports dashboards, then sleeps |
| `sysctl` (init) | `busybox` | Sets `vm.max_map_count=262144` before ES starts |

## Connecting WAF on Envoy UI

After ELK is running, configure the woe-ui backend to stream logs from it.

**At install time:**

```sh
helm install woe-ui oci://docker.io/f5networks/woe-internal-ui-helm \
  --set args.esUrl="http://<GATEWAY_IP>:9200"
```

**At runtime** (UI already deployed):

Go to Settings > Server Configuration in the UI, enter the Elasticsearch URL,
and click Apply Changes.

## Uninstall

```sh
helm uninstall elk -n f5-waf
```

If persistence was enabled:

```sh
kubectl delete pvc elk-data -n f5-waf
```

## License

[Apache License 2.0](LICENSE)
