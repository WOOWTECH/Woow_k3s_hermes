{{/*
Helper templates for the hermes chart.

Multiple releases of this chart can share one namespace — one release per
live Hermes instance ("hermes", "cindytech1", ...). Object names are derived
from `.Values.instance`, NOT `.Release.Name`, so that a release name and an
instance name can differ if ever needed, and so the name matches exactly what
the original hand-written manifests used (the fullname of the "hermes"
instance in namespace "hermes" is literally "hermes").
*/}}

{{- define "hermes.instance" -}}
{{- required "instance is required (the live object name prefix, e.g. \"hermes\" or \"cindytech1\")" .Values.instance -}}
{{- end -}}

{{- /*
Object placement. `namespace.name` is EMPTY by default so placement follows
`-n`/`--namespace`. Setting it (here or in a values file) makes it win over
`-n`: a `-n <test-ns> -f deploy/woow-k3s/<real instance>.yaml` rehearsal would
then write to the REAL instance namespace. That happened once on the sibling
n8n chart and touched production, so keep this empty and never set
`namespace.name` in any file under deploy/woow-k3s/.
*/ -}}
{{- define "hermes.ns" -}}
{{ .Values.namespace.name | default .Release.Namespace }}
{{- end -}}

{{/* `annotations:` block with the keep policy, or nothing. */}}
{{- define "hermes.keepAnnotations" -}}
{{- if .Values.keepOnUninstall -}}
annotations:
  helm.sh/resource-policy: keep
{{- end -}}
{{- end -}}

{{- /*
Placeholder substitution.

Some live objects carry credentials as PLAIN values inside a pod template
(a dashboard basic-auth password, a webui password, a postgres password set
as a literal env var, a Cloudflare tunnel token passed as a --token CLI
arg). Those values must never be committed, but a takeover has to render the
pod template byte-identical to live or every pod restarts.

So the committed instance values carry `__NAME__` tokens, and the real
values are supplied at apply time:

    --set-string placeholders.NAME="$VALUE"

`hermes.subst` replaces every `__NAME__` with placeholders.NAME.
`hermes.substYaml` does the same to a toYaml'd value (env lists, sidecars).

With placeholdersStrict (default true) a leftover `__NAME__` fails the
render instead of silently shipping a literal "__DASHBOARD_PASSWORD__" as
someone's password — which, on a takeover, would also restart the pod.
*/ -}}
{{- define "hermes.subst" -}}
{{- $root := index . 0 -}}
{{- $out := index . 1 | toString -}}
{{- /* __INSTANCE__ is implicit and always available, so the chart defaults
       can name this release's own objects (<instance>-secrets, <instance>-
       config, <instance>-postgresql-svc ...) instead of hardcoding the
       "hermes" instance's names and breaking every other instance. */ -}}
{{- $ph := merge (dict "INSTANCE" (include "hermes.instance" $root)) ($root.Values.placeholders | default dict) -}}
{{- range $k, $v := $ph -}}
{{- $out = replace (printf "__%s__" $k) ($v | toString) $out -}}
{{- end -}}
{{- $left := regexFindAll "__[A-Z0-9_]+__" $out -1 -}}
{{- if and $left $root.Values.placeholdersStrict -}}
{{- fail (printf "unsubstituted placeholder(s): %s. Supply each with --set-string placeholders.<NAME>=<value> (see README), or set placeholdersStrict=false to render the token literally." (join ", " ($left | uniq))) -}}
{{- end -}}
{{- $out -}}
{{- end -}}

{{- define "hermes.substYaml" -}}
{{- include "hermes.subst" (list (index . 0) (toYaml (index . 1))) -}}
{{- end -}}

{{- /* Extra `from` entry letting the `helm test` smoke pod reach Postgres/
       Redis. Without it the NetworkPolicy blocks the test and `helm test`
       can never pass. Rendered only when networkPolicy.allowTests — the one
       live instance that has these policies sets it false so a takeover
       leaves the policy byte-identical. */ -}}
{{- define "hermes.netpolTestFrom" -}}
{{- if and .Values.networkPolicy.allowTests .Values.tests.enabled }}
        - podSelector:
            matchLabels:
              app.kubernetes.io/component: smoke-test
              app.kubernetes.io/instance: {{ include "hermes.instance" . }}
{{- end }}
{{- end -}}

{{- /*
Pod-template annotations.

Anything under `spec.template.metadata.annotations` is part of the
pod-template hash, so a live annotation that the chart cannot reproduce
makes a takeover roll the Deployment. Three live Deployments carry a
`kubectl.kubernetes.io/restartedAt` stamp left by a past `kubectl rollout
restart`; the instance values replay it verbatim so the hash is unchanged.
*/ -}}
{{- define "hermes.podAnnotations" -}}
{{- with . }}
annotations:
  {{- toYaml . | nindent 2 }}
{{- end }}
{{- end -}}
