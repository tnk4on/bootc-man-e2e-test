#!/usr/bin/env bash
#
# bcvk macOS vfkit E2E テストスクリプト
#
# SSoT: このファイルの原本は bootc-man-dev/tests/test-bcvk-macos.sh
#        変更は原本で行い、ここへコピーする。
#
# 使い方:
#   ./scripts/test-bcvk-macos.sh
#
# 環境変数:
#   BCVK_TEST_IMAGE  ephemeral テスト用イメージ (default: quay.io/fedora/fedora-bootc:latest)
#   BCVK_TEST_DISK   persistent VM テスト用 .raw ディスク (未指定時は bootc-man ci で生成)
#   BCVK_SKIP_EPHEMERAL   "1" で ephemeral VM テストをスキップ
#   BCVK_SKIP_PERSISTENT  "1" で persistent VM テストをスキップ
#   BCVK_TEST_LOG_DIR     テストログ保存先 (default: /tmp/bcvk-e2e-logs)
#
set -uo pipefail

BCVK_TEST_IMAGE="${BCVK_TEST_IMAGE:-quay.io/fedora/fedora-bootc:latest}"
BCVK_TEST_DISK="${BCVK_TEST_DISK:-}"
BCVK_TEST_SSH_USER="${BCVK_TEST_SSH_USER:-user}"
BCVK_TEST_SSH_KEY="${BCVK_TEST_SSH_KEY:-}"
BCVK_TEST_LOG_DIR="${BCVK_TEST_LOG_DIR:-/tmp/bcvk-e2e-logs}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
WORKSPACE_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"

mkdir -p "$BCVK_TEST_LOG_DIR"
FULL_LOG="$BCVK_TEST_LOG_DIR/e2e-$(date +%Y%m%d-%H%M%S)-$$.log"

PASSED=0
FAILED=0
SKIPPED=0
FAILURES=()

# --- helpers ---

color_pass="\033[32m"
color_fail="\033[31m"
color_skip="\033[33m"
color_reset="\033[0m"

exec 3>>"$FULL_LOG"

log() {
    echo "[$(date +%H:%M:%S)] $*" >&3
}

# Run a command, capturing stdout to a variable and logging everything.
# Usage: output=$(run_logged bcvk ephemeral ps)
# The command's stdout is returned, stderr goes to the log.
strip_ansi() {
    sed 's/\x1b\[[0-9;]*m//g'
}

run_logged() {
    log "--- CMD: $*"
    local output stderr_file
    stderr_file=$(mktemp)
    output=$("$@" 2>"$stderr_file")
    local rc=$?
    if [[ -s "$stderr_file" ]]; then
        log "STDERR:"
        strip_ansi < "$stderr_file" >&3
    fi
    rm -f "$stderr_file"
    log "EXIT: $rc"
    if [[ -n "$output" ]]; then
        log "STDOUT: $output"
    fi
    echo "$output"
    return $rc
}

run_logged_all() {
    log "--- CMD: $*"
    local output
    output=$("$@" 2>&1 | strip_ansi)
    local rc=$?
    log "EXIT: $rc"
    if [[ -n "$output" ]]; then
        log "OUTPUT: $output"
    fi
    echo "$output"
    return $rc
}

run_test() {
    local id="$1" desc="$2"
    shift 2
    printf "  %-6s %-45s " "$id" "$desc"
}

pass() {
    printf "${color_pass}PASS${color_reset}\n"
    ((PASSED++))
    log "[$CURRENT_TEST_ID] PASS: $CURRENT_TEST_DESC"
}

fail() {
    local msg="${1:-}"
    printf "${color_fail}FAIL${color_reset}"
    if [[ -n "$msg" ]]; then
        printf " (%s)" "$msg"
    fi
    printf "\n"
    ((FAILED++))
    FAILURES+=("$CURRENT_TEST_ID: $CURRENT_TEST_DESC")
    log "[$CURRENT_TEST_ID] FAIL: $CURRENT_TEST_DESC ($msg)"
}

skip() {
    local msg="${1:-}"
    printf "${color_skip}SKIP${color_reset}"
    if [[ -n "$msg" ]]; then
        printf " (%s)" "$msg"
    fi
    printf "\n"
    ((SKIPPED++))
    log "[$CURRENT_TEST_ID] SKIP: $CURRENT_TEST_DESC ($msg)"
}

CURRENT_TEST_ID=""
CURRENT_TEST_DESC=""

