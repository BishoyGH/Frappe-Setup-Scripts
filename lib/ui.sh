#!/usr/bin/env bash
# shellcheck shell=bash
# Terminal UI layer, sourced by common.sh:
#  - whiptail/dialog front-end for the prompt helpers (ask, choose, ...), with plain prompts as fallback
#  - input validators and ask_valid / ask_new_password
#  - step progress (phase), quiet mode with a spinner, and the final summary box
#
# Environment:
#   FSS_UI=auto|tui|whiptail|dialog|plain   auto (default) uses whiptail or dialog when a terminal is available
#   FSS_QUIET=1                             hide command output (it still goes to the log) and show a spinner

[[ -n "${_FSS_UI_LOADED:-}" ]] && return 0
_FSS_UI_LOADED=1

_FSS_TUI_BIN='' _FSS_TUI_CHECKED=0
_UI_DETAILS='' _UI_SECTION='' _UI_OUT=''
_UI_BACKTITLE='Frappe Setup Scripts'

# ui_parse_flags "$@": consume the UI flags shared by every script; the rest ends up in FSS_REST_ARGS.
FSS_REST_ARGS=()
ui_parse_flags() {
	FSS_REST_ARGS=()
	local a
	for a in "$@"; do
		case "$a" in
			--plain|--no-tui) export FSS_UI=plain ;;
			--tui) export FSS_UI=tui ;;
			--quiet|-q) export FSS_QUIET=1 ;;
			--verbose|-v) export FSS_QUIET=0 ;;
			*) FSS_REST_ARGS+=("$a") ;;
		esac
	done
	_FSS_TUI_CHECKED=0
}

# UI options as help text, for the scripts' --help output.
ui_flags_help() {
	cat <<'EOF'
Options:
  --plain     plain text prompts instead of dialog boxes (or FSS_UI=plain)
  --tui       always use dialog boxes when whiptail or dialog is installed
  --quiet     show a progress spinner instead of every command's output (or FSS_QUIET=1);
              the full output is still written to the log in ~/frappe-setup-logs
  -h, --help  show this help
EOF
}

ui_set_title() { _UI_BACKTITLE=$*; }

_ui_has_tty() { { : </dev/tty >/dev/tty; } 2>/dev/null; }

_ui_size() {
	_UI_ROWS=24 _UI_COLS=80
	local r c
	if read -r r c < <(stty size </dev/tty 2>/dev/null) && [[ "$r" =~ ^[0-9]+$ && "$c" =~ ^[0-9]+$ ]]; then
		_UI_ROWS=$r _UI_COLS=$c
	fi
}

tui_active() {
	if ((!_FSS_TUI_CHECKED)); then
		_FSS_TUI_CHECKED=1
		_FSS_TUI_BIN=''
		local want=${FSS_UI:-auto}
		case "$want" in plain|no|off|0|false) return 1 ;; esac
		if [[ "${ASSUME_DEFAULTS:-0}" != 1 && "${TERM:-dumb}" != dumb ]] && _ui_has_tty; then
			_ui_size
			if ((_UI_ROWS >= 15 && _UI_COLS >= 60)); then
				case "$want" in
					whiptail|dialog) command -v "$want" >/dev/null 2>&1 && _FSS_TUI_BIN=$want ;;
					*)
						if command -v whiptail >/dev/null 2>&1; then _FSS_TUI_BIN=whiptail
						elif command -v dialog >/dev/null 2>&1; then _FSS_TUI_BIN=dialog
						fi
						;;
				esac
			fi
		fi
		if [[ -z "$_FSS_TUI_BIN" && "$want" != auto ]]; then
			printf '%s!%s  %s\n' "${C_YELLOW}${C_BOLD}" "${C_RESET}" "Dialog boxes are not available (need whiptail or dialog and a terminal of at least 60x15); using plain prompts." >&2
		fi
	fi
	[[ -n "$_FSS_TUI_BIN" ]]
}

_ui_strip() { sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e 's/\x1b\][^\a]*\a//g'; }

# ui_details <text>: context for the next question (a table, a status list...).
# Plain mode prints it; dialog mode also shows it at the top of the next dialog box.
ui_details() {
	printf '%s\n' "$*" >&2
	tui_active || return 0
	_UI_DETAILS+="$(_ui_strip <<<"$*")"$'\n'
}

