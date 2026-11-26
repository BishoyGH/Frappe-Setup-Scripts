#!/usr/bin/env bash
# Offline tests for the helper functions in lib/. No network, no root, no Frappe needed.
# Usage: tests/run-tests.sh

# shellcheck disable=SC2015,SC2012,SC2016,SC2116,SC2329,SC2030,SC2031  # test idioms: "cond && ok || bad"
set -uo pipefail
ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
export HOME="$TMP/home" XDG_STATE_HOME="$TMP/state" NO_COLOR=1 FSS_LOG_DIR="$TMP/logs"
mkdir -p "$HOME"

# shellcheck source=lib/common.sh
. "$ROOT/lib/common.sh"
# shellcheck source=lib/apps.sh
. "$ROOT/lib/apps.sh"
# shellcheck source=lib/unattended.sh
. "$ROOT/lib/unattended.sh"
# shellcheck source=lib/ops.sh
. "$ROOT/lib/ops.sh"

PASS=0 FAIL=0 CURRENT=''
t() { CURRENT=$1; }
ok() { PASS=$((PASS + 1)); }
bad() { FAIL=$((FAIL + 1)); printf 'FAIL [%s] %s\n' "$CURRENT" "$*" >&2; }
eq() { # eq <expected> <actual> [label]
	if [[ "$1" == "$2" ]]; then ok; else bad "${3:-}: expected '$1', got '$2'"; fi
}
fails() { # fails <command...>: the command must exit non-zero (run in a subshell; die exits)
	if ( "$@" ) >/dev/null 2>&1; then bad "expected failure: $*"; else ok; fi
}

# --------------------------------------------------------------------------
t "frappe_major_from_ref"
eq 15 "$(frappe_major_from_ref version-15)"
eq 15 "$(frappe_major_from_ref v15.50.0)"
eq develop "$(frappe_major_from_ref develop)"
eq develop "$(frappe_major_from_ref main)"
eq '' "$(frappe_major_from_ref my-feature)"

t "python/node for major"
eq 3.10 "$(python_for_major 14)"
eq 3.11 "$(python_for_major 15)"
eq 3.14 "$(python_for_major 16)"
eq 3.14 "$(python_for_major develop)"
eq 18 "$(node_for_major 15)"
eq 24 "$(node_for_major 16)"

t "resolve_app_deps"
eq "erpnext hrms" "$(resolve_app_deps hrms | tr '\n' ' ' | sed 's/ $//')"
eq "payments erpnext webshop" "$(resolve_app_deps webshop | tr '\n' ' ' | sed 's/ $//')"
eq "telephony helpdesk my_app" "$(resolve_app_deps my_app helpdesk | tr '\n' ' ' | sed 's/ $//')"
eq "" "$(resolve_app_deps)"

t "catalog"
eq https://github.com/frappe/health "$(app_repo healthcare)"
app_in_catalog erpnext && ok || bad "erpnext in catalog"
app_in_catalog nope && bad "nope in catalog" || ok

t "pick_app_branch"
remote_branches() { printf '%s\n' develop main version-14 version-15; }
eq version-15 "$(pick_app_branch x version-15)"
eq develop "$(pick_app_branch x develop)"
eq main "$(pick_app_branch x version-16)" "no version-16 -> main"
remote_branches() { printf '%s\n' version-13 version-14; }
eq version-14 "$(pick_app_branch x version-16)" "only old release branches -> newest"
remote_branches() { :; }
fails pick_app_branch x version-15
unset -f remote_branches
# shellcheck source=lib/apps.sh
_FSS_APPS_LOADED='' . "$ROOT/lib/apps.sh"

