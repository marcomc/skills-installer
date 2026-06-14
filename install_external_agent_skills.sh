#!/usr/bin/env bash
set -Eeuo pipefail

readonly DEFAULT_CONFIG="${XDG_CONFIG_HOME:-${HOME}/.config}/skills-installer/external-skills.conf"

CONFIG_FILE="${SKILLS_INSTALLER_CONFIG:-${DEFAULT_CONFIG}}"
DRY_RUN=false
FORCE_LINKS=false
NO_INSTALL=false
NO_LINK=false
LIST_PLAN=false
BACKUP_STAMP="$(date +'%Y%m%d%H%M%S')"
PLAN_FILE=""

usage() {
  cat <<'USAGE'
Usage: install_external_agent_skills.sh [options]

Install external agent skills into ~/.agents/skills, then fan out symlinks from
~/.agents/skills into agent-specific skill directories.

Options:
  -c, --config FILE   TOML config file.
                     Default: ~/.config/skills-installer/external-skills.conf
      --dry-run       Print commands and planned link changes without mutating.
      --force-links   Replace existing non-symlink agent skill entries by
                     moving them to *.backup.TIMESTAMP first.
      --list-plan     Show the resolved install plan and exit.
      --no-install    Skip canonical install/linking and only repair agent links.
      --no-link       Install canonical copies but skip symlink repair.
  -h, --help          Show this help.
USAGE
}

log() {
  printf '%s\n' "$*"
}

warn() {
  printf 'warning: %s\n' "$*" >&2
}

die() {
  printf 'error: %s\n' "$*" >&2
  exit 1
}

need_cmd() {
  command -v "$1" >/dev/null 2>&1 || die "required command not found: $1"
}

run_cmd() {
  if [[ "${DRY_RUN}" = true ]]; then
    printf '+'
    printf ' %q' "$@"
    printf '\n'
  else
    "$@"
  fi
}

parse_args() {
  while [[ "$#" -gt 0 ]]; do
    case "$1" in
      -c|--config)
        [[ "$#" -ge 2 ]] || die "$1 requires a file path"
        CONFIG_FILE="$2"
        shift 2
        ;;
      --dry-run)
        DRY_RUN=true
        shift
        ;;
      --force-links)
        FORCE_LINKS=true
        shift
        ;;
      --list-plan)
        LIST_PLAN=true
        shift
        ;;
      --no-install)
        NO_INSTALL=true
        shift
        ;;
      --no-link)
        NO_LINK=true
        shift
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        die "unknown option: $1"
        ;;
    esac
  done
}

link_resolves_to() {
  local link_path="$1"
  local expected_target="$2"

  python3 - "${link_path}" "${expected_target}" <<'PY'
import os
import sys

link_path = sys.argv[1]
expected_target = sys.argv[2]

if not os.path.islink(link_path):
    sys.exit(1)

actual_target = os.readlink(link_path)
if not os.path.isabs(actual_target):
    actual_target = os.path.abspath(
        os.path.join(os.path.dirname(link_path), actual_target)
    )

if os.path.realpath(actual_target) == os.path.realpath(expected_target):
    sys.exit(0)

sys.exit(1)
PY
}

link_targets_path() {
  local link_path="$1"
  local expected_target="$2"

  python3 - "${link_path}" "${expected_target}" <<'PY'
import os
import sys

link_path = sys.argv[1]
expected_target = sys.argv[2]

if not os.path.islink(link_path):
    sys.exit(1)

actual_target = os.readlink(link_path)
if not os.path.isabs(actual_target):
    actual_target = os.path.abspath(
        os.path.join(os.path.dirname(link_path), actual_target)
    )

if os.path.abspath(actual_target) == os.path.abspath(expected_target):
    sys.exit(0)

sys.exit(1)
PY
}

relative_link_target() {
  local source_dir="$1"
  local target_dir="$2"

  python3 - "${source_dir}" "${target_dir}" <<'PY'
import os
import sys

print(os.path.relpath(sys.argv[1], sys.argv[2]))
PY
}

