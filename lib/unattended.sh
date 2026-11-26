#!/usr/bin/env bash
# shellcheck shell=bash
# Unattended runs: preset answers (command-line flags or an answers file) and resumable steps.
# Requires lib/common.sh to be sourced first.

[[ -n "${_FSS_UNATTENDED_LOADED:-}" ]] && return 0
_FSS_UNATTENDED_LOADED=1

# --------------------------------------------------------------------------
# Preset answers
# ANSWER[KEY] holds a value given on the command line or in an answers file. Scripts call
# `preset KEY "label"` before asking a question; when it succeeds the question is skipped.
# --------------------------------------------------------------------------
declare -gA ANSWER=()

# Secrets may be given in an answers file, but go to these globals (read by ask_secret).
FSS_SECRET_KEYS=(DB_ROOT_PASSWORD ADMIN_PASSWORD FRAPPE_USER_PASSWORD)

_trim() { local s=$1; s=${s#"${s%%[![:space:]]*}"}; s=${s%"${s##*[![:space:]]}"}; printf '%s' "$s"; }

# load_answers_file <file> <allowed-key...>
# Reads KEY=value lines (no shell evaluation). Values already set (flags, environment) win.
load_answers_file() {
	local file=$1; shift
	local -A allowed=()
	local k line key val n=0
	for k in "$@" "${FSS_SECRET_KEYS[@]}"; do allowed[$k]=1; done
	[[ -f "$file" && -r "$file" ]] || die "Cannot read answers file: $file"
	while IFS= read -r line || [[ -n "$line" ]]; do
		n=$((n + 1))
		line=$(_trim "${line%$'\r'}")
		[[ -z "$line" || "$line" == \#* ]] && continue
		if [[ ! "$line" =~ ^(export[[:space:]]+)?([A-Za-z_][A-Za-z0-9_]*)[[:space:]]*=(.*)$ ]]; then
			die "$file line $n: expected KEY=value, got: $line"
		fi
		key=${BASH_REMATCH[2]^^}
		val=$(_trim "${BASH_REMATCH[3]}")
		if [[ "$val" =~ ^\"(.*)\"$ || "$val" =~ ^\'(.*)\'$ ]]; then val=${BASH_REMATCH[1]}; fi
		[[ -n "${allowed[$key]:-}" ]] || die "$file line $n: unknown setting '$key'. Known settings: $*"
		if [[ " ${FSS_SECRET_KEYS[*]} " == *" $key "* ]]; then
			[[ -n "${!key:-}" ]] || printf -v "$key" '%s' "$val"
			mask_secret "$val"
			continue
		fi
		[[ -n "${ANSWER[$key]+set}" ]] || ANSWER[$key]=$val
	done <"$file"
	if [[ "$(stat -c %a "$file" 2>/dev/null)" =~ [0-7][1-7]$ ]] && grep -qE '^[[:space:]]*(export[[:space:]]+)?[A-Za-z_]*PASSWORD[[:space:]]*=' "$file"; then
		warn "$file contains passwords and is readable by other users; consider: chmod 600 $file"
	fi
}

# set_answer <KEY> <value>: from a command-line flag (overrides an answers file).
set_answer() { ANSWER[$1]=$2; }
has_answer() { [[ -n "${ANSWER[$1]+set}" ]]; }

# preset <VAR> <label>: if an answer for VAR was given, assign it, show it, and return 0.
preset() {
	local __var=$1 __label=$2
	has_answer "$__var" || return 1
	printf -v "$__var" '%s' "${ANSWER[$__var]}"
	printf '%s?%s %s %s%s%s\n' "${C_CYAN}" "${C_RESET}" "$__label" "${C_DIM}" "${ANSWER[$__var]:-(none)}" "${C_RESET}" >&2
	return 0
}

# preset_bool <VAR> <label>: like preset, for yes/no answers; returns 0 for yes, 1 for no, 2 if unset.
preset_bool() {
	local __var=$1 __label=$2
	has_answer "$__var" || return 2
	case "${ANSWER[$__var],,}" in
		1|y|yes|true|on) printf '%s?%s %s %syes%s\n' "${C_CYAN}" "${C_RESET}" "$__label" "${C_DIM}" "${C_RESET}" >&2; return 0 ;;
		0|n|no|false|off|'') printf '%s?%s %s %sno%s\n' "${C_CYAN}" "${C_RESET}" "$__label" "${C_DIM}" "${C_RESET}" >&2; return 1 ;;
		*) die "$__var must be yes or no, got '${ANSWER[$__var]}'." ;;
	esac
}

# ask_bool_preset <VAR> <prompt> <default y|n>: preset answer if given, else ask. 0 = yes.
ask_bool_preset() {
	local rc=0
	preset_bool "$1" "$2" || rc=$?
	((rc == 2)) || return "$rc"
	ask_yes_no "$2" "$3"
}

# expect_one_of <VAR> <allowed...>: fail clearly when a preset answer is not a known choice.
expect_one_of() {
	local __var=$1 v; shift
	for v in "$@"; do [[ "${!__var}" == "$v" ]] && return 0; done
	die "Invalid $__var '${!__var}'. Use one of: $*"
}

# split_list <string>: comma/space separated list -> one item per line.
split_list() { tr -s ', ' '\n' <<<"$1" | sed '/^$/d'; }

# --------------------------------------------------------------------------
# Resumable steps
# A run records each finished step in a state file; a later run with the same state skips them.
# --------------------------------------------------------------------------
FSS_STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/frappe-setup-scripts"
FSS_STATE_FILE=''

# state_use <name>: select (and create) the state file for one job, e.g. install-frappe-bench.
state_use() {
	mkdir -p "$FSS_STATE_DIR" && chmod 700 "$FSS_STATE_DIR"
	FSS_STATE_FILE="$FSS_STATE_DIR/$1.steps"
	touch "$FSS_STATE_FILE"
}
state_answers_file() { printf '%s/%s.conf' "$FSS_STATE_DIR" "$1"; }

step_is_done() { [[ -n "$FSS_STATE_FILE" ]] && grep -qxF "done $1" "$FSS_STATE_FILE" 2>/dev/null; }

mark_step_done() {
	[[ -n "$FSS_STATE_FILE" ]] || return 0
	step_is_done "$1" || printf 'done %s\n' "$1" >>"$FSS_STATE_FILE"
	# Test hook: simulate a crash right after a step, to exercise resuming in CI.
	if [[ -n "${FSS_FAIL_AFTER_STEP:-}" && "$FSS_FAIL_AFTER_STEP" == "$1" ]]; then
		die "Stopping after step '$1' (FSS_FAIL_AFTER_STEP is set)."
	fi
	return 0
}

# state_set <key> <value> / state_get <key>: small facts a resumed run needs (e.g. real app names).
state_set() {
	[[ -n "$FSS_STATE_FILE" ]] || return 0
	sed -i "/^set $1 /d" "$FSS_STATE_FILE"
	printf 'set %s %s\n' "$1" "$2" >>"$FSS_STATE_FILE"
}
state_get() { [[ -n "$FSS_STATE_FILE" ]] && sed -n "s/^set $1 //p" "$FSS_STATE_FILE" 2>/dev/null | tail -1; }

last_done_step() { [[ -f "$1" ]] && sed -n 's/^done //p' "$1" | tail -1; }

# step <name> <description> <command...>: run a step unless an earlier run finished it.
step() {
	local name=$1 desc=$2; shift 2
	if step_is_done "$name"; then
		info "Skipping: $desc (done in an earlier run)"
		return 0
	fi
	"$@"
	mark_step_done "$name"
}

# save_answers <file> <KEY=value...>: write an answers file that load_answers_file can read back.
save_answers() {
	local file=$1 kv; shift
	(
		umask 077
		{
			echo "# Answers saved by Frappe-Setup-Scripts on $(date '+%F %T'); passwords are not stored."
			for kv in "$@"; do printf '%s\n' "$kv"; done
		} >"$file"
	)
}
