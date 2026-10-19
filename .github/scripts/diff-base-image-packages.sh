#!/usr/bin/env bash
# Diffs installed RPM packages between old/new digests of any base image
# reference (FROM ...@sha256:...) that changed in a Containerfile between
# two git refs. Writes a Markdown summary to OUT_FILE.
set -euo pipefail

BASE_SHA="$1"
HEAD_SHA="$2"
OUT_FILE="${3:-base-image-diff.md}"

command -v podman >/dev/null || { sudo apt-get update && sudo apt-get install -y podman; }

: > "$OUT_FILE"

mapfile -t pairs < <(
  git diff --unified=0 "$BASE_SHA" "$HEAD_SHA" -- 'image/Containerfile' \
    | grep -E '^[+-]FROM [a-zA-Z0-9./_-]+(:[a-zA-Z0-9._-]+)?@sha256:[0-9a-f]{64}' \
    | sed -E 's/^([+-])FROM ([a-zA-Z0-9./_-]+)(:[a-zA-Z0-9._-]+)?@(sha256:[0-9a-f]{64}).*/\1 \2 \4/' \
    | sort -u
)

declare -A OLD_DIGEST
declare -A NEW_DIGEST

for line in "${pairs[@]:-}"; do
  [[ -z "$line" ]] && continue
  sign=${line%% *}
  rest=${line#* }
  image=${rest%% *}
  digest=${rest#* }
  if [[ "$sign" == "-" ]]; then
    OLD_DIGEST["$image"]="$digest"
  else
    NEW_DIGEST["$image"]="$digest"
  fi
done

rpm_list() {
  local ref="$1"
  podman run --rm --entrypoint '' "$ref" \
    rpm -qa --qf '%{NAME} %{VERSION}-%{RELEASE}.%{ARCH}\n' | sort
}

for image in "${!NEW_DIGEST[@]}"; do
  old="${OLD_DIGEST[$image]:-}"
  new="${NEW_DIGEST[$image]}"
  [[ -z "$old" || "$old" == "$new" ]] && continue

  echo "Diffing $image: $old -> $new" >&2

  old_pkgs=$(rpm_list "${image}@${old}")
  new_pkgs=$(rpm_list "${image}@${new}")

  {
    echo "### \`$image\`"
    echo
    echo "\`${old:0:19}\`... → \`${new:0:19}\`..."
    echo
  } >> "$OUT_FILE"

  added=$(comm -13 <(awk '{print $1}' <<<"$old_pkgs") <(awk '{print $1}' <<<"$new_pkgs"))
  removed=$(comm -23 <(awk '{print $1}' <<<"$old_pkgs") <(awk '{print $1}' <<<"$new_pkgs"))

  changed=""
  while read -r name old_evr; do
    [[ -z "$name" ]] && continue
    new_evr=$(awk -v n="$name" '$1==n{print $2}' <<<"$new_pkgs")
    if [[ -n "$new_evr" && "$new_evr" != "$old_evr" ]]; then
      changed+="| $name | $old_evr | $new_evr |\n"
    fi
  done <<<"$old_pkgs"

  if [[ -n "$changed" ]]; then
    {
      echo "**Updated packages**"
      echo
      echo "| Package | Old | New |"
      echo "|---|---|---|"
      echo -e "$changed"
    } >> "$OUT_FILE"
  fi

  if [[ -n "$added" ]]; then
    {
      echo "**Added packages**: $(echo "$added" | paste -sd, -)"
      echo
    } >> "$OUT_FILE"
  fi

  if [[ -n "$removed" ]]; then
    {
      echo "**Removed packages**: $(echo "$removed" | paste -sd, -)"
      echo
    } >> "$OUT_FILE"
  fi

  if [[ -z "$changed" && -z "$added" && -z "$removed" ]]; then
    echo "_No package changes detected._" >> "$OUT_FILE"
    echo >> "$OUT_FILE"
  fi
done
