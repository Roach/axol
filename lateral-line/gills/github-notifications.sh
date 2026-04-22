#!/usr/bin/env bash
# github-notifications — poll GitHub's /notifications endpoint with a
# personal-access token and turn each unread thread into an Axol bubble.
#
# Intended to run on launchd with StartInterval: 30 (matches lateral-line's
# own cadence). One sample per invocation; failures are no-ops so the next
# sample retries.
#
# Credentials:
#   security add-generic-password -a "$USER" -s axol-github-pat -w <token>
# Token scope — fine-grained PAT with:
#   - "Notifications" read
#   - "Metadata" read (auto-granted)
# Classic-PAT equivalents: `notifications`.
#
# GILL_KEYCHAIN: axol-github-pat
# GILL_PAT_HELP: Create at https://github.com/settings/personal-access-tokens/new — set Account permissions → Notifications to Read.

set -euo pipefail

lib="$(cd "$(dirname "$0")" && pwd)/lib.sh"
# shellcheck source=./lib.sh
. "$lib"

gill_init "github-notifications"

gill_axol_up || { gill_log "axol not listening; skipping sample"; exit 0; }

token=$(gill_keychain_secret "axol-github-pat") || exit 0

# On first run, default the cursor to one hour ago so we don't flood the
# user with every stale unread notification they'd ignored before installing.
since=$(gill_cursor_read)
if [[ -z "$since" ]]; then
    since=$(date -u -v-1H +%FT%TZ 2>/dev/null || date -u -d '1 hour ago' +%FT%TZ)
fi

# Record "now" before the GET so the next cursor spans exactly the window
# we're about to query. Using the response time instead would risk losing
# notifications created between the server responding and us writing the
# cursor.
now=$(date -u +%FT%TZ)

if ! resp=$(curl -fsS --max-time 10 \
        -H "Authorization: Bearer $token" \
        -H 'Accept: application/vnd.github+json' \
        -H 'X-GitHub-Api-Version: 2022-11-28' \
        -H 'User-Agent: axol-lateral-line' \
        "https://api.github.com/notifications?since=$since&all=false"); then
    gill_log "GitHub fetch failed; will retry next sample"
    exit 0
fi

# GitHub returns an array; jq handles an empty one gracefully.
count=$(jq 'length' <<<"$resp")
if [[ "$count" -eq 0 ]]; then
    gill_cursor_write "$now"
    exit 0
fi

# Convert an api.github.com subject URL into the human-facing web URL.
# Pulls: /repos/X/Y/pulls/N → /X/Y/pull/N (pull, not pulls — GitHub's UI
# singular). Issues / Releases / Commits just drop the /repos prefix.
api_to_web_url() {
    local u="$1"
    u="${u#https://api.github.com}"
    u="${u/\/repos\///}"
    u="${u/\/pulls\//\/pull/}"
    printf 'https://github.com%s' "$u"
}

# Map GitHub's notification `reason` to Axol priority. Direct attention —
# someone asked for a review or @mentioned you — is worth pinning the
# bubble open; everything else rides the normal (auto-dismiss) lane.
priority_for_reason() {
    case "$1" in
        review_requested|mention|team_mention|assign|security_alert) printf 'urgent' ;;
        *) printf 'normal' ;;
    esac
}

delivered=0
while IFS= read -r item; do
    repo=$(jq -r '.repository.full_name' <<<"$item")
    subject_title=$(jq -r '.subject.title' <<<"$item")
    reason=$(jq -r '.reason' <<<"$item")
    subject_url=$(jq -r '.subject.url // empty' <<<"$item")
    web_url=""
    [[ -n "$subject_url" ]] && web_url=$(api_to_web_url "$subject_url")

    priority=$(priority_for_reason "$reason")

    envelope=$(jq -n \
        --arg title "$repo" \
        --arg body "$reason: $subject_title" \
        --arg prio "$priority" \
        --arg url "$web_url" \
        '{
            title: $title,
            body: $body,
            priority: $prio,
            source: "github-notifications",
            icon: "github",
            actions: (if $url == "" then [] else [{type:"open-url", url:$url, label:"View"}] end)
        }')

    if gill_post_envelope "$envelope"; then
        delivered=$((delivered + 1))
    else
        gill_log "local forward failed for $repo ($subject_title); leaving cursor unchanged and retrying next sample"
        exit 0
    fi
done < <(jq -c '.[]' <<<"$resp")

gill_cursor_write "$now"
gill_log "delivered=$delivered/$count cursor=$now"
