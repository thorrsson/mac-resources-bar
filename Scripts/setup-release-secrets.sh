#!/bin/bash
# Populate the release environment without executing the dotenv file as shell code.
set +x
set -euo pipefail

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'USAGE'
Usage: ./Scripts/setup-release-secrets.sh [options]

  -f, --env-file PATH    Dotenv file (default: .env in this checkout)
  -R, --repo OWNER/REPO  Target repository (default: this checkout's gh repository)
  -n, --dry-run          Validate and print secret names without uploading values
  -h, --help             Show this help

Copy .env.example to .env and fill in the release credentials first.
The release environment must already exist; its protection rules are not changed.
Requires an authenticated GitHub CLI (gh) with permission to manage its secrets.

Accepts one-line KEY=value entries, optional export prefixes, surrounding single
or double quotes, blank lines, and whole-line # comments. Values are literal:
no shell commands, variable interpolation, escape expansion, or inline comments.
Encode .p12/.p8 files as single-line base64 before adding them.
Unknown or duplicate keys are errors. Every secret is required.
USAGE
}

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${ROOT}/.env"
REPO=""
DRY_RUN=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        -f|--env-file)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "--env-file requires a path."
            ENV_FILE="$2"
            shift 2
            ;;
        -R|--repo)
            [[ $# -ge 2 && -n "$2" && "$2" != -* ]] || die "--repo requires OWNER/REPO."
            REPO="$2"
            shift 2
            ;;
        -n|--dry-run)
            DRY_RUN=1
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            die "unknown argument; see --help."
            ;;
    esac
done

[[ -f "${ENV_FILE}" && -r "${ENV_FILE}" ]] || die "cannot read dotenv file: ${ENV_FILE}"

# Exactly the secrets .github/workflows/release.yml reads.
required_secrets=(
    MACOS_CERTIFICATE_P12
    MACOS_CERTIFICATE_PASSWORD
    MACOS_SIGNING_IDENTITY
    NOTARY_API_KEY_ID
    NOTARY_API_ISSUER_ID
    NOTARY_API_KEY_P8
    SPARKLE_PUBLIC_ED_KEY
    SPARKLE_PRIVATE_ED_KEY
)
allowed_names=" ${required_secrets[*]} "
seen_names=" "
provided_names=" "
names=()
values=()
line_number=0
assignment='^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$'

trim() {
    REPLY="${1#"${1%%[![:space:]]*}"}"
    REPLY="${REPLY%"${REPLY##*[![:space:]]}"}"
}

while IFS= read -r line || [[ -n "${line}" ]]; do
    line_number=$((line_number + 1))
    trim "${line}"
    line="${REPLY}"
    [[ -z "${line}" || "${line}" == \#* ]] && continue
    [[ "${line}" =~ ${assignment} ]] \
        || die "invalid assignment on line ${line_number}; use one-line KEY=value entries."
    name="${BASH_REMATCH[2]}"
    value="${BASH_REMATCH[3]}"
    [[ "${allowed_names}" == *" ${name} "* ]] \
        || die "unrecognized release setting ${name} on line ${line_number}."
    [[ "${seen_names}" != *" ${name} "* ]] \
        || die "duplicate setting ${name} on line ${line_number}."
    seen_names+="${name} "

    trim "${value}"
    value="${REPLY}"
    case "${value}" in
        \"*|\'*)
            quote="${value:0:1}"
            [[ ${#value} -ge 2 && "${value: -1}" == "${quote}" ]] \
                || die "unmatched quote on line ${line_number}; use base64 for multiline keys."
            value="${value:1:${#value}-2}"
            ;;
    esac
    [[ -n "${value}" ]] || continue
    names+=("${name}")
    values+=("${value}")
    provided_names+="${name} "
done < "${ENV_FILE}"

for name in "${required_secrets[@]}"; do
    [[ "${provided_names}" == *" ${name} "* ]] || die "${name} must be set in the dotenv file."
done

# Keep CLI diagnostics non-interactive and prevent HTTP debug logging.
export GH_PROMPT_DISABLED=1
unset GH_DEBUG
if [[ -z "${REPO}" || "${DRY_RUN}" == 0 ]]; then
    command -v gh >/dev/null 2>&1 || die "GitHub CLI (gh) is required; install it and run gh auth login."
fi
if [[ -z "${REPO}" ]]; then
    REPO="$(cd "${ROOT}" && gh repo view --json nameWithOwner --jq .nameWithOwner)" \
        || die "cannot resolve the repository; check gh auth login or pass --repo OWNER/REPO."
fi
[[ "${REPO}" =~ ^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] || die "repository must be OWNER/REPO."

if [[ "${DRY_RUN}" == 0 ]]; then
    gh api --method GET "repos/${REPO}/environments/release" --silent \
        || die "cannot access ${REPO}'s release environment. Create it with required reviewers and v* tag restrictions first, and check gh authentication and repository permissions."
fi

for ((i = 0; i < ${#names[@]}; i++)); do
    if [[ "${DRY_RUN}" == 1 ]]; then
        printf 'Would set secret %s in %s/release\n' "${names[$i]}" "${REPO}"
    else
        # stdin keeps plaintext out of command arguments and process listings.
        printf '%s' "${values[$i]}" | gh secret set "${names[$i]}" --env release --repo "${REPO}" \
            || die "failed to set secret ${names[$i]}; earlier uploads may have succeeded. Fix the error and rerun."
        printf 'Set secret %s in %s/release\n' "${names[$i]}" "${REPO}"
    fi
done
