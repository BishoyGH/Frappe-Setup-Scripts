#!/usr/bin/env bash
# shellcheck shell=bash
# Shared helpers: logging, interactive prompts, OS detection, services, runtime env.
# Sourced by the top-level scripts; not meant to be executed directly.

[[ -n "${_FSS_COMMON_LOADED:-}" ]] && return 0
_FSS_COMMON_LOADED=1

export LANG="${LANG:-C.UTF-8}"
export LC_ALL="${LC_ALL:-C.UTF-8}"

# --------------------------------------------------------------------------
# Output
# --------------------------------------------------------------------------
if [[ -t 2 ]] && [[ -z "${NO_COLOR:-}" ]]; then
	C_RESET=$'\e[0m' C_BOLD=$'\e[1m' C_DIM=$'\e[2m'
	C_RED=$'\e[31m' C_GREEN=$'\e[32m' C_YELLOW=$'\e[33m' C_BLUE=$'\e[34m' C_CYAN=$'\e[36m'
else
	C_RESET='' C_BOLD='' C_DIM='' C_RED='' C_GREEN='' C_YELLOW='' C_BLUE='' C_CYAN=''
fi

info()    { printf '%s==>%s %s\n' "${C_BLUE}${C_BOLD}" "${C_RESET}" "$*" >&2; }
success() { printf '%s✔%s  %s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}" "$*" >&2; }
warn()    { printf '%s!%s  %s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}" "$*" >&2; _ui_note "! $*"; }
error()   { printf '%s✖%s  %s\n' "${C_RED}${C_BOLD}" "${C_RESET}" "$*" >&2; }
die()     { error "$*"; exit 1; }
header()  {
	local line
	_UI_SECTION=$*
	# Inside a numbered step (see phase in ui.sh) headers become sub-headings.
	if [[ "${_FSS_IN_PHASE:-0}" == 1 ]]; then
		printf '%s── %s%s\n' "${C_CYAN}" "$*" "${C_RESET}" >&2
		return 0
	fi
	line=$(printf '%*s' 64 '' | tr ' ' '-')
	printf '\n%s%s\n %s\n%s%s\n' "${C_CYAN}${C_BOLD}" "$line" "$*" "$line" "${C_RESET}" >&2
}

# Secrets registered with mask_secret are replaced by **** wherever run() prints a command.
_FSS_SECRETS=()
mask_secret() { [[ -n "${1:-}" ]] && _FSS_SECRETS+=("$1"); return 0; }
masked() {
	local s=$* x
	for x in "${_FSS_SECRETS[@]}"; do s=${s//"$x"/****}; done
	printf '%s' "$s"
}

# run: print the command (secrets masked), then execute it. Fails the script on error (set -e).
run() {
	if ui_quiet_active; then _ui_run_quiet "$@"; return; fi
	printf '%s$ %s%s\n' "${C_DIM}" "$(masked "$*")" "${C_RESET}" >&2
	"$@"
}

# Exit hooks (several modules need cleanup; a single EXIT trap runs them all)
_FSS_EXIT_HOOKS=()
_fss_run_exit_hooks() {
	local h
	for h in "${_FSS_EXIT_HOOKS[@]}"; do eval "$h" || true; done
	_fss_flush_log
}
on_exit() { _FSS_EXIT_HOOKS+=("$*"); trap _fss_run_exit_hooks EXIT; }

# Standard strict mode + error report for the entry scripts.
_fss_on_err() {
	# A function passing on a failure (return "$rc") was already reported where it failed.
	[[ "$3" == return* ]] && return 0
	error "Command failed (exit $1) at line $2: $3"
	[[ -n "${_FSS_CURRENT_PHASE:-}" ]] && error "During $_FSS_CURRENT_PHASE"
	[[ -n "${FSS_LOG_FILE:-}" ]] && error "Full log: $FSS_LOG_FILE"
	return 0
}
strict_mode() {
	set -Eeo pipefail
	trap '_fss_on_err "$?" "$LINENO" "$BASH_COMMAND"' ERR
}

# --------------------------------------------------------------------------
# Interactive prompts
# All prompts read from /dev/tty so the scripts also work when piped.
# Set ASSUME_DEFAULTS=1 to accept every default without asking (automation/CI).
# --------------------------------------------------------------------------
_tty_read() {
	# _tty_read <varname> [read options...]; exits the script when input is closed (EOF).
	local __var=$1; shift
	if [[ -r /dev/tty ]] && { : </dev/tty; } 2>/dev/null; then
		IFS= read -r "$@" "${__var?}" </dev/tty && return 0
	else
		IFS= read -r "$@" "${__var?}" && return 0
	fi
	# read fails at EOF; a final line without a newline still counts as an answer.
	[[ -n "${!__var}" ]] && return 0
	printf '\n' >&2
	die "No more input (stdin was closed); stopping."
}

# ask <varname> <prompt> [default]
ask() {
	local __var=$1 __prompt=$2 __default=${3:-} __reply=''
	if [[ "${ASSUME_DEFAULTS:-0}" == 1 ]]; then
		printf -v "$__var" '%s' "$__default"
		printf '%s?%s %s %s[%s]%s\n' "${C_CYAN}" "${C_RESET}" "$__prompt" "${C_DIM}" "$__default" "${C_RESET}" >&2
		return 0
	fi
	if tui_active; then _tui_ask "$__var" "$__prompt" "$__default" 1; return 0; fi
	while true; do
		if [[ -n "$__default" ]]; then
			printf '%s?%s %s %s[%s]%s: ' "${C_CYAN}${C_BOLD}" "${C_RESET}" "$__prompt" "${C_DIM}" "$__default" "${C_RESET}" >&2
		else
			printf '%s?%s %s: ' "${C_CYAN}${C_BOLD}" "${C_RESET}" "$__prompt" >&2
		fi
		_tty_read __reply
		__reply=${__reply:-$__default}
		[[ -n "$__reply" ]] && break
		warn "A value is required."
	done
	printf -v "$__var" '%s' "$__reply"
}

# ask_optional <varname> <prompt> [default] -- like ask, but accepts an empty answer.
ask_optional() {
	local __var=$1 __prompt=$2 __default=${3:-} __reply=''
	if [[ "${ASSUME_DEFAULTS:-0}" == 1 ]]; then
		printf -v "$__var" '%s' "$__default"; return 0
	fi
	if tui_active; then _tui_ask "$__var" "$__prompt" "$__default" 0; return 0; fi
	printf '%s?%s %s %s[%s]%s: ' "${C_CYAN}${C_BOLD}" "${C_RESET}" "$__prompt" "${C_DIM}" "${__default:-none}" "${C_RESET}" >&2
	_tty_read __reply
	printf -v "$__var" '%s' "${__reply:-$__default}"
}

# ask_secret <varname> <prompt> [confirm:yes|no] [env-var-with-default]
ask_secret() {
	local __var=$1 __prompt=$2 __confirm=${3:-yes} __envvar=${4:-} __a='' __b=''
	if [[ -n "$__envvar" && -n "${!__envvar:-}" ]]; then
		printf -v "$__var" '%s' "${!__envvar}"
		mask_secret "${!__envvar}"
		return 0
	fi
	if [[ "${ASSUME_DEFAULTS:-0}" == 1 ]]; then
		die "ASSUME_DEFAULTS is set but no value for '${__prompt}' was provided${__envvar:+ (set $__envvar)}."
	fi
	if tui_active; then _tui_secret "$__var" "$__prompt" "$__confirm"; mask_secret "${!__var}"; return 0; fi
	while true; do
		printf '%s?%s %s: ' "${C_CYAN}${C_BOLD}" "${C_RESET}" "$__prompt" >&2
		_tty_read __a -s
		printf '\n' >&2
		if [[ -z "$__a" ]]; then warn "A value is required."; continue; fi
		if [[ "$__confirm" == yes ]]; then
			printf '%s?%s Confirm %s: ' "${C_CYAN}${C_BOLD}" "${C_RESET}" "${__prompt,}" >&2
			_tty_read __b -s
			printf '\n' >&2
			if [[ "$__a" != "$__b" ]]; then warn "Values do not match, try again."; continue; fi
		fi
		break
	done
	mask_secret "$__a"
	printf -v "$__var" '%s' "$__a"
}

# ask_yes_no <prompt> [default:y|n]  -> returns 0 for yes, 1 for no
ask_yes_no() {
	local __prompt=$1 __default=${2:-y} __reply='' __hint
	[[ "$__default" == y ]] && __hint='Y/n' || __hint='y/N'
	if [[ "${ASSUME_DEFAULTS:-0}" == 1 ]]; then
		printf '%s?%s %s [%s] %s\n' "${C_CYAN}" "${C_RESET}" "$__prompt" "$__hint" "$__default" >&2
		[[ "$__default" == y ]]; return
	fi
	if tui_active; then _tui_yes_no "$__prompt" "$__default"; return; fi
	while true; do
		printf '%s?%s %s [%s]: ' "${C_CYAN}${C_BOLD}" "${C_RESET}" "$__prompt" "$__hint" >&2
		_tty_read __reply
		__reply=${__reply:-$__default}
		case "${__reply,,}" in
			y|yes) return 0 ;;
			n|no)  return 1 ;;
			*) warn "Please answer y or n." ;;
		esac
	done
}