test_case() {
    CURRENT_TEST_ID="$1"
    CURRENT_TEST_DESC="$2"
    log ""
    log "======== [$1] $2 ========"
    run_test "$1" "$2"
}

cleanup_ephemeral() {
    bcvk ephemeral rm-all --force >/dev/null 2>&1 || true
}

# Wait until a detached ephemeral VM is SSH-ready (up to 60s).
# Usage: wait_ssh_ready <vm_name>
wait_ssh_ready() {
    local name="$1"
    local deadline=$((SECONDS + 60))
    while [[ $SECONDS -lt $deadline ]]; do
        local info
        info=$(bcvk ephemeral ps --json 2>/dev/null) || true
        local port key
        port=$(echo "$info" | python3 -c "import sys,json; d=json.load(sys.stdin); print([v['ssh_port'] for v in d if v['name']=='$name'][0])" 2>/dev/null) || true
        key=$(echo "$info" | python3 -c "import sys,json; d=json.load(sys.stdin); print([v['ssh_key'] for v in d if v['name']=='$name'][0])" 2>/dev/null) || true
        if [[ -n "$port" ]] && [[ -n "$key" ]]; then
            if ssh -p "$port" -i "$key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ConnectTimeout=2 -o LogLevel=ERROR root@localhost "true" 2>/dev/null; then
                return 0
            fi
        fi
        sleep 3
    done
    return 1
}

cleanup_vm() {
    bcvk vm rm-all --force >/dev/null 2>&1 || true
    # Kill any orphaned bcvk VM processes (but not podman machine's vfkit/gvproxy)
    pkill -f 'gvproxy.*bcvk/vms' 2>/dev/null || true
    pkill -f 'vfkit.*bcvk/vms' 2>/dev/null || true
    sleep 1
}

cleanup_all() {
    cleanup_ephemeral
    cleanup_vm
}

trap cleanup_all EXIT

# --- Phase 0: 前提条件チェック ---

echo ""
echo "========================================="
echo " bcvk macOS vfkit E2E テスト"
echo "========================================="
echo ""
echo "Image: $BCVK_TEST_IMAGE"
echo "Log:   $FULL_LOG"
echo "Logs:  $BCVK_TEST_LOG_DIR/"
echo ""

log "=== E2E test started ==="
log "Image: $BCVK_TEST_IMAGE"
log "Disk: ${BCVK_TEST_DISK:-auto}"
log "SSH user: $BCVK_TEST_SSH_USER"
log "Skip ephemeral: ${BCVK_SKIP_EPHEMERAL:-0}"
log "Skip persistent: ${BCVK_SKIP_PERSISTENT:-0}"

echo "--- Phase 0: 前提条件 ---"

test_case "0-1" "bcvk バイナリ"
if command -v bcvk >/dev/null 2>&1; then
    pass
else
    fail "bcvk not found in PATH"
    echo "FATAL: bcvk が見つかりません。中止します。" >&2
    exit 1
fi

test_case "0-2" "vfkit 検出"
if command -v vfkit >/dev/null 2>&1 || [[ -x /opt/podman/bin/vfkit ]]; then
    pass
else
    fail "vfkit not found"
    echo "FATAL: vfkit が見つかりません。中止します。" >&2
    exit 1
fi

test_case "0-3" "gvproxy 検出"
if command -v gvproxy >/dev/null 2>&1 || [[ -x /opt/podman/bin/gvproxy ]] || [[ -x /opt/homebrew/opt/podman/libexec/podman/gvproxy ]]; then
    pass
else
    fail "gvproxy not found"
    echo "FATAL: gvproxy が見つかりません。中止します。" >&2
    exit 1
fi

test_case "0-4" "podman machine 起動中"
if podman machine info --format '{{.Host.CurrentMachine}}' 2>/dev/null | grep -q .; then
    pass
else
    fail "no podman machine running"
    echo "FATAL: podman machine が起動していません。中止します。" >&2
    exit 1
fi

# --- Phase 1: Ephemeral VM テスト ---

echo ""
echo "--- Phase 1: Ephemeral VM テスト ---"

if [[ "${BCVK_SKIP_EPHEMERAL:-}" == "1" ]]; then
    echo "  (BCVK_SKIP_EPHEMERAL=1: skipped)"
    SKIPPED=$((SKIPPED + 21))
else

cleanup_ephemeral

