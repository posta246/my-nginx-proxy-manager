#!/usr/bin/env bash
#
# Daily dependency & CVE update helper.
#
# For every JavaScript sub-project it:
#   1. installs dependencies,
#   2. records outdated packages and the `yarn audit` summary (CVEs),
#   3. upgrades dependencies within their declared semver ranges,
#   4. records the post-upgrade audit summary and lockfile changes,
#   5. appends a human readable report to logs/updates/YYYY-MM-DD.md
#
# Environment variables:
#   NPM_UPDATE_SKIP_UPGRADE=true   Only audit/report, do not run `yarn upgrade`
#                                  (handy for local testing / dry runs).
#   NPM_UPDATE_PROJECTS="a b"      Override the list of projects to process.
#
# The script never aborts the whole run on a single project failure so that a
# broken sub-project still produces a log entry instead of an empty commit.

set -uo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$REPO_ROOT"

DATE="$(date -u +%F)"
TIMESTAMP="$(date -u '+%Y-%m-%d %H:%M:%S UTC')"
LOG_DIR="${REPO_ROOT}/logs/updates"
LOG_FILE="${LOG_DIR}/${DATE}.md"

SKIP_UPGRADE="${NPM_UPDATE_SKIP_UPGRADE:-false}"
read -r -a PROJECTS <<< "${NPM_UPDATE_PROJECTS:-backend frontend docs test}"

mkdir -p "$LOG_DIR"

log() { printf '%s\n' "$*" >> "$LOG_FILE"; }

# Extra flags passed to `yarn install` (e.g. --ignore-engines for local dry runs).
YARN_INSTALL_FLAGS="${YARN_INSTALL_FLAGS:-}"

# NOTE: `yarn audit`/`yarn outdated` exit non-zero when vulnerabilities/outdated
# packages exist. Combined with `set -o pipefail` that makes the whole pipeline
# non-zero, so we capture the parsed output first and only fall back when it is
# genuinely empty (otherwise the fallback string would be appended spuriously).
audit_summary() {
	local out
	out="$(yarn audit --json 2>/dev/null | jq -rs '
		(map(select(.type == "auditSummary")) | last | .data.vulnerabilities) as $v
		| if $v == null then empty
		  else "info \($v.info), low \($v.low), moderate \($v.moderate), high \($v.high), critical \($v.critical)"
		  end' 2>/dev/null)"
	if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "no audit data"; fi
}

outdated_list() {
	local out
	out="$(yarn outdated --json 2>/dev/null | jq -rs '
		(map(select(.type == "table")) | last | .data.body) as $b
		| if ($b == null or ($b | length) == 0) then empty
		  else ($b[] | "  - `\(.[0])`: \(.[1]) → wanted \(.[2]), latest \(.[3])")
		  end' 2>/dev/null)"
	if [ -n "$out" ]; then printf '%s\n' "$out"; else echo "  _None_"; fi
}

if [ ! -f "$LOG_FILE" ]; then
	{
		echo "# Dependency update log — ${DATE}"
		echo
		echo "Automated daily dependency & CVE update report."
	} > "$LOG_FILE"
fi

log ""
log "## Run at ${TIMESTAMP}"
if [ "$SKIP_UPGRADE" = "true" ]; then
	log ""
	log "> Mode: audit-only (upgrade skipped)."
fi

CHANGED=0

for proj in "${PROJECTS[@]}"; do
	[ -f "${proj}/package.json" ] || continue
	echo "::group::${proj}" 2>/dev/null || true
	echo "Processing ${proj} ..."

	log ""
	log "### ${proj}"

	pushd "$proj" >/dev/null || continue

	lock_before=""
	[ -f yarn.lock ] && lock_before="$(sha256sum yarn.lock | awk '{print $1}')"

	if ! yarn install --non-interactive ${YARN_INSTALL_FLAGS} >/tmp/yarn-install-"${proj}".log 2>&1; then
		log ""
		log "- ⚠️ \`yarn install\` failed — see workflow logs."
		popd >/dev/null || true
		continue
	fi

	log ""
	log "- Audit before: ${proj} → $(audit_summary)"
	log "- Outdated packages:"
	outdated_list | while IFS= read -r line; do log "$line"; done

	if [ "$SKIP_UPGRADE" != "true" ]; then
		if yarn upgrade --non-interactive >/tmp/yarn-upgrade-"${proj}".log 2>&1; then
			log "- Upgrade: completed (within declared semver ranges)."
		else
			log "- ⚠️ Upgrade: \`yarn upgrade\` reported errors — see workflow logs."
		fi
		log "- Audit after: ${proj} → $(audit_summary)"
	fi

	lock_after=""
	[ -f yarn.lock ] && lock_after="$(sha256sum yarn.lock | awk '{print $1}')"

	if [ "$lock_before" != "$lock_after" ]; then
		CHANGED=1
		numstat="$(git --no-pager diff --numstat -- yarn.lock package.json 2>/dev/null)"
		log "- Lockfile changed: **yes**"
		if [ -n "$numstat" ]; then
			log ""
			log '  ```'
			printf '%s\n' "$numstat" | while IFS= read -r line; do log "  $line"; done
			log '  ```'
		fi
	else
		log "- Lockfile changed: no"
	fi

	popd >/dev/null || true
done

log ""
if [ "$CHANGED" -eq 1 ]; then
	log "_Result: dependency changes were made in this run._"
else
	log "_Result: no dependency changes were required in this run._"
fi

echo "Log written to ${LOG_FILE}"

# Expose whether anything changed to the calling GitHub Actions step.
if [ -n "${GITHUB_OUTPUT:-}" ]; then
	echo "changed=${CHANGED}" >> "$GITHUB_OUTPUT"
	echo "log_file=logs/updates/${DATE}.md" >> "$GITHUB_OUTPUT"
fi

exit 0
