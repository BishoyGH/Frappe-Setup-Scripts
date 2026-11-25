#!/usr/bin/env bash
# shellcheck shell=bash
# Catalog of official Frappe apps and git branch resolution.

[[ -n "${_FSS_APPS_LOADED:-}" ]] && return 0
_FSS_APPS_LOADED=1

# name|repository|title|space-separated dependencies (apps that must be installed first)
# Listed in a dependency-safe install order.
FRAPPE_APP_CATALOG=(
	"payments|https://github.com/frappe/payments|Payments (gateways integration)|"
	"erpnext|https://github.com/frappe/erpnext|ERPNext (accounting, stock, manufacturing, ...)|"
	"telephony|https://github.com/frappe/telephony|Telephony (call integrations)|"
	"hrms|https://github.com/frappe/hrms|Frappe HR & Payroll|erpnext"
	"crm|https://github.com/frappe/crm|Frappe CRM|"
	"helpdesk|https://github.com/frappe/helpdesk|Helpdesk (customer support)|telephony"
	"lms|https://github.com/frappe/lms|Frappe Learning (LMS)|payments"
	"insights|https://github.com/frappe/insights|Insights (BI & reporting)|"
	"builder|https://github.com/frappe/builder|Builder (website builder)|"
	"print_designer|https://github.com/frappe/print_designer|Print Designer|"
	"wiki|https://github.com/frappe/wiki|Wiki|"
	"drive|https://github.com/frappe/drive|Drive (file storage)|"
	"gameplan|https://github.com/frappe/gameplan|Gameplan (team discussions)|"
	"lending|https://github.com/frappe/lending|Lending (loan management)|erpnext"
	"healthcare|https://github.com/frappe/health|Healthcare|erpnext"
	"education|https://github.com/frappe/education|Education|erpnext"
	"webshop|https://github.com/frappe/webshop|Webshop (e-commerce storefront)|erpnext payments"
	"ecommerce_integrations|https://github.com/frappe/ecommerce_integrations|Shopify/Amazon/Unicommerce integrations|erpnext"
)

_catalog_field() { # _catalog_field <app> <index 1-4>
	local entry
	for entry in "${FRAPPE_APP_CATALOG[@]}"; do
		if [[ "${entry%%|*}" == "$1" ]]; then
			cut -d'|' -f"$2" <<<"$entry"
			return 0
		fi
	done
	return 1
}
app_repo()  { _catalog_field "$1" 2; }
app_title() { _catalog_field "$1" 3; }
app_deps()  { _catalog_field "$1" 4; }
app_in_catalog() { _catalog_field "$1" 1 >/dev/null; }

catalog_names() { local e; for e in "${FRAPPE_APP_CATALOG[@]}"; do echo "${e%%|*}"; done; }

# catalog_menu_options: "name|title" lines for choose/choose_multi
catalog_menu_options() {
	local e
	for e in "${FRAPPE_APP_CATALOG[@]}"; do
		printf '%s|%s\n' "$(cut -d'|' -f1 <<<"$e")" "$(cut -d'|' -f3 <<<"$e")"
	done
}

# resolve_app_deps <app...>: prints the apps plus dependencies, in catalog install order.
resolve_app_deps() {
	local -A want=()
	local a d changed=1
	for a in "$@"; do want[$a]=1; done
	while ((changed)); do
		changed=0
		for a in "${!want[@]}"; do
			for d in $(app_deps "$a" 2>/dev/null); do
				if [[ -z "${want[$d]:-}" ]]; then want[$d]=1; changed=1; fi
			done
		done
	done
	for a in $(catalog_names); do
		[[ -n "${want[$a]:-}" ]] && { echo "$a"; unset "want[$a]"; }
	done
	# Custom (non-catalog) apps keep their given order at the end.
	for a in "$@"; do [[ -n "${want[$a]:-}" ]] && echo "$a"; done
	return 0
}

# --------------------------------------------------------------------------
# Git refs
# --------------------------------------------------------------------------
_FSS_REF_CACHE_DIR="${TMPDIR:-/tmp}/frappe-setup-refs-$$"
on_exit "rm -rf '$_FSS_REF_CACHE_DIR'"

# remote_branches <repo-url>: list branch names (cached on disk, so subshells share it)
remote_branches() {
	local url=$1 key
	key=$(printf '%s' "$url" | tr -c 'A-Za-z0-9' '_')
	mkdir -p "$_FSS_REF_CACHE_DIR"
	if [[ ! -s "$_FSS_REF_CACHE_DIR/$key" ]]; then
		git ls-remote --heads "$url" 2>/dev/null | sed 's#.*refs/heads/##' | sort -V >"$_FSS_REF_CACHE_DIR/$key" || true
	fi
	cat "$_FSS_REF_CACHE_DIR/$key"
}

remote_ref_exists() { # remote_ref_exists <url> <branch-or-tag>
	git ls-remote --exit-code "$1" "refs/heads/$2" "refs/tags/$2" >/dev/null 2>&1
}

# frappe_release_branches: version-N branches of frappe, newest first
frappe_release_branches() {
	remote_branches https://github.com/frappe/frappe | grep -E '^version-[0-9]+$' | sort -t- -k2 -nr
}

# pick_app_branch <repo-url> <frappe-branch>: best matching branch for an app.
# Order: same branch as frappe > (for develop) develop > main > master > develop > newest version-N.
pick_app_branch() {
	local url=$1 fb=$2 b
	local branches
	branches=$(remote_branches "$url")
	[[ -z "$branches" ]] && return 1
	if grep -qxF "$fb" <<<"$branches"; then echo "$fb"; return 0; fi
	local major
	major=$(frappe_major_from_ref "$fb")
	if [[ "$major" == develop ]]; then
		for b in develop main master; do grep -qxF "$b" <<<"$branches" && { echo "$b"; return 0; }; done
	fi
	if [[ "$major" =~ ^[0-9]+$ ]] && grep -qxF "version-$major" <<<"$branches"; then echo "version-$major"; return 0; fi
	for b in main master develop; do grep -qxF "$b" <<<"$branches" && { echo "$b"; return 0; }; done
	grep -E '^version-[0-9]+$' <<<"$branches" | sort -t- -k2 -nr | head -1
}

# app_branch_options <repo-url>: interesting branches for a menu (release lines + main/master/develop)
app_branch_options() {
	remote_branches "$1" | grep -E '^(version-[0-9]+|main|master|develop|stable)$' | sort -V
}
