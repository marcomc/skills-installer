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
list_mode=false

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
    --list)
      list_mode=true
      ;;
  esac
  shift || true
done

if [[ "${list_mode}" = true ]]; then
  printf '│\n'
  printf '│  Skill With Spaces\n'
  printf '│      CLI-discovered smoke-test skill.\n'
  exit 0
fi

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
        target_base="${CODEX_HOME:-${HOME}/.codex}/skills"
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
printf 'CODEX_HOME=%s\n' "${CODEX_HOME:-}" >> "${MOCK_NPX_LOG}"
mkdir -p "${target_base}"
rm -rf "${target_base:?}/${skill_name}"
/bin/cp -R "${source_dir}/${skill_name}" "${target_base}/${skill_name}"
EOF
cat > "${bin_dir}/cp" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail

if [[ "${MOCK_CP_FAIL:-0}" = 1 ]]; then
  printf 'mock cp failure\n' >&2
  exit 73
fi

/bin/cp "$@"
EOF
chmod +x "${bin_dir}/npx" "${bin_dir}/cp"
export MOCK_NPX_LOG="${mock_npx_log}"
export PATH="${bin_dir}:${PATH}"

HOME="${home_dir}" "${repo_root}/install_external_agent_skills.sh" --config "${repo_root}/config/external-skills.example.conf" --list-plan >/dev/null

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

wrong_target="${tmp_root}/wrong-target"
mkdir -p "${wrong_target}"
rm "${fanout_link}"
ln -s "${wrong_target}" "${fanout_link}"

fanout_conflict_config="${tmp_root}/fanout-conflict.conf"
cat > "${fanout_conflict_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "symlink"
default_agents = ["codex", "openclaw"]

[agent_targets]
codex = "~/.codex/skills"
openclaw = "~/.openclaw/skills"

[[sources]]
name = "fanout-conflict"
source = "${src_dir}"
include = ["my-test-skill"]
agents = ["codex", "openclaw"]
full_depth = true
EOF

if HOME="${home_dir}" "${repo_root}/install_external_agent_skills.sh" --config "${fanout_conflict_config}" --no-install >/dev/null 2>&1; then
  fail "fanout conflict unexpectedly succeeded"
fi
openclaw_link="${home_dir}/.openclaw/skills/my-test-skill"
test -L "${openclaw_link}" || fail "fanout conflict stopped before later agent target"

canonical_conflict_source="${tmp_root}/canonical-conflict-source"
canonical_conflict_a_dir="${canonical_conflict_source}/canonical-conflict-a"
canonical_conflict_b_dir="${canonical_conflict_source}/canonical-conflict-b"
mkdir -p "${canonical_conflict_a_dir}" "${canonical_conflict_b_dir}"
cat > "${canonical_conflict_a_dir}/SKILL.md" <<'EOF'
---
name: canonical-conflict-a
description: Canonical conflict smoke-test skill.
---

# Canonical Conflict A
EOF
cat > "${canonical_conflict_b_dir}/SKILL.md" <<'EOF'
---
name: canonical-conflict-b
description: Canonical conflict smoke-test skill.
---

# Canonical Conflict B
EOF
ln -s "${wrong_target}" "${home_dir}/.agents/skills/canonical-conflict-a"

canonical_conflict_config="${tmp_root}/canonical-conflict.conf"
cat > "${canonical_conflict_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "symlink"
default_agents = ["codex"]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "canonical-conflict"
source = "${canonical_conflict_source}"
include = ["*"]
agents = ["codex"]
full_depth = true
EOF

if HOME="${home_dir}" "${repo_root}/install_external_agent_skills.sh" --config "${canonical_conflict_config}" --no-link >/dev/null 2>&1; then
  fail "canonical conflict unexpectedly succeeded"
fi
test -L "${home_dir}/.agents/skills/canonical-conflict-b" || fail "canonical conflict stopped before later skill"

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

real_codex_home="${tmp_root}/real-codex-home"
HOME="${home_dir}" CODEX_HOME="${real_codex_home}" MOCK_NPX_LAYOUT=agent "${repo_root}/install_external_agent_skills.sh" --config "${copy_install_config}"
HOME="${home_dir}" MOCK_NPX_LAYOUT=canonical "${repo_root}/install_external_agent_skills.sh" --config "${copy_install_config}"
if grep -Fxq "${home_dir}" "${mock_npx_log}"; then
  fail "copy-mode install used the real HOME instead of a temporary HOME"
fi
if [[ -e "${real_codex_home}/skills/copy-skill" ]]; then
  fail "copy-mode install wrote to real CODEX_HOME"
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

