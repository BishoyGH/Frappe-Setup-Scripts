#!/usr/bin/env bash
# shellcheck shell=bash
# Pre-flight checks: memory, disk, CPU, ports, network, WSL/systemd, DNS.
# Each check records "status|label|detail" with status ok, warn or fail.

[[ -n "${_FSS_PREFLIGHT_LOADED:-}" ]] && return 0
_FSS_PREFLIGHT_LOADED=1

_PF_RESULTS=()
_pf() { _PF_RESULTS+=("$1|$2|$3"); }

_pf_mb() { awk -v k="$1" '$1 == k":" { printf "%d", $2 / 1024 }' /proc/meminfo 2>/dev/null; }

# _pf_free_mb <path>: free space (MB) on the filesystem holding <path> (or its nearest existing parent)
_pf_free_mb() {
	local p=$1
	while [[ ! -e "$p" && "$p" != / ]]; do p=$(dirname "$p"); done
	df -Pk "$p" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 }'
}
_pf_fs() { local p=$1; while [[ ! -e "$p" && "$p" != / ]]; do p=$(dirname "$p"); done; df -P "$p" 2>/dev/null | awk 'NR == 2 { print $6 }'; }

_pf_gb() { awk -v m="$1" 'BEGIN { printf "%.1f GB", m / 1024 }'; }

pf_check_memory() {
	local mem swap
	mem=$(_pf_mb MemTotal); swap=$(_pf_mb SwapTotal)
	mem=${mem:-0}; swap=${swap:-0}
	local detail
	detail="$(_pf_gb "$mem") RAM, $(_pf_gb "$swap") swap"
	if ((mem + swap < 2000)); then
		_pf fail "Memory" "$detail. At least 2 GB (RAM + swap) is needed; 4 GB is recommended. Asset builds will run out of memory."
	elif ((mem < 3800)); then
		_pf warn "Memory" "$detail. 4 GB RAM is recommended; builds with ERPNext may be slow or fail without swap."
	else
		_pf ok "Memory" "$detail"
	fi
}

pf_check_cpu() {
	local n
	n=$(nproc 2>/dev/null || echo 1)
	if ((n < 2)); then _pf warn "CPU" "$n core. It works, but installs and builds will be slow."
	else _pf ok "CPU" "$n cores"
	fi
}

pf_check_disk() {
	local path=${1:-$HOME} free free_root fs fs_root
	free=$(_pf_free_mb "$path"); free=${free:-0}
	fs=$(_pf_fs "$path")
	if ((free < 5000)); then
		_pf fail "Disk ($fs)" "$(_pf_gb "$free") free. A bench with apps needs at least 5 GB; 15 GB or more is recommended."
	elif ((free < 15000)); then
		_pf warn "Disk ($fs)" "$(_pf_gb "$free") free. 15 GB or more is recommended (apps, node_modules, backups)."
	else
		_pf ok "Disk ($fs)" "$(_pf_gb "$free") free"
	fi
	fs_root=$(_pf_fs /var/lib)
	if [[ -n "$fs_root" && "$fs_root" != "$fs" ]]; then
		free_root=$(_pf_free_mb /var/lib); free_root=${free_root:-0}
		if ((free_root < 2000)); then
			_pf warn "Disk ($fs_root)" "$(_pf_gb "$free_root") free. MariaDB stores databases in /var/lib/mysql."
		else
			_pf ok "Disk ($fs_root)" "$(_pf_gb "$free_root") free (MariaDB data)"
		fi
	fi
}

# _pf_port_owner <port>: prints the listening process name, empty if the port is free.
# Returns 1 if the port is free.
_pf_port_owner() {
	local port=$1 out=''
	if command -v ss >/dev/null 2>&1; then
		# Process names of other users' listeners need root; use sudo only if it does not prompt.
		if is_root; then out=$(ss -Hltnp "sport = :$port" 2>/dev/null || true)
		else out=$(sudo -n ss -Hltnp "sport = :$port" 2>/dev/null || ss -Hltnp "sport = :$port" 2>/dev/null || true)
		fi
		if [[ -z "$out" ]]; then return 1; fi
		grep -oE 'users:\(\("[^"]+"' <<<"$out" | head -1 | cut -d'"' -f2
		return 0
	fi
	(exec 3<>"/dev/tcp/127.0.0.1/$port") 2>/dev/null || return 1
	return 0
}