backup_existing_target() {
  local target_skill_dir="$1"
  local backup_dir
  local counter=1

  backup_dir="${target_skill_dir}.backup.${BACKUP_STAMP}"
  while [[ -e "${backup_dir}" ]] || [[ -L "${backup_dir}" ]]; do
    backup_dir="${target_skill_dir}.backup.${BACKUP_STAMP}.${counter}"
    counter=$((counter + 1))
  done

  run_cmd mv "${target_skill_dir}" "${backup_dir}"
}

run_cmd_with_home() {
  local home_dir="$1"
  local config_home
  local env_vars
  shift

  config_home="${home_dir}/.config"
  env_vars=(
    HOME="${home_dir}"
    XDG_CONFIG_HOME="${config_home}"
    FLATPAK_XDG_CONFIG_HOME="${config_home}"
    APPDATA="${config_home}"
    CODEX_HOME="${home_dir}/.codex"
    CLAUDE_CONFIG_DIR="${home_dir}/.claude"
    VIBE_HOME="${home_dir}/.vibe"
    HERMES_HOME="${home_dir}/.hermes"
    AUTOHAND_HOME="${home_dir}/.autohand"
  )

  if [[ "${DRY_RUN}" = true ]]; then
    printf '+ env'
    printf ' %q' "${env_vars[@]}"
    printf ' %q' "$@"
    printf '\n'
  else
    env "${env_vars[@]}" "$@"
  fi
}

expand_path_for_home() {
  local raw_path="$1"
  local home_dir="$2"

  HOME="${home_dir}" python3 - "${raw_path}" <<'PY'
import os
import sys

print(os.path.abspath(os.path.expandvars(os.path.expanduser(sys.argv[1]))))
PY
}

restore_errexit() {
  local was_set="$1"

  if [[ "${was_set}" = true ]]; then
    set -e
  else
    set +e
  fi
}

ensure_canonical_symlink() {
  local source_skill_dir="$1"
  local canonical_dir="$2"
  local skill_name="$3"
  local canonical_skill_dir
  local link_target
  local link_status
  local errexit_was_set=false

  canonical_skill_dir="${canonical_dir}/${skill_name}"

  if [[ ! -d "${source_skill_dir}" ]]; then
    warn "source skill missing, cannot link canonical skill: ${source_skill_dir}"
    return 1
  fi

  run_cmd mkdir -p "${canonical_dir}"

  if [[ -L "${canonical_skill_dir}" ]]; then
    if [[ $- == *e* ]]; then
      errexit_was_set=true
    fi
    set +e
    link_resolves_to "${canonical_skill_dir}" "${source_skill_dir}"
    link_status=$?
    restore_errexit "${errexit_was_set}"
    if [[ "${link_status}" -eq 0 ]]; then
      log "canonical link ok: ${canonical_skill_dir}"
      return 0
    fi

    if [[ "${FORCE_LINKS}" != true ]]; then
      warn "existing canonical symlink points elsewhere: ${canonical_skill_dir}"
      return 1
    fi

    run_cmd rm "${canonical_skill_dir}"
  elif [[ -e "${canonical_skill_dir}" ]]; then
    if [[ "${FORCE_LINKS}" != true ]]; then
      warn "existing canonical non-symlink left untouched: ${canonical_skill_dir}"
      return 1
    fi

    backup_existing_target "${canonical_skill_dir}"
  fi

  link_target="$(relative_link_target "${source_skill_dir}" "${canonical_dir}")"
  run_cmd ln -s "${link_target}" "${canonical_skill_dir}"
}

