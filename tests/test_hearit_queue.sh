#!/bin/bash
# Tests for hearit_queue.sh. Uses a fake runner instead of HearItOwnIt.scpt, so
# nothing is downloaded and Music isn't touched.
#   bash tests/test_hearit_queue.sh
set -uo pipefail
here="$(cd "$(dirname "$0")/.." && pwd)"
tmp="$(mktemp -d -t hearitqueuetest)"
trap 'rm -rf "$tmp"' EXIT

export HEARIT_QUEUE_ROOT="$tmp/HearIt"
export HEARIT_STATE_DIR="$tmp/state"
export HEARIT_RECENTS="$tmp/recents"
export HEARIT_QUEUE_LOCK="$tmp/lock"
export HEARIT_QUIET=1
export HEARIT_RUNNER="$tmp/runner"
export HEARIT_FAST_DIR="$tmp/fast"
queue="$HEARIT_QUEUE_ROOT/Queue"
failed="$HEARIT_QUEUE_ROOT/Failed"
calls="$tmp/calls"

# Fake runner: titles starting with "ok" succeed, anything else fails.
cat > "$HEARIT_RUNNER" <<EOF
#!/bin/bash
printf '%s\t%s\n' "\$1" "\$2" >> "$calls"
if [[ "\${1#*|}" == ok* ]]; then echo "DOWNLOADED|/x.m4a"; else echo "Failed"; fi
EOF
chmod +x "$HEARIT_RUNNER"

fails=0
check() {  # check <description> <command...>
  local what="$1"; shift
  if "$@"; then echo "ok   - $what"; else echo "FAIL - $what"; fails=$((fails + 1)); fi
}
reset() { rm -rf "$HEARIT_QUEUE_ROOT" "$HEARIT_STATE_DIR" "$HEARIT_FAST_DIR" "$calls" "$HEARIT_QUEUE_LOCK"; mkdir -p "$queue"; : > "$calls"; }
run() { bash "$here/hearit_queue.sh"; }

# 1) a good song is processed, gets its playlist, and leaves the queue
reset
printf 'Some Artist|ok song|Road Trip\n' > "$queue/1.txt"
run
check "good song leaves the queue" test ! -e "$queue/1.txt"
check "runner gets artist|title and playlist" grep -qx $'Some Artist|ok song\tRoad Trip' "$calls"

# 2) a failing song stays queued, then moves to Failed/ on the 3rd try
reset
printf 'Nobody|bad song|\n' > "$queue/2.txt"
run
check "failed song stays queued after 1 try" test -e "$queue/2.txt"
run; run
check "failed song moves to Failed/ after 3 tries" test -e "$failed/2.txt"
check "…and is gone from the queue" test ! -e "$queue/2.txt"
check "runner was called 3 times" test "$(wc -l < "$calls" | tr -d ' ')" = 3

# 3) a malformed line goes straight to Failed/ without calling the runner
reset
printf 'garbage\n' > "$queue/3.txt"
run
check "malformed file moves to Failed/" test -e "$failed/3.txt"
check "runner not called for malformed file" test ! -s "$calls"

# 4) songs are processed oldest first; a song with no playlist passes ""
reset
printf 'A|ok one|\n' > "$queue/20260101-000001.txt"
printf 'B|ok two|x\n' > "$queue/20260101-000002.txt"
run
check "processed in order" test "$(cut -f1 "$calls" | tr '\n' ',')" = "A|ok one,B|ok two,"
check "empty playlist passed as empty" grep -qx $'A|ok one\t' "$calls"

# 5) the Mac's recent playlists are shared with the phone
reset
printf 'blue\nog\n' > "$HEARIT_RECENTS"
run
check "playlists.txt copied for the iPhone" cmp -s "$HEARIT_RECENTS" "$HEARIT_QUEUE_ROOT/playlists.txt"

# 6) a second copy exits while the first is running
reset
printf 'A|ok one|\n' > "$queue/6.txt"
mkdir "$HEARIT_QUEUE_LOCK" && echo $$ > "$HEARIT_QUEUE_LOCK/pid"
run
check "busy lock: queue left alone" test -e "$queue/6.txt"
# …but a lock left by a crashed run is ignored
echo 999999 > "$HEARIT_QUEUE_LOCK/pid"
run
check "stale lock: queue processed" test ! -e "$queue/6.txt"

# 7) a song that arrives while the queue is running is picked up in the same run
reset
cat > "$tmp/runner2" <<EOF
#!/bin/bash
[[ "\$1" == "A|ok first" ]] && printf 'B|ok late|\n' > "$queue/9.txt"
printf '%s\t%s\n' "\$1" "\$2" >> "$calls"
echo "DOWNLOADED|/x.m4a"
EOF
chmod +x "$tmp/runner2"
printf 'A|ok first|\n' > "$queue/8.txt"
HEARIT_RUNNER="$tmp/runner2" run
check "late arrival processed in the same run" test ! -e "$queue/9.txt"

