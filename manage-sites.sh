#!/usr/bin/env bash
# Interactive site manager for a Frappe bench:
# list, create, migrate, back up, restore and remove sites; install/uninstall apps;
# fetch new apps into the bench; set the default site; HTTPS for production benches.
#
# Usage: ./manage-sites.sh [bench-path]

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/prereqs.sh
. "$SCRIPT_DIR/lib/prereqs.sh"
# shellcheck source=lib/apps.sh
. "$SCRIPT_DIR/lib/apps.sh"
strict_mode

if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
	sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'
	exit 0
fi
[[ -n "${1:-}" ]] && BENCH_PATH=$1

header "Frappe site manager"
is_root && die "Run this script as the user that owns the bench, not as root."
detect_os
load_runtime_env
command -v bench >/dev/null 2>&1 || die "bench is not installed for $(id -un). Run ./install.sh first."
select_bench BENCH
use_node_for_bench "$BENCH"
PROD=0; bench_is_production "$BENCH" && PROD=1
DB_ROOT_PW=${DB_ROOT_PASSWORD:-}
ensure_bench_redis "$BENCH"

# --------------------------------------------------------------------------
# Helpers
# --------------------------------------------------------------------------
b() { with_bench "$BENCH" "$@"; }

get_db_root_pw() {
	[[ -n "$DB_ROOT_PW" ]] && mariadb_password_works "$DB_ROOT_PW" && return 0
	local pw
	while true; do
		ask_secret pw "MariaDB root password" no
		if mariadb_password_works "$pw"; then DB_ROOT_PW=$pw; return 0; fi
		warn "That password did not work."
		[[ "${ASSUME_DEFAULTS:-0}" == 1 ]] && die "Invalid DB_ROOT_PASSWORD."
	done
}