# 1-1: run-ssh 基本動作
test_case "1-1" "run-ssh 基本動作"
output=$(run_logged bcvk ephemeral run-ssh --execute "echo OK" "$BCVK_TEST_IMAGE")
if echo "$output" | grep -q "^OK$"; then
    pass
else
    fail "expected 'OK' in output"
fi

# 1-2: run-ssh コマンド失敗で非ゼロ終了
test_case "1-2" "run-ssh コマンド失敗で非ゼロ終了"
set +e
err_out=$(run_logged_all bcvk ephemeral run-ssh --execute "exit 42" "$BCVK_TEST_IMAGE")
rc=$?
set -e
if [[ $rc -ne 0 ]] && echo "$err_out" | grep -q "command failed"; then
    pass
else
    fail "expected non-zero exit and 'command failed', got rc=$rc"
fi

# 1-3: run -d (detach)
test_case "1-3" "run -d (detach)"
vm_name=$(run_logged bcvk ephemeral run -d -K --name e2e-detach "$BCVK_TEST_IMAGE")
if [[ "$vm_name" == "e2e-detach" ]]; then
    pass
else
    fail "expected 'e2e-detach', got '$vm_name'"
fi
wait_ssh_ready e2e-detach

# 1-4: ps (テーブル)
test_case "1-4" "ps (テーブル)"
ps_out=$(run_logged bcvk ephemeral ps)
if echo "$ps_out" | grep -q "e2e-detach"; then
    pass
else
    fail "e2e-detach not in ps output"
fi

# 1-5: ps --json
test_case "1-5" "ps --json"
json_out=$(run_logged bcvk ephemeral ps --json)
if echo "$json_out" | python3 -c "import sys,json; d=json.load(sys.stdin); assert any(v['name']=='e2e-detach' for v in d)" 2>/dev/null; then
    pass
else
    fail "invalid JSON or missing name"
fi

# 1-6: ssh (コマンド実行)
# gvproxy port forward re-expose can briefly disrupt connectivity, retry up to 3 times
test_case "1-6" "ssh コマンド実行"
ssh_out=""
for attempt in 1 2 3; do
    ssh_out=$(run_logged bcvk ephemeral ssh e2e-detach -- hostname) && break
    sleep 3
done
if [[ -n "$ssh_out" ]]; then
    pass
else
    fail "empty hostname output"
fi

# 1-7: rm-all --force
test_case "1-7" "rm-all --force"
rm_out=$(run_logged bcvk ephemeral rm-all --force)
if echo "$rm_out" | grep -q "Removed"; then
    pass
else
    fail "no 'Removed' in output"
fi

# 1-8: rm-all 後の ps
test_case "1-8" "rm-all 後の ps"
ps_after=$(run_logged bcvk ephemeral ps)
if echo "$ps_after" | grep -q "No running"; then
    pass
else
    fail "VMs still present after rm-all"
fi

# 1-9: rm-all 複数 VM
test_case "1-9" "rm-all 複数 VM"
run_logged bcvk ephemeral run -d -K --name e2e-multi1 "$BCVK_TEST_IMAGE" >/dev/null
run_logged bcvk ephemeral run -d -K --name e2e-multi2 "$BCVK_TEST_IMAGE" >/dev/null
wait_ssh_ready e2e-multi1
wait_ssh_ready e2e-multi2
rm_out=$(run_logged bcvk ephemeral rm-all --force)
count=$(echo "$rm_out" | grep -c "Removed" || true)
ps_check=$(run_logged bcvk ephemeral ps)
if [[ $count -ge 2 ]] && echo "$ps_check" | grep -q "No running"; then
    pass
else
    fail "expected 2+ removed, got $count"
fi

# 1-10: --vcpus --memory
test_case "1-10" "--vcpus --memory"
output=$(run_logged bcvk ephemeral run-ssh --vcpus 4 --memory 2G --execute "nproc" "$BCVK_TEST_IMAGE")
if echo "$output" | grep -q "^4$"; then
    pass
else
    fail "expected nproc=4, got: $output"
fi

# 1-11: --karg
# Clear disk cache so the karg is included in the freshly built grub.cfg / cmdline
test_case "1-11" "--karg"
podman machine ssh -- rm -f '/var/tmp/bcvk/disk-*.raw' >/dev/null 2>&1 || true
output=$(run_logged bcvk ephemeral run-ssh --karg "systemd.log_level=debug" --execute "cat /proc/cmdline" "$BCVK_TEST_IMAGE")
if echo "$output" | grep -q "systemd.log_level=debug"; then
    pass