printf 'old canonical copy\n' > "${copy_canonical}/SKILL.md"
cat > "${home_skill_dir}/SKILL.md" <<'EOF'
---
name: copy-skill
description: Updated source smoke-test skill.
---

# New Source Copy
EOF
if HOME="${home_dir}" MOCK_NPX_LAYOUT=canonical MOCK_CP_FAIL=1 "${repo_root}/install_external_agent_skills.sh" --config "${copy_install_config}" >/dev/null 2>&1; then
  fail "copy-mode replacement succeeded despite mocked cp failure"
fi
if ! grep -Fq 'old canonical copy' "${copy_canonical}/SKILL.md"; then
  fail "failed copy-mode replacement did not preserve old canonical copy"
fi

dry_run_temp_dir="${home_dir}/.agents/skills/.copy-skill.tmp.DRYRUN"
mkdir -p "${dry_run_temp_dir}"
printf 'keep dry-run temp\n' > "${dry_run_temp_dir}/sentinel"
HOME="${home_dir}" "${repo_root}/install_external_agent_skills.sh" --config "${copy_install_config}" --dry-run >/dev/null
if ! grep -Fq 'keep dry-run temp' "${dry_run_temp_dir}/sentinel"; then
  fail "copy-mode dry-run removed existing deterministic temp directory"
fi

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

unsafe_source="${tmp_root}/unsafe-source"
unsafe_skill_dir="${unsafe_source}/unsafe-skill"
mkdir -p "${unsafe_skill_dir}"
cat > "${unsafe_skill_dir}/SKILL.md" <<'EOF'
---
name: ../../escaped-skill
description: Unsafe name smoke-test skill.
---

# Unsafe Skill
EOF

unsafe_config="${tmp_root}/unsafe-name.conf"
cat > "${unsafe_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "symlink"
default_agents = ["codex"]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "unsafe-name"
source = "${unsafe_source}"
include = ["*"]
agents = ["codex"]
EOF

if HOME="${home_dir}" "${repo_root}/install_external_agent_skills.sh" --config "${unsafe_config}" >/dev/null 2>&1; then
  fail "unsafe skill name was accepted"
fi
if [[ -e "${home_dir}/.agents/escaped-skill" ]] || [[ -L "${home_dir}/.agents/escaped-skill" ]]; then
  fail "unsafe skill name escaped canonical directory"
fi

filtered_source="${tmp_root}/filtered-source"
filtered_safe_dir="${filtered_source}/safe-skill"
filtered_unsafe_dir="${filtered_source}/personal/unsafe-skill"
mkdir -p "${filtered_safe_dir}" "${filtered_unsafe_dir}"
cat > "${filtered_safe_dir}/SKILL.md" <<'EOF'
---
name: safe-skill
description: Safe filtered smoke-test skill.
---

# Safe Skill
EOF
cat > "${filtered_unsafe_dir}/SKILL.md" <<'EOF'
---
name: ../../excluded-skill
description: Excluded unsafe name smoke-test skill.
---

# Excluded Unsafe Skill
EOF

filtered_config="${tmp_root}/filtered-name.conf"
cat > "${filtered_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "symlink"
default_agents = ["codex"]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "filtered-name"
source = "${filtered_source}"
include = ["*"]
exclude_paths = ["personal"]
agents = ["codex"]
EOF

filtered_plan="$(
  HOME="${home_dir}" \
  "${repo_root}/install_external_agent_skills.sh" \
    --config "${filtered_config}" \
    --list-plan
)"
printf '%s\n' "${filtered_plan}" | grep -Fq 'safe-skill' || fail "filtered safe skill missing"
if printf '%s\n' "${filtered_plan}" | grep -Fq 'excluded-skill'; then
  fail "excluded unsafe skill appeared in plan"
fi

invalid_frontmatter_source="${tmp_root}/invalid-frontmatter-source"
invalid_frontmatter_valid_dir="${invalid_frontmatter_source}/valid-skill"
invalid_frontmatter_invalid_dir="${invalid_frontmatter_source}/invalid-skill"
mkdir -p "${invalid_frontmatter_valid_dir}" "${invalid_frontmatter_invalid_dir}"
cat > "${invalid_frontmatter_valid_dir}/SKILL.md" <<'EOF'
---
name: valid-frontmatter-skill
description: Valid frontmatter smoke-test skill.
---

# Valid Frontmatter Skill
EOF
cat > "${invalid_frontmatter_invalid_dir}/SKILL.md" <<'EOF'
# Invalid Frontmatter Skill
EOF

invalid_frontmatter_config="${tmp_root}/invalid-frontmatter.conf"
cat > "${invalid_frontmatter_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "symlink"
default_agents = ["codex"]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "invalid-frontmatter"
source = "${invalid_frontmatter_source}"
include = ["*"]
agents = ["codex"]
EOF

