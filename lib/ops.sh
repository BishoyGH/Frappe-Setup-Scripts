#!/usr/bin/env bash
# shellcheck shell=bash
# Production operations: backup sets with retention, offsite copies (rclone), restore points
# with rollback, health checks, notifications and cron jobs.
# Requires lib/common.sh (and lib/prereqs.sh for package installs) to be sourced first.

[[ -n "${_FSS_OPS_LOADED:-}" ]] && return 0
_FSS_OPS_LOADED=1

# --------------------------------------------------------------------------
# Per-bench settings, stored in <bench>/.frappe-ops.conf
# Values already in the environment win over the file (useful for cron and CI).
# --------------------------------------------------------------------------
OPS_KEYS=(BACKUP_DIR BACKUP_KEEP_DAYS BACKUP_KEEP_MIN BACKUP_WITH_FILES
	OFFSITE_REMOTE OFFSITE_KEEP_DAYS RESTORE_POINTS_KEEP NOTIFY_WEBHOOK)

ops_conf_path() { printf '%s/.frappe-ops.conf\n' "$1"; }

# ops_load_conf <bench>
# shellcheck disable=SC2034  # the settings are used by ops.sh
ops_load_conf() {
	local bench=$1 k conf
	local -A from_env=()
	for k in "${OPS_KEYS[@]}"; do
		[[ -n "${!k+x}" ]] && from_env[$k]=${!k}
	done
	BACKUP_DIR="$HOME/frappe-backups/$(basename "$bench")"
	BACKUP_KEEP_DAYS=14
	BACKUP_KEEP_MIN=7
	BACKUP_WITH_FILES=1
	OFFSITE_REMOTE=''
	OFFSITE_KEEP_DAYS=30
	RESTORE_POINTS_KEEP=3
	NOTIFY_WEBHOOK=''
	conf=$(ops_conf_path "$bench")
	# shellcheck disable=SC1090
	[[ -f "$conf" ]] && . "$conf"
	for k in "${!from_env[@]}"; do printf -v "$k" '%s' "${from_env[$k]}"; done
	return 0
}

# ops_save_conf <bench>
ops_save_conf() {
	local bench=$1 conf k
	conf=$(ops_conf_path "$bench")
	{
		echo "# Written by Frappe-Setup-Scripts (ops.sh). Safe to edit."
		for k in "${OPS_KEYS[@]}"; do printf '%s=%q\n' "$k" "${!k}"; done
	} >"$conf"
	chmod 600 "$conf"
	info "Saved settings to $conf"
}

# --------------------------------------------------------------------------
# Notifications (Slack, Discord, Mattermost, ntfy-style JSON webhooks)
# --------------------------------------------------------------------------
# ops_notify <level: ok|warn|fail> <message>
ops_notify() {
	local level=$1 msg=$2 payload
	[[ -n "${NOTIFY_WEBHOOK:-}" ]] || return 0
	msg="[$(hostname -s 2>/dev/null || echo frappe)] ${level^^}: $msg"
	payload=$(python3 -c 'import json,sys; m=sys.argv[1]; print(json.dumps({"text": m, "content": m}))' "$msg" 2>/dev/null) \
		|| payload="{\"text\": \"${msg//\"/\'}\"}"
	curl -fsS -m 20 -o /dev/null -H 'Content-Type: application/json' -d "$payload" "$NOTIFY_WEBHOOK" \
		|| warn "Could not send the notification to the webhook."
}

