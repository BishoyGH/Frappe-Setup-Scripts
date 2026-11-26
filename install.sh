#!/usr/bin/env bash
# Installer for the Frappe framework and official Frappe apps.
# Supports Ubuntu, Debian and Arch Linux (bare metal, VM or WSL), development or production setups.
#
# Interactive by default. Every question can also be answered with a flag or an answers file
# (see examples/install.conf), and --yes accepts the default for anything left unanswered.
# If a run stops half-way, run the same command again: finished steps are skipped.
#
# Usage: ./install.sh [options]

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/prereqs.sh
. "$SCRIPT_DIR/lib/prereqs.sh"
# shellcheck source=lib/apps.sh
. "$SCRIPT_DIR/lib/apps.sh"
# shellcheck source=lib/unattended.sh
. "$SCRIPT_DIR/lib/unattended.sh"
# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"
strict_mode

usage() {
	cat <<'EOF'
Usage: ./install.sh [options]

  -y, --yes, --non-interactive   accept the default for every question that has no preset answer
  -c, --config FILE              read answers from FILE (KEY=value lines, see examples/install.conf)
      --resume                   continue an install that did not finish (asked automatically otherwise)
      --fresh                    ignore any unfinished install and start over

Answers (each one is also a KEY in the answers file; flags win over the file):
      --mode development|production        MODE
      --frappe-branch BRANCH|latest        FRAPPE_BRANCH   e.g. version-15, develop, v15.50.0
      --frappe-major N                     FRAPPE_MAJOR    only for a tag/branch with no version in it
      --python VERSION                     PYTHON_VERSION  default: recommended for the Frappe version
      --node MAJOR                         NODE_VERSION
      --apps LIST                          APPS            official apps, comma separated ("" = none)
      --custom-app URL                     CUSTOM_APPS     repeatable; space or comma separated in the file
      --app-branch APP=BRANCH              APP_BRANCHES    repeatable; comma separated in the file
      --bench-name NAME                    BENCH_NAME      created in $HOME
      --site NAME | --no-site              SITE_NAME / CREATE_SITE
      --site-apps LIST|all|none            SITE_APPS
      --dns-multitenant | --no-dns-multitenant   DNS_MULTITENANT   (production)
      --letsencrypt-email EMAIL            LETSENCRYPT_EMAIL (production, DNS multitenant)
      --user NAME                          FRAPPE_USER     owner of the bench when started as root

Passwords: at each password prompt type your own (hidden, asked twice, checked for strength) or press
Enter to generate a strong one. Unattended runs take them from the environment or the answers file,
never from flags (flags show up in the process list):
  DB_ROOT_PASSWORD       MariaDB root password
  ADMIN_PASSWORD         Administrator login of the new site
  FRAPPE_USER_PASSWORD   login password of the Linux user created when started as root
Other environment variables: FSS_LOG_DIR (log directory, default ~/frappe-setup-logs), NO_COLOR=1.

Display:
      --plain                        plain text prompts instead of dialog boxes (FSS_UI=plain)
      --tui                          always use dialog boxes when whiptail or dialog is installed
      --quiet                        one spinner line per command instead of its full output (FSS_QUIET=1);
                                     the full output still goes to the log

Example (unattended development install with ERPNext and HR):
  DB_ROOT_PASSWORD=... ADMIN_PASSWORD=... ./install.sh --yes --apps erpnext,hrms --site dev.localhost
EOF
}

ANSWER_KEYS=(MODE FRAPPE_BRANCH FRAPPE_MAJOR PYTHON_VERSION NODE_VERSION APPS CUSTOM_APPS APP_BRANCHES
	BENCH_NAME CREATE_SITE SITE_NAME SITE_APPS DNS_MULTITENANT LETSENCRYPT_EMAIL FRAPPE_USER)

# --------------------------------------------------------------------------
# Command line
# --------------------------------------------------------------------------
FSS_ARGS="$*"
ui_parse_flags "$@"; set -- "${FSS_REST_ARGS[@]}"
CONFIG_FILE='' RESUME=auto
need_value() { [[ $# -ge 2 ]] || die "Option $1 needs a value (see --help)."; }
while (($#)); do
	arg=$1
	if [[ "$arg" == --*=* ]]; then set -- "${arg%%=*}" "${arg#*=}" "${@:2}"; arg=$1; fi
	case "$arg" in
		-h|--help) usage; exit 0 ;;
		-y|--yes|--non-interactive) ASSUME_DEFAULTS=1 ;;
		-c|--config) need_value "$@"; CONFIG_FILE=$(realpath -- "$2") || die "Answers file not found: $2"; shift ;;
		--resume) RESUME=yes ;;
		--fresh|--no-resume) RESUME=no ;;
		--mode) need_value "$@"; set_answer MODE "$2"; shift ;;
		--frappe-branch) need_value "$@"; set_answer FRAPPE_BRANCH "$2"; shift ;;
		--frappe-major) need_value "$@"; set_answer FRAPPE_MAJOR "$2"; shift ;;
		--python) need_value "$@"; set_answer PYTHON_VERSION "$2"; shift ;;
		--node) need_value "$@"; set_answer NODE_VERSION "$2"; shift ;;
		--apps) need_value "$@"; set_answer APPS "$2"; shift ;;
		--custom-app) need_value "$@"; set_answer CUSTOM_APPS "${ANSWER[CUSTOM_APPS]:+${ANSWER[CUSTOM_APPS]} }$2"; shift ;;
		--app-branch) need_value "$@"; set_answer APP_BRANCHES "${ANSWER[APP_BRANCHES]:+${ANSWER[APP_BRANCHES]},}$2"; shift ;;
		--bench-name) need_value "$@"; set_answer BENCH_NAME "$2"; shift ;;
		--site) need_value "$@"; set_answer SITE_NAME "$2"; set_answer CREATE_SITE yes; shift ;;
		--no-site) set_answer CREATE_SITE no ;;
		--site-apps) need_value "$@"; set_answer SITE_APPS "$2"; shift ;;
		--dns-multitenant) set_answer DNS_MULTITENANT yes ;;
		--no-dns-multitenant) set_answer DNS_MULTITENANT no ;;
		--letsencrypt-email) need_value "$@"; set_answer LETSENCRYPT_EMAIL "$2"; shift ;;
		--user) need_value "$@"; set_answer FRAPPE_USER "$2"; shift ;;
		*) die "Unknown option: $arg (see --help)" ;;
	esac
	shift