ensure_skill_link() {
  local canonical_skill_dir="$1"
  local target_base_dir="$2"
  local skill_name="$3"
  local target_skill_dir
  local link_target
  local link_status
  local errexit_was_set=false

  target_skill_dir="${target_base_dir}/${skill_name}"

  if [[ "${DRY_RUN}" != true ]] && [[ ! -d "${canonical_skill_dir}" ]]; then
    warn "canonical skill missing, cannot link: ${canonical_skill_dir}"
    return 1
  fi

  run_cmd mkdir -p "${target_base_dir}"

  if [[ -L "${target_skill_dir}" ]]; then
    if [[ $- == *e* ]]; then
      errexit_was_set=true
    fi
    set +e
    link_targets_path "${target_skill_dir}" "${canonical_skill_dir}"
    link_status=$?
    restore_errexit "${errexit_was_set}"
    if [[ "${link_status}" -eq 0 ]]; then
      log "link ok: ${target_skill_dir}"
      return 0
    fi

    if [[ "${FORCE_LINKS}" != true ]]; then
      warn "existing symlink points elsewhere: ${target_skill_dir}"
      return 1
    fi

    run_cmd rm "${target_skill_dir}"
  elif [[ -e "${target_skill_dir}" ]]; then
    if [[ "${FORCE_LINKS}" != true ]]; then
      warn "existing non-symlink target left untouched: ${target_skill_dir}"
      return 1
    fi

    backup_existing_target "${target_skill_dir}"
  fi

  link_target="$(relative_link_target "${canonical_skill_dir}" "${target_base_dir}")"
  run_cmd ln -s "${link_target}" "${target_skill_dir}"
}

generate_plan() {
  local config_file="$1"

  python3 - "${config_file}" <<'PY'
import contextlib
import fnmatch
import os
import re
import shutil
import subprocess
import sys
import tempfile

CONFIG_FILE = sys.argv[1]
ANSI_RE = re.compile(r"\x1b\[[0-9;?]*[A-Za-z]")
SAFE_SKILL_NAME_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9_.-]*$")
SKILL_LINE_RE = re.compile(r"^\s*│\s{4}([A-Za-z0-9][A-Za-z0-9_.-]*)\s*$")

DEFAULT_AGENT_TARGETS = {
    "codex": "~/.codex/skills",
    "claude-code": "~/.claude/skills",
    "claude": "~/.claude/skills",
    "openclaw": "~/.openclaw/skills",
    "github-copilot": "~/.copilot/skills",
    "copilot": "~/.copilot/skills",
    "gemini-cli": "~/.gemini/skills",
    "gemini": "~/.gemini/skills",
    "opencode": "~/.config/opencode/skills",
    "antigravity": "~/.gemini/antigravity/skills",
    "antigravity-cli": "~/.gemini/antigravity-cli/skills",
}

DEFAULT_AGENTS = [
    "codex",
    "claude-code",
    "openclaw",
    "github-copilot",
    "gemini-cli",
    "opencode",
    "antigravity",
    "antigravity-cli",
]


def warn(message):
    print(f"warning: {message}", file=sys.stderr)


def strip_comment(line):
    quote = None
    escaped = False
    chars = []
    for char in line:
        if escaped:
            chars.append(char)
            escaped = False
            continue
        if char == "\\":
            chars.append(char)
            escaped = True
            continue
        if quote:
            chars.append(char)
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
            chars.append(char)
            continue
        if char == "#":
            break
        chars.append(char)
    return "".join(chars).strip()


def parse_array(value):
    value = value.strip()
    if not (value.startswith("[") and value.endswith("]")):
        raise ValueError(f"expected TOML array, got {value!r}")
    inner = value[1:-1].strip()
    if not inner:
        return []

    result = []
    current = []
    quote = None
    escaped = False
    for char in inner:
        if escaped:
            current.append(char)
            escaped = False
            continue
        if char == "\\":
            current.append(char)
            escaped = True
            continue
        if quote:
            current.append(char)
            if char == quote:
                quote = None
            continue
        if char in ("'", '"'):
            quote = char
            current.append(char)
            continue
        if char == ",":
            result.append(parse_scalar("".join(current).strip()))
            current = []
            continue
        current.append(char)
    if current:
        result.append(parse_scalar("".join(current).strip()))
    return result


def parse_scalar(value):
    value = value.strip()
    if value in ("true", "false"):
        return value == "true"
    if value.startswith("["):
        return parse_array(value)
    if len(value) >= 2 and value[0] == value[-1] and value[0] in ("'", '"'):
        return value[1:-1]
    return value


def load_minimal_toml(file_name):
    config = {}
    current = config

    with open(file_name, "r", encoding="utf-8") as handle:
        for line_number, line in iter_logical_toml_lines(handle, file_name):
            if line == "[agent_targets]":
                current = config.setdefault("agent_targets", {})
                continue

            if line == "[[sources]]":
                source = {}
                config.setdefault("sources", []).append(source)
                current = source
                continue

            if "=" not in line:
                raise ValueError(f"{file_name}:{line_number}: invalid TOML line")

            key, value = line.split("=", 1)
            current[key.strip()] = parse_scalar(value)

    return config


