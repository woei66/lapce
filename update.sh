#!/usr/bin/env bash
# =============================================================================
# Lapce update.sh — 將 target/docker/lapce 部署到系統應用程式位置
# =============================================================================
#
# 功能:
#   1. 複製 target/docker/lapce → ~/.local/bin/lapce (使用者安裝, PATH 優先)
#   2. 複製 target/docker/lapce → /usr/local/bin/lapce (系統安裝, 需 sudo)
#   3. 複製 icons/lapce/lapce_logo.svg → ~/.local/share/icons/hicolor/scalable/apps/dev.lapce.lapce.svg
#   4. 複製 extra/linux/dev.lapce.lapce.desktop → ~/.local/share/applications/
#   5. 複製 extra/linux/dev.lapce.lapce.metainfo.xml → ~/.local/share/metainfo/
#   6. 更新 desktop database 與 GTK icon cache
#
# 安裝位置摘要:
#   | 類型           | 路徑                                                        |
#   |----------------|-------------------------------------------------------------|
#   | Binary (user)  | ~/.local/bin/lapce                                          |
#   | Binary (system)| /usr/local/bin/lapce                                        |
#   | Desktop entry  | ~/.local/share/applications/dev.lapce.lapce.desktop         |
#   | Icon           | ~/.local/share/icons/hicolor/scalable/apps/dev.lapce.lapce.svg |
#   | AppStream      | ~/.local/share/metainfo/dev.lapce.lapce.metainfo.xml        |
#   | Config         | ~/.config/lapce-nightly                                     |
#   | Data           | ~/.local/share/lapce-nightly                                |
#
# 用法: ./update.sh [--system] [--from PATH]
#       ./update.sh --uninstall [--system] [--purge]
#   --system         安裝/移除時一併處理 /usr/local/bin/lapce (需要 sudo)
#   --from PATH      使用指定的執行檔, 而非 target/docker/lapce
#   --uninstall, -u  解除安裝 (移除 binary, icon, desktop entry, AppStream)
#   --purge          搭配 --uninstall, 一併移除設定與資料目錄
# =============================================================================

set -euo pipefail

# ── 色彩 ────────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

info()  { printf "  ${CYAN}[INFO]${NC}  %s\n" "$*"; }
ok()    { printf "  ${GREEN}[OK]${NC}    %s\n" "$*"; }
warn()  { printf "  ${YELLOW}[WARN]${NC}  %s\n" "$*"; }
err()   { printf "  ${RED}[ERR]${NC}   %s\n" "$*"; }