# choose <varname> <prompt> <default-index (1-based)> <option>...
# Options may be "value|description"; the value is stored in <varname>.
choose() {
	local __var=$1 __prompt=$2 __default=$3; shift 3
	local -a __opts=("$@")
	local __i __reply='' __val __desc
	if tui_active; then _tui_choose "$__var" "$__prompt" "$__default" "${__opts[@]}"; return 0; fi
	printf '%s?%s %s\n' "${C_CYAN}${C_BOLD}" "${C_RESET}" "$__prompt" >&2
	for __i in "${!__opts[@]}"; do
		__val=${__opts[$__i]%%|*}
		__desc=''
		[[ "${__opts[$__i]}" == *"|"* ]] && __desc=${__opts[$__i]#*|}
		printf '   %s%2d)%s %-22s %s%s%s\n' "${C_BOLD}" $((__i + 1)) "${C_RESET}" "$__val" "${C_DIM}" "$__desc" "${C_RESET}" >&2
	done
	if [[ "${ASSUME_DEFAULTS:-0}" == 1 ]]; then
		__reply=$__default
	else
		while true; do
			printf '   Select [%s]: ' "$__default" >&2
			_tty_read __reply
			__reply=${__reply:-$__default}
			if [[ "$__reply" =~ ^[0-9]+$ ]] && ((__reply >= 1 && __reply <= ${#__opts[@]})); then
				break
			fi
			warn "Enter a number between 1 and ${#__opts[@]}."
		done
	fi
	printf -v "$__var" '%s' "${__opts[$((__reply - 1))]%%|*}"
}

# choose_multi <array-varname> <prompt> <default-indexes e.g. "1 3" or ""> <option>...
# User enters numbers separated by spaces/commas, "a" for all, "n" for none.
choose_multi() {
	local __var=$1 __prompt=$2 __default=$3; shift 3
	local -a __opts=("$@") __picked=()
	local __i __reply='' __val __desc __ok __n
	if tui_active; then _tui_choose_multi "$__var" "$__prompt" "$__default" "${__opts[@]}"; return 0; fi
	printf '%s?%s %s\n' "${C_CYAN}${C_BOLD}" "${C_RESET}" "$__prompt" >&2
	for __i in "${!__opts[@]}"; do
		__val=${__opts[$__i]%%|*}
		__desc=''
		[[ "${__opts[$__i]}" == *"|"* ]] && __desc=${__opts[$__i]#*|}
		printf '   %s%2d)%s %-22s %s%s%s\n' "${C_BOLD}" $((__i + 1)) "${C_RESET}" "$__val" "${C_DIM}" "$__desc" "${C_RESET}" >&2
	done
	while true; do
		if [[ "${ASSUME_DEFAULTS:-0}" == 1 ]]; then
			__reply=$__default
		else
			printf '   Numbers separated by spaces, "a" = all, "n" = none [%s]: ' "${__default:-n}" >&2
			_tty_read __reply
			__reply=${__reply:-${__default:-n}}
		fi
		__reply=${__reply//,/ }
		__picked=()
		__ok=1
		case "${__reply,,}" in
			a|all) for __i in "${!__opts[@]}"; do __picked+=("${__opts[$__i]%%|*}"); done ;;
			n|none|'') ;;
			*)
				for __n in $__reply; do
					if [[ "$__n" =~ ^[0-9]+$ ]] && ((__n >= 1 && __n <= ${#__opts[@]})); then
						__val=${__opts[$((__n - 1))]%%|*}
						[[ " ${__picked[*]} " == *" $__val "* ]] || __picked+=("$__val")
					else
						warn "Invalid choice: $__n"; __ok=0
					fi
				done
				;;
		esac
		((__ok)) && break
		[[ "${ASSUME_DEFAULTS:-0}" == 1 ]] && die "Invalid default selection: $__default"
	done
	eval "$__var=(\"\${__picked[@]}\")"
}

# pause stays a plain prompt in dialog mode too, so the output above it remains readable.
pause() {
	[[ "${ASSUME_DEFAULTS:-0}" == 1 ]] && return 0
	local _r
	printf '%sPress Enter to continue...%s' "${C_DIM}" "${C_RESET}" >&2
	_tty_read _r || true
}

# --------------------------------------------------------------------------
# Privileges
# --------------------------------------------------------------------------
is_root() { [[ "$(id -u)" -eq 0 ]]; }

# as_root <cmd...>: run a command with root privileges.
as_root() {
	if is_root; then "$@"; else sudo "$@"; fi
}

ensure_sudo() {
	is_root && return 0
	command -v sudo >/dev/null 2>&1 || die "sudo is not installed. Run this script as root once so it can install sudo and create a user."
	info "Some steps need administrator rights; sudo may ask for your password."
	# "sudo true" rather than "sudo -v": -v asks for a password even with NOPASSWD rules
	# when another rule (e.g. %sudo) matches, which breaks cloud images without passwords.
	sudo true || die "Could not obtain sudo privileges."
	# Keep the sudo timestamp fresh while the script runs.
	( while kill -0 "$$" 2>/dev/null; do sudo -n true 2>/dev/null; sleep 50; done ) &
	on_exit "kill $! 2>/dev/null"
}

# --------------------------------------------------------------------------
# OS detection
# --------------------------------------------------------------------------
# shellcheck disable=SC2034  # used by the other modules
OS_ID='' OS_LIKE='' OS_VERSION='' OS_CODENAME='' OS_FAMILY='' OS_PRETTY='' IS_WSL=0 ARCH=''

detect_os() {
	[[ -r /etc/os-release ]] || die "Cannot read /etc/os-release; unsupported system."
	# shellcheck disable=SC1091
	. /etc/os-release
	OS_ID=${ID:-unknown}
	OS_LIKE=${ID_LIKE:-}
	OS_VERSION=${VERSION_ID:-rolling}
	# shellcheck disable=SC2034
	OS_CODENAME=${VERSION_CODENAME:-${UBUNTU_CODENAME:-}}
	OS_PRETTY=${PRETTY_NAME:-$OS_ID}
	case "$OS_ID" in
		ubuntu|debian|linuxmint|pop|elementary|zorin|kali|raspbian) OS_FAMILY=debian ;;
		arch|manjaro|endeavouros|garuda|artix|cachyos) OS_FAMILY=arch ;;
		*)
			if [[ " $OS_LIKE " == *" debian "* || " $OS_LIKE " == *" ubuntu "* ]]; then OS_FAMILY=debian
			elif [[ " $OS_LIKE " == *" arch "* ]]; then OS_FAMILY=arch
			else OS_FAMILY=unsupported
			fi
			;;
	esac
	if grep -qiE 'microsoft|wsl' /proc/sys/kernel/osrelease 2>/dev/null || [[ -n "${WSL_DISTRO_NAME:-}" ]]; then
		IS_WSL=1
	fi
	case "$(uname -m)" in
		x86_64|amd64) ARCH=amd64 ;;
		aarch64|arm64) ARCH=arm64 ;;
		*) ARCH=$(uname -m) ;;
	esac
}