invalid_frontmatter_plan="$(
  HOME="${home_dir}" \
  "${repo_root}/install_external_agent_skills.sh" \
    --config "${invalid_frontmatter_config}" \
    --list-plan
)"
printf '%s\n' "${invalid_frontmatter_plan}" | grep -Fq 'valid-frontmatter-skill' || fail "valid frontmatter skill missing"
if printf '%s\n' "${invalid_frontmatter_plan}" | grep -Fq 'invalid-skill'; then
  fail "invalid frontmatter SKILL.md appeared in plan"
fi

space_name_source="${tmp_root}/space-name-source"
space_name_skill_dir="${space_name_source}/space-name-skill"
mkdir -p "${space_name_skill_dir}"
cat > "${space_name_skill_dir}/SKILL.md" <<'EOF'
---
name: Skill With Spaces
description: Space-name smoke-test skill.
---

# Skill With Spaces
EOF

space_name_config="${tmp_root}/space-name.conf"
cat > "${space_name_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "symlink"
default_agents = ["codex"]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "space-name"
source = "${space_name_source}"
include = ["Skill With Spaces"]
agents = ["codex"]
EOF

space_name_plan="$(
  HOME="${home_dir}" \
  "${repo_root}/install_external_agent_skills.sh" \
    --config "${space_name_config}" \
    --list-plan
)"
printf '%s\n' "${space_name_plan}" | grep -Fq 'Skill With Spaces' || fail "local skill name with spaces missing"

cli_space_name_config="${tmp_root}/cli-space-name.conf"
cat > "${cli_space_name_config}" <<'EOF'
canonical_dir = "~/.agents/skills"
canonical_mode = "copy"
default_agents = ["codex"]

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "cli-space-name"
source = "not-a-local-source"
include = ["Skill With Spaces"]
agents = ["codex"]
EOF

cli_space_name_plan="$(
  HOME="${home_dir}" \
  "${repo_root}/install_external_agent_skills.sh" \
    --config "${cli_space_name_config}" \
    --list-plan
)"
printf '%s\n' "${cli_space_name_plan}" | grep -Fq 'Skill With Spaces' || fail "CLI skill name with spaces missing"

shallow_source="${tmp_root}/shallow-source"
shallow_direct_dir="${shallow_source}/direct-skill"
shallow_container_dir="${shallow_source}/skills/container-skill"
shallow_container_category_dir="${shallow_source}/skills/category/container-nested-skill"
shallow_nested_dir="${shallow_source}/category/nested-skill"
mkdir -p "${shallow_direct_dir}" "${shallow_container_dir}" "${shallow_container_category_dir}" "${shallow_nested_dir}"
cat > "${shallow_direct_dir}/SKILL.md" <<'EOF'
---
name: direct-skill
description: Direct shallow smoke-test skill.
---

# Direct Skill
EOF
cat > "${shallow_container_dir}/SKILL.md" <<'EOF'
---
name: container-skill
description: Container shallow smoke-test skill.
---

# Container Skill
EOF
cat > "${shallow_container_category_dir}/SKILL.md" <<'EOF'
---
name: container-nested-skill
description: Container nested shallow smoke-test skill.
---

# Container Nested Skill
EOF
cat > "${shallow_nested_dir}/SKILL.md" <<'EOF'
---
name: too-deep-skill
description: Too-deep shallow smoke-test skill.
---

# Too Deep Skill
EOF

shallow_config="${tmp_root}/shallow.conf"
cat > "${shallow_config}" <<EOF
canonical_dir = "~/.agents/skills"
canonical_mode = "symlink"
default_agents = ["codex"]
full_depth = false

[agent_targets]
codex = "~/.codex/skills"

[[sources]]
name = "shallow"
source = "${shallow_source}"
include = ["*"]
agents = ["codex"]
EOF

shallow_plan="$(
  HOME="${home_dir}" \
  "${repo_root}/install_external_agent_skills.sh" \
    --config "${shallow_config}" \
    --list-plan
)"
printf '%s\n' "${shallow_plan}" | grep -Fq 'direct-skill' || fail "direct skill missing with full_depth=false"
printf '%s\n' "${shallow_plan}" | grep -Fq 'container-skill' || fail "skills container skill missing with full_depth=false"
printf '%s\n' "${shallow_plan}" | grep -Fq 'container-nested-skill' || fail "skills category container skill missing with full_depth=false"
if printf '%s\n' "${shallow_plan}" | grep -Fq 'too-deep-skill'; then
  fail "nested category skill selected despite full_depth=false"
fi

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
