#!/usr/bin/env bash
# Production operations for a Frappe bench:
#   backup    back up every site (database + files) with retention and an optional offsite copy
#   schedule  automatic backups and health checks (cron), offsite storage, alerts
#   restore   restore a site from a local or offsite backup (also from another server)
#   rollback  put the bench back to a restore point taken before an update
#   status    health check: services, workers, sites, scheduler, disk, backups, certificates
#   secure    firewall, fail2ban, swap, automatic security updates, MariaDB tuning
#   domain    add or remove a custom domain on a site (with HTTPS)
#   ssl       certificate expiry and automatic renewal
#
# Usage: ./ops.sh [command] [options]          (no command opens a menu)
#   ./ops.sh backup  [--site SITE] [--no-files] [--no-offsite]
#   ./ops.sh status  [--quiet] [--notify]      exit code 0 = ok, 1 = warnings, 2 = failures
#   ./ops.sh restore [--site SITE] [--yes]
#   ./ops.sh rollback [--yes]
# Set BENCH_PATH to pick the bench without a prompt.

SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
# shellcheck source=lib/common.sh
. "$SCRIPT_DIR/lib/common.sh"
# shellcheck source=lib/prereqs.sh
. "$SCRIPT_DIR/lib/prereqs.sh"
# shellcheck source=lib/ops.sh
. "$SCRIPT_DIR/lib/ops.sh"
strict_mode

usage() { sed -n '2,18p' "$0" | sed 's/^# \{0,1\}//'; }

CMD=${1:-}
[[ $# -gt 0 ]] && shift
case "$CMD" in
	-h|--help|help) usage; exit 0 ;;
	''|backup|schedule|restore|rollback|status|secure|domain|ssl) ;;
	*) usage; die "Unknown command: $CMD" ;;
esac

if is_root && [[ "$CMD" != secure ]]; then
	die "Run this script as the user that owns the bench, not as root (only 'secure' may run as root)."
fi
detect_os
load_runtime_env
command -v bench >/dev/null 2>&1 || [[ "$CMD" == secure ]] || die "bench is not installed for $(id -un). Run ./install.sh first."

QUIET=0
[[ "$CMD" == status && " $* " == *" --quiet "* ]] && QUIET=1
((QUIET)) || header "Frappe production operations"
select_bench BENCH
BENCH_NAME=$(basename "$BENCH")
ops_load_conf "$BENCH"
PROD=0; bench_is_production "$BENCH" && PROD=1

b() { with_bench "$BENCH" "$@"; }

DB_ROOT_PW=${DB_ROOT_PASSWORD:-}
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

