# Runbook: edge protection

Why CrowdSec runs this way: [../16_edge_protection.md](../16_edge_protection.md).

The Grafana dashboard `CrowdSec` (uid `crowdsec`) shows the would-be bans per scenario and per IP, the parser
health and the allowlist refreshes. The steps below read the same data at the source.

Alerts, decisions and allowlists live in LAPI. Parsing, scenarios and the simulation setting live in the agent.

```bash
LAPI="kubectl -n crowdsec exec deploy/crowdsec-lapi -c crowdsec-lapi --"
AGENT="kubectl -n crowdsec exec deploy/crowdsec-agent -c crowdsec-agent --"
```

## Install

1. Generate and seal the LAPI secrets, then commit and push. Each run rotates both values.

   ```bash
   make configure-crowdsec
   ```

   Expected: `[PASS] encryptedData has csLapiSecret` and `[PASS] encryptedData has registrationToken`. Until
   the Secret exists, the LAPI and agent pods wait in `CreateContainerConfigError`.

2. Set `PUBLIC_EGRESS_IP` in `.env`, run `make configure-values`, then commit and push.

## Check that it works

1. Check that the agent reads and parses the Envoy lines.

   ```bash
   $AGENT cscli metrics show acquisition parsers
   ```

   Expected: a `kubernetes:envoy-gateway-system/<pod>/envoy` row with lines read and parsed. A few unparsed
   lines are normal. They are Envoy lines with an empty host, such as HTTP codec errors.

2. Check that simulation is on.

   ```bash
   $AGENT cscli simulation status
   ```

   Expected: `global simulation: enabled`.

3. List the alerts of the last 24 hours.

   ```bash
   $LAPI cscli alerts list --since 24h
   ```

   Expected: every decision shows `(simul)ban`. No alert names a private IP, the own public IP or a crawler IP.

4. Read one alert with its events.

   ```bash
   $LAPI cscli alerts inspect <id> -d
   ```

5. List the decisions LAPI would hand to a bouncer.

   ```bash
   $LAPI cscli decisions list
   ```

   Expected during the audit: `No active decisions`.

## Check the crawler allowlist

1. Show the allowlist with each entry's source.

   ```bash
   $LAPI cscli allowlists inspect crawlers
   ```

   Expected: several thousand entries. The comment names the source, such as `google-common` or `meta`.

2. Check one IP.

   ```bash
   $LAPI cscli allowlists check <ip>
   ```

   Expected for a crawler IP: `<ip> is allowlisted by item <cidr> from crawlers (<source>)`.

3. Read the sidecar's last run.

   ```bash
   kubectl -n crowdsec logs deploy/crowdsec-lapi -c crawler-allowlist --tail=25
   ```

   Expected: one line per source with its prefix count, then `done: <n> entries, ... 0 failures`. A failed
   source logs `download failed or empty, keeping its <n> entries`.

## Refresh the allowlist now

```bash
make crowdsec-allowlist
```

Expected: the same lines as the sidecar log, and `[PASS] every source loaded`.

## Find out why a line did or did not trigger

1. Copy one raw Envoy line into a file in the agent pod.

   ```bash
   kubectl -n envoy-gateway-system logs <envoy pod> -c envoy --tail=1 > /tmp/line.log
   kubectl -n crowdsec cp /tmp/line.log "$(kubectl -n crowdsec get pod -l type=agent -o name | cut -d/ -f2)":/tmp/line.log -c crowdsec-agent
   ```

2. Run it through the parsers and scenarios.

   ```bash
   $AGENT cscli explain --file /tmp/line.log --type envoy -v
   ```

   Expected: `local/envoy-gateway-json` succeeds and sets `source_ip`. A whitelisted line stops at
   `local/never-ban` or a hub whitelist.

## Whitelist a noisy host or client

Add the entry to the `never-ban.yaml` key in `argo_apps/platform/charts/03_crowdsec/templates/agent-files-configmap.yaml`,
as a CIDR or an `expression`. Push. Reloader restarts the agent when the ConfigMap changes.
