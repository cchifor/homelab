{{/* Validate that required fields are set. */}}
{{- define "claude-jobs.validate" -}}
{{- if not .Values.job.name -}}{{ fail "job.name is required" }}{{- end -}}
{{- if not .Values.job.schedule -}}{{ fail "job.schedule is required" }}{{- end -}}
{{- if not .Values.job.prompt -}}{{ fail "job.prompt is required" }}{{- end -}}
{{- if not .Values.job.allowedTools -}}{{ fail "job.allowedTools is required" }}{{- end -}}
{{- end -}}

{{- define "claude-jobs.fullname" -}}
claude-job-{{ .Values.job.name }}
{{- end -}}

{{- define "claude-jobs.labels" -}}
app.kubernetes.io/name: claude-jobs
app.kubernetes.io/instance: {{ include "claude-jobs.fullname" . }}
app.kubernetes.io/component: claude-job
homelab.chifor/job-name: {{ .Values.job.name }}
{{- end -}}