else
    fail "karg not found in /proc/cmdline"
fi

# 1-12: --name カスタム名
test_case "1-12" "--name カスタム名"
output=$(run_logged bcvk ephemeral run-ssh --name custom-name --execute "echo OK" "$BCVK_TEST_IMAGE")
if echo "$output" | grep -q "OK"; then
    pass
else
    fail "custom name run failed"
fi

# 1-13: run 単体 (フォアグラウンド)
test_case "1-13" "run 単体 (フォアグラウンド)"
bcvk ephemeral run -K --name e2e-fg "$BCVK_TEST_IMAGE" >/tmp/bcvk-e2e-fg.log 2>&1 &
fg_pid=$!
wait_ssh_ready e2e-fg
ps_check=$(run_logged bcvk ephemeral ps)
if echo "$ps_check" | grep -q "e2e-fg"; then
    cleanup_ephemeral
    wait $fg_pid 2>/dev/null || true
    if grep -q "starting ephemeral VM\|SSH port.*forwarded\|SSH connected" /tmp/bcvk-e2e-fg.log 2>/dev/null; then
        pass
    else
        fail "boot log incomplete"
    fi
else
    kill $fg_pid 2>/dev/null || true
    wait $fg_pid 2>/dev/null || true
    fail "VM not visible in ps"
fi
rm -f /tmp/bcvk-e2e-fg.log

# 1-14: run-ssh trailing args (バグ修正済み)
test_case "1-14" "run-ssh trailing args"
output=$(run_logged bcvk ephemeral run-ssh "$BCVK_TEST_IMAGE" -- uname -r)
if [[ -n "$output" ]] && echo "$output" | grep -qE "^[0-9]+\."; then
    pass
else
    fail "no kernel version in output: $output"
fi

# 1-15: --execute 複数回
test_case "1-15" "--execute 複数回"
output=$(run_logged bcvk ephemeral run-ssh --execute "echo A" --execute "echo B" "$BCVK_TEST_IMAGE")
if echo "$output" | grep -q "A" && echo "$output" | grep -q "B"; then
    pass
else
    fail "missing A or B in output"
fi

# 1-16: ssh リモートコマンド引数
test_case "1-16" "ssh リモートコマンド引数"
run_logged bcvk ephemeral run -d -K --name e2e-ssharg "$BCVK_TEST_IMAGE" >/dev/null
wait_ssh_ready e2e-ssharg
output=$(run_logged bcvk ephemeral ssh e2e-ssharg -- cat /etc/os-release)
cleanup_ephemeral
if echo "$output" | grep -qi "ID="; then
    pass
else
    fail "expected 'ID=' in os-release output"
fi

# 1-17: ps 自動クリーンアップ
test_case "1-17" "ps 自動クリーンアップ"
run_logged bcvk ephemeral run -d -K --name e2e-cleanup "$BCVK_TEST_IMAGE" >/dev/null
wait_ssh_ready e2e-cleanup
pid_json=$(run_logged bcvk ephemeral ps --json)
vfkit_pid=$(echo "$pid_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print([v['pid'] for v in d if v['name']=='e2e-cleanup'][0])" 2>/dev/null)
gvproxy_pid=$(echo "$pid_json" | python3 -c "import sys,json; d=json.load(sys.stdin); print([v['gvproxy_pid'] for v in d if v['name']=='e2e-cleanup'][0])" 2>/dev/null)
if [[ -n "$vfkit_pid" ]]; then
    kill "$vfkit_pid" 2>/dev/null || true
    [[ -n "$gvproxy_pid" ]] && kill "$gvproxy_pid" 2>/dev/null || true
    sleep 3
    # Also kill the detached bcvk parent to reap zombie children
    bcvk_parent=$(ps -o ppid= -p "$vfkit_pid" 2>/dev/null | tr -d ' ')
    [[ -n "$bcvk_parent" ]] && kill "$bcvk_parent" 2>/dev/null || true
    sleep 2
    ps_after=$(run_logged bcvk ephemeral ps)
    if echo "$ps_after" | grep -q "No running"; then
        pass
    else
        fail "dead VM still in ps"
        cleanup_ephemeral
    fi
else
    fail "could not get vfkit PID"
    cleanup_ephemeral
fi

cleanup_ephemeral

