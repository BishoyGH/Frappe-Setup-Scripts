#!/usr/bin/env bash
# Main menu for Frappe-Setup-Scripts.
# Usage: ./frappe-setup.sh [install|update|sites]

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
strict_mode

case "${1:-}" in
	install) shift; exec bash "$SCRIPT_DIR/install.sh" "$@" ;;
	update) shift; exec bash "$SCRIPT_DIR/update-bench.sh" "$@" ;;
	sites) shift; exec bash "$SCRIPT_DIR/manage-sites.sh" "$@" ;;
	-h|--help) sed -n '2,3p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
	'') ;;
	*) die "Unknown command: $1 (use install, update or sites)" ;;
esac

header "Frappe Setup Scripts"
choose ACTION "What do you want to do?" 1 \
	"install|Install Frappe + apps on this machine (new bench)" \
	"update|Update or upgrade an existing bench and all its sites" \
	"sites|Create, migrate, back up, restore or remove sites" \
	"quit|Exit"
case "$ACTION" in
	install) exec bash "$SCRIPT_DIR/install.sh" ;;
	update) exec bash "$SCRIPT_DIR/update-bench.sh" ;;
	sites) exec bash "$SCRIPT_DIR/manage-sites.sh" ;;
	quit) exit 0 ;;
esac