t "prompts with ASSUME_DEFAULTS"
ASSUME_DEFAULTS=1
ask v "Name" "frappe-bench" 2>/dev/null; eq frappe-bench "$v"
ask_optional v "Optional" "" 2>/dev/null; eq '' "$v"
ask_yes_no "Yes?" y 2>/dev/null && ok || bad "ask_yes_no default y"
ask_yes_no "No?" n 2>/dev/null && bad "ask_yes_no default n" || ok
choose v "Pick" 2 "a|first" "b|second" 2>/dev/null; eq b "$v"
choose_multi arr "Pick" "1 3" a b c 2>/dev/null; eq "a c" "${arr[*]}"
choose_multi arr "Pick" "a" a b c 2>/dev/null; eq "a b c" "${arr[*]}"
choose_multi arr "Pick" "" a b c 2>/dev/null; eq "" "${arr[*]}"
fails choose_multi arr "Pick" "9" a b
fails ask_secret v "Password" yes NOT_SET_VAR
SECRET_VAR=s3cret ask_secret v "Password" yes SECRET_VAR; eq s3cret "$v"
ASSUME_DEFAULTS=0

t "secret masking"
_FSS_SECRETS=()
mask_secret 'p@ss w0rd'
mask_secret ''
eq "new-site x --admin-password ****" "$(masked new-site x --admin-password 'p@ss w0rd')"
eq "\$ echo --db-root-password ****" "$(run echo --db-root-password 'p@ss w0rd' 2>&1 >/dev/null)"

t "password_problem"
password_problem "abcd" 4 >/dev/null && ok || bad "4 chars, min 4"
eq "Use at least 8 characters." "$(password_problem short 8)"
fails password_problem " leading-space" 1
fails password_problem "trailing-space " 1
fails password_problem $'tab\there' 1
password_problem "p@ss w0rd with spaces" 8 >/dev/null && ok || bad "inner spaces allowed"

t "password_weakness"
for w in password Password123! admin admin2024 frappe aaaaaaaaaaaa 12345678 987654 abcdefgh qwertyuiop changeme; do
	password_weakness "$w" >/dev/null && bad "'$w' should be weak" || ok
done
eq "it is shorter than 12 characters" "$(password_weakness 'Xk9#pQ2m')"
eq "it contains 'frappeuser'" "$(password_weakness 'myfrappeuser-Pw1!' frappeuser)"
eq "it contains 'erp'" "$(password_weakness 'Erp-Server-2024!' erp.example.com erp)"
password_weakness 'Tr0ub4dor&3x!' >/dev/null && ok || bad "strong mixed password"
password_weakness 'correct horse battery staple' >/dev/null && ok || bad "long passphrase"
password_weakness 'alllowercaseletters' >/dev/null && ok || bad "16+ chars needs fewer kinds"
fails password_weakness 'lowercaseonly'
password_weakness "$(gen_password 20)" >/dev/null && ok || bad "generated passwords are strong"

# Plain prompts read stdin in these tests instead of the terminal.
np() { # np <input lines> <ask_new_password args...>: prints the chosen password, then the generated list
	local input=$1; shift
	(
		_tty_read() { local __v=$1; shift; IFS= read -r "$@" "${__v?}"; }
		FSS_UI=plain _FSS_TUI_CHECKED=0 ASSUME_DEFAULTS=0
		ask_new_password out "$@" 2>/dev/null || exit 1
		printf '%s\n' "$out" "${#FSS_GENERATED_SECRETS[@]}"
	) <<<"$input"
}

t "ask_new_password: typed by the user"
eq $'Tr0ub4dor&3x!\n0' "$(np $'Tr0ub4dor&3x!\nTr0ub4dor&3x!' "DB" "" 8)" "typed twice"
eq $'Tr0ub4dor&3x!\n0' "$(np $'Tr0ub4dor&3x!\nmismatch\nTr0ub4dor&3x!\nTr0ub4dor&3x!' "DB" "" 8)" "mismatch asks again"
eq $'Tr0ub4dor&3x!\n0' "$(np $'short\nTr0ub4dor&3x!\nTr0ub4dor&3x!' "DB" "" 8)" "too short asks again"
eq $'Tr0ub4dor&3x!\n0' "$(np $'password1\nn\nTr0ub4dor&3x!\nTr0ub4dor&3x!' "DB" "" 8)" "weak, declined"
eq $'password1\n0' "$(np $'password1\ny\npassword1' "DB" "" 8)" "weak, accepted"
eq $'Tr0ub4dor&3x!\n0' "$(np $'site1-Secret-99\nn\nTr0ub4dor&3x!\nTr0ub4dor&3x!' "Admin" "" 4 site1.localhost site1)" "contains site name"

