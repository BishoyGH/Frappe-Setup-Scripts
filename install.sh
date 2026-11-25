#!/usr/bin/env bash
# Interactive installer for the Frappe framework and official Frappe apps.
# Supports Ubuntu, Debian and Arch Linux (bare metal, VM or WSL), development or production setups.
#
# Usage: ./install.sh            (interactive)
#        ASSUME_DEFAULTS=1 DB_ROOT_PASSWORD=... ADMIN_PASSWORD=... ./install.sh   (accept all defaults)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/prereqs.sh
. "$SCRIPT_DIR/lib/prereqs.sh"
# shellcheck source=lib/apps.sh
. "$SCRIPT_DIR/lib/apps.sh"
strict_mode

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
	sed -n '2,7p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
fi

header "Frappe installer"
require_supported_os

# --------------------------------------------------------------------------
# Running as root: create (or pick) a regular user and continue as that user.
# --------------------------------------------------------------------------
if is_root; then
	warn "Frappe benches must not be owned by root."
	bootstrap_root_minimum
	ask FRAPPE_USER "Linux user that will own the bench (created if missing)" "${FRAPPE_USER:-frappe}"
	[[ "$FRAPPE_USER" == root ]] && die "Choose a non-root user."
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
		--preserve-env=ASSUME_DEFAULTS,DB_ROOT_PASSWORD,ADMIN_PASSWORD,NO_COLOR \
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
header "1/5  Setup type"
choose MODE "What kind of setup is this?" 1 \
	"development|bench start, developer mode, hot reload" \
	"production|nginx + supervisor, runs as background services"
if [[ "$MODE" == production ]] && ((IS_WSL)); then
	warn "Production on WSL is fine for testing, but WSL is not meant to host a public server."
fi

header "2/5  Frappe version"
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
	while true; do
		ask FRAPPE_BRANCH "Frappe branch or tag"
		remote_ref_exists https://github.com/frappe/frappe "$FRAPPE_BRANCH" && break
		warn "'$FRAPPE_BRANCH' was not found in frappe/frappe."
	done
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
	ask PYTHON_VERSION "Python version" "$PYTHON_VERSION"
	ask NODE_VERSION "Node.js major version" "$NODE_VERSION"
fi

header "3/5  Apps"
mapfile -t app_opts < <(catalog_menu_options)
erp_idx=$(( $(catalog_names | grep -nx erpnext | cut -d: -f1) ))
choose_multi PICKED_APPS "Which official apps should be installed? (Frappe itself is always installed)" "$erp_idx" "${app_opts[@]}"

declare -A CUSTOM_APP_URL=()
while true; do
	ask_optional extra_url "Git URL of another (custom) app to add, blank to continue" ""
	[[ -z "$extra_url" ]] && break
	extra_name=$(basename "${extra_url%.git}")
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
	printf '\n   %-24s %-16s %s\n' APP BRANCH REPOSITORY >&2
	for a in "${APPS[@]}"; do
		flag=''
		[[ "${APP_BRANCH[$a]}" != "$APP_TARGET_BRANCH" ]] && flag=" ${C_YELLOW}(no $APP_TARGET_BRANCH branch)${C_RESET}"
		printf '   %-24s %-16s %s%s\n' "$a" "${APP_BRANCH[$a]}" "${APP_URL[$a]}" "$flag" >&2
	done
	echo >&2
	if ! ask_yes_no "Use these branches?" y; then
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
ask BENCH_NAME "Bench directory name (created in $HOME)" "frappe-bench"
BENCH_PATH="$HOME/$BENCH_NAME"
if [[ -e "$BENCH_PATH" ]]; then
	if is_bench_dir "$BENCH_PATH"; then
		die "$BENCH_PATH already contains a bench. Use ./update-bench.sh or ./manage-sites.sh for it, or pick another name."
	fi
	die "$BENCH_PATH already exists and is not a bench. Pick another name."
fi

