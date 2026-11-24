#!/usr/bin/env bash
set -euo pipefail

project_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)
work_dir=$(mktemp -d)
trap 'rm -f -- "$work_dir/avahi.conf" "$work_dir/busctl" "$work_dir/hostname" "$work_dir/systemctl" "$work_dir/restarts" "$work_dir/last-attempt" "$work_dir/last-attempt.new"; rmdir -- "$work_dir"' EXIT

cat > "$work_dir/hostname" <<'MOCK'
#!/usr/bin/env bash
printf '%s\n' "$TEST_HOSTNAME"
MOCK

cat > "$work_dir/systemctl" <<'MOCK'
#!/usr/bin/env bash
case "$1" in
    is-active) [[ $TEST_STATE != inactive ]] ;;
    try-restart)
        printf '%s\n' "$2" >> "$RUNTIME_DIRECTORY/restarts"
        [[ $TEST_RESTART != fail ]]
        ;;
    *) exit 90 ;;
esac
MOCK

cat > "$work_dir/busctl" <<'MOCK'
#!/usr/bin/env bash
case "${!#}" in
    GetState)
        [[ $TEST_STATE != failed-query ]] || exit 1
        if [[ $TEST_STATE == registering ]]; then
            printf 'i 1\n'
        else
            printf 'i 2\n'
        fi
        ;;
    ExecStart)
        [[ $TEST_STATE != failed-execstart ]] || exit 1
        printf '%s\n' "$TEST_EXEC_START"
        ;;
    GetDomainName)
        [[ $TEST_STATE != failed-domain ]] || exit 1
        printf 's "%s"\n' "$TEST_DOMAIN"
        ;;
    GetHostNameFqdn)
        name=$TEST_PUBLISHED
        if [[ -e $RUNTIME_DIRECTORY/restarts ]]; then name=$TEST_AFTER; fi
        printf 's "%s"\n' "$name"
        ;;
    *) exit 91 ;;
esac
MOCK

chmod +x "$work_dir/hostname" "$work_dir/systemctl" "$work_dir/busctl"

