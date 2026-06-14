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
bin_dir="${tmp_root}/bin"
config_file="${tmp_root}/external-skills.conf"
skill_dir="${src_dir}/my-test-skill"
literal_source="${tmp_root}/\$(touch pwned)"
literal_skill_dir="${literal_source}/literal-skill"
home_source_dir="${home_dir}/copy-source"
home_skill_dir="${home_source_dir}/copy-skill"
mock_npx_log="${tmp_root}/npx.log"

mkdir -p "${skill_dir}" "${home_dir}" "${literal_skill_dir}" "${home_skill_dir}" "${bin_dir}"
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
cat > "${bin_dir}/npx" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

source_dir=""
skill_name=""
agent_name=""
copy_mode=false

while [[ "$#" -gt 0 ]]; do
  case "$1" in
    add)
      shift
      source_dir="${1:-}"
      ;;
    --agent)
      shift
      agent_name="${1:-}"
      ;;
    --skill)
      shift
      skill_name="${1:-}"
      ;;
    --copy)
      copy_mode=true
      ;;
  esac
  shift || true
done

if [[ "${copy_mode}" != true ]] || [[ -z "${source_dir}" ]] || [[ -z "${skill_name}" ]]; then
  printf 'mock npx only supports skills add --copy with --skill\n' >&2
  exit 2
fi

case "${MOCK_NPX_LAYOUT:-agent}" in
  canonical)
    target_base="${HOME}/.agents/skills"
    ;;
  agent)
    case "${agent_name}" in
      codex)
        target_base="${HOME}/.codex/skills"
        ;;
      *)
        printf 'unsupported mock agent: %s\n' "${agent_name}" >&2
        exit 2
        ;;
    esac
    ;;
  *)
    printf 'unsupported mock layout: %s\n' "${MOCK_NPX_LAYOUT}" >&2
    exit 2
    ;;
esac

printf '%s\n' "${HOME}" >> "${MOCK_NPX_LOG}"
mkdir -p "${target_base}"
rm -rf "${target_base:?}/${skill_name}"
cp -R "${source_dir}/${skill_name}" "${target_base}/${skill_name}"
EOF
chmod +x "${bin_dir}/npx"
export MOCK_NPX_LOG="${mock_npx_log}"
export PATH="${bin_dir}:${PATH}"

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

rm "${fanout_link}"
ln -s "${skill_dir}" "${fanout_link}"

HOME="${home_dir}" \
SKILLS_INSTALLER_FORCE_MINIMAL_TOML=1 \
"${repo_root}/install_external_agent_skills.sh" \
  --config "${config_file}" \
  --no-install \
  --force-links

python3 - "${canonical_link}" "${fanout_link}" <<'PY'
import os
import sys

canonical, fanout = sys.argv[1:]

if not os.path.islink(fanout):
    raise SystemExit(f"{fanout} is not a symlink")

fanout_target = os.readlink(fanout)
if not os.path.isabs(fanout_target):
    fanout_target = os.path.abspath(os.path.join(os.path.dirname(fanout), fanout_target))
if os.path.abspath(fanout_target) != os.path.abspath(canonical):
    raise SystemExit("repaired fanout symlink does not point at canonical layer")
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

copy_install_config="${tmp_root}/copy-install.conf"
cat > "${copy_install_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "copy"
default_agents = ["codex"]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "copy-install"
source = "${home_source_dir}"
include = ["copy-skill"]
agents = ["codex"]
EOF

HOME="${home_dir}" MOCK_NPX_LAYOUT=agent "${repo_root}/install_external_agent_skills.sh" --config "${copy_install_config}"
HOME="${home_dir}" MOCK_NPX_LAYOUT=canonical "${repo_root}/install_external_agent_skills.sh" --config "${copy_install_config}"
if grep -Fxq "${home_dir}" "${mock_npx_log}"; then
  fail "copy-mode install used the real HOME instead of a temporary HOME"
fi

copy_canonical="${home_dir}/.agents/skills/copy-skill"
copy_fanout="${home_dir}/.codex/skills/copy-skill"

python3 - "${home_skill_dir}" "${copy_canonical}" "${copy_fanout}" <<'PY'
import os
import sys

source, canonical, fanout = sys.argv[1:]

if not os.path.isdir(canonical) or os.path.islink(canonical):
    raise SystemExit("canonical copy is not a real directory")
if os.path.realpath(canonical) == os.path.realpath(source):
    raise SystemExit("canonical copy resolves to source instead of a copied directory")
if not os.path.isfile(os.path.join(canonical, "SKILL.md")):
    raise SystemExit("canonical copy is missing SKILL.md")
if not os.path.islink(fanout):
    raise SystemExit("copy fanout is not a symlink")

fanout_target = os.readlink(fanout)
if not os.path.isabs(fanout_target):
    fanout_target = os.path.abspath(os.path.join(os.path.dirname(fanout), fanout_target))
if os.path.abspath(fanout_target) != os.path.abspath(canonical):
    raise SystemExit("copy fanout symlink does not point at canonical layer")
PY

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

install_home="${tmp_root}/install-home"
install_prefix="${tmp_root}/install-prefix"
install_config_home="${tmp_root}/xdg-config"
mkdir -p "${install_home}" "${install_prefix}" "${install_config_home}"

HOME="${install_home}" \
XDG_CONFIG_HOME="${install_config_home}" \
make -C "${repo_root}" install PREFIX="${install_prefix}" >/dev/null

test -x "${install_prefix}/bin/install_external_agent_skills.sh" || fail "make install did not install script"
test -f "${install_config_home}/skills-installer/external-skills.conf" || fail "make install ignored XDG_CONFIG_HOME"
if [[ -e "${install_home}/.config/skills-installer/external-skills.conf" ]]; then
  fail "make install wrote config under HOME/.config despite XDG_CONFIG_HOME"
fi
