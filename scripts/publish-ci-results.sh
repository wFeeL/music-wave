#!/usr/bin/env bash
# Публикует ci-out/ в ветку ci-results: runs/<UTC>-<sha7>-<workflow>-<mode>-a<attempt>/.
# Запускается задачей publish (if: always()), единственной с правом contents: write, после того как артефакт ci-out
# скачан в ci-out/. Окружение: GH_TOKEN, CI_OUTCOME и MODE (в release.yml еще RELEASE_OUTCOME).
# Каждая попытка заново клонирует ветку (или создает orphan при первом запуске), до пяти попыток.
# Код 0 при успехе, 1 после пяти неудачных попыток. Рассчитан на bash 3.2 и BSD-утилиты, работает
# и на Linux-раннере (в том числе ubuntu-задачей publish).
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
ROOT=$PWD
OUT="$ROOT/ci-out"
BRANCH=ci-results

: "${GH_TOKEN:?GH_TOKEN is required}"
: "${GITHUB_REPOSITORY:?GITHUB_REPOSITORY is required}"

SHA=${GITHUB_SHA:-$(git rev-parse HEAD)}
SHA7=$(printf '%s' "$SHA" | cut -c1-7)
WORKFLOW=$(printf '%s' "${GITHUB_WORKFLOW:-mac}" | tr -c 'A-Za-z0-9._-' '-')
RUN_MODE=$(printf '%s' "${MODE:-unknown}" | tr -c 'A-Za-z0-9._-' '-')
ATTEMPT=${GITHUB_RUN_ATTEMPT:-1}
STAMP=$(date -u +%Y%m%dT%H%M%SZ)
RUN_DIR="runs/$STAMP-$SHA7-$WORKFLOW-$RUN_MODE-a$ATTEMPT"
SERVER=${GITHUB_SERVER_URL:-https://github.com}
RUN_URL="$SERVER/$GITHUB_REPOSITORY/actions/runs/${GITHUB_RUN_ID:-0}"
REMOTE="https://x-access-token:$GH_TOKEN@${SERVER#https://}/$GITHUB_REPOSITORY.git"

# Итог в копии ci-out дополняется данными workflow; сам ci-out не меняется.
write_summary() { # каталог результатов
    local summary="$1/summary.md"
    if [[ ! -f "$summary" ]]; then
        {
            echo "# WaveFeels CI: $RUN_MODE"
            echo
            echo "- result: no summary (ci step did not write ci-out/summary.md)"
        } > "$summary"
    fi
    {
        echo
        echo "## Workflow"
        echo
        echo "- ci step outcome: ${CI_OUTCOME:-unknown}"
        if [[ -n "${RELEASE_OUTCOME:-}" ]]; then
            echo "- release step outcome: $RELEASE_OUTCOME"
        fi
        echo "- ref: ${GITHUB_REF_NAME:-unknown}"
        echo "- run: $RUN_URL"
        echo "- results: $RUN_DIR"
    } >> "$summary"
}

publish_once() { # рабочий каталог
    local repo="$1/repo" rc
    git ls-remote --exit-code --heads "$REMOTE" "$BRANCH" > /dev/null 2>&1
    rc=$?
    if [[ $rc -eq 0 ]]; then
        git clone --quiet --depth 1 --single-branch --branch "$BRANCH" "$REMOTE" "$repo" || return 1
    elif [[ $rc -eq 2 ]]; then
        echo "branch $BRANCH does not exist yet, creating orphan"
        git init --quiet "$repo" || return 1
        git -C "$repo" checkout --quiet --orphan "$BRANCH" || return 1
    else
        echo "git ls-remote failed with code $rc"
        return 1
    fi

    mkdir -p "$repo/$RUN_DIR" || return 1
    if [[ -d "$OUT" ]]; then
        # ditto есть только в macOS; задача publish работает на ubuntu.
        if command -v ditto > /dev/null 2>&1; then
            ditto "$OUT" "$repo/$RUN_DIR" || return 1
        else
            cp -R "$OUT/." "$repo/$RUN_DIR" || return 1
        fi
    fi
    write_summary "$repo/$RUN_DIR" || return 1
    git -C "$repo" add -A "$RUN_DIR" || return 1
    git -C "$repo" \
        -c user.name="github-actions[bot]" \
        -c user.email="41898282+github-actions[bot]@users.noreply.github.com" \
        commit --quiet -m "ci: results $RUN_DIR (${CI_OUTCOME:-unknown})" || return 1
    git -C "$repo" push --quiet "$REMOTE" "HEAD:refs/heads/$BRANCH"
}

attempt=1
while [[ $attempt -le 5 ]]; do
    work=$(mktemp -d)
    if publish_once "$work"; then
        rm -rf "$work"
        echo "published CI results to $BRANCH:$RUN_DIR"
        exit 0
    fi
    rm -rf "$work"
    echo "publish attempt $attempt failed"
    sleep $((attempt * 3))
    attempt=$((attempt + 1))
done

echo "error: could not publish CI results after 5 attempts" >&2
exit 1
