#!/usr/bin/env bash
# shellcheck shell=bash
# Resource safety, sourced by common.sh:
#  - free disk space and memory, including the Windows drive that holds WSL's virtual disk
#  - a watchdog (resource_guard_start) that stops a run before it fills the disk, exhausts memory,
#    or writes an endless log
#  - WSL helpers: Windows drives, .wslconfig, Windows entries on PATH, page cache
#
# Environment (all optional):
#   FSS_MIN_FREE_MB=2048   stop when free disk space (Linux or, on WSL, the Windows drive) drops below this
#   FSS_MIN_MEM_MB=150     stop when available memory + free swap stays below this for 15 seconds
#   FSS_LOG_MAX_MB=500     stop when the log of one run grows past this (a command printing endlessly)
#   FSS_GUARD=0            turn the watchdog off

[[ -n "${_FSS_RESOURCES_LOADED:-}" ]] && return 0
_FSS_RESOURCES_LOADED=1

# res_meminfo_mb <MemTotal|MemAvailable|SwapTotal|SwapFree>: a /proc/meminfo value in MB (0 if unknown)
res_meminfo_mb() {
	local v
	v=$(awk -v k="$1" '$1 == k":" { printf "%d", $2 / 1024; exit }' /proc/meminfo 2>/dev/null)
	printf '%s' "${v:-0}"
}

# res_existing <path>: <path> or its nearest existing parent
res_existing() {
	local p=$1
	while [[ ! -e "$p" && "$p" != / && -n "$p" ]]; do p=$(dirname "$p"); done
	printf '%s' "${p:-/}"
}

# res_free_mb <path>: free space (MB) on the filesystem holding <path>
res_free_mb() {
	local v
	v=$(df -Pk "$(res_existing "$1")" 2>/dev/null | awk 'NR == 2 { printf "%d", $4 / 1024 }')
	printf '%s' "${v:-0}"
}

# res_mountpoint <path>: mount point of the filesystem holding <path>
res_mountpoint() { df -P "$(res_existing "$1")" 2>/dev/null | awk 'NR == 2 { print $6 }'; }

res_gb() { awk -v m="$1" 'BEGIN { printf "%.1f GB", m / 1024 }'; }

# --------------------------------------------------------------------------
# WSL
# The distro's files live in a virtual disk (ext4.vhdx) on a Windows drive, usually C:. Inside WSL,
# df reports the virtual disk's maximum size (often 1 TB), not the space left on that Windows drive,
# so a check of / alone passes while C: fills up. The virtual disk also does not shrink when files
# are deleted, unless it is sparse.
# --------------------------------------------------------------------------

# wsl_drive_mounts [mounts-file]: "<drive letter> <mount point>" for each mounted Windows drive.
wsl_drive_mounts() {
	awk '
		$1 ~ /^[A-Za-z]:/ { print tolower(substr($1, 1, 1)), $2; next }
		$1 == "drvfs" && match($4, /path=[A-Za-z]:/) { print tolower(substr($4, RSTART + 5, 1)), $2 }
	' "${1:-/proc/mounts}" 2>/dev/null | awk '!seen[$1]++'
}

# wsl_lxss_base_path <distro>: the folder holding the distro's virtual disk, from `reg.exe query ... /s`
# output on stdin (Windows line endings are fine).
wsl_lxss_base_path() {
	tr -d '\r' | awk -v want="$1" '
		function flush() { if (name == want && base != "") { print base; found = 1; exit } name = ""; base = "" }
		/^HKEY_/ { flush(); next }
		$1 == "DistributionName" { $1 = ""; $2 = ""; sub(/^ +/, ""); name = $0 }
		$1 == "BasePath" { $1 = ""; $2 = ""; sub(/^ +/, ""); base = $0 }
		END { if (!found) flush() }
	'
}

FSS_WSL_HOST_DRIVE='' FSS_WSL_HOST_MNT='' _FSS_WSL_DETECTED=0
_wsl_c_mount() { wsl_drive_mounts | awk '$1 == "c" { print $2; exit }'; }

