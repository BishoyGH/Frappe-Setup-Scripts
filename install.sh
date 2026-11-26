#!/usr/bin/env bash
# Interactive installer for the Frappe framework and official Frappe apps.
# Supports Ubuntu, Debian and Arch Linux (bare metal, VM or WSL), development or production setups.
#
# Usage: ./install.sh [--plain] [--quiet]     (interactive)
#        ASSUME_DEFAULTS=1 DB_ROOT_PASSWORD=... ADMIN_PASSWORD=... ./install.sh   (accept all defaults)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/prereqs.sh
. "$SCRIPT_DIR/lib/prereqs.sh"
# shellcheck source=lib/apps.sh
. "$SCRIPT_DIR/lib/apps.sh"
# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"
strict_mode
ui_parse_flags "$@"; set -- "${FSS_ARGS[@]}"

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
	sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
	echo; ui_flags_help
	exit 0
fi

ui_set_title "Frappe Setup Scripts · Installer"
header "Frappe installer"
require_supported_os

# --------------------------------------------------------------------------
# Running as root: create (or pick) a regular user and continue as that user.
# --------------------------------------------------------------------------
if is_root; then
	warn "Frappe benches must not be owned by root."
	bootstrap_root_minimum
	ask_valid FRAPPE_USER "Linux user that will own the bench (created if missing)" "${FRAPPE_USER:-frappe}" valid_username
	create_bench_user "$FRAPPE_USER"
	user_home=$(getent passwd "$FRAPPE_USER" | cut -d: -f6)
	dest="$user_home/Frappe-Setup-Scripts"
	if [[ "$SCRIPT_DIR" != "$dest" ]]; then
		rm -rf "$dest"
		cp -a "$SCRIPT_DIR" "$dest"
		chown -R "$FRAPPE_USER:" "$dest"
	fi
	info "Continuing as '$FRAPPE_USER' (sudo will ask for that user's password)."
	exec sudo -u "$FRAPPE_USER" -H \
		--preserve-env=ASSUME_DEFAULTS,DB_ROOT_PASSWORD,ADMIN_PASSWORD,NO_COLOR,FSS_UI,FSS_QUIET,TERM \
		bash "$dest/install.sh" "$@"
fi

ensure_sudo
if ! command -v git >/dev/null 2>&1 || ! command -v curl >/dev/null 2>&1; then
	info "Installing git and curl first (needed to look up app versions)."
	bootstrap_root_minimum
fi

# --------------------------------------------------------------------------
# 1. Questions
# --------------------------------------------------------------------------
header "1/6  Setup type"
choose MODE "What kind of setup is this?" 1 \
	"development|bench start, developer mode, hot reload" \
	"production|nginx + supervisor, runs as background services"
if [[ "$MODE" == production ]] && ((IS_WSL)); then
	warn "Production on WSL is fine for testing, but WSL is not meant to host a public server."
fi

header "2/6  System check"
preflight_checks "$MODE" "$HOME" || die "Stopped after the system check."
CREATE_SWAP=0
if swap_recommended; then
	ask_yes_no "This machine has little memory and no swap. Create a 4 GB swap file (/swapfile) so builds do not run out of memory?" y && CREATE_SWAP=1
fi