# 1-18: --debug フラグ
test_case "1-18" "--debug フラグ"
output=$(run_logged bcvk ephemeral run-ssh --debug --execute "echo OK" "$BCVK_TEST_IMAGE")
if echo "$output" | grep -q "OK"; then
    pass
else
    fail "--debug run failed"
fi

# 1-19: --gui --detach 排他
test_case "1-19" "--gui --detach 排他"
set +e
err_out=$(run_logged_all bcvk ephemeral run --gui -d "$BCVK_TEST_IMAGE")
rc=$?
set -e
if [[ $rc -ne 0 ]] && echo "$err_out" | grep -qi "gui.*detach\|cannot be used together"; then
    pass
else
    fail "expected error for --gui + -d"
fi

# 1-20: 非 bootc イメージ
test_case "1-20" "非 bootc イメージ"
set +e
err_out=$(run_logged_all bcvk ephemeral run-ssh --execute "echo" docker.io/library/alpine:latest)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    pass
else
    fail "expected error for non-bootc image"
fi

# 1-21: 同時起動
test_case "1-21" "同時起動"
run_logged bcvk ephemeral run -d -K --name e2e-conc1 "$BCVK_TEST_IMAGE" >/dev/null
run_logged bcvk ephemeral run -d -K --name e2e-conc2 "$BCVK_TEST_IMAGE" >/dev/null
wait_ssh_ready e2e-conc1
wait_ssh_ready e2e-conc2
ps_json=$(run_logged bcvk ephemeral ps --json)
count=$(echo "$ps_json" | python3 -c "import sys,json; print(len(json.load(sys.stdin)))" 2>/dev/null)
cleanup_ephemeral
if [[ "$count" -ge 2 ]]; then
    pass
else
    fail "expected 2+ VMs, got $count"
fi

fi  # end BCVK_SKIP_EPHEMERAL check

# --- Phase 2: Persistent VM テスト ---

echo ""
echo "--- Phase 2: Persistent VM テスト ---"

if [[ "${BCVK_SKIP_PERSISTENT:-}" == "1" ]]; then
    echo "  (BCVK_SKIP_PERSISTENT=1: skipped)"
    SKIPPED=$((SKIPPED + 24))
elif [[ -z "$BCVK_TEST_DISK" ]]; then
    echo ""
    echo "  テストデータ準備: bootc-man ci run --stage build,convert ..."
    PIPELINE_DIR="$WORKSPACE_DIR/samples/bootc-ci-test"
    if [[ ! -d "$PIPELINE_DIR" ]]; then
        echo "FATAL: $PIPELINE_DIR が見つかりません。BCVK_TEST_DISK を指定してください。" >&2
        echo ""
        echo "--- Phase 2: SKIP (ディスクイメージなし) ---"
        SKIPPED=$((SKIPPED + 24))
    else
        cd "$PIPELINE_DIR"
        if ! bootc-man ci run --stage build,convert 2>&1 | tail -5; then
            echo "FATAL: bootc-man ci run failed" >&2
            SKIPPED=$((SKIPPED + 24))
            BCVK_TEST_DISK=""
        else
            BCVK_TEST_DISK_SRC=$(find "$PIPELINE_DIR" -name "*.raw" -path "*/output/*" 2>/dev/null | head -1)
            if [[ -z "$BCVK_TEST_DISK_SRC" ]]; then
                BCVK_TEST_DISK_SRC=$(find /tmp -name "*.raw" -newer "$PIPELINE_DIR/bootc-ci.yaml" 2>/dev/null | head -1)
            fi
            if [[ -z "$BCVK_TEST_DISK_SRC" ]]; then
                echo "WARN: .raw ファイルが見つかりません。Phase 2 をスキップします。" >&2
                SKIPPED=$((SKIPPED + 24))
            else
                BCVK_TEST_DISK="/tmp/bcvk-e2e-test-disk.raw"
                echo "  Cloning disk (CoW) and clearing xattr..."
                cp -c "$BCVK_TEST_DISK_SRC" "$BCVK_TEST_DISK" 2>/dev/null || cp "$BCVK_TEST_DISK_SRC" "$BCVK_TEST_DISK"
                xattr -c "$BCVK_TEST_DISK"
                echo "  Disk: $BCVK_TEST_DISK"
            fi
        fi
        cd "$WORKSPACE_DIR"
    fi
fi

if [[ -n "$BCVK_TEST_DISK" ]]; then
    xattr -c "$BCVK_TEST_DISK" 2>/dev/null || true
fi

