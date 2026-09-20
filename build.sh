#!/bin/sh
# =============================================================================
# Lapce build.sh — 以 Docker Compose 建置 lapce 執行檔
# =============================================================================
#
# 流程:
#   1. docker compose build lapce-build      建置 builder image
#   2. docker compose run --rm lapce-build   將容器內的 /out/lapce 複製到主機
#   3. 驗證產物並印出版本
#
# 產物:
#   target/docker/lapce
#
# 環境變數 (與 docker-compose.yml 相同, 可用 shell 或 .env 覆寫):
#   CARGO_PROFILE      要編譯的 cargo profile          (預設 release-lto)
#   CARGO_BUILD_JOBS   平行編譯工作數, 控制記憶體用量 (預設 8)
#   BUILDER_IMAGE      builder image 名稱              (預設 lapce-builder:local)
#
# 用法: ./build.sh [--no-cache] [--run]
#   --no-cache  建置時不使用 BuildKit 快取
#   --run       建置完成後啟動 GUI 容器
#               (docker compose --profile run up lapce, 需 X11/Wayland)
#   --help      顯示此說明
# =============================================================================

set -eu

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
OUT_BIN="${SCRIPT_DIR}/target/docker/lapce"

usage() {
    cat <<'EOF'
用法: ./build.sh [--no-cache] [--run]

以 Docker Compose 建置 Lapce, 產物為 target/docker/lapce。

選項:
  --no-cache  建置 builder image 時不使用快取
  --run       建置完成後啟動 GUI 容器 (需要 X11 或 Wayland)
  --help      顯示此說明

環境變數:
  CARGO_PROFILE      預設 release-lto
  CARGO_BUILD_JOBS   預設 8
  BUILDER_IMAGE      預設 lapce-builder:local
EOF
}

NO_CACHE=false
RUN_GUI=false

for arg in "$@"; do
    case "$arg" in
        --no-cache)
            NO_CACHE=true
            ;;
        --run)
            RUN_GUI=true
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            echo "未知參數: $arg" >&2
            usage >&2
            exit 1
            ;;
    esac
done

if ! command -v docker >/dev/null 2>&1; then
    echo "錯誤: 找不到 docker, 請先安裝 Docker 與 Compose v2。" >&2
    exit 1
fi

PROFILE="${CARGO_PROFILE:-release-lto}"
JOBS="${CARGO_BUILD_JOBS:-8}"

cd "$SCRIPT_DIR"

echo "==> 建置 Lapce builder image (profile=${PROFILE}, jobs=${JOBS})..."
if $NO_CACHE; then
    docker compose build --no-cache lapce-build
else
    docker compose build lapce-build
fi

echo ""
echo "==> 從容器取出執行檔到 target/docker/..."
docker compose run --rm lapce-build

if [ ! -f "$OUT_BIN" ]; then
    echo "錯誤: 找不到產物 $OUT_BIN" >&2
    exit 1
fi

echo ""
echo "==> 建置完成: $OUT_BIN"
ls -lh "$OUT_BIN"
"$OUT_BIN" --version || true

if $RUN_GUI; then
    echo ""
    echo "==> 啟動 Lapce GUI 容器..."
    exec docker compose --profile run up lapce
fi
