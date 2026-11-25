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

Secrets come from the environment or the answers file, never from flags:
  DB_ROOT_PASSWORD, ADMIN_PASSWORD, FRAPPE_USER_PASSWORD
Other environment variables: FSS_LOG_DIR (log directory, default ~/frappe-setup-logs), NO_COLOR=1.

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
header "Frappe installer"
require_supported_os
[[ "${ASSUME_DEFAULTS:-0}" == 1 ]] && info "Unattended mode: questions without a preset answer use their default."

# --------------------------------------------------------------------------
# Running as root: create (or pick) a regular user and continue as that user.
# --------------------------------------------------------------------------
if is_root; then
	warn "Frappe benches must not be owned by root."
	bootstrap_root_minimum
	preset FRAPPE_USER "Linux user that will own the bench" ||
		ask FRAPPE_USER "Linux user that will own the bench (created if missing)" "${FRAPPE_USER:-frappe}"
	[[ "$FRAPPE_USER" == root ]] && die "Choose a non-root user."
	[[ "$FRAPPE_USER" =~ ^[a-z_][a-z0-9_-]*$ ]] || die "Invalid user name: $FRAPPE_USER"
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
	sudo -u "$FRAPPE_USER" -H \
		--preserve-env=ASSUME_DEFAULTS,DB_ROOT_PASSWORD,ADMIN_PASSWORD,NO_COLOR,FSS_LOG_DIR,FSS_FAIL_AFTER_STEP \
		bash "$dest/install.sh" "${child_args[@]}" || rc=$?
	exit "$rc"
fi

ensure_sudo
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
header "1/5  Setup type"
preset MODE "Setup type" ||
	choose MODE "What kind of setup is this?" 1 \
		"development|bench start, developer mode, hot reload" \
		"production|nginx + supervisor, runs as background services"
expect_one_of MODE development production
if [[ "$MODE" == production ]] && ((IS_WSL)); then
	warn "Production on WSL is fine for testing, but WSL is not meant to host a public server."
fi

header "2/5  Frappe version"
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
		while true; do
			ask FRAPPE_BRANCH "Frappe branch or tag"
			remote_ref_exists https://github.com/frappe/frappe "$FRAPPE_BRANCH" && break
			warn "'$FRAPPE_BRANCH' was not found in frappe/frappe."
		done
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
	ask PYTHON_VERSION "Python version" "$PYTHON_VERSION"
	ask NODE_VERSION "Node.js major version" "$NODE_VERSION"
fi
[[ "$PYTHON_VERSION" =~ ^3\.[0-9]+(\.[0-9]+)?$ ]] || die "Invalid Python version: $PYTHON_VERSION"
[[ "$NODE_VERSION" =~ ^[0-9]+$ ]] || die "Invalid Node.js major version: $NODE_VERSION"

header "3/5  Apps"
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
	printf '\n   %-24s %-16s %s\n' APP BRANCH REPOSITORY >&2
	for a in "${APPS[@]}"; do
		flag=''
		[[ "${APP_BRANCH[$a]}" != "$APP_TARGET_BRANCH" ]] && flag=" ${C_YELLOW}(no $APP_TARGET_BRANCH branch)${C_RESET}"
		printf '   %-24s %-16s %s%s\n' "$a" "${APP_BRANCH[$a]}" "${APP_URL[$a]}" "$flag" >&2
	done
	echo >&2
	if ! has_answer APP_BRANCHES && ! ask_yes_no "Use these branches?" y; then
		for a in "${APPS[@]}"; do
			mapfile -t bopts < <(app_branch_options "${APP_URL[$a]}")
			bopts+=("other|type a branch or tag")
			def=1
			for i in "${!bopts[@]}"; do [[ "${bopts[$i]}" == "${APP_BRANCH[$a]}" ]] && def=$((i + 1)); done
			choose pick "Branch for $a" "$def" "${bopts[@]}"
			if [[ "$pick" == other ]]; then
				while true; do
					ask pick "Branch or tag for $a" "${APP_BRANCH[$a]}"
					remote_ref_exists "${APP_URL[$a]}" "$pick" && break
					warn "'$pick' not found in ${APP_URL[$a]}."
				done
			fi
			APP_BRANCH[$a]=$pick
		done
	fi