# Build --ssh-key option if specified
VM_SSH_KEY_OPT=""
if [[ -n "$BCVK_TEST_SSH_KEY" ]]; then
    VM_SSH_KEY_OPT="--ssh-key $BCVK_TEST_SSH_KEY"
fi

if [[ -n "$BCVK_TEST_DISK" ]] && [[ "${BCVK_SKIP_PERSISTENT:-}" != "1" ]]; then

cleanup_vm

# 2-1: vm run
test_case "2-1" "vm run"
output=$(run_logged_all bcvk vm run "$BCVK_TEST_DISK" --name e2e-vm --ssh-user "$BCVK_TEST_SSH_USER" $VM_SSH_KEY_OPT)
if echo "$output" | grep -q "is running"; then
    pass
else
    fail "vm run failed: $output"
fi

# 2-2: vm list (テーブル)
test_case "2-2" "vm list (テーブル)"
output=$(run_logged bcvk vm list)
if echo "$output" | grep -q "e2e-vm"; then
    pass
else
    fail "e2e-vm not in list"
fi

# 2-3: vm list --json
test_case "2-3" "vm list --json"
json=$(run_logged bcvk vm list --json)
if echo "$json" | python3 -c "import sys,json; json.load(sys.stdin)" 2>/dev/null; then
    pass
else
    fail "invalid JSON"
fi

# 2-4: vm ls エイリアス
test_case "2-4" "vm ls エイリアス"
output=$(run_logged bcvk vm ls)
if echo "$output" | grep -q "e2e-vm"; then
    pass
else
    fail "ls alias failed"
fi

# 2-5: vm inspect
test_case "2-5" "vm inspect"
output=$(run_logged bcvk vm inspect e2e-vm)
if echo "$output" | grep -q "Name:" && echo "$output" | grep -q "State:"; then
    pass
else
    fail "inspect output incomplete"
fi

# 2-6: vm inspect --json
test_case "2-6" "vm inspect --json"
json=$(run_logged bcvk vm inspect e2e-vm --json)
if echo "$json" | python3 -c "import sys,json; d=json.load(sys.stdin); assert 'name' in d and 'state' in d" 2>/dev/null; then
    pass
else
    fail "invalid JSON or missing fields"
fi

