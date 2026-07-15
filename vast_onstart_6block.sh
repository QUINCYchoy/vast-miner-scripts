#!/bin/bash
set +e

if command -v entrypoint.sh >/dev/null 2>&1; then
  entrypoint.sh &
fi

export DEBIAN_FRONTEND=noninteractive

BASE_DIR="/workspace/miner"
mkdir -p "$BASE_DIR"
chmod -R 777 /workspace || true
chmod -R 777 "$BASE_DIR" || true

LOG_SETUP="$BASE_DIR/miner_setup.log"
SIX_PEARL_LOG="$BASE_DIR/six_pearl_miner.log"
SRB_PEARL_LOG="$BASE_DIR/srb_pearl_miner.log"
PEARL_SUPERVISOR_LOG="$BASE_DIR/pearl_supervisor.log"
PEARL_LOG="$BASE_DIR/pearl_miner.log"
XELIS_LOG="$BASE_DIR/xelis_miner.log"

touch "$LOG_SETUP" "$SIX_PEARL_LOG" "$SRB_PEARL_LOG" "$PEARL_SUPERVISOR_LOG" "$PEARL_LOG" "$XELIS_LOG"
chmod 666 "$LOG_SETUP" "$SIX_PEARL_LOG" "$SRB_PEARL_LOG" "$PEARL_SUPERVISOR_LOG" "$PEARL_LOG" "$XELIS_LOG"

echo "========== Miner setup started: $(date) ==========" >> "$LOG_SETUP"

MACHINE_ID="${VAST_MACHINE_ID:-unknownMachine}"
VAST_OFFER_ID="${VAST_OFFER_ID:-unknownOffer}"
EXPECTED_TOTAL_TH="${EXPECTED_TOTAL_TH:-unknown}"
EXPECTED_TH_PER_GPU="${EXPECTED_TH_PER_GPU:-unknown}"
EXPECTED_GPU_COUNT="${EXPECTED_GPU_COUNT:-unknown}"

echo "VAST_MACHINE_ID: $MACHINE_ID" >> "$LOG_SETUP"
echo "VAST_OFFER_ID: $VAST_OFFER_ID" >> "$LOG_SETUP"
echo "EXPECTED_TOTAL_TH: $EXPECTED_TOTAL_TH" >> "$LOG_SETUP"
echo "EXPECTED_TH_PER_GPU: $EXPECTED_TH_PER_GPU" >> "$LOG_SETUP"
echo "EXPECTED_GPU_COUNT: $EXPECTED_GPU_COUNT" >> "$LOG_SETUP"

apt update >> "$LOG_SETUP" 2>&1
apt install -y wget tar iputils-ping pciutils coreutils sed gawk curl ca-certificates procps psmisc >> "$LOG_SETUP" 2>&1

cd "$BASE_DIR" || exit 1

choose_best_pool() {
  local best_pool=""
  local best_latency="999999"

  for pool in "$@"; do
    echo "Testing ping: $pool" >> "$LOG_SETUP"
    avg_latency=$(ping -c 4 -W 2 "$pool" 2>/dev/null | awk -F'/' '/rtt|round-trip/ {print $5}')

    if [ -z "$avg_latency" ]; then
      echo "$pool ping failed" >> "$LOG_SETUP"
      continue
    fi

    echo "$pool average latency: ${avg_latency} ms" >> "$LOG_SETUP"

    is_better=$(awk -v a="$avg_latency" -v b="$best_latency" 'BEGIN {print (a < b) ? 1 : 0}')

    if [ "$is_better" = "1" ]; then
      best_latency="$avg_latency"
      best_pool="$pool"
    fi
  done

  echo "$best_pool"
}

PEARL_POOLS=(
  "de.pearl.herominers.com"
  "fr.pearl.herominers.com"
  "es.pearl.herominers.com"
  "fi.pearl.herominers.com"
  "ca.pearl.herominers.com"
  "us.pearl.herominers.com"
  "us2.pearl.herominers.com"
  "us3.pearl.herominers.com"
  "br.pearl.herominers.com"
  "hk.pearl.herominers.com"
  "kr.pearl.herominers.com"
  "sg.pearl.herominers.com"
  "tr.pearl.herominers.com"
  "au.pearl.herominers.com"
)