# pf_check_ports <mode>
pf_check_ports() {
	local mode=$1 p owner busy=() label
	local -a ports
	if [[ "$mode" == production ]]; then ports=(80 443); else ports=(8000 9000 11000 13000); fi
	for p in "${ports[@]}"; do
		if owner=$(_pf_port_owner "$p"); then
			case "$p:${owner:-?}" in
				80:nginx|443:nginx) ;; # nginx gets configured for Frappe
				*) busy+=("$p${owner:+ ($owner)}") ;;
			esac
		fi
	done
	label="Ports"
	if ((${#busy[@]})); then
		if [[ "$mode" == production ]]; then
			_pf warn "$label" "In use: ${busy[*]}. nginx needs ports 80 and 443; stop the other web server first."
		else
			_pf warn "$label" "In use: ${busy[*]}. Another bench may be running; 'bench start' of the new bench would clash (change ports with bench set-config)."
		fi
	else
		_pf ok "$label" "${ports[*]} free$([[ "$mode" == production ]] && echo ' (or used by nginx)')"
	fi
	if owner=$(_pf_port_owner 3306); then
		case "${owner:-}" in
			mariadbd|mysqld|mariadb|'') _pf ok "Port 3306" "database server already running${owner:+ ($owner)}; it will be reused" ;;
			*) _pf warn "Port 3306" "used by $owner, not MariaDB." ;;
		esac
	fi
}

