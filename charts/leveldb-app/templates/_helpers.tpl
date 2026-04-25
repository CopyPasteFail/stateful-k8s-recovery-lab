{{/*
Expand the name of the chart.
*/}}
{{- define "leveldb-app.name" -}}
{{- default .Chart.Name .Values.nameOverride | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Create a default fully qualified app name.
If Release.Name already contains the chart name, use Release.Name alone to
avoid repetition (e.g. "leveldb-app" not "leveldb-app-leveldb-app").
*/}}
{{- define "leveldb-app.fullname" -}}
{{- if .Values.fullnameOverride }}
{{- .Values.fullnameOverride | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- $name := default .Chart.Name .Values.nameOverride }}
{{- if contains $name .Release.Name }}
{{- .Release.Name | trunc 63 | trimSuffix "-" }}
{{- else }}
{{- printf "%s-%s" .Release.Name $name | trunc 63 | trimSuffix "-" }}
{{- end }}
{{- end }}
{{- end }}

{{/*
Chart label value: <name>-<version> with '+' replaced by '_'.
*/}}
{{- define "leveldb-app.chart" -}}
{{- printf "%s-%s" .Chart.Name .Chart.Version | replace "+" "_" | trunc 63 | trimSuffix "-" }}
{{- end }}

{{/*
Common labels applied to all resources.
*/}}
{{- define "leveldb-app.labels" -}}
helm.sh/chart: {{ include "leveldb-app.chart" . }}
{{ include "leveldb-app.selectorLabels" . }}
{{- if .Chart.AppVersion }}
app.kubernetes.io/version: {{ .Chart.AppVersion | quote }}
{{- end }}
app.kubernetes.io/managed-by: {{ .Release.Service }}
{{- end }}

{{/*
Selector labels used by the StatefulSet and Service.
*/}}
{{- define "leveldb-app.selectorLabels" -}}
app.kubernetes.io/name: {{ include "leveldb-app.name" . }}
app.kubernetes.io/instance: {{ .Release.Name }}
{{- end }}

{{/*
ServiceAccount name to use.
*/}}
{{- define "leveldb-app.serviceAccountName" -}}
{{- if .Values.serviceAccount.create }}
{{- default (include "leveldb-app.fullname" .) .Values.serviceAccount.name }}
{{- else }}
{{- default "default" .Values.serviceAccount.name }}
{{- end }}
{{- end }}
