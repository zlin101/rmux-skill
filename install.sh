#!/usr/bin/env sh
set -eu

REPO_OWNER=${RMUX_SKILL_REPO_OWNER:-zlin101}
REPO_NAME=${RMUX_SKILL_REPO_NAME:-rmux-skill}
REF=${RMUX_SKILL_REF:-main}
SKILL_NAME=${RMUX_SKILL_NAME:-rmux-skill}
SOURCE_URL=${RMUX_SKILL_SOURCE_URL:-"https://raw.githubusercontent.com/$REPO_OWNER/$REPO_NAME/$REF/rmux-skill/SKILL.md"}

usage() {
  cat <<'EOF'
Install rmux-skill for a file-based agent.

Usage:
  install.sh codex
  install.sh claude

Options:
  codex      Install to ~/.codex/skills/rmux-skill/SKILL.md
  claude     Install to ~/.claude/skills/rmux-skill/SKILL.md

Environment:
  SKILLS_DIR          Override the parent skills directory.
  RMUX_SKILL_REF      Git ref to install from. Defaults to main.
  RMUX_SKILL_SOURCE_URL
                      Override the SKILL.md download URL.
EOF
}

target=${1:-}
case "$target" in
  codex)
    default_skills_dir="$HOME/.codex/skills"
    ;;
  claude|claude-code)
    default_skills_dir="$HOME/.claude/skills"
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 2
    ;;
esac

skills_dir=${SKILLS_DIR:-$default_skills_dir}
install_dir="$skills_dir/$SKILL_NAME"
target_file="$install_dir/SKILL.md"

tmp_file=$(mktemp "${TMPDIR:-/tmp}/rmux-skill.XXXXXX")
cleanup() {
  rm -f "$tmp_file"
}
trap cleanup EXIT INT HUP TERM

download() {
  if command -v curl >/dev/null 2>&1; then
    curl -fsSL "$SOURCE_URL" -o "$tmp_file"
  elif command -v wget >/dev/null 2>&1; then
    wget -qO "$tmp_file" "$SOURCE_URL"
  else
    echo "error: curl or wget is required" >&2
    exit 1
  fi
}

download

if ! grep -q '^name: rmux-skill$' "$tmp_file"; then
  echo "error: downloaded file does not look like rmux-skill/SKILL.md" >&2
  echo "source: $SOURCE_URL" >&2
  exit 1
fi

mkdir -p "$install_dir"
cp "$tmp_file" "$target_file"
chmod 0644 "$target_file"

echo "Installed rmux-skill:"
echo "  $target_file"