# --------------------------------------------------------------------------
# Site database access with the site's own credentials (no MariaDB root password needed)
# --------------------------------------------------------------------------
# site_db_info <bench> <site>: sets SDB_NAME SDB_USER SDB_PASS SDB_HOST SDB_PORT SDB_TYPE
site_db_info() {
	local bench=$1 site=$2 py out
	py="$bench/env/bin/python"
	[[ -x "$py" ]] || py=python3
	out=$("$py" - "$bench" "$site" <<'PY'
import json, os, shlex, sys
bench, site = sys.argv[1], sys.argv[2]
conf = {}
for p in (os.path.join(bench, "sites", "common_site_config.json"), os.path.join(bench, "sites", site, "site_config.json")):
    try:
        with open(p) as f:
            conf.update(json.load(f))
    except (OSError, ValueError):
        pass
vals = {
    "SDB_NAME": conf.get("db_name", ""),
    "SDB_USER": conf.get("db_user") or conf.get("db_name", ""),
    "SDB_PASS": conf.get("db_password", ""),
    "SDB_HOST": conf.get("db_host") or "127.0.0.1",
    "SDB_PORT": str(conf.get("db_port") or 3306),
    "SDB_TYPE": conf.get("db_type") or "mariadb",
}
print("\n".join(f"{k}={shlex.quote(str(v))}" for k, v in vals.items()))
PY
	) || return 1
	eval "$out"
	[[ -n "$SDB_NAME" ]]
}

# _site_sql <args...>: run the MariaDB client as the site user (after site_db_info).
_site_sql() {
	local cli=mysql
	command -v mariadb >/dev/null 2>&1 && cli=mariadb
	MYSQL_PWD="$SDB_PASS" "$cli" -u"$SDB_USER" -h"$SDB_HOST" -P"$SDB_PORT" "$@"
}

# site_db_reachable <bench> <site>
site_db_reachable() {
	site_db_info "$1" "$2" || return 1
	[[ "$SDB_TYPE" == mariadb ]] || return 1
	_site_sql -N -B -e 'SELECT 1' "$SDB_NAME" >/dev/null 2>&1
}

