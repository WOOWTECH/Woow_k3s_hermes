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

{{- define "hermes.ns" -}}
{{ .Values.namespace.name }}
{{- end -}}

{{/* `annotations:` block with the keep policy, or nothing. */}}
{{- define "hermes.keepAnnotations" -}}
{{- if .Values.keepOnUninstall -}}
annotations:
  helm.sh/resource-policy: keep
{{- end -}}
{{- end -}}