def iter_logical_toml_lines(handle, file_name):
    pending = []
    pending_start = 0
    bracket_depth = 0

    for line_number, raw_line in enumerate(handle, 1):
        line = strip_comment(raw_line)
        if not line:
            continue

        if pending:
            pending.append(line)
            bracket_depth += line.count("[") - line.count("]")
            if bracket_depth <= 0:
                yield pending_start, " ".join(pending)
                pending = []
                pending_start = 0
                bracket_depth = 0
            continue

        if is_multiline_array_start(line):
            pending = [line]
            pending_start = line_number
            bracket_depth = line.count("[") - line.count("]")
            continue

        yield line_number, line

    if pending:
        raise ValueError(f"{file_name}:{pending_start}: unterminated TOML array")


def is_multiline_array_start(line):
    if line.startswith("["):
        return False
    if "=" not in line:
        return False
    value = line.split("=", 1)[1].strip()
    return value.startswith("[") and not value.endswith("]")


def load_config(file_name):
    if os.environ.get("SKILLS_INSTALLER_FORCE_MINIMAL_TOML") == "1":
        return load_minimal_toml(file_name)

    try:
        import tomllib

        with open(file_name, "rb") as handle:
            return tomllib.load(handle)
    except ModuleNotFoundError:
        pass

    try:
        import tomli

        with open(file_name, "rb") as handle:
            return tomli.load(handle)
    except ModuleNotFoundError:
        return load_minimal_toml(file_name)


def expand_user(value):
    return os.path.abspath(os.path.expandvars(os.path.expanduser(str(value))))


def source_to_clone_url(source):
    expanded = expand_user(source)
    if os.path.isdir(expanded):
        return None
    if re.match(r"^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", source):
        return f"https://github.com/{source}.git"
    if source.startswith(("https://", "http://", "ssh://", "git@")):
        return source
    return None


@contextlib.contextmanager
def materialized_source(source):
    expanded = expand_user(source)
    if os.path.isdir(expanded):
        yield expanded
        return

    clone_url = source_to_clone_url(source)
    if not clone_url:
        yield None
        return

    if not shutil.which("git"):
        warn("git not found; path-based include/exclude filters are unavailable")
        yield None
        return

    with tempfile.TemporaryDirectory(prefix="skills-installer-") as temp_dir:
        checkout_dir = os.path.join(temp_dir, "source")
        command = ["git", "clone", "--depth", "1", clone_url, checkout_dir]
        result = subprocess.run(
            command,
            check=False,
            stdout=subprocess.PIPE,
            stderr=subprocess.PIPE,
            text=True,
        )
        if result.returncode != 0:
            warn(f"could not clone {source!r}; falling back to CLI list")
            yield None
            return
        yield checkout_dir


def read_skill_name(skill_file):
    frontmatter = {}
    in_frontmatter = False
    with open(skill_file, "r", encoding="utf-8") as handle:
        for raw_line in handle:
            line = raw_line.strip()
            if line == "---":
                if not in_frontmatter:
                    in_frontmatter = True
                    continue
                break
            if in_frontmatter and ":" in line:
                key, value = line.split(":", 1)
                key = key.strip()
                value = value.strip().strip("'\"")
                if key in {"name", "description"} and value:
                    frontmatter[key] = value
    if "name" in frontmatter and "description" in frontmatter:
        return frontmatter["name"]
    return None


def validate_skill_name(skill_name, source_path):
    if SAFE_SKILL_NAME_RE.match(skill_name):
        return
    raise SystemExit(
        f"error: unsafe skill name {skill_name!r} in {source_path}; "
        "skill names must match [A-Za-z0-9][A-Za-z0-9_.-]*"
    )


