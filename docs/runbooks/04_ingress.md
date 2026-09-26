# Ingress, TLS and SSO runbook

The design is in [04_ingress.md](../04_ingress.md).

## Check the ingress stack

1. Check Envoy Gateway:

   ```bash
   kubectl get gatewayclass eg                       # ACCEPTED=True
   kubectl -n gateway get gateway                    # shared-gateway and one per host, PROGRAMMED=True
   kubectl -n envoy-gateway-system get pods          # controller Running, envoy-* once a Gateway is programmed
   ```

2. Check that exactly one LoadBalancer Service holds the pinned IP:

   ```bash
   kubectl get svc -A | grep LoadBalancer            # one envoy-eg-<hash> in envoy-gateway-system
   ```

3. Check cert-manager and the issuers:

   ```bash
   kubectl -n cert-manager get pods                  # controller, webhook and cainjector Running
   kubectl get clusterissuer                         # letsencrypt-staging and letsencrypt-prod both READY=True
   ```

## Free the pinned IP from a stale Service

The merged Envoy Service gets no IP when another LoadBalancer Service holds it. Nothing reconciles the usual
suspects: `cilium-gateway-shared-gateway`, or a per-Gateway Envoy Service from before `mergeGateways`.

1. List the LoadBalancer Services:

   ```bash
   kubectl get svc -A | grep LoadBalancer
   ```

2. Delete every one except `envoy-gateway-system/envoy-eg-<hash>`:

   ```bash
   kubectl -n gateway delete svc cilium-gateway-shared-gateway
   ```

3. Check that LB-IPAM assigned the IP to the Envoy Service.

## Move a host from staging to prod

Browsers reject a staging cert, so a host is unusable until it moves to prod.

1. Check that the staging cert issued: `kubectl -n gateway get certificate` shows `READY=True`.
2. Set the issuer to `letsencrypt-prod`:
   - one host: the `issuer` of its ingress.
   - the shared wildcards: `acme.cloudflare.wildcardIssuer` in `03_gateway/values.yaml`.
   - one new zone while the others stay on prod: list it in `acme.cloudflare.wildcardIssuerOverrides`, then remove
     it once issuance works.
3. Commit and push.

## Fix a wildcard cert that does not issue

A failed wildcard takes down every host on its zone.

1. Read the Cloudflare error:

   ```bash
   kubectl -n cert-manager get challenges
   ```

2. The usual cause is a zone the API token has no `Zone:DNS:Edit` or `Zone:Read` on. Widen the token in Cloudflare.
   The token string stays the same, so no re-seal is needed.

## Render ingress consumers locally after a chart change

Consumers vendor `lib/helm/ingress` as a `file://` dependency. After you change the chart, run
`helm dependency update` in each consumer before a local `helm template`. `make configure-values` prints the loop.

## Turn on SSO

1. Put `GOOGLE_SSO_CLIENT_ID` and `GOOGLE_SSO_CLIENT_SECRET` in `.env`.
2. Run `lib/shell/04_google_sso.sh`. It needs the cluster for `kubeseal`. It prints the redirect URIs, writes
   `clientID` and seals the secret.
3. On the Google OAuth client, register each printed redirect URI and add each apex under "Authorized domains".
4. Publish the consent screen. In "Testing" mode only listed test users can log in, whatever the allowlist says.
5. Commit and push. Argo CD applies `04_google_sso` at wave 4.
6. Check the policies:

   ```bash
   kubectl -n gateway get securitypolicy             # one sso-<domainslug> per domain, Accepted=True
   ```

   Not Accepted means the client-secret Secret is missing. Run step 2 again and push.

7. Browse a gated host. Expect the Google login and a bounce through `google-sso.<domain>`. An allowlisted account
   reaches the app, and any other is denied. An open host loads with no login.

## Change who can reach what

| Change | Google Console | Cluster |
|---|---|---|
| add a subdomain to an ingress | nothing, if the domain is already gated | add the host to the `hosts:` of that ingress |
| gate a host | nothing | add its `subdomain` to `hosts` in `04_google_sso/values.yaml` |
| change who may log in | nothing | set `SSO_ALLOWLIST` in `.env` and run `make configure-values`, or set the `allowlist` of one host |
| add a registrable domain | one redirect URI and the apex under "Authorized domains" | see [Add a registrable domain](#add-a-registrable-domain) |
| change the base domain | one redirect URI and the apex under "Authorized domains" | see [Change the base domain](#change-the-base-domain) |

Commit and push after each change.

## Add a registrable domain

1. Add an `extraDomains` entry to `04_google_sso/values.yaml`. List only the gated subdomains.

   ```yaml
   extraDomains:
     - domain: example.edu
       issuer: letsencrypt-staging
       hosts:
         - subdomain: api
           allowlist: [ops@example.edu]
   ```

2. Add an `ingresses[]` entry with `domain: example.edu` to the workload chart. List every host, gated or not.
3. On the same Google client, add `https://google-sso.example.edu/oauth2/callback` as a redirect URI and
   `example.edu` under "Authorized domains". `04_google_sso.sh` prints both.
4. Point DNS for each host and for `google-sso.example.edu` at `INGRESS_LB_IP`. Forward `:80` for HTTP-01.
5. Optional, for a wildcard cert: add `example.edu` to `CLOUDFLARE_WILDCARD_DOMAINS` in `.env`, widen the token
   zones in Cloudflare, and run `make configure-values`.
6. Commit and push.
7. Once the staging cert issues, set the entry's `issuer` to `letsencrypt-prod`. After step 5, also set its
   `wildcardIssuerOverrides` line. Push again.

No re-seal is needed, because one client serves every domain.

Gotchas:

- Do not put another domain into `06_platform_ingress` or `sample_user_manager` values. `make configure-values`
  rewrites `domain` on every ingress there with no warning.
- The blackbox probes cover only the `ops.` and `app.` tiers. A second domain gets no synthetic monitoring.

## Change the base domain

1. Set `BASE_DOMAIN` in `.env` and run `make configure-values`. Every host in every chart follows.
2. Point `google-sso.<new domain>` and each gated host at the router. Forward `:80` for HTTP-01.
3. In Google, add the new apex under "Authorized domains" and `https://google-sso.<new domain>/oauth2/callback` as a
   redirect URI.
4. Run `lib/shell/04_google_sso.sh`, then commit and push.
5. Set `issuer` to `letsencrypt-prod` once the staging callback cert issues.

## Fix `CSRF token validation failed` on login

The same policy must cover the app route and the callback route.

1. Check that the host's subdomain is in `hosts` of `04_google_sso/values.yaml`.
2. Check that the route name matches: the full host with dots turned into dashes.
