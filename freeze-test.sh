#!/usr/bin/env bash
# Freeze/unfreeze test: checkpoint a running MongoDB container to disk with
# CRIU (via `docker checkpoint`), measure memory before/while frozen/after,
# then restore it and verify that in-memory state survived.
set -Eeuo pipefail

IMAGE=${IMAGE:-mongo:7}
DATA_MB=${DATA_MB:-300}
C=freeze-mongo
CP=freeze-$C
SUMMARY=${GITHUB_STEP_SUMMARY:-/dev/null}

log() { printf '\n==> %s\n' "$*"; }
now() { date +%s.%N; }
elapsed() { awk -v a="$1" -v b="$2" 'BEGIN { printf "%.2f", b - a }'; }

host_used_mb() { free -m | awk '/^Mem:/ { print $3 }'; }
mongod_rss_mb() { ps -C mongod -o rss= | awk '{ s += $1 } END { printf "%d", s / 1024 }'; }
container_mem() { docker stats --no-stream --format '{{.MemUsage}}' "$C" | cut -d/ -f1 | xargs; }
mongo_eval() { docker exec "$C" mongosh --quiet --eval "$1"; }

wait_for_mongo() {
  for _ in $(seq 1 60); do
    if mongo_eval 'db.runCommand({ ping: 1 }).ok' >/dev/null 2>&1; then return 0; fi
    sleep 1
  done
  echo "mongod did not become ready in 60s" >&2
  return 1
}

on_error() {
  local rc=$? line=$1 cmd=$2
  trap - ERR
  echo "::error::freeze test failed (exit $rc) at line $line: $cmd"
  {
    echo "## Freeze test failed"
    echo
    echo "Exit code $rc at line $line: \`$cmd\`"
  } >>"$SUMMARY"

  log "Diagnostics"
  docker ps -a || true
  docker logs --tail 50 "$C" 2>&1 || true
  sudo find /var/lib/docker /run/containerd /var/lib/containerd \
    \( -name dump.log -o -name restore.log -o -name 'criu-*.log' \) 2>/dev/null |
    while read -r f; do
      echo "--- $f"
      sudo tail -n 60 "$f"
      # Also emit it as an annotation (readable via the public API).
      sudo tail -n 40 "$f" |
        awk -v name="$(basename "$f")" '
          { gsub(/%/, "%25"); gsub(/\r/, "%0D"); out = out $0 "%0A" }
          END { printf "::error title=%s::%s\n", name, out }'
    done || true
  sudo journalctl -u docker -u containerd --since '-15 min' --no-pager | tail -n 80 || true
  exit "$rc"
}
trap 'on_error $LINENO "$BASH_COMMAND"' ERR

docker rm -f "$C" >/dev/null 2>&1 || true

log "Pulling $IMAGE"
docker pull -q "$IMAGE"

baseline_host=$(host_used_mb)

log "Starting $C"
# No published ports: CRIU can't checkpoint established TCP connections,
# and every mongosh call below goes through `docker exec` instead.
docker run -d --name "$C" "$IMAGE" >/dev/null
wait_for_mongo

log "Loading ~${DATA_MB}MB into mongod's cache"
mongo_eval "
  const s = 'x'.repeat(1024);
  const batches = Math.ceil(${DATA_MB} * 1024 / 1000);
  for (let b = 0; b < batches; b++) {
    db.blob.insertMany(Array.from({ length: 1000 }, (_, i) => ({ b, i, s })));
  }
  print('docs:', db.blob.countDocuments());
  print('scanned:', db.blob.find().itcount());
"

# Runtime-only state: a restarted mongod would reset this parameter
# to its default (600000).
mongo_eval 'db.adminCommand({ setParameter: 1, cursorTimeoutMillis: 123456 })' >/dev/null
before_param=$(mongo_eval 'db.adminCommand({ getParameter: 1, cursorTimeoutMillis: 1 }).cursorTimeoutMillis')
before_uptime=$(mongo_eval 'db.serverStatus().uptime')
before_docs=$(mongo_eval 'db.blob.countDocuments()')

sleep 2
running_host=$(host_used_mb)
running_rss=$(mongod_rss_mb)
running_ctr=$(container_mem)

log "Freezing: docker checkpoint create $C $CP"
t0=$(now)
docker checkpoint create "$C" "$CP"
t1=$(now)
freeze_secs=$(elapsed "$t0" "$t1")

sleep 3
frozen_host=$(host_used_mb)
frozen_rss=$(mongod_rss_mb)
cid=$(docker inspect -f '{{.Id}}' "$C")
cp_dir=/var/lib/docker/containers/$cid/checkpoints/$CP
checkpoint_mb=$(sudo du -sm "$cp_dir" 2>/dev/null | cut -f1 || true)
checkpoint_mb=${checkpoint_mb:-?}
docker checkpoint ls "$C"

log "Unfreezing: docker start --checkpoint $CP $C"
t0=$(now)
docker start --checkpoint "$CP" "$C"
wait_for_mongo
t1=$(now)
unfreeze_secs=$(elapsed "$t0" "$t1")
docker checkpoint rm "$C" "$CP"

sleep 2
restored_host=$(host_used_mb)
restored_rss=$(mongod_rss_mb)
restored_ctr=$(container_mem)
after_param=$(mongo_eval 'db.adminCommand({ getParameter: 1, cursorTimeoutMillis: 1 }).cursorTimeoutMillis')
after_uptime=$(mongo_eval 'db.serverStatus().uptime')
after_docs=$(mongo_eval 'db.blob.countDocuments()')

if [[ $after_param == "$before_param" && $after_uptime -ge $before_uptime && $after_docs == "$before_docs" ]]; then
  state="preserved"
else
  state="LOST"
fi

freed=$((running_host - frozen_host))

result=$(
  cat <<EOF
## Freeze test result ($IMAGE, ~${DATA_MB}MB loaded)

| Stage | Host used (MB) | mongod RSS (MB) | Container mem |
|---|---|---|---|
| Baseline (no container) | $baseline_host | - | - |
| Running | $running_host | $running_rss | $running_ctr |
| Frozen | $frozen_host | $frozen_rss | stopped |
| Unfrozen | $restored_host | $restored_rss | $restored_ctr |

- **Memory freed by freeze:** ${freed} MB of host RAM (mongod RSS ${running_rss} MB -> ${frozen_rss} MB)
- **Checkpoint on disk:** ${checkpoint_mb} MB
- **Freeze time:** ${freeze_secs}s, **unfreeze time (until ping):** ${unfreeze_secs}s
- **In-memory state:** ${state} (cursorTimeoutMillis ${before_param} -> ${after_param}, uptime ${before_uptime}s -> ${after_uptime}s, docs ${before_docs} -> ${after_docs})
EOF
)

log "Result"
echo "$result"
echo "$result" >>"$SUMMARY"

[[ $state == preserved ]] || {
  echo "::error::in-memory state was lost after restore"
  exit 1
}