header "5/5  Site"
CREATE_SITE=0 SITE_NAME='' ADMIN_PW='' SITE_APPS=() DNS_MULTITENANT=0 LETSENCRYPT=0 LE_EMAIL=''
if ask_yes_no "Create a site now?" y; then
	CREATE_SITE=1
	if [[ "$MODE" == production ]]; then
		ask SITE_NAME "Site name (use the domain name it will be served on, e.g. erp.example.com)" "$(hostname -f 2>/dev/null || cat /etc/hostname 2>/dev/null || echo site1.local)"
	else
		ask SITE_NAME "Site name (*.localhost names open in the browser without editing hosts)" "site1.localhost"
	fi
	[[ "$SITE_NAME" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || die "Invalid site name: $SITE_NAME"
	ask_secret ADMIN_PW "Administrator password for $SITE_NAME" yes ADMIN_PASSWORD
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
				ask LE_EMAIL "Email for Let's Encrypt expiry notices"
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
		((LETSENCRYPT)) && printf '   %-18s %s\n' "HTTPS" "Let's Encrypt ($LE_EMAIL)"
	fi
} >&2
echo >&2
ask_yes_no "Start the installation?" y || die "Cancelled."

# --------------------------------------------------------------------------
# 3. Install
# --------------------------------------------------------------------------
setup_logging install
START_TS=$(date +%s)

install_base_packages "$MODE"
install_mariadb_server
configure_mariadb_root DB_ROOT_PW
install_wkhtmltopdf
install_uv
PYTHON_BIN=$(install_python "$PYTHON_VERSION")
install_node "$NODE_VERSION"
install_bench_cli
persist_shell_env

header "Creating bench $BENCH_NAME (frappe @ $FRAPPE_BRANCH)"
init_args=(init --frappe-branch "$FRAPPE_BRANCH" --python "$PYTHON_BIN")
if [[ "$MODE" == development ]] && bench init --help 2>/dev/null | grep -q -- '--dev'; then
	init_args+=(--dev)
fi
# Assets are built once, after all apps are fetched.
init_args+=(--skip-assets)
( cd "$HOME" && run bench "${init_args[@]}" "$BENCH_NAME" ) || true
# bench exits 0 even after rolling back a failed init, so check the result explicitly.
is_bench_dir "$BENCH_PATH" && [[ -x "$BENCH_PATH/env/bin/python" ]] ||
	die "bench init failed (see the output above). Fix the problem and run ./install.sh again."
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

for a in "${APPS[@]}"; do
	header "Getting app $a @ ${APP_BRANCH[$a]}"
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
done

header "Building assets"
[[ "$MODE" == production ]] && export NODE_ENV=production
with_bench "$BENCH_PATH" build

if [[ "$MODE" == development ]]; then
	with_bench "$BENCH_PATH" set-config -g developer_mode 1
fi
((DNS_MULTITENANT)) && with_bench "$BENCH_PATH" config dns_multitenant on

if ((CREATE_SITE)); then
	header "Creating site $SITE_NAME"
	site_args=(new-site "$SITE_NAME" --admin-password "$ADMIN_PW" --db-root-password "$DB_ROOT_PW")
	for a in "${SITE_APPS[@]}"; do site_args+=(--install-app "$a"); done
	with_bench "$BENCH_PATH" "${site_args[@]}"
	check_site_apps "$BENCH_PATH" "$SITE_NAME" "${SITE_APPS[@]}" || true
	with_bench "$BENCH_PATH" use "$SITE_NAME"
	if [[ "$MODE" == development ]]; then
		with_bench "$BENCH_PATH" --site "$SITE_NAME" set-config developer_mode 1
		with_bench "$BENCH_PATH" --site "$SITE_NAME" clear-cache
	fi
fi

if [[ "$MODE" == production ]]; then
	with_bench "$BENCH_PATH" set-config -g developer_mode 0 || true
	setup_production "$BENCH_PATH"
	if ((LETSENCRYPT)); then
		header "Setting up HTTPS for $SITE_NAME"
		case "$OS_FAMILY" in
			debian) apt_install certbot ;;
			arch) pacman_install certbot ;;
		esac
		( cd "$BENCH_PATH" && run as_root env "PATH=$PATH" "$(command -v bench)" setup lets-encrypt "$SITE_NAME" ) ||
			warn "Let's Encrypt failed. Fix DNS and retry with: cd $BENCH_PATH && sudo env PATH=\$PATH bench setup lets-encrypt $SITE_NAME"
	fi
fi

wsl_offer_systemd

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