require_supported_os() {
	detect_os
	[[ "$OS_FAMILY" == unsupported ]] && die "Unsupported distribution: $OS_PRETTY. Supported: Ubuntu, Debian, Arch Linux (also under WSL)."
	if [[ "$ARCH" != amd64 && "$ARCH" != arm64 ]]; then
		die "Unsupported CPU architecture: $ARCH (need x86_64 or aarch64)."
	fi
	if [[ "$OS_ID" == ubuntu ]] && [[ "${OS_VERSION%%.*}" -lt 22 ]]; then
		warn "Ubuntu $OS_VERSION is older than 22.04 and is not tested; continuing anyway."
	fi
	if [[ "$OS_ID" == debian ]] && [[ "$OS_VERSION" =~ ^[0-9]+$ ]] && ((OS_VERSION < 11)); then
		warn "Debian $OS_VERSION is older than 11 and is not tested; continuing anyway."
	fi
	info "Detected ${C_BOLD}${OS_PRETTY}${C_RESET} (${OS_FAMILY} family, ${ARCH}$( ((IS_WSL)) && printf ', WSL'))"
}

# --------------------------------------------------------------------------
# Services (systemd when available, SysV/manual fallback for WSL without systemd)
# --------------------------------------------------------------------------
has_systemd() {
	[[ -d /run/systemd/system ]] && [[ "$(cat /proc/1/comm 2>/dev/null)" == systemd ]]
}

