{{/*
ingress-edge.securitypolicy — ONE Google-SSO policy for this ingress. It selects THIS ingress's routes by
the group label (`<groupLabelKey>: <ingress.name>`, targetSelectors), so it attaches to exactly the hosts
in this ingress and carries THIS ingress's own email allowlist, several ingresses on the same domain each
get their own. Three filters run at the Envoy edge, in order:
  1. oidc          : no session -> 302 to Google; the callback lands on the shared google-sso.<domain>
                     host (stood up by 04_google_sso) and stores the ID token in a cookie scoped to
                     cookieDomain.
  2. jwt           : validates that ID token (Google's JWKS) and exposes its claims.
  3. authorization : Deny by default; Allow only when the `email` claim is in THIS ingress's allowlist.
ONE Google OAuth client (clientID + sealed secret from the shared oidc config) is used everywhere; only
the redirectURL host, cookieDomain, group label and allowlist differ per ingress. A SecurityPolicy is
namespaced and selects routes in its OWN namespace, hence gatewayNamespace == the routes' ns.
ctx: {cfg, ingress}.
*/}}
{{- define "ingress-edge.securitypolicy" -}}
{{- $sso := .ingress.sso -}}
{{- $oidc := .cfg.oidc -}}
apiVersion: gateway.envoyproxy.io/v1alpha1
kind: SecurityPolicy
metadata:
  name: sso-{{ .ingress.name }}
  namespace: {{ .cfg.gatewayNamespace }}
spec:
  targetSelectors:
    - group: gateway.networking.k8s.io
      kind: HTTPRoute
      matchLabels:
        {{ .cfg.groupLabelKey }}: {{ .ingress.name | quote }}

  oidc:
    provider:
      issuer: "https://accounts.google.com"
    clientID: {{ $oidc.clientID | quote }}
    clientSecret:
      name: {{ $oidc.clientSecretName | quote }}
    # Fixed shared callback host for this ingress's domain (register it on the Google OAuth client).
    redirectURL: {{ printf "https://%s.%s/oauth2/callback" $oidc.authSubdomain $sso.domain | quote }}
    # Off the default /logout so it doesn't collide with a backend app's own /logout (e.g. ArgoCD's).
    logoutPath: {{ $oidc.logoutPath | quote }}
    # Share the session cookie across every subdomain of this domain (one login covers them all); each
    # ingress still re-checks its OWN allowlist below, so a shared cookie never widens access.
    cookieDomain: {{ $sso.cookieDomain | default $sso.domain | quote }}
    cookieNames:
      idToken: {{ $oidc.idTokenCookie | quote }}
    # Silently renew the id/access token so a session survives past Google's ~1h id-token expiry, up to
    # defaultRefreshTokenTTL (sessionTTL). Without this the user is bounced back to Google every hour.
    refreshToken: {{ $oidc.refreshToken }}
    defaultRefreshTokenTTL: {{ $oidc.sessionTTL | quote }}
    {{- with $oidc.csrfTokenTTL }}
    # Lifetime of the per-flow CSRF (OauthNonce) + PKCE (CodeVerifier) cookies. A failed/abandoned flow
    # orphans them for this long; keep it short so leftovers drain fast (EG default is 10m).
    csrfTokenTTL: {{ . | quote }}
    {{- end }}
    {{- with $oidc.denyRedirectSecFetchMode }}
    # Return 401 instead of a 302->Google for non-navigational requests (XHR/fetch/websocket). Such a
    # request can't render Google's login page, so the OIDC flow it kicks off never completes, and every
    # attempt leaks an OauthNonce/CodeVerifier cookie; a logged-out SPA (Grafana Live's /api/live/ws,
    # ArgoCD's polling) spams these until Envoy resets the stream (http2.too_many_headers ->
    # ERR_HTTP2_PROTOCOL_ERROR). Only real navigations (Sec-Fetch-Mode: navigate) should redirect to login.
    denyRedirect:
      headers:
        - name: Sec-Fetch-Mode
          type: RegularExpression
          value: {{ . | quote }}
    {{- end }}
    # Minimal scopes: `openid` (required to get an ID token) + `email` (the only claim we authorize on).
    scopes:
      - openid
      - email

  jwt:
    providers:
      - name: google
        issuer: "https://accounts.google.com"
        remoteJWKS:
          uri: "https://www.googleapis.com/oauth2/v3/certs"
        extractFrom:
          cookies:
            - {{ $oidc.idTokenCookie | quote }}

  authorization:
    defaultAction: Deny
    rules:
      - name: allow-listed-emails
        action: Allow
        principal:
          jwt:
            provider: google
            claims:
              - name: email
                valueType: String
                values:
                  {{- range $sso.allowlist }}
                  - {{ . | quote }}
                  {{- end }}
{{- end -}}
