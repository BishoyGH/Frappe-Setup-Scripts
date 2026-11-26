#!/usr/bin/env bash
# Interactive updater for an existing Frappe bench and all of its sites.
#  - update:  pull the latest commits on the current branches, migrate every site, rebuild, restart
#  - upgrade: move the bench to another Frappe major version (e.g. version-15 -> version-16)
#  - apps:    update only some apps
#  - migrate / build: run just that step
#
# Usage: ./update-bench.sh [--yes] [--action update|upgrade|apps|migrate|build] [bench-path]
#   --yes accepts every default (e.g. for cron: ./update-bench.sh --yes --action update ~/frappe-bench)

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/prereqs.sh
. "$SCRIPT_DIR/lib/prereqs.sh"
# shellcheck source=lib/apps.sh
. "$SCRIPT_DIR/lib/apps.sh"
strict_mode

FSS_ARGS="$*"
ACTION=''
while (($#)); do
	case "$1" in
		-h|--help) sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
		-y|--yes|--non-interactive) ASSUME_DEFAULTS=1 ;;
		--action) [[ $# -ge 2 ]] || die "--action needs a value."; ACTION=$2; shift ;;
		--action=*) ACTION=${1#*=} ;;
		-*) die "Unknown option: $1 (see --help)" ;;
		*) BENCH_PATH=$1 ;;
	esac
	shift
done
case "${ACTION:-update}" in update|upgrade|apps|migrate|build|quit) ;; *) die "Unknown action: $ACTION" ;; esac

setup_logging update-bench
header "Frappe bench updater"
is_root && die "Run this script as the user that owns the bench, not as root."
detect_os
load_runtime_env
command -v bench >/dev/null 2>&1 || die "bench is not installed for $(id -un). Run ./install.sh first."

select_bench BENCH
use_node_for_bench "$BENCH"
mapfile -t SITES < <(bench_sites "$BENCH")
mapfile -t APPS < <(bench_apps "$BENCH")
PROD=0; bench_is_production "$BENCH" && PROD=1

# app_remote <app>: upstream URL for an app's repository
app_remote() {
	local d="$BENCH/apps/$1"
	git -C "$d" remote get-url upstream 2>/dev/null || git -C "$d" remote get-url origin 2>/dev/null || true
}

show_status() {
	header "Bench status: $BENCH"
	printf '   %-24s %-16s %s\n' APP BRANCH VERSION >&2
	local a ver
	for a in "${APPS[@]}"; do
		ver=$(grep -hoE '^__version__\s*=\s*"[^"]+"' "$BENCH/apps/$a/$a/__init__.py" 2>/dev/null | grep -oE '"[^"]+"' | tr -d '"' || true)
		printf '   %-24s %-16s %s\n' "$a" "$(app_branch "$BENCH" "$a")" "${ver:-?}" >&2
	done
	printf '\n   Sites: %s\n' "${SITES[*]:-(none)}" >&2
	printf '   Mode:  %s\n\n' "$( ((PROD)) && echo production || echo development)" >&2
}

# check_dirty: returns 0 if every app repo is clean, otherwise asks what to do.
RESET_FLAG=()
check_dirty() {
	local a dirty=()
	for a in "${APPS[@]}"; do
		[[ -n "$(git -C "$BENCH/apps/$a" status --porcelain --untracked-files=no 2>/dev/null)" ]] && dirty+=("$a")
	done
	((${#dirty[@]})) || return 0
	warn "These apps have local, uncommitted changes: ${dirty[*]}"
	local act
	choose act "How should they be handled?" 1 \
		"stash|git stash the changes (recoverable with git stash pop)" \
		"reset|discard the changes (bench update --reset)" \
		"abort|stop here"
	case "$act" in
		stash) for a in "${dirty[@]}"; do run git -C "$BENCH/apps/$a" stash push -m "frappe-setup-scripts $(date +%F-%T)"; done ;;
		reset) RESET_FLAG=(--reset) ;;
		abort) die "Aborted." ;;
	esac
}