t "ask_new_password: generated"
out=$(np '' "DB" "" 8)
[[ "$(sed -n 1p <<<"$out")" =~ ^[A-Za-z0-9]{20}$ ]] && ok || bad "generated: $out"
eq 1 "$(sed -n 2p <<<"$out")" "remembered for the summary"
(
	_tty_read() { local __v=$1; shift; IFS= read -r "$@" "${__v?}"; }
	FSS_UI=plain _FSS_TUI_CHECKED=0 ASSUME_DEFAULTS=0 FSS_CRED_FILE="$TMP/creds/b1.txt" F0=$FAIL
	ask_new_password pw "MariaDB root password" "" 8 2>/dev/null <<<''
	eq 600 "$(stat -c %a "$FSS_CRED_FILE")" "saved right away, private"
	eq "MariaDB root password: $pw" "$(grep -v '^#' "$FSS_CRED_FILE")"
	((FAIL == F0))
) || bad "checks above"

t "ask_new_password: resumed run reuses generated passwords"
(
	FSS_GENERATED_SECRETS=() _FSS_SECRETS=() FSS_CRED_FILE="$TMP/creds/b1.txt" F0=$FAIL
	load_generated_secrets "$FSS_CRED_FILE"
	eq 1 "${#FSS_GENERATED_SECRETS[@]}"
	load_generated_secrets "$FSS_CRED_FILE"
	eq 1 "${#FSS_GENERATED_SECRETS[@]}" "loading twice adds nothing"
	saved=$(generated_secret "MariaDB root password")
	ask_new_password pw "MariaDB root password" "" 8 2>/dev/null </dev/null
	eq "$saved" "$pw" "no prompt, same password"
	eq "x ****" "$(masked x "$saved")" "loaded passwords are masked"
	((FAIL == F0))
) || bad "checks above"
load_generated_secrets "$TMP/does-not-exist" && ok || bad "missing file is fine"

t "ask_new_password: unattended"
(
	_FSS_SECRETS=() ASSUME_DEFAULTS=1 F0=$FAIL
	MY_PW='hunter22' ask_new_password v "DB" MY_PW 8 2>"$TMP/np.err"; eq hunter22 "$v" "env value used even if weak"
	grep -q 'MY_PW is weak' "$TMP/np.err" && ok || bad "warns about the weak env password"
	grep -q 'hunter22' "$TMP/np.err" && bad "warning must not show the password" || ok
	eq "x ****" "$(masked x hunter22)" "env password masked"
	fails ask_new_password v "DB" UNSET_PW 8
	((FAIL == F0))
) || bad "checks above"

t "answers file"
cat >"$TMP/a.conf" <<'EOF'
# comment
MODE=production
  export SITE_NAME = "erp.example.com"
APPS='erpnext, hrms'
DB_ROOT_PASSWORD=dbpw
FRAPPE_BRANCH=version-15
EOF
ANSWER=() DB_ROOT_PASSWORD=''
set_answer FRAPPE_BRANCH develop # a flag wins over the file
load_answers_file "$TMP/a.conf" MODE SITE_NAME APPS FRAPPE_BRANCH 2>/dev/null
eq production "${ANSWER[MODE]}"
eq erp.example.com "${ANSWER[SITE_NAME]}"
eq "erpnext, hrms" "${ANSWER[APPS]}"
eq develop "${ANSWER[FRAPPE_BRANCH]}" "flag wins"
eq dbpw "$DB_ROOT_PASSWORD" "secret goes to its variable"
eq "" "${ANSWER[DB_ROOT_PASSWORD]:-}" "secret not kept as an answer"
eq "erpnext hrms" "$(split_list "${ANSWER[APPS]}" | tr '\n' ' ' | sed 's/ $//')"
printf 'BOGUS=1\n' >"$TMP/b.conf"
fails load_answers_file "$TMP/b.conf" MODE
printf 'not a setting\n' >"$TMP/c.conf"
fails load_answers_file "$TMP/c.conf" MODE
fails load_answers_file "$TMP/missing.conf" MODE
printf 'MODE=development\r\nSITE_NAME=\r\n' >"$TMP/d.conf"
ANSWER=()
load_answers_file "$TMP/d.conf" MODE SITE_NAME
eq development "${ANSWER[MODE]}" "CRLF line endings"
has_answer SITE_NAME && ok || bad "empty value is still an answer"