# ── 路徑定義 ────────────────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
# 顯示用路徑: 確保印出的指令可直接執行 (例如以 bash update.sh 執行時補上 ./)
SELF="$0"
case "$SELF" in
    */*) ;;
    *) SELF="./$SELF" ;;
esac
SOURCE_BIN="${SCRIPT_DIR}/target/docker/lapce"
DESKTOP_SOURCE="${SCRIPT_DIR}/extra/linux/dev.lapce.lapce.desktop"
METAINFO_SOURCE="${SCRIPT_DIR}/extra/linux/dev.lapce.lapce.metainfo.xml"
ICON_SOURCE="${SCRIPT_DIR}/icons/lapce/lapce_logo.svg"

USER_BIN="${HOME}/.local/bin/lapce"
SYSTEM_BIN="/usr/local/bin/lapce"
ICON_DEST="${HOME}/.local/share/icons/hicolor/scalable/apps/dev.lapce.lapce.svg"
DESKTOP_DEST="${HOME}/.local/share/applications/dev.lapce.lapce.desktop"
METAINFO_DEST="${HOME}/.local/share/metainfo/dev.lapce.lapce.metainfo.xml"

SYSTEM_INSTALL=false
UNINSTALL=false
PURGE=false

# ── 參數解析 ────────────────────────────────────────────────────────────────
while [ $# -gt 0 ]; do
    case "$1" in
        --system|-s)
            SYSTEM_INSTALL=true
            shift
            ;;
        --uninstall|-u)
            UNINSTALL=true
            shift
            ;;
        --purge)
            PURGE=true
            shift
            ;;
        --from)
            if [ $# -lt 2 ]; then
                err "--from 需要一個路徑參數"
                exit 1
            fi
            SOURCE_BIN="$2"
            shift 2
            ;;
        --help|-h)
            echo "用法: $0 [--system] [--from PATH]"
            echo "      $0 --uninstall [--system] [--purge]"
            echo ""
            echo "將建置好的 Lapce 執行檔部署到系統應用程式位置, 或解除安裝。"
            echo ""
            echo "選項:"
            echo "  --system, -s     安裝/移除時一併處理 /usr/local/bin/lapce (需要 sudo)"
            echo "  --from PATH      使用指定的執行檔 (預設 target/docker/lapce)"
            echo "  --uninstall, -u  解除安裝 (移除 binary, icon, desktop entry, AppStream)"
            echo "  --purge          搭配 --uninstall, 一併移除設定與資料目錄"
            echo "  --help, -h       顯示此說明"
            exit 0
            ;;
        *)
            err "未知參數: $1"
            exit 1
            ;;
    esac
done

if $PURGE && ! $UNINSTALL; then
    err "--purge 需與 --uninstall 搭配使用"
    exit 1
fi

# =============================================================================
# 解除安裝模式
# =============================================================================
if $UNINSTALL; then
    echo ""
    echo "================================================"
    echo "  Lapce Uninstall Script"
    echo "================================================"
    echo ""

    REMOVED_ANY=false

    # ── 1. 移除使用者 binary ────────────────────────────────────────────────
    echo "── 步驟 1: 移除使用者 binary ──"
    if [ -e "$USER_BIN" ]; then
        rm -f "$USER_BIN"
        ok "已移除 → $USER_BIN"
        REMOVED_ANY=true
    else
        info "不存在, 略過 → $USER_BIN"
    fi

    # ── 2. 移除系統 binary (optional) ───────────────────────────────────────
    echo ""
    echo "── 步驟 2: 移除系統 binary ──"
    if $SYSTEM_INSTALL; then
        if [ -e "$SYSTEM_BIN" ]; then
            if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
                info "需要 sudo 權限來移除 $SYSTEM_BIN"
                sudo rm -f "$SYSTEM_BIN"
            else
                rm -f "$SYSTEM_BIN"
            fi
            ok "已移除 → $SYSTEM_BIN"
            REMOVED_ANY=true
        else
            info "不存在, 略過 → $SYSTEM_BIN"
        fi
    else
        info "跳過系統移除 (使用 --system 啟用)"
    fi

    # ── 3. 移除 icon ────────────────────────────────────────────────────────
    echo ""
    echo "── 步驟 3: 移除應用程式圖示 ──"
    if [ -e "$ICON_DEST" ]; then
        rm -f "$ICON_DEST"
        ok "已移除 → $ICON_DEST"
        REMOVED_ANY=true
    else
        info "不存在, 略過 → $ICON_DEST"
    fi

    # ── 4. 移除 desktop entry ───────────────────────────────────────────────
    echo ""
    echo "── 步驟 4: 移除 desktop entry ──"
    if [ -e "$DESKTOP_DEST" ]; then
        rm -f "$DESKTOP_DEST"
        ok "已移除 → $DESKTOP_DEST"
        REMOVED_ANY=true
    else
        info "不存在, 略過 → $DESKTOP_DEST"
    fi

    # ── 5. 移除 AppStream metadata ──────────────────────────────────────────
    echo ""
    echo "── 步驟 5: 移除 AppStream metadata ──"
    if [ -e "$METAINFO_DEST" ]; then
        rm -f "$METAINFO_DEST"
        ok "已移除 → $METAINFO_DEST"
        REMOVED_ANY=true
    else
        info "不存在, 略過 → $METAINFO_DEST"
    fi

    # ── 6. 移除設定與資料 (需 --purge) ─────────────────────────────────────
    echo ""
    echo "── 步驟 6: 移除設定與資料 ──"
    if $PURGE; then
        for d in \
            "${HOME}/.config/lapce" \
            "${HOME}/.config/lapce-nightly" \
            "${HOME}/.config/lapce-debug" \
            "${HOME}/.config/lapce-stable" \
            "${HOME}/.local/share/lapce" \
            "${HOME}/.local/share/lapce-nightly" \
            "${HOME}/.local/share/lapce-debug" \
            "${HOME}/.local/share/lapce-stable"
        do
            if [ -e "$d" ]; then
                rm -rf "$d"
                ok "已移除 → $d"
                REMOVED_ANY=true
            fi
        done
    else
        info "保留設定與資料 (使用 --purge 一併移除)"
    fi

    # ── 7. 更新 desktop database 與 icon cache ─────────────────────────────
    echo ""
    echo "── 步驟 7: 更新 desktop database 與 icon cache ──"
    if command -v update-desktop-database >/dev/null 2>&1; then
        update-desktop-database "${HOME}/.local/share/applications/" 2>/dev/null || true
        ok "已執行 update-desktop-database"
    else
        warn "update-desktop-database 未安裝，略過 (sudo apt install desktop-file-utils)"
    fi

    if command -v gtk-update-icon-cache >/dev/null 2>&1; then
        gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor" >/dev/null 2>&1 || true
        ok "已執行 gtk-update-icon-cache"
    else
        warn "gtk-update-icon-cache 未安裝，略過 (sudo apt install libgtk-3-bin)"
    fi

    # ── 完成 ────────────────────────────────────────────────────────────────
    echo ""
    echo "================================================"
    echo "  ✅ Lapce 解除安裝完成"
    echo "================================================"
    echo ""
    if ! $REMOVED_ANY; then
        warn "找不到任何已安裝的檔案, 可能尚未安裝。"
    fi
    if ! $SYSTEM_INSTALL; then
        echo "  注意: 若曾以 --system 安裝, 請加上 --system 再執行一次。"
    fi
    if ! $PURGE; then
        echo "  注意: 設定與資料仍保留在 ~/.config 與 ~/.local/share。"
    fi
    echo ""
    exit 0
fi

# ── 必要檔案檢查 ────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo "  Lapce Update Script"
echo "================================================"
echo ""

if [ ! -f "$SOURCE_BIN" ]; then
    err "找不到 $SOURCE_BIN"
    echo ""
    echo "  請先執行建置 (例如 ./build.sh) 以產生執行檔,"
    echo "  或使用 --from PATH 指定既有執行檔。"
    exit 1
fi

SOURCE_SIZE=$(stat -c%s "$SOURCE_BIN" 2>/dev/null || stat -f%z "$SOURCE_BIN" 2>/dev/null)
info "來源 binary: $SOURCE_BIN ($(numfmt --to=iec 2>/dev/null <<< "$SOURCE_SIZE" || echo "${SOURCE_SIZE} bytes"))"

if [ ! -f "$ICON_SOURCE" ]; then
    warn "找不到 $ICON_SOURCE，將跳過 icon 安裝"
fi

# 由執行檔版本推斷 Lapce 使用的設定/資料目錄後綴 (nightly / debug / stable)。
VERSION_STRING=$("$SOURCE_BIN" --version 2>/dev/null || true)
case "$VERSION_STRING" in
    *Nightly*) FLAVOR="nightly" ;;
    *Debug*)   FLAVOR="debug" ;;
    *Stable*)  FLAVOR="stable" ;;
    *)         FLAVOR="nightly" ;;
esac
CONFIG_DIR="${HOME}/.config/lapce-${FLAVOR}"
DATA_DIR="${HOME}/.local/share/lapce-${FLAVOR}"

# ── 1. 複製到 ~/.local/bin/lapce ───────────────────────────────────────────
echo ""
echo "── 步驟 1: 部署至使用者 binary 目錄 ──"
mkdir -p "${HOME}/.local/bin"

if [ -f "$USER_BIN" ]; then
    info "覆蓋現有 $USER_BIN"
fi

cp "$SOURCE_BIN" "$USER_BIN"
chmod 755 "$USER_BIN"
ok "已複製 → $USER_BIN"

# ── 2. 檢查 PATH 中是否有 lapce ─────────────────────────────────────────────
echo ""
echo "── 步驟 2: 驗證 PATH 優先順序 ──"
RESOLVED=$(command -v lapce 2>/dev/null || true)
if [ "$RESOLVED" = "$USER_BIN" ]; then
    ok "PATH 已指向 $USER_BIN"
elif [ -n "$RESOLVED" ]; then
    warn "PATH 目前指向 $RESOLVED (預期 $USER_BIN)"
    echo ""
    echo "  請確認 ~/.local/bin 在你的 PATH 最前面:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
else
    warn "lapce 不在 PATH 中"
    echo ""
    echo "  請確認 ~/.local/bin 在你的 PATH 中:"
    echo "    export PATH=\"\$HOME/.local/bin:\$PATH\""
fi

# ── 3. 複製到 /usr/local/bin/lapce (optional) ──────────────────────────────
echo ""
echo "── 步驟 3: 部署至系統 binary 目錄 ──"
if $SYSTEM_INSTALL; then
    if [ "$(id -u)" -ne 0 ] && ! sudo -n true 2>/dev/null; then
        info "需要 sudo 權限來寫入 $SYSTEM_BIN"
        sudo cp "$SOURCE_BIN" "$SYSTEM_BIN"
        sudo chmod 755 "$SYSTEM_BIN"
    else
        cp "$SOURCE_BIN" "$SYSTEM_BIN"
        chmod 755 "$SYSTEM_BIN"
    fi
    ok "已複製 → $SYSTEM_BIN"
else
    info "跳過系統安裝 (使用 --system 啟用)"
fi

# ── 4. 複製 icon ────────────────────────────────────────────────────────────
echo ""
echo "── 步驟 4: 部署應用程式圖示 ──"
if [ -f "$ICON_SOURCE" ]; then
    mkdir -p "$(dirname "$ICON_DEST")"
    cp "$ICON_SOURCE" "$ICON_DEST"
    ok "已複製 → $ICON_DEST"
else
    warn "略過 icon (來源檔案不存在)"
fi

# ── 5. 部署 desktop entry ──────────────────────────────────────────────────
echo ""
echo "── 步驟 5: 部署 desktop entry ──"
mkdir -p "$(dirname "$DESKTOP_DEST")"

if [ -f "$DESKTOP_SOURCE" ]; then
    cp "$DESKTOP_SOURCE" "$DESKTOP_DEST"
    ok "已複製 → $DESKTOP_DEST"
else
    # 後備內容與 extra/linux/dev.lapce.lapce.desktop 一致
    info "找不到 $DESKTOP_SOURCE，寫入預設內容"
    cat > "$DESKTOP_DEST" << 'DESKTOPEOF'
[Desktop Entry]
Version=1.0
Type=Application

Name=Lapce
Comment=Lightning-fast and powerful code editor written in Rust
Categories=Development;IDE;
GenericName=Code Editor
StartupWMClass=lapce

Icon=dev.lapce.lapce
Exec=lapce %F
Terminal=false
MimeType=text/plain;inode/directory;
Actions=new-window;

[Desktop Action new-window]
Name=New Window
Exec=lapce --new %F
Icon=dev.lapce.lapce
DESKTOPEOF
    ok "已建立 → $DESKTOP_DEST"
fi

# ── 6. 部署 AppStream metadata ─────────────────────────────────────────────
echo ""
echo "── 步驟 6: 部署 AppStream metadata ──"
if [ -f "$METAINFO_SOURCE" ]; then
    mkdir -p "$(dirname "$METAINFO_DEST")"
    cp "$METAINFO_SOURCE" "$METAINFO_DEST"
    ok "已複製 → $METAINFO_DEST"
else
    warn "略過 metainfo (來源檔案不存在)"
fi

# ── 7. 更新 desktop database 與 icon cache ─────────────────────────────────
echo ""
echo "── 步驟 7: 更新 desktop database 與 icon cache ──"
if command -v update-desktop-database >/dev/null 2>&1; then
    update-desktop-database "${HOME}/.local/share/applications/" 2>/dev/null || true
    ok "已執行 update-desktop-database"
else
    warn "update-desktop-database 未安裝，略過 (sudo apt install desktop-file-utils)"
fi

if command -v gtk-update-icon-cache >/dev/null 2>&1; then
    gtk-update-icon-cache -f -t "${HOME}/.local/share/icons/hicolor" >/dev/null 2>&1 || true
    ok "已執行 gtk-update-icon-cache"
else
    warn "gtk-update-icon-cache 未安裝，略過 (sudo apt install libgtk-3-bin)"
fi

# ── 8. 確保 config 目錄存在 ────────────────────────────────────────────────
echo ""
echo "── 步驟 8: 確保 config 目錄 ──"
if [ -d "$CONFIG_DIR" ]; then
    ok "已存在 → $CONFIG_DIR"
else
    mkdir -p "$CONFIG_DIR"
    ok "已建立 → $CONFIG_DIR"
fi

# ── 完成 ────────────────────────────────────────────────────────────────────
echo ""
echo "================================================"
echo "  ✅ Lapce 更新完成"
echo "================================================"
echo ""
echo "  安裝路徑總覽:"
echo "    Binary (user):    $USER_BIN"
if $SYSTEM_INSTALL; then
    echo "    Binary (system):  $SYSTEM_BIN"
fi
echo "    Desktop entry:    $DESKTOP_DEST"
echo "    Icon:             $ICON_DEST"
echo "    AppStream:        $METAINFO_DEST"
echo "    Config:           $CONFIG_DIR"
echo "    Data:             $DATA_DIR"
echo ""
echo "  你可以透過應用程式選單或終端機直接執行 'lapce' 來啟動。"
echo ""
echo "  解除安裝方式:"
echo "    $SELF --uninstall            # 移除程式檔案, 保留設定與資料"
echo "    $SELF --uninstall --purge    # 一併移除設定與資料"
if $SYSTEM_INSTALL; then
    echo "    $SELF --uninstall --system   # 已安裝系統版本, 需加上 --system 一併移除"
else
    echo "    (若曾以 --system 安裝, 解除安裝時請再加上 --system)"
fi
echo ""