backup_sites() {
	((${#SITES[@]})) || return 0
	if ask_yes_no "Back up all ${#SITES[@]} site(s) before updating?" y; then
		local with_files=()
		ask_yes_no "Include uploaded files in the backups?" y && with_files=(--with-files)
		local s
		for s in "${SITES[@]}"; do
			header "Backing up $s"
			with_bench "$BENCH" --site "$s" backup "${with_files[@]}"
		done
		success "Backups are in $BENCH/sites/<site>/private/backups"
	fi
}

warn_dev_server() {
	if ((!PROD)) && pgrep -f "$BENCH.*(honcho|frappe.utils.bench_helper frappe serve)" >/dev/null 2>&1; then
		warn "'bench start' seems to be running for this bench. Stop it (Ctrl+C) before updating."
		pause
	fi
	ensure_bench_redis "$BENCH"
}

do_update() {
	check_dirty
	warn_dev_server
	backup_sites
	header "Updating apps and migrating all sites"
	run_bench_update --no-backup "${RESET_FLAG[@]}" "$@"
}

# run_bench_update <args...>: bench update, with a clear message if it stops half-way.
run_bench_update() {
	if ! with_bench "$BENCH" update "$@"; then
		error "bench update did not finish. Sites may still be in maintenance mode."
		error "After fixing the problem, re-run this script, or bring sites back with:"
		error "  cd $BENCH && bench set-config -g maintenance_mode 0 && bench set-config -g pause_scheduler 0"
		exit 1
	fi
}

do_upgrade() {
	local current target major py node a branch url
	current=$(frappe_major_of_bench "$BENCH")
	info "Current Frappe major version: ${C_BOLD}$current${C_RESET} (branch $(app_branch "$BENCH" frappe))"
	local -a opts=()
	while read -r b; do
		[[ -z "$b" ]] && continue
		opts+=("$b|Frappe v${b#version-}")
	done < <(frappe_release_branches 4)
	opts+=("develop|Unreleased development branch")
	choose target "Upgrade (or switch) to which version?" 1 "${opts[@]}"
	major=$(frappe_major_from_ref "$target")
	if [[ "$major" =~ ^[0-9]+$ && "$current" =~ ^[0-9]+$ ]]; then
		if ((major < current)); then die "Downgrading ($current -> $major) is not supported by Frappe."; fi
		if ((major > current + 1)); then
			warn "Frappe supports upgrading one major version at a time ($current -> $((current + 1)) -> ...)."
			ask_yes_no "Continue anyway?" n || die "Aborted."
		fi
	fi

	declare -A NEW_BRANCH=()
	printf '\n   %-24s %-16s %s\n' APP CURRENT NEW >&2
	for a in "${APPS[@]}"; do
		url=$(app_remote "$a")
		if [[ -z "$url" ]]; then NEW_BRANCH[$a]=''; continue; fi
		branch=$(pick_app_branch "$url" "$target" || true)
		NEW_BRANCH[$a]=$branch
		printf '   %-24s %-16s %s\n' "$a" "$(app_branch "$BENCH" "$a")" "${branch:-(unchanged: no remote)}" >&2
	done
	echo >&2
	if ! ask_yes_no "Use these branches?" y; then
		for a in "${APPS[@]}"; do
			[[ -z "${NEW_BRANCH[$a]}" ]] && continue
			ask branch "Branch for $a" "${NEW_BRANCH[$a]}"
			NEW_BRANCH[$a]=$branch
		done
	fi

	py=$(python_for_major "$major"); node=$(node_for_major "$major")
	local env_py
	env_py=$("$BENCH/env/bin/python" -c 'import sys;print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || echo '?')
	info "Python in bench env: $env_py (recommended for target: $py); Node recommended: $node"
	local change_py=0 change_node=0
	[[ "$env_py" != "$py" ]] && ask_yes_no "Rebuild the Python environment with Python $py?" y && change_py=1
	[[ "$(tr -d '[:space:]' <"$BENCH/.nvmrc" 2>/dev/null)" != "$node" ]] && ask_yes_no "Switch this bench to Node $node?" y && change_node=1

	check_dirty
	warn_dev_server
	backup_sites
	ask_yes_no "Start the upgrade now?" y || die "Aborted."

	if ((change_node)); then
		install_node "$node"
		echo "$node" >"$BENCH/.nvmrc"
		use_node_for_bench "$BENCH"
	fi

	header "Switching branches"
	# Group apps by target branch: bench switch-to-branch takes one branch per call.
	declare -A BY_BRANCH=()
	for a in "${APPS[@]}"; do
		branch=${NEW_BRANCH[$a]}
		[[ -z "$branch" || "$branch" == "$(app_branch "$BENCH" "$a")" ]] && continue
		BY_BRANCH[$branch]+="$a "
	done
	for branch in "${!BY_BRANCH[@]}"; do
		# shellcheck disable=SC2086
		with_bench "$BENCH" switch-to-branch "$branch" ${BY_BRANCH[$branch]} --upgrade
	done

	if ((change_py)); then
		install_uv
		local pybin
		pybin=$(install_python "$py")
		header "Rebuilding the Python environment with Python $py"
		with_bench "$BENCH" migrate-env "$pybin"
	fi

	header "Installing requirements, migrating sites and building assets"
	run_bench_update --no-backup --force "${RESET_FLAG[@]}"
	if [[ -f "$BENCH/.frappe-setup.env" ]]; then
		sed -i -e "s/^FRAPPE_BRANCH=.*/FRAPPE_BRANCH=$target/" -e "s/^PYTHON_VERSION=.*/PYTHON_VERSION=$py/" \
			-e "s/^NODE_VERSION=.*/NODE_VERSION=$node/" "$BENCH/.frappe-setup.env"
	fi
	((PROD)) && reload_production "$BENCH"
}

do_apps() {
	local -a pick=()
	choose_multi pick "Update which apps?" "" "${APPS[@]}"
	((${#pick[@]})) || die "No apps selected."
	local list
	list=$(IFS=,; echo "${pick[*]}")
	do_update --apps "$list"
}

show_status
[[ -n "$ACTION" ]] || choose ACTION "What do you want to do?" 1 \
	"update|Pull latest changes on current branches, migrate all sites, rebuild, restart" \
	"upgrade|Upgrade to another Frappe major version (e.g. v15 -> v16)" \
	"apps|Update only selected apps (and migrate all sites)" \
	"migrate|Only run migrations on all sites" \
	"build|Only rebuild assets" \
	"quit|Exit"

case "$ACTION" in
	update)
		ask_yes_no "Update ${#APPS[@]} app(s) and migrate ${#SITES[@]} site(s)?" y || die "Aborted."
		do_update
		;;
	upgrade) do_upgrade ;;
	apps) do_apps ;;
	migrate)
		ensure_bench_redis "$BENCH"
		for s in "${SITES[@]}"; do header "Migrating $s"; with_bench "$BENCH" --site "$s" migrate; done
		;;
	build) with_bench "$BENCH" build ;;
	quit) exit 0 ;;
esac

if ((PROD)) && [[ "$ACTION" != quit ]]; then
	with_bench "$BENCH" restart || as_root supervisorctl restart all || true
fi
mapfile -t APPS < <(bench_apps "$BENCH")
show_status
success "Finished."