t "preset helpers"
ANSWER=([MODE]=production [CREATE_SITE]=no [DNS]=yes [BAD]=maybe)
preset MODE "Mode" 2>/dev/null && eq production "$MODE" || bad "preset MODE"
preset NOPE "Nope" 2>/dev/null && bad "preset of missing key" || ok
preset_bool CREATE_SITE "Site?" 2>/dev/null; eq 1 "$?"
preset_bool DNS "DNS?" 2>/dev/null; eq 0 "$?"
preset_bool MISSING "x" 2>/dev/null; eq 2 "$?"
fails preset_bool BAD "x"
ASSUME_DEFAULTS=1
ask_bool_preset MISSING "Default yes" y 2>/dev/null; eq 0 "$?"
ask_bool_preset CREATE_SITE "Preset no" y 2>/dev/null; eq 1 "$?"
ASSUME_DEFAULTS=0
MODE=production; expect_one_of MODE development production && ok || bad "expect_one_of"
MODE=prod; fails expect_one_of MODE development production

t "resumable steps"
state_use install-test
count=0
work() { count=$((count + 1)); }
step one "first" work 2>/dev/null
step one "first" work 2>/dev/null
eq 1 "$count" "a finished step is skipped"
step_is_done two && bad "two not done yet" || ok
state_set appname-x real_x
state_set appname-x real_y
eq real_y "$(state_get appname-x)" "state_set overwrites"
eq one "$(last_done_step "$FSS_STATE_FILE")"
(FSS_FAIL_AFTER_STEP=two; mark_step_done two) 2>/dev/null && bad "fail hook" || ok
step_is_done two && ok || bad "step recorded before the fail hook stops"
save_answers "$TMP/saved.conf" "MODE=development" "APPS=erpnext,hrms" "CUSTOM_APPS="
eq 600 "$(stat -c %a "$TMP/saved.conf")" "answers file is private"
ANSWER=()
load_answers_file "$TMP/saved.conf" MODE APPS CUSTOM_APPS
eq "development|erpnext,hrms|" "${ANSWER[MODE]}|${ANSWER[APPS]}|${ANSWER[CUSTOM_APPS]}" "round trip"

t "log file"
out=$(
	bash -c '
		. "$1/lib/common.sh"
		setup_logging unit
		mask_secret hunter2
		run true --password hunter2
		printf "\e[31mred\e[0m\n"
		for i in $(seq 1 500); do echo "line $i"; done
		echo "LAST LINE"
	' _ "$ROOT" 2>&1
)
log=$(ls -t "$FSS_LOG_DIR"/unit-*.log | head -1)
grep -q 'LAST LINE' "$log" && ok || bad "last line reached the log"
grep -q 'hunter2' "$log" && bad "secret leaked to the log" || ok
grep -q $'\e' "$log" && bad "colour codes in the log" || ok
grep -qx 'red' "$log" && ok || bad "colour stripped text present"
eq 600 "$(stat -c %a "$log")" "log is private"
[[ "$out" == *"LAST LINE"* ]] && ok || bad "terminal output kept"
for i in $(seq 1 25); do touch -d "-$i minutes" "$FSS_LOG_DIR/unit-2000010${i}-000000-1.log"; done
bash -c '. "$1/lib/common.sh"; setup_logging unit' _ "$ROOT" >/dev/null 2>&1
eq 20 "$(find "$FSS_LOG_DIR" -name 'unit-*.log' | wc -l | tr -d ' ')" "keeps the newest 20 logs"