def discover_tree_skills(root_dir, full_depth):
    if not full_depth and os.path.isfile(os.path.join(root_dir, "SKILL.md")):
        skill_file = os.path.join(root_dir, "SKILL.md")
        skill_name = read_skill_name(skill_file)
        if not skill_name:
            return {}
        return {skill_name: "."}

    discovered = {}
    for current_dir, dir_names, file_names in os.walk(root_dir):
        dir_names[:] = [
            name
            for name in dir_names
            if name not in {".git", ".hg", ".svn", "node_modules", "__pycache__"}
        ]
        if not full_depth and os.path.relpath(current_dir, root_dir) != ".":
            dir_names[:] = []

        if "SKILL.md" not in file_names:
            continue

        skill_file = os.path.join(current_dir, "SKILL.md")
        skill_name = read_skill_name(skill_file)
        if not skill_name:
            continue
        relative_dir = os.path.relpath(current_dir, root_dir)
        if skill_name in discovered:
            warn(f"duplicate skill name {skill_name!r}; using first occurrence")
            continue
        discovered[skill_name] = relative_dir

    return discovered


def discover_cli_skills(source, full_depth):
    if not shutil.which("npx"):
        raise SystemExit("error: required command not found: npx")

    command = ["npx", "--yes", "skills@latest", "add", source, "--list"]
    if full_depth:
        command.append("--full-depth")

    result = subprocess.run(
        command,
        check=False,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        text=True,
    )
    if result.returncode != 0:
        sys.stderr.write(result.stderr)
        raise SystemExit(f"error: failed to list skills for source: {source}")

    skills = {}
    for raw_line in result.stdout.splitlines():
        line = ANSI_RE.sub("", raw_line)
        match = SKILL_LINE_RE.match(line)
        if match:
            skills[match.group(1)] = match.group(1)
    return skills


def normalize_list(value, default):
    if value is None:
        return list(default)
    if isinstance(value, str):
        return [value]
    return [str(item) for item in value]


def matches_filter(pattern, skill_name, relative_dir):
    if pattern == "*":
        return True
    segments = set(relative_dir.split(os.sep))
    return (
        fnmatch.fnmatch(skill_name, pattern)
        or fnmatch.fnmatch(relative_dir, pattern)
        or pattern in segments
    )


def selected_skills(discovered, include, exclude, exclude_paths):
    selected = []
    for skill_name, relative_dir in sorted(discovered.items()):
        if not any(matches_filter(pattern, skill_name, relative_dir) for pattern in include):
            continue
        if any(matches_filter(pattern, skill_name, relative_dir) for pattern in exclude):
            continue
        if any(matches_filter(pattern, skill_name, relative_dir) for pattern in exclude_paths):
            continue
        selected.append(skill_name)
    return selected


def discover_source_skills(source, full_depth):
    with materialized_source(source) as root_dir:
        if root_dir:
            discovered = discover_tree_skills(root_dir, full_depth)
            if discovered:
                return discovered
    return discover_cli_skills(source, full_depth)


def bool_value(config, key, default):
    value = config.get(key, default)
    if isinstance(value, bool):
        return value
    return str(value).lower() in {"1", "true", "yes", "on"}


