package safety

import "regexp"

var (
	privateKeyPattern    = regexp.MustCompile(`(?s)-----BEGIN [^-]*PRIVATE KEY-----.*?-----END [^-]*PRIVATE KEY-----`)
	authorizationPattern = regexp.MustCompile(`(?i)(authorization\s*:\s*(?:bearer\s+)?)[^\s]+`)
	credentialPattern    = regexp.MustCompile(`(?i)(api[_-]?key|access[_-]?token|token|password|secret)(\s*[:=]\s*)[^\s,;]+`)
	githubTokenPattern   = regexp.MustCompile(`\b(?:gh[pousr]_[A-Za-z0-9_]{12,}|github_pat_[A-Za-z0-9_]{12,})\b`)
	ansiPattern          = regexp.MustCompile(`\x1b\[[0-9;]*[A-Za-z]`)
)

func Redact(value string) string {
	value = ansiPattern.ReplaceAllString(value, "")
	value = privateKeyPattern.ReplaceAllString(value, "[REDACTED PRIVATE KEY]")
	value = authorizationPattern.ReplaceAllString(value, "${1}[REDACTED]")
	value = credentialPattern.ReplaceAllString(value, "${1}${2}[REDACTED]")
	value = githubTokenPattern.ReplaceAllString(value, "[REDACTED]")
	return value
}