t "log writer does not hang on a leftover background process"
start=$(date +%s)
timeout 30 bash -c '
	. "$1/lib/common.sh"
	setup_logging hang
	sleep 60 &   # like a daemon that inherited stdout
	echo "BEFORE EXIT"
' _ "$ROOT" >/dev/null 2>&1
eq 0 "$?" "script exits (not killed by timeout)"
(( $(date +%s) - start < 20 )) && ok || bad "took $(( $(date +%s) - start ))s"
grep -q 'BEFORE EXIT' "$(ls -t "$FSS_LOG_DIR"/hang-*.log | head -1)" && ok || bad "output before exit is in the log"
pkill -f 'sleep 60' 2>/dev/null || true

t "install.sh argument handling"
fails bash "$ROOT/install.sh" --bogus
fails bash "$ROOT/install.sh" --mode
fails bash "$ROOT/install.sh" --config "$TMP/missing.conf"
bash "$ROOT/install.sh" --help | grep -q -- '--non-interactive' && ok || bad "--help lists options"

# --------------------------------------------------------------------------
t "backup sets and retention"
BK="$TMP/backups"; mkdir -p "$BK"
for d in 1 3 10 20 30 40; do
	ts=$(date -d "-$d days" +%Y%m%d_%H%M%S)
	for p in database.sql.gz files.tgz private-files.tgz site_config_backup.json; do touch "$BK/$ts-s1_test-$p"; done
done
touch "$BK/unrelated.txt"
eq 6 "$(backup_sets "$BK" | wc -l | tr -d ' ')" "six sets"
newest=$(backup_sets "$BK" | head -1)
eq "$(date -d '-1 days' +%Y%m%d)" "${newest:0:8}" "newest first"
eq "$BK/$newest-files.tgz" "$(backup_set_part "$BK" "$newest" files)" "set part"
backup_set_part "$BK" "$newest" nope >/dev/null && bad "missing part found" || ok
prune_backup_sets "$BK" 14 2 2>/dev/null
eq 3 "$(backup_sets "$BK" | wc -l | tr -d ' ')" "keeps sets newer than 14 days"
prune_backup_sets "$BK" 0 2 2>/dev/null
eq 2 "$(backup_sets "$BK" | wc -l | tr -d ' ')" "always keeps the newest 2"
[[ -f "$BK/unrelated.txt" ]] && ok || bad "other files are left alone"
eq 0 "$(newest_backup_age_hours "$BK" | tr -d ' ')" "age of the newest backup (mtime)"
eq '' "$(newest_backup_age_hours "$TMP/none")" "no backup dir"

t "offsite paths"
eq "r:site1" "$(offsite_join "r:" site1)"
eq "r:bucket/p/site1" "$(offsite_join "r:bucket/p/" site1)"
eq "r:/srv/b/site1" "$(offsite_join "r:/srv/b" site1)"

t "ops settings"
B="$TMP/bench"; mkdir -p "$B"
( ops_load_conf "$B"; eq 14 "$BACKUP_KEEP_DAYS"; eq "$HOME/frappe-backups/bench" "$BACKUP_DIR"
  OFFSITE_REMOTE='fo-x:my bucket/a b'; NOTIFY_WEBHOOK='https://h/x?a=1&b=$2'; ops_save_conf "$B" 2>/dev/null )
eq 600 "$(stat -c %a "$B/.frappe-ops.conf")" "conf is private"
( ops_load_conf "$B"; eq 'fo-x:my bucket/a b' "$OFFSITE_REMOTE"; eq 'https://h/x?a=1&b=$2' "$NOTIFY_WEBHOOK" )
( export BACKUP_KEEP_DAYS=30; ops_load_conf "$B"; eq 30 "$BACKUP_KEEP_DAYS" "environment wins over the file" )

t "site database settings"
mkdir -p "$B/sites/s1"
printf '{"db_host": "db.internal"}' >"$B/sites/common_site_config.json"
printf '{"db_name": "_abc", "db_password": "p\x27w \\"x"}' >"$B/sites/s1/site_config.json"
( site_db_info "$B" s1 && ok || bad "site_db_info"
  eq _abc "$SDB_NAME"; eq _abc "$SDB_USER" "user defaults to db name"; eq "p'w \"x" "$SDB_PASS"
  eq db.internal "$SDB_HOST" "common config"; eq 3306 "$SDB_PORT"; eq mariadb "$SDB_TYPE" )