def make_plan(config):
    canonical_dir = expand_user(config.get("canonical_dir", "~/.agents/skills"))
    default_agents = normalize_list(config.get("default_agents"), DEFAULT_AGENTS)
    installer_agent = str(config.get("installer_agent", "codex"))
    default_full_depth = bool_value(config, "full_depth", True)
    default_copy = bool_value(config, "copy", True)
    default_canonical_mode = str(config.get("canonical_mode", "copy")).lower()

    agent_targets = dict(DEFAULT_AGENT_TARGETS)
    for agent, target_dir in config.get("agent_targets", {}).items():
        agent_targets[str(agent)] = str(target_dir)

    sources = config.get("sources", [])
    if not sources:
        raise SystemExit("error: config has no [[sources]] entries")

    rows = []
    for source_config in sources:
        source = str(source_config.get("source", "")).strip()
        if not source:
            raise SystemExit("error: every [[sources]] entry needs source = ...")

        expanded_source = expand_user(source)
        install_source = expanded_source if os.path.isdir(expanded_source) else source
        full_depth = bool_value(source_config, "full_depth", default_full_depth)
        copy_files = bool_value(source_config, "copy", default_copy)
        canonical_mode = str(
            source_config.get("canonical_mode", default_canonical_mode)
        ).lower()
        if canonical_mode not in {"copy", "symlink"}:
            raise SystemExit(
                "error: canonical_mode must be either 'copy' or 'symlink'"
            )
        if canonical_mode == "copy" and not copy_files:
            raise SystemExit(
                "error: canonical_mode = 'copy' requires copy = true; "
                "use canonical_mode = 'symlink' for canonical symlinks"
            )
        source_installer_agent = str(source_config.get("installer_agent", installer_agent))
        source_installer_target = DEFAULT_AGENT_TARGETS.get(source_installer_agent)
        if canonical_mode == "copy" and not source_installer_target:
            raise SystemExit(
                "error: copy mode requires installer_agent to be one of: "
                f"{', '.join(sorted(DEFAULT_AGENT_TARGETS))}"
            )
        include = normalize_list(source_config.get("include"), ["*"])
        exclude = normalize_list(source_config.get("exclude"), [])
        exclude_paths = normalize_list(source_config.get("exclude_paths"), [])
        agents = normalize_list(source_config.get("agents"), default_agents)
        extra_args = normalize_list(source_config.get("extra_args"), [])
        link_source = str(source_config.get("link_source", source))
        link_source_root = expand_user(link_source)
        discovery_source = str(
            source_config.get(
                "discovery_source",
                link_source_root if canonical_mode == "symlink" else install_source,
            )
        )

        if canonical_mode == "symlink" and not os.path.isdir(link_source_root):
            raise SystemExit(
                "error: canonical_mode = 'symlink' requires a local source "
                f"directory or link_source for source {source!r}"
            )

        discovered = discover_source_skills(discovery_source, full_depth)
        skills = selected_skills(discovered, include, exclude, exclude_paths)
        for skill_name in skills:
            validate_skill_name(
                skill_name,
                os.path.join(discovery_source, discovered[skill_name], "SKILL.md"),
            )
        if not skills:
            warn(f"source {source!r} selected no skills")
            continue

        target_specs = []
        for agent in agents:
            target_dir = agent_targets.get(agent)
            if not target_dir:
                warn(f"agent {agent!r} has no configured target path; skipping fanout")
                continue
            target_specs.append(f"{agent}={expand_user(target_dir)}")

        for skill_name in skills:
            relative_dir = discovered[skill_name]
            source_skill_dir = ""
            if canonical_mode == "symlink":
                source_skill_dir = expand_user(os.path.join(link_source_root, relative_dir))
            rows.append(
                [
                    install_source,
                    skill_name,
                    ",".join(agents),
                    ";".join(target_specs),
                    "true" if full_depth else "false",
                    "true" if copy_files else "false",
                    ",".join(extra_args),
                    canonical_dir,
                    source_installer_agent,
                    source_installer_target or "",
                    canonical_mode,
                    source_skill_dir,
                ]
            )

    return rows


if not os.path.exists(CONFIG_FILE):
    raise SystemExit(f"error: config file not found: {CONFIG_FILE}")

config = load_config(CONFIG_FILE)
for row in make_plan(config):
    print("\x1f".join(row))
PY
}

run_npx_add_skill() {
  local home_dir="$1"
  local skill_source="$2"
  local skill_name="$3"
  local full_depth="$4"
  local copy_files="$5"
  local extra_args_csv="$6"
  local installer_agent="$7"
  local cmd
  local extra_args
  local extra_arg

  cmd=(npx --yes skills@latest add "${skill_source}" --global --agent "${installer_agent}" --skill "${skill_name}" -y)

  if [[ "${copy_files}" = true ]]; then
    cmd+=(--copy)
  fi
  if [[ "${full_depth}" = true ]]; then
    cmd+=(--full-depth)
  fi
  if [[ -n "${extra_args_csv}" ]]; then
    IFS=',' read -r -a extra_args <<< "${extra_args_csv}"
    for extra_arg in "${extra_args[@]}"; do
      [[ -n "${extra_arg}" ]] && cmd+=("${extra_arg}")
    done
  fi

  if [[ -n "${home_dir}" ]]; then
    run_cmd_with_home "${home_dir}" "${cmd[@]}"
  else
    run_cmd "${cmd[@]}"
  fi
}