# pick_site <varname> [prompt] [preset]
pick_site() {
	local __var=$1 __prompt=${2:-Which site?} __preset=${3:-} __s
	local -a sites=()
	mapfile -t sites < <(bench_sites "$BENCH")
	((${#sites[@]})) || { warn "This bench has no sites yet."; return 1; }
	if [[ -n "$__preset" ]]; then
		[[ " ${sites[*]} " == *" $__preset "* ]] || die "No site named $__preset in $BENCH."
		__s=$__preset
	elif ((${#sites[@]} == 1)); then __s=${sites[0]}; info "Site: ${C_BOLD}$__s${C_RESET}"
	else choose __s "$__prompt" 1 "${sites[@]}"
	fi
	printf -v "$__var" '%s' "$__s"
}

# set_label <dir> <set>: "date time, size, parts" description of a backup set
set_label() {
	local dir=$1 set=$2 ts parts=() f
	ts=${set%%-*}
	for f in database files private-files; do backup_set_part "$dir" "$set" "$f" >/dev/null && parts+=("$f"); done
	printf '%s-%s-%s %s:%s, %s, %s' "${ts:0:4}" "${ts:4:2}" "${ts:6:2}" "${ts:9:2}" "${ts:11:2}" \
		"$(human_size "$dir/$set"-*)" "$(IFS=+; echo "${parts[*]}")"
}

# --------------------------------------------------------------------------
# backup
# --------------------------------------------------------------------------
cmd_backup() {
	local only='' files=$BACKUP_WITH_FILES offsite=1 s dest
	while (($#)); do
		case "$1" in
			--site) only=$2; shift ;;
			--no-files) files=0 ;;
			--no-offsite) offsite=0 ;;
			*) die "Unknown option for backup: $1" ;;
		esac
		shift
	done
	local -a sites=() failed=()
	if [[ -n "$only" ]]; then sites=("$only"); else mapfile -t sites < <(bench_sites "$BENCH"); fi
	((${#sites[@]})) || { warn "No sites to back up."; return 0; }
	if [[ -z "$OFFSITE_REMOTE" ]]; then offsite=0
	elif ((offsite)) && ! command -v rclone >/dev/null 2>&1; then
		warn "rclone is missing; skipping the offsite copy. Run ./ops.sh schedule to set it up again."
		offsite=0; failed+=("offsite (rclone missing)")
	fi
	mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
	ensure_bench_redis "$BENCH"
	info "Backing up ${#sites[@]} site(s) to $BACKUP_DIR$( ((offsite)) && printf ' and %s' "$OFFSITE_REMOTE")"
	for s in "${sites[@]}"; do
		header "Backing up $s"
		dest="$BACKUP_DIR/$s"
		if ! ops_backup_site "$BENCH" "$s" "$dest" "$files"; then
			error "Backup of $s failed."
			failed+=("$s")
			continue
		fi
		info "Newest set: $(set_label "$dest" "$(backup_sets "$dest" | head -1)")"
		prune_backup_sets "$dest" "$BACKUP_KEEP_DAYS" "$BACKUP_KEEP_MIN"
		if ((offsite)); then
			if offsite_push "$dest" "$s"; then offsite_prune "$s"
			else error "Offsite copy of $s failed."; failed+=("$s (offsite)")
			fi
		fi
	done
	local free
	free=$(df -Ph "$BACKUP_DIR" | awk 'NR == 2 { print $4 " free (" $5 " used)" }')
	info "Backup disk: $free"
	if ((${#failed[@]})); then
		ops_notify fail "Backup of bench $BENCH_NAME failed for: ${failed[*]}"
		die "Backup failed for: ${failed[*]}"
	fi
	date +%s >"$BACKUP_DIR/.last-success"
	[[ "${NOTIFY_ON_SUCCESS:-0}" == 1 ]] && ops_notify ok "Backup of ${#sites[@]} site(s) on $BENCH_NAME finished."
	success "Backups finished."
}

# --------------------------------------------------------------------------
# offsite storage
# --------------------------------------------------------------------------
configure_offsite() {
	header "Offsite backup storage"
	ensure_rclone
	local kind base remote provider endpoint region key secret bucket prefix name
	name=$(printf '%s' "fo-$BENCH_NAME" | tr -c 'A-Za-z0-9_-' '-')
	choose kind "Where should backups be copied?" 1 \
		"s3|S3-compatible storage: AWS S3, Cloudflare R2, Backblaze B2, Wasabi, DO Spaces, MinIO" \
		"rclone|A remote you already set up with 'rclone config' (SFTP, Google Drive, ...)" \
		"none|Do not copy backups offsite"
	case "$kind" in
		none) OFFSITE_REMOTE=''; return 0 ;;
		s3)
			choose provider "Storage provider" 1 "AWS|Amazon S3" "Cloudflare|Cloudflare R2" "Other|Backblaze B2 (S3 API) or any other S3 service" \
				"Wasabi|Wasabi" "DigitalOcean|DigitalOcean Spaces" "Minio|MinIO (self-hosted)"
			endpoint=''
			if [[ "$provider" != AWS ]]; then
				ask endpoint "Endpoint URL (e.g. https://<account>.r2.cloudflarestorage.com, https://s3.<region>.backblazeb2.com)" "${S3_ENDPOINT:-}"
			fi
			case "$provider" in
				AWS) region=us-east-1 ;;
				Cloudflare) region=auto ;;
				*) region='' ;;
			esac
			ask_optional region "Region" "${S3_REGION:-$region}"
			ask key "Access key ID" "${S3_ACCESS_KEY_ID:-}"
			ask_secret secret "Secret access key" no S3_SECRET_ACCESS_KEY
			ask bucket "Bucket name (must already exist)" "${S3_BUCKET:-}"
			ask prefix "Folder inside the bucket" "frappe/$(hostname -s 2>/dev/null || echo server)/$BENCH_NAME"
			rclone_write_remote "$name" <<EOF
type = s3
provider = $provider
access_key_id = $key
secret_access_key = $secret
region = $region
endpoint = $endpoint
no_check_bucket = true
EOF
			remote="$name:$bucket/${prefix#/}"
			;;
		rclone)
			local -a remotes=()
			mapfile -t remotes < <(rclone listremotes 2>/dev/null | sed 's/:$//')
			((${#remotes[@]})) || { warn "No rclone remotes found. Create one with 'rclone config' first."; OFFSITE_REMOTE=''; return 1; }
			choose base "Which rclone remote?" 1 "${remotes[@]}"
			ask prefix "Folder on $base" "frappe/$(hostname -s 2>/dev/null || echo server)/$BENCH_NAME"
			remote="$base:$prefix"
			;;
	esac

	if ask_yes_no "Encrypt backups before they leave this server (rclone crypt)?" y; then
		local pw='' obscured keyfile
		ask_optional pw "Encryption password (leave empty to generate a strong one)" "${OFFSITE_CRYPT_PASSWORD:-}"
		[[ -n "$pw" ]] || pw=$(head -c 32 /dev/urandom | base64 | tr -d '/+=\n' | head -c 32)
		obscured=$(printf '%s' "$pw" | rclone obscure -)
		rclone_write_remote "$name-crypt" <<EOF
type = crypt
remote = $remote
password = $obscured
EOF
		remote="$name-crypt:"
		keyfile="$BACKUP_DIR/OFFSITE-ENCRYPTION-PASSWORD.txt"
		mkdir -p "$BACKUP_DIR"
		( umask 077; printf 'rclone crypt password for %s\n%s\n' "$remote" "$pw" >"$keyfile" )
		warn "Encryption password: ${C_BOLD}$pw${C_RESET}"
		warn "Store it in a password manager NOW. Without it the offsite backups cannot be restored on another server."
		warn "(A copy is in $keyfile, which is lost together with this server.)"
		pause
	fi

	info "Testing write access to $remote"
	if printf 'frappe-ops test %s\n' "$(date)" | rclone rcat "$(offsite_join "$remote" .frappe-ops-test)" && rclone deletefile "$(offsite_join "$remote" .frappe-ops-test)"; then
		success "Offsite storage works."
	else
		warn "Could not write to $remote."
		ask_yes_no "Keep this setting anyway?" n || { OFFSITE_REMOTE=''; return 1; }
	fi
	OFFSITE_REMOTE=$remote
	ask OFFSITE_KEEP_DAYS "Delete offsite backups older than (days, 0 = never)" "$OFFSITE_KEEP_DAYS"
}

# --------------------------------------------------------------------------
# schedule
# --------------------------------------------------------------------------
cron_cmd() {
	local sub=$1 log=$2
	printf 'cd %q && BENCH_PATH=%q ASSUME_DEFAULTS=1 NO_COLOR=1 flock -n %q bash ops.sh %s >>%q 2>&1' \
		"$SCRIPT_DIR" "$BENCH" "$BACKUP_DIR/.lock-${sub%% *}" "$sub" "$log"
}

cmd_schedule() {
	header "Automatic backups and monitoring for $BENCH_NAME"
	local cur when freq hh mm sched
	cur=$(cron_get "backup:$BENCH")
	[[ -n "$cur" ]] && info "Current schedule: ${cur%% cd *}"
	if [[ " $* " == *" --remove "* ]]; then
		cron_remove "backup:$BENCH"; cron_remove "status:$BENCH"
		success "Removed the backup and health check jobs of $BENCH_NAME."
		return 0
	fi
	ask BACKUP_DIR "Local backup folder" "$BACKUP_DIR"
	ask BACKUP_KEEP_DAYS "Keep local backups for (days)" "$BACKUP_KEEP_DAYS"
	ask BACKUP_KEEP_MIN "Always keep at least this many recent backups per site" "$BACKUP_KEEP_MIN"
	if ask_yes_no "Include uploaded files (public + private) in scheduled backups?" "$( ((BACKUP_WITH_FILES)) && echo y || echo n)"; then
		BACKUP_WITH_FILES=1; else BACKUP_WITH_FILES=0
	fi
	choose freq "How often?" 1 "daily|once a day" "12h|every 12 hours" "6h|every 6 hours" "hourly|every hour (database only is recommended)"
	when=02:30
	if [[ "$freq" != hourly ]]; then
		while true; do
			ask when "At what time (HH:MM, server time $(date +%Z))" "$when"
			[[ "$when" =~ ^([01]?[0-9]|2[0-3]):([0-5][0-9])$ ]] && break
			warn "Use 24-hour HH:MM."
		done
	fi
	hh=$((10#${when%%:*})); mm=$((10#${when##*:}))
	case "$freq" in
		daily) sched="$mm $hh * * *" ;;
		12h) sched="$mm $((hh % 12)),$((hh % 12 + 12)) * * *" ;;
		6h) sched="$mm $((hh % 6)),$((hh % 6 + 6)),$((hh % 6 + 12)),$((hh % 6 + 18)) * * *" ;;
		hourly) sched="$mm * * * *" ;;
	esac

	if [[ -n "$OFFSITE_REMOTE" ]]; then
		info "Offsite copies go to $OFFSITE_REMOTE"
		ask_yes_no "Change the offsite storage?" n && { configure_offsite || true; }
	elif ask_yes_no "Also copy every backup offsite (S3, R2, B2, SFTP, ...)? Strongly recommended." y; then
		configure_offsite || true
	fi

	ask_optional NOTIFY_WEBHOOK "Webhook URL for alerts (Slack, Discord, Mattermost; empty = none)" "$NOTIFY_WEBHOOK"
	mkdir -p "$BACKUP_DIR"; chmod 700 "$BACKUP_DIR"
	ops_save_conf "$BENCH"

	ensure_cron
	cron_set "backup:$BENCH" "$sched" "$(cron_cmd backup "$BACKUP_DIR/backup.log")"
	success "Backups scheduled: $sched (log: $BACKUP_DIR/backup.log)"
	if [[ -n "$NOTIFY_WEBHOOK" ]] && ask_yes_no "Run a health check every 10 minutes and alert the webhook when something breaks or recovers?" y; then
		cron_set "status:$BENCH" "*/10 * * * *" "$(cron_cmd 'status --quiet --notify' "$BACKUP_DIR/health.log")"
		success "Health checks scheduled every 10 minutes."
		ops_notify ok "Alerts for bench $BENCH_NAME are set up."
	fi
	if ask_yes_no "Run a backup now to test the setup?" y; then cmd_backup; fi
}

# --------------------------------------------------------------------------
# restore
# --------------------------------------------------------------------------
cmd_restore() {
	local preset='' yes=0
	while (($#)); do
		case "$1" in
			--site) preset=$2; shift ;;
			--yes) yes=1 ;;
			*) die "Unknown option for restore: $1" ;;
		esac
		shift
	done
	header "Restore a site"
	local site src from dir set db pub priv f
	pick_site site "Restore into which site? (create it first with manage-sites.sh if needed)" "$preset" || return 0
	local -a srcs=("local|a backup in $BACKUP_DIR")
	[[ -n "$OFFSITE_REMOTE" ]] && srcs+=("offsite|a backup in $OFFSITE_REMOTE")
	srcs+=("bench|a backup made by bench (sites/<site>/private/backups)" "path|a backup file somewhere else")
	choose src "Restore from" 1 "${srcs[@]}"

	case "$src" in
		local|offsite|bench)
			local -a from_opts=()
			if [[ "$src" == offsite ]]; then
				from_opts=("$site")
				while read -r f; do [[ -n "$f" && "$f" != "$site" ]] && from_opts+=("$f"); done \
					< <(rclone lsf --dirs-only "${OFFSITE_REMOTE%/}" 2>/dev/null | sed 's#/$##')
			else
				from_opts=("$site")
				for f in "$BACKUP_DIR"/*/ "$BENCH"/sites/*/private/backups/; do
					[[ -d "$f" ]] || continue
					if [[ "$src" == bench ]]; then f=${f%/private/backups/}; else f=${f%/}; fi
					f=$(basename "$f")
					[[ "$f" == "$site" || "$f" == restore-points ]] || from_opts+=("$f")
				done
			fi
			[[ "${#from_opts[@]}" -gt 1 ]] && choose from "Backups of which site? (another site = copy it into $site)" 1 "${from_opts[@]}"
			from=${from:-$site}
			local -a sets=() opts=()
			case "$src" in
				local) dir="$BACKUP_DIR/$from"; mapfile -t sets < <(backup_sets "$dir") ;;
				bench) dir="$BENCH/sites/$from/private/backups"; mapfile -t sets < <(backup_sets "$dir") ;;
				offsite) dir="$BACKUP_DIR/$from"; mapfile -t sets < <(offsite_sets "$from") ;;
			esac
			((${#sets[@]})) || die "No backups found for $from."
			for set in "${sets[@]:0:15}"; do
				if [[ "$src" == offsite ]]; then opts+=("$set|${set:0:4}-${set:4:2}-${set:6:2} ${set:9:2}:${set:11:2}")
				else opts+=("$set|$(set_label "$dir" "$set")")
				fi
			done
			choose set "Which backup?" 1 "${opts[@]}"
			if [[ "$src" == offsite ]]; then
				info "Downloading $set from $OFFSITE_REMOTE"
				offsite_fetch "$from" "$set" "$dir"
			fi
			;;
		path)
			ask db "Path to the database backup (.sql or .sql.gz)"
			[[ -f "$db" ]] || die "File not found: $db"
			dir=$(cd "$(dirname "$db")" && pwd)
			set=$(basename "$db"); set=${set%-database.sql.gz}; set=${set%-database.sql}
			;;
	esac
	db=$(backup_set_part "$dir" "$set" database) || die "No database file in $set."
	pub=$(backup_set_part "$dir" "$set" files || true)
	priv=$(backup_set_part "$dir" "$set" private-files || true)

	local -a args=(--site "$site" restore "$db")
	[[ -n "$pub" ]] && ask_yes_no "Restore public files ($(basename "$pub"))?" y && args+=(--with-public-files "$pub")
	[[ -n "$priv" ]] && ask_yes_no "Restore private files ($(basename "$priv"))?" y && args+=(--with-private-files "$priv")

	warn "This replaces ALL data of $site with the backup $set."
	local def=n; ((yes)) && def=y
	ask_yes_no "Restore now?" "$def" || return 0
	if ask_yes_no "Back up the current state of $site first?" y; then
		ops_backup_site "$BENCH" "$site" "$BACKUP_DIR/$site" 1
	fi
	get_db_root_pw
	args+=(--db-root-password "$DB_ROOT_PW" --force)
	ensure_bench_redis "$BENCH"
	b "${args[@]}"

	# A backup from another server or site needs its encryption key, or saved passwords stay unreadable.
	local cfg old_key cur_key
	cfg=$(backup_set_part "$dir" "$set" site_config_backup || true)
	if [[ -n "$cfg" ]]; then
		old_key=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("encryption_key",""))' "$cfg" 2>/dev/null || true)
		cur_key=$(python3 -c 'import json,sys;print(json.load(open(sys.argv[1])).get("encryption_key",""))' "$BENCH/sites/$site/site_config.json" 2>/dev/null || true)
		if [[ -n "$old_key" && "$old_key" != "$cur_key" ]]; then
			warn "The backup was encrypted with a different encryption_key (another server or site)."
			if ask_yes_no "Use the backup's encryption_key for $site so saved passwords and API keys keep working?" y; then
				b --site "$site" set-config encryption_key "$old_key"
			fi
		fi
	fi
	b --site "$site" migrate
	b --site "$site" clear-cache
	((PROD)) && { b restart || true; }
	success "$site restored from $set."
}

# --------------------------------------------------------------------------
# rollback
# --------------------------------------------------------------------------
cmd_rollback() {
	local yes=0
	[[ " $* " == *" --yes "* ]] && yes=1
	header "Roll back to a restore point"
	local -a points=() opts=()
	mapfile -t points < <(list_restore_points)
	((${#points[@]})) || die "No restore points in $(restore_points_dir). update-bench.sh creates one before each update."
	local p rp app branch commit cur
	for p in "${points[@]}"; do opts+=("$p|$(human_size "$(restore_points_dir)/$p")"); done
	choose p "Which restore point?" 1 "${opts[@]}"
	rp="$(restore_points_dir)/$p"
	printf '\n   %-22s %-26s %s\n' APP "RESTORE POINT" NOW >&2
	while read -r app branch commit; do
		cur="$(app_branch "$BENCH" "$app") @ $(git -C "$BENCH/apps/$app" rev-parse --short=10 HEAD 2>/dev/null || echo '?')"
		printf '   %-22s %-26s %s\n' "$app" "$branch @ ${commit:0:10}" "$cur" >&2
	done <"$rp/apps.lock"
	echo >&2
	warn "Every site's database goes back to ${p%%-*}; data entered since then is lost."
	local def=n; ((yes)) && def=y
	ask_yes_no "Roll back now?" "$def" || return 0
	if ask_yes_no "Back up the current databases first (in case you need today's data)?" y; then
		local s
		for s in $(bench_sites "$BENCH"); do ops_backup_site "$BENCH" "$s" "$BACKUP_DIR/$s" 0; done
	fi
	ensure_bench_redis "$BENCH"
	restore_point_rollback "$BENCH" "$rp" || die "Rollback finished with errors."
}

# --------------------------------------------------------------------------
# status
# --------------------------------------------------------------------------
ST_LEVEL=0 ST_PROBLEMS=()
st() { # st <ok|warn|fail|info> <check> <detail>
	local lvl=$1 name=$2 detail=$3 mark color
	case "$lvl" in
		ok) mark='ok'; color=$C_GREEN ;;
		info) mark='--'; color=$C_DIM ;;
		warn) mark='WARN'; color=$C_YELLOW; ((ST_LEVEL < 1)) && ST_LEVEL=1; ST_PROBLEMS+=("$name: $detail") ;;
		fail) mark='FAIL'; color=$C_RED; ST_LEVEL=2; ST_PROBLEMS+=("$name: $detail") ;;
	esac
	if ((QUIET)) && [[ "$lvl" == ok || "$lvl" == info ]]; then return 0; fi
	printf '   %s%-5s%s %-28s %s\n' "$color$C_BOLD" "$mark" "$C_RESET" "$name" "$detail" >&2
}