# pick_site <varname> [prompt]
pick_site() {
	local __var=$1 __prompt=${2:-Which site?}
	local -a sites=()
	mapfile -t sites < <(bench_sites "$BENCH")
	((${#sites[@]})) || { warn "This bench has no sites yet."; return 1; }
	local __s
	if ((${#sites[@]} == 1)); then __s=${sites[0]}; info "Site: ${C_BOLD}$__s${C_RESET}"
	else choose __s "$__prompt" 1 "${sites[@]}"
	fi
	printf -v "$__var" '%s' "$__s"
}

site_installed_apps() { site_apps "$BENCH" "$1"; }

after_site_change() {
	((PROD)) || return 0
	info "Reloading nginx and bench processes for the new configuration."
	reload_production "$BENCH"
}

# --------------------------------------------------------------------------
# Actions
# --------------------------------------------------------------------------
list_sites() {
	header "Sites in $BENCH"
	local s def='' apps
	[[ -f "$BENCH/sites/currentsite.txt" ]] && def=$(cat "$BENCH/sites/currentsite.txt")
	def=${def:-$(grep -oE '"default_site"\s*:\s*"[^"]+"' "$BENCH/sites/common_site_config.json" 2>/dev/null | grep -oE '"[^"]+"$' | tr -d '"' || true)}
	local any=0
	while read -r s; do
		[[ -z "$s" ]] && continue
		any=1
		apps=$(site_installed_apps "$s" | tr '\n' ' ')
		printf '   %s%-32s%s %s%s\n' "${C_BOLD}" "$s" "${C_RESET}" "${apps:-frappe only}" "$([[ "$s" == "$def" ]] && printf '  %s(default)%s' "$C_GREEN" "$C_RESET")" >&2
	done < <(bench_sites "$BENCH")
	((any)) || echo "   (no sites)" >&2
}

create_site() {
	header "Create a site"
	local site admin_pw def_name apps_opts=() apps=() a
	if ((PROD)); then def_name=$(hostname -f 2>/dev/null || cat /etc/hostname 2>/dev/null || echo site1.local); else def_name="site$(( $(bench_sites "$BENCH" | wc -l) + 1 )).localhost"; fi
	ask site "Site name" "$def_name"
	[[ "$site" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?$ ]] || { warn "Invalid site name."; return 1; }
	[[ -d "$BENCH/sites/$site" ]] && { warn "Site $site already exists."; return 1; }
	ask_secret admin_pw "Administrator password for $site" yes
	get_db_root_pw
	mapfile -t apps_opts < <(bench_apps "$BENCH" | grep -vx frappe || true)
	if ((${#apps_opts[@]})); then
		choose_multi apps "Install which apps on $site?" "a" "${apps_opts[@]}"
		mapfile -t apps < <(resolve_app_deps "${apps[@]}")
	fi
	local args=(new-site "$site" --admin-password "$admin_pw" --db-root-password "$DB_ROOT_PW")
	for a in "${apps[@]}"; do args+=(--install-app "$a"); done
	b "${args[@]}"
	check_site_apps "$BENCH" "$site" "${apps[@]}" || true
	if ((!PROD)); then
		grep -q '"developer_mode"\s*:\s*1' "$BENCH/sites/common_site_config.json" 2>/dev/null && b --site "$site" set-config developer_mode 1
		[[ "$site" == *.localhost ]] || { ask_yes_no "Add $site to /etc/hosts?" y && b --site "$site" add-to-hosts; }
	fi
	ask_yes_no "Make $site the default site?" "$([[ -s "$BENCH/sites/currentsite.txt" ]] && echo n || echo y)" && b use "$site"
	after_site_change
	success "Site $site created."
}

install_app_on_site() {
	header "Install apps on a site"
	local site a
	pick_site site || return 0
	local -a installed=() available=() pick=()
	mapfile -t installed < <(site_installed_apps "$site")
	while read -r a; do
		[[ "$a" == frappe || " ${installed[*]} " == *" $a "* ]] && continue
		available+=("$a")
	done < <(bench_apps "$BENCH")
	((${#available[@]})) || { warn "Every app in this bench is already installed on $site. Use 'Get a new app' first."; return 0; }
	choose_multi pick "Install which apps on $site?" "" "${available[@]}"
	((${#pick[@]})) || return 0
	mapfile -t pick < <(resolve_app_deps "${pick[@]}")
	local -a todo=()
	for a in "${pick[@]}"; do [[ " ${installed[*]} " == *" $a "* ]] || todo+=("$a"); done
	b --site "$site" install-app "${todo[@]}"
	check_site_apps "$BENCH" "$site" "${todo[@]}" && success "Installed ${todo[*]} on $site."
}

uninstall_app_from_site() {
	header "Uninstall an app from a site"
	local site app
	pick_site site || return 0
	local -a installed=()
	mapfile -t installed < <(site_installed_apps "$site")
	((${#installed[@]})) || { warn "Only frappe is installed on $site."; return 0; }
	choose app "Uninstall which app from $site?" 1 "${installed[@]}"
	warn "This deletes all of $app's DocTypes and data from $site."
	ask_yes_no "Take a backup first?" y && b --site "$site" backup --with-files
	ask_yes_no "Really uninstall $app from $site?" n || return 0
	b --site "$site" uninstall-app "$app" --yes --no-backup
	success "$app uninstalled from $site."
}

get_new_app() {
	header "Get a new app into the bench"
	local frappe_branch target src app url branch a
	frappe_branch=$(app_branch "$BENCH" frappe)
	target=$frappe_branch
	local -a present=() opts=()
	mapfile -t present < <(bench_apps "$BENCH")
	while IFS= read -r a; do
		[[ " ${present[*]} " == *" ${a%%|*} "* ]] || opts+=("$a")
	done < <(catalog_menu_options)
	opts+=("custom|Another app from a git URL")
	choose src "Which app?" 1 "${opts[@]}"
	if [[ "$src" == custom ]]; then
		ask url "Git URL of the app"
		app=$(basename "${url%.git}")
		ask branch "Branch or tag" "$(pick_app_branch "$url" "$target" || echo main)"
		b get-app --branch "$branch" "$url"
		return 0
	fi
	local -a chain=()
	mapfile -t chain < <(resolve_app_deps "$src")
	for app in "${chain[@]}"; do
		[[ " ${present[*]} " == *" $app "* ]] && continue
		url=$(app_repo "$app")
		branch=$(pick_app_branch "$url" "$target") || { warn "Cannot read branches of $url."; return 1; }
		ask branch "Branch for $app (frappe is on $frappe_branch)" "$branch"
		b get-app --branch "$branch" "$url"
	done
	if ask_yes_no "Install ${chain[*]} on a site now?" y; then install_app_on_site; fi
	((PROD)) && reload_production "$BENCH"
	return 0
}

migrate_site() {
	header "Migrate sites"
	local site
	local -a sites=()
	mapfile -t sites < <(bench_sites "$BENCH")
	((${#sites[@]})) || { warn "No sites."; return 0; }
	choose site "Migrate which site?" 1 "all|every site in the bench" "${sites[@]}"
	if [[ "$site" == all ]]; then
		for site in "${sites[@]}"; do header "Migrating $site"; b --site "$site" migrate; done
	else
		b --site "$site" migrate
	fi
	success "Migration finished."
}

backup_site() {
	header "Back up sites"
	local site s
	local -a sites=() flags=()
	mapfile -t sites < <(bench_sites "$BENCH")
	((${#sites[@]})) || { warn "No sites."; return 0; }
	choose site "Back up which site?" 1 "all|every site in the bench" "${sites[@]}"
	ask_yes_no "Include uploaded (public and private) files?" y && flags+=(--with-files)
	ask_yes_no "Compress file backups (.tgz)?" y && [[ " ${flags[*]} " == *" --with-files "* ]] && flags+=(--compress)
	[[ "$site" == all ]] || sites=("$site")
	for s in "${sites[@]}"; do
		header "Backing up $s"
		b --site "$s" backup "${flags[@]}"
		info "Saved in $BENCH/sites/$s/private/backups:"
		# shellcheck disable=SC2012
		ls -1t "$BENCH/sites/$s/private/backups" 2>/dev/null | head -4 | sed 's/^/     /' >&2 || true
	done
	success "Backup finished."
}

restore_site() {
	header "Restore a site from backup"
	local site db file pub priv
	pick_site site "Restore into which site? (create it first if needed)" || return 0
	local dir="$BENCH/sites/$site/private/backups"
	local -a dbs=()
	mapfile -t dbs < <(ls -1t "$dir"/*.sql.gz "$dir"/*.sql 2>/dev/null || true)
	if ((${#dbs[@]})); then
		dbs+=("other|enter a path")
		choose db "Which database backup?" 1 "${dbs[@]}"
	else
		db=other
	fi
	[[ "$db" == other ]] && ask db "Path to the database backup (.sql or .sql.gz)"
	[[ -f "$db" ]] || { warn "File not found: $db"; return 1; }
	local stem=${db%-database.sql.gz}; stem=${stem%-database.sql}
	local -a args=(--site "$site" restore "$db")
	for file in "$stem"-files.tar "$stem"-files.tgz; do [[ -f "$file" ]] && pub=$file; done
	for file in "$stem"-private-files.tar "$stem"-private-files.tgz; do [[ -f "$file" ]] && priv=$file; done
	if [[ -n "${pub:-}" ]] && ask_yes_no "Restore public files from $(basename "$pub")?" y; then args+=(--with-public-files "$pub"); fi
	if [[ -n "${priv:-}" ]] && ask_yes_no "Restore private files from $(basename "$priv")?" y; then args+=(--with-private-files "$priv"); fi
	warn "Restoring replaces ALL current data of $site."
	ask_yes_no "Continue?" n || return 0
	get_db_root_pw
	args+=(--db-root-password "$DB_ROOT_PW" --force)
	b "${args[@]}"
	b --site "$site" migrate
	success "$site restored."
}

remove_site() {
	header "Remove a site"
	local site confirm
	pick_site site "Remove which site?" || return 0
	warn "This drops the database of $site and moves its folder to $BENCH/archived/sites."
	local -a flags=()
	ask_yes_no "Take a final backup first?" y || flags+=(--no-backup)
	ask confirm "Type the site name to confirm"
	[[ "$confirm" == "$site" ]] || { warn "Name did not match; nothing removed."; return 0; }
	get_db_root_pw
	b drop-site "$site" --db-root-password "$DB_ROOT_PW" "${flags[@]}" --force
	[[ -f "$BENCH/sites/currentsite.txt" && "$(cat "$BENCH/sites/currentsite.txt")" == "$site" ]] && rm -f "$BENCH/sites/currentsite.txt"
	after_site_change
	success "$site removed."
}

set_default_site() {
	local site
	pick_site site "Make which site the default?" || return 0
	b use "$site"
	success "$site is now the default site."
}

toggle_developer_mode() {
	local site cur
	pick_site site || return 0
	cur=$(cd "$BENCH" && bench --site "$site" show-config -f json 2>/dev/null | grep -oE '"developer_mode"\s*:\s*[01]' | grep -oE '[01]$' || true)
	if [[ "$cur" == 1 ]]; then
		ask_yes_no "Developer mode is ON for $site. Turn it off?" y && b --site "$site" set-config developer_mode 0
	else
		ask_yes_no "Developer mode is OFF for $site. Turn it on?" y && b --site "$site" set-config developer_mode 1
	fi
	b --site "$site" clear-cache
}

setup_https() {
	header "HTTPS with Let's Encrypt"
	local site
	pick_site site || return 0
	if ! grep -q '"dns_multitenant"\s*:\s*true' "$BENCH/sites/common_site_config.json" 2>/dev/null; then
		warn "Let's Encrypt needs DNS multitenancy (sites served by their domain name)."
		ask_yes_no "Turn on DNS multitenancy and regenerate nginx config?" y || return 0
		b config dns_multitenant on
		reload_production "$BENCH"
	fi
	command -v certbot >/dev/null 2>&1 || case "$OS_FAMILY" in
		debian) apt_install certbot ;;
		arch) pacman_install certbot ;;
	esac
	ensure_sudo
	( cd "$BENCH" && run as_root env "PATH=$PATH" "$(command -v bench)" setup lets-encrypt "$site" )
	success "HTTPS configured for $site."
}

# --------------------------------------------------------------------------
# Menu
# --------------------------------------------------------------------------
menu_opts=(
	"list|List sites and their apps"
	"create|Create a new site"
	"install-app|Install apps on a site"
	"uninstall-app|Uninstall an app from a site"
	"get-app|Get a new app into the bench"
	"migrate|Migrate (update) a site or all sites"
	"backup|Back up a site or all sites"
	"restore|Restore a site from a backup"
	"remove|Remove (drop) a site"
	"default|Set the default site"
)
if ((PROD)); then
	menu_opts+=("https|Set up HTTPS (Let's Encrypt) for a site")
else
	menu_opts+=("devmode|Toggle developer mode for a site")
fi
menu_opts+=("quit|Exit")

list_sites
while true; do
	echo >&2
	choose ACTION "What do you want to do? (bench: $BENCH)" 1 "${menu_opts[@]}"
	# Ask for the MariaDB password here (not in the subshell) so it is remembered between actions.
	case "$ACTION" in create|restore|remove) get_db_root_pw ;; esac
	# Each action runs in a subshell so a failed bench command returns to the menu.
	case "$ACTION" in
		quit) break ;;
		list) ( list_sites ) || true ;;
		create) ( create_site ) || warn "Site creation did not finish." ;;
		install-app) ( install_app_on_site ) || warn "App install did not finish." ;;
		uninstall-app) ( uninstall_app_from_site ) || warn "Uninstall did not finish." ;;
		get-app) ( get_new_app ) || warn "Getting the app did not finish." ;;
		migrate) ( migrate_site ) || warn "Migration did not finish." ;;
		backup) ( backup_site ) || warn "Backup did not finish." ;;
		restore) ( restore_site ) || warn "Restore did not finish." ;;
		remove) ( remove_site ) || warn "Removal did not finish." ;;
		default) ( set_default_site ) || true ;;
		devmode) ( toggle_developer_mode ) || true ;;
		https) ( setup_https ) || warn "HTTPS setup did not finish." ;;
	esac
	[[ "${ASSUME_DEFAULTS:-0}" == 1 ]] && break
done
success "Bye."