# _ui_note <line>: warnings are carried into the next dialog box so they are not hidden behind it.
_ui_note() {
	[[ -n "$_FSS_TUI_BIN" ]] || return 0
	_UI_DETAILS+="$(_ui_strip <<<"$*")"$'\n'
	# keep the last 12 lines only
	_UI_DETAILS=$(tail -n 12 <<<"$_UI_DETAILS")$'\n'
}

# ui_error <message>: show a problem with the last answer.
ui_error() {
	if tui_active; then
		_ui_dialog msgbox "$*" 0
	else
		warn "$*"
	fi
}

# _ui_dialog <kind> <text> <list-length> [box options...] [-- box arguments...]
# kind: inputbox passwordbox yesno msgbox menu checklist. Result in _UI_OUT, exit code returned.
_ui_dialog() {
	local kind=$1 text=$2 n=$3; shift 3
	local -a pre=() post=()
	while (($#)); do
		if [[ "$1" == -- ]]; then shift; post=("$@"); break; fi
		pre+=("$1"); shift
	done
	if [[ -n "$_UI_DETAILS" ]]; then
		text="${_UI_DETAILS%$'\n'}"$'\n\n'"$text"
		_UI_DETAILS=''
	fi
	_ui_size
	local maxw=0 line lines=0 itemw=0 i w h lh cap_w
	cap_w=$((_UI_COLS - 4)); ((cap_w > 110)) && cap_w=110
	while IFS= read -r line; do ((${#line} > maxw)) && maxw=${#line}; done <<<"$text"
	if [[ "$kind" == menu || "$kind" == checklist ]]; then
		local step=2; [[ "$kind" == checklist ]] && step=3
		for ((i = 0; i + 1 < ${#post[@]}; i += step)); do
			w=$((${#post[i]} + ${#post[i + 1]} + 8)); ((w > itemw)) && itemw=$w
		done
		[[ "$kind" == checklist ]] && itemw=$((itemw + 4))
	fi
	w=$((maxw + 6)); ((itemw + 6 > w)) && w=$((itemw + 6)); ((w < 54)) && w=54; ((w > cap_w)) && w=$cap_w
	while IFS= read -r line; do lines=$((lines + (${#line} + w - 7) / (w - 6) )); ((${#line} == 0)) && lines=$((lines + 1)); done <<<"$text"
	h=$((lines + 6))
	lh=0
	if ((n > 0)); then
		lh=$n
		((lh > _UI_ROWS - lines - 9)) && lh=$((_UI_ROWS - lines - 9))
		((lh < 3)) && lh=3
		((lh > n)) && lh=$n
		h=$((h + lh + 1))
	fi
	[[ "$kind" == inputbox || "$kind" == passwordbox ]] && h=$((h + 2))
	((h > _UI_ROWS - 2)) && h=$((_UI_ROWS - 2))
	local -a common=(--backtitle "$_UI_BACKTITLE")
	[[ -n "$_UI_SECTION" ]] && common+=(--title " $_UI_SECTION ")
	if [[ "$_FSS_TUI_BIN" == whiptail ]]; then
		# Long texts need a scrollable box (it takes the keyboard focus, so only when needed).
		[[ "$kind" == msgbox || "$kind" == yesno ]] && ((lines + 7 > _UI_ROWS - 2)) && common+=(--scrolltext)
	else
		[[ "$kind" == passwordbox ]] && common+=(--insecure)
		[[ "$kind" == menu || "$kind" == checklist ]] && common+=(--no-collapse)
	fi
	local -a size=("$h" "$w"); ((n > 0)) && size+=("$lh")
	local rc=0
	_UI_OUT=$("$_FSS_TUI_BIN" "${common[@]}" "${pre[@]}" "--$kind" "$text" "${size[@]}" "${post[@]}" 2>&1 >/dev/tty </dev/tty) || rc=$?
	return "$rc"
}

_ui_cancelled() { die "Cancelled."; }

# _ui_echo <prompt> <answer>: keep a transcript of answers on the terminal/log.
_ui_echo() { printf '%s?%s %s %s%s%s\n' "${C_CYAN}" "${C_RESET}" "$1" "${C_BOLD}" "$2" "${C_RESET}" >&2; }

_tui_ask() { # _tui_ask <var> <prompt> <default> <required:1|0>
	local __ui_var=$1 __ui_prompt=$2 __ui_def=$3 __ui_req=$4 __ui_rc
	while true; do
		__ui_rc=0
		_ui_dialog inputbox "$__ui_prompt" 0 -- "$__ui_def" || __ui_rc=$?
		((__ui_rc == 0)) || _ui_cancelled
		[[ -n "$_UI_OUT" || "$__ui_req" == 0 ]] && break
		_ui_dialog msgbox "A value is required." 0 || true
	done
	_ui_echo "$__ui_prompt" "$_UI_OUT"
	printf -v "$__ui_var" '%s' "$_UI_OUT"
}

_tui_secret() { # _tui_secret <var> <prompt> <confirm:yes|no> [allow-empty:1|0]
	local __ui_var=$1 __ui_prompt=$2 __ui_confirm=$3 __ui_empty=${4:-0} __ui_a __ui_rc
	while true; do
		__ui_rc=0
		_ui_dialog passwordbox "$__ui_prompt" 0 || __ui_rc=$?
		((__ui_rc == 0)) || _ui_cancelled
		__ui_a=$_UI_OUT
		if [[ -z "$__ui_a" ]]; then
			[[ "$__ui_empty" == 1 ]] && break
			_ui_dialog msgbox "A value is required." 0 || true; continue
		fi
		if [[ "$__ui_confirm" == yes ]]; then
			__ui_rc=0
			_ui_dialog passwordbox "Confirm: ${__ui_prompt}" 0 || __ui_rc=$?
			((__ui_rc == 0)) || _ui_cancelled
			if [[ "$_UI_OUT" != "$__ui_a" ]]; then _ui_dialog msgbox "The two values do not match. Try again." 0 || true; continue; fi
		fi
		break
	done
	_ui_echo "$__ui_prompt" "$([[ -n "$__ui_a" ]] && echo '********' || echo '(empty)')"
	printf -v "$__ui_var" '%s' "$__ui_a"
}

_tui_yes_no() { # _tui_yes_no <prompt> <default:y|n>
	local rc=0
	local -a opts=()
	[[ "$2" == n ]] && opts+=(--defaultno)
	_ui_dialog yesno "$1" 0 "${opts[@]}" || rc=$?
	((rc == 255)) && _ui_cancelled
	_ui_echo "$1" "$( ((rc == 0)) && echo yes || echo no)"
	return "$rc"
}

# Options are "value|description" as for choose().
_tui_choose() { # _tui_choose <var> <prompt> <default-index> <option>...
	local __ui_var=$1 __ui_prompt=$2 __ui_def=$3; shift 3
	local -a __ui_items=()
	local __ui_o __ui_defval='' __ui_i=0 __ui_rc=0 __ui_has_quit=0
	for __ui_o in "$@"; do
		__ui_i=$((__ui_i + 1))
		__ui_items+=("${__ui_o%%|*}")
		if [[ "$__ui_o" == *"|"* ]]; then __ui_items+=("${__ui_o#*|}"); else __ui_items+=(""); fi
		((__ui_i == __ui_def)) && __ui_defval=${__ui_o%%|*}
		[[ "${__ui_o%%|*}" == quit ]] && __ui_has_quit=1
	done
	_ui_dialog menu "$__ui_prompt" "$#" --default-item "$__ui_defval" -- "${__ui_items[@]}" || __ui_rc=$?
	if ((__ui_rc != 0)); then
		# Cancel/Esc picks "quit" in menus that have one.
		((__ui_has_quit)) && { printf -v "$__ui_var" '%s' quit; return 0; }
		_ui_cancelled
	fi
	_ui_echo "$__ui_prompt" "$_UI_OUT"
	printf -v "$__ui_var" '%s' "$_UI_OUT"
}

_tui_choose_multi() { # _tui_choose_multi <array-var> <prompt> <defaults: "1 3" | a | ""> <option>...
	local __ui_var=$1 __ui_prompt=$2 __ui_def=$3; shift 3
	local -a __ui_items=() __ui_picked=()
	local __ui_o __ui_i=0 __ui_on __ui_rc=0 __ui_line
	__ui_def=" ${__ui_def//,/ } "
	for __ui_o in "$@"; do
		__ui_i=$((__ui_i + 1))
		__ui_on=OFF
		[[ "$__ui_def" == *" a "* || "$__ui_def" == *" all "* || "$__ui_def" == *" $__ui_i "* ]] && __ui_on=ON
		__ui_items+=("${__ui_o%%|*}")
		if [[ "$__ui_o" == *"|"* ]]; then __ui_items+=("${__ui_o#*|}"); else __ui_items+=(""); fi
		__ui_items+=("$__ui_on")
	done
	_ui_dialog checklist "$__ui_prompt"$'\n'"(Space toggles, Enter confirms)" "$#" --separate-output -- "${__ui_items[@]}" || __ui_rc=$?
	((__ui_rc == 0)) || _ui_cancelled
	while IFS= read -r __ui_line; do
		__ui_line=${__ui_line//\"/}
		[[ -n "$__ui_line" ]] && __ui_picked+=("$__ui_line")
	done <<<"$_UI_OUT"
	_ui_echo "$__ui_prompt" "${__ui_picked[*]:-(none)}"
	eval "$__ui_var=(\"\${__ui_picked[@]}\")"
}

# --------------------------------------------------------------------------
# Validation
# Validators print a short reason and return 1 when a value is not acceptable.
# --------------------------------------------------------------------------

# ask_valid <varname> <prompt> <default> <validator> [validator-args...]
ask_valid() {
	local __av_var=$1 __av_prompt=$2 __av_def=$3 __av_fn=$4; shift 4
	local __av_val='' __av_msg
	while true; do
		ask __av_val "$__av_prompt" "$__av_def"
		if __av_msg=$("$__av_fn" "$__av_val" "$@" 2>&1); then break; fi
		[[ "${ASSUME_DEFAULTS:-0}" == 1 ]] && die "$__av_prompt: ${__av_msg:-invalid value: $__av_val}"
		ui_error "${__av_msg:-Invalid value: $__av_val}"
		__av_def=$__av_val
	done
	printf -v "$__av_var" '%s' "$__av_val"
}

valid_hostname_like() {
	local v=$1
	((${#v} <= 253)) || { echo "Too long (max 253 characters)."; return 1; }
	[[ "$v" =~ ^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?(\.[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?)*$ ]] || {
		echo "'$v' is not a valid name. Use letters, digits, dashes and dots, like erp.example.com or site1.localhost."
		return 1
	}
}

# valid_site_name <name> [bench-path]
valid_site_name() {
	valid_hostname_like "$1" || return 1
	if [[ -n "${2:-}" && -d "$2/sites/$1" ]]; then echo "A site named $1 already exists in $2."; return 1; fi
	return 0
}

# valid_bench_name <name>: a new directory under $HOME
valid_bench_name() {
	local v=$1
	[[ "$v" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || { echo "Use letters, digits, dots, dashes and underscores only (no spaces or slashes)."; return 1; }
	if [[ -e "$HOME/$v" ]]; then
		if is_bench_dir "$HOME/$v"; then
			echo "$HOME/$v already contains a bench. Pick another name, or use update-bench.sh / manage-sites.sh for that bench."
		else
			echo "$HOME/$v already exists. Pick another name."
		fi
		return 1
	fi
}

valid_email() {
	[[ "$1" =~ ^[^@[:space:]]+@[^@[:space:]]+\.[^@[:space:]]+$ ]] || { echo "'$1' does not look like an email address."; return 1; }
}

valid_username() {
	[[ "$1" != root ]] || { echo "Choose a regular (non-root) user."; return 1; }
	[[ "$1" =~ ^[a-z_][a-z0-9_-]{0,31}$ ]] || { echo "Use lowercase letters, digits, '-' and '_', starting with a letter."; return 1; }
}

valid_python_version() { [[ "$1" =~ ^3\.[0-9]{1,2}$ ]] || { echo "Use a Python version like 3.11."; return 1; }; }
valid_node_version() {
	[[ "$1" =~ ^[0-9]{2}$ ]] || { echo "Use a Node.js major version like 18 or 24."; return 1; }
	(($1 >= 14)) || { echo "Node $1 is too old for Frappe."; return 1; }
}

# valid_git_url <url>: well-formed and readable (git ls-remote).
valid_git_url() {
	local url=$1
	[[ "$url" =~ ^(https?://|ssh://|git@[^:]+:|file://|/) ]] || { echo "Use a git URL like https://github.com/owner/app (or git@github.com:owner/app.git)."; return 1; }
	if ! GIT_TERMINAL_PROMPT=0 timeout 30 git ls-remote --heads "$url" >/dev/null 2>&1; then
		echo "Cannot read $url. Check the URL, your network, and (for private repos) your git credentials or SSH key."
		return 1
	fi
}

# valid_git_ref <url> <ref>
valid_git_ref() {
	[[ -n "$1" ]] || { echo "A branch or tag is required."; return 1; }
	remote_ref_exists "$2" "$1" || { echo "'$1' was not found in $2."; return 1; }
}

# --------------------------------------------------------------------------
# Passwords
# --------------------------------------------------------------------------
FSS_GENERATED_SECRETS=() # "label|value"

gen_password() { # gen_password [length]
	local len=${1:-20} pw=''
	while ((${#pw} < len)); do
		pw+=$(LC_ALL=C tr -dc 'A-Za-z0-9' </dev/urandom 2>/dev/null | head -c "$len" || true)
	done
	printf '%s' "${pw:0:len}"
}

# ask_new_password <varname> <label> [env-var] [min-length]
# A new password: typed twice, or left empty to generate a strong one (shown in the final summary).
ask_new_password() {
	local __np_var=$1 __np_label=$2 __np_env=${3:-} __np_min=${4:-1} __np_a='' __np_b=''
	if [[ -n "$__np_env" && -n "${!__np_env:-}" ]]; then
		printf -v "$__np_var" '%s' "${!__np_env}"; return 0
	fi
	if [[ "${ASSUME_DEFAULTS:-0}" == 1 ]]; then
		ask_secret "$__np_var" "$__np_label" yes "$__np_env"; return 0
	fi
	while true; do
		if tui_active; then
			_tui_secret __np_a "$__np_label"$'\n'"(leave empty to generate a strong password)" no 1
		else
			printf '%s?%s %s %s(Enter = generate one)%s: ' "${C_CYAN}${C_BOLD}" "${C_RESET}" "$__np_label" "${C_DIM}" "${C_RESET}" >&2
			_tty_read __np_a -s; printf '\n' >&2
		fi
		if [[ -z "$__np_a" ]]; then
			__np_a=$(gen_password 20)
			FSS_GENERATED_SECRETS+=("$__np_label|$__np_a")
			success "Generated a strong password for: $__np_label (shown at the end)."
			break
		fi
		if ((${#__np_a} < __np_min)); then ui_error "Use at least $__np_min characters."; continue; fi
		if tui_active; then
			_tui_secret __np_b "Confirm: $__np_label" no 1
		else
			printf '%s?%s Confirm %s: ' "${C_CYAN}${C_BOLD}" "${C_RESET}" "${__np_label,}" >&2
			_tty_read __np_b -s; printf '\n' >&2
		fi
		[[ "$__np_a" == "$__np_b" ]] && break
		ui_error "The two passwords do not match. Try again."
	done
	printf -v "$__np_var" '%s' "$__np_a"
}

# generated_secret <label>: print a generated password, if one was generated for <label>.
generated_secret() {
	local e
	for e in "${FSS_GENERATED_SECRETS[@]}"; do [[ "${e%%|*}" == "$1" ]] && { printf '%s' "${e#*|}"; return 0; }; done
	return 1
}

# save_generated_secrets <file>: write generated passwords to a file only the user can read.
save_generated_secrets() {
	local file=$1 e
	((${#FSS_GENERATED_SECRETS[@]})) || return 1
	mkdir -p "$(dirname "$file")"
	chmod 700 "$(dirname "$file")"
	(
		umask 077
		{
			echo "# Generated by Frappe-Setup-Scripts on $(date '+%F %T')"
			echo "# Store these in a password manager, then delete this file."
			for e in "${FSS_GENERATED_SECRETS[@]}"; do printf '%s: %s\n' "${e%%|*}" "${e#*|}"; done
		} >"$file"
	)
}

# --------------------------------------------------------------------------
# Progress: numbered steps with elapsed time
# --------------------------------------------------------------------------
_FSS_PHASE_N=0 _FSS_PHASE_TOTAL=0 _FSS_PHASE_T0=0 _FSS_IN_PHASE=0 _FSS_CURRENT_PHASE=''
_FSS_PHASE_LOG=() # "title|seconds"

fmt_duration() { # fmt_duration <seconds>
	local s=$1
	if ((s >= 3600)); then printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
	elif ((s >= 60)); then printf '%dm%02ds' $((s / 60)) $((s % 60))
	else printf '%ds' "$s"
	fi
}

_ui_term_title() {
	case "${TERM:-}" in xterm*|screen*|tmux*|rxvt*|alacritty|foot*|wezterm) ;; *) return 0 ;; esac
	if _ui_has_tty; then printf '\e]2;%s\a' "$*" >/dev/tty 2>/dev/null || true; fi
}

# phase_plan <total>: start counting steps.
phase_plan() { _FSS_PHASE_TOTAL=$1 _FSS_PHASE_N=0 _FSS_PHASE_T0=$(date +%s) _FSS_PHASE_LOG=(); }

# phase <title> <command...>: run one numbered step of the plan.
phase() {
	local title=$1 t0 now pct bar filled width=20; shift
	_FSS_PHASE_N=$((_FSS_PHASE_N + 1))
	now=$(date +%s); t0=$now
	((_FSS_PHASE_TOTAL > 0)) || _FSS_PHASE_TOTAL=$_FSS_PHASE_N
	pct=$(( (_FSS_PHASE_N - 1) * 100 / _FSS_PHASE_TOTAL ))
	filled=$(( (_FSS_PHASE_N - 1) * width / _FSS_PHASE_TOTAL ))
	bar=$(printf '%*s' "$filled" '' | tr ' ' '#')$(printf '%*s' $((width - filled)) '' | tr ' ' '.')
	bar=${bar//#/█}; bar=${bar//./░}
	_FSS_CURRENT_PHASE="step $_FSS_PHASE_N of $_FSS_PHASE_TOTAL: $title"
	_UI_SECTION=$title
	printf '\n%s▶ Step %d/%d  %s%s  %s%s %3d%%  %s elapsed%s\n' "${C_CYAN}${C_BOLD}" "$_FSS_PHASE_N" "$_FSS_PHASE_TOTAL" "$title" "${C_RESET}" \
		"${C_DIM}" "$bar" "$pct" "$(fmt_duration $((now - _FSS_PHASE_T0)))" "${C_RESET}" >&2
	_ui_term_title "[$_FSS_PHASE_N/$_FSS_PHASE_TOTAL] $title · ${_UI_BACKTITLE}"
	_FSS_IN_PHASE=1
	"$@"
	_FSS_IN_PHASE=0
	now=$(date +%s)
	_FSS_PHASE_LOG+=("$title|$((now - t0))")
	_FSS_CURRENT_PHASE=''
	printf '%s✔%s  %s %s(%s)%s\n' "${C_GREEN}${C_BOLD}" "${C_RESET}" "$title" "${C_DIM}" "$(fmt_duration $((now - t0)))" "${C_RESET}" >&2
	((_FSS_PHASE_N == _FSS_PHASE_TOTAL)) && _ui_term_title "${_UI_BACKTITLE}: done"
	return 0
}

# phase_report: per-step timings as "title  duration" lines.
phase_report() {
	local e
	for e in "${_FSS_PHASE_LOG[@]}"; do printf '%-32s %s\n' "${e%%|*}" "$(fmt_duration "${e#*|}")"; done
}

# --------------------------------------------------------------------------
# Quiet mode: command output goes to the log only; a spinner shows progress
# --------------------------------------------------------------------------
_UI_SPIN_PID=''
_ui_spinner_stop() {
	[[ -n "$_UI_SPIN_PID" ]] || return 0
	kill "$_UI_SPIN_PID" 2>/dev/null || true
	wait "$_UI_SPIN_PID" 2>/dev/null || true
	_UI_SPIN_PID=''
	printf '\r\e[K' >/dev/tty 2>/dev/null || true
}

ui_quiet_active() { [[ "${FSS_QUIET:-0}" == 1 && -n "${FSS_LOG_FILE:-}" ]]; }

# _ui_run_quiet <cmd...>: used by run() in quiet mode.
_ui_run_quiet() {
	local label rc=0 t0 cols=80 lw
	label=$(masked "$*")
	label=${label//$'\n'/ }
	((${#label} > 50)) && label="${label:0:47}..."
	printf '$ %s\n' "$(masked "$*")" >>"$FSS_LOG_FILE"
	t0=$(date +%s)
	if _ui_has_tty; then
		_ui_size; cols=$_UI_COLS
		lw=$((cols - ${#label} - 16))
		(
			trap - ERR EXIT; set +e +o pipefail
			frames="|/-\\"
			[[ "${LC_ALL:-${LANG:-}}" == *UTF-8* ]] && frames='⠋⠙⠹⠸⠼⠴⠦⠧⠇⠏'
			i=0
			while :; do
				last=''
				if ((lw > 12)); then
					last=$(tail -c 400 "$FSS_LOG_FILE" 2>/dev/null | tr '\r' '\n' | sed -e 's/\x1b\[[0-9;]*[A-Za-z]//g' -e '/^[[:space:]]*$/d' | tail -n 1)
					last=${last:0:lw}
				fi
				printf '\r\e[K  %s%s%s %s %s%s%s %s' "$C_CYAN" "${frames:i % ${#frames}:1}" "$C_RESET" "$label" \
					"$C_DIM" "$(fmt_duration $(( $(date +%s) - t0 )))" "$C_RESET" "$last" >/dev/tty
				i=$((i + 1))
				sleep 0.25
			done
		) &
		_UI_SPIN_PID=$!
	fi
	"$@" >>"$FSS_LOG_FILE" 2>&1 </dev/null || rc=$?
	_ui_spinner_stop
	if ((rc == 0)); then
		printf '  %s✔ %s (%s)%s\n' "$C_DIM" "$label" "$(fmt_duration $(( $(date +%s) - t0 )))" "$C_RESET" >&2
	else
		error "Failed (exit $rc): $(masked "$*")"
		error "Last lines of $FSS_LOG_FILE:"
		tail -n 25 "$FSS_LOG_FILE" | sed 's/^/     /' >/dev/tty 2>/dev/null || tail -n 25 "$FSS_LOG_FILE" >&2
	fi
	return "$rc"
}

# --------------------------------------------------------------------------
# Boxes
# --------------------------------------------------------------------------
# ui_box <title> <line>...: draw a framed block (lines may contain colors).
ui_box() {
	local title=$1; shift
	local line plain max=${#title} cols=80 w pad
	for line in "$@"; do plain=$(_ui_strip <<<"$line"); ((${#plain} > max)) && max=${#plain}; done
	if _ui_has_tty; then _ui_size; cols=$_UI_COLS; fi
	w=$((max + 4))
	local right=1 tr='╮' br='╯'
	((w + 2 > cols)) && right=0 tr='' br=
	local rule
	rule=$(printf '%*s' $((w - ${#title} - 3)) '' | tr ' ' '#'); rule=${rule//#/─}
	{
		printf '\n%s╭─ %s%s%s %s%s%s\n' "${C_GREEN}" "${C_BOLD}" "$title" "${C_RESET}${C_GREEN}" "$rule" "$tr" "${C_RESET}"
		for line in "$@"; do
			plain=$(_ui_strip <<<"$line")
			pad=$((w - 2 - ${#plain}))
			if ((right)); then
				printf '%s│%s  %s%*s%s│%s\n' "${C_GREEN}" "${C_RESET}" "$line" "$pad" '' "${C_GREEN}" "${C_RESET}"
			else
				printf '%s│%s  %s\n' "${C_GREEN}" "${C_RESET}" "$line"
			fi
		done
		rule=$(printf '%*s' "$w" '' | tr ' ' '#'); rule=${rule//#/─}
		printf '%s╰%s%s%s\n' "${C_GREEN}" "$rule" "$br" "${C_RESET}"
	} >&2
}

# kv <label> <value>: a box/summary line with an aligned label
kv() { printf '%s%-11s%s %s' "${C_DIM}" "$1" "${C_RESET}" "$2"; }