XELIS_POOLS=(
  "de.xelis.herominers.com"
  "fr.xelis.herominers.com"
  "es.xelis.herominers.com"
  "fi.xelis.herominers.com"
  "ca.xelis.herominers.com"
  "us.xelis.herominers.com"
  "us2.xelis.herominers.com"
  "us3.xelis.herominers.com"
  "br.xelis.herominers.com"
  "hk.xelis.herominers.com"
  "kr.xelis.herominers.com"
  "sg.xelis.herominers.com"
  "au.xelis.herominers.com"
)

BEST_PEARL_POOL=$(choose_best_pool "${PEARL_POOLS[@]}")
BEST_XELIS_POOL=$(choose_best_pool "${XELIS_POOLS[@]}")

if [ -z "$BEST_PEARL_POOL" ]; then
  BEST_PEARL_POOL="hk.pearl.herominers.com"
fi

if [ -z "$BEST_XELIS_POOL" ]; then
  BEST_XELIS_POOL="ca.xelis.herominers.com"
fi

echo "Best Pearl pool: $BEST_PEARL_POOL" >> "$LOG_SETUP"
echo "Best Xelis pool: $BEST_XELIS_POOL" >> "$LOG_SETUP"

GPU_COUNT=0
GPU_MODEL="GPU"

if command -v nvidia-smi >/dev/null 2>&1; then
  GPU_COUNT=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | wc -l)
  FIRST_GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -n 1)
  if [ -n "$FIRST_GPU" ]; then
    GPU_MODEL="$FIRST_GPU"
  fi
else
  GPU_COUNT=$(lspci | grep -i "nvidia" | grep -i "vga\|3d" | wc -l)
fi

if [ -z "$GPU_COUNT" ] || [ "$GPU_COUNT" -eq 0 ]; then
  GPU_COUNT=0
fi

SHORT_GPU_MODEL=$(echo "$GPU_MODEL" | sed 's/NVIDIA//Ig' | sed 's/GeForce//Ig' | sed 's/Graphics Device//Ig' | sed 's/[^A-Za-z0-9]//g')

if [ -z "$SHORT_GPU_MODEL" ]; then
  SHORT_GPU_MODEL="GPU"
fi

WORKER_NAME="${GPU_COUNT}x${SHORT_GPU_MODEL}_M${MACHINE_ID}"

if [ "$GPU_COUNT" -eq 0 ]; then
  WORKER_NAME="CPUonly_M${MACHINE_ID}"
fi

echo "GPU count: $GPU_COUNT" >> "$LOG_SETUP"
echo "GPU model: $GPU_MODEL" >> "$LOG_SETUP"
echo "Worker name: $WORKER_NAME" >> "$LOG_SETUP"

SRB_URL="https://github.com/doktor83/SRBMiner-Multi/releases/download/3.4.4/SRBMiner-Multi-3-4-4-Linux.tar.gz"
SRB_ARCHIVE="$BASE_DIR/SRBMiner-Multi-3-4-4-Linux.tar.gz"
SRB_DIR="$BASE_DIR/SRBMiner-Multi-3-4-4"
SRB_BIN="$SRB_DIR/SRBMiner-MULTI"

if [ ! -f "$SRB_BIN" ]; then
  wget -O "$SRB_ARCHIVE" "$SRB_URL" >> "$LOG_SETUP" 2>&1
  tar -xzf "$SRB_ARCHIVE" -C "$BASE_DIR" >> "$LOG_SETUP" 2>&1
fi

if [ -f "$SRB_BIN" ]; then
  chmod +x "$SRB_BIN"
else
  echo "ERROR: SRBMiner missing: $SRB_BIN" >> "$LOG_SETUP"
fi

SIX_URL="https://github.com/6block/pearl-miner/releases/download/v0.1.5/six-pearl-0.1.5.tar.gz"
SIX_ARCHIVE="$BASE_DIR/six-pearl-0.1.5.tar.gz"
SIX_DIR="$BASE_DIR/six-pearl"
SIX_BIN="$SIX_DIR/six-pearl-miner"

if [ ! -f "$SIX_BIN" ]; then
  wget -O "$SIX_ARCHIVE" "$SIX_URL" >> "$LOG_SETUP" 2>&1
  tar -xzf "$SIX_ARCHIVE" -C "$BASE_DIR" >> "$LOG_SETUP" 2>&1
fi

if [ -f "$SIX_BIN" ]; then
  chmod +x "$SIX_BIN"
else
  echo "WARNING: 6block miner missing: $SIX_BIN" >> "$LOG_SETUP"
fi