service_is_active() {
	local name=$1
	if has_systemd; then systemctl is-active --quiet "$name"
	elif command -v service >/dev/null 2>&1; then as_root service "$name" status >/dev/null 2>&1
	else pgrep -x "$name" >/dev/null 2>&1
	fi
}

# service_enable_start <name> [fallback command...]
service_enable_start() {
	local name=$1; shift
	if has_systemd; then
		run as_root systemctl enable --now "$name"
	elif command -v service >/dev/null 2>&1 && [[ -e "/etc/init.d/$name" ]]; then
		run as_root service "$name" start || true
	elif (($#)); then
		# A daemon started here must not keep the script's output pipe (the log writer) open,
		# or the script never finishes; give it the log file (or nothing) instead.
		run as_root "$@" </dev/null >>"${FSS_LOG_FILE:-/dev/null}" 2>&1
	else
		warn "Cannot start '$name' automatically (no systemd). Start it manually."
		return 1
	fi
}

service_reload() {
	local name=$1
	if has_systemd; then run as_root systemctl reload-or-restart "$name"
	elif command -v service >/dev/null 2>&1 && [[ -e "/etc/init.d/$name" ]]; then run as_root service "$name" reload || run as_root service "$name" restart
	else return 1
	fi
}

# --------------------------------------------------------------------------
# Frappe version knowledge
# --------------------------------------------------------------------------
# frappe_major_from_ref <branch-or-tag> -> prints a major number, "develop", or ""
frappe_major_from_ref() {
	local ref=$1
	case "$ref" in
		develop|main|master) echo develop ;;
		version-[0-9]*) echo "${ref#version-}" | grep -oE '^[0-9]+' || true ;;
		v[0-9]*) echo "${ref#v}" | grep -oE '^[0-9]+' || true ;;
		*) echo '' ;;
	esac
}

