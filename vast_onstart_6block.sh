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
SRB_PEARL_LOG="$BASE_DIR/srb_pearl_miner.log"
XELIS_LOG="$BASE_DIR/xelis_miner.log"

APT_DONE_FLAG="$BASE_DIR/.apt_done"
SRB_DONE_FLAG="$BASE_DIR/.srb_done"

touch "$LOG_SETUP" "$SRB_PEARL_LOG" "$XELIS_LOG"
chmod 666 "$LOG_SETUP" "$SRB_PEARL_LOG" "$XELIS_LOG"

echo "========== Miner setup started: $(date) ==========" >> "$LOG_SETUP"

MACHINE_ID="${VAST_MACHINE_ID:-unknownMachine}"
VAST_OFFER_ID="${VAST_OFFER_ID:-unknownOffer}"
EXPECTED_TOTAL_TH="${EXPECTED_TOTAL_TH:-unknown}"
EXPECTED_TH_PER_GPU="${EXPECTED_TH_PER_GPU:-unknown}"
EXPECTED_GPU_COUNT="${EXPECTED_GPU_COUNT:-unknown}"
EXPECTED_MIN_RATIO="${EXPECTED_MIN_RATIO:-0.80}"

echo "EXPECTED_MIN_RATIO: $EXPECTED_MIN_RATIO" >> "$LOG_SETUP"
echo "VAST_MACHINE_ID: $MACHINE_ID" >> "$LOG_SETUP"
echo "VAST_OFFER_ID: $VAST_OFFER_ID" >> "$LOG_SETUP"
echo "EXPECTED_TOTAL_TH: $EXPECTED_TOTAL_TH" >> "$LOG_SETUP"
echo "EXPECTED_TH_PER_GPU: $EXPECTED_TH_PER_GPU" >> "$LOG_SETUP"
echo "EXPECTED_GPU_COUNT: $EXPECTED_GPU_COUNT" >> "$LOG_SETUP"

if [ ! -f "$APT_DONE_FLAG" ]; then
  echo "[BOOTSTRAP] First-time apt install starting at $(date)" >> "$LOG_SETUP"
  apt update >> "$LOG_SETUP" 2>&1
  apt install -y wget tar iputils-ping pciutils coreutils sed gawk curl ca-certificates procps psmisc >> "$LOG_SETUP" 2>&1
  touch "$APT_DONE_FLAG"
  echo "[BOOTSTRAP] apt install done at $(date)" >> "$LOG_SETUP"
else
  echo "[BOOTSTRAP] Skip apt install because $APT_DONE_FLAG exists" >> "$LOG_SETUP"
fi

cd "$BASE_DIR" || exit 1

choose_best_pool() {
  local best_pool=""
  local best_latency="999999"

  for pool in "$@"; do
    echo "Testing ping: $pool" >> "$LOG_SETUP"
    avg_latency=$(ping -c 2 -W 2 "$pool" 2>/dev/null | awk -F'/' '/rtt|round-trip/ {print $5}')

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
  "prl.kryptex.network"
  "prl-eu.kryptex.network"
  "prl-us.kryptex.network"
  "prl-br.kryptex.network"
  "prl-sg.kryptex.network"
  "prl-hk.kryptex.network"
  "prl-ru.kryptex.network"
  "prl-ae.kryptex.network"
)

XELIS_POOLS=(
  "xel.kryptex.network"
  "xel-eu.kryptex.network"
  "xel-us.kryptex.network"
  "xel-br.kryptex.network"
  "xel-sg.kryptex.network"
  "xel-hk.kryptex.network"
  "xel-ru.kryptex.network"
  "xel-ae.kryptex.network"
)

BEST_PEARL_POOL=$(choose_best_pool "${PEARL_POOLS[@]}")
BEST_XELIS_POOL=$(choose_best_pool "${XELIS_POOLS[@]}")

if [ -z "$BEST_PEARL_POOL" ]; then
  BEST_PEARL_POOL="prl.kryptex.network"
fi

if [ -z "$BEST_XELIS_POOL" ]; then
  BEST_XELIS_POOL="xel.kryptex.network"
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

if [ -z "$GPU_COUNT" ] || [ "$GPU_COUNT" -eq 0 ] 2>/dev/null; then
  GPU_COUNT=0
fi