t "mariadb tuning sizes"
( awk() { command awk "$@"; }
  read -r pool log < <(mariadb_tuning_values 2>/dev/null || true)
  [[ "$pool" =~ ^[0-9]+$ ]] && ((pool >= 256 && pool % 128 == 0)) && ok || bad "pool $pool"
  [[ "$log" =~ ^[0-9]+$ ]] && ((log >= 64 && log <= 2048)) && ok || bad "log $log" ) 2>/dev/null || true

t "cron entries"
if command -v crontab >/dev/null 2>&1; then
	crontab() { if [[ "${1:-}" == -l ]]; then cat "$TMP/crontab" 2>/dev/null; else cat >"$TMP/crontab.new" && mv "$TMP/crontab.new" "$TMP/crontab"; fi; }
	echo '0 1 * * * other job' >"$TMP/crontab"
	cron_set "backup:/b 1" "1 2 * * *" "echo a"
	cron_set "backup:/b 1" "3 4 * * *" "echo b"
	cron_set "status:/b 1" "*/10 * * * *" "echo s"
	eq 3 "$(wc -l <"$TMP/crontab" | tr -d ' ')" "replaced, not duplicated"
	eq "3 4 * * * echo b # frappe-ops:backup:/b 1" "$(cron_get "backup:/b 1")"
	cron_remove "backup:/b 1"; cron_remove "status:/b 1"
	eq "0 1 * * * other job" "$(cat "$TMP/crontab")" "other jobs kept"
	unset -f crontab
fi

t "ops.sh argument handling"
fails bash "$ROOT/ops.sh" bogus
bash "$ROOT/ops.sh" --help | grep -q 'rollback' && ok || bad "--help lists commands"

t "WSL drive mounts"
cat >"$TMP/mounts" <<'MOUNTS'
none /mnt/wsl tmpfs rw,relatime 0 0
C:\134 /mnt/c 9p rw,noatime,dirsync,aname=drvfs;path=C:\;uid=1000;gid=1000;symlinkroot=/mnt/ 0 0
drvfs /mnt/d 9p rw,noatime,aname=drvfs;path=D:\;uid=1000 0 0
/dev/sdc / ext4 rw,relatime 0 0
MOUNTS
eq "c /mnt/c|d /mnt/d" "$(wsl_drive_mounts "$TMP/mounts" | paste -sd'|')"

t "WSL virtual disk location"
lxss=$'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss\r\n    DefaultDistribution    REG_SZ    {a}\r\n\r\n'
lxss+=$'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss\\{a}\r\n    BasePath    REG_SZ    C:\\Users\\Me\\AppData\\Local\\Packages\\Ubuntu\\LocalState\r\n    DistributionName    REG_SZ    Ubuntu\r\n\r\n'
lxss+=$'HKEY_CURRENT_USER\\Software\\Microsoft\\Windows\\CurrentVersion\\Lxss\\{b}\r\n    DistributionName    REG_SZ    Debian Test\r\n    BasePath    REG_SZ    \\\\?\\E:\\WSL\\Debian\r\n'
eq 'C:\Users\Me\AppData\Local\Packages\Ubuntu\LocalState' "$(wsl_lxss_base_path Ubuntu <<<"$lxss")"
eq '\\?\E:\WSL\Debian' "$(wsl_lxss_base_path 'Debian Test' <<<"$lxss")" "last key, name with a space"
eq '' "$(wsl_lxss_base_path Arch <<<"$lxss")" "unknown distro"

t "WSL PATH and .wslconfig"
( IS_WSL=1 PATH="/usr/bin:/mnt/c/Windows/system32:/home/u/.local/bin:/mnt/c/Program Files/nodejs:/mnt/data/bin:/bin"
  wsl_strip_windows_path; eq "/usr/bin:/home/u/.local/bin:/mnt/data/bin:/bin" "$PATH" )
