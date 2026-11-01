{{/* Hostname of the external bootstrap address, e.g. kafka.mgmt.rezakara.demo. */}}
{{- define "kafka.externalBootstrapHost" -}}
{{- printf "%s.%s" .Values.cluster.name .Values.cluster.external.domain -}}
{{- end -}}

{{/* Hostname of one broker's external address. Takes a dict with "root" and "id". */}}
{{- define "kafka.externalBrokerHost" -}}
{{- printf "%s-%d.%s" .root.Values.cluster.name (int .id) .root.Values.cluster.external.domain -}}
{{- end -}}