# 2-7: vm ssh
test_case "2-7" "vm ssh (コマンド実行)"
# vm ssh は対話モードのみなので、ssh コマンドを直接実行
ssh_info=$(run_logged bcvk vm inspect e2e-vm --json)
ssh_port=$(echo "$ssh_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_port'])" 2>/dev/null)
ssh_key=$(echo "$ssh_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_key'])" 2>/dev/null)
ssh_user=$(echo "$ssh_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_user'])" 2>/dev/null)
if [[ -n "$ssh_port" ]]; then
    output=$(run_logged ssh -p "$ssh_port" -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$ssh_user@localhost" "echo OK")
    if echo "$output" | grep -q "OK"; then
        pass
    else
        fail "ssh command failed"
    fi
else
    fail "could not get ssh info"
fi

# 2-8: vm stop
test_case "2-8" "vm stop"
output=$(run_logged_all bcvk vm stop e2e-vm)
if echo "$output" | grep -q "Stopped"; then
    pass
else
    fail "stop failed: $output"
fi

# 2-9: vm inspect (停止後)
test_case "2-9" "vm inspect (停止後)"
output=$(run_logged bcvk vm inspect e2e-vm)
if echo "$output" | grep -q "stopped"; then
    pass
else
    fail "expected stopped state"
fi

# 2-10: vm start
test_case "2-10" "vm start"
output=$(run_logged_all bcvk vm start e2e-vm)
if echo "$output" | grep -q "Started"; then
    pass
else
    fail "start failed: $output"
fi

# 2-11: vm ssh (再起動後)
test_case "2-11" "vm ssh (再起動後)"
ssh_info=$(run_logged bcvk vm inspect e2e-vm --json)
ssh_port=$(echo "$ssh_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_port'])" 2>/dev/null)
ssh_key=$(echo "$ssh_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_key'])" 2>/dev/null)
ssh_user=$(echo "$ssh_info" | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_user'])" 2>/dev/null)
output=$(ssh -p "$ssh_port" -i "$ssh_key" -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o LogLevel=ERROR "$ssh_user@localhost" "echo OK" 2>/dev/null)
if echo "$output" | grep -q "OK"; then
    pass
else
    fail "ssh after restart failed"
fi

# 2-12: vm stop → rm
test_case "2-12" "vm stop → rm"
run_logged bcvk vm stop e2e-vm >/dev/null
output=$(run_logged_all bcvk vm rm e2e-vm)
if echo "$output" | grep -q "Removed"; then
    pass
else
    fail "rm failed: $output"
fi

# 2-13: vm rm --force (稼働中)
test_case "2-13" "vm rm --force (稼働中)"
run_logged bcvk vm run "$BCVK_TEST_DISK" --name e2e-force --ssh-user "$BCVK_TEST_SSH_USER" $VM_SSH_KEY_OPT >/dev/null
output=$(run_logged_all bcvk vm rm --force e2e-force)
if echo "$output" | grep -q "Removed"; then
    pass
else
    fail "force rm failed: $output"
fi

# 2-14: vm rm-all --force
test_case "2-14" "vm rm-all --force"
DISK2="/tmp/bcvk-e2e-test-disk2.raw"
cp -c "$BCVK_TEST_DISK" "$DISK2" 2>/dev/null || cp "$BCVK_TEST_DISK" "$DISK2"
xattr -c "$DISK2" 2>/dev/null || true
run_logged bcvk vm run "$BCVK_TEST_DISK" --name e2e-rmall1 --ssh-user "$BCVK_TEST_SSH_USER" $VM_SSH_KEY_OPT >/dev/null
run_logged bcvk vm run "$DISK2" --name e2e-rmall2 --ssh-user "$BCVK_TEST_SSH_USER" $VM_SSH_KEY_OPT >/dev/null
output=$(run_logged_all bcvk vm rm-all --force)
count=$(echo "$output" | grep -c "Removed" || true)
rm -f "$DISK2"
if [[ $count -ge 2 ]]; then
    pass
else
    fail "expected 2+ removed, got $count"
fi

# 2-15: 存在しない VM
test_case "2-15" "存在しない VM"
set +e
err=$(run_logged_all bcvk vm ssh nonexistent)
rc=$?
set -e
if [[ $rc -ne 0 ]]; then
    pass
else
    fail "expected error for nonexistent VM"
fi

# 2-16: vm run --vcpus --memory
test_case "2-16" "vm run --vcpus --memory"
run_logged bcvk vm run "$BCVK_TEST_DISK" --name e2e-opts --vcpus 4 --memory 2G --ssh-user "$BCVK_TEST_SSH_USER" $VM_SSH_KEY_OPT >/dev/null
json=$(run_logged bcvk vm inspect e2e-opts --json)
cpus=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['cpus'])" 2>/dev/null)
mem=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['memory'])" 2>/dev/null)
run_logged bcvk vm rm --force e2e-opts >/dev/null
if [[ "$cpus" == "4" ]] && [[ "$mem" == "2048" ]]; then
    pass
else
    fail "cpus=$cpus mem=$mem (expected 4, 2048)"
fi

# 2-17: vm run --ssh-port 指定
test_case "2-17" "vm run --ssh-port 指定"
run_logged bcvk vm run "$BCVK_TEST_DISK" --name e2e-port --ssh-port 2299 --ssh-user "$BCVK_TEST_SSH_USER" $VM_SSH_KEY_OPT >/dev/null
json=$(run_logged bcvk vm inspect e2e-port --json)
port=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_port'])" 2>/dev/null)
run_logged bcvk vm rm --force e2e-port >/dev/null
if [[ "$port" == "2299" ]]; then
    pass
else
    fail "ssh_port=$port (expected 2299)"
fi

# 2-18: vm run --ssh-user 指定
test_case "2-18" "vm run --ssh-user 指定"
run_logged bcvk vm run "$BCVK_TEST_DISK" --name e2e-user --ssh-user user $VM_SSH_KEY_OPT >/dev/null
json=$(run_logged bcvk vm inspect e2e-user --json)
user=$(echo "$json" | python3 -c "import sys,json; print(json.load(sys.stdin)['ssh_user'])" 2>/dev/null)
run_logged bcvk vm rm --force e2e-user >/dev/null
if [[ "$user" == "user" ]]; then
    pass
else
    fail "ssh_user=$user (expected 'user')"
fi

# 2-19: vm run 名前自動生成
test_case "2-19" "vm run 名前自動生成"
run_logged bcvk vm run "$BCVK_TEST_DISK" --ssh-user "$BCVK_TEST_SSH_USER" $VM_SSH_KEY_OPT >/dev/null
output=$(run_logged bcvk vm list)
run_logged bcvk vm rm-all --force >/dev/null
disk_stem=$(basename "$BCVK_TEST_DISK" .raw)
if echo "$output" | grep -q "$disk_stem"; then
    pass