fi

header "4/5  Bench"
preset BENCH_NAME "Bench directory name" ||
	ask BENCH_NAME "Bench directory name (created in $HOME)" "frappe-bench"
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

header "5/5  Site"
CREATE_SITE=0 SITE_NAME='' ADMIN_PW='' SITE_APPS=() DNS_MULTITENANT=0 LETSENCRYPT=0 LETSENCRYPT_EMAIL=''
if ask_bool_preset CREATE_SITE "Create a site now?" y; then
	CREATE_SITE=1
	if [[ "$MODE" == production ]]; then
		preset SITE_NAME "Site name" ||
			ask SITE_NAME "Site name (use the domain name it will be served on, e.g. erp.example.com)" "$(hostname -f 2>/dev/null || cat /etc/hostname 2>/dev/null || echo site1.local)"
	else
		preset SITE_NAME "Site name" ||
			ask SITE_NAME "Site name (*.localhost names open in the browser without editing hosts)" "site1.localhost"
	fi
	[[ "$SITE_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Invalid site name: $SITE_NAME"
	ask_secret ADMIN_PW "Administrator password for $SITE_NAME" yes ADMIN_PASSWORD
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
					ask LETSENCRYPT_EMAIL "Email for Let's Encrypt expiry notices"
				fi
			fi
		fi
	fi
fi

# --------------------------------------------------------------------------
# 2. Summary
# --------------------------------------------------------------------------
header "Summary"
{
	printf '   %-18s %s\n' "System" "$OS_PRETTY ($ARCH$( ((IS_WSL)) && printf ', WSL'))"
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
} >&2
echo >&2
ask_yes_no "Start the installation?" y || die "Cancelled."

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

step packages "system packages" install_base_packages "$MODE"
if step_is_done mariadb; then
	start_mariadb
else
	install_mariadb_server
	mark_step_done mariadb
fi
configure_mariadb_root DB_ROOT_PW
install_wkhtmltopdf
install_uv
PYTHON_BIN=$(install_python "$PYTHON_VERSION")
install_node "$NODE_VERSION"
install_bench_cli
persist_shell_env

bench_init() {
	if is_bench_dir "$BENCH_PATH" && [[ -x "$BENCH_PATH/env/bin/python" ]]; then
		info "$BENCH_PATH already exists; keeping it."
		return 0
	fi
	header "Creating bench $BENCH_NAME (frappe @ $FRAPPE_BRANCH)"
	local init_args=(init --frappe-branch "$FRAPPE_BRANCH" --python "$PYTHON_BIN")
	if [[ "$MODE" == development ]] && bench init --help 2>/dev/null | grep -q -- '--dev'; then
		init_args+=(--dev)
	fi
	# Assets are built once, after all apps are fetched.
	init_args+=(--skip-assets)
	( cd "$HOME" && run bench "${init_args[@]}" "$BENCH_NAME" ) || true
	# bench exits 0 even after rolling back a failed init, so check the result explicitly.
	is_bench_dir "$BENCH_PATH" && [[ -x "$BENCH_PATH/env/bin/python" ]] ||
		die "bench init failed (see the output above). Fix the problem and run ./install.sh again."
}
step bench-init "bench init" bench_init
echo "$NODE_VERSION" >"$BENCH_PATH/.nvmrc"
use_node_for_bench "$BENCH_PATH"
ensure_bench_redis "$BENCH_PATH"
cat >"$BENCH_PATH/.frappe-setup.env" <<EOF
# Written by Frappe-Setup-Scripts
MODE=$MODE
FRAPPE_BRANCH=$FRAPPE_BRANCH
PYTHON_VERSION=$PYTHON_VERSION
NODE_VERSION=$NODE_VERSION
EOF

# rename_site_app <repo-name> <real-name>: a custom app's real name can differ from its repository.
rename_site_app() {
	local i
	[[ "$1" == "$2" ]] && return 0
	for i in "${!SITE_APPS[@]}"; do [[ "${SITE_APPS[$i]}" == "$1" ]] && SITE_APPS[i]=$2; done
	return 0
}
for a in "${APPS[@]}"; do
	if step_is_done "app-$a"; then
		info "Skipping: get app $a (done in an earlier run)"
		rename_site_app "$a" "$(state_get "appname-$a")"
		continue
	fi
	if bench_apps "$BENCH_PATH" | grep -qxF "$a"; then
		info "App $a is already in the bench."
		added=$a
	else
		header "Getting app $a @ ${APP_BRANCH[$a]}"
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
done

build_assets() {
	header "Building assets"
	[[ "$MODE" == production ]] && export NODE_ENV=production
	with_bench "$BENCH_PATH" build
}
step build "build assets" build_assets

if [[ "$MODE" == development ]]; then
	with_bench "$BENCH_PATH" set-config -g developer_mode 1
fi
((DNS_MULTITENANT)) && with_bench "$BENCH_PATH" config dns_multitenant on

create_site() {
	header "Creating site $SITE_NAME"
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
((CREATE_SITE)) && step site "create site $SITE_NAME" create_site

if [[ "$MODE" == production ]]; then
	with_bench "$BENCH_PATH" set-config -g developer_mode 0 || true
	step production "production setup (nginx + supervisor)" setup_production "$BENCH_PATH"
	setup_letsencrypt() {
		header "Setting up HTTPS for $SITE_NAME"
		pkg_install certbot
		( cd "$BENCH_PATH" && run as_root env "PATH=$PATH" "$(command -v bench)" setup lets-encrypt "$SITE_NAME" ) ||
			warn "Let's Encrypt failed. Fix DNS and retry with: cd $BENCH_PATH && sudo env PATH=\$PATH bench setup lets-encrypt $SITE_NAME"
	}
	((LETSENCRYPT)) && step letsencrypt "Let's Encrypt" setup_letsencrypt
fi

wsl_offer_systemd
mark_step_done complete

# --------------------------------------------------------------------------
# 4. Done
# --------------------------------------------------------------------------
ELAPSED=$(( $(date +%s) - START_TS ))
header "Done in $((ELAPSED / 60))m $((ELAPSED % 60))s"
{
	echo "   Bench:   $BENCH_PATH"
	echo "   Apps:    $(bench_apps "$BENCH_PATH" | tr '\n' ' ')"
	if ((CREATE_SITE)); then
		echo "   Site:    $SITE_NAME  (login: Administrator)"
	fi
	echo
	if [[ "$MODE" == development ]]; then
		echo "   Start the development server:"
		echo "     source ~/.bashrc"
		echo "     cd $BENCH_PATH && nvm use && bench start"
		((CREATE_SITE)) && echo "   Then open http://$SITE_NAME:8000"
		[[ "$SITE_NAME" == *.localhost ]] || { ((CREATE_SITE)) && echo "   (add '127.0.0.1 $SITE_NAME' to your hosts file, or run: bench --site $SITE_NAME add-to-hosts)"; }
	else
		echo "   Services are managed by supervisor (sudo supervisorctl status)."
		((CREATE_SITE)) && echo "   Open http$( ((LETSENCRYPT)) && printf s)://$SITE_NAME"
	fi
	echo
	echo "   Manage sites:     $SCRIPT_DIR/manage-sites.sh"
	echo "   Update the bench: $SCRIPT_DIR/update-bench.sh"
	echo "   Log file:         $FSS_LOG_FILE"
} >&2
success "Frappe is installed."