# Recommended Python / Node versions per Frappe major (from Frappe's CI matrix).
python_for_major() {
	case "$1" in
		13) echo 3.9 ;;
		14) echo 3.10 ;;
		15) echo 3.11 ;;
		16|develop|*) echo 3.14 ;;
	esac
}
node_for_major() {
	case "$1" in
		13) echo 14 ;;
		14) echo 16 ;;
		15) echo 18 ;;
		16|develop|*) echo 24 ;;
	esac
}

# --------------------------------------------------------------------------
# Runtime environment for bench (uv tools, nvm)
# --------------------------------------------------------------------------
export NVM_DIR="${NVM_DIR:-$HOME/.nvm}"

load_runtime_env() {
	case ":$PATH:" in *":$HOME/.local/bin:"*) ;; *) export PATH="$HOME/.local/bin:$PATH" ;; esac
	if [[ -s "$NVM_DIR/nvm.sh" ]] && ! command -v nvm >/dev/null 2>&1; then
		# shellcheck disable=SC1091
		. "$NVM_DIR/nvm.sh" --no-use
	fi
}

# use_node_for_bench <bench-path>: switch to the node version pinned in <bench>/.nvmrc
use_node_for_bench() {
	local bench=$1 want=default
	load_runtime_env
	if command -v nvm >/dev/null 2>&1; then
		[[ -s "$bench/.nvmrc" ]] && want=$(tr -d '[:space:]' <"$bench/.nvmrc")
		if ! nvm use --silent "$want" >/dev/null 2>&1; then
			warn "Node '$want' (from $bench/.nvmrc) is not installed; trying to install it with nvm."
			nvm install "$want" >/dev/null 2>&1 && nvm use --silent "$want" >/dev/null 2>&1 \
				|| nvm use --silent default >/dev/null 2>&1 || true
		fi
	fi
	command -v node >/dev/null 2>&1 || warn "node is not on PATH; asset builds will fail."
}

# --------------------------------------------------------------------------
# Bench helpers
# --------------------------------------------------------------------------
is_bench_dir() { [[ -d "$1/apps/frappe" && -d "$1/sites" ]]; }