else
    fail "auto-generated name not found (expected stem: $disk_stem)"
fi

# 2-20: vm run 存在しないディスク
test_case "2-20" "vm run 存在しないディスク"
set +e
err=$(run_logged_all bcvk vm run /nonexistent/disk.raw)
rc=$?
set -e
if [[ $rc -ne 0 ]] && echo "$err" | grep -qi "not found"; then
    pass
else
    fail "expected 'not found' error"
fi

# 2-21: vm rm --force なし (稼働中)
test_case "2-21" "vm rm (稼働中, --force なし)"
run_logged bcvk vm run "$BCVK_TEST_DISK" --name e2e-noforce --ssh-user "$BCVK_TEST_SSH_USER" $VM_SSH_KEY_OPT >/dev/null
set +e
err=$(run_logged_all bcvk vm rm e2e-noforce)
rc=$?
set -e
run_logged bcvk vm rm --force e2e-noforce >/dev/null
if [[ $rc -ne 0 ]] && echo "$err" | grep -qi "running"; then
    pass
else
    fail "expected 'is running' error"
fi

# 2-22: vm stop 停止中 VM
test_case "2-22" "vm stop 停止中 VM"
run_logged bcvk vm run "$BCVK_TEST_DISK" --name e2e-stoptwice --ssh-user "$BCVK_TEST_SSH_USER" $VM_SSH_KEY_OPT >/dev/null
run_logged bcvk vm stop e2e-stoptwice >/dev/null
set +e
err=$(run_logged_all bcvk vm stop e2e-stoptwice)
rc=$?
set -e
run_logged bcvk vm rm e2e-stoptwice >/dev/null
if [[ $rc -ne 0 ]] && echo "$err" | grep -qi "not running"; then
    pass
else
    fail "expected 'not running' error"
fi

# 2-23: vm start 稼働中 VM
test_case "2-23" "vm start 稼働中 VM"
run_logged bcvk vm run "$BCVK_TEST_DISK" --name e2e-startrun --ssh-user "$BCVK_TEST_SSH_USER" $VM_SSH_KEY_OPT >/dev/null
set +e
err=$(run_logged_all bcvk vm start e2e-startrun)
rc=$?
set -e
run_logged bcvk vm rm --force e2e-startrun >/dev/null
if [[ $rc -ne 0 ]] && echo "$err" | grep -qi "already running"; then
    pass
else
    fail "expected 'already running' error"
fi

# 2-24: vm ssh 停止中 VM
test_case "2-24" "vm ssh 停止中 VM"
run_logged bcvk vm run "$BCVK_TEST_DISK" --name e2e-sshstop --ssh-user "$BCVK_TEST_SSH_USER" $VM_SSH_KEY_OPT >/dev/null
run_logged bcvk vm stop e2e-sshstop >/dev/null
set +e
err=$(run_logged_all bcvk vm ssh e2e-sshstop)
rc=$?
set -e
run_logged bcvk vm rm e2e-sshstop >/dev/null
if [[ $rc -ne 0 ]] && echo "$err" | grep -qi "not running"; then
    pass
else
    fail "expected 'not running' error"
fi

fi  # end persistent VM tests

# --- サマリー ---

echo ""
echo "========================================="
echo " テスト結果"
echo "========================================="
printf "  ${color_pass}PASSED:  %d${color_reset}\n" "$PASSED"
printf "  ${color_fail}FAILED:  %d${color_reset}\n" "$FAILED"
printf "  ${color_skip}SKIPPED: %d${color_reset}\n" "$SKIPPED"
echo "  TOTAL:   $((PASSED + FAILED + SKIPPED))"

if [[ ${#FAILURES[@]} -gt 0 ]]; then
    echo ""
    echo "  失敗テスト:"
    for f in "${FAILURES[@]}"; do
        echo "    - $f"
    done
fi

echo ""
echo "  Full log: $FULL_LOG"
echo "  Per-test: $BCVK_TEST_LOG_DIR/"
echo ""

log "=== E2E test finished: PASSED=$PASSED FAILED=$FAILED SKIPPED=$SKIPPED ==="
exec 3>&-

if [[ $FAILED -gt 0 ]]; then
    exit 1
fi
exit 0