header "3/6  Frappe version"
info "Looking up Frappe release branches..."
mapfile -t RELEASES < <(frappe_release_branches | head -3)
((${#RELEASES[@]})) || RELEASES=(version-16 version-15 version-14)
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
FRAPPE_MAJOR=$(frappe_major_from_ref "$FRAPPE_BRANCH")
if [[ -z "$FRAPPE_MAJOR" ]]; then
	ask FRAPPE_MAJOR "Which Frappe major version is '$FRAPPE_BRANCH' (e.g. 15)?" "${RELEASES[0]#version-}"
fi
# App branches follow the release line, e.g. tag v15.50.0 -> apps on version-15.
APP_TARGET_BRANCH=$FRAPPE_BRANCH
[[ "$FRAPPE_MAJOR" =~ ^[0-9]+$ ]] && [[ "$FRAPPE_BRANCH" != version-* ]] && APP_TARGET_BRANCH="version-$FRAPPE_MAJOR"

PYTHON_VERSION=$(python_for_major "$FRAPPE_MAJOR")
NODE_VERSION=$(node_for_major "$FRAPPE_MAJOR")
if ! ask_yes_no "Use Python $PYTHON_VERSION and Node $NODE_VERSION (recommended for this version)?" y; then
	ask_valid PYTHON_VERSION "Python version" "$PYTHON_VERSION" valid_python_version
	ask_valid NODE_VERSION "Node.js major version" "$NODE_VERSION" valid_node_version
fi

header "4/6  Apps"
mapfile -t app_opts < <(catalog_menu_options)
erp_idx=$(( $(catalog_names | grep -nx erpnext | cut -d: -f1) ))
choose_multi PICKED_APPS "Which official apps should be installed? (Frappe itself is always installed)" "$erp_idx" "${app_opts[@]}"

declare -A CUSTOM_APP_URL=()
while true; do
	ask_optional extra_url "Git URL of another (custom) app to add, blank to continue" ""
	[[ -z "$extra_url" ]] && break
	if ! msg=$(valid_git_url "$extra_url"); then ui_error "$msg"; continue; fi
	extra_name=$(basename "${extra_url%.git}")
	if [[ " ${PICKED_APPS[*]} " == *" $extra_name "* ]]; then ui_error "$extra_name is already selected."; continue; fi
	success "Added $extra_name."
	CUSTOM_APP_URL[$extra_name]=$extra_url
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
	table=$(printf '   %-22s %-14s %s' APP BRANCH REPOSITORY)
	for a in "${APPS[@]}"; do
		flag=''
		[[ "${APP_BRANCH[$a]}" != "$APP_TARGET_BRANCH" ]] && flag=" ${C_YELLOW}(no $APP_TARGET_BRANCH branch)${C_RESET}"
		table+=$'\n'$(printf '   %-22s %-14s %s%s' "$a" "${APP_BRANCH[$a]}" "${APP_URL[$a]#https://github.com/}" "$flag")
	done
	ui_details "$table"
	if ! ask_yes_no "Use these branches?" y; then
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
default_bench=frappe-bench
n=2; while [[ -e "$HOME/$default_bench" ]]; do default_bench="frappe-bench-$n"; n=$((n + 1)); done
ask_valid BENCH_NAME "Bench directory name (created in $HOME)" "$default_bench" valid_bench_name
BENCH_PATH="$HOME/$BENCH_NAME"

# MariaDB root password: asked now when MariaDB is not installed yet, so the install runs unattended.
if [[ -z "${DB_ROOT_PASSWORD:-}" ]] && ! command -v mariadb >/dev/null 2>&1 && ! command -v mysql >/dev/null 2>&1; then
	ask_new_password DB_ROOT_PASSWORD "MariaDB root password" DB_ROOT_PASSWORD 8
	export DB_ROOT_PASSWORD
fi

header "6/6  Site"
CREATE_SITE=0 SITE_NAME='' ADMIN_PW='' SITE_APPS=() DNS_MULTITENANT=0 LETSENCRYPT=0 LE_EMAIL=''
if ask_yes_no "Create a site now?" y; then
	CREATE_SITE=1
	if [[ "$MODE" == production ]]; then
		ask_valid SITE_NAME "Site name (use the domain name it will be served on, e.g. erp.example.com)" "$(hostname -f 2>/dev/null || cat /etc/hostname 2>/dev/null || echo site1.local)" valid_site_name
	else
		ask_valid SITE_NAME "Site name (*.localhost names open in the browser without editing hosts)" "site1.localhost" valid_site_name
	fi
	ask_new_password ADMIN_PW "Administrator password for $SITE_NAME" ADMIN_PASSWORD "$([[ "$MODE" == production ]] && echo 8 || echo 4)"
	if ((${#APPS[@]})); then
		mapfile -t site_app_opts < <(printf '%s\n' "${APPS[@]}")
		choose_multi SITE_APPS "Install which apps on $SITE_NAME?" "a" "${site_app_opts[@]}"
		mapfile -t SITE_APPS < <(resolve_app_deps "${SITE_APPS[@]}")
	fi
	if [[ "$MODE" == production ]]; then
		if [[ "$SITE_NAME" == *.* && "$SITE_NAME" != *.localhost && "$SITE_NAME" != *.local ]]; then
			ask_yes_no "Serve sites by domain name (DNS multitenancy, recommended)?" y && DNS_MULTITENANT=1
			if ((DNS_MULTITENANT)) && ask_yes_no "Get a free HTTPS certificate from Let's Encrypt now (DNS must already point here)?" n; then
				LETSENCRYPT=1
				ask_valid LE_EMAIL "Email for Let's Encrypt expiry notices" "" valid_email
				_PF_RESULTS=(); pf_check_dns "$SITE_NAME"; preflight_report || true
			fi
		fi
	fi
fi

# --------------------------------------------------------------------------
# 2. Summary
# --------------------------------------------------------------------------
header "Summary"
summary=$(
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
		((LETSENCRYPT)) && printf '   %-18s %s\n' "HTTPS" "Let's Encrypt ($LE_EMAIL)"
	fi
	((CREATE_SWAP)) && printf '   %-18s %s\n' "Swap" "create a 4 GB /swapfile"
	printf '   %-18s %s\n' "Output" "$( [[ "${FSS_QUIET:-0}" == 1 ]] && echo 'compact (full output in the log)' || echo 'full')"
)
ui_details "$summary"
ask_yes_no "Start the installation? It usually takes 10 to 30 minutes." y || die "Cancelled."

# --------------------------------------------------------------------------
# 3. Install
# --------------------------------------------------------------------------
setup_logging install
START_TS=$(date +%s)

# Each step below is one numbered entry of the progress display.
do_mariadb() { install_mariadb_server; configure_mariadb_root DB_ROOT_PW; }
do_python() { install_uv; PYTHON_BIN=$(install_python "$PYTHON_VERSION"); }
do_bench_cli() { install_bench_cli; persist_shell_env; }

do_bench_init() {
	local -a init_args=(init --frappe-branch "$FRAPPE_BRANCH" --python "$PYTHON_BIN")
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

do_get_app() {
	local a=$1 before added i
	before=$(bench_apps "$BENCH_PATH" | sort)
	with_bench "$BENCH_PATH" get-app --skip-assets --branch "${APP_BRANCH[$a]}" "${APP_URL[$a]}" || true
	added=$(comm -13 <(echo "$before") <(bench_apps "$BENCH_PATH" | sort) | grep -vx frappe | tail -1 || true)
	if [[ -z "$added" ]]; then
		die "Getting $a failed (see the output above). Retry with: cd $BENCH_PATH && bench get-app --branch ${APP_BRANCH[$a]} ${APP_URL[$a]}"
	fi
	if [[ "$added" != "$a" ]]; then
		# A custom app's real name can differ from its repository name.
		info "App from ${APP_URL[$a]} is named '$added'."
		for i in "${!SITE_APPS[@]}"; do [[ "${SITE_APPS[$i]}" == "$a" ]] && SITE_APPS[i]=$added; done
	fi
	return 0
}

do_build() {
	[[ "$MODE" == production ]] && export NODE_ENV=production
	with_bench "$BENCH_PATH" build
	if [[ "$MODE" == development ]]; then
		with_bench "$BENCH_PATH" set-config -g developer_mode 1
	fi
	((DNS_MULTITENANT)) && with_bench "$BENCH_PATH" config dns_multitenant on
	return 0
}

do_site() {
	local -a site_args=(new-site "$SITE_NAME" --admin-password "$ADMIN_PW" --db-root-password "$DB_ROOT_PW")
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

do_production() {
	with_bench "$BENCH_PATH" set-config -g developer_mode 0 || true
	setup_production "$BENCH_PATH"
}

HTTPS_OK=0
do_https() {
	case "$OS_FAMILY" in
		debian) apt_install certbot ;;
		arch) pacman_install certbot ;;
	esac
	if ( cd "$BENCH_PATH" && run as_root env "PATH=$PATH" "$(command -v bench)" setup lets-encrypt "$SITE_NAME" ); then
		HTTPS_OK=1
	else
		warn "Let's Encrypt failed. Fix DNS and retry with: cd $BENCH_PATH && sudo env PATH=\$PATH bench setup lets-encrypt $SITE_NAME"
	fi
}

PLAN=()
((CREATE_SWAP)) && PLAN+=("Swap file|create_swapfile 4")
PLAN+=(
	"System packages|install_base_packages $MODE"
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

phase_plan "${#PLAN[@]}"
for entry in "${PLAN[@]}"; do
	read -ra cmd <<<"${entry#*|}"
	phase "${entry%%|*}" "${cmd[@]}"
done

wsl_offer_systemd

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
		URLS+=("http$( ((HTTPS_OK)) && printf s)://$SITE_NAME")
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
	CRED_FILE="$HOME/.frappe-credentials/$BENCH_NAME.txt"
	save_generated_secrets "$CRED_FILE" || CRED_FILE=''
fi
secret_note() { # secret_note <label>
	if generated_secret "$1" >/dev/null; then echo "(generated, see below)"; else echo "(the password you entered)"; fi
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

if [[ -n "$CRED_FILE" ]]; then
	{
		printf '\n%s%s%s\n' "${C_YELLOW}${C_BOLD}" "Generated passwords (shown once, not written to the log):" "${C_RESET}"
		for e in "${FSS_GENERATED_SECRETS[@]}"; do printf '   %-44s %s%s%s\n' "${e%%|*}" "${C_BOLD}" "${e#*|}" "${C_RESET}"; done
		printf '   %sAlso saved in %s (only you can read it).%s\n' "${C_DIM}" "$CRED_FILE" "${C_RESET}"
		printf '   %sStore them in a password manager, then delete that file.%s\n' "${C_DIM}" "${C_RESET}"
	} >/dev/tty 2>/dev/null || warn "Generated passwords are saved in $CRED_FILE (only you can read it)."
	echo "   Generated passwords were shown on the terminal and saved in $CRED_FILE." >>"$FSS_LOG_FILE"
fi
success "Frappe is installed."