# find_benches: list bench directories under $HOME (depth 2) and /home/*/ (depth 1)
find_benches() {
	local d
	{
		for d in "$HOME"/* "$HOME"/*/* /home/*/* /opt/*; do
			if [[ -d "$d" ]] && is_bench_dir "$d"; then printf '%s\n' "$d"; fi
		done
	} 2>/dev/null | awk '!seen[$0]++'
}

# select_bench <varname>: interactively pick a bench directory.
select_bench() {
	local __var=$1 __sel=''
	local -a __found=()
	mapfile -t __found < <(find_benches)
	if [[ -n "${BENCH_PATH:-}" ]]; then
		__sel=$BENCH_PATH
	elif ((${#__found[@]} == 1)); then
		__sel=${__found[0]}
		info "Using bench at ${C_BOLD}$__sel${C_RESET}"
	elif ((${#__found[@]} > 1)); then
		choose __sel "Which bench?" 1 "${__found[@]}" "other|type a path"
		[[ "$__sel" == other ]] && ask __sel "Bench directory" "$HOME/frappe-bench"
	else
		ask __sel "Bench directory" "$HOME/frappe-bench"
	fi
	__sel=$(cd "$__sel" 2>/dev/null && pwd) || die "Directory not found."
	is_bench_dir "$__sel" || die "$__sel does not look like a bench (missing apps/frappe or sites)."
	printf -v "$__var" '%s' "$__sel"
}

# bench_sites <bench>: list site directory names
bench_sites() {
	local bench=$1 d
	for d in "$bench"/sites/*/; do
		d=${d%/}
		if [[ -f "$d/site_config.json" ]]; then basename "$d"; fi
	done
	return 0
}

# bench_apps <bench>: list apps present in the bench (from sites/apps.txt, else apps/)
bench_apps() {
	local bench=$1
	if [[ -s "$bench/sites/apps.txt" ]]; then
		grep -v '^\s*$' "$bench/sites/apps.txt"
	else
		find "$bench/apps" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' | sort
	fi
}

# app_branch <bench> <app>
app_branch() { git -C "$1/apps/$2" rev-parse --abbrev-ref HEAD 2>/dev/null || echo '?'; }

bench_is_production() {
	local bench=$1 name
	name=$(basename "$bench")
	[[ -e "/etc/supervisor/conf.d/$name.conf" || -e "/etc/supervisor.d/$name.ini" || -e "/etc/nginx/conf.d/$name.conf" ]]
}

# frappe_major_of_bench <bench>
frappe_major_of_bench() {
	local bench=$1 v
	v=$(grep -oE '__version__\s*=\s*"[^"]+"' "$bench/apps/frappe/frappe/__init__.py" 2>/dev/null | grep -oE '[0-9]+' | head -1 || true)
	[[ -n "$v" ]] && { echo "$v"; return; }
	frappe_major_from_ref "$(app_branch "$bench" frappe)"
}

# site_apps <bench> <site>: apps installed on a site (excluding frappe)
site_apps() {
	( cd "$1" && bench --site "$2" list-apps 2>/dev/null ) | awk '{print $1}' | grep -vE '^\s*$|^frappe$' || true
}

# check_site_apps <bench> <site> <app...>: warn about apps that did not get installed.
check_site_apps() {
	local bench=$1 site=$2 a; shift 2
	local installed missing=()
	installed=" $(site_apps "$bench" "$site" | tr '\n' ' ') "
	for a in "$@"; do [[ "$installed" == *" $a "* ]] || missing+=("$a"); done
	if ((${#missing[@]})); then
		warn "Not installed on $site: ${missing[*]}. Retry with: cd $bench && bench --site $site install-app ${missing[*]}"
		return 1
	fi
	return 0
}

# --------------------------------------------------------------------------
# Bench Redis for development benches
# Site commands (new-site, install-app, migrate) need the bench's Redis queue/cache.
# In production supervisor runs them; in development they only run with `bench start`,
# so start them for the duration of the script when they are not already up.
# --------------------------------------------------------------------------
_FSS_STARTED_REDIS=()
redis_port_up() {
	if command -v redis-cli >/dev/null 2>&1; then
		redis-cli -p "$1" ping 2>/dev/null | grep -q PONG
	else
		(exec 3<>"/dev/tcp/127.0.0.1/$1") 2>/dev/null
	fi
}
stop_bench_redis() {
	local p
	for p in "${_FSS_STARTED_REDIS[@]}"; do
		redis-cli -p "$p" shutdown nosave >/dev/null 2>&1 || true
	done
	_FSS_STARTED_REDIS=()
}
ensure_bench_redis() {
	local bench=$1 conf port
	bench_is_production "$bench" && return 0
	command -v redis-server >/dev/null 2>&1 || return 0
	for conf in "$bench"/config/redis_*.conf; do
		[[ -f "$conf" ]] || continue
		port=$(awk '$1 == "port" { print $2; exit }' "$conf")
		[[ -n "$port" ]] || continue
		redis_port_up "$port" && continue
		if ( cd "$bench" && redis-server "$conf" --daemonize yes >/dev/null 2>&1 ); then
			if ((${#_FSS_STARTED_REDIS[@]} == 0)); then on_exit stop_bench_redis; fi
			_FSS_STARTED_REDIS+=("$port")
		fi
	done
	if ((${#_FSS_STARTED_REDIS[@]})); then
		info "Started the bench's Redis (ports ${_FSS_STARTED_REDIS[*]}) for this run; it stops when the script ends."
		sleep 1
	fi
	return 0
}

# with_bench <bench> <bench-args...>: run bench inside the bench directory with the right env.
with_bench() {
	local bench=$1; shift
	( cd "$bench" && run bench "$@" )
}

# --------------------------------------------------------------------------
# Log files
# setup_logging <name>: copy everything the script prints (not what you type) to
# $FSS_LOG_DIR/<name>-<timestamp>.log, without colour codes. Keeps the newest 20 logs per name.
# --------------------------------------------------------------------------
FSS_LOG_DIR="${FSS_LOG_DIR:-$HOME/frappe-setup-logs}"
_FSS_LOG_PID=''
setup_logging() {
	local name=$1 old
	[[ -n "${FSS_LOG_FILE:-}" && -n "$_FSS_LOG_PID" ]] && return 0
	if [[ ! -d "$FSS_LOG_DIR" ]]; then mkdir -p "$FSS_LOG_DIR" && chmod 700 "$FSS_LOG_DIR"; fi
	# The PID keeps names unique when two runs share a directory in the same second
	# (install.sh as root hands over to the bench user within a second).
	FSS_LOG_FILE="$FSS_LOG_DIR/$name-$(date +%Y%m%d-%H%M%S)-$$.log"
	( umask 077; : >"$FSS_LOG_FILE" )
	# Prompts read from /dev/tty, so only output (never typed input) reaches the log.
	exec > >(tee >(sed -u 's/\x1b\[[0-9;]*[A-Za-z]//g' >>"$FSS_LOG_FILE"); wait "$!" 2>/dev/null) 2>&1
	_FSS_LOG_PID=$!
	on_exit ':'  # make sure the EXIT trap (which flushes the log) is installed
	# shellcheck disable=SC2012  # log names are ours: <name>-<digits>.log
	while read -r old; do rm -f -- "$old"; done < <(ls -1t "$FSS_LOG_DIR/$name"-*.log 2>/dev/null | tail -n +21)
	{
		printf '# %s, started %s by %s on %s\n' "$name" "$(date '+%F %T %z')" "$(id -un)" "$(hostname 2>/dev/null || echo '?')"
		printf '# scripts: %s\n' "$(git -C "${SCRIPT_DIR:-.}" describe --always --dirty 2>/dev/null || echo unknown)"
		printf '# command: %s\n' "$(masked "$0 ${FSS_ARGS:-}")"
	} >>"$FSS_LOG_FILE"
	info "Logging to $FSS_LOG_FILE"
	ui_quiet_active && info "Quiet mode: command output goes to the log only."
	return 0
}

# Wait for the log writer so the last lines are not lost when the script exits.
_fss_flush_log() {
	[[ -n "$_FSS_LOG_PID" ]] || return 0
	exec 1>&- 2>&-
	# Normally the writer ends as soon as our output closes. If some background process
	# still holds the pipe, do not hang: give it 5 seconds, then stop it.
	local _
	for _ in 1 2 3 4 5 6 7 8 9 10; do
		kill -0 "$_FSS_LOG_PID" 2>/dev/null || break
		sleep 0.5
	done
	kill "$_FSS_LOG_PID" 2>/dev/null || true
	_FSS_LOG_PID=''
}

# Dialog boxes, validation, progress and summary helpers.
# shellcheck source=lib/ui.sh
. "$(dirname "${BASH_SOURCE[0]}")/ui.sh"
