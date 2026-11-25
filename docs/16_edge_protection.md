# Edge protection

CrowdSec reads the Envoy access log and finds scanners and abusive IPs. It runs in audit mode: it records each
ban it would make as simulated, and nothing blocks. A later bouncer at Envoy enforces the bans.

How to read alerts, check the allowlist and refresh it: [runbooks/16_edge_protection.md](runbooks/16_edge_protection.md).

| | |
|---|---|
| App | `crowdsec`, wave 3, namespace `crowdsec` |
| Wrapper chart | `argo_apps/platform/charts/03_crowdsec/` |
| Upstream chart | `crowdsec` from `https://crowdsecurity.github.io/helm-charts` |
| Workloads | the agent, which parses and detects. LAPI (local API), which stores alerts and decisions in SQLite. |

## Decisions

- **CrowdSec,** because it ships maintained HTTP scenarios, such as sensitive-file probing and admin-panel scans,
  and a bouncer for Envoy exists. A home-grown rule set would need the same scenarios written and kept current.
- **The agent reads Envoy through the Kubernetes API,** with the `kubernetes` acquisition. It needs a Role with
  `get`, `list` and `watch` on pods and `get` on `pods/log` in `envoy-gateway-system`, and no hostPath. Envoy
  writes JSON to stdout, and no hub parser reads that format, so `files/parsers/` holds a local one.
- **The agent trusts the client IP Envoy picked.** `downstream_remote_address` holds the IP that the `client-ip`
  ClientTrafficPolicy in `03_gateway` takes from `X-Forwarded-For`, and only from a Cloudflare peer. See
  [04_ingress.md](04_ingress.md#client-ip).
- **Global scope.** Detection and bans cover every host the same way. A host that trips a scenario on purpose
  gets a global whitelist entry, not a per-host setting.
- **Simulation and no blocklist pull during the audit.** `simulation: true` stores every decision as simulated,
  and LAPI never hands a simulated decision to a bouncer. Community blocklist decisions are never simulated, so
  both pulls stay off until blocking starts.
- **SQLite on `longhorn-r2-retained-with-backups`.** One LAPI replica writes the database, and the volume backups
  are its only copy. Both PVCs carry `Prune=false,Delete=false`.
- **The LAPI secrets are sealed, not chart-generated.** The chart generates them with Helm `lookup`, which Argo CD
  cannot run, so every sync would roll new ones. `make configure-crowdsec` generates and seals them.
- **The chart's acquisition list holds a placeholder.** The chart refuses to render without one, and its schema
  has no `kubernetes` source. The real acquisition is `files/acquis-envoy.yaml`.

## Who is never banned

Three layers, from earliest to latest:

| Layer | Where | Covers |
|---|---|---|
| `local/never-ban` parser | `templates/agent-files-configmap.yaml` | private ranges, the own public IP (`PUBLIC_EGRESS_IP` in `.env`), the CCBot user agent |
| hub whitelists | collection `crowdsecurity/whitelist-good-actors` | Google and Bing by reverse DNS, CDNs, public DNS resolvers |
| centralized allowlist `crawlers` | LAPI, loaded by the `crawler-allowlist` sidecar | the published IPs of the crawlers below |

- **The allowlist covers search, AI and link-preview crawlers that publish their IPs:** Google (4 lists), Bing,
  Apple, DuckDuckGo, OpenAI (3), Anthropic, Perplexity (2), Common Crawl and Amazon (3 HTML pages). Meta
  publishes no list, so its network AS32934 from RIPEstat stands in. The sources are in
  `files/crawler-allowlist.sh`.
- **Other bots are treated like any visitor.** Bytespider, PetalBot and SEO tools such as SemrushBot are not on
  the list.
- **The refresh is a sidecar in the LAPI pod, not a CronJob.** `cscli allowlists` writes to the SQLite file
  directly and refuses to run off the LAPI pod. LAPI has no API to write an allowlist. The sidecar runs at start
  and every 24h, and needs no `pods/exec`. A failed run logs a line and tries again after 1h. It fires no
  job-failed alert.
- **A failed source keeps its old entries.** Each entry's comment names its source, so one broken URL removes
  nothing. Each run removes the IPs that no source lists any more.
- **A prefix shorter than /8 (IPv4) or /16 (IPv6) is dropped,** so a broken or hijacked source cannot allowlist a
  large part of the internet.

## Fail-open

A broken CrowdSec must not block. In audit mode nothing blocks at all. Once the bouncer runs, Envoy fails open
when the bouncer is down or slow. When LAPI is down and the bouncer still runs, the bouncer keeps its cached bans.