cmd_status() {
	local notify=0 a
	for a in "$@"; do case "$a" in --notify) notify=1 ;; --quiet) ;; *) die "Unknown option for status: $a" ;; esac; done
	((QUIET)) || header "Health of $BENCH ($( ((PROD)) && echo production || echo development))"
	local -a sites=()
	mapfile -t sites < <(bench_sites "$BENCH")

	# Database
	if ((${#sites[@]})) && site_db_reachable "$BENCH" "${sites[0]}"; then st ok MariaDB "reachable"
	elif (exec 3<>/dev/tcp/127.0.0.1/3306) 2>/dev/null; then st ok MariaDB "port 3306 open"
	else st fail MariaDB "not reachable on 127.0.0.1:3306"
	fi
	# Redis
	local conf port
	for conf in "$BENCH"/config/redis_*.conf; do
		[[ -f "$conf" ]] || continue
		port=$(awk '$1 == "port" { print $2; exit }' "$conf")
		[[ -n "$port" ]] || continue
		if redis_port_up "$port"; then st ok "$(basename "$conf" .conf)" "port $port"
		elif ((PROD)); then st fail "$(basename "$conf" .conf)" "not answering on port $port"
		else st info "$(basename "$conf" .conf)" "not running (starts with bench start)"
		fi
	done
	# Web server and workers
	if ((PROD)); then
		if pgrep -x nginx >/dev/null 2>&1; then st ok nginx running; else st fail nginx "not running"; fi
		local sv
		if sv=$(sudo -n supervisorctl status 2>/dev/null) || sv=$(supervisorctl status 2>/dev/null); then
			local total down
			total=$(grep -c "^$BENCH_NAME-" <<<"$sv" || true)
			down=$(grep "^$BENCH_NAME-" <<<"$sv" | grep -v RUNNING | awk '{print $1 " " $2}' | paste -sd, - || true)
			if [[ -z "$down" && "$total" -gt 0 ]]; then st ok "bench processes" "$total running"
			elif [[ "$total" -eq 0 ]]; then st fail "bench processes" "none found in supervisor"
			else st fail "bench processes" "not running: $down"
			fi
		elif pgrep -f supervisord >/dev/null 2>&1; then st info supervisor "running (no permission to list processes)"
		else st fail supervisor "not running"
		fi
	fi
	# Sites
	local s web_up=1 sched maint
	if ((!PROD)); then
		port=$(grep -oE '"webserver_port"\s*:\s*[0-9]+' "$BENCH/sites/common_site_config.json" 2>/dev/null | grep -oE '[0-9]+$' || echo 8000)
		(exec 3<>"/dev/tcp/127.0.0.1/${port:-8000}") 2>/dev/null || { web_up=0; st info "web server" "bench start is not running"; }
	fi
	for s in "${sites[@]}"; do
		if ((web_up)); then
			if site_responds "$BENCH" "$s"; then st ok "$s" "answers /api/method/ping"
			else st fail "$s" "does not answer /api/method/ping"
			fi
		fi
		maint=$(grep -oE '"maintenance_mode"\s*:\s*1' "$BENCH/sites/$s/site_config.json" "$BENCH/sites/common_site_config.json" 2>/dev/null || true)
		[[ -n "$maint" ]] && st warn "$s" "maintenance mode is on"
		if ((PROD)) && site_db_info "$BENCH" "$s" && [[ "$SDB_TYPE" == mariadb ]]; then
			sched=$(_site_sql -N -B "$SDB_NAME" -e "SELECT value FROM tabSingles WHERE doctype='System Settings' AND field='enable_scheduler'" 2>/dev/null || true)
			if [[ "$sched" == 1 ]]; then st ok "$s scheduler" enabled
			else st warn "$s scheduler" "disabled (bench --site $s enable-scheduler)"
			fi
		fi
		if ((PROD)) && grep -qE '"(ssl_certificate|domains)"' "$BENCH/sites/$s/site_config.json" 2>/dev/null; then
			local days
			if days=$(cert_days_left "$s"); then
				if ((days < 7)); then st fail "$s certificate" "expires in $days days"
				elif ((days < 21)); then st warn "$s certificate" "expires in $days days"
				else st ok "$s certificate" "valid for $days days"
				fi
			fi
		fi
	done
	# Disk and memory
	local use mount avail
	while read -r use mount; do
		use=${use%\%}
		if ((use >= 90)); then st fail "disk $mount" "$use% used"
		elif ((use >= 80)); then st warn "disk $mount" "$use% used"
		else st ok "disk $mount" "$use% used"
		fi
	done < <(df -P "$BENCH" "$( [[ -d "$BACKUP_DIR" ]] && echo "$BACKUP_DIR" || echo "$BENCH")" 2>/dev/null | awk 'NR > 1 && !seen[$6]++ { print $5, $6 }')
	avail=$(awk '/^MemAvailable:/ { print int($2 / 1024) }' /proc/meminfo)
	if ((avail < 150)); then st fail memory "${avail} MB available"
	elif ((avail < 400)); then st warn memory "${avail} MB available"
	else st ok memory "${avail} MB available"
	fi
	# Backups
	local age
	age=$(newest_backup_age_hours "$BACKUP_DIR")
	if [[ -z "$age" ]]; then
		if ((PROD)); then st warn backups "none in $BACKUP_DIR (./ops.sh schedule)"; else st info backups "none in $BACKUP_DIR"; fi
	elif ((age > 26)); then st warn backups "newest is $age hours old"
	else st ok backups "newest is $age hour(s) old"
	fi
	if ((PROD)); then
		if [[ -n "$(cron_get "backup:$BENCH")" ]]; then st ok "backup schedule" "$(cron_get "backup:$BENCH" | awk '{print $1, $2, $3, $4, $5}')"
		else st warn "backup schedule" "not set up (./ops.sh schedule)"
		fi
		if [[ -n "$OFFSITE_REMOTE" ]]; then st ok "offsite copy" "$OFFSITE_REMOTE"; else st warn "offsite copy" "not set up"; fi
	fi

	local label
	case "$ST_LEVEL" in 0) label=ok ;; 1) label=warn ;; *) label=fail ;; esac
	if ((!QUIET)); then
		echo >&2
		case "$ST_LEVEL" in
			0) success "Everything looks healthy." ;;
			1) warn "${#ST_PROBLEMS[@]} warning(s)." ;;
			*) error "Problems found: ${#ST_PROBLEMS[@]}." ;;
		esac
	elif ((ST_LEVEL)); then
		printf '%s %s: %s\n' "$(date '+%F %T')" "$label" "$(IFS=';'; echo "${ST_PROBLEMS[*]}")"
	fi
	((notify)) && status_notify "$label"
	exit "$ST_LEVEL"
}