SHORT_GPU_MODEL=$(echo "$GPU_MODEL" | sed 's/NVIDIA//Ig' | sed 's/GeForce//Ig' | sed 's/Graphics Device//Ig' | sed 's/[^A-Za-z0-9]//g')
if [ -z "$SHORT_GPU_MODEL" ]; then
  SHORT_GPU_MODEL="GPU"
fi

WORKER_NAME="${GPU_COUNT}x${SHORT_GPU_MODEL}_M${MACHINE_ID}"

if [ "$GPU_COUNT" -eq 0 ] 2>/dev/null; then
  WORKER_NAME="CPUonly_M${MACHINE_ID}"
fi

echo "GPU count: $GPU_COUNT" >> "$LOG_SETUP"
echo "GPU model: $GPU_MODEL" >> "$LOG_SETUP"
echo "Worker name: $WORKER_NAME" >> "$LOG_SETUP"

SRB_URL="https://github.com/doktor83/SRBMiner-Multi/releases/download/3.8.1/SRBMiner-Multi-3-8-1-Linux.tar.gz"
SRB_ARCHIVE="$BASE_DIR/SRBMiner-Multi-3-8-1-Linux.tar.gz"
SRB_DIR="$BASE_DIR/SRBMiner-Multi-3-8-1"
SRB_BIN="$SRB_DIR/SRBMiner-MULTI"

if [ -f "$SRB_BIN" ]; then
  echo "[DOWNLOAD] Skip SRBMiner download because binary exists: $SRB_BIN" >> "$LOG_SETUP"
else
  echo "[DOWNLOAD] SRBMiner binary missing, downloading..." >> "$LOG_SETUP"
  wget -O "$SRB_ARCHIVE" "$SRB_URL" >> "$LOG_SETUP" 2>&1
  tar -xzf "$SRB_ARCHIVE" -C "$BASE_DIR" >> "$LOG_SETUP" 2>&1
fi

if [ -f "$SRB_BIN" ]; then
  chmod +x "$SRB_BIN"
  touch "$SRB_DONE_FLAG"
else
  echo "ERROR: SRBMiner missing: $SRB_BIN" >> "$LOG_SETUP"
fi

PEARL_WALLET_BASE="krxX8KPKN2"
XELIS_WALLET="krxX8KPKN2"

pkill -f SRBMiner-MULTI >/dev/null 2>&1 || true
pkill -f start_srb_pearl_miner.sh >/dev/null 2>&1 || true
pkill -f start_xelis_miner.sh >/dev/null 2>&1 || true

cat > "$BASE_DIR/start_srb_pearl_miner.sh" << EOF
#!/bin/bash
cd "$BASE_DIR"
while true; do
  echo "Starting SRBMiner Pearl at \$(date)"
  "$SRB_BIN" --algorithm pearlhash --pool ${BEST_PEARL_POOL}:7048,prl-sg.kryptex.network:7048 --wallet ${PEARL_WALLET_BASE}.${WORKER_NAME}
  echo "SRBMiner Pearl stopped at \$(date), restart in 10s"
  sleep 10
done
EOF

cat > "$BASE_DIR/start_xelis_miner.sh" << EOF
#!/bin/bash
cd "$BASE_DIR"
while true; do
  echo "Starting Xelis CPU miner at \$(date)"
  "$SRB_BIN" --algorithm xelishashv3 --pool ${BEST_XELIS_POOL}:7019,xel-sg.kryptex.network:7019 --wallet ${XELIS_WALLET}.${WORKER_NAME} --disable-gpu
  echo "Xelis stopped at \$(date), restart in 10s"
  sleep 10
done
EOF

chmod +x "$BASE_DIR"/start_*.sh
chmod -R 777 "$BASE_DIR" || true

if [ -f "$SRB_BIN" ]; then
  nohup "$BASE_DIR/start_srb_pearl_miner.sh" >> "$SRB_PEARL_LOG" 2>&1 &
  nohup "$BASE_DIR/start_xelis_miner.sh" >> "$XELIS_LOG" 2>&1 &
  echo "SRBMiner Pearl started" >> "$LOG_SETUP"
  echo "Xelis miner started" >> "$LOG_SETUP"
else
  echo "Miners NOT started because SRBMiner missing" >> "$LOG_SETUP"
fi

echo "========== Miner setup finished: $(date) ==========" >> "$LOG_SETUP"
sleep 5