run_case() {
    local description=$1 hostname=$2 domain=$3 published=$4 after=$5
    local expected_restarts=$6 expected_attempt=$7 expected_status=$8
    shift 8
    local config=${TEST_CONFIG:-$'[server]\n#host-name=example'}
    local default_exec='a(sasbttttuii) 1 "/usr/sbin/avahi-daemon" 2 "/usr/sbin/avahi-daemon" "-s" false 0 0 0 0 0 0 0'
    local status=0 output restart_calls='' has_attempt=no

    rm -f -- "$work_dir/restarts"
    if [[ ${KEEP_ATTEMPT:-no} != yes ]]; then rm -f -- "$work_dir/last-attempt"; fi
    printf '%s\n' "$config" > "$work_dir/avahi.conf"
    if [[ ${1:-} ]]; then printf '%s\n' "$1" > "$work_dir/last-attempt"; fi

    # Expand the positional arguments in the child shell.
    # shellcheck disable=SC2016
    output=$(env "PATH=$work_dir:$PATH" "RUNTIME_DIRECTORY=$work_dir" \
        "TEST_HOSTNAME=$hostname" "TEST_DOMAIN=$domain" \
        "TEST_PUBLISHED=$published" "TEST_AFTER=$after" \
        "TEST_STATE=${TEST_STATE:-running}" "TEST_RESTART=${TEST_RESTART:-success}" \
        "TEST_EXEC_START=${TEST_EXEC_START-$default_exec}" "TEST_NOW=${TEST_NOW:-10800}" \
        bash -c '
            source "$1"
            monotonic_seconds() { printf "%s\n" "$TEST_NOW"; }
            main "$2"
        ' bash "$project_dir/avahi-name-recovery" "$work_dir/avahi.conf" 2>&1) || status=$?

    if [[ -f $work_dir/restarts ]]; then restart_calls=$(cat "$work_dir/restarts"); fi
    if [[ -f $work_dir/last-attempt ]]; then has_attempt=yes; fi
    if [[ $restart_calls != "$expected_restarts" || $has_attempt != "$expected_attempt" ||
        $status != "$expected_status" ]]; then
        printf 'FAIL %s (status=%s, restarts=%s, attempt=%s)\n%s\n' \
            "$description" "$status" "$restart_calls" "$has_attempt" "$output" >&2
        return 1
    fi
    printf 'PASS %s\n' "$description"
}

unset AVAHI_EXPECTED_HOSTNAME
restart=avahi-daemon.service
run_case 'healthy name clears cooldown' 'Node.example.org' local 'NODE.LOCAL.' node.local '' no 0 10799
run_case 'default name recovers on another hostname' desk local desk-2.local DESK.LOCAL "$restart" no 0
AVAHI_EXPECTED_HOSTNAME=printer TEST_CONFIG=$'[server]\nhost-name=printer' \
    run_case 'explicit label and custom domain' node devices.example. printer-2.devices.example \
        printer.devices.example "$restart" no 0
TEST_CONFIG=$'[server]\n Host-Name = node-2' \
    run_case 'configured host label requires override' node local node-2.local node.local '' no 0
TEST_CONFIG=$'[server]\nhost-name-from-machine-id=Yes' \
    run_case 'machine-ID naming requires override' node local node-2.local node.local '' no 0
TEST_CONFIG=$'[server]\nhost-name-from-machine-id=no' \
    run_case 'disabled machine-ID naming permits the default' desk local desk-2.local desk.local "$restart" no 0
AVAHI_EXPECTED_HOSTNAME='not.a.label' \
    run_case 'malformed override skips recovery' node local node-2.local node.local '' no 0
run_case 'increment an existing numeric suffix' node-2 local node-3.local node-2.local "$restart" no 0
run_case 'leading-zero suffix is part of the stem' node-02 local node-02-2.local node-02.local "$restart" no 0
run_case 'lower suffix is not a fallback' node-4 local node-3.local node-4.local '' no 0
run_case 'different domain skips recovery' desk local desk-2.example desk.local '' no 0
run_case 'unrelated label skips recovery' desk local other-2.local desk.local '' no 0
run_case 'oversize suffix skips recovery' node-99999999999 local node-2.local node.local '' no 0
printf -v long_label '%063d' 0
long_label=${long_label//0/a}
run_case 'first fallback truncates a long stem' "$long_label" local "${long_label:0:61}-2.local" \
    "$long_label.local" "$restart" no 0
run_case 'two-digit fallback truncates a long stem further' "${long_label:0:61}-9" local \
    "${long_label:0:60}-10.local" "${long_label:0:61}-9.local" "$restart" no 0
TEST_STATE=inactive run_case 'inactive Avahi' desk local desk-2.local desk.local '' no 0
TEST_STATE=registering run_case 'Avahi registration in progress' desk local desk-2.local desk.local '' no 0
TEST_STATE=failed-query run_case 'D-Bus state lookup fails' desk local desk-2.local desk.local '' no 0
TEST_STATE=failed-domain run_case 'D-Bus domain lookup fails' desk local desk-2.local desk.local '' no 0
run_case 'persistent conflict stores cooldown' desk local desk-2.local desk-2.local "$restart" yes 0
run_case 'recent attempt defers restart' desk local desk-2.local desk.local '' yes 0 10799
run_case 'expired cooldown permits one restart' desk local desk-2.local desk.local "$restart" no 0 7200
TEST_RESTART=fail run_case 'restart failure preserves cooldown' desk local desk-2.local desk.local "$restart" yes 1

exec_header='a(sasbttttuii) 1'
exec_binary='"/usr/sbin/avahi-daemon"'
exec_status='false 0 0 0 0 0 0 0'
TEST_EXEC_START="$exec_header $exec_binary 1 $exec_binary $exec_status" \
    run_case 'direct Avahi command without options uses default configuration' \
        desk local desk-2.local desk.local "$restart" no 0
TEST_EXEC_START="$exec_header $exec_binary 4 $exec_binary \"-s\" \"-f\" \"/etc/avahi/custom.conf\" $exec_status" \
    run_case 'alternate config with short option skips recovery' \
        desk local desk-2.local desk.local '' no 0
TEST_EXEC_START="$exec_header $exec_binary 2 $exec_binary \"-f/etc/avahi/custom.conf\" $exec_status" \
    run_case 'alternate config with attached short option skips recovery' \
        desk local desk-2.local desk.local '' no 0
TEST_EXEC_START="$exec_header $exec_binary 2 $exec_binary \"--file=/etc/avahi/custom.conf\" $exec_status" \
    run_case 'alternate config with long option skips recovery' \
        desk local desk-2.local desk.local '' no 0
TEST_EXEC_START="$exec_header $exec_binary 3 $exec_binary \"--file\" \"/etc/avahi/custom.conf\" $exec_status" \
    run_case 'alternate config with separate long option skips recovery' \
        desk local desk-2.local desk.local '' no 0
TEST_EXEC_START="$exec_header \"/usr/bin/sh\" 3 \"/usr/bin/sh\" \"-c\" \"avahi-daemon -s\" $exec_status" \
    run_case 'wrapper command skips recovery' desk local desk-2.local desk.local '' no 0
TEST_EXEC_START="$exec_header $exec_binary 2 $exec_binary \"\$AVAHI_OPTS\" $exec_status" \
    run_case 'variable startup arguments skip recovery' desk local desk-2.local desk.local '' no 0
TEST_EXEC_START='' run_case 'malformed startup query skips recovery' desk local desk-2.local desk.local '' no 0
TEST_STATE=failed-execstart run_case 'failed startup query skips recovery' desk local desk-2.local desk.local '' no 0
AVAHI_EXPECTED_HOSTNAME=desk TEST_STATE=failed-execstart \
    run_case 'explicit hostname supports custom or unavailable startup details' \
        kernel-name local desk-2.local desk.local "$restart" no 0

TEST_NOW=10000 run_case 'unresolved first attempt starts cooldown' \
    desk local desk-2.local desk-2.local "$restart" yes 0
TEST_NOW=13599 KEEP_ATTEMPT=yes run_case 'failed attempt still cools down at 3599 seconds' \
    desk local desk-2.local desk.local '' yes 0
TEST_NOW=13600 KEEP_ATTEMPT=yes run_case 'failed attempt may retry at 3600 seconds' \
    desk local desk-2.local desk.local "$restart" no 0
TEST_NOW=10000 run_case 'successful restart clears cooldown' \
    desk local desk-2.local desk.local "$restart" no 0
TEST_NOW=10900 KEEP_ATTEMPT=yes run_case 'next check may retry after confirmed success' \
    desk local desk-2.local desk.local "$restart" no 0