PEARL_WALLET_BASE="prl1p9e624jsy6rlnlf0ykk7s54f6l2wf8pwfpvlvzysy7nz99drwehuq9wtqgh+mdl1pwplfk0n8u35gupc40lvyhsvuuacfc0t88yacevvk23cg8gmc63wsad52rg"
XELIS_WALLET="z677gw7u6eayct3w34ezg3zzm42sq90txrh5z9hh3ur5puctu4tqzqqyqqtcqsqklpyjv"

cat > "$BASE_DIR/start_six_pearl_miner.sh" << EOF
#!/bin/bash
cd "$BASE_DIR"
while true; do
  echo "Starting 6block Pearl miner at \$(date)"
  "$SIX_BIN" --pool ${BEST_PEARL_POOL}:1200 --wallet ${PEARL_WALLET_BASE}.${WORKER_NAME} --proof-field plain_proof_zst
  echo "6block Pearl stopped at \$(date), restart in 10s"
  sleep 10
done
EOF

cat > "$BASE_DIR/start_srb_pearl_miner.sh" << EOF
#!/bin/bash
cd "$BASE_DIR"
while true; do
  echo "Starting SRBMiner Pearl fallback at \$(date)"
  "$SRB_BIN" --algorithm pearlhash --pool ${BEST_PEARL_POOL}:1200,de.pearl.herominers.com:1200 --wallet ${PEARL_WALLET_BASE} --worker ${WORKER_NAME}
  echo "SRBMiner Pearl stopped at \$(date), restart in 10s"
  sleep 10
done
EOF

cat > "$BASE_DIR/start_xelis_miner.sh" << EOF
#!/bin/bash
cd "$BASE_DIR"
while true; do
  echo "Starting Xelis CPU miner at \$(date)"
  "$SRB_BIN" --algorithm xelishashv3 --pool ${BEST_XELIS_POOL}:1225,de.xelis.herominers.com:1225 --wallet ${XELIS_WALLET} --disable-gpu --worker ${WORKER_NAME}
  echo "Xelis stopped at \$(date), restart in 10s"
  sleep 10
done
EOF

cat > "$BASE_DIR/start_pearl_supervisor.sh" << EOF
#!/bin/bash
cd "$BASE_DIR"

SIX_GRACE_SECONDS=180
SIX_PATTERN='Mining:[[:space:]]*total[[:space:]]*[0-9]+(\\.[0-9]+)?[[:space:]]*[kKmMgGtTpP]?H(/s|s)?'

echo "Pearl supervisor started at \$(date)" >> "$LOG_SETUP"

if [ -f "$SIX_BIN" ]; then
  echo "Starting 6block first" >> "$LOG_SETUP"
  nohup "$BASE_DIR/start_six_pearl_miner.sh" >> "$SIX_PEARL_LOG" 2>&1 &
  SIX_PID=\$!
  sleep "\$SIX_GRACE_SECONDS"

  if grep -E "\$SIX_PATTERN" "$SIX_PEARL_LOG" >/dev/null 2>&1; then
    echo "6block hashrate detected, keeping 6block" >> "$LOG_SETUP"
    wait "\$SIX_PID"
    echo "6block exited, fallback to SRBMiner" >> "$LOG_SETUP"
  else
    echo "No 6block hashrate, fallback to SRBMiner" >> "$LOG_SETUP"
    kill "\$SIX_PID" >/dev/null 2>&1 || true
    pkill -f six-pearl-miner >/dev/null 2>&1 || true
    sleep 5
  fi
else
  echo "6block binary missing, use SRBMiner fallback" >> "$LOG_SETUP"
fi

while true; do
  nohup "$BASE_DIR/start_srb_pearl_miner.sh" >> "$SRB_PEARL_LOG" 2>&1 &
  SRB_PID=\$!
  wait "\$SRB_PID"
  echo "SRBMiner Pearl exited, restart in 10s" >> "$LOG_SETUP"
  sleep 10
done
EOF

chmod +x "$BASE_DIR"/start_*.sh
chmod -R 777 "$BASE_DIR" || true

if [ -f "$SRB_BIN" ]; then
  nohup "$BASE_DIR/start_pearl_supervisor.sh" >> "$PEARL_SUPERVISOR_LOG" 2>&1 &
  nohup "$BASE_DIR/start_xelis_miner.sh" >> "$XELIS_LOG" 2>&1 &
  echo "Pearl supervisor started" >> "$LOG_SETUP"
  echo "Xelis miner started" >> "$LOG_SETUP"
else
  echo "Miners NOT started because SRBMiner missing" >> "$LOG_SETUP"
fi

echo "========== Miner setup finished: $(date) ==========" >> "$LOG_SETUP"
sleep 5