install_canonical_copy() {
  local skill_source="$1"
  local skill_name="$2"
  local full_depth="$3"
  local extra_args_csv="$4"
  local installer_agent="$5"
  local installer_target_template="$6"
  local canonical_dir="$7"
  local temp_home
  local temp_canonical_skill_dir
  local temp_target_base
  local temp_agent_skill_dir
  local staged_skill_dir
  local canonical_skill_dir
  local replacement_parent
  local replacement_skill_dir
  local old_backup_dir
  local install_status
  local copy_status=0
  local old_was_moved=false
  local errexit_was_set=false

  temp_home="$(mktemp -d)"

  if [[ $- == *e* ]]; then
    errexit_was_set=true
  fi

  set +e
  run_npx_add_skill "${temp_home}" "${skill_source}" "${skill_name}" "${full_depth}" true "${extra_args_csv}" "${installer_agent}"
  install_status=$?

  if [[ "${install_status}" -ne 0 ]]; then
    rm -rf "${temp_home}"
    restore_errexit "${errexit_was_set}"
    return "${install_status}"
  fi

  temp_canonical_skill_dir="${temp_home}/.agents/skills/${skill_name}"
  temp_target_base="$(expand_path_for_home "${installer_target_template}" "${temp_home}")"
  temp_agent_skill_dir="${temp_target_base}/${skill_name}"
  canonical_skill_dir="${canonical_dir}/${skill_name}"
  staged_skill_dir="${temp_canonical_skill_dir}"
  if [[ "${DRY_RUN}" != true ]] && [[ ! -d "${staged_skill_dir}" ]] && [[ -d "${temp_agent_skill_dir}" ]]; then
    staged_skill_dir="${temp_agent_skill_dir}"
  fi

  if [[ "${DRY_RUN}" != true ]] && [[ ! -d "${staged_skill_dir}" ]]; then
    warn "installer did not create expected skill copy: ${temp_canonical_skill_dir} or ${temp_agent_skill_dir}"
    rm -rf "${temp_home}"
    restore_errexit "${errexit_was_set}"
    return 1
  fi

  run_cmd mkdir -p "${canonical_dir}"
  copy_status=$?
  if [[ "${copy_status}" -eq 0 ]]; then
    if [[ "${DRY_RUN}" = true ]]; then
      replacement_parent="${canonical_dir}/.${skill_name}.tmp.DRYRUN"
    else
      replacement_parent="$(mktemp -d "${canonical_dir}/.${skill_name}.tmp.XXXXXX")"
      copy_status=$?
    fi
  fi
  if [[ "${copy_status}" -eq 0 ]]; then
    replacement_skill_dir="${replacement_parent}/${skill_name}"
    run_cmd cp -R "${staged_skill_dir}" "${replacement_skill_dir}"
    copy_status=$?
  fi
  if [[ "${copy_status}" -eq 0 ]] && { [[ -e "${canonical_skill_dir}" ]] || [[ -L "${canonical_skill_dir}" ]]; }; then
    old_backup_dir="${canonical_skill_dir}.backup.${BACKUP_STAMP}.$$"
    run_cmd mv "${canonical_skill_dir}" "${old_backup_dir}"
    copy_status=$?
    [[ "${copy_status}" -eq 0 ]] && old_was_moved=true
  fi
  if [[ "${copy_status}" -eq 0 ]]; then
    run_cmd mv "${replacement_skill_dir}" "${canonical_skill_dir}"
    copy_status=$?
  fi
  if [[ "${copy_status}" -ne 0 ]] && [[ "${old_was_moved}" = true ]]; then
    run_cmd mv "${old_backup_dir}" "${canonical_skill_dir}"
  fi
  if [[ "${DRY_RUN}" != true ]] && [[ -n "${replacement_parent:-}" ]]; then
    rm -rf "${replacement_parent}"
  fi
  if [[ "${copy_status}" -eq 0 ]] && [[ "${old_was_moved}" = true ]]; then
    run_cmd rm -rf "${old_backup_dir}"
  fi

  rm -rf "${temp_home}"
  restore_errexit "${errexit_was_set}"
  return "${copy_status}"
}

