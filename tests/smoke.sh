#!/usr/bin/env bash
set -Eeuo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
tmp_root="$(mktemp -d)"

cleanup() {
  rm -rf "${tmp_root}"
}
trap cleanup EXIT

fail() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

src_dir="${tmp_root}/source"
home_dir="${tmp_root}/home"
config_file="${tmp_root}/external-skills.conf"
skill_dir="${src_dir}/my-test-skill"
literal_source="${tmp_root}/\$(touch pwned)"
literal_skill_dir="${literal_source}/literal-skill"
home_source_dir="${home_dir}/copy-source"
home_skill_dir="${home_source_dir}/copy-skill"

mkdir -p "${skill_dir}" "${home_dir}" "${literal_skill_dir}" "${home_skill_dir}"
cat > "${skill_dir}/SKILL.md" <<'EOF'
---
name: my-test-skill
description: Temporary smoke-test skill.
---

# My Test Skill
EOF
cat > "${literal_skill_dir}/SKILL.md" <<'EOF'
---
name: literal-skill
description: Literal path smoke-test skill.
---

# Literal Skill
EOF
cat > "${home_skill_dir}/SKILL.md" <<'EOF'
---
name: copy-skill
description: Expanded source smoke-test skill.
---

# Copy Skill
EOF

cat > "${config_file}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "symlink"
default_agents = [
  "codex",
]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "local-test"
source = "${src_dir}"
include = [
  "my-test-skill",
]
agents = [
  "codex",
]
full_depth = true
EOF

plan="$(
  HOME="${home_dir}" \
  SKILLS_INSTALLER_FORCE_MINIMAL_TOML=1 \
  "${repo_root}/install_external_agent_skills.sh" \
    --config "${config_file}" \
    --list-plan
)"

printf '%s\n' "${plan}" | grep -Fq 'mode=symlink' || fail "plan did not use symlink mode"
printf '%s\n' "${plan}" | grep -Fq "${skill_dir}" || fail "plan did not include source skill dir"

HOME="${home_dir}" \
SKILLS_INSTALLER_FORCE_MINIMAL_TOML=1 \
"${repo_root}/install_external_agent_skills.sh" \
  --config "${config_file}"

canonical_link="${home_dir}/.agents/skills/my-test-skill"
fanout_link="${home_dir}/.codex/skills/my-test-skill"

python3 - "${skill_dir}" "${canonical_link}" "${fanout_link}" <<'PY'
import os
import sys

source, canonical, fanout = sys.argv[1:]

if not os.path.islink(canonical):
    raise SystemExit(f"{canonical} is not a symlink")
if not os.path.islink(fanout):
    raise SystemExit(f"{fanout} is not a symlink")
if os.path.realpath(canonical) != os.path.realpath(source):
    raise SystemExit("canonical symlink does not resolve to source skill")
if os.path.realpath(fanout) != os.path.realpath(source):
    raise SystemExit("fanout symlink does not resolve to source skill")

fanout_target = os.readlink(fanout)
if not os.path.isabs(fanout_target):
    fanout_target = os.path.abspath(os.path.join(os.path.dirname(fanout), fanout_target))
if os.path.abspath(fanout_target) != os.path.abspath(canonical):
    raise SystemExit("fanout symlink does not point at canonical layer")
PY

expanded_config="${tmp_root}/expanded-source.conf"
cat > "${expanded_config}" <<'EOF'
canonical_dir = "~/.agents/skills"
canonical_mode = "copy"
default_agents = ["codex"]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "expanded-copy"
source = "$HOME/copy-source"
include = ["copy-skill"]
agents = ["codex"]
EOF

expanded_plan="$(
  HOME="${home_dir}" \
  "${repo_root}/install_external_agent_skills.sh" \
    --config "${expanded_config}" \
    --list-plan
)"
printf '%s\n' "${expanded_plan}" | grep -Fq "${home_source_dir}" || fail "local copy source was not expanded"

copy_false_config="${tmp_root}/copy-false.conf"
cat > "${copy_false_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "copy"
copy = false
default_agents = ["codex"]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "copy-false"
source = "${home_source_dir}"
include = ["copy-skill"]
agents = ["codex"]
EOF

if HOME="${home_dir}" "${repo_root}/install_external_agent_skills.sh" --config "${copy_false_config}" --list-plan >/dev/null 2>&1; then
  fail "copy mode accepted copy = false"
fi

literal_config="${tmp_root}/literal-source.conf"
cat > "${literal_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "copy"
default_agents = ["codex"]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "literal-source"
source = "${literal_source}"
include = ["literal-skill"]
agents = ["codex"]
EOF

HOME="${home_dir}" "${repo_root}/install_external_agent_skills.sh" --config "${literal_config}" --list-plan >/dev/null
if [[ -e "${repo_root}/pwned" ]] || [[ -e "${tmp_root}/pwned" ]]; then
  fail "command-substitution-looking source path was evaluated"
fi

link_source_config="${tmp_root}/link-source.conf"
cat > "${link_source_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "symlink"
default_agents = ["codex"]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "link-source"
source = "invalid-owner/invalid-repo"
link_source = "${src_dir}"
include = ["my-test-skill"]
agents = ["codex"]
EOF

link_source_plan="$(
  HOME="${home_dir}" \
  "${repo_root}/install_external_agent_skills.sh" \
    --config "${link_source_config}" \
    --list-plan
)"
printf '%s\n' "${link_source_plan}" | grep -Fq 'my-test-skill' || fail "symlink mode did not discover from link_source"

full_depth_source="${tmp_root}/full-depth-source"
mkdir -p "${full_depth_source}/nested/nested-skill"
cat > "${full_depth_source}/SKILL.md" <<'EOF'
---
name: root-skill
description: Root smoke-test skill.
---

# Root Skill
EOF
cat > "${full_depth_source}/nested/nested-skill/SKILL.md" <<'EOF'
---
name: nested-skill
description: Nested smoke-test skill.
---

# Nested Skill
EOF

full_depth_config="${tmp_root}/full-depth.conf"
cat > "${full_depth_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "symlink"
default_agents = ["codex"]
full_depth = false

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "root-only"
source = "${full_depth_source}"
include = ["*"]
agents = ["codex"]
EOF

full_depth_plan="$(
  HOME="${home_dir}" \
  "${repo_root}/install_external_agent_skills.sh" \
    --config "${full_depth_config}" \
    --list-plan
)"
printf '%s\n' "${full_depth_plan}" | grep -Fq 'root-skill' || fail "root skill missing with full_depth=false"
if printf '%s\n' "${full_depth_plan}" | grep -Fq 'nested-skill'; then
  fail "nested skill selected despite root skill and full_depth=false"
fi