# site_db_load <bench> <site> <dump.sql[.gz]>: replace the site's database with a dump.
# Every table is dropped first so tables created by a newer version do not linger.
site_db_load() {
	local bench=$1 site=$2 dump=$3 sql='' name type
	site_db_info "$bench" "$site" || { error "Cannot read the database settings of $site."; return 1; }
	[[ "$SDB_TYPE" == mariadb ]] || { error "$site uses $SDB_TYPE; only MariaDB is supported here."; return 1; }
	[[ -f "$dump" ]] || { error "Dump not found: $dump"; return 1; }
	while IFS=$'\t' read -r name type; do
		[[ -n "$name" ]] || continue
		name=${name//\`/\`\`}
		if [[ "$type" == VIEW ]]; then sql+="DROP VIEW IF EXISTS \`$name\`;"
		else sql+="DROP TABLE IF EXISTS \`$name\`;"
		fi
	done < <(_site_sql -N -B -e 'SHOW FULL TABLES' "$SDB_NAME")
	if [[ -n "$sql" ]]; then
		_site_sql "$SDB_NAME" -e "SET FOREIGN_KEY_CHECKS=0; $sql SET FOREIGN_KEY_CHECKS=1;" || return 1
	fi
	info "Loading $(basename "$dump") into $site"
	if [[ "$dump" == *.gz ]]; then
		gzip -dc "$dump" | _site_sql "$SDB_NAME"
	else
		_site_sql "$SDB_NAME" <"$dump"
	fi
}

# --------------------------------------------------------------------------
# Backup sets
# A set is every file in a directory that shares a "YYYYMMDD_HHMMSS-<site>" prefix, as
# written by `bench backup --backup-path <dir>`.
# --------------------------------------------------------------------------
# ops_backup_site <bench> <site> <dest-dir> <with-files 0|1>
ops_backup_site() {
	local bench=$1 site=$2 dest=$3 files=$4
	local -a args=(--site "$site" backup --backup-path "$dest")
	((files)) && args+=(--with-files --compress)
	mkdir -p "$dest"
	chmod 700 "$dest"
	( cd "$bench" && run bench "${args[@]}" )
}

# backup_sets <dir>: list set prefixes (timestamp-site), newest first.
backup_sets() {
	local dir=$1
	[[ -d "$dir" ]] || return 0
	find "$dir" -maxdepth 1 -type f -name '*-database.sql*' -printf '%f\n' 2>/dev/null \
		| sed -E 's/-database\.sql(\.gz)?$//' | sort -ru
}

# backup_set_files <dir> <set>: every file of a set
backup_set_files() {
	local dir=$1 set=$2
	find "$dir" -maxdepth 1 -type f -name "$set-*" | sort
}

# backup_set_part <dir> <set> <database|files|private-files|site_config_backup>
backup_set_part() {
	local dir=$1 set=$2 part=$3 f
	for f in "$dir/$set-$part".*; do
		[[ -f "$f" ]] && { printf '%s\n' "$f"; return 0; }
	done
	return 1
}

# prune_backup_sets <dir> <keep-days> <keep-min>
# Removes sets older than <keep-days>, but always keeps the <keep-min> newest ones.
prune_backup_sets() {
	local dir=$1 days=$2 min=$3 cutoff set n=0 removed=0
	cutoff=$(date -d "-$days days" +%Y%m%d_%H%M%S)
	while read -r set; do
		[[ -n "$set" ]] || continue
		n=$((n + 1))
		((n <= min)) && continue
		[[ "${set%%-*}" < "$cutoff" ]] || continue
		backup_set_files "$dir" "$set" | xargs -r rm -f --
		removed=$((removed + 1))
	done < <(backup_sets "$dir")
	((removed)) && info "Removed $removed old backup set(s) from $dir (older than $days days, kept the newest $min)."
	return 0
}

# human_size <path...>
human_size() { du -shc "$@" 2>/dev/null | tail -1 | cut -f1; }

# newest_backup_age_hours <dir>: hours since the newest set in <dir>, or empty
newest_backup_age_hours() {
	local dir=$1 newest
	[[ -d "$dir" ]] || return 0
	newest=$(find "$dir" -maxdepth 2 -type f -name '*-database.sql*' -printf '%T@\n' 2>/dev/null | sort -rn | head -1)
	[[ -n "$newest" ]] || return 0
	echo $(( ($(date +%s) - ${newest%.*}) / 3600 ))
}

# --------------------------------------------------------------------------
# Offsite copies with rclone (S3-compatible storage, Backblaze, SFTP, Google Drive, ...)
# --------------------------------------------------------------------------
ensure_rclone() {
	command -v rclone >/dev/null 2>&1 && return 0
	header "Installing rclone"
	pkg_install rclone
	command -v rclone >/dev/null 2>&1 || die "rclone was not installed."
}

rclone_conf_file() {
	local f
	f=$(rclone config file 2>/dev/null | tail -1)
	[[ "$f" == /* ]] || f="$HOME/.config/rclone/rclone.conf"
	printf '%s\n' "$f"
}

# rclone_write_remote <name> <<'EOF' key = value lines EOF
# Replaces the [name] section of the rclone config (keys never show up in `ps`).
rclone_write_remote() {
	local name=$1 file body tmp
	body=$(cat)
	file=$(rclone_conf_file)
	mkdir -p "$(dirname "$file")"
	touch "$file"
	chmod 600 "$file"
	tmp=$(mktemp)
	awk -v s="[$name]" '
		/^\[.*\]$/ { skip = ($0 == s) }
		!skip { print }
	' "$file" >"$tmp"
	printf '\n[%s]\n%s\n' "$name" "$body" >>"$tmp"
	cat "$tmp" >"$file"
	rm -f "$tmp"
}

# offsite_target <site>: remote path for a site
offsite_target() { offsite_join "$OFFSITE_REMOTE" "$1"; }

# offsite_join <remote> <name>: "r:" + "x" -> "r:x", "r:dir" + "x" -> "r:dir/x"
offsite_join() {
	local r=${1%/}
	if [[ "$r" == *: ]]; then printf '%s%s\n' "$r" "$2"; else printf '%s/%s\n' "$r" "$2"; fi
}

# offsite_push <local-dir> <site>
offsite_push() {
	local dir=$1 site=$2 target
	[[ -n "${OFFSITE_REMOTE:-}" ]] || return 0
	target=$(offsite_target "$site")
	info "Copying backups of $site to $target"
	run rclone copy --transfers 2 --retries 5 --low-level-retries 10 "$dir" "$target"
}

# offsite_prune <site>: delete offsite files older than OFFSITE_KEEP_DAYS.
# Only called right after a successful upload, so the newest set is always there.
offsite_prune() {
	local site=$1
	[[ -n "${OFFSITE_REMOTE:-}" && "${OFFSITE_KEEP_DAYS:-0}" -gt 0 ]] || return 0
	run rclone delete --min-age "${OFFSITE_KEEP_DAYS}d" "$(offsite_target "$site")" || warn "Could not prune old offsite backups of $site."
}

# offsite_sets <site>: backup sets stored offsite, newest first
offsite_sets() {
	rclone lsf --files-only "$(offsite_target "$1")" 2>/dev/null \
		| grep -E -- '-database\.sql(\.gz)?$' | sed -E 's/-database\.sql(\.gz)?$//' | sort -ru
}

# offsite_fetch <site> <set> <dest-dir>
offsite_fetch() {
	local site=$1 set=$2 dest=$3
	mkdir -p "$dest"
	run rclone copy --include "$set-*" "$(offsite_target "$site")" "$dest"
}

# --------------------------------------------------------------------------
# Restore points: app commits + Python/Node versions + database dumps of every site,
# taken before an update so a failed update can be rolled back.
# --------------------------------------------------------------------------
restore_points_dir() { printf '%s/restore-points\n' "$BACKUP_DIR"; }

bench_python_version() {
	"$1/env/bin/python" -c 'import sys;print(f"{sys.version_info[0]}.{sys.version_info[1]}")' 2>/dev/null || echo ''
}

# restore_point_create <bench> <label>: prints the restore point directory on stdout.
restore_point_create() {
	local bench=$1 label=${2:-manual} root dir a s commit
	root=$(restore_points_dir)
	dir="$root/$(date +%Y%m%d_%H%M%S)-$label"
	mkdir -p "$dir/sites"
	chmod 700 "$root" "$dir"
	header "Creating a restore point"
	{
		for a in $(bench_apps "$bench"); do
			[[ -d "$bench/apps/$a/.git" ]] || continue
			commit=$(git -C "$bench/apps/$a" rev-parse HEAD)
			# Keep the commit reachable even if a later shallow fetch or gc would drop it.
			git -C "$bench/apps/$a" update-ref refs/frappe-ops/restore-point "$commit" 2>/dev/null || true
			printf '%s %s %s\n' "$a" "$(app_branch "$bench" "$a")" "$commit"
		done
	} >"$dir/apps.lock"
	bench_python_version "$bench" >"$dir/python.version"
	[[ -f "$bench/.nvmrc" ]] && cp "$bench/.nvmrc" "$dir/nvmrc"
	cp "$bench/sites/apps.txt" "$dir/apps.txt" 2>/dev/null || true
	for s in $(bench_sites "$bench"); do
		if ! site_db_reachable "$bench" "$s"; then
			warn "Cannot log in to the database of $s with its own credentials; the rollback could not restore it."
		fi
		ops_backup_site "$bench" "$s" "$dir/sites/$s" 0 >&2 || { error "Backup of $s failed."; return 1; }
	done
	printf '%s\n' "$dir" >"$root/LATEST"
	prune_restore_points
	success "Restore point: $dir ($(human_size "$dir"))"
	printf '%s\n' "$dir"
}

prune_restore_points() {
	local root keep=${RESTORE_POINTS_KEEP:-3} d n=0
	root=$(restore_points_dir)
	while read -r d; do
		[[ -n "$d" ]] || continue
		n=$((n + 1))
		((n > keep)) && rm -rf -- "${root:?}/$d"
	done < <(find "$root" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r)
	return 0
}

# list_restore_points: directory names, newest first
list_restore_points() {
	find "$(restore_points_dir)" -mindepth 1 -maxdepth 1 -type d -printf '%f\n' 2>/dev/null | sort -r
}

# bench_maintenance <bench> on|off
bench_maintenance() {
	local bench=$1 state=$2 v s
	[[ "$state" == on ]] && v=1 || v=0
	( cd "$bench" && bench set-config -g maintenance_mode "$v" >/dev/null 2>&1 && bench set-config -g pause_scheduler "$v" >/dev/null 2>&1 ) || true
	if [[ "$state" == off ]]; then
		for s in $(bench_sites "$bench"); do
			( cd "$bench" && bench --site "$s" set-maintenance-mode off >/dev/null 2>&1 ) || true
		done
	fi
}

# restore_point_rollback <bench> <restore-point-dir>
# Puts every app back on the recorded commit, restores Python/Node and every site's database.
restore_point_rollback() {
	local bench=$1 dir=$2 app branch commit d cur want_py have_py s dump failed=0
	local -a soft=()
	[[ -f "$dir/apps.lock" ]] || { error "Not a restore point: $dir"; return 1; }
	header "Rolling back to $(basename "$dir")"
	bench_maintenance "$bench" on

	while read -r app branch commit; do
		d="$bench/apps/$app"
		[[ -d "$d/.git" && -n "$commit" ]] || continue
		cur=$(git -C "$d" rev-parse HEAD 2>/dev/null || true)
		if [[ "$cur" == "$commit" && "$(app_branch "$bench" "$app")" == "$branch" ]]; then continue; fi
		info "$app: back to $branch @ ${commit:0:10}"
		if [[ "$branch" == HEAD ]]; then
			run git -C "$d" checkout -q --detach "$commit" || failed=1
		else
			run git -C "$d" checkout -q -B "$branch" "$commit" || failed=1
		fi
	done <"$dir/apps.lock"
	[[ -f "$dir/apps.txt" ]] && cp "$dir/apps.txt" "$bench/sites/apps.txt"

	if [[ -f "$dir/nvmrc" ]] && ! cmp -s "$dir/nvmrc" "$bench/.nvmrc"; then
		cp "$dir/nvmrc" "$bench/.nvmrc"
	fi
	use_node_for_bench "$bench"

	want_py=$(cat "$dir/python.version" 2>/dev/null || true)
	have_py=$(bench_python_version "$bench")
	if [[ -n "$want_py" && "$want_py" != "$have_py" ]]; then
		info "Python env is $have_py; going back to $want_py"
		install_uv
		( cd "$bench" && run bench migrate-env "$(install_python "$want_py")" ) || failed=1
	fi

	header "Reinstalling the previous requirements"
	( cd "$bench" && run bench setup requirements ) || { warn "bench setup requirements reported errors."; soft+=("bench setup requirements"); }

	for s in $(bench_sites "$bench"); do
		dump=$(backup_set_part "$dir/sites/$s" "$(backup_sets "$dir/sites/$s" | head -1)" database 2>/dev/null || true)
		if [[ -z "$dump" ]]; then warn "No database dump of $s in this restore point; leaving it as is."; continue; fi
		site_db_load "$bench" "$s" "$dump" || { error "Database restore of $s failed."; failed=1; }
	done

	header "Rebuilding assets"
	( cd "$bench" && run bench build ) || { warn "bench build failed."; soft+=("bench build"); }
	for s in $(bench_sites "$bench"); do ( cd "$bench" && bench --site "$s" clear-cache >/dev/null 2>&1 ) || true; done
	bench_maintenance "$bench" off
	if bench_is_production "$bench"; then
		( cd "$bench" && run bench restart ) || as_root supervisorctl restart all || true
	fi
	if ((failed)); then
		error "Rollback finished with errors (see above). Restore point kept at $dir"
		return 1
	fi
	success "Rolled back to $(basename "$dir"): app code and databases are restored."
	if ((${#soft[@]})); then
		warn "These steps failed and need a re-run once the cause (often the network) is fixed:"
		warn "  cd $bench && $(printf '%s && ' "${soft[@]}" | sed 's/ && $//')"
	fi
}

# --------------------------------------------------------------------------
# Health checks
# --------------------------------------------------------------------------
# site_responds <bench> <site>: 0 when /api/method/ping answers "pong"
site_responds() {
	local bench=$1 site=$2 port body
	if bench_is_production "$bench"; then
		body=$(curl -s -m 15 -H "Host: $site" "http://127.0.0.1/api/method/ping" 2>/dev/null || true)
		if [[ "$body" != *pong* ]]; then
			body=$(curl -sk -m 15 --resolve "$site:443:127.0.0.1" "https://$site/api/method/ping" 2>/dev/null || true)
		fi
	else
		port=$(grep -oE '"webserver_port"\s*:\s*[0-9]+' "$bench/sites/common_site_config.json" 2>/dev/null | grep -oE '[0-9]+$' || echo 8000)
		body=$(curl -s -m 15 -H "Host: $site" "http://127.0.0.1:${port:-8000}/api/method/ping" 2>/dev/null || true)
	fi
	[[ "$body" == *pong* ]]
}

# wait_site_responds <bench> <site> [seconds]
wait_site_responds() {
	local bench=$1 site=$2 secs=${3:-90} i
	for ((i = 0; i < secs; i += 5)); do
		site_responds "$bench" "$site" && return 0
		sleep 5
	done
	return 1
}

# cert_days_left <site>: days until the Let's Encrypt/nginx certificate of <site> expires
cert_days_left() {
	local site=$1 crt="/etc/letsencrypt/live/$1/fullchain.pem" end=''
	if [[ -r "$crt" ]]; then
		end=$(openssl x509 -enddate -noout -in "$crt" 2>/dev/null | cut -d= -f2)
	else
		end=$(echo | timeout 10 openssl s_client -servername "$site" -connect 127.0.0.1:443 2>/dev/null \
			| openssl x509 -enddate -noout 2>/dev/null | cut -d= -f2)
	fi
	[[ -n "$end" ]] || return 1
	echo $(( ($(date -d "$end" +%s) - $(date +%s)) / 86400 ))
}

# --------------------------------------------------------------------------
# Cron
# --------------------------------------------------------------------------
ensure_cron() {
	if ! command -v crontab >/dev/null 2>&1; then
		case "$OS_FAMILY" in
			debian) pkg_install cron ;;
			arch) pkg_install cronie ;;
		esac
	fi
	pgrep -x cron >/dev/null 2>&1 || pgrep -x crond >/dev/null 2>&1 && return 0
	if [[ "$OS_FAMILY" == arch ]]; then service_enable_start cronie crond || true
	else service_enable_start cron cron || true
	fi
}

# cron_set <tag> <schedule> <command>: add or replace a crontab line tagged "# frappe-ops:<tag>"
cron_set() {
	local tag=$1 sched=$2 cmd=$3
	{ crontab -l 2>/dev/null | grep -vF "# frappe-ops:$tag" || true; printf '%s %s # frappe-ops:%s\n' "$sched" "$cmd" "$tag"; } | crontab -
}

cron_remove() {
	local tag=$1
	{ crontab -l 2>/dev/null | grep -vF "# frappe-ops:$tag" || true; } | crontab -
}

cron_get() { crontab -l 2>/dev/null | grep -F "# frappe-ops:$1" | head -1 || true; }
