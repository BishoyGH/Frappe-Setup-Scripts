#!/usr/bin/env bash
# Offline tests for the helper functions in lib/. No network, no root, no Frappe needed.
# Usage: tests/run-tests.sh

# shellcheck disable=SC2015,SC2012,SC2016,SC2116,SC2329  # test idioms: "cond && ok || bad"
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
printf '%d passed, %d failed\n' "$PASS" "$FAIL"
((FAIL == 0))