show_plan() {
  local plan_file="$1"
  local skill_source
  local skill_name
  local agents_csv
  local target_specs
  local full_depth
  local copy_files
  local extra_args_csv
  local canonical_dir
  local installer_agent
  local installer_target_template
  local canonical_mode
  local source_skill_dir

  while IFS=$'\037' read -r skill_source skill_name agents_csv target_specs full_depth copy_files extra_args_csv canonical_dir installer_agent installer_target_template canonical_mode source_skill_dir; do
    printf '%s\t%s\tagents=%s\tcanonical=%s\tmode=%s\tinstaller_agent=%s\tcopy=%s\tfull_depth=%s\ttargets=%s\textra_args=%s\tsource_skill_dir=%s\n' \
      "${skill_source}" \
      "${skill_name}" \
      "${agents_csv}" \
      "${canonical_dir}" \
      "${canonical_mode}" \
      "${installer_agent}" \
      "${copy_files}" \
      "${full_depth}" \
      "${target_specs}" \
      "${extra_args_csv}" \
      "${source_skill_dir}"
  done < "${plan_file}"
}

process_plan() {
  local plan_file="$1"
  local skill_source
  local skill_name
  local agents_csv
  local target_specs
  local full_depth
  local copy_files
  local extra_args_csv
  local canonical_dir
  local installer_agent
  local installer_target_template
  local canonical_mode
  local source_skill_dir
  local canonical_skill_dir
  local target_spec
  local target_agent
  local target_dir
  local failures=0
  local target_list
  local install_status
  local link_status

  while IFS=$'\037' read -r skill_source skill_name agents_csv target_specs full_depth copy_files extra_args_csv canonical_dir installer_agent installer_target_template canonical_mode source_skill_dir; do
    [[ -n "${skill_source}" ]] || continue

    log "skill: ${skill_name} (${skill_source}, ${canonical_mode})"

    if [[ "${NO_INSTALL}" != true ]]; then
      set +e
      if [[ "${canonical_mode}" = symlink ]]; then
        ensure_canonical_symlink "${source_skill_dir}" "${canonical_dir}" "${skill_name}"
        install_status=$?
      else
        if [[ "${copy_files}" != true ]]; then
          warn "copy mode requires copy=true for ${skill_name}"
          install_status=1
        else
          install_canonical_copy "${skill_source}" "${skill_name}" "${full_depth}" "${extra_args_csv}" "${installer_agent}" "${installer_target_template}" "${canonical_dir}"
          install_status=$?
        fi
      fi
      set -e
      if [[ "${install_status}" -ne 0 ]]; then
        failures=$((failures + 1))
      fi
    fi

    canonical_skill_dir="${canonical_dir}/${skill_name}"

    if [[ "${NO_LINK}" = true ]]; then
      continue
    fi

    if [[ -z "${target_specs}" ]]; then
      warn "no target agents configured for ${skill_name}"
      failures=$((failures + 1))
      continue
    fi

    IFS=';' read -r -a target_list <<< "${target_specs}"
    for target_spec in "${target_list[@]}"; do
      target_agent="${target_spec%%=*}"
      target_dir="${target_spec#*=}"
      log "fanout: ${skill_name} -> ${target_agent}:${target_dir}"
      set +e
      ensure_skill_link "${canonical_skill_dir}" "${target_dir}" "${skill_name}"
      link_status=$?
      set -e
      if [[ "${link_status}" -ne 0 ]]; then
        failures=$((failures + 1))
      fi
    done
  done < "${plan_file}"

  if [[ "${failures}" -gt 0 ]]; then
    die "${failures} operation(s) failed"
  fi
}

main() {
  parse_args "$@"

  need_cmd python3
  need_cmd npx

  PLAN_FILE="$(mktemp)"
  trap 'rm -f "${PLAN_FILE}"' EXIT

  generate_plan "${CONFIG_FILE}" > "${PLAN_FILE}"

  if [[ "${LIST_PLAN}" = true ]]; then
    show_plan "${PLAN_FILE}"
    exit 0
  fi

  process_plan "${PLAN_FILE}"
}

main "$@"
