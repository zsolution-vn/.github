#!/usr/bin/env bash
#
# setup-claude.sh — Onboard Claude Code GitHub Actions cho một repo trong org.
#
# Vì GitHub Free KHÔNG cho private repo dùng org-level secret, script này set
# secret ở cấp repo và copy file caller workflow vào repo đích.
#
# Yêu cầu:
#   - gh CLI đã đăng nhập (gh auth login) với quyền admin trên repo đích
#   - Biến môi trường ANTHROPIC_API_KEY và ANTHROPIC_BASE_URL đã export
#
# Cách dùng:
#   export ANTHROPIC_API_KEY="sk-..."
#   export ANTHROPIC_BASE_URL="https://your-gateway.example.com"
#
#   # 1 repo:
#   ./setup-claude.sh zsolution-vn/ten-repo
#
#   # Nhiều repo:
#   ./setup-claude.sh zsolution-vn/repo-a zsolution-vn/repo-b
#
#   # TẤT CẢ private repo trong org:
#   ./setup-claude.sh --all-private
#
#   # Theo danh sách trong file (mỗi dòng 1 owner/repo, bỏ qua dòng trống / bắt đầu bằng #):
#   ./setup-claude.sh --from-file scripts/claude-target-repos.txt
#
set -euo pipefail

ORG="zsolution-vn"
# Branch của repo .github chứa reusable workflow mà caller tham chiếu (@REF).
REUSABLE_REF="main"

# ---- Kiểm tra điều kiện ------------------------------------------------------
command -v gh >/dev/null 2>&1 || { echo "✗ Chưa cài gh CLI." >&2; exit 1; }
gh auth status >/dev/null 2>&1 || { echo "✗ gh chưa đăng nhập. Chạy: gh auth login" >&2; exit 1; }

: "${ANTHROPIC_API_KEY:?✗ Chưa export ANTHROPIC_API_KEY}"
: "${ANTHROPIC_BASE_URL:?✗ Chưa export ANTHROPIC_BASE_URL}"

# ---- Nội dung 2 file caller workflow ----------------------------------------
read -r -d '' CALLER_CLAUDE <<'YAML' || true
name: Claude Code

on:
  issue_comment:
    types: [created]
  pull_request_review_comment:
    types: [created]
  issues:
    types: [opened, assigned]
  pull_request_review:
    types: [submitted]

permissions:
  contents: write
  pull-requests: write
  issues: write
  id-token: write
  actions: read

jobs:
  claude:
    uses: zsolution-vn/.github/.github/workflows/claude-reusable.yml@main
    secrets: inherit
YAML

read -r -d '' CALLER_REVIEW <<'YAML' || true
name: Claude Code Review

on:
  pull_request:
    types: [opened, synchronize]

permissions:
  contents: read
  pull-requests: write
  issues: write
  id-token: write
  actions: read

jobs:
  claude-review:
    uses: zsolution-vn/.github/.github/workflows/claude-review-reusable.yml@main
    secrets: inherit
YAML

# ---- Hàm onboard 1 repo ------------------------------------------------------
setup_repo() {
  local repo="$1"
  echo "── $repo ──────────────────────────────────────────"

  # 1) Set repo-level secret (hoạt động trên private repo gói Free)
  gh secret set ANTHROPIC_API_KEY  --repo "$repo" --body "$ANTHROPIC_API_KEY"
  gh secret set ANTHROPIC_BASE_URL --repo "$repo" --body "$ANTHROPIC_BASE_URL"
  echo "  ✓ Đã set secret ANTHROPIC_API_KEY, ANTHROPIC_BASE_URL"

  # 2) Commit 2 file caller qua Contents API (không cần clone)
  put_workflow_file "$repo" ".github/workflows/claude.yml"            "$CALLER_CLAUDE"
  put_workflow_file "$repo" ".github/workflows/claude-code-review.yml" "$CALLER_REVIEW"
  echo "  ✓ Đã thêm caller workflow"
}

# put_workflow_file <repo> <path> <content>
put_workflow_file() {
  local repo="$1" path="$2" content="$3"
  local b64 sha args
  b64=$(printf '%s' "$content" | base64 | tr -d '\n')

  # Lấy sha hiện tại nếu file đã tồn tại (để update thay vì lỗi)
  sha=$(gh api "repos/$repo/contents/$path" --jq '.sha' 2>/dev/null || true)

  args=(--method PUT "repos/$repo/contents/$path"
        -f "message=chore: add Claude Code caller workflow"
        -f "content=$b64")
  [ -n "$sha" ] && args+=(-f "sha=$sha")

  gh api "${args[@]}" >/dev/null
}

# ---- Thu thập danh sách repo -------------------------------------------------
declare -a REPOS=()
if [ "${1:-}" = "--all-private" ]; then
  echo "→ Lấy danh sách private repo của org $ORG ..."
  while IFS= read -r r; do REPOS+=("$r"); done < <(
    gh repo list "$ORG" --visibility private --limit 500 --json nameWithOwner -q '.[].nameWithOwner'
  )
elif [ "${1:-}" = "--from-file" ]; then
  file="${2:?✗ Thiếu đường dẫn file sau --from-file}"
  [ -f "$file" ] || { echo "✗ Không thấy file: $file" >&2; exit 1; }
  while IFS= read -r r; do
    r="${r%%#*}"; r="$(echo "$r" | xargs)"   # bỏ comment + trim
    [ -n "$r" ] && REPOS+=("$r")
  done < "$file"
elif [ "$#" -ge 1 ]; then
  REPOS=("$@")
else
  echo "Cách dùng:" >&2
  echo "  $0 <owner/repo> [owner/repo ...]" >&2
  echo "  $0 --all-private" >&2
  echo "  $0 --from-file <path>" >&2
  exit 1
fi

[ "${#REPOS[@]}" -eq 0 ] && { echo "✗ Không có repo nào để xử lý." >&2; exit 1; }

echo "→ Sẽ onboard ${#REPOS[@]} repo (set 2 secret + commit 2 file caller vào mỗi repo)."
if [ "${ASSUME_YES:-}" != "1" ]; then
  printf "   Xác nhận tiếp tục? [y/N] "
  read -r ans
  case "$ans" in
    y|Y|yes|YES) ;;
    *) echo "Đã hủy."; exit 0 ;;
  esac
fi

for repo in "${REPOS[@]}"; do
  setup_repo "$repo"
done

echo ""
echo "✓ Hoàn tất. Nhắc nhở:"
echo "  - Cài Claude GitHub App cho các repo: https://github.com/apps/claude"
echo "  - Bật setting Access trên repo $ORG/.github:"
echo "    Settings → Actions → General → Access →"
echo "    'Accessible from repositories in the $ORG organization'"