# _pf_reach <url>: HTTPS reachability
_pf_reach() {
	if command -v curl >/dev/null 2>&1; then
		curl -sS -o /dev/null --max-time 12 -I "$1" 2>/dev/null
	else
		local host=${1#https://}; host=${host%%/*}
		timeout 8 bash -c "exec 3<>/dev/tcp/$host/443" 2>/dev/null
	fi
}

pf_check_network() {
	local u failed=() host
	for u in https://github.com https://pypi.org/simple/ https://registry.npmjs.org/ https://raw.githubusercontent.com/; do
		host=${u#https://}; host=${host%%/*}
		_pf_reach "$u" || failed+=("$host")
	done
	if [[ " ${failed[*]} " == *" github.com "* ]]; then
		_pf fail "Network" "Cannot reach ${failed[*]}. Frappe and its apps are downloaded from GitHub; check the connection or proxy."
	elif ((${#failed[@]})); then
		_pf warn "Network" "Cannot reach ${failed[*]}. Python or Node packages may fail to download."
	else
		_pf ok "Network" "github.com, pypi.org, npmjs.org reachable"
	fi
}

pf_check_platform() {
	if ((IS_WSL)); then
		if grep -qi 'wsl2\|microsoft-standard' /proc/sys/kernel/osrelease 2>/dev/null; then
			_pf ok "WSL" "WSL 2$(has_systemd && echo ', systemd on' || echo ', systemd off (services are started by the scripts)')"
		else
			_pf fail "WSL" "This looks like WSL 1. MariaDB and Redis need WSL 2: run 'wsl --set-version <distro> 2' in Windows."
		fi
	elif ! has_systemd; then
		_pf warn "Init system" "systemd is not running (container?). Services are started directly, and do not start again after a reboot."
	fi
}

# pf_check_dns <domain>: does the domain resolve to this machine? (needed for Let's Encrypt)
pf_check_dns() {
	local domain=$1 resolved local_ips
	resolved=$(getent ahostsv4 "$domain" 2>/dev/null | awk '{ print $1; exit }')
	if [[ -z "$resolved" ]]; then
		_pf warn "DNS $domain" "does not resolve yet. Point an A record to this server before requesting HTTPS."
		return 0
	fi
	local_ips=" $(hostname -I 2>/dev/null || ip -4 -o addr show 2>/dev/null | awk '{ sub(/\/.*/, "", $4); printf "%s ", $4 }') "
	if [[ "$local_ips" == *" $resolved "* ]]; then
		_pf ok "DNS $domain" "points to $resolved (this machine)"
	else
		_pf warn "DNS $domain" "points to $resolved, which is not an address of this machine. That is fine behind NAT or a cloud public IP; otherwise fix the A record."
	fi
}

# preflight_report: print the results table; returns 0 = all ok, 1 = warnings, 2 = failures.
preflight_report() {
	local e st label detail sym worst=0 text=''
	for e in "${_PF_RESULTS[@]}"; do
		st=${e%%|*}; e=${e#*|}; label=${e%%|*}; detail=${e#*|}
		case "$st" in
			ok) sym="${C_GREEN}✔${C_RESET}" ;;
			warn) sym="${C_YELLOW}!${C_RESET}"; ((worst < 1)) && worst=1 ;;
			fail) sym="${C_RED}✖${C_RESET}"; worst=2 ;;
		esac
		text+=$(printf '   %s %-18s %s' "$sym" "$label" "$detail")$'\n'
	done
	ui_details "${text%$'\n'}"
	return "$worst"
}

# preflight_checks <mode> [bench-parent-dir]: run the machine checks and ask whether to go on
# when something failed. Returns 1 if the user chose to stop.
preflight_checks() {
	local mode=${1:-development} dir=${2:-$HOME} rc=0
	_PF_RESULTS=()
	info "Checking this machine..."
	pf_check_platform
	pf_check_memory
	pf_check_cpu
	pf_check_disk "$dir"
	pf_check_ports "$mode"
	pf_check_network
	preflight_report || rc=$?
	case "$rc" in
		0) success "All checks passed." ;;
		1) info "Warnings only; you can continue." ;;
		2)
			error "Some checks failed; the installation will probably not work."
			if [[ "${FSS_SKIP_CHECKS:-0}" == 1 ]]; then
				warn "FSS_SKIP_CHECKS=1: continuing anyway."
			elif [[ "${ASSUME_DEFAULTS:-0}" == 1 && "${FSS_STRICT_CHECKS:-0}" != 1 ]]; then
				warn "Unattended run: continuing anyway (set FSS_STRICT_CHECKS=1 to stop here instead)."
			else
				ask_yes_no "Continue anyway?" n || return 1
			fi
			;;
	esac
	return 0
}

# --------------------------------------------------------------------------
# Swap: small machines need it for asset builds
# --------------------------------------------------------------------------
in_container() {
	[[ -f /.dockerenv || -f /run/.containerenv ]] && return 0
	command -v systemd-detect-virt >/dev/null 2>&1 && systemd-detect-virt -cq 2>/dev/null && return 0
	return 1
}

# swap_recommended: true when RAM < 4 GB, swap < 1 GB, and a swap file can be created here.
swap_recommended() {
	local mem swap
	mem=$(_pf_mb MemTotal); swap=$(_pf_mb SwapTotal)
	((IS_WSL)) && return 1
	in_container && return 1
	[[ -e /swapfile ]] && return 1
	((${mem:-0} < 3800 && ${swap:-0} < 1000)) || return 1
	(($(_pf_free_mb /) > 8000))
}

# create_swapfile [size-GB]
create_swapfile() {
	local gb=${1:-4}
	header "Creating a ${gb} GB swap file"
	run as_root fallocate -l "${gb}G" /swapfile || run as_root dd if=/dev/zero of=/swapfile bs=1M count=$((gb * 1024))
	run as_root chmod 600 /swapfile
	run as_root mkswap /swapfile
	if run as_root swapon /swapfile; then
		grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | as_root tee -a /etc/fstab >/dev/null
		success "Swap enabled ($(_pf_gb "$(_pf_mb SwapTotal)"))."
	else
		warn "Could not enable swap; continuing without it."
		as_root rm -f /swapfile
	fi
}