# status_notify <ok|warn|fail>: alert on a change of state, and every 6 hours while failing.
status_notify() {
	local now=$1 state="$BACKUP_DIR/.health-state" prev='ok' since=0 t
	t=$(date +%s)
	mkdir -p "$BACKUP_DIR"
	[[ -f "$state" ]] && read -r prev since <"$state"
	if [[ "$now" != "$prev" ]] || { [[ "$now" == fail ]] && ((t - since > 21600)); }; then
		if [[ "$now" == ok ]]; then ops_notify ok "Bench $BENCH_NAME is healthy again."
		else ops_notify "$now" "Bench $BENCH_NAME: $(IFS=';'; echo "${ST_PROBLEMS[*]}")"
		fi
		printf '%s %s\n' "$now" "$t" >"$state"
	fi
}

# --------------------------------------------------------------------------
# secure
# --------------------------------------------------------------------------
ssh_ports() {
	local p
	{
		[[ -n "${SSH_CONNECTION:-}" ]] && awk '{print $4}' <<<"$SSH_CONNECTION"
		as_root sshd -T 2>/dev/null | awk '$1 == "port" { print $2 }'
		grep -hE '^\s*Port\s+[0-9]+' /etc/ssh/sshd_config /etc/ssh/sshd_config.d/*.conf 2>/dev/null | awk '{print $2}'
	} | sort -un | grep -E '^[0-9]+$' >/tmp/.fss-ssh-ports.$$ || true
	p=$(paste -sd' ' /tmp/.fss-ssh-ports.$$); rm -f /tmp/.fss-ssh-ports.$$
	printf '%s\n' "${p:-22}"
}

secure_firewall() {
	if ((IS_WSL)); then info "WSL: skipping the firewall (Windows handles it)."; return 0; fi
	local ports p
	ports=$(ssh_ports)
	ask_yes_no "Turn on the firewall (ufw): allow SSH (port ${ports// /, }), HTTP and HTTPS, block everything else?" y || return 0
	command -v ufw >/dev/null 2>&1 || pkg_install ufw
	for p in $ports; do run as_root ufw allow "$p/tcp" comment 'SSH'; done
	run as_root ufw allow 80/tcp comment 'HTTP'
	run as_root ufw allow 443/tcp comment 'HTTPS'
	run as_root ufw default deny incoming
	run as_root ufw default allow outgoing
	run as_root ufw --force enable
	[[ "$OS_FAMILY" == arch ]] && { service_enable_start ufw || true; }
	as_root ufw status verbose >&2 || true
	success "Firewall on."
}

secure_fail2ban() {
	ask_yes_no "Install fail2ban (ban IPs after repeated failed SSH logins)?" y || return 0
	if [[ "$OS_FAMILY" == arch ]]; then pkg_install fail2ban python-systemd; else pkg_install fail2ban; fi
	local backend=auto ports
	if has_systemd && [[ ! -s /var/log/auth.log && ! -s /var/log/secure ]]; then backend=systemd; fi
	ports=$(ssh_ports)
	as_root tee /etc/fail2ban/jail.d/frappe-setup-scripts.local >/dev/null <<EOF
# Added by Frappe-Setup-Scripts (ops.sh secure)
[DEFAULT]
bantime = 1h
findtime = 10m
maxretry = 5
bantime.increment = true

[sshd]
enabled = true
port = ${ports// /,}
backend = $backend
EOF
	if has_systemd; then run as_root systemctl enable fail2ban >/dev/null 2>&1 || true; run as_root systemctl restart fail2ban
	else service_enable_start fail2ban || true
	fi
	success "fail2ban is protecting SSH."
}

secure_auto_updates() {
	[[ "$OS_FAMILY" == debian ]] || { info "Automatic updates are not recommended on Arch; skipping."; return 0; }
	ask_yes_no "Install security updates automatically (unattended-upgrades)?" y || return 0
	apt_install unattended-upgrades
	as_root tee /etc/apt/apt.conf.d/20auto-upgrades >/dev/null <<'EOF'
APT::Periodic::Update-Package-Lists "1";
APT::Periodic::Unattended-Upgrade "1";
APT::Periodic::AutocleanInterval "7";
EOF
	success "Security updates will install automatically."
}

secure_swap_sysctl() {
	local ram_mb size
	ram_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
	if ((IS_WSL)); then info "WSL: swap is managed by Windows; skipping."
	elif [[ -n "$(swapon --show --noheadings 2>/dev/null)" ]]; then info "Swap already enabled: $(swapon --show --noheadings | awk '{print $1 " " $3}' | paste -sd, -)"
	elif ((ram_mb < 8192)); then
		size=$(( ram_mb < 4096 ? 2 : 4 ))
		if ask_yes_no "No swap and ${ram_mb} MB RAM. Create a ${size} GB swap file (avoids crashes during asset builds)?" y; then
			if run as_root fallocate -l "${size}G" /swapfile && run as_root chmod 600 /swapfile && run as_root mkswap /swapfile >/dev/null && run as_root swapon /swapfile; then
				grep -q '^/swapfile ' /etc/fstab || echo '/swapfile none swap sw 0 0' | as_root tee -a /etc/fstab >/dev/null
				success "Swap enabled."
			else
				as_root rm -f /swapfile; warn "Could not enable swap here (containers often do not allow it)."
			fi
		fi
	fi
	if ask_yes_no "Apply kernel settings recommended for Redis and MariaDB (vm.overcommit_memory=1, low swappiness)?" y; then
		printf '# Added by Frappe-Setup-Scripts\nvm.overcommit_memory = 1\nvm.swappiness = 10\n' | as_root tee /etc/sysctl.d/90-frappe.conf >/dev/null
		as_root sysctl -q -p /etc/sysctl.d/90-frappe.conf 2>/dev/null || warn "Could not apply sysctl settings now; they apply after a reboot."
	fi
}

# mariadb_tuning_values: prints "<buffer-pool-MB> <log-file-MB>" for this machine's RAM.
mariadb_tuning_values() {
	local ram_mb pool log
	ram_mb=$(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo)
	# The app (gunicorn, workers, Redis) shares the machine: 25% of RAM on small hosts, 40% on large ones.
	if ((ram_mb <= 4096)); then pool=$((ram_mb * 25 / 100)); else pool=$((ram_mb * 40 / 100)); fi
	((pool < 256)) && pool=256
	pool=$(( pool / 128 * 128 ))
	((pool < 256)) && pool=256
	log=$((pool / 4)); ((log < 64)) && log=64; ((log > 2048)) && log=2048
	printf '%s %s\n' "$pool" "$log"
}

secure_mariadb() {
	local pool log conf
	read -r pool log < <(mariadb_tuning_values)
	ask_yes_no "Tune MariaDB for this machine (buffer pool ${pool} MB, slow query log)? MariaDB restarts for a few seconds." y || return 0
	conf="$(dirname "$(mariadb_conf_path)")/zz-frappe-tuning.cnf"
	as_root tee "$conf" >/dev/null <<EOF
# Added by Frappe-Setup-Scripts (ops.sh secure); sized for $(awk '/^MemTotal:/ { print int($2 / 1024) }' /proc/meminfo) MB RAM.
[mysqld]
innodb_buffer_pool_size = ${pool}M
innodb_log_file_size = ${log}M
innodb_flush_method = O_DIRECT
tmp_table_size = 64M
max_heap_table_size = 64M
max_connections = 300
slow_query_log = 1
long_query_time = 2
EOF
	info "Wrote $conf"
	start_mariadb
	success "MariaDB tuned."
}

cmd_secure() {
	header "Secure and tune this server"
	ensure_sudo
	((PROD)) || warn "$BENCH is a development bench; these settings are meant for servers."
	secure_firewall
	secure_fail2ban
	secure_auto_updates
	secure_swap_sysctl
	secure_mariadb
	success "Done. Check the result with ./ops.sh status"
}

# --------------------------------------------------------------------------
# domains and certificates
# --------------------------------------------------------------------------
ensure_certbot() {
	command -v certbot >/dev/null 2>&1 && return 0
	pkg_install certbot
}

site_domains() {
	python3 -c '
import json, sys
c = json.load(open(sys.argv[1]))
for d in c.get("domains", []):
    print(d["domain"] if isinstance(d, dict) else d)
' "$BENCH/sites/$1/site_config.json" 2>/dev/null || true
}

cmd_domain() {
	((PROD)) || die "Custom domains need a production bench (nginx)."
	header "Custom domains"
	local site act domain
	pick_site site "Which site?" || return 0
	local -a doms=()
	mapfile -t doms < <(site_domains "$site")
	info "Domains of $site: ${doms[*]:-(none besides $site)}"
	choose act "What do you want to do?" 1 "add|Add a domain" "remove|Remove a domain" "quit|Nothing"
	case "$act" in
		add)
			ask domain "Domain (DNS must point to this server, e.g. erp.example.com)"
			[[ "$domain" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]*[A-Za-z0-9])?\.[A-Za-z]{2,}$ ]] || die "Not a valid domain: $domain"
			grep -q '"dns_multitenant"\s*:\s*true' "$BENCH/sites/common_site_config.json" 2>/dev/null || b config dns_multitenant on
			b setup add-domain --site "$site" "$domain"
			reload_production "$BENCH"
			if ask_yes_no "Get a free Let's Encrypt certificate for $domain now?" y; then
				ensure_sudo; ensure_certbot
				( cd "$BENCH" && run as_root env "PATH=$PATH" "$(command -v bench)" setup lets-encrypt "$site" --custom-domain "$domain" )
			fi
			success "$domain now serves $site."
			;;
		remove)
			((${#doms[@]})) || { warn "No custom domains."; return 0; }
			choose domain "Remove which domain?" 1 "${doms[@]}"
			b setup remove-domain --site "$site" "$domain"
			reload_production "$BENCH"
			success "$domain removed from $site."
			;;
	esac
}

cmd_ssl() {
	((PROD)) || die "Certificates are only used on production benches."
	header "Certificates"
	local s d days
	for s in $(bench_sites "$BENCH"); do
		for d in "$s" $(site_domains "$s"); do
			if days=$(cert_days_left "$d"); then printf '   %-40s valid for %s days\n' "$d" "$days" >&2
			else printf '   %-40s no certificate\n' "$d" >&2
			fi
		done
	done
	echo >&2
	local renew=''
	if has_systemd && systemctl list-timers --all 2>/dev/null | grep -q certbot; then renew='systemd timer certbot.timer'
	elif as_root crontab -l 2>/dev/null | grep -qE 'certbot|renew-lets-encrypt'; then renew="root's crontab"
	elif grep -rqsE 'certbot' /etc/cron.d/; then renew='/etc/cron.d'
	fi
	ensure_sudo
	if [[ -n "$renew" ]]; then
		success "Automatic renewal is scheduled ($renew)."
	elif ask_yes_no "No automatic renewal found. Add a daily renewal job (/etc/cron.d/frappe-certbot)?" y; then
		ensure_certbot
		printf '# Added by Frappe-Setup-Scripts\n17 3 * * * root certbot renew --quiet --deploy-hook "nginx -s reload"\n' \
			| as_root tee /etc/cron.d/frappe-certbot >/dev/null
		success "Certificates renew automatically."
	fi
	if command -v certbot >/dev/null 2>&1 && ask_yes_no "Test the renewal now (certbot renew --dry-run)?" n; then
		run as_root certbot renew --dry-run
	fi
}

# --------------------------------------------------------------------------
# Main
# --------------------------------------------------------------------------
run_cmd() {
	local c=$1; shift
	case "$c" in
		backup) cmd_backup "$@" ;;
		schedule) cmd_schedule "$@" ;;
		restore) cmd_restore "$@" ;;
		rollback) cmd_rollback "$@" ;;
		status) cmd_status "$@" ;;
		secure) cmd_secure "$@" ;;
		domain) cmd_domain "$@" ;;
		ssl) cmd_ssl "$@" ;;
	esac
}

if [[ -n "$CMD" ]]; then
	run_cmd "$CMD" "$@"
	exit 0
fi

menu=(
	"status|Health check of services, sites, disk, backups"
	"backup|Back up all sites now"
	"schedule|Automatic backups, offsite copies and alerts"
	"restore|Restore a site from a backup"
	"rollback|Undo an update (restore point)"
)
((PROD)) && menu+=("secure|Firewall, fail2ban, swap, security updates, MariaDB tuning" "domain|Add or remove a custom domain" "ssl|Certificates and renewal")
menu+=("quit|Exit")
while true; do
	echo >&2
	choose ACTION "What do you want to do? (bench: $BENCH)" 1 "${menu[@]}"
	[[ "$ACTION" == quit ]] && break
	# A separate process, so a failing step stops that action (set -e) and returns to the menu.
	BENCH_PATH=$BENCH bash "$0" "$ACTION" || warn "$ACTION finished with problems."
	[[ "${ASSUME_DEFAULTS:-0}" == 1 ]] && break
done