done
[[ -n "$CONFIG_FILE" ]] && load_answers_file "$CONFIG_FILE" "${ANSWER_KEYS[@]}"
# A site name in the answers implies creating a site.
has_answer SITE_NAME && ! has_answer CREATE_SITE && set_answer CREATE_SITE yes

setup_logging install
ui_set_title "Frappe Setup Scripts · Installer"
header "Frappe installer"
require_supported_os
wsl_strip_windows_path
[[ "${ASSUME_DEFAULTS:-0}" == 1 ]] && info "Unattended mode: questions without a preset answer use their default."

# --------------------------------------------------------------------------
# Running as root: create (or pick) a regular user and continue as that user.
# --------------------------------------------------------------------------
if is_root; then
	warn "Frappe benches must not be owned by root."
	bootstrap_root_minimum
	if preset FRAPPE_USER "Linux user that will own the bench"; then
		msg=$(valid_username "$FRAPPE_USER") || die "FRAPPE_USER: $msg"
	else
		ask_valid FRAPPE_USER "Linux user that will own the bench (created if missing)" "${FRAPPE_USER:-frappe}" valid_username
	fi
	create_bench_user "$FRAPPE_USER"
	user_home=$(getent passwd "$FRAPPE_USER" | cut -d: -f6)
	dest="$user_home/Frappe-Setup-Scripts"
	if [[ "$SCRIPT_DIR" != "$dest" ]]; then
		rm -rf "$dest"
		cp -a "$SCRIPT_DIR" "$dest"
		chown -R "$FRAPPE_USER:" "$dest"
	fi

	# Hand the answers over in a file the user can read (the original may be root-only).
	child_args=()
	[[ "${ASSUME_DEFAULTS:-0}" == 1 ]] && child_args+=(--yes)
	[[ "$RESUME" == yes ]] && child_args+=(--resume)
	[[ "$RESUME" == no ]] && child_args+=(--fresh)
	answers_copy=''
	if ((${#ANSWER[@]})); then
		answers_copy="$dest/.answers-$$.conf"
		pairs=()
		for k in "${!ANSWER[@]}"; do [[ "$k" == FRAPPE_USER ]] || pairs+=("$k=${ANSWER[$k]}"); done
		save_answers "$answers_copy" "${pairs[@]}"
		chown "$FRAPPE_USER:" "$answers_copy"
		child_args+=(--config "$answers_copy")
	fi

	# Unattended: the user may have no password, so allow passwordless sudo for this run only.
	temp_sudoers=''
	# (Test real access: `bench setup sudoers` adds NOPASSWD rules for a few commands only.)
	if [[ "${ASSUME_DEFAULTS:-0}" == 1 ]] && ! sudo -u "$FRAPPE_USER" sudo -n true 2>/dev/null; then
		temp_sudoers="/etc/sudoers.d/zz-frappe-setup-$FRAPPE_USER"
		printf '# Temporary, removed when install.sh finishes\n%s ALL=(ALL:ALL) NOPASSWD: ALL\n' "$FRAPPE_USER" >"$temp_sudoers"
		chmod 440 "$temp_sudoers"
		info "Granted '$FRAPPE_USER' passwordless sudo for the duration of the install."
	fi
	# shellcheck disable=SC2329  # called from the EXIT trap
	cleanup_root_phase() {
		[[ -n "$temp_sudoers" ]] && rm -f "$temp_sudoers"
		[[ -n "$answers_copy" ]] && rm -f "$answers_copy"
		return 0
	}
	on_exit cleanup_root_phase

	export DB_ROOT_PASSWORD ADMIN_PASSWORD
	info "Continuing as '$FRAPPE_USER'$([[ -z "$temp_sudoers" ]] && echo " (sudo may ask for that user's password)")."
	rc=0
	# Leave a working directory the new user may not be able to read (e.g. /root).
	cd "$user_home"
	sudo -u "$FRAPPE_USER" -H \
		--preserve-env=ASSUME_DEFAULTS,DB_ROOT_PASSWORD,ADMIN_PASSWORD,NO_COLOR,FSS_LOG_DIR,FSS_FAIL_AFTER_STEP,FSS_UI,FSS_QUIET,TERM,WSL_DISTRO_NAME,FSS_SKIP_CHECKS,FSS_STRICT_CHECKS,FSS_GUARD,FSS_MIN_FREE_MB,FSS_MIN_MEM_MB,FSS_LOG_MAX_MB,FSS_CLEAN_CACHES \
		bash "$dest/install.sh" "${child_args[@]}" || rc=$?
	exit "$rc"
fi

ensure_sudo
# Stop cleanly before the disk (on WSL also the Windows drive) fills up or memory runs out.
resource_guard_start "$HOME"
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
	info "Installing git and curl first (needed to look up app versions)."
	bootstrap_root_minimum
fi

# --------------------------------------------------------------------------
# 0. Resume an unfinished install?
# --------------------------------------------------------------------------
# pending_installs: bench names whose install started but did not finish.
pending_installs() {
	local f n
	for f in "$FSS_STATE_DIR"/install-*.steps; do
		[[ -f "$f" ]] || continue
		grep -qx 'done complete' "$f" && continue
		n=${f##*/install-}; echo "${n%.steps}"
	done
	return 0
}

RESUMING=0
if [[ "$RESUME" != no ]]; then
	mapfile -t PENDING < <(pending_installs)
	cand=''
	if has_answer BENCH_NAME; then
		for p in "${PENDING[@]}"; do [[ "$p" == "${ANSWER[BENCH_NAME]}" ]] && cand=$p; done
	elif ((${#PENDING[@]} == 1)); then
		cand=${PENDING[0]}
	elif ((${#PENDING[@]} > 1)); then
		choose cand "Several installs did not finish. Resume which one?" 1 "${PENDING[@]}" "none|start a new install"
		[[ "$cand" == none ]] && cand=''
	fi
	if [[ -n "$cand" ]]; then
		last=$(last_done_step "$FSS_STATE_DIR/install-$cand.steps")
		if [[ "$RESUME" == yes ]] ||
			ask_yes_no "The install of ~/$cand did not finish (last finished step: ${last:-none}). Resume it?" y; then
			RESUMING=1
			load_answers_file "$(state_answers_file "install-$cand")" "${ANSWER_KEYS[@]}"
			info "Resuming the install of ~/$cand with its saved answers."
		fi
	elif [[ "$RESUME" == yes ]]; then
		die "There is no unfinished install to resume."
	fi
fi

# --------------------------------------------------------------------------
# 1. Questions
# --------------------------------------------------------------------------
header "1/6  Setup type"
preset MODE "Setup type" ||
	choose MODE "What kind of setup is this?" 1 \
		"development|bench start, developer mode, hot reload" \
		"production|nginx + supervisor, runs as background services"
expect_one_of MODE development production
if [[ "$MODE" == production ]] && ((IS_WSL)); then
	warn "Production on WSL is fine for testing, but WSL is not meant to host a public server."
fi

header "2/6  System check"
CREATE_SWAP=0
if ((RESUMING)); then
	info "Resuming an earlier install; checking only memory and free disk space."
	preflight_checks "$MODE" "$HOME" quick || die "Stopped after the system check."
else
	preflight_checks "$MODE" "$HOME" || die "Stopped after the system check."
	if wsl_offer_wslconfig; then
		if ask_yes_no "The limits apply after WSL restarts. Stop now, so you can run 'wsl --shutdown' in PowerShell and start the installer again?" y; then
			info "Run 'wsl --shutdown' in PowerShell (or cmd), reopen this distro, then run the same command again."
			exit 0
		fi
		warn "Continuing without the new limits; they apply after the next 'wsl --shutdown'."
	fi
fi
if ((!RESUMING)) && [[ "${ASSUME_DEFAULTS:-0}" != 1 ]] && swap_recommended; then
	ask_yes_no "This machine has little memory and no swap. Create a 4 GB swap file (/swapfile) so builds do not run out of memory?" y && CREATE_SWAP=1
fi

header "3/6  Frappe version"
info "Looking up Frappe release branches..."
mapfile -t RELEASES < <(frappe_release_branches 3)
((${#RELEASES[@]})) || RELEASES=(version-16 version-15 version-14)
if preset FRAPPE_BRANCH "Frappe version"; then
	[[ "$FRAPPE_BRANCH" == latest ]] && FRAPPE_BRANCH=${RELEASES[0]} && info "Latest stable is $FRAPPE_BRANCH."
	remote_ref_exists https://github.com/frappe/frappe "$FRAPPE_BRANCH" ||
		die "FRAPPE_BRANCH '$FRAPPE_BRANCH' was not found in frappe/frappe."
else
	version_opts=()
	for r in "${RELEASES[@]}"; do
		m=${r#version-}
		version_opts+=("$r|Frappe v$m  (Python $(python_for_major "$m"), Node $(node_for_major "$m"))")
	done
	version_opts[0]+="  latest stable"
	version_opts+=("develop|Unreleased development branch (unstable)" "custom|A specific branch or tag, e.g. v15.50.0")
	choose FRAPPE_BRANCH "Which Frappe version?" 1 "${version_opts[@]}"
	if [[ "$FRAPPE_BRANCH" == custom ]]; then
		ask_valid FRAPPE_BRANCH "Frappe branch or tag" "" valid_git_ref https://github.com/frappe/frappe
	fi
fi
FRAPPE_MAJOR=$(frappe_major_from_ref "$FRAPPE_BRANCH")
if [[ -z "$FRAPPE_MAJOR" ]]; then
	preset FRAPPE_MAJOR "Frappe major version" ||
		ask FRAPPE_MAJOR "Which Frappe major version is '$FRAPPE_BRANCH' (e.g. 15)?" "${RELEASES[0]#version-}"
fi
# App branches follow the release line, e.g. tag v15.50.0 -> apps on version-15.
APP_TARGET_BRANCH=$FRAPPE_BRANCH
[[ "$FRAPPE_MAJOR" =~ ^[0-9]+$ ]] && [[ "$FRAPPE_BRANCH" != version-* ]] && APP_TARGET_BRANCH="version-$FRAPPE_MAJOR"

PYTHON_VERSION=$(python_for_major "$FRAPPE_MAJOR")
NODE_VERSION=$(node_for_major "$FRAPPE_MAJOR")
if has_answer PYTHON_VERSION || has_answer NODE_VERSION; then
	preset PYTHON_VERSION "Python version" || true
	preset NODE_VERSION "Node.js major version" || true
elif ! ask_yes_no "Use Python $PYTHON_VERSION and Node $NODE_VERSION (recommended for this version)?" y; then
	ask_valid PYTHON_VERSION "Python version" "$PYTHON_VERSION" valid_python_version
	ask_valid NODE_VERSION "Node.js major version" "$NODE_VERSION" valid_node_version
fi
[[ "$PYTHON_VERSION" =~ ^3\.[0-9]+(\.[0-9]+)?$ ]] || die "Invalid Python version: $PYTHON_VERSION"
[[ "$NODE_VERSION" =~ ^[0-9]+$ ]] || die "Invalid Node.js major version: $NODE_VERSION"

header "4/6  Apps"
PICKED_APPS=()
if preset APPS "Official apps"; then
	mapfile -t PICKED_APPS < <(split_list "$APPS")
	for a in "${PICKED_APPS[@]}"; do
		app_in_catalog "$a" || die "Unknown official app '$a'. Known apps: $(catalog_names | tr '\n' ' ')(use CUSTOM_APPS / --custom-app for others)"
	done
else
	mapfile -t app_opts < <(catalog_menu_options)
	erp_idx=$(( $(catalog_names | grep -nx erpnext | cut -d: -f1) ))
	choose_multi PICKED_APPS "Which official apps should be installed? (Frappe itself is always installed)" "$erp_idx" "${app_opts[@]}"
fi
OFFICIAL_APPS=("${PICKED_APPS[@]}")

declare -A CUSTOM_APP_URL=()
CUSTOM_URLS=()
if preset CUSTOM_APPS "Custom app repositories"; then
	mapfile -t CUSTOM_URLS < <(split_list "$CUSTOM_APPS")
else
	while true; do
		ask_optional extra_url "Git URL of another (custom) app to add, blank to continue" ""
		[[ -z "$extra_url" ]] && break
		if ! msg=$(valid_git_url "$extra_url"); then ui_error "$msg"; continue; fi
		extra_name=$(basename "${extra_url%.git}")
		if [[ " ${PICKED_APPS[*]} " == *" $extra_name "* ]]; then ui_error "$extra_name is already selected."; continue; fi
		success "Added $extra_name."
		CUSTOM_URLS+=("$extra_url")
	done
fi
for u in "${CUSTOM_URLS[@]}"; do
	extra_name=$(basename "${u%.git}")
	CUSTOM_APP_URL[$extra_name]=$u
	PICKED_APPS+=("$extra_name")
done

mapfile -t APPS < <(resolve_app_deps "${PICKED_APPS[@]}")
for a in "${APPS[@]}"; do
	[[ " ${PICKED_APPS[*]} " == *" $a "* ]] || info "Adding ${C_BOLD}$a${C_RESET} (required by another selected app)."
done

declare -A APP_URL=() APP_BRANCH=()
if ((${#APPS[@]})); then
	info "Matching app branches to Frappe ${C_BOLD}$FRAPPE_BRANCH${C_RESET}..."
	for a in "${APPS[@]}"; do
		APP_URL[$a]=${CUSTOM_APP_URL[$a]:-$(app_repo "$a")}
		APP_BRANCH[$a]=$(pick_app_branch "${APP_URL[$a]}" "$APP_TARGET_BRANCH") ||
			die "Could not read branches of ${APP_URL[$a]} (network problem or private repo?)."
	done
	if has_answer APP_BRANCHES; then
		while IFS= read -r kv; do
			a=${kv%%=*} b=${kv#*=}
			[[ "$kv" == *=* && -n "$a" && -n "$b" ]] || die "APP_BRANCHES entries look like app=branch, got '$kv'."
			[[ -n "${APP_URL[$a]:-}" ]] || die "APP_BRANCHES names '$a', which is not one of the selected apps (${APPS[*]})."
			remote_ref_exists "${APP_URL[$a]}" "$b" || die "Branch or tag '$b' not found in ${APP_URL[$a]}."
			APP_BRANCH[$a]=$b
		done < <(split_list "${ANSWER[APP_BRANCHES]}")
	fi
	table=$(printf '   %-22s %-14s %s' APP BRANCH REPOSITORY)
	for a in "${APPS[@]}"; do
		flag=''
		[[ "${APP_BRANCH[$a]}" != "$APP_TARGET_BRANCH" ]] && flag=" ${C_YELLOW}(no $APP_TARGET_BRANCH branch)${C_RESET}"
		table+=$'\n'$(printf '   %-22s %-14s %s%s' "$a" "${APP_BRANCH[$a]}" "${APP_URL[$a]#https://github.com/}" "$flag")
	done
	ui_details "$table"
	if ! has_answer APP_BRANCHES && ! ask_yes_no "Use these branches?" y; then
		for a in "${APPS[@]}"; do
			mapfile -t bopts < <(app_branch_options "${APP_URL[$a]}")
			bopts+=("other|type a branch or tag")
			def=1
			for i in "${!bopts[@]}"; do [[ "${bopts[$i]}" == "${APP_BRANCH[$a]}" ]] && def=$((i + 1)); done
			choose pick "Branch for $a" "$def" "${bopts[@]}"
			if [[ "$pick" == other ]]; then
				ask_valid pick "Branch or tag for $a" "${APP_BRANCH[$a]}" valid_git_ref "${APP_URL[$a]}"
			fi
			APP_BRANCH[$a]=$pick
		done
	fi
fi

header "5/6  Bench"
if ! preset BENCH_NAME "Bench directory name"; then
	default_bench=frappe-bench
	n=2; while [[ -e "$HOME/$default_bench" ]]; do default_bench="frappe-bench-$n"; n=$((n + 1)); done
	ask_valid BENCH_NAME "Bench directory name (created in $HOME)" "$default_bench" valid_bench_name
fi
[[ "$BENCH_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || die "Invalid bench name: $BENCH_NAME"
BENCH_PATH="$HOME/$BENCH_NAME"
STATE_NAME="install-$BENCH_NAME"
if [[ -e "$BENCH_PATH" ]] && ((!RESUMING)); then
	if is_bench_dir "$BENCH_PATH"; then
		if grep -qxs 'done complete' "$FSS_STATE_DIR/$STATE_NAME.steps" && [[ "${ASSUME_DEFAULTS:-0}" == 1 ]]; then
			success "$BENCH_PATH was already installed by an earlier run; nothing to do."
			info "Use ./update-bench.sh to update it or ./manage-sites.sh to manage its sites."
			exit 0
		fi
		die "$BENCH_PATH already contains a bench. Use ./update-bench.sh or ./manage-sites.sh for it, or pick another name."
	fi
	die "$BENCH_PATH already exists and is not a bench. Pick another name."
fi
if [[ -e "$BENCH_PATH" ]] && ! is_bench_dir "$BENCH_PATH"; then
	die "$BENCH_PATH exists but is not a bench (left over from a failed 'bench init'?). Move it away and run ./install.sh again."
fi

# Generated passwords are written to this file as soon as they are generated, so a failed run
# does not lose them; a resumed run reads them back and keeps using them.
FSS_CRED_FILE="$HOME/.frappe-credentials/$BENCH_NAME.txt"
if ((RESUMING)); then
	load_generated_secrets "$FSS_CRED_FILE"
elif [[ -s "$FSS_CRED_FILE" ]]; then
	old_creds="$FSS_CRED_FILE.$(date +%Y%m%d-%H%M%S).old"
	mv "$FSS_CRED_FILE" "$old_creds"
	info "Kept the passwords of an earlier install of $BENCH_NAME in $old_creds."
fi

# MariaDB root password: asked now when MariaDB is not installed yet, so the install runs on its own.
if [[ -z "${DB_ROOT_PASSWORD:-}" ]] && ! command -v mariadb >/dev/null 2>&1 && ! command -v mysql >/dev/null 2>&1; then
	ask_new_password DB_ROOT_PASSWORD "MariaDB root password" DB_ROOT_PASSWORD 8
	export DB_ROOT_PASSWORD
fi

header "6/6  Site"
CREATE_SITE=0 SITE_NAME='' ADMIN_PW='' ADMIN_PASSWORD_KEPT=0 SITE_APPS=() DNS_MULTITENANT=0 LETSENCRYPT=0 LETSENCRYPT_EMAIL=''
if ask_bool_preset CREATE_SITE "Create a site now?" y; then
	CREATE_SITE=1
	if preset SITE_NAME "Site name"; then
		msg=$(valid_hostname_like "$SITE_NAME") || die "SITE_NAME: $msg"
	elif [[ "$MODE" == production ]]; then
		ask_valid SITE_NAME "Site name (use the domain name it will be served on, e.g. erp.example.com)" "$(hostname -f 2>/dev/null || cat /etc/hostname 2>/dev/null || echo site1.local)" valid_hostname_like
	else
		ask_valid SITE_NAME "Site name (*.localhost names open in the browser without editing hosts)" "site1.localhost" valid_hostname_like
	fi
	if ((RESUMING)) && grep -qxsF 'done site' "$FSS_STATE_DIR/$STATE_NAME.steps"; then
		info "$SITE_NAME was created by the earlier run; its Administrator password stays as it was."
		generated_secret "Administrator password for $SITE_NAME" >/dev/null || ADMIN_PASSWORD_KEPT=1
	else
		ask_new_password ADMIN_PW "Administrator password for $SITE_NAME" ADMIN_PASSWORD \
			"$([[ "$MODE" == production ]] && echo 8 || echo 4)" "$SITE_NAME" "${SITE_NAME%%.*}"
	fi
	if ((${#APPS[@]})); then
		if preset SITE_APPS "Apps to install on $SITE_NAME"; then
			case "${ANSWER[SITE_APPS],,}" in
				all) SITE_APPS=("${APPS[@]}") ;;
				none|'') SITE_APPS=() ;;
				*)
					mapfile -t SITE_APPS < <(split_list "${ANSWER[SITE_APPS]}")
					for a in "${SITE_APPS[@]}"; do
						[[ " ${APPS[*]} " == *" $a "* ]] || die "SITE_APPS names '$a', which is not one of the bench's apps (${APPS[*]})."
					done
					;;
			esac
		else
			mapfile -t site_app_opts < <(printf '%s\n' "${APPS[@]}")
			choose_multi SITE_APPS "Install which apps on $SITE_NAME?" "a" "${site_app_opts[@]}"
		fi
		mapfile -t SITE_APPS < <(resolve_app_deps "${SITE_APPS[@]}")
	fi
	if [[ "$MODE" == production ]]; then
		if [[ "$SITE_NAME" == *.* && "$SITE_NAME" != *.localhost && "$SITE_NAME" != *.local ]]; then
			ask_bool_preset DNS_MULTITENANT "Serve sites by domain name (DNS multitenancy, recommended)?" y && DNS_MULTITENANT=1
			if ((DNS_MULTITENANT)); then
				if preset LETSENCRYPT_EMAIL "Let's Encrypt email"; then
					[[ -n "$LETSENCRYPT_EMAIL" ]] && LETSENCRYPT=1
				elif ask_yes_no "Get a free HTTPS certificate from Let's Encrypt now (DNS must already point here)?" n; then
					LETSENCRYPT=1
					ask_valid LETSENCRYPT_EMAIL "Email for Let's Encrypt expiry notices" "" valid_email
				fi
				if ((LETSENCRYPT)); then _PF_RESULTS=(); pf_check_dns "$SITE_NAME"; preflight_report || true; fi
			fi
		fi
	fi
fi

# --------------------------------------------------------------------------
# 2. Summary
# --------------------------------------------------------------------------
header "Summary"
WSL_NOTE=''; ((IS_WSL)) && WSL_NOTE=', WSL'
summary=$(
	printf '   %-18s %s\n' "System" "$OS_PRETTY ($ARCH${WSL_NOTE})"
	printf '   %-18s %s\n' "Mode" "$MODE"
	printf '   %-18s %s\n' "Frappe" "$FRAPPE_BRANCH"
	printf '   %-18s %s\n' "Python / Node" "$PYTHON_VERSION / $NODE_VERSION"
	printf '   %-18s %s\n' "Bench" "$BENCH_PATH"
	if ((${#APPS[@]})); then
		for a in "${APPS[@]}"; do printf '   %-18s %s @ %s\n' "App" "$a" "${APP_BRANCH[$a]}"; done
	fi
	if ((CREATE_SITE)); then
		printf '   %-18s %s\n' "Site" "$SITE_NAME"
		printf '   %-18s %s\n' "Site apps" "${SITE_APPS[*]:-(frappe only)}"
		((DNS_MULTITENANT)) && printf '   %-18s %s\n' "DNS multitenant" "on"
		((LETSENCRYPT)) && printf '   %-18s %s\n' "HTTPS" "Let's Encrypt ($LETSENCRYPT_EMAIL)"
	fi
	((RESUMING)) && printf '   %-18s %s\n' "Resuming" "after step '$(last_done_step "$FSS_STATE_DIR/$STATE_NAME.steps")'"
	((CREATE_SWAP)) && printf '   %-18s %s\n' "Swap" "create a 4 GB /swapfile"
	printf '   %-18s %s\n' "Output" "$( [[ "${FSS_QUIET:-0}" == 1 ]] && echo 'compact (full output in the log)' || echo 'full')"
)
ui_details "$summary"
ask_yes_no "Start the installation? It usually takes 10 to 30 minutes." y || die "Cancelled."

# Record the answers so an interrupted run can be resumed with exactly the same choices.
((RESUMING)) || rm -f "$FSS_STATE_DIR/$STATE_NAME.steps"
state_use "$STATE_NAME"
branch_pairs=()
for a in "${APPS[@]}"; do branch_pairs+=("$a=${APP_BRANCH[$a]}"); done
save_answers "$(state_answers_file "$STATE_NAME")" \
	"MODE=$MODE" "FRAPPE_BRANCH=$FRAPPE_BRANCH" "FRAPPE_MAJOR=$FRAPPE_MAJOR" \
	"PYTHON_VERSION=$PYTHON_VERSION" "NODE_VERSION=$NODE_VERSION" \
	"APPS=$(IFS=,; echo "${OFFICIAL_APPS[*]}")" "CUSTOM_APPS=${CUSTOM_URLS[*]}" \
	"APP_BRANCHES=$(IFS=,; echo "${branch_pairs[*]}")" "BENCH_NAME=$BENCH_NAME" \
	"CREATE_SITE=$CREATE_SITE" "SITE_NAME=$SITE_NAME" "SITE_APPS=$( ((${#SITE_APPS[@]})) && (IFS=,; echo "${SITE_APPS[*]}") || echo none)" \
	"DNS_MULTITENANT=$DNS_MULTITENANT" "LETSENCRYPT_EMAIL=$LETSENCRYPT_EMAIL"

# --------------------------------------------------------------------------
# 3. Install
# Each step is recorded when it finishes; a re-run skips finished steps. Quick, idempotent
# steps (MariaDB password check, Python/Node/bench tools, config) always run.
# --------------------------------------------------------------------------
START_TS=$(date +%s)

# Each function below is one numbered entry of the progress display. Inside them, `step`
# records finished work so a re-run skips it; quick, idempotent parts always run.
do_packages() { step packages "system packages" install_base_packages "$MODE"; }
do_swap() { step swap "swap file" create_swapfile 4; }
do_mariadb() {
	if step_is_done mariadb; then
		start_mariadb
	else
		install_mariadb_server
		mark_step_done mariadb
	fi
	configure_mariadb_root DB_ROOT_PW
}
do_python() { install_uv; PYTHON_BIN=$(install_python "$PYTHON_VERSION"); }
do_bench_cli() { install_bench_cli; persist_shell_env; }

bench_init() {
	if is_bench_dir "$BENCH_PATH" && [[ -x "$BENCH_PATH/env/bin/python" ]]; then
		info "$BENCH_PATH already exists; keeping it."
		return 0
	fi
	local init_args=(init --frappe-branch "$FRAPPE_BRANCH" --python "$PYTHON_BIN")
	if [[ "$MODE" == development ]] && bench init --help 2>/dev/null | grep -q -- '--dev'; then
		init_args+=(--dev)
	fi
	# Assets are built once, after all apps are fetched.
	init_args+=(--skip-assets)
	( cd "$HOME" && run bench "${init_args[@]}" "$BENCH_NAME" ) || true
	# bench exits 0 even after rolling back a failed init, so check the result explicitly.
	if ! is_bench_dir "$BENCH_PATH" || [[ ! -x "$BENCH_PATH/env/bin/python" ]]; then
		die "bench init failed (see the output above). Fix the problem and run ./install.sh again."
	fi
}
do_bench_init() {
	step bench-init "bench init" bench_init
	echo "$NODE_VERSION" >"$BENCH_PATH/.nvmrc"
	use_node_for_bench "$BENCH_PATH"
	ensure_bench_redis "$BENCH_PATH"
	cat >"$BENCH_PATH/.frappe-setup.env" <<ENV
# Written by Frappe-Setup-Scripts
MODE=$MODE
FRAPPE_BRANCH=$FRAPPE_BRANCH
PYTHON_VERSION=$PYTHON_VERSION
NODE_VERSION=$NODE_VERSION
ENV
}

# rename_site_app <repo-name> <real-name>: a custom app's real name can differ from its repository.
rename_site_app() {
	local i
	[[ "$1" == "$2" ]] && return 0
	for i in "${!SITE_APPS[@]}"; do [[ "${SITE_APPS[$i]}" == "$1" ]] && SITE_APPS[i]=$2; done
	return 0
}
do_get_app() {
	local a=$1 before added
	if step_is_done "app-$a"; then
		info "Skipping: get app $a (done in an earlier run)"
		rename_site_app "$a" "$(state_get "appname-$a")"
		return 0
	fi
	if bench_apps "$BENCH_PATH" | grep -qxF "$a"; then
		info "App $a is already in the bench."
		added=$a
	else
		before=$(bench_apps "$BENCH_PATH" | sort)
		with_bench "$BENCH_PATH" get-app --skip-assets --branch "${APP_BRANCH[$a]}" "${APP_URL[$a]}" || true
		added=$(comm -13 <(echo "$before") <(bench_apps "$BENCH_PATH" | sort) | grep -vx frappe | tail -1 || true)
		if [[ -z "$added" ]]; then
			die "Getting $a failed (see the output above). Fix the problem and run ./install.sh again to continue."
		fi
		[[ "$added" != "$a" ]] && info "App from ${APP_URL[$a]} is named '$added'."
	fi
	rename_site_app "$a" "$added"
	state_set "appname-$a" "$added"
	mark_step_done "app-$a"
}

build_assets() {
	[[ "$MODE" == production ]] && export NODE_ENV=production
	with_bench "$BENCH_PATH" build
}
do_build() {
	step build "build assets" build_assets
	if [[ "$MODE" == development ]]; then
		with_bench "$BENCH_PATH" set-config -g developer_mode 1
	fi
	((DNS_MULTITENANT)) && with_bench "$BENCH_PATH" config dns_multitenant on
	return 0
}

create_site() {
	local site_args=(new-site "$SITE_NAME" --admin-password "$ADMIN_PW" --db-root-password "$DB_ROOT_PW")
	# A site left over from an interrupted run is recreated from scratch.
	if [[ -f "$BENCH_PATH/sites/$SITE_NAME/site_config.json" ]]; then
		warn "Site $SITE_NAME exists from an earlier, unfinished run; recreating it."
		site_args+=(--force)
	fi
	local a
	for a in "${SITE_APPS[@]}"; do site_args+=(--install-app "$a"); done
	with_bench "$BENCH_PATH" "${site_args[@]}"
	check_site_apps "$BENCH_PATH" "$SITE_NAME" "${SITE_APPS[@]}" || true
	with_bench "$BENCH_PATH" use "$SITE_NAME"
	if [[ "$MODE" == development ]]; then
		with_bench "$BENCH_PATH" --site "$SITE_NAME" set-config developer_mode 1
		with_bench "$BENCH_PATH" --site "$SITE_NAME" clear-cache
	fi
}
do_site() { step site "create site $SITE_NAME" create_site; }

do_production() {
	with_bench "$BENCH_PATH" set-config -g developer_mode 0 || true
	step production "production setup (nginx + supervisor)" setup_production "$BENCH_PATH"
}

HTTPS_OK=0
setup_letsencrypt() {
	pkg_install certbot
	if ( cd "$BENCH_PATH" && run as_root env "PATH=$PATH" "$(command -v bench)" setup lets-encrypt "$SITE_NAME" ); then
		HTTPS_OK=1
	else
		warn "Let's Encrypt failed. Fix DNS and retry with: cd $BENCH_PATH && sudo env PATH=\$PATH bench setup lets-encrypt $SITE_NAME"
	fi
}
do_https() {
	if step_is_done letsencrypt; then HTTPS_OK=1; fi
	step letsencrypt "Let's Encrypt" setup_letsencrypt
}

PLAN=()
((CREATE_SWAP)) && PLAN+=("Swap file|do_swap")
PLAN+=(
	"System packages|do_packages"
	"MariaDB|do_mariadb"
	"wkhtmltopdf (PDF)|install_wkhtmltopdf"
	"Python $PYTHON_VERSION|do_python"
	"Node.js $NODE_VERSION|install_node $NODE_VERSION"
	"bench CLI|do_bench_cli"
	"Bench $BENCH_NAME (frappe @ $FRAPPE_BRANCH)|do_bench_init"
)
for a in "${APPS[@]}"; do PLAN+=("App $a @ ${APP_BRANCH[$a]}|do_get_app $a"); done
PLAN+=("Building assets|do_build")
((CREATE_SITE)) && PLAN+=("Site $SITE_NAME|do_site")
[[ "$MODE" == production ]] && PLAN+=("Production (nginx + supervisor)|do_production")
((LETSENCRYPT)) && PLAN+=("HTTPS for $SITE_NAME|do_https")
# Download caches (yarn, uv, npm, packages) take several GB. On WSL that space is taken from the
# Windows drive for good, so they are removed by default there (FSS_CLEAN_CACHES=0 keeps them).
if [[ "${FSS_CLEAN_CACHES:-$IS_WSL}" == 1 ]]; then PLAN+=("Clean up download caches|clean_download_caches"); fi

phase_plan "${#PLAN[@]}"
for entry in "${PLAN[@]}"; do
	read -ra cmd <<<"${entry#*|}"
	phase "${entry%%|*}" "${cmd[@]}"
	# WSL: hand the file cache of the step back to Windows instead of letting it pile up.
	wsl_drop_caches
done

wsl_offer_systemd
mark_step_done complete

# --------------------------------------------------------------------------
# 4. Done
# --------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START_TS ))
ui_set_title "Frappe Setup Scripts"

# Where to open the site
URLS=()
if ((CREATE_SITE)); then
	if [[ "$MODE" == development ]]; then
		URLS+=("http://$SITE_NAME:8000")
	else
		scheme=http; ((HTTPS_OK)) && scheme=https
		URLS+=("$scheme://$SITE_NAME")
		if ((!DNS_MULTITENANT)); then
			for ip in $(hostname -I 2>/dev/null); do
				[[ "$ip" == *:* ]] || URLS+=("http://$ip")
			done
		fi
	fi
fi

# Generated passwords: saved to a private file and shown once on the terminal (never in the log).
CRED_FILE=''
if ((${#FSS_GENERATED_SECRETS[@]})); then
	CRED_FILE=$FSS_CRED_FILE
	save_generated_secrets "$CRED_FILE" || CRED_FILE=''
fi
secret_note() { # secret_note <label>
	if generated_secret "$1" >/dev/null; then echo "(generated, see below)"
	elif [[ "$1" == Administrator* && "${ADMIN_PASSWORD_KEPT:-0}" == 1 ]]; then echo "(set in the earlier run)"
	else echo "(the password you entered)"
	fi
}

info "Step timings:"
phase_report | sed 's/^/     /' >&2

box=()
box+=("$(kv Bench "$BENCH_PATH")")
box+=("$(kv Frappe "$FRAPPE_BRANCH  (Python $PYTHON_VERSION, Node $NODE_VERSION)")")
box+=("$(kv Apps "$(bench_apps "$BENCH_PATH" | tr '\n' ' ')")")
if ((CREATE_SITE)); then
	box+=("")
	box+=("$(kv Site "$SITE_NAME")")
	for u in "${URLS[@]}"; do box+=("$(kv Open "${C_BOLD}$u${C_RESET}")"); done
	box+=("$(kv Login "Administrator  $(secret_note "Administrator password for $SITE_NAME")")")
fi
box+=("$(kv MariaDB "root  $(secret_note "MariaDB root password")")")
box+=("")
if [[ "$MODE" == development ]]; then
	box+=("Start the development server:")
	box+=("  ${C_BOLD}source ~/.bashrc${C_RESET}")
	box+=("  ${C_BOLD}cd $BENCH_PATH && bench start${C_RESET}")
	if ((CREATE_SITE)) && [[ "$SITE_NAME" != *.localhost ]]; then
		box+=("  Add '127.0.0.1 $SITE_NAME' to your hosts file,")
		box+=("  or run: bench --site $SITE_NAME add-to-hosts")
	fi
else
	box+=("Services run under supervisor:  ${C_BOLD}sudo supervisorctl status${C_RESET}")
	((LETSENCRYPT && !HTTPS_OK)) && box+=("${C_YELLOW}HTTPS is not set up yet${C_RESET}: fix DNS, then use manage-sites.sh > https")
fi
box+=("")
box+=("$(kv Sites "$SCRIPT_DIR/manage-sites.sh")")
box+=("$(kv Update "$SCRIPT_DIR/update-bench.sh")")
box+=("$(kv Log "$FSS_LOG_FILE")")
ui_box "Frappe is ready  ·  $(fmt_duration "$ELAPSED")" "${box[@]}"

if [[ -n "$CRED_FILE" ]] && ! _ui_has_tty; then
	warn "Generated passwords are saved in $CRED_FILE (only you can read it)."
elif [[ -n "$CRED_FILE" ]]; then
	{
		printf '\n%s%s%s\n' "${C_YELLOW}${C_BOLD}" "Generated passwords (shown once, not written to the log):" "${C_RESET}"
		for e in "${FSS_GENERATED_SECRETS[@]}"; do printf '   %-44s %s%s%s\n' "${e%%|*}" "${C_BOLD}" "${e#*|}" "${C_RESET}"; done
		printf '   %sAlso saved in %s (only you can read it).%s\n' "${C_DIM}" "$CRED_FILE" "${C_RESET}"
		printf '   %sStore them in a password manager, then delete that file.%s\n' "${C_DIM}" "${C_RESET}"
	} >/dev/tty
	echo "   Generated passwords were shown on the terminal and saved in $CRED_FILE." >>"$FSS_LOG_FILE"
fi
success "Frappe is installed."