# 8) a file iCloud hasn't filled in yet (empty) waits instead of failing,
#    and is processed once its contents arrive
reset
: > "$queue/10.txt"
( sleep 1; printf 'A|ok synced|\n' > "$queue/10.txt" ) &
HEARIT_SYNC_WAIT=4 run
wait
check "late-syncing file processed, not failed" test ! -e "$failed/10.txt" -a ! -e "$queue/10.txt"
check "…with its real contents" grep -q 'A|ok synced' "$calls"
# …but one that stays empty is left queued for next time
reset
: > "$queue/11.txt"
HEARIT_SYNC_WAIT=0 run
check "still-empty file stays queued" test -e "$queue/11.txt"
check "…and isn't moved to Failed/" test ! -e "$failed/11.txt"

# 9) Wi-Fi fast lane: hearit_now.sh drops the song in the fast folder
reset
printf '20260926-101500.txt\nSome Artist|ok fast|Mix\n' | bash "$here/hearit_now.sh" > /dev/null
check "hearit_now writes the fast file" grep -qx 'Some Artist|ok fast|Mix' "$HEARIT_FAST_DIR/20260926-101500.txt"
check "hearit_now rejects a bad name" bash -c "printf '../x.txt\nA|B|\n' | bash '$here/hearit_now.sh' 2> /dev/null; test \$? -eq 2"
# …it's processed before older iCloud songs, and its later iCloud copy is skipped
printf 'Old|ok old|\n' > "$queue/20260926-090000.txt"
run
check "fast song goes first" test "$(head -n 1 "$calls" | cut -f1)" = "Some Artist|ok fast"
check "fast file removed" test ! -e "$HEARIT_FAST_DIR/20260926-101500.txt"
printf 'Some Artist|ok fast|Mix\n' > "$queue/20260926-101500.txt"
run
check "iCloud copy of a Wi-Fi song is deleted" test ! -e "$queue/20260926-101500.txt"
check "…without downloading it twice" test "$(grep -c 'ok fast' "$calls")" = 1
# …also when the iCloud copy is already there during the same run
reset
mkdir -p "$HEARIT_FAST_DIR"
printf 'A|ok both|\n' > "$HEARIT_FAST_DIR/20260926-111111.txt"
printf 'A|ok both|\n' > "$queue/20260926-111111.txt"
run
check "both copies gone after one run" test ! -e "$queue/20260926-111111.txt" -a ! -e "$HEARIT_FAST_DIR/20260926-111111.txt"
check "…downloaded once" test "$(grep -c 'ok both' "$calls")" = 1

# 10) several songs sent quickly over Wi-Fi all download, oldest first
reset
for i in 1 2 3; do
  printf '20260926-12000%s.txt\nA|ok burst %s|\n' "$i" "$i" | bash "$here/hearit_now.sh" > /dev/null
done
run
check "all 3 Wi-Fi songs downloaded" test "$(grep -c 'ok burst' "$calls")" = 3
check "…in the order they were sent" test "$(cut -f1 "$calls" | tr '\n' ',')" = "A|ok burst 1,A|ok burst 2,A|ok burst 3,"
check "…and the fast folder is empty" test -z "$(ls "$HEARIT_FAST_DIR")"
check "lock released at the end" test ! -e "$HEARIT_QUEUE_LOCK"

# 11) songs sent over Wi-Fi while one is downloading are picked up in the same run
reset
cat > "$tmp/runner3" <<EOF
#!/bin/bash
if [[ "\$1" == "A|ok first" ]]; then
  printf '20260926-130002.txt\nB|ok second|\n' | bash "$here/hearit_now.sh" > /dev/null
  printf '20260926-130003.txt\nC|ok third|\n' | bash "$here/hearit_now.sh" > /dev/null
fi
printf '%s\t%s\n' "\$1" "\$2" >> "$calls"
echo "DOWNLOADED|/x.m4a"
EOF
chmod +x "$tmp/runner3"
printf '20260926-130001.txt\nA|ok first|\n' | bash "$here/hearit_now.sh" > /dev/null
HEARIT_RUNNER="$tmp/runner3" run
check "songs sent mid-download all processed" test "$(cut -f1 "$calls" | tr '\n' ',')" = "A|ok first,B|ok second,C|ok third,"

# 12) a run only removes its own lock, never one another run holds
reset
mkdir "$HEARIT_QUEUE_LOCK" && echo $$ > "$HEARIT_QUEUE_LOCK/pid"
run
check "another run's lock is left alone" test "$(cat "$HEARIT_QUEUE_LOCK/pid")" = $$
rm -rf "$HEARIT_QUEUE_LOCK"

echo
if [[ $fails -eq 0 ]]; then echo "All tests passed"; else echo "$fails test(s) failed"; exit 1; fi
