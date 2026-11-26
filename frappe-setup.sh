#!/usr/bin/env bash
# Main menu for Frappe-Setup-Scripts.
# Usage: ./frappe-setup.sh [install|update|sites|ops|check] [--plain] [--quiet]

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/preflight.sh
. "$SCRIPT_DIR/lib/preflight.sh"
strict_mode
ui_parse_flags "$@"; set -- "${FSS_REST_ARGS[@]}"

# check: only run the system checks and print the result.
run_check() {
	header "System check"
	require_supported_os
	local mode=development
	[[ "${1:-}" == production ]] && mode=production
	_PF_RESULTS=()
	pf_check_platform
	pf_check_memory
	pf_check_cpu
	pf_check_disk "$HOME"
	pf_check_ports "$mode"
	pf_check_network
	local rc=0
	preflight_report || rc=$?
	case "$rc" in
		0) success "This machine is ready for Frappe." ;;
		1) warn "Ready, with warnings (see above)." ;;
		*) error "Some checks failed (see above)." ;;
	esac
	return 0
}

case "${1:-}" in
	install) shift; exec bash "$SCRIPT_DIR/install.sh" "$@" ;;
	update) shift; exec bash "$SCRIPT_DIR/update-bench.sh" "$@" ;;
	sites) shift; exec bash "$SCRIPT_DIR/manage-sites.sh" "$@" ;;
	ops) shift; exec bash "$SCRIPT_DIR/ops.sh" "$@" ;;
	check|doctor) shift; run_check "$@"; exit 0 ;;
	-h|--help) sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'; echo; ui_flags_help; exit 0 ;;
	'') ;;
	*) die "Unknown command: $1 (use install, update, sites, ops or check)" ;;
esac

# Status of the benches already on this machine, shown above the menu.
bench_summary() {
	local b mode n out='' major
	while IFS= read -r b; do
		[[ -z "$b" ]] && continue
		mode=development; bench_is_production "$b" && mode=production
		n=$(bench_sites "$b" | grep -c . || true)
		major=$(frappe_major_of_bench "$b" 2>/dev/null || true)
		out+=$(printf '   %-34s Frappe %-8s %-12s %s site(s)' "${b/#$HOME/\~}" "${major:-?}" "$mode" "$n")$'\n'
	done < <(find_benches)
	printf '%s' "${out%$'\n'}"
}

ui_set_title "Frappe Setup Scripts"
header "Frappe Setup Scripts"
detect_os
status=$(bench_summary)
default=1
if [[ -n "$status" ]]; then
	ui_details "Benches on this machine:"$'\n'"$status"
	default=2
else
	ui_details "No Frappe bench found on this machine yet. Start with 'install'."
fi
choose ACTION "What do you want to do?" "$default" \
	"install|Install Frappe + apps on this machine (new bench)" \
	"update|Update or upgrade an existing bench and all its sites" \
	"sites|Create, migrate, back up, restore or remove sites" \
	"ops|Production: scheduled backups, restore, rollback, health, security" \
	"check|Check this machine (memory, disk, ports, network)" \
	"quit|Exit"
case "$ACTION" in
	install) exec bash "$SCRIPT_DIR/install.sh" ;;
	update) exec bash "$SCRIPT_DIR/update-bench.sh" ;;
	sites) exec bash "$SCRIPT_DIR/manage-sites.sh" ;;
	ops) exec bash "$SCRIPT_DIR/ops.sh" ;;
	check) run_check ;;
	quit) exit 0 ;;
esac
