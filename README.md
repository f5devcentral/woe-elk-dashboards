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
- **Kibana setup** -- creates the `waf-logs-*` index pattern automatically

> **Community-supported, best-effort.**
> This repository contains community-contributed Helm charts that wrap
> third-party open-source software. They are provided as-is for development
> and demo environments without official F5 support or warranty.

## Prerequisites

- Kubernetes 1.25+
- Helm 3.8+
- At least 2 GiB of allocatable memory on the target node

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
kubectl get pods -n f5-waf -l app=elk -w
```

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
| `image.tag` | `8.16.1` | Image tag (defaults to `appVersion`) |
| `elasticsearch.javaOpts` | `-Xms1g -Xmx1g` | ES JVM heap settings |
| `logstash.javaOpts` | `-Xms512m -Xmx512m` | Logstash JVM heap settings |
| `logstash.pipeline` | `""` | Override the bundled WAF Logstash pipeline |
| `kibana.importDashboards` | `true` | Create waf-logs index pattern in Kibana |
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

### Logstash Pipeline

The chart includes a Logstash pipeline (`files/logstash-waf.conf`) that:

1. Listens for syslog on port 5144
2. Parses WAF security log fields using grok (attack_type, violations,
   signatures, policy_name, request_status, etc.)
3. Parses XML violation details
4. Splits multi-value fields (sig_ids, sig_names, violations, etc.)
5. Resolves GeoIP from client IP
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