( IS_WSL=0 PATH="/usr/bin:/mnt/c/x"; wsl_strip_windows_path; eq "/usr/bin:/mnt/c/x" "$PATH" "not WSL: unchanged" )
( res_meminfo_mb() { echo 16000; }; wslconfig_recommended | grep -qx 'memory=6GB' && ok || bad "memory capped at 6 GB" )
( res_meminfo_mb() { echo 3900; }; wslconfig_recommended | grep -qx 'memory=4GB' && ok || bad "memory at least 4 GB" )
printf '[wsl2]\n# memory=2GB\nswap=0\n' >"$TMP/wslconfig"
wslconfig_has "$TMP/wslconfig" memory && bad "commented key counts" || ok
printf '[wsl2]\r\nMemory = 4GB\r\n' >"$TMP/wslconfig"
wslconfig_has "$TMP/wslconfig" memory && ok || bad "key with spaces and CRLF"

t "resource helpers"
[[ "$(res_free_mb "$TMP/does/not/exist")" =~ ^[0-9]+$ ]] && ok || bad "free space of a missing path"
[[ "$(res_meminfo_mb MemTotal)" =~ ^[1-9][0-9]*$ ]] && ok || bad "MemTotal"
eq 0 "$(res_meminfo_mb NoSuchKey)"
( IS_WSL=0; res_disk_problem "$TMP" 1 >/dev/null && bad "plenty of space" || ok
  msg=$(res_disk_problem "$TMP" 999999999) && [[ "$msg" == "only "* ]] && ok || bad "low space: $msg" )
sleep 30 & sl=$!
( sleep 31 ) & sub=$!
desc=" $(res_descendants $$ "$sub" | tr '\n' ' ') "
[[ "$desc" == *" $sl "* ]] && ok || bad "child listed"
[[ "$desc" != *" $sub "* ]] && ok || bad "excluded child skipped"
pkill -P "$sub" 2>/dev/null; kill "$sl" "$sub" 2>/dev/null; wait 2>/dev/null

t "resource guard stops a run"
guarded() { # guarded <name> <guard env...> -- <command...>: a small script that runs <command> under the guard
	local name=$1; shift
	local -a env=()
	while [[ "$1" != -- ]]; do env+=("$1"); shift; done; shift
	{
		printf '. %q\nstrict_mode\nsetup_logging %q\nIS_WSL=0\n' "$ROOT/lib/common.sh" "$name"
		printf '%s ' FSS_GUARD_INTERVAL=1 "${env[@]}"; printf 'resource_guard_start %q\n' "$TMP"
		printf '%s\necho "after"\n' "$*"
	} >"$TMP/$name.sh"
	bash "$TMP/$name.sh" 2>&1
}
start=$(date +%s)
out=$(guarded g1 FSS_MIN_FREE_MB=999999999 -- run sleep 60); rc=$?
eq 143 "$rc" "exit status"
(( $(date +%s) - start < 20 )) && ok || bad "stopped quickly"
[[ "$out" == *"Safety stop. Disk almost full"* && "$out" == *"Stopped by the safety check"* ]] && ok || bad "explains the stop: $out"
[[ "$out" != *after* ]] && ok || bad "script did not continue"
grep -q '^# resources' "$FSS_LOG_DIR"/g1-*.log && ok || bad "resource snapshot in the log"
out=$(guarded g2 FSS_LOG_MAX_MB=1 -- run yes | tail -c 2000)
[[ "$out" == *"The log grew past 1 MB"* ]] && ok || bad "endless output stopped"
out=$(guarded g3 FSS_MIN_FREE_MB=999999999 -- 'while :; do :; done')
[[ "$out" == *"Stopped by the safety check"* ]] && ok || bad "busy script stopped"
out=$(guarded g4 -- echo fine); rc=$?
eq 0 "$rc" "a normal run is not affected"
[[ "$out" == *fine*after* && "$out" != *Safety* ]] && ok || bad "normal output: $out"

# --------------------------------------------------------------------------
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