# wsl_detect_host_drive: set FSS_WSL_HOST_DRIVE (e.g. "C:") and FSS_WSL_HOST_MNT (e.g. /mnt/c) to the
# Windows drive that holds this distro's virtual disk. Falls back to C: when Windows cannot be asked.
wsl_detect_host_drive() {
	((_FSS_WSL_DETECTED)) && return 0
	_FSS_WSL_DETECTED=1
	((IS_WSL)) || return 0
	local mounts c reg base letter=''
	mounts=$(wsl_drive_mounts)
	c=$(awk '$1 == "c" { print $2; exit }' <<<"$mounts")
	reg="$c/Windows/System32/reg.exe"
	if [[ -n "$c" && -x "$reg" && -n "${WSL_DISTRO_NAME:-}" ]] && command -v timeout >/dev/null 2>&1; then
		base=$( (cd "$c" && timeout 10 "$reg" query 'HKCU\Software\Microsoft\Windows\CurrentVersion\Lxss' /s) </dev/null 2>/dev/null |
			wsl_lxss_base_path "$WSL_DISTRO_NAME" || true)
		[[ "$base" =~ ([A-Za-z]): ]] && letter=${BASH_REMATCH[1],,}
	fi
	letter=${letter:-c}
	FSS_WSL_HOST_MNT=$(awk -v l="$letter" '$1 == l { print $2; exit }' <<<"$mounts")
	[[ -n "$FSS_WSL_HOST_MNT" ]] && FSS_WSL_HOST_DRIVE="${letter^^}:"
	return 0
}

# wsl_on_windows_drive <path>: is <path> on a Windows drive (/mnt/c, ...) rather than the Linux disk?
wsl_on_windows_drive() {
	local mp
	mp=$(res_mountpoint "$1")
	[[ -n "$mp" ]] && wsl_drive_mounts | awk -v m="$mp" '$2 == m { f = 1 } END { exit !f }'
}

# wsl_windows_home: the Windows user profile folder as a Linux path (e.g. /mnt/c/Users/me), or nothing.
wsl_windows_home() {
	local c win drive rest mnt
	c=$(_wsl_c_mount)
	[[ -n "$c" && -x "$c/Windows/System32/cmd.exe" ]] && command -v timeout >/dev/null 2>&1 || return 0
	win=$( (cd "$c" && timeout 10 "$c/Windows/System32/cmd.exe" /d /c 'echo %USERPROFILE%') </dev/null 2>/dev/null | tr -d '\r' | tail -1)
	[[ "$win" =~ ^([A-Za-z]):\\(.*)$ ]] || return 0
	drive=${BASH_REMATCH[1],,} rest=${BASH_REMATCH[2]//\\//}
	mnt=$(wsl_drive_mounts | awk -v l="$drive" '$1 == l { print $2; exit }')
	[[ -n "$mnt" && -d "$mnt/$rest" ]] && printf '%s/%s' "${mnt%/}" "$rest"
	return 0
}

# wslconfig_has <file> <key>: is <key> set (not commented out) in a .wslconfig?
wslconfig_has() { [[ -f "$1" ]] && grep -qiE "^[[:space:]]*$2[[:space:]]*=" "$1"; }

# wslconfig_recommended: the .wslconfig the installer suggests for this machine.
wslconfig_recommended() {
	local mem gb
	mem=$(res_meminfo_mb MemTotal)
	# WSL gets half of the Windows memory by default. Cap it at 6 GB (a Frappe + ERPNext build needs
	# about 3 GB) so Windows keeps enough, but never go below 4 GB.
	gb=$(( (mem + 512) / 1024 )); ((gb > 6)) && gb=6; ((gb < 4)) && gb=4
	cat <<EOF
# Written by Frappe-Setup-Scripts. Takes effect after 'wsl --shutdown'.
[wsl2]
# Most memory WSL may use; Windows keeps the rest.
memory=${gb}GB
swap=4GB

[experimental]
# Give memory WSL no longer needs (file cache) back to Windows.
autoMemoryReclaim=gradual
# Let new virtual disks shrink when files are deleted.
sparseVhd=true
EOF
}

# wsl_strip_windows_path: drop Windows folders (/mnt/c/...) from PATH for this run. WSL adds them by
# default, which makes every command lookup slower and can pick up Windows' node, npm or yarn.
wsl_strip_windows_path() {
	((IS_WSL)) || return 0
	local -a parts keep=()
	local p
	IFS=: read -ra parts <<<"$PATH"
	for p in "${parts[@]}"; do
		[[ "$p" =~ ^/mnt/[A-Za-z](/|$) ]] && continue
		keep+=("$p")
	done
	PATH=$(IFS=:; printf '%s' "${keep[*]}")
	export PATH
}

# wsl_drop_caches: let WSL hand the Linux file cache back to Windows (it otherwise keeps growing
# toward WSL's memory limit during big downloads and builds). Quietly does nothing without sudo.
wsl_drop_caches() {
	((IS_WSL)) || return 0
	sync 2>/dev/null || true
	if is_root; then echo 1 >/proc/sys/vm/drop_caches 2>/dev/null || true
	else sudo -n sh -c 'echo 1 > /proc/sys/vm/drop_caches' >/dev/null 2>&1 || true
	fi
	return 0
}

# res_disk_problem <path> <min-MB>: prints why disk space is too low (empty and status 1 when fine).
res_disk_problem() {
	local path=$1 min=$2 free mp
	free=$(res_free_mb "$path")
	if ((free < min)); then
		mp=$(res_mountpoint "$path")
		printf 'only %s left on %s (the limit is %s).' "$(res_gb "$free")" "${mp:-$path}" "$(res_gb "$min")"
		return 0
	fi
	if ((IS_WSL)) && [[ -n "$FSS_WSL_HOST_MNT" ]]; then
		free=$(res_free_mb "$FSS_WSL_HOST_MNT")
		if ((free < min)); then
			printf "only %s left on Windows drive %s, where WSL's virtual disk grows (the limit is %s)." \
				"$(res_gb "$free")" "$FSS_WSL_HOST_DRIVE" "$(res_gb "$min")"
			return 0
		fi
	fi
	return 1
}

# --------------------------------------------------------------------------
# Watchdog
# --------------------------------------------------------------------------
_FSS_GUARD_PID='' _FSS_GUARD_FLAG=''

# _res_proc_tree: "pid ppid" of every process
_res_proc_tree() {
	local f l rest
	for f in /proc/[0-9]*/stat; do
		read -r l <"$f" 2>/dev/null || continue
		rest=${l##*) }
		# shellcheck disable=SC2086  # split "state ppid ..." into fields
		set -- $rest
		printf '%s %s\n' "${l%% *}" "$2"
	done
}

# res_descendants <pid> [excluded-pid...]: every descendant of <pid>, parents first, skipping the
# excluded processes and everything below them.
res_descendants() {
	local root=$1; shift
	_res_proc_tree | awk -v root="$root" -v ex=" $* " '
		{ kids[$2] = kids[$2] " " $1 }
		END {
			n = 1; q[1] = root
			for (i = 1; i <= n; i++) {
				m = split(kids[q[i]], k, " ")
				for (j = 1; j <= m; j++) {
					if (index(ex, " " k[j] " ")) continue
					q[++n] = k[j]; print k[j]
				}
			}
		}'
}

# _res_stop_tree <pid> <excluded-pid...>: TERM the descendants of <pid> (root-owned ones through sudo).
_res_stop_tree() {
	local -a pids
	mapfile -t pids < <(res_descendants "$@")
	((${#pids[@]})) || return 0
	kill -TERM "${pids[@]}" 2>/dev/null || true
	is_root || sudo -n kill -TERM "${pids[@]}" 2>/dev/null || true
}

# _res_guard_loop <main-pid> <path> <log-pid>: runs in the background; see resource_guard_start.
_res_guard_loop() {
	trap - ERR EXIT TERM; set +e +o pipefail
	local main=$1 path=$2 logpid=$3 reason low_mem=0 mem last_snap=0 now size
	local interval=${FSS_GUARD_INTERVAL:-5} min_free=${FSS_MIN_FREE_MB:-2048} min_mem=${FSS_MIN_MEM_MB:-150}
	local log_max=$(( ${FSS_LOG_MAX_MB:-500} * 1024 * 1024 ))
	while kill -0 "$main" 2>/dev/null; do
		sleep "$interval" >/dev/null 2>&1
		kill -0 "$main" 2>/dev/null || break
		reason=$(res_disk_problem "$path" "$min_free") && reason="Disk almost full: $reason"
		mem=$(( $(res_meminfo_mb MemAvailable) + $(res_meminfo_mb SwapFree) ))
		if ((mem < min_mem)); then low_mem=$((low_mem + 1)); else low_mem=0; fi
		if [[ -z "$reason" ]] && ((low_mem >= 3)); then
			reason="Memory almost exhausted: ${mem} MB of memory and swap left (the limit is ${min_mem} MB)."
		fi
		if [[ -z "$reason" && -n "${FSS_LOG_FILE:-}" ]]; then
			size=$(stat -c %s "$FSS_LOG_FILE" 2>/dev/null || echo 0)
			((size > log_max)) && reason="The log grew past ${FSS_LOG_MAX_MB:-500} MB: a command keeps printing the same output."
		fi
		now=$(date +%s)
		if [[ -n "${FSS_LOG_FILE:-}" ]] && { ((now - last_snap >= 60)) || [[ -n "$reason" ]]; }; then
			last_snap=$now
			printf '# resources %s: %s MB free on %s%s, %s MB memory available, %s MB swap free\n' \
				"$(date +%T)" "$(res_free_mb "$path")" "$(res_mountpoint "$path")" \
				"$( ((IS_WSL)) && [[ -n "$FSS_WSL_HOST_MNT" ]] && printf ', %s MB free on %s' "$(res_free_mb "$FSS_WSL_HOST_MNT")" "$FSS_WSL_HOST_DRIVE")" \
				"$(res_meminfo_mb MemAvailable)" "$(res_meminfo_mb SwapFree)" >>"$FSS_LOG_FILE" 2>/dev/null
		fi
		[[ -n "$reason" ]] || continue
		printf '%s\n' "$reason" >"$_FSS_GUARD_FLAG"
		printf '\n%s✖  Safety stop. %s%s\n%s   Stopping the running command so the machine stays usable.%s\n' \
			"${C_RED}${C_BOLD}" "$reason" "${C_RESET}" "${C_RED}" "${C_RESET}" >&2
		_res_stop_tree "$main" "$BASHPID" "$logpid"
		sleep 5 >/dev/null 2>&1
		# If the script itself is still busy (not a command it started), stop it too.
		kill -0 "$main" 2>/dev/null && kill -TERM "$main" 2>/dev/null
		break
	done
}

# resource_guard_start [path]: watch free disk space (of [path], default $HOME, and on WSL of the
# Windows drive), memory and the log size while the script runs; stop the run cleanly when one of
# them hits its limit, instead of letting it fill the disk or crash the machine.
resource_guard_start() {
	[[ "${FSS_GUARD:-1}" == 0 || -n "$_FSS_GUARD_PID" ]] && return 0
	local path=${1:-$HOME}
	wsl_detect_host_drive
	_FSS_GUARD_FLAG=$(mktemp "${TMPDIR:-/tmp}/fss-guard.XXXXXX") || return 0
	# stdout is not kept open: a background process holding the log pipe would delay the exit.
	_res_guard_loop "$$" "$path" "${_FSS_LOG_PID:-0}" </dev/null >/dev/null &
	_FSS_GUARD_PID=$!
	# A stopped run ends through the normal exit path (exit hooks, log flush).
	trap 'exit 143' TERM
	on_exit resource_guard_stop
}

# resource_guard_stop: stop the watchdog; explain what happened if it stopped the run.
resource_guard_stop() {
	[[ -n "$_FSS_GUARD_PID" ]] || return 0
	kill "$_FSS_GUARD_PID" 2>/dev/null || true
	wait "$_FSS_GUARD_PID" 2>/dev/null || true
	_FSS_GUARD_PID=''
	if [[ -s "$_FSS_GUARD_FLAG" ]]; then
		error "Stopped by the safety check: $(cat "$_FSS_GUARD_FLAG")"
		resource_advice
	fi
	rm -f "$_FSS_GUARD_FLAG"
	return 0
}

# resource_tripped: did the watchdog stop this run?
resource_tripped() { [[ -n "$_FSS_GUARD_FLAG" && -s "$_FSS_GUARD_FLAG" ]]; }

# resource_advice: what to do after a safety stop or a low-resource warning.
resource_advice() {
	info "Free some space or memory, then run the same command again: finished steps are skipped."
	if ((IS_WSL)); then
		info "WSL keeps its files in a virtual disk on Windows drive ${FSS_WSL_HOST_DRIVE:-C:} that does not shrink by itself."
		info "  Free space inside WSL:  yarn cache clean; uv cache prune; sudo apt-get clean (or sudo pacman -Sc)"
		info "  Then give it back to Windows (PowerShell): wsl --shutdown; wsl --manage ${WSL_DISTRO_NAME:-<distro>} --set-sparse true"
		info "  Limit WSL's memory in %UserProfile%\\.wslconfig (see the README section 'WSL')."
	fi
	info "Limits: FSS_MIN_FREE_MB=${FSS_MIN_FREE_MB:-2048}, FSS_MIN_MEM_MB=${FSS_MIN_MEM_MB:-150}, FSS_LOG_MAX_MB=${FSS_LOG_MAX_MB:-500} (FSS_GUARD=0 turns the check off)."
}
