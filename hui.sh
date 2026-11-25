#!/usr/bin/env bash
# Copyright (C) 2026 hui contributors
# SPDX-License-Identifier: MIT
# shellcheck shell=bash
#
# hui.sh — AOSP / 类原生 ROM 构建加速工具
#
# 不需要手动 source 这个文件：build/envsetup.sh 末尾会扫描 vendorsetup.sh，
# 通过 vendor/hui/vendorsetup.sh 自动把它挂进来。
#
#   cd <源码树>
#   source build/envsetup.sh
#   hui nabu-user           # 编内核 + 编 ROM
#
# 常用：
#   hui status             看当前产品 / 内核缓存 / 建议并行度
#   hui build [目标…]      只跑构建（命中内核快照 + 机器上限并发 + 构建图复用）
#   hui m systemimage      只出镜像，跳过 OTA 打包
#   hui save               手动把当前内核产物存成快照
#   hui doctor             体检：内存 / 并行度 / 缓存 / 构建图
#   hui graph --verify     校验构建图，能复用就直接编（跳过 kati+soong）
#   hui report             上一次构建的耗时分布（siso metrics；Runa 读 .ninja_log）
#
# 设计原则：
#   1. 只碰 .hui/ 和 out/target/product/<dev>/obj/{KERNEL_OBJ,DTB_OBJ,DTBO_OBJ}
#   2. 内核缓存命中与否由「源码 + defconfig + 工具链」的指纹决定，指纹不一致绝不恢复
#   3. 快照用 reflink（btrfs/xfs 上是 O(1) 拷贝），不占实际空间
#   4. 构建失败不写缓存
#
# 兼容性：只用 bash / zsh 都支持的写法——
#   数组只用 arr=(...) / "${arr[@]}" 这种两边都认的形式；不用 ${!var}、[[ ]]、
#   BASH_SOURCE；不依赖单词分割；不用裸 glob
#   （zsh 默认 nomatch：一个不匹配的通配符会直接中断整个函数，这是之前报错的原因）
# 不会 set -e / 改 setopt，不会污染你的 shell。

HUI_VERSION="5.5.6"

# 源码树根，按优先级找：
#   1. HUI_TOP（vendor/hui/vendorsetup.sh 里用 $T 设好）
#   2. ANDROID_BUILD_TOP（lunch 之后才有）
#   3. gettop（envsetup 自带的函数）
#   4. 从当前目录往上找 build/envsetup.sh
# 少了任何一环都不该报"认不出 codename"——那是最难查的错法。
if [ -z "${HUI_TOP:-}" ] && [ -n "${ANDROID_BUILD_TOP:-}" ]; then
    HUI_TOP=$ANDROID_BUILD_TOP
fi
if [ -z "${HUI_TOP:-}" ] && command -v gettop >/dev/null 2>&1; then
    HUI_TOP=$(gettop 2>/dev/null)
fi
if [ -z "${HUI_TOP:-}" ]; then
    _hui_d=$PWD
    while [ -n "$_hui_d" ] && [ "$_hui_d" != "/" ]; do
        if [ -f "$_hui_d/build/envsetup.sh" ]; then
            HUI_TOP=$_hui_d
            break
        fi
        _hui_d=$(dirname "$_hui_d")
    done
    unset _hui_d
fi

# ---------------------------------------------------------------------------
# 基础
# ---------------------------------------------------------------------------

hui__c_red=$(printf '\033[31m'); hui__c_grn=$(printf '\033[32m')
hui__c_yel=$(printf '\033[33m'); hui__c_cyn=$(printf '\033[36m')
hui__c_blu=$(printf '\033[34m')

# ---------------------------------------------------------------------------
# 主题：强调色默认从桌面壁纸提取（HUI_THEME=default 关闭；HUI_WALLPAPER 指定图）
# 取色失败（没壁纸 / 没 magick / 没 python3）时静默回退内置配色。
# ---------------------------------------------------------------------------
hui__theme_wallpaper() {
    local p
    if [ -n "${HUI_WALLPAPER:-}" ] && [ -f "$HUI_WALLPAPER" ]; then
        printf '%s' "$HUI_WALLPAPER"; return 0
    fi
    # KDE Plasma：containment 配置里的 Image=file://...
    p=$(sed -n 's/^Image=file:\/\///p' "$HOME/.config/plasma-org.kde.plasma.desktop-appletsrc" 2>/dev/null |
        while IFS= read -r f; do [ -f "$f" ] && { printf '%s' "$f"; break; }; done)
    [ -n "$p" ] && { printf '%s' "$p"; return 0; }
    # GNOME
    if command -v gsettings >/dev/null 2>&1; then
        p=$(gsettings get org.gnome.desktop.background picture-uri-dark 2>/dev/null)
        [ -n "$p" ] || p=$(gsettings get org.gnome.desktop.background picture-uri 2>/dev/null)
        p=${p#file://}; p=${p//\'/}
        [ -f "$p" ] && { printf '%s' "$p"; return 0; }
    fi
    # Hyprland：hyprpaper 的 preload，或 swww 缓存里的图
    p=$(sed -n 's/^[[:space:]]*preload[[:space:]]*=[[:space:]]*//p' "$HOME/.config/hypr/hyprpaper.conf" 2>/dev/null | head -1)
    [ -n "$p" ] && [ -f "$p" ] && { printf '%s' "$p"; return 0; }
    p=$(ls -1 "$HOME/.cache/swww/"* 2>/dev/null | head -1)
    [ -n "$p" ] && [ -f "$p" ] && { printf '%s' "$p"; return 0; }
    # sway / i3：swaybg -i / feh --bg-*
    p=$(grep -rhoE '(swaybg[^&;]*(-i|--image)[[:space:]]+|feh[^&;]*--bg-[a-z]+[[:space:]]+)([^[:space:]&;]+)' \
          "$HOME/.config/sway/config" "$HOME/.config/i3/config" 2>/dev/null |
        sed -E 's/.*[[:space:]]([^[:space:]]+)$/\1/' | head -1)
    [ -n "$p" ] && [ -f "$p" ] && { printf '%s' "$p"; return 0; }
    return 1
}

hui__theme_init() {
    HUI__THEME_ACCENT=""
    HUI__THEME_ACCENT2=""
    [ "${HUI_THEME:-wallpaper}" = "default" ] && return 0
    [ -n "${HUI_TOP:-}" ] || return 0
    local wp state cache sig accent accent2
    wp=$(hui__theme_wallpaper) || return 0
    [ -f "$wp" ] || return 0
    state="${HUI_STATE:-$HUI_TOP/.hui}"
    cache="$state/theme"
    mkdir -p "$state" 2>/dev/null
    sig=$(stat -c '%Y-%s' "$wp" 2>/dev/null)
    if [ -f "$cache" ] && [ "$(sed -n 's/^sig=//p' "$cache" 2>/dev/null)" = "$sig" ] \
       && [ "$(sed -n 's/^wall=//p' "$cache" 2>/dev/null)" = "$wp" ]; then
        accent=$(sed -n 's/^accent=//p' "$cache" 2>/dev/null)
        accent2=$(sed -n 's/^accent2=//p' "$cache" 2>/dev/null)
    fi
    if [ -z "$accent" ] || [ -z "$accent2" ]; then
        if command -v magick >/dev/null 2>&1 || command -v convert >/dev/null 2>&1; then :; else return 0; fi
        command -v python3 >/dev/null 2>&1 || return 0
        local out hex truec c256 hex2 truec2 c2562
        out=$(HUI__WP="$wp" python3 - <<'PY' 2>/dev/null
import os, shutil, subprocess, colorsys
img = os.environ['HUI__WP']
tool = shutil.which('magick') or shutil.which('convert')
try:
    out = subprocess.run([tool, img, '-resize', '80x80^', '-colors', '8',
                          '-format', '%c', 'histogram:info:-'],
                         capture_output=True, text=True, timeout=20).stdout
except Exception:
    raise SystemExit(1)
cols = []
for line in out.splitlines():
    line = line.strip()
    if '#' not in line:
        continue
    try:
        cnt = int(line.split(':')[0])
    except ValueError:
        continue
    hx = line.split('#')[1].split()[0][:6]
    if len(hx) != 6:
        continue
    cols.append((cnt, hx))
if not cols:
    raise SystemExit(1)

def hsl(h):
    r, g, b = (int(h[i:i + 2], 16) / 255 for i in (0, 2, 4))
    return colorsys.rgb_to_hls(r, g, b)

def score(c):
    cnt, h = c
    _, _, sat = hsl(h)
    return sat + min(cnt, 2000) / 2000 * 0.15

def hue_diff(a, b):
    d = abs(hsl(a)[0] - hsl(b)[0])
    d = min(d, 1 - d)
    return d * 360

_, hx = max(cols, key=score)
cands = [c for c in cols if c[1] != hx and hue_diff(c[1], hx) >= 40]
if not cands:
    cands = [c for c in cols if c[1] != hx] or cols
_, hx2 = max(cands, key=score)

def emit(h):
    hh, lum, sat = hsl(h)
    sat = max(sat, 0.5)
    lum = min(max(lum, 0.62), 0.78)
    r, g, b = colorsys.hls_to_rgb(hh, lum, sat)
    R, G, B = (round(r * 255), round(g * 255), round(b * 255))
    print('#%02X%02X%02X' % (R, G, B))
    print('\x1b[38;2;%d;%d;%dm' % (R, G, B))
    print('\x1b[38;5;%dm' % (16 + 36 * round(R / 51) + 6 * round(G / 51) + round(B / 51)))

emit(hx)
emit(hx2)
PY
)
        [ -n "$out" ] || return 0
        hex=$(printf '%s\n' "$out" | sed -n 1p)
        truec=$(printf '%s\n' "$out" | sed -n 2p)
        c256=$(printf '%s\n' "$out" | sed -n 3p)
        hex2=$(printf '%s\n' "$out" | sed -n 4p)
        truec2=$(printf '%s\n' "$out" | sed -n 5p)
        c2562=$(printf '%s\n' "$out" | sed -n 6p)
        case "${COLORTERM:-}${TERM:-}" in
            *truecolor*|*24bit*) accent=$truec; accent2=$truec2 ;;
            *)                   accent=$c256; accent2=$c2562 ;;
        esac
        [ -n "$accent" ] || return 0
        { echo '# hui theme v2'
          echo "wall=$wp"
          echo "sig=$sig"
          echo "hex=$hex"
          echo "accent=$accent"
          echo "hex2=$hex2"
          echo "accent2=$accent2"
        } >| "$cache.tmp" 2>/dev/null && mv -f -- "$cache.tmp" "$cache" 2>/dev/null
    fi
    [ -n "$accent" ] || return 0
    HUI__THEME_ACCENT=$accent
    hui__c_cyn=$accent
    [ -n "$accent2" ] && HUI__THEME_ACCENT2=$accent2
    return 0
}

hui__theme_init
hui__theme_init
hui__c_dim=$(printf '\033[2m'); hui__c_bld=$(printf '\033[1m'); hui__c_rst=$(printf '\033[0m')

# 取前 N 个字符（不用 ${var:0:N}，dash 不认）
hui__short() { printf '%s' "$1" | cut -c1-${2:-12}; }

# 读同名变量的值（间接展开）。bash 的 ${!var} 在 zsh 里是 bad substitution，
# 会让整个子 shell 直接退出（hui build 曾因此在 zsh 下一行都编不了），所以统一走 eval。
hui__indirect_get() {
    eval "printf '%s' \"\${$1:-}\""
}

hui__say()  { printf '%s[hui]%s %s\n' "$hui__c_cyn" "$hui__c_rst" "$*"; }
hui__ok()   { printf '%s[hui] ✓%s %s\n' "$hui__c_grn" "$hui__c_rst" "$*"; }
hui__warn() { printf '%s[hui] !%s %s\n' "$hui__c_yel" "$hui__c_rst" "$*" >&2; }
hui__err()  { printf '%s[hui] ✗%s %s\n' "$hui__c_red" "$hui__c_rst" "$*" >&2; }
hui__dim()  { printf '%s%s%s\n' "$hui__c_dim" "$*" "$hui__c_rst"; }

hui__human() {
    # bytes -> human
    local b=${1:-0}
    awk -v b="$b" 'BEGIN{
        split("B KiB MiB GiB TiB", u, " ");
        i=1; while (b>=1024 && i<5) { b/=1024; i++ }
        printf (i==1 ? "%d %s" : "%.1f %s"), b, u[i]
    }'
}

hui__mem_gb() {
    awk '/^MemTotal:/{printf "%.0f", $2/1024/1024}' /proc/meminfo 2>/dev/null || echo 0
}

# ---------------------------------------------------------------------------
# 环境探测
# ---------------------------------------------------------------------------

hui__require_env() {
    if [ -z "${ANDROID_BUILD_TOP:-}" ]; then
        hui__err "还没 source build/envsetup.sh。先执行："
        hui__err "    source build/envsetup.sh && lunch <product>-<variant>"
        return 1
    fi
    HUI_TOP=${HUI_TOP:-$ANDROID_BUILD_TOP}
    HUI_STATE=${HUI_STATE:-$HUI_TOP/.hui}
    HUI_MEM_PER_JOB=${HUI_MEM_PER_JOB:-1.2}
    HUI_KEEP=${HUI_KEEP:-1}
    if [ -z "${HUI__HIGHMEM_EXPLICIT:-}" ]; then
        if [ -n "${HUI_HIGHMEM_JOBS:-}" ]; then HUI__HIGHMEM_EXPLICIT=1; else HUI__HIGHMEM_EXPLICIT=0; fi
    fi
    HUI_HIGHMEM_JOBS=${HUI_HIGHMEM_JOBS:-$(hui__highmem_jobs)}
    HUI__PRODUCT=${HUI__PRODUCT:-${TARGET_PRODUCT:-}}
    if [ -z "$HUI__PRODUCT" ]; then
        hui__err "还没 lunch。先 lunch <product>-<variant>，或者直接用："
        hui__err "    hui <codename>-<variant>      例如：hui nabu-user"
        return 1
    fi
    return 0
}

# 同一棵源码树同时只允许一个构建。两个 hui 并跑会互相清内核完成标记、
# 抢内存（31G 机器会直接掉进 swap），面板/日志也会互相覆盖。
hui__build_lock() {
    local f="${HUI_STATE:-$HUI_TOP/.hui}/build.lock"
    command -v flock >/dev/null 2>&1 || return 0
    mkdir -p "${f%/*}" 2>/dev/null
    # 注意：exec 带 2>/dev/null 会把当前 shell 的 stderr 永久改成 /dev/null，
    # 之后所有 hui__warn/hui__err/摘要都看不到。这里用 { } 把静音限制在打开 fd9
    # 这一步，fd9 本身仍然留在当前 shell。
    { exec 9>>"$f"; } 2>/dev/null || return 0
    if ! flock -n 9 2>/dev/null; then
        { exec 9>&-; } 2>/dev/null
        hui__err "已有另一个 hui 构建在跑（锁文件 $f）"
        hui__dim "  同时跑两个构建会互清内核完成标记、抢内存；等前一个结束再试"
        hui__dim "  确认前一个已经退出但锁还在：查一下还有没有 hui/m/ninja/runa 进程"
        return 1
    fi
    HUI__LOCK_HELD=1
    return 0
}

hui__build_unlock() {
    [ "${HUI__LOCK_HELD:-0}" = "1" ] || return 0
    { exec 9>&-; } 2>/dev/null
    HUI__LOCK_HELD=0
}

hui__device() {
    [ -n "${HUI__DEV:-}" ] && { printf '%s' "$HUI__DEV"; return 0; }
    # 1) lunch 设置的 ANDROID_PRODUCT_OUT，最快。
    #    但环境里可能残留上一个产品的值，只有和当前 TARGET_PRODUCT 对得上才采信
    if [ -n "${ANDROID_PRODUCT_OUT:-}" ]; then
        local cand=${ANDROID_PRODUCT_OUT##*/}
        case "$HUI__PRODUCT" in
            *"$cand") HUI__DEV=$cand ;;
        esac
    fi
    # 2) 上次快照 meta 里记的设备名
    local meta="$(hui__cache_root)/latest/meta"
    if [ -z "${HUI__DEV:-}" ] && [ -f "$meta" ]; then
        HUI__DEV=$(sed -n 's/^device=//p' "$meta")
    fi
    # 3) 最后才问 build 系统（会触发 kati）
    if [ -z "${HUI__DEV:-}" ]; then
        HUI__DEV=$(get_build_var TARGET_DEVICE 2>/dev/null)
    fi
    HUI__DEV=${HUI__DEV:-$1}
    printf '%s' "$HUI__DEV"
}

# 产物目录是 out/target/product/<TARGET_DEVICE>，不是产品名（lineage_nabu → nabu）
hui__prodout() {
    local p=$1 dev
    dev=$(hui__device "$p")
    if [ -n "${ANDROID_PRODUCT_OUT:-}" ] && [ "${ANDROID_PRODUCT_OUT##*/}" = "$dev" ]; then
        printf '%s' "$ANDROID_PRODUCT_OUT"
    else
        printf '%s/out/target/product/%s' "$HUI_TOP" "$dev"
    fi
}

# get_build_var 一次 1~2s，加载后缓存在 shell 变量里。
# 特例：构建图还没生成（比如刚删了 out/target/product/<dev>）时，
# get_build_var 会先跑一遍 kati 分析（10 分钟级）。这种情况下优先用上次
# 内核快照 meta 里记的配置，避免为了取几个变量白跑一次分析。
hui__kernel_vars() {
    [ -n "${HUI__KV_LOADED:-}" ] && return 0
    hui__require_env || return 1

    local graph="$HUI_TOP/out/soong/build.$HUI__PRODUCT.ninja"
    local meta; meta="$(hui__cache_root)/latest/meta"

    if [ ! -f "$graph" ] && [ -f "$meta" ] && [ -n "$(sed -n 's/^source=//p' "$meta")" ]; then
        HUI__KS=$(sed -n 's/^source=//p' "$meta")
        HUI__KC=$(sed -n 's/^defconfig=//p' "$meta")
        HUI__KA=$(sed -n 's/^arch=//p' "$meta");   HUI__KA=${HUI__KA:-arm64}
        HUI__KI=$(sed -n 's/^image=//p' "$meta");  HUI__KI=${HUI__KI:-Image.gz}
        HUI__KV=$(sed -n 's/^kernel_version=//p' "$meta")
        HUI__KCE=""; HUI__KEXT=""
        HUI__KV_LOADED=1
        hui__dim "  （构建图未生成，内核配置取自上次快照，省掉一次 kati 分析）" >&2
        return 0
    fi

    if [ "${HUI_NO_KATI:-0}" = "1" ] && [ ! -f "$graph" ]; then
        # TUI 场景：宁可先不显示内核信息，也不要在进界面前卡十分钟
        HUI__KV_LOADED=1
        return 0
    fi

    [ -f "$graph" ] || \
        hui__warn "构建图未生成：取内核变量会触发 kati 分析，可能要好几分钟" >&2

    HUI__KS=$(get_build_var TARGET_KERNEL_SOURCE 2>/dev/null)
    HUI__KC=$(get_build_var TARGET_KERNEL_CONFIG 2>/dev/null)
    HUI__KCE=$(get_build_var TARGET_KERNEL_CONFIG_EXT 2>/dev/null)
    HUI__KA=$(get_build_var TARGET_KERNEL_ARCH 2>/dev/null);   HUI__KA=${HUI__KA:-arm64}
    HUI__KI=$(get_build_var BOARD_KERNEL_IMAGE_NAME 2>/dev/null); HUI__KI=${HUI__KI:-Image.gz}
    HUI__KV=$(get_build_var TARGET_KERNEL_VERSION 2>/dev/null)
    HUI__KEXT=$(get_build_var TARGET_KERNEL_EXT_MODULES 2>/dev/null)
    HUI__KV_LOADED=1
    return 0
}

# 面板配置表要的字段（PLATFORM / BUILD_ID / PATCH / GMS）：
# 前三个优先 out/.../system/build.prop（构建产物，带 PRODUCT_BUILD_PROP_OVERRIDES，最准）；
# 没有就退回 get_build_var —— 刚清过 out/ 或正在构图时 build.prop 还不存在，
# 只读它的话面板会显示三个「?」，看着像坏了。
# 每个 shell 只取一次，缓存在 HUI__PLATFORM / HUI__BUILD_ID / HUI__PATCH / HUI__WITH_GMS。
hui__panel_config() {
    [ -n "${HUI__PANEL_CFG:-}" ] && return 0
    HUI__PANEL_CFG=1
    local bp dev
    dev=${HUI__DEV:-${HUI__PRODUCT##*_}}
    bp="$HUI_TOP/out/target/product/$dev/system/build.prop"
    if [ -r "$bp" ]; then
        HUI__PLATFORM=$(sed -n 's/^ro.build.version.release=//p' "$bp" 2>/dev/null | head -1)
        HUI__BUILD_ID=$(sed -n 's/^ro.build.id=//p' "$bp" 2>/dev/null | head -1)
        HUI__PATCH=$(sed -n 's/^ro.build.version.security_patch=//p' "$bp" 2>/dev/null | head -1)
    fi
    command -v get_build_var >/dev/null 2>&1 || return 0
    [ -n "${HUI__PLATFORM:-}" ] || HUI__PLATFORM=$(get_build_var PLATFORM_VERSION 2>/dev/null)
    [ -n "${HUI__BUILD_ID:-}" ] || HUI__BUILD_ID=$(get_build_var BUILD_ID 2>/dev/null)
    [ -n "${HUI__PATCH:-}" ] || HUI__PATCH=$(get_build_var PLATFORM_SECURITY_PATCH 2>/dev/null)
    [ -n "${HUI__WITH_GMS:-}" ] || HUI__WITH_GMS=$(get_build_var WITH_GMS 2>/dev/null)
    return 0
}

hui__kernel_src_abs() {
    hui__kernel_vars || return 1
    [ -n "$HUI__KS" ] || return 1
    printf '%s/%s' "$HUI_TOP" "${HUI__KS%/}"
}

# ---------------------------------------------------------------------------
# 指纹：内核源码 + defconfig + 工具链 + kernel.mk
# ---------------------------------------------------------------------------

# 生成 manifest：相对路径 \t size \t mtime，按路径排序
hui__manifest() {
    local src=$1 out=$2
    local prune=(-not -path "$src/.git" -not -path "$src/.git/*"
                 -not -path "$src/out" -not -path "$src/out/*")
    find "$src" -type f "${prune[@]}" -printf '%P\t%s\t%T@\n' 2>/dev/null | sort >| "$out"
}

# 说明：用「路径+大小+mtime」而不是内容哈希，是因为 ninja 判新旧本身就看 mtime，
# 而内容哈希在 1.5G 内核源上要十几秒。要更严格可 HUI_DEEP_HASH=1。
hui__fingerprint() {
    hui__kernel_vars || return 1
    local src
    src=$(hui__kernel_src_abs) || return 1
    [ -d "$src" ] || { hui__err "内核源码目录不存在: $src"; return 1; }

    local tc
    tc=$(ls -1 "$HUI_TOP/prebuilts/clang/host/linux-x86" 2>/dev/null |
         grep -E '^clang-r[0-9]+$' | sort -V | tail -1)

    local tmp
    tmp=$(mktemp "${TMPDIR:-/tmp}/hui-fp.XXXXXX") || return 1

    {
        echo "fastbuild-kernel-v1"
        echo "product=$HUI__PRODUCT arch=$HUI__KA image=$HUI__KI kver=$HUI__KV"
        echo "source=$HUI__KS"
        echo "toolchain=$tc"
        # defconfig 片段（相对内核源码）
        # 注意：zsh 默认不对 $var 做单词分割，所以用 tr 拆成行再读
        printf '%s\n%s\n' "$HUI__KC" "$HUI__KCE" | tr ' ' '\n' |
        while IFS= read -r c; do
            [ -n "$c" ] || continue
            f="$src/arch/$HUI__KA/configs/$c"
            [ -f "$f" ] && { printf 'cfg=%s\n' "$c"; sha256sum < "$f"; }
        done
        # 外部模块源码
        printf '%s\n' "$HUI__KEXT" | tr ' ' '\n' |
        while IFS= read -r m; do
            [ -n "$m" ] || continue
            [ -e "$HUI_TOP/$m" ] && printf 'ext:%s\n' "$m"
        done
        # 构建规则本身（不同 ROM 的 kernel.mk 位置不一样，有几个算几个）
        local rulef
        for rulef in "$HUI_TOP/vendor/lineage/build/tasks/kernel.mk" \
                     "$HUI_TOP/build/make/core/tasks/kernel.mk" \
                     "$HUI_TOP/build/kernel/build.sh"; do
            if [ -f "$rulef" ]; then
                echo "rule=${rulef#$HUI_TOP/}"
                sha256sum < "$rulef"
            fi
        done
    } >| "$tmp.key"

    if [ "${HUI_DEEP_HASH:-0}" = "1" ]; then
        find "$src" -type f -not -path "$src/.git/*" -not -path "$src/out/*" -print0 2>/dev/null |
            sort -z | xargs -0 -r sha256sum 2>/dev/null | sort -k2 |
            sha256sum >> "$tmp.key"
    else
        hui__manifest "$src" "$tmp.manifest"
        # 注意：只哈希内容，不能把临时文件名喂进去，否则每次算出来的指纹都不一样
        echo "manifest:" >> "$tmp.key"
        sha256sum < "$tmp.manifest" >> "$tmp.key"
    fi

    local fp
    fp=$(sha256sum "$tmp.key" | cut -d' ' -f1)
    HUI__MANIFEST_TMP=$tmp
    printf '%s' "$fp"
}

# ---------------------------------------------------------------------------
# 快照存取
# ---------------------------------------------------------------------------

hui__cache_root() { printf '%s/%s/kernel' "$HUI_STATE" "$HUI__PRODUCT"; }

hui__cache_latest() {
    local r; r=$(hui__cache_root)
    [ -L "$r/latest" ] && readlink "$r/latest" | sed "s|^$r/||"
}

# ---------------------------------------------------------------------------
# 内核完成标记
# ---------------------------------------------------------------------------
# 「Image 存在」≠「内核编完了」：内核阶段的三个目标（kernel/dtboimage/dtbimage）
# 是分开的，中断可能在 Image 落盘之后、dtbo 之前发生。所以这里用一个只在内核
# 整段 m 返回 0 之后才写的标记文件，开始编之前先删掉——中断过的构建绝不会留下
# 能骗过复检的标记。标记放在 KERNEL_OBJ 里，跟着快照一起复制/恢复。
hui__kdone_file() { printf '%s/obj/KERNEL_OBJ/.hui-kernel-done' "$1"; }

hui__kdone_clear() {
    local kd; kd=$(hui__kdone_file "$1")
    rm -f -- "$kd" "$kd.tmp" 2>/dev/null
    return 0
}

# 记录关键产物的 mtime/大小，复检时逐条核对：产物被改过/删过就不算完成。
# Image/Image.gz-dtb 是内核阶段的主产物，mtime 必须对得上；dtbo.img/dtb.img
# 在 ROM 阶段还会被重新生成（mtime/大小都会变），所以只记存在性——标记存在
# 就说明内核阶段结束时它们已经在了，只要没被删掉就仍然可以复用。
hui__kdone_artifacts() {
    local po=$1 ko="$1/obj/KERNEL_OBJ" f
    for f in \
        "$ko/arch/$HUI__KA/boot/$HUI__KI" \
        "$ko/arch/$HUI__KA/boot/Image.gz-dtb"; do
        [ -f "$f" ] || continue
        stat -c '%Y %s %n' -- "$f" 2>/dev/null
    done
    for f in \
        "$po/obj/DTBO_OBJ/arch/$HUI__KA/boot/dtbo.img" \
        "$po/obj/DTB_OBJ/arch/$HUI__KA/boot/dtb.img"; do
        [ -f "$f" ] || continue
        printf 'exists %s\n' "$f"
    done
}

hui__kdone_write() {
    local po=$1 kd img
    kd=$(hui__kdone_file "$po")
    img="$po/obj/KERNEL_OBJ/arch/$HUI__KA/boot/$HUI__KI"
    [ -f "$img" ] || return 1
    {
        echo "# hui kernel completion stamp v1（中断的构建不会留下它）"
        echo "saved=$(date '+%F %T')"
        echo "product=$HUI__PRODUCT"
        echo "image=$HUI__KI arch=$HUI__KA"
        hui__kdone_artifacts "$po"
    } >| "$kd.tmp" 2>/dev/null || return 1
    mv -f -- "$kd.tmp" "$kd" 2>/dev/null || return 1
    return 0
}

hui__kdone_ok() {
    local kd; kd=$(hui__kdone_file "$1")
    [ -s "$kd" ] || return 1
    local a b c n=0
    while read -r a b c; do
        case "$a" in ''|'#'*) continue ;; esac
        if [ "$a" = "exists" ]; then
            [ -f "$b" ] || return 1
            n=$((n + 1))
            continue
        fi
        case "$a" in ''|*[!0-9]*) continue ;; esac
        [ -f "$c" ] || return 1
        [ "$(stat -c '%Y' -- "$c" 2>/dev/null)" = "$a" ] || return 1
        [ "$(stat -c '%s' -- "$c" 2>/dev/null)" = "$b" ] || return 1
        n=$((n + 1))
    done < "$kd"
    [ "$n" -gt 0 ]
}

hui__kernel_ready() {
    # 完整 = Image 在、.config 在，且有一整段内核 m 成功后留下的完成标记。
    # 不要再拿 Image 和 .config 比 mtime：dtboimage/dtbimage 在 Image 之后跑，
    # Kbuild 每跑一次都会重写 .config，一次完整成功的内核构建里 .config 必然
    # 比 Image 新，用 -nt 判断会把编好的内核全部误判成半成品。
    local po=$1 ko="$1/obj/KERNEL_OBJ"
    local img="$ko/arch/$HUI__KA/boot/$HUI__KI"
    [ -f "$img" ] && [ -f "$ko/.config" ] || return 1
    hui__kdone_ok "$po"
}

# 内核最终产物路径（编完才有）
hui__kernel_image() {
    [ -n "${HUI__KS:-}" ] || return 1
    local po; po=$(hui__prodout "$HUI__PRODUCT")
    printf '%s' "$po/obj/KERNEL_OBJ/arch/$HUI__KA/boot/$HUI__KI"
}

hui__save() {
    HUI__SAVE_STATE=""
    HUI__SAVE_FP=""
    hui__kernel_vars || return 1
    local force=${1:-}
    case "$force" in
        ""|--force) ;;
        *) hui__err "未知参数：$force"
           hui__dim "  用法：hui save [--force]"
           return 1 ;;
    esac
    if [ -z "$HUI__KS" ]; then
        HUI__SAVE_STATE="prebuilt"
        hui__say "该产品用预编译内核（TARGET_KERNEL_SOURCE 为空），无需缓存"
        return 0
    fi

    local po; po=$(hui__prodout "$HUI__PRODUCT")
    local ko="$po/obj/KERNEL_OBJ"
    local img="$ko/arch/$HUI__KA/boot/$HUI__KI"
    if [ ! -f "$img" ]; then
        hui__warn "没有内核产物 $img，跳过保存"
        return 1
    fi
    if [ "$force" = "--force" ]; then
        # 强存 = 用户确认产物确实完整。顺手把完成标记刷新成当前产物，
        # 否则恢复时复检仍会判缺标记/产物已变，快照等于白存。
        hui__kdone_write "$po" || \
            hui__warn "强存：写完成标记失败，恢复时可能仍会被判为不完整"
    fi
    if [ "$force" != "--force" ] && ! hui__kdone_ok "$po"; then
        hui__warn "内核阶段没有完整跑完（缺 .hui-kernel-done），不保存不完整快照"
        hui__dim "  中断过的构建不能当快照用；确认产物确实完整要强存：hui save --force"
        return 1
    fi

    local fp; fp=$(hui__fingerprint) || return 1
    local root; root=$(hui__cache_root)
    local dst="$root/$fp"

    if [ -d "$dst" ] && [ "$force" != "--force" ]; then
        HUI__SAVE_STATE="skip"
        HUI__SAVE_FP=$(hui__short "$fp")
        [ "${HUI__SAVE_QUIET:-0}" = "1" ] || \
            hui__dim "  内核快照已是最新（$(hui__short "$fp")），跳过保存"
        hui__prune_keep "$root" "$dst"
        rm -rf "${HUI__MANIFEST_TMP:-}" 2>/dev/null
        return 0
    fi

    [ "${HUI__SAVE_QUIET:-0}" = "1" ] || hui__say "保存内核快照 $(hui__short "$fp") …"
    rm -rf -- "$dst"
    mkdir -p -- "$dst" || return 1

    local d
    for d in KERNEL_OBJ DTBO_OBJ DTB_OBJ; do
        [ -d "$po/obj/$d" ] || continue
        cp -a --reflink=auto -- "$po/obj/$d" "$dst/$d" || {
            hui__err "拷贝 $d 失败"; return 1; }
    done

    mv -f "${HUI__MANIFEST_TMP:-/dev/null}" "$dst/manifest.txt" 2>/dev/null || :
    {
        echo "fingerprint=$fp"
        echo "saved=$(date '+%F %T')"
        echo "product=$HUI__PRODUCT"
        echo "device=$(hui__device "$HUI__PRODUCT")"
        echo "arch=$HUI__KA"
        echo "kernel_version=$HUI__KV"
        echo "image=$HUI__KI"
        echo "source=$HUI__KS"
        echo "defconfig=$(echo $HUI__KC)"
    } >| "$dst/meta"

    ( cd "$root" && ln -sfn "$fp" latest )
    HUI__SAVE_STATE="saved"
    HUI__SAVE_FP=$(hui__short "$fp")
    hui__prune "$root"
    [ "${HUI__SAVE_QUIET:-0}" = "1" ] || \
        hui__ok "内核快照已保存：$(hui__human "$(du -sb -- "$dst" 2>/dev/null | cut -f1)") 逻辑大小（reflink，实际占用接近 0）"
    return 0
}

# 默认只留最近一份快照（HUI_KEEP=0 可清空，N>1 才保留历史）。
hui__prune() {
    local root=$1 keep=${HUI_KEEP:-1}
    case "$keep" in ''|*[!0-9]*) keep=1 ;; esac
    local list
    list=$(find "$root" -maxdepth 1 -mindepth 1 -type d -printf '%T@ %p\n' 2>/dev/null |
           sort -rn | awk 'NR>'"$keep"' {print $2}')
    [ -n "$list" ] || return 0
    local d
    printf '%s\n' "$list" | while IFS= read -r d; do
        [ -n "$d" ] || continue
        hui__dim "清理旧快照 $(basename "$d")"
        rm -rf -- "$d"
    done
}

# 只留指定快照；HUI_KEEP<=1 时把同产品其它快照全删掉（比按 mtime 留 N 份更准）。
hui__prune_keep() {
    local root=$1 keepdir=$2 keep=${HUI_KEEP:-1} d
    case "$keep" in ''|*[!0-9]*) keep=1 ;; esac
    [ "$keep" -le 1 ] || return 0
    [ -d "$root" ] || return 0
    for d in "$root"/*; do
        [ -e "$d" ] || continue
        [ -L "$d" ] && continue
        [ -d "$d" ] || continue
        [ "$d" = "$keepdir" ] && continue
        hui__dim "清理旧快照 $(basename "$d")"
        rm -rf -- "$d"
    done
    return 0
}

hui__restore() {
    hui__kernel_vars || return 1
    if [ -n "${1:-}" ]; then
        hui__err "未知参数：$1"
        hui__dim "  用法：hui restore（不接受参数）"
        return 1
    fi
    [ -n "$HUI__KS" ] || { hui__dim "预编译内核产品，跳过"; return 0; }

    local po; po=$(hui__prodout "$HUI__PRODUCT")
    local ko="$po/obj/KERNEL_OBJ"

    if hui__kernel_ready "$po"; then
        hui__ok "内核产物已在位，跳过编译"
        return 0
    fi

    local fp; fp=$(hui__fingerprint) || return 1
    local src
    src="$(hui__cache_root)/$fp"
    if [ ! -d "$src/KERNEL_OBJ" ]; then
        hui__warn "内核指纹不一致（$(hui__short "$fp")），需要重新编译"
        hui__explain_miss "$fp"
        hui__purge_stale "$(hui__cache_root)"
        rm -rf "${HUI__MANIFEST_TMP:-}" 2>/dev/null
        return 2
    fi

    hui__say "命中内核缓存 $(hui__short "$fp")，恢复中 …"
    mkdir -p -- "$po/obj" || return 1
    local d
    for d in KERNEL_OBJ DTBO_OBJ DTB_OBJ; do
        [ -d "$src/$d" ] || continue
        rm -rf -- "$po/obj/$d"
        cp -a --reflink=auto -- "$src/$d" "$po/obj/$d" || { hui__err "恢复 $d 失败"; return 1; }
    done
    rm -rf "${HUI__MANIFEST_TMP:-}" 2>/dev/null

    if hui__kernel_ready "$po"; then
        hui__ok "内核已恢复，预计省下 20~30 分钟"
        hui__prune_keep "$(hui__cache_root)" "$src"
        return 0
    fi
    hui__warn "恢复后的内核产物不完整（快照缺完成标记或产物已变），这次会重编内核"
    return 2
}

# 指纹变了，旧快照已经无法复用：直接删掉，别占着磁盘。
hui__purge_stale() {
    local root=$1 d n=0
    [ -d "$root" ] || return 0
    for d in "$root"/*; do
        [ -e "$d" ] || continue
        [ -L "$d" ] && continue
        [ -d "$d" ] || continue
        hui__dim "删除失效快照 $(basename "$d")（指纹不匹配，留着也用不上）"
        rm -rf -- "$d"
        n=$((n + 1))
    done
    rm -f -- "$root/latest" 2>/dev/null
    [ "$n" -gt 0 ] && hui__ok "已清理 $n 份失效内核快照"
    return 0
}

hui__explain_miss() {
    local root; root=$(hui__cache_root)
    local latest; latest=$(hui__cache_latest)
    [ -n "$latest" ] && [ -f "$root/$latest/manifest.txt" ] || {
        hui__dim "  （没有历史快照，这是第一次）"; return 0; }
    local cur="${HUI__MANIFEST_TMP:-}"
    [ -f "$cur" ] || return 0
    local diff
    diff=$(diff --unchanged-line-format='' \
                --old-line-format='- %L' \
                --new-line-format='+ %L' \
                "$root/$latest/manifest.txt" "$cur" 2>/dev/null | head -6)
    if [ -n "$diff" ]; then
        hui__dim "  与上次快照相比，这些文件变了："
        printf '%s\n' "$diff" | sed 's/^/    /' >&2
    else
        hui__dim "  源码清单没变，多半是 defconfig / 工具链 / kernel.mk 变了"
    fi
}

# ---------------------------------------------------------------------------
# 并行度
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 子命令
# ---------------------------------------------------------------------------

# 解析 ccache -s，输出 HUI__CC_HIT(%) / HUI__CC_SIZE / HUI__CC_MAX
hui__ccache_stats() {
    HUI__CC_HIT=""; HUI__CC_SIZE=""; HUI__CC_MAX=""
    command -v ccache >/dev/null 2>&1 || return 1
    local s line
    s=$(ccache -s 2>/dev/null) || return 1
    HUI__CC_HIT=$(printf '%s\n' "$s" | grep -E '^ +Hits:' | head -1 |
                 grep -oE '\([0-9. ]+%\)' | tr -d '()% ')
    line=$(printf '%s\n' "$s" | grep 'Cache size')
    HUI__CC_SIZE=$(printf '%s\n' "$line" | grep -oE '[0-9]+\.?[0-9]*' | sed -n 1p)
    HUI__CC_MAX=$(printf '%s\n' "$line" | grep -oE '[0-9]+\.?[0-9]*' | sed -n 2p)
    [ -n "$HUI__CC_HIT" ]
}

hui__cmd_status() {
    hui__require_env || return 1
    hui__kernel_vars || return 1
    local po; po=$(hui__prodout "$HUI__PRODUCT")
    local nproc mem_gb jobs cap
    nproc=$(nproc); mem_gb=$(hui__mem_gb); jobs=$(hui__jobs_start); cap=$(hui__jobs_max)

    echo
    printf '  源码树      %s\n' "${HUI_TOP:-未设置}"
    printf '  产品        %s\n' "$HUI__PRODUCT"
    printf '  变体        %s\n' "${TARGET_BUILD_VARIANT:-?}"
    printf '  输出目录    %s\n' "$po"
    printf '  机器        %s 核 / %s GiB 内存\n' "$nproc" "$mem_gb"
    local exe; exe=$(hui__executor)
    local rmax=$jobs
    hui__runa_like "$exe" && rmax=$cap
    case "$exe" in
        runa|hui)
            printf '  执行器      %s（运行中可调并发）\n' "$(hui__executor_label "$exe")"
            local exe_bin; exe_bin=$(hui__executor_bin_path "$exe" 2>/dev/null)
            [ -n "$exe_bin" ] && printf '              %s\n' "$exe_bin" ;;
        siso) printf '  执行器      siso（运行中只能降，不能升）\n' ;;
        *)    printf '  执行器      m（原生，无运行中调节）\n' ;;
    esac
    local jlabel="内存准入"
    case "${HUI_MEM_ADMIT:-1}" in 0|off|OFF|false|no) jlabel="准入已关" ;; esac
    printf '  并发        -j%s（%s；硬上限 %s）· 高内存 %s 路 · 运行中 %s~%s · nice %s\n' \
        "$jobs" "$jlabel" "$cap" "${HUI_HIGHMEM_JOBS:-$(hui__highmem_jobs)}" \
        "$(hui__jobs_min)" "$rmax" "${HUI_NICE:-10}"
    if [ -s "$(hui__perf_file)" ]; then
        local last lj lp lm le
        last=$(tail -n 1 "$(hui__perf_file)" 2>/dev/null)
        lj=$(printf '%s' "$last" | cut -f2)
        lp=$(printf '%s' "$last" | cut -f3)
        lm=$(printf '%s' "$last" | cut -f4)
        le=$(printf '%s' "$last" | cut -f5)
        case "$le" in ''|*[!0-9]*) le=0 ;; esac
        printf '  上次构建    -j%s · 内存压力 平均 %s%% / 峰 %s%% · %dh%02dm\n' \
            "${lj:--}" "${lp:--}" "${lm:--}" $(( le / 3600 )) $(( le % 3600 / 60 ))
    fi
    printf '  内存压力    %s\n' "$(hui__pressure_line)"

    # 构建图
    local nj="$HUI_TOP/${OUT_DIR:-out}/soong/build.$HUI__PRODUCT.ninja"
    if [ -f "$nj" ]; then
        printf '  构建图      已就绪 %s（%s；构建时校验后直接复用）\n' \
            "$(hui__human "$(stat -c %s "$nj" 2>/dev/null)")" "$(hui__graph_mtime)"
    else
        printf '  构建图      %s缺失%s → 下次构建要先跑 10~15 分钟分析\n' "$hui__c_yel" "$hui__c_rst"
    fi

    # 内核
    if [ -z "$HUI__KS" ]; then
        printf '  内核        预编译（TARGET_KERNEL_SOURCE 为空）\n'
    else
        printf '  内核源码    %s\n' "$HUI__KS"
        printf '  内核配置    %s\n' "$(echo ${HUI__KC})"
        if hui__kernel_ready "$po"; then
            printf '  内核产物    %s在位（内核阶段完整跑完）%s\n' "$hui__c_grn" "$hui__c_rst"
        else
            local kimg="$po/obj/KERNEL_OBJ/arch/$HUI__KA/boot/$HUI__KI"
            if [ -f "$kimg" ]; then
                printf '  内核产物    %s不完整（上次没编完，缺完成标记；不会当成就绪）%s\n' "$hui__c_yel" "$hui__c_rst"
            else
                printf '  内核产物    %s不在位（需恢复或重编）%s\n' "$hui__c_yel" "$hui__c_rst"
            fi
        fi
        local latest; latest=$(hui__cache_latest 2>/dev/null)
        if [ -n "$latest" ]; then
            printf '  最近快照    %s（%s）\n' "$(hui__short "$latest")" \
                "$(grep -m1 '^saved=' "$(hui__cache_root)/$latest/meta" 2>/dev/null | cut -d= -f2-)"
        else
            printf '  最近快照    无\n'
        fi
    fi

    if [ "${USE_CCACHE:-0}" != "0" ] && hui__ccache_stats; then
        printf '  ccache      命中 %s%%，缓存 %s / %s GB\n' \
            "$HUI__CC_HIT" "$HUI__CC_SIZE" "$HUI__CC_MAX"
    fi

    local avail
    avail=$(df -B1 --output=avail "$HUI_TOP" 2>/dev/null | tail -1)
    printf '  磁盘可用    %s\n\n' "$(hui__human "${avail:-0}")"
}

hui__cmd_doctor() {
    hui__require_env || return 1
    hui__kernel_vars || return 1
    local mem_gb nproc jobs cap
    mem_gb=$(hui__mem_gb); nproc=$(nproc); jobs=$(hui__jobs_start); cap=$(hui__jobs_max)

    echo; hui__say "体检"
    local jlabel="内存准入"
    case "${HUI_MEM_ADMIT:-1}" in 0|off|OFF|false|no) jlabel="准入已关" ;; esac
    hui__ok "并发 -j${jobs}（${jlabel}；硬上限 ${cap}）· 高内存任务 ${HUI_HIGHMEM_JOBS:-$(hui__highmem_jobs)} 路"
    if [ "$jobs" -lt "$cap" ]; then
        hui__dim "  按 ${HUI_MEM_PER_JOB:-1.2}G/进程、预留 ${HUI_MEM_RESERVE_MB:-2048}MB 算：${mem_gb}G 内存这次起步 -j${jobs}；想无视内存满核：HUI_MEM_ADMIT=0 HUI_JOBS=max"
    fi
    hui__dim "  构建进程 nice ${HUI_NICE:-10} / ionice ${HUI_IONICE:-6}：满核时前台和后台不跟着卡（HUI_NICE=0 关）"
    hui__mem_sample
    printf '  当前压力    %s\n' "$(hui__pressure_line)"
    if [ "${HUI__SWAP_TOTAL_MB:-0}" -gt 0 ] && \
       [ "$(( HUI__SWAP_USED_MB * 100 / HUI__SWAP_TOTAL_MB ))" -ge 50 ]; then
        hui__warn "swap 已用 ${HUI__SWAP_USED_MB}MB / ${HUI__SWAP_TOTAL_MB}MB，构建会明显变慢"
    fi

    local swap_used swap_total
    swap_total=$(free -g 2>/dev/null | awk '/Swap:/{print $2}')
    swap_used=$(free -g 2>/dev/null | awk '/Swap:/{print $3}')
    if [ "${swap_used:-0}" -gt 2 ]; then
        hui__warn "swap 已用 ${swap_used}G（共 ${swap_total}G），上次构建大概率在换页"
    fi

    local nj="$HUI_TOP/${OUT_DIR:-out}/soong/build.$HUI__PRODUCT.ninja"
    if [ -f "$nj" ]; then
        hui__ok "构建图在位（$(hui__graph_mtime)）；hui 会在构建前校验，过了就跳过分析"
        hui__dim "  想单独试：hui graph --verify"
    else
        hui__warn "构建图缺失：下次 m 要先重跑 kati+soong 分析，10~15 分钟起步"
    fi

    local avail
    avail=$(df -B1 --output=avail "$HUI_TOP" 2>/dev/null | tail -1)
    if [ "$(awk -v a="${avail:-0}" 'BEGIN{print (a < 20*1024*1024*1024)?1:0}')" = "1" ]; then
        hui__warn "磁盘只剩 $(hui__human "${avail:-0}")，完整构建可能需要 40G+"
    fi

    if [ "${USE_CCACHE:-0}" != "0" ] && hui__ccache_stats; then
        printf '  ccache 命中率 %s%%（%s / %s GB）\n' "$HUI__CC_HIT" "$HUI__CC_SIZE" "$HUI__CC_MAX"
        if awk -v s="$HUI__CC_SIZE" -v m="$HUI__CC_MAX" 'BEGIN{exit !(s > m*0.9)}'; then
            hui__warn "ccache 快满了（${HUI__CC_SIZE}/${HUI__CC_MAX} GB），会频繁淘汰热条目"
            hui__dim  "  扩容：ccache -M $(( ${HUI__CC_MAX%.*} * 2 ))G"
        fi
    fi

    if [ -n "$HUI__KS" ] && ! hui__kernel_ready "$(hui__prodout "$HUI__PRODUCT")"; then
        hui__dim "  内核产物不完整/不在位：hui build 会先试快照恢复，快照没有就重编内核"
    fi
    echo
}

hui__cmd_fingerprint() {
    hui__kernel_vars || return 1
    local t0 t1 fp
    t0=$(date +%s%N)
    fp=$(hui__fingerprint) || return 1
    t1=$(date +%s%N)
    rm -rf "${HUI__MANIFEST_TMP:-}" 2>/dev/null
    printf '%s\n' "$fp"
    hui__dim "  计算耗时 $(( (t1-t0)/1000000 )) ms" >&2
}


# ===========================================================================
# 内存压力模型（含 swap） / 线性闭环调度
# ===========================================================================
#
# 目标：并行度像一条连续的曲线，不是开关，也不许大起大落。
#
#   1. 压力评分 score ∈ [0,100]：可用内存 / PSI / **swap 换入速率** / **swap 占用率**
#      四项线性加权（不用 max，避免单个指标把曲线掰成台阶）
#   2. score ≤ HUI_THROTTLE_AT（默认 35）不降；高过才线性收到下限
#   3. 降一步 HUI_RAMP_STEP（默认 1）；连续 3 秒低于阈值才回升一步
#   4. 执行层用占空比：ratio = target/max，每轮停 siso (1-ratio) 的时间、
#      放行 ratio 的时间，平均并发 ≈ target，不会从 20 一步掉到 6
#   5. 安全阀：score 高且可用内存见底时整段停一小会儿（有次数上限，避免拖超时）

hui__mem_available_mb() { awk '/^MemAvailable:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0; }
hui__mem_total_mb()     { awk '/^MemTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0; }
hui__swap_total_mb()    { awk '/^SwapTotal:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0; }
hui__swap_free_mb()     { awk '/^SwapFree:/{printf "%d", $2/1024}' /proc/meminfo 2>/dev/null || echo 0; }

# /proc/pressure/memory 里 full 行的 avg10（百分比整数）。内核没开 PSI 就返回 0
hui__psi_full10() {
    local v
    v=$(awk '/^full/{for(i=1;i<=NF;i++) if($i ~ /^avg10=/){sub("avg10=","",$i); printf "%d", $i+0.5; exit}}' \
        /proc/pressure/memory 2>/dev/null)
    printf '%s' "${v:-0}"
}

# 采样一次内存，结果放进 HUI__* 全局。
# swap 换入（pswpin）是"真缺页"，比占用率更早、更准地反映系统在抖。
hui__mem_sample() {
    HUI__AVAIL_MB=$(hui__mem_available_mb)
    HUI__SWAP_TOTAL_MB=$(hui__swap_total_mb)
    local sf; sf=$(hui__swap_free_mb)
    HUI__SWAP_USED_MB=$(( HUI__SWAP_TOTAL_MB - sf ))
    [ "$HUI__SWAP_USED_MB" -lt 0 ] && HUI__SWAP_USED_MB=0
    HUI__PSI_FULL=$(hui__psi_full10)

    local pin
    pin=$(awk '/^pswpin /{print $2; exit}' /proc/vmstat 2>/dev/null)
    pin=${pin:-0}
    if [ -n "${HUI__PSWPIN_PREV:-}" ]; then
        local d=$(( pin - HUI__PSWPIN_PREV ))
        [ "$d" -lt 0 ] && d=0
        HUI__SWAPIN_PS=$(( d / ${HUI_TICK:-1} ))
    else
        HUI__SWAPIN_PS=0
    fi
    HUI__PSWPIN_PREV=$pin
}

# 压力评分 0..100，四项线性加权
hui__pressure_score() {
    local avail=${HUI__AVAIL_MB:-0}
    local psi=${HUI__PSI_FULL:-0}
    local swapin=${HUI__SWAPIN_PS:-0}
    local stotal=${HUI__SWAP_TOTAL_MB:-0}
    local sused=${HUI__SWAP_USED_MB:-0}
    local hi=${HUI_AVAIL_HIGH_MB:-8192} lo=${HUI_AVAIL_LOW_MB:-2048}
    local p1 p2 p3 p4=0 s

    # 1) 可用内存：hi 以上 0 分，lo 以下满分
    p1=$(awk -v a="$avail" -v hi="$hi" -v lo="$lo" 'BEGIN{
        if (hi<=lo) { print (a<lo)?100:0; exit }
        v=(hi-a)/(hi-lo); if(v<0)v=0; if(v>1)v=1; printf "%.0f", v*100 }')

    # 2) PSI full avg10：40% 打满
    p2=$(( psi * 100 / 40 )); [ "$p2" -gt 100 ] && p2=100

    # 3) swap 换入：3000 pages/s（约 12MB/s）打满
    p3=$(( swapin * 100 / 3000 )); [ "$p3" -gt 100 ] && p3=100

    # 4) swap 占用率：70% 打满（长期压力的兜底）
    if [ "$stotal" -gt 0 ]; then
        p4=$(( sused * 100 / stotal ))
        [ "$p4" -gt 100 ] && p4=100
        p4=$(( p4 * 100 / 70 )); [ "$p4" -gt 100 ] && p4=100
    fi

    s=$(( (p1*40 + p2*25 + p3*20 + p4*15) / 100 ))
    [ "$s" -gt 100 ] && s=100
    printf '%s' "$s"
}

# 并发上限 = 机器的最大值（nproc）。和 hui__jobs_fast 同一口径：
# HUI_JOBS 可以是数字、max、或空（空=满核），非数字一律按满核算。
# 保留这个名字是因为控制器和面板还在用它。
hui__jobs_max() { hui__jobs_fast; }

# 起步时如果整机已经在疯狂换页，只提醒一句——不减速
hui__mem_headsup() {
    hui__mem_sample
    local stotal=${HUI__SWAP_TOTAL_MB:-0} sused=${HUI__SWAP_USED_MB:-0}
    [ "$stotal" -gt 0 ] || return 0
    [ $(( sused * 100 / stotal )) -ge 80 ] || return 0
    [ "${HUI__AVAIL_MB:-0}" -lt 4096 ] || return 0
    hui__warn "整机内存很紧：可用 ${HUI__AVAIL_MB}MB，swap 已用 ${sused}MB/${stotal}MB"
    hui__dim "  换页比编译慢一个数量级；先关掉吃内存的程序，或调大 HUI_MEM_PER_JOB / 调小 HUI_JOBS"
}

# 并发上限 = 本机核数。上限就是机器能开到的最大值，内存不再压低它。
# 内存只做两件事，都发生在「任务内部」，不影响天花板：
#   1. 高内存任务（链接/打包）单独限流：hui__highmem_jobs
#   2. 运行中压力评分：控制器在 HUI_JOBS_MIN ~ nproc 之间动态收放
# 想手动压到固定值：HUI_JOBS=20；不设 / max 就是满核。
hui__jobs_fast() {
    local n j
    n=$(nproc 2>/dev/null || echo 8)
    case "$n" in ''|*[!0-9]*) n=8 ;; esac
    case "${HUI_JOBS:-}" in
        max|MAX|auto|AUTO|"")
            j=$n ;;
        *[!0-9]*)
            j=$n ;;
        *)
            j=${HUI_JOBS}
            [ "$j" -gt "$n" ] && j=$n
            ;;
    esac
    [ "$j" -lt 1 ] && j=1
    printf '%s' "$j"
}

# 高内存任务（链接/打包）的并发：照 uni 的池公式，每任务 4G、预留 3G，
# 再被全局并发封顶：P = max(1, min(J, floor((A - 3G) / 4G)))
hui__highmem_jobs() {
    local j=${1:-$(hui__jobs_max)} a p
    a=$(hui__mem_available_mb)
    case "$a" in ''|*[!0-9]*) a=8192 ;; esac
    if [ "$a" -le 3072 ]; then printf '1'; return 0; fi
    p=$(( (a - 3072) / 4096 ))
    [ "$p" -lt 1 ] && p=1
    [ "$p" -gt "$j" ] && p=$j
    printf '%s' "$p"
}

# 阶段边界用最新的 MemAvailable 重算池子；用户显式设了就不动
hui__highmem_refresh() {
    [ "${HUI__HIGHMEM_EXPLICIT:-0}" = "1" ] && return 0
    HUI_HIGHMEM_JOBS=$(hui__highmem_jobs "${1:-}")
}

# 内存准入：按「当前可用内存 + 一半空闲 swap − 预留」估计这一刻最多该跑几路。
# 这是实际并发的来源；hui__jobs_max 只是硬上限（核数）。
# 空闲 swap 只算一半：swap 是慢速兜底，全算进来会让起手值过于激进而引发换页；
# 但一点都不算，在 30G 内存 + 60G swap 的机器上又永远到不了满核。
# 预留 HUI_MEM_RESERVE_MB 是留给系统/桌面/回写的余量，别让编译器把内存吃干。
hui__mem_jobs_admit() {
    local n a sw per res frac
    n=$(hui__jobs_max)
    a=$(hui__mem_available_mb)
    case "$a" in ''|*[!0-9]*) a=8192 ;; esac
    sw=$(hui__swap_free_mb)
    case "$sw" in ''|*[!0-9]*) sw=0 ;; esac
    per=${HUI_MEM_PER_JOB:-1.2}
    case "$per" in ''|*[!0-9.]*|*.*.*) per=1.2 ;; esac
    awk -v p="$per" 'BEGIN{exit !(p > 0)}' 2>/dev/null || per=1.2
    res=${HUI_MEM_RESERVE_MB:-2048}
    case "$res" in ''|*[!0-9]*) res=2048 ;; esac
    frac=${HUI_MEM_SWAP_FRACTION:-0.5}
    case "$frac" in ''|*[!0-9.]*|*.*.*) frac=0.5 ;; esac
    awk -v f="$frac" 'BEGIN{exit !(f >= 0 && f <= 1)}' 2>/dev/null || frac=0.5
    awk -v a="$a" -v sw="$sw" -v per="$per" -v res="$res" -v n="$n" -v frac="$frac" 'BEGIN{
        credit = frac * sw
        # swap 折算不能超过当前可用内存：RAM 快满、swap 全空时不该按 swap 起手。
        if (credit > a) credit = a
        v = (a + credit - res) / (per * 1024)
        if (v > n) v = n
        if (v < 1) v = 1
        printf "%d", v
    }'
}

# 把构建进程的 CPU/IO 优先级降下来：满核并发时前台、桌面和后台任务
# 不跟着一起卡。只作用于当前子 shell 及其子进程（siso/make/编译器），
# 交互 shell 本身不受影响；空闲时 nice 不损失吞吐。
# HUI_NICE=0 关掉；HUI_IONICE_CLASS=3 用 idle 级 IO（磁盘很忙时更让路）。
hui__lower_priority() {
    local pid="" nice_v=${HUI_NICE:-10} io_cls=${HUI_IONICE_CLASS:-2} io_lvl=${HUI_IONICE:-6}
    case "$nice_v" in 0|off|OFF|false|no) return 0 ;; esac
    if [ -n "${ZSH_VERSION:-}" ]; then
        zmodload zsh/system 2>/dev/null
        pid=${sysparams[pid]:-}
    elif [ -n "${BASH_VERSION:-}" ]; then
        pid=${BASHPID:-}
    fi
    [ -n "$pid" ] || pid=$$
    if command -v renice >/dev/null 2>&1; then
        renice -n "$nice_v" -p "$pid" >/dev/null 2>&1
    fi
    if command -v ionice >/dev/null 2>&1; then
        ionice -c "$io_cls" -n "$io_lvl" -p "$pid" >/dev/null 2>&1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# 执行器：自建 hui / Runa / siso / m（都是 ninja 兼容）
# ---------------------------------------------------------------------------
# Runa 是随 hui 一起分发的 ninja 兼容执行器，支持 --parallelism-file：
# 运行中改并发只影响「还没启动」的任务，已经在跑的编译器不会被中断。
# siso 没有这个接口（--local_jobs 是启动参数），只能靠占空比停/放。
# 因此有 Runa 时优先用它；已经用 siso 建过的树保持 siso，避免丢增量状态。

hui__runa_bin() {
    local c
    for c in "${HUI_EXECUTOR_BIN:-}" \
             "${HUI_RUNA:-}" \
             "${HUI_HOME:+$HUI_HOME/prebuilts/hui/hui}" \
             "${HUI_TOP:+$HUI_TOP/vendor/hui/prebuilts/hui/hui}" \
             "${HUI_TOP:+$HUI_TOP/hui/prebuilts/hui/hui}" \
             "${HUI_HOME:+$HUI_HOME/prebuilts/runa/runa}" \
             "${HUI_TOP:+$HUI_TOP/vendor/hui/prebuilts/runa/runa}" \
             "${HUI_TOP:+$HUI_TOP/hui/prebuilts/runa/runa}"; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    command -v hui-exec 2>/dev/null || command -v runa 2>/dev/null
}

# 只找 Runa（显式 HUI_EXECUTOR=runa 时用；不能又把 hui 二进制当成 Runa）
hui__runa_only_bin() {
    local c
    for c in "${HUI_EXECUTOR_BIN:-}" \
             "${HUI_RUNA:-}" \
             "${HUI_HOME:+$HUI_HOME/prebuilts/runa/runa}" \
             "${HUI_TOP:+$HUI_TOP/vendor/hui/prebuilts/runa/runa}" \
             "${HUI_TOP:+$HUI_TOP/hui/prebuilts/runa/runa}"; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    command -v runa 2>/dev/null
}

# 自建 hui 执行器（只找 hui，不回退到 runa）
hui__hui_bin() {
    local c
    for c in "${HUI_EXECUTOR_BIN:-}" \
             "${HUI_HOME:+$HUI_HOME/prebuilts/hui/hui}" \
             "${HUI_TOP:+$HUI_TOP/vendor/hui/prebuilts/hui/hui}" \
             "${HUI_TOP:+$HUI_TOP/hui/prebuilts/hui/hui}"; do
        [ -n "$c" ] && [ -x "$c" ] && { printf '%s' "$c"; return 0; }
    done
    return 1
}

# 当前策略下执行器实际用的二进制路径（给 status/启动信息和 label 共用）
hui__executor_bin_path() {
    case "${1:-}" in
        hui)  hui__hui_bin ;;
        runa) hui__runa_only_bin ;;
        *)    return 1 ;;
    esac
}

# 执行器显示串：名称 + 版本 + 短 SHA（只对 hui/runa；找不到就只给名字）
hui__executor_label() {
    local exe=${1:-} bin ver sha name
    case "$exe" in
        hui)  name="自建 hui" ;;
        runa) name="Runa" ;;
        *)    printf '%s' "${exe:-?}"; return 0 ;;
    esac
    bin=$(hui__executor_bin_path "$exe" 2>/dev/null)
    [ -n "$bin" ] || { printf '%s' "$name"; return 0; }
    ver=$("$bin" --version 2>/dev/null | head -n 1)
    sha=$(sha256sum -- "$bin" 2>/dev/null | cut -d' ' -f1 | cut -c1-12)
    printf '%s %s · sha256 %s' "$name" "${ver:-?}" "${sha:-?}"
}

# 自建 hui 与 Runa 同属“ninja 兼容 + --parallelism-file”，下游按同一类处理。
# 不传参数时按当前 hui__executor 判断。
hui__runa_like() {
    case "${1:-$(hui__executor)}" in
        runa|hui) return 0 ;;
        *)        return 1 ;;
    esac
}

hui__runa_ok() {
    local r
    [ "${HUI__RUNA_OK:-}" = "1" ] && return 0
    [ "${HUI__RUNA_OK:-}" = "0" ] && return 1
    case "$(printf '%s' "${HUI_EXECUTOR:-auto}" | tr 'A-Z' 'a-z')" in
        runa|runa-ninja) r=$(hui__runa_only_bin) ;;
        *)               r=$(hui__runa_bin) ;;
    esac
    [ -n "$r" ] || { HUI__RUNA_OK=0; return 1; }
    if "$r" --help 2>&1 | grep -q -- '--parallelism-file'; then
        HUI__RUNA_OK=1
        HUI__RUNA_PATH=$r
        return 0
    fi
    HUI__RUNA_OK=0
    return 1
}

# 三份图齐全 —— 这是 Runa/siso 都能直接吃的合并图原料
hui__graph_files() {
    local out=${OUT_DIR:-out}
    [ -s "$HUI_TOP/$out/soong/build.$HUI__PRODUCT.ninja" ] &&
        [ -s "$HUI_TOP/$out/build-$HUI__PRODUCT.ninja" ] &&
        [ -s "$HUI_TOP/$out/build-$HUI__PRODUCT-package.ninja" ]
}

hui__executor() {
    local forced out
    forced=$(printf '%s' "${HUI_EXECUTOR:-auto}" | tr '[:upper:]' '[:lower:]')
    case "$forced" in
        runa|runa-ninja)
            if [ -n "$(hui__runa_only_bin)" ]; then printf 'runa'; return 0; fi
            hui__warn "HUI_EXECUTOR=runa，但没找到 Runa（prebuilts/runa/runa / HUI_RUNA），回退 auto" >&2
            ;;
        hui|ninja-hui)
            if [ -n "$(hui__hui_bin)" ]; then printf 'hui'; return 0; fi
            hui__warn "HUI_EXECUTOR=hui，但没找到自建执行器（hui/prebuilts/hui/hui），回退 auto" >&2
            ;;
        siso)            printf 'siso'; return 0 ;;
        m|ninja|native)  printf 'm'; return 0 ;;
    esac
    out=${OUT_DIR:-out}
    # 这棵树已经用 siso 建过：换执行器等于丢 siso 的增量/dep 状态，继续 siso
    if [ -f "$HUI_TOP/$out/.siso_deps" ] && [ -x "$HUI_TOP/prebuilts/siso/linux-x86/siso" ]; then
        printf 'siso'; return 0
    fi
    if hui__runa_ok; then
        # 实际选中自建 hui 二进制时也如实标成 hui，别写成 Runa
        if [ -n "$(hui__hui_bin)" ] && [ "$(hui__runa_bin)" = "$(hui__hui_bin)" ]; then
            printf 'hui'
        else
            printf 'runa'
        fi
        return 0
    fi
    if [ -x "$HUI_TOP/prebuilts/siso/linux-x86/siso" ]; then printf 'siso'; return 0; fi
    printf 'm'
}

hui__admit_lib() {
    local f
    for f in "${HUI_HOME:+$HUI_HOME/lib/admit.py}" \
             "${HUI_TOP:+$HUI_TOP/vendor/hui/lib/admit.py}" \
             "${HUI_TOP:+$HUI_TOP/hui/lib/admit.py}"; do
        [ -n "$f" ] && [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

hui__admit_start() {
    local file=$1 initial=$2 ceiling=$3 lib floor policy tick ctrl_log
    command -v python3 >/dev/null 2>&1 || return 0
    lib=$(hui__admit_lib) || return 0
    # pid 用独立的 floor（HUI_CTRL_FLOOR，默认 2）；用户显式设了 HUI_JOBS_MIN
    # 就以它为准。legacy 保留旧行为（可降到 1，不使用这个 floor）。
    if [ -n "${HUI_JOBS_MIN:-}" ]; then
        floor=$HUI_JOBS_MIN
    else
        floor=${HUI_CTRL_FLOOR:-2}
    fi
    case "$floor" in ''|*[!0-9]*) floor=1 ;; esac
    [ "$floor" -lt 1 ] && floor=1
    [ "$floor" -gt "$initial" ] && floor=$initial
    policy=$(printf '%s' "${HUI_ADMIT_POLICY:-pid}" | tr 'A-Z' 'a-z')
    case "$policy" in legacy|pid) ;; *) policy=pid ;; esac
    tick=${HUI_ADMIT_TICK:-1}
    case "$tick" in ''|*[!0-9.]*|*.*.*) tick=1 ;; esac
    awk -v t="$tick" 'BEGIN{exit !(t >= 0.2)}' 2>/dev/null || tick=1
    # 控制器日志必须单独落盘：阶段日志是构建 stdout 的 > 重定向，
    # 和这里的 append 抢文件偏移，写进去会被覆盖（之前 admission 行时有时无就是这原因）。
    ctrl_log="$(hui__state_dir)/ctrl-${HUI__PRODUCT:-build}.log"
    mkdir -p -- "${ctrl_log%/*}" 2>/dev/null
    python3 "$lib" --file "$file" --initial "$initial" --ceiling "$ceiling" \
        --floor "$floor" --policy "$policy" --ctrl-log "$ctrl_log" \
        --parent "$$" --stat "${HUI__STAT_FILE:-}" --log "${HUI__LOG_FILE:-}" \
        --tick "$tick" >/dev/null 2>&1 &
    HUI__ADMIT_PID=$!
    return 0
}

hui__admit_stop() {
    local pid=${HUI__ADMIT_PID:-}
    [ -n "$pid" ] || return 0
    kill "$pid" 2>/dev/null
    wait "$pid" 2>/dev/null
    HUI__ADMIT_PID=""
    return 0
}

# 上次构建的实测数据：日期 并发 平均PSI 峰值PSI 秒数 返回码
hui__perf_file() { printf '%s' "${HUI_STATE:-$HUI_TOP/.hui}/perf.tsv"; }

# 每次构建实际的起手值 = 内存准入值（受硬上限夹住）。
# 控制器只在这个值以下收放；压力低也不越过准入线，避免自己把自己推进 swap。
# HUI_MEM_ADMIT=0 关掉准入，直接按硬上限起步（老行为）。
hui__jobs_start() {
    local cap minj j
    cap=$(hui__jobs_max); minj=$(hui__jobs_min)
    [ "$minj" -gt "$cap" ] && minj=$cap
    case "${HUI_MEM_ADMIT:-1}" in
        0|off|OFF|false|no) j=$cap ;;
        *) j=$(hui__mem_jobs_admit) ;;
    esac
    [ "$j" -gt "$cap" ] && j=$cap
    [ "$j" -lt "$minj" ] && j=$minj
    printf '%s' "$j"
}
# 下限不是死的：HUI_JOBS_MIN 只是“内存够时的下限”。
# 内存真的紧时允许压得更低（2~4 路），否则 6 路一起换页只会更慢。
hui__jobs_min() {
    local floor=${HUI_JOBS_MIN:-6} a per f
    case "$floor" in ''|*[!0-9]*) floor=6 ;; esac
    [ "$floor" -ge 1 ] || floor=1
    a=$(hui__mem_available_mb)
    case "$a" in ''|*[!0-9]*) printf '%s' "$floor"; return 0 ;; esac
    per=${HUI_MEM_PER_JOB:-1.2}
    case "$per" in ''|*[!0-9.]*|*.*.*) per=1.2 ;; esac
    awk -v p="$per" 'BEGIN{exit !(p > 0)}' 2>/dev/null || per=1.2
    f=$(awk -v a="$a" -v per="$per" 'BEGIN{
        v = int(a / (per * 1024 * 2))
        if (v < 1) v = 1
        printf "%d", v
    }')
    [ "$f" -lt "$floor" ] && floor=$f
    printf '%s' "$floor"
}

# 构图（m --skip-ninja / soong bootstrap）不是 1 任务 1 线程的编译负载，
# -j 给太大只会把内存压进 swap（实测 -j32 构图时 PSI 60%+）。
# 默认取核数一半（最少 4，且不超过编译并发），HUI_GRAPH_JOBS 可覆盖。
hui__graph_jobs() {
    local jobs=${1:-} gj n mem_mb mem_cap auto_scale=1
    n=$(nproc 2>/dev/null || echo 8)
    case "$n" in ''|*[!0-9]*) n=8 ;; esac
    case "$(printf '%s' "${HUI_CPU_SCALE:-auto}" | tr 'A-Z' 'a-z')" in
        0|off|false|no|manual) auto_scale=0 ;;
    esac
    gj=${HUI_GRAPH_JOBS:-}
    case "$gj" in ''|*[!0-9]*) gj="" ;; esac
    if [ -z "$gj" ] || [ "$gj" -lt 1 ]; then
        gj=$(( n / 2 ))
        [ "$gj" -lt 4 ] && gj=4
        if [ "$auto_scale" = "1" ]; then
            # 构图也是内存重活：再按总内存的一半封一次顶，并限制在 32 路内。
            mem_mb=$(hui__mem_total_mb 2>/dev/null)
            case "$mem_mb" in ''|*[!0-9]*) mem_mb=0 ;; esac
            if [ "$mem_mb" -gt 0 ]; then
                mem_cap=$(( mem_mb / 2048 ))
                [ "$mem_cap" -lt 4 ] && mem_cap=4
                [ "$gj" -gt "$mem_cap" ] && gj=$mem_cap
            fi
            [ "$gj" -gt 32 ] && gj=32
        fi
    fi
    [ "$gj" -gt "$n" ] && gj=$n
    if [ -n "$jobs" ]; then
        case "$jobs" in ''|*[!0-9]*) : ;; *) [ "$gj" -gt "$jobs" ] && gj=$jobs ;; esac
    fi
    [ "$gj" -lt 1 ] && gj=1
    printf '%s' "$gj"
}

# 每类高内存任务的并发池：池深 = (可用内存 - 预留) / 该类单任务预算。
# 只对支持 HUI_POOL_* 的执行器生效（自建 hui / 将来的执行器）；
# 单个池可用同名环境变量覆盖，HUI_POOLS=0 关闭。
hui__pool_spec() {
    printf '%s' "${HUI_POOL_SPEC:-R8:5120 KOTLIN:5120 JAVA:2048 RUST:2048 LINK:4096}"
}

hui__pools_export() {
    local jobs=$1 avail reserve free_budget kv name budget var depth
    [ "${HUI_POOLS:-1}" = "0" ] && return 0
    [ -n "$jobs" ] || return 0
    avail=$(hui__mem_available_mb)
    reserve=$(( ${HUI_POOL_RESERVE_MB:-3072} ))
    free_budget=$(( avail - reserve ))
    [ "$free_budget" -lt 0 ] && free_budget=0
    for kv in $(hui__pool_spec); do
        name=${kv%%:*}; budget=${kv##*:}
        var="HUI_POOL_${name}_JOBS"
        [ -n "$(hui__indirect_get "$var")" ] && continue   # 已显式指定，不覆盖
        case "$budget" in ''|*[!0-9]*) continue ;; esac    # 预算写错就别除零
        [ "$budget" -le 0 ] && continue
        depth=$(( free_budget / budget ))
        [ "$depth" -lt 1 ] && depth=1
        [ "$depth" -gt "$jobs" ] && depth=$jobs
        export "$var=$depth"
    done
    return 0
}

hui__pools_summary() {
    local out="" name var depth
    [ "${HUI_POOLS:-1}" = "0" ] && return 0
    for name in $(hui__pool_spec | tr ' ' '\n' | cut -d: -f1); do
        var="HUI_POOL_${name}_JOBS"
        depth=$(hui__indirect_get "$var")
        [ -n "$depth" ] && out="$out $(printf '%s' "$name" | tr 'A-Z' 'a-z')=$depth"
    done
    printf '%s' "$out"
}

# 一行压力摘要，给 status/doctor 用
hui__pressure_line() {
    hui__mem_sample
    local score; score=$(hui__pressure_score)
    local maxj minj tgt throttle
    maxj=$(hui__jobs_start); minj=$(hui__jobs_min); throttle=${HUI_THROTTLE_AT:-35}
    [ "$minj" -gt "$maxj" ] && minj=$maxj
    if [ "$score" -le "$throttle" ]; then
        tgt=$maxj
    else
        tgt=$(( maxj - (score - throttle) * (maxj - minj) / (100 - throttle) ))
        [ "$tgt" -lt "$minj" ] && tgt=$minj
    fi
    printf '可用 %sMB / swap %sMB/%sMB / PSI %s%% → 压力 %s%%，目标并发 %s/%s' \
        "$HUI__AVAIL_MB" "$HUI__SWAP_USED_MB" "$HUI__SWAP_TOTAL_MB" \
        "$HUI__PSI_FULL" "$score" "$tgt" "$maxj"
}

# 找出本次构建的 siso 进程：comm=siso，且祖先进程链里有当前 shell。
# bash 里 $$ 在子 shell 中仍是主 shell 的 PID，正好拿来做亲缘判断，
# 这样同时开着两个产品的构建也不会误伤。
hui__find_siso() {
    local p cur up found
    for p in $(pgrep -x siso 2>/dev/null); do
        cur=$p; found=0
        for _ in 1 2 3 4 5 6 7 8; do
            up=$(awk '{print $4}' "/proc/$cur/stat" 2>/dev/null)
            [ -z "$up" ] && break
            [ "$up" = "0" ] && break
            if [ "$up" = "$$" ]; then found=1; break; fi
            [ "$up" = "1" ] && break
            cur=$up
        done
        [ "$found" = "1" ] && printf '%s\n' "$p"
    done
}

_hui_ctrl_signal() {
    hui__find_siso | while IFS= read -r q; do
        [ -n "$q" ] && kill -"$1" "$q" 2>/dev/null
    done
}
_hui_ctrl_stop() { _hui_ctrl_signal STOP; }
_hui_ctrl_cont() { _hui_ctrl_signal CONT; }

# 闭环调度：上限按机器算，运行中只在上限以下按压力来回微调
hui__ctrl_loop() {
    local maxj=${HUI__JOBS_MAX:-$(hui__jobs_start)}
    local minj; minj=$(hui__jobs_min)
    [ "$minj" -gt "$maxj" ] && minj=$maxj
    local step=${HUI_RAMP_STEP:-1}
    local tick=${HUI_TICK:-1}
    local critical=${HUI_CRITICAL:-90}
    local floor_mb=${HUI_FLOOR_MB:-600}
    # 压力低于这个值不降并发；高于它才线性往下收。留 5 分回差防抖。
    local throttle=${HUI_THROTTLE_AT:-35}
    local target raw score calm=0 stop_s cont_s now_s last_crit=0
    target=$maxj
    [ "$target" -gt "$maxj" ] && target=$maxj
    [ "$target" -lt "$minj" ] && target=$minj

    trap '_hui_ctrl_cont; exit 0' INT TERM HUP
    local parent=$PPID

    while :; do
        sleep "$tick"
        # 父 shell 已经退出就自己收摊，别变成孤儿进程
        hui__parent_alive "$parent" || exit 0
        [ "$PPID" = "$parent" ] || exit 0
        hui__mem_sample
        score=$(hui__pressure_score)

        # 没有 siso 进程 = 还在 soong 分析、生成构建图，单线程，没有并发可调。
        # 这时候既不该停（没东西可停），也不该打「暂停调度」这种假动作——
        # 否则看起来就像把图生成卡住了。
        if [ -z "$(hui__find_siso)" ]; then
            target=$maxj
            [ -n "${HUI__STAT_FILE:-}" ] && printf '%s %s\n' "$target" "$score" >| "$HUI__STAT_FILE"
            continue
        fi

        # 压力低于 throttle 不降并发；高过它才线性往下收
        if [ "$score" -le "$throttle" ]; then
            raw=$maxj
            calm=$((calm + 1))
        else
            raw=$(( maxj - (score - throttle) * (maxj - minj) / (100 - throttle) ))
            calm=0
        fi
        [ "$raw" -lt "$minj" ] && raw=$minj
        [ "$raw" -gt "$maxj" ] && raw=$maxj

        # 把当前目标/评分留给状态面板
        # 降要快（直接落到准入/压力算出的目标），升要慢（连续 3 秒低压才回一步）
        if [ "$target" -gt "$raw" ]; then
            target=$raw
            calm=0
        elif [ "$target" -lt "$raw" ]; then
            if [ "$calm" -ge 3 ]; then
                target=$(( target + step )); [ "$target" -gt "$raw" ] && target=$raw
                calm=0
            fi
        else
            calm=0
        fi

        [ "${HUI_CTRL_DEBUG:-0}" = "1" ] && \
            printf '[ctrl] score=%s%% avail=%sMB swap=%sMB target=%s/%s\n' \
                "$score" "${HUI__AVAIL_MB:-?}" "${HUI__SWAP_USED_MB:-?}" "$target" "$maxj" >&2

        # 内存临界：只把「派发目标」压到下限，不暂停构建。
        # 已经在跑的编译器继续跑完并释放内存；siso 只是不再加新任务。
        if { [ "$score" -ge "$critical" ] || [ "${HUI__AVAIL_MB:-0}" -lt "$floor_mb" ]; }; then
            target=$minj
            calm=0
            now_s=$(date +%s)
            if [ $(( now_s - last_crit )) -ge 10 ]; then
                last_crit=$now_s
                printf '%s[hui]%s 内存临界（可用 %sMB / swap %sG / PSI %s%%）→ 派发压到 %s，已跑的继续编完腾内存\n' \
                    "$hui__c_yel" "$hui__c_rst" "$HUI__AVAIL_MB" \
                    "$(awk -v m="${HUI__SWAP_USED_MB:-0}" 'BEGIN{printf "%.1f", m/1024}')" \
                    "${HUI__PSI_FULL:-0}" "$minj" >&2
            fi
        fi

        # 把当前目标/评分留给状态面板
        [ -n "${HUI__STAT_FILE:-}" ] && printf '%s %s\n' "$target" "$score" >| "$HUI__STAT_FILE"

        # 占空比调速：ratio = target/max，平均并发贴着 target 走
        if [ "$target" -ge "$maxj" ]; then
            _hui_ctrl_cont
            continue
        fi
        stop_s=$(awk -v t="$target" -v m="$maxj" -v k="$tick" 'BEGIN{ v=k*(1-t/m); if(v<0.05)v=0.05; printf "%.2f", v }')
        cont_s=$(awk -v t="$target" -v m="$maxj" -v k="$tick" 'BEGIN{ printf "%.2f", k*t/m }')
        _hui_ctrl_stop
        sleep "$stop_s"
        _hui_ctrl_cont
        sleep "$cont_s"
    done
}

hui__ctrl_start() {
    # 默认开：实际并发是内存准入值，运行中压力高就少派发一点。
    # 想固定并发不调速：HUI_WATCHDOG=0
    case "${HUI_WATCHDOG:-1}" in
        0|off|OFF|false|no) return 0 ;;
    esac
    [ -r /proc/pressure/memory ] || return 0
    if [ -n "${HUI__LOG_FILE:-}" ]; then
        hui__ctrl_loop 2>> "$HUI__LOG_FILE" &
    else
        hui__ctrl_loop &
    fi
    HUI__CTRL_PID=$!
    return 0
}

hui__ctrl_stop() {
    [ -n "${HUI__CTRL_PID:-}" ] || return 0
    kill -TERM "$HUI__CTRL_PID" 2>/dev/null
    wait "$HUI__CTRL_PID" 2>/dev/null
    HUI__CTRL_PID=""
}


# ---------------------------------------------------------------------------
# 全屏面板：旋转 90° 的 T 字，随终端尺寸自适应
#
#   ┌──────────┬──────────────────────────────┐
#   │ 编译机器  │ 编译目标（含进度）             │
#   │ htop 条   ├──────────────────────────────┤
#   │           │ 编译日志                      │
#   │  整根到底  ├──────────────────────────────┤
#   │           │     0:45 compile foo.a        │  ← 只在右下：最近完成的动作 + 耗时
#   │           │     1:15 link libx.so         │     （高度 行数/3，4~10 行）
#   ├───────────┴──────────────────────────────┤
#   │ [ 45% 1234/5678] CC bar.o                │  ← 进度行永远压最后一排
#   └──────────────────────────────────────────┘
# ---------------------------------------------------------------------------

# 字节截断：面板里参与对齐的文本一律是 ASCII，所以按字节切最稳
hui__cut() {
    local n=$1 s=$2
    if [ "${#s}" -le "$n" ] || [ "$n" -lt 1 ]; then
        printf '%s' "$s"
    elif [ "$n" -eq 1 ]; then
        printf '…'
    else
        printf '%s…' "$(printf '%s' "$s" | cut -c1-$(( n - 1 )))"
    fi
}

# 帧缓冲：一行一条记录「行号<TAB>该行的转义序列」，画完再只重发变化的行
_hui_row() {
    local r=$1; shift
    printf '%s\t' "$r" >&4
    printf "$@" >&4
    printf '\n' >&4
}

# 毫秒时间戳：优先用 EPOCHREALTIME（内建变量，不起进程）
hui__now_ms() {
    local t=${EPOCHREALTIME:-}
    if [ -n "$t" ]; then
        t=${t//[!0-9]/}
        printf '%s' "${t:0:13}"
    else
        printf '%s' "$(($(date +%s) * 1000))"
    fi
}

# 父进程还活着吗？被收养或变成僵尸都算没了 —— 后台面板用它决定何时收摊，
# 否则孤儿面板会继续往同一个终端画，和新面板叠在一起看起来像"内容重复"
hui__parent_alive() {
    local p=$1 st
    [ -n "$p" ] || return 1
    kill -0 "$p" 2>/dev/null || return 1
    st=$(awk '{print $3}' "/proc/$p/stat" 2>/dev/null)
    [ "$st" = "Z" ] && return 1
    return 0
}

hui__dash_size() {
    local sz="" rows=0 cols=0
    # 每帧都 stty 太贵（构建图生成时机器很忙），循环里 5 拍量一次放这里。
    # 注意有些 pty 会报 "0 0"，这种缓存不能信，得继续往下探
    if [ -n "${HUI__SIZE_FRESH:-}" ]; then
        local fr=${HUI__SIZE_FRESH%% *}
        case "$fr" in ''|*[!0-9]*) fr=0 ;; esac
        if [ "$fr" -ge 5 ]; then printf '%s' "$HUI__SIZE_FRESH"; return 0; fi
    fi

    # 关键：渲染器是后台任务，交互 shell 会把它的 stdin 接到 /dev/null，
    # 这时 `stty size` 读不到窗口大小。必须显式从 /dev/tty 读。
    sz=$(stty size < /dev/tty 2>/dev/null)
    [ -n "$sz" ] || sz=$(stty size 2>/dev/null)
    rows=${sz%% *}; cols=${sz##* }
    case "$rows" in ''|*[!0-9]*) rows=0 ;; esac

    # 再退到父进程递进来的尺寸
    if [ "$rows" -lt 5 ] && [ -n "${HUI__SIZE_HINT:-}" ]; then
        rows=${HUI__SIZE_HINT%% *}; cols=${HUI__SIZE_HINT##* }
        case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
    fi
    # 再退到环境变量 / terminfo
    if [ "$rows" -lt 5 ]; then
        rows=${LINES:-0}; cols=${COLUMNS:-0}
        case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
    fi
    if [ "$rows" -lt 5 ]; then
        rows=$(tput lines 2>/dev/null); cols=$(tput cols 2>/dev/null)
        case "$rows" in ''|*[!0-9]*) rows=0 ;; esac
    fi
    case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
    [ "$rows" -lt 5 ] && rows=24
    case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
    [ "$cols" -lt 20 ] && cols=80
    printf '%s %s' "$rows" "$cols"
}

# 有没有可用的控制终端（能 open /dev/tty）。聊天/IDE 里 stdout/stderr 常被
# 接成管道，但控制终端还在，这种情况就借 /dev/tty 兜底。
hui__have_tty() { (exec 3<>/dev/tty) 2>/dev/null; }

hui__dash_available() {
    [ "${HUI_DASHBOARD:-1}" = "0" ] && return 1
    if [ ! -t 2 ]; then
        # stderr 被管道接走：只要有控制终端，面板照样可以画到 /dev/tty
        hui__have_tty || return 1
    fi
    local sz rows
    sz=$(hui__dash_size); rows=${sz%% *}
    case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
    [ "$rows" -ge 16 ] || return 1
    return 0
}

# 读一个按键，最多等 0.05s；没有输入就返回非 0
hui__read_key() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        read -r -s -k1 -t 0.05 "$1" < /dev/tty 2>/dev/null
    else
        read -r -s -n1 -t 0.05 "$1" < /dev/tty 2>/dev/null
    fi
}

hui__dash_tail() {
    local log=$1 n=$2 cols=$3 off=${4:-0} w
    w=$(( cols - 1 ))
    tail -n $(( n + off )) "$log" 2>/dev/null |
        tr '\r' '\n' |
        sed -e 's/\033\[[0-9;?]*[a-zA-Z]//g' -e 's/\033\[[0-9;]*m//g' \
            -e 's/\t/    /g' |
        grep -v '^[[:space:]]*$' |
        head -n "$n" |
        HUI__TAILC=${HUI_TAIL_COLOR:-1} LC_ALL=C awk -v w="$w" '
            BEGIN {
                e = 27
                RST = sprintf("%c[0m", e); DIM = sprintf("%c[2m", e)
                BLD = sprintf("%c[1m", e); CYN = sprintf("%c[36m", e)
                BLU = sprintf("%c[34m", e); GRN = sprintf("%c[32m", e)
                MAG = sprintf("%c[35m", e); YEL = sprintf("%c[33m", e)
                RED = sprintf("%c[31m", e)
                color = ENVIRON["HUI__TAILC"]
            }
            {
                line = $0
                if (length(line) > w) {
                    s = substr(line, 1, w - 2)
                    gsub(/[^ -~]+$/, "", s)
                    line = s "…"
                }
                if (color == "0") { print line; next }

                # 报错整行红、告警整行黄（大小写都认）
                ll = tolower(line)
                if (ll ~ /(^| )error:|failed:|fatal error|ninja: build stopped|soong bootstrap failed/) {
                    print RED line RST; next
                }
                if (ll ~ /warning:|warn:/) { print YEL line RST; next }

                # 拆出 "[ 45% 123/456]" 前缀，前缀压暗
                pre = ""; rest = line
                if (substr(line, 1, 1) == "[") {
                    i = index(line, "]")
                    if (i > 0 && i <= 16) { pre = substr(line, 1, i); rest = substr(line, i + 1) }
                }

                # 动作名 = 第一个路径之前那一小段（compile / link / generate serializers …）
                verb = ""; tail = rest
                j = index(rest, "/")
                if (j > 1) {
                    cand = substr(rest, 1, j - 1)
                    if (length(cand) <= 26 && cand ~ /^ [A-Za-z][A-Za-z0-9:+. _-]*$/) {
                        verb = cand; tail = substr(rest, j)
                    }
                }

                vc = ""
                vl = tolower(verb)
                if (vl ~ /error|fail/)            vc = RED
                else if (vl ~ /compile/)          vc = CYN
                else if (vl ~ /serializ|generat/) vc = BLU
                else if (vl ~ /link|install|copy|cp|creat/) vc = GRN
                else if (vl ~ /java|jar|apk|dex|packag|target/) vc = MAG

                out = ""
                if (pre != "")  out = out DIM pre RST
                if (verb != "") out = out vc verb RST
                print out tail
            }'
}

# 取 m/ninja 那一行完整进度："[ 45% 1234/5678] CC foo.o"
# 一次 awk 读完日志尾部（每帧只起 tail+awk 两个进程）：
#   HUI__DASH_PROG_LINE 里写 4 行：进度行 / 百分比 / 已编-总数 / 当前命令
#   HUI__DASH_TAIL 里写日志区要显示的那几行（已去 ANSI、截断、上色）
hui__dash_read() {
    local log=$1 n=$2 cols=$3 off=${4:-0} w
    w=$(( cols - 1 ))
    # 先清空：awk 只在写第一行时才截断文件，日志变空/换文件时不清会留着上一帧的旧行
    : >| "${HUI__DASH_TAIL:-/dev/null}" 2>/dev/null
    : >| "${HUI__DASH_PROG_LINE:-/dev/null}" 2>/dev/null
    tail -c 65536 -- "$log" 2>/dev/null |
        HUI__TAILC=${HUI_TAIL_COLOR:-1} LC_ALL=C awk -v w="$w" -v n="$n" -v off="$off" \
            -v prog="${HUI__DASH_PROG_LINE:-/dev/null}" -v tailf="${HUI__DASH_TAIL:-/dev/null}" '
        function elide(s) {
            if (w > 4 && length(s) > w) {
                s = substr(s, 1, w - 2)
                gsub(/[^ -~]+$/, "", s)
                s = s "…"
            }
            return s
        }
        function paint(s,   pre, rest, verb, tail, vc, vl, j, cand, i2, k2, out) {
            if (color == "0") return s
            k2 = tolower(s)
            if (k2 ~ /(^| )error:|failed:|fatal error|ninja: build stopped|soong bootstrap failed/) return RED s RST
            if (k2 ~ /warning:|warn:/) return YEL s RST
            pre = ""; rest = s
            if (substr(s, 1, 1) == "[") {
                i2 = index(s, "]")
                if (i2 > 0 && i2 <= 16) { pre = substr(s, 1, i2); rest = substr(s, i2 + 1) }
            }
            verb = ""; tail = rest
            j = index(rest, "/")
            if (j > 1) {
                cand = substr(rest, 1, j - 1)
                if (length(cand) <= 26 && cand ~ /^ [A-Za-z][A-Za-z0-9:+. _-]*$/) {
                    verb = cand; tail = substr(rest, j)
                }
            }
            vc = ""
            vl = tolower(verb)
            if (vl ~ /error|fail/)                         vc = RED
            else if (vl ~ /compile/)                       vc = CYN
            else if (vl ~ /serializ|generat/)              vc = BLU
            else if (vl ~ /link|install|copy|cp|creat/)    vc = GRN
            else if (vl ~ /java|jar|apk|dex|packag|target/) vc = MAG
            out = ""
            if (pre != "")  out = out DIM pre RST
            if (verb != "") out = out vc verb RST
            return out tail
        }
        BEGIN {
            RS = "[\r\n]"
            e = 27
            RST = sprintf("%c[0m", e); DIM = sprintf("%c[2m", e)
            CYN = sprintf("%c[36m", e); BLU = sprintf("%c[34m", e)
            GRN = sprintf("%c[32m", e); MAG = sprintf("%c[35m", e)
            YEL = sprintf("%c[33m", e); RED = sprintf("%c[31m", e)
            color = ENVIRON["HUI__TAILC"]
            want = n + off
            if (want > 512) want = 512
            if (want < 1) want = 1
            cnt = 0; last = ""; cur = ""
        }
        {
            line = $0
            gsub(/\033\[[0-9;?]*[a-zA-Z]/, "", line)
            gsub(/\033/, "", line)
            gsub(/\t/, "    ", line)
            gsub(/[\001-\010\013\014\016-\037\177]/, "", line)
            if (line ~ /^[[:space:]]*$/) next
            # m 启动那段 KEY=VALUE 已经在右上产品信息里汇总了，日志区别再重复一遍
            if (line ~ /^[A-Z][A-Z0-9_]*=/) next
            if (line ~ /^=+$/) next
            cur = line
            if (line ~ /\[[[:space:]]*([0-9]+%[[:space:]]*)?[0-9]+\/[0-9]+\]/) last = line
            cnt++
            buf[cnt % want] = line
        }
        END {
            if (last == "") last = cur
            pct = ""; cnts = ""; cmd = last
            if (last != "" && match(last, /\[[^]]*\]/)) {
                br = substr(last, RSTART, RLENGTH)
                cmd = substr(last, RSTART + RLENGTH)
                sub(/^ +/, "", cmd)
                if (match(br, /[0-9][0-9]*%/)) pct = substr(br, RSTART, RLENGTH - 1)
                if (match(br, /[0-9][0-9]*\/[0-9][0-9]*/)) cnts = substr(br, RSTART, RLENGTH)
                # siso/ninja 有时只打 [123/456]，没有百分比，这里补一个
                if (pct == "" && cnts != "") {
                    split(cnts, ab, "/")
                    if (ab[2] + 0 > 0) pct = int(ab[1] * 100 / ab[2])
                }
            }
            printf "%s\n%s\n%s\n%s\n", last, pct, cnts, cmd > prog
            total = (cnt < want) ? cnt : want
            start = cnt - total + 1
            lim = (n < total) ? n : total
            for (k = 0; k < lim; k++) {
                i = start + k
                print paint(elide(buf[i % want])) > tailf
            }
        }'
}

# htop 风格的条：[████░░░░]
hui__bar() {
    local pct=${1:-0} width=${2:-10} i=0 out=""
    [ "$pct" -lt 0 ] && pct=0
    [ "$pct" -gt 100 ] && pct=100
    local filled=$(( pct * width / 100 ))
    while [ "$i" -lt "$filled" ]; do out="$out█"; i=$((i + 1)); done
    while [ "$i" -lt "$width" ]; do out="$out░"; i=$((i + 1)); done
    printf '%s' "$out"
}

hui__bar_color() {
    local pct=${1:-0}
    if [ "$pct" -ge 80 ]; then printf '%s' "$hui__c_red"
    elif [ "$pct" -ge 50 ]; then printf '%s' "$hui__c_yel"
    else printf '%s' "$hui__c_grn"; fi
}

# CPU 使用率：两次 /proc/stat 采样求差；首次退回 loadavg
hui__cpu_util() {
    local _u _n _s _i _w _irq _sirq _st _rest
    read -r _u _n _s _i _w _irq _sirq _st _rest < <(sed -n '1s/^cpu[ ]*/ /p' /proc/stat 2>/dev/null)
    [ -n "${_st:-}" ] || _st=0
    local total=$(( ${_u:-0} + ${_n:-0} + ${_s:-0} + ${_i:-0} + ${_w:-0} + ${_irq:-0} + ${_sirq:-0} + ${_st:-0} ))
    local idlet=$(( ${_i:-0} + ${_w:-0} ))
    local pct=""
    if [ -n "${HUI__CPU_PREV_TOTAL:-}" ] && [ "$total" -gt "${HUI__CPU_PREV_TOTAL:-0}" ]; then
        local dt=$(( total - HUI__CPU_PREV_TOTAL ))
        local di=$(( idlet - ${HUI__CPU_PREV_IDLE:-0} ))
        [ "$di" -lt 0 ] && di=0
        pct=$(( 100 * (dt - di) / dt ))
        [ "$pct" -lt 0 ] && pct=0
        [ "$pct" -gt 100 ] && pct=100
    fi
    HUI__CPU_PREV_TOTAL=$total
    HUI__CPU_PREV_IDLE=$idlet
    if [ -z "$pct" ]; then
        pct=$(awk -v l="$(cut -d' ' -f1 /proc/loadavg 2>/dev/null)" -v n="$(nproc 2>/dev/null || echo 1)" \
              'BEGIN{ p=100*l/n; if (p>100) p=100; printf "%d", p }')
    fi
    printf '%s' "$pct"
}

# 一行： 标签(6格) 值
# 一行： 5 格 ASCII 标签 + 值（值按字节截断，保证整行不超宽）
hui__kv() {
    if [ -n "${4:-}" ]; then
        printf ' %s%-6s%s %s%s%s\n' "$hui__c_cyn" "$1" "$hui__c_rst" \
            "$4" "$(hui__cut "$3" "$2")" "$hui__c_rst"
    else
        printf ' %s%-6s%s %s\n' "$hui__c_cyn" "$1" "$hui__c_rst" "$(hui__cut "$3" "$2")"
    fi
}

# 值太长时折行（续行对齐到值列）：产品全名在窄栏里不再被截断
hui__kv_wrap() {
    local key=$1 val=$2 max=$3 maxlines=${4:-3} vcolor=${5:-}
    local rest=$val line n=0 indent="        "
    local lim=$(( maxlines > 1 ? maxlines - 1 : 1 ))
    while [ -n "$rest" ] && [ "$n" -lt "$lim" ] && [ "${#rest}" -gt "$max" ]; do
        line=${rest:0:$max}
        # 优先在最后一个空格处断开，避免切在单词中间
        case "$line" in
            *" "*) line=${line% *} ;;
        esac
        if [ -z "$line" ]; then
            line=${rest:0:$max}
            rest=${rest:$max}
        else
            rest=${rest:${#line}}
            rest=${rest# }
        fi
        if [ "$n" -eq 0 ]; then
            printf ' %s%-6s%s %s%s%s\n' "$hui__c_cyn" "$key" "$hui__c_rst" "$vcolor" "$line" "$hui__c_rst"
        else
            printf '%s%s%s%s\n' "$indent" "$vcolor" "$line" "$hui__c_rst"
        fi
        n=$((n + 1))
    done
    [ -z "$rest" ] && return 0
    # 最后一行：放不下就截断加 …
    if [ "${#rest}" -gt "$max" ]; then
        line=$(hui__cut "$max" "$rest")
    else
        line=$rest
    fi
    if [ "$n" -eq 0 ]; then
        printf ' %s%-6s%s %s%s%s\n' "$hui__c_cyn" "$key" "$hui__c_rst" "$vcolor" "$line" "$hui__c_rst"
    else
        printf '%s%s%s%s\n' "$indent" "$vcolor" "$line" "$hui__c_rst"
    fi
}

hui__dash_left_pane() {
    local out=$1 lw=$2 rows=${3:-0}
    local maxv=$(( lw - 8 ))
    [ "$maxv" -lt 4 ] && maxv=4
    local bw=$(( lw - 16 ))
    [ "$bw" -lt 5 ] && bw=5

    local cpu_pct mem_pct swap_pct load1 el jobs disk logv
    cpu_pct=$(hui__cpu_util)
    local mtot mavail
    mtot=$(awk '/^MemTotal:/{print $2}' /proc/meminfo 2>/dev/null)
    mavail=$(awk '/^MemAvailable:/{print $2}' /proc/meminfo 2>/dev/null)
    mem_pct=$(awk -v t="${mtot:-1}" -v a="${mavail:-1}" 'BEGIN{ v=100*(t-a)/t; if(v<0)v=0; if(v>100)v=100; printf "%d", v }')
    local st su
    st=${HUI__SWAP_TOTAL_MB:-0}; su=${HUI__SWAP_USED_MB:-0}
    if [ "$st" -gt 0 ]; then swap_pct=$(( su * 100 / st )); else swap_pct=0; fi
    load1=$(awk '{printf "%s %s %s", $1, $2, $3}' /proc/loadavg 2>/dev/null)
    el=$(( $(date +%s) - ${HUI__PHASE_START:-$(date +%s)} ))
    jobs="-"
    if [ -n "${HUI__STAT_FILE:-}" ] && [ -f "$HUI__STAT_FILE" ]; then
        local _t _s2
        read -r _t _s2 < "$HUI__STAT_FILE" 2>/dev/null || true
        [ -n "${_t:-}" ] && jobs=$_t
    fi
    [ "$jobs" = "-" ] && jobs=${HUI__JOBS_MAX:--}
    disk=$(df -h "$HUI_TOP" 2>/dev/null | awk 'NR==2{print $4}')
    logv="${HUI__LOG_SHORT:-}"
    [ "${#logv}" -gt "$maxv" ] && logv=${logv##*/}

    {
        printf ' %s编译机器%s\n' "$hui__c_bld$hui__c_cyn" "$hui__c_rst"
        printf ' %s%s%s\n' "$hui__c_dim" "$(printf '─%.0s' $(seq 1 $((lw - 2))))" "$hui__c_rst"
        printf ' %s%-6s%s [%s%s%s] %s%3s%%%s\n' "$hui__c_cyn" "CPU" "$hui__c_rst" \
            "$(hui__bar_color "$cpu_pct")" "$(hui__bar "$cpu_pct" "$bw")" "$hui__c_rst" \
            "$(hui__bar_color "$cpu_pct")" "$cpu_pct" "$hui__c_rst"
        hui__kv "LOAD" "$load1" "$maxv"
        printf ' %s%-6s%s [%s%s%s] %s%3s%%%s\n' "$hui__c_cyn" "MEM" "$hui__c_rst" \
            "$(hui__bar_color "$mem_pct")" "$(hui__bar "$mem_pct" "$bw")" "$hui__c_rst" \
            "$(hui__bar_color "$mem_pct")" "$mem_pct" "$hui__c_rst"
        hui__kv "AVAIL" "$(awk -v m="${HUI__AVAIL_MB:-0}" 'BEGIN{printf "%.1f GiB", m/1024}')" "$maxv"
        printf ' %s%-6s%s [%s%s%s] %s%3s%%%s\n' "$hui__c_cyn" "SWAP" "$hui__c_rst" \
            "$(hui__bar_color "$swap_pct")" "$(hui__bar "$swap_pct" "$bw")" "$hui__c_rst" \
            "$(hui__bar_color "$swap_pct")" "$swap_pct" "$hui__c_rst"
        local psi psic
        psi=$(hui__pressure_score 2>/dev/null)
        case "$psi" in ''|*[!0-9]*) psi=0 ;; esac
        psic=$hui__c_grn
        [ "$psi" -ge 10 ] && psic=$hui__c_yel
        [ "$psi" -ge 30 ] && psic=$hui__c_red
        hui__kv "PSI" "$psi%  jobs ${jobs}/${HUI__JOBS_MAX:-?}" "$maxv" "$psic"
        hui__kv "DISK" "${disk} free" "$maxv"
        hui__kv "TIME" "$(printf '%02d:%02d:%02d' $((el / 3600)) $((el % 3600 / 60)) $((el % 60)))" "$maxv" "$hui__c_bld$hui__c_cyn"
        hui__kv "LOG" "$logv" "$maxv" "$hui__c_dim"
    } >| "$out"

    # 左下角机器信息：紧跟占用指标下面（不贴底），硬件三项 + 系统两项
    if [ "${rows:-0}" -gt 0 ]; then
        local hw_cpu hw_cpu_txt hw_ram hw_disk hw_os hw_kver hw_threads hw_cores used pad bp ver id patch _avail _n kv
        hw_cpu=$(awk -F': ' '/model name/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
        [ -n "$hw_cpu" ] || hw_cpu=$(uname -m 2>/dev/null)
        # "13th Gen Intel(R) Core(TM) i9-13980HX" 这类长串压成 i9-13980HX
        case "$hw_cpu" in
            *i[0-9]-[0-9]*) hw_cpu=$(printf '%s' "$hw_cpu" | grep -oE 'i[0-9]-[0-9]+[A-Za-z]*' | head -1) ;;
            *Ryzen*)        hw_cpu=$(printf '%s' "$hw_cpu" | grep -oE 'Ryzen [0-9] [0-9]+[A-Za-z]*' | head -1) ;;
            *EPYC*)         hw_cpu=$(printf '%s' "$hw_cpu" | grep -oE 'EPYC [0-9]+[A-Za-z]*' | head -1) ;;
            *)              hw_cpu=$(printf '%s' "$hw_cpu" | sed -e 's/(R)//g' -e 's/(TM)//g' \
                                    -e 's/ CPU//g' -e 's/ Processor//g' -e 's/ *@.*//' -e 's/  */ /g') ;;
        esac
        [ -n "$hw_cpu" ] || hw_cpu=$(uname -m 2>/dev/null)
        hw_threads=$(nproc 2>/dev/null)
        hw_cores=$(awk -F': ' '/^cpu cores/{print $2; exit}' /proc/cpuinfo 2>/dev/null)
        case "$hw_cores" in ''|*[!0-9]*) hw_cores="" ;; esac
        hw_cpu_txt=$hw_cpu
        if [ -n "$hw_cores" ] && [ -n "$hw_threads" ] && [ "$hw_cores" -ne "$hw_threads" ]; then
            hw_cpu_txt="$hw_cpu · ${hw_cores}C/${hw_threads}T"
        elif [ -n "$hw_threads" ]; then
            hw_cpu_txt="$hw_cpu · ${hw_threads}T"
        fi
        # 栏太窄时退回纯型号，别把型号本身截掉
        [ "${#hw_cpu_txt}" -gt "$maxv" ] && hw_cpu_txt=$hw_cpu
        hw_ram="$(hui__mem_gb) GiB"
        hw_disk=$(df -h "$HUI_TOP" 2>/dev/null | awk 'NR==2{print $2}')
        [ -n "$hw_disk" ] || hw_disk="?"
        hw_os=""
        if [ -r /etc/os-release ]; then
            hw_os=$(sed -n 's/^PRETTY_NAME=//p' /etc/os-release 2>/dev/null | head -1 | tr -d '"')
        fi
        [ -n "$hw_os" ] || hw_os=$(uname -s 2>/dev/null)
        hw_kver=$(uname -r 2>/dev/null)
        [ -n "$hw_kver" ] || hw_kver="?"
        {
            printf ' %s%s%s\n' "$hui__c_dim" "$(printf '─%.0s' $(seq 1 $((lw - 2))))" "$hui__c_rst"
            hui__kv "OS" "$hw_os" "$maxv"
            hui__kv "KERNEL" "$hw_kver" "$maxv"
            hui__kv "CPU" "$hw_cpu_txt" "$maxv"
            hui__kv "RAM" "$hw_ram" "$maxv"
            hui__kv "DISK" "$hw_disk" "$maxv"
        } >> "$out"
    fi

    # 构建配置要用的几项（原样配置块用）：Android 版本 / BUILD_ID / 安全补丁
    # build.prop 优先（构建产物最准）；还没构建过（比如正在构图）就用
    # hui__panel_config 从 get_build_var 取的当前配置，别让面板只剩「?」。
    ver=""; id=""; patch=""
    bp="$HUI_TOP/out/target/product/${HUI__DEV:-${HUI__PRODUCT##*_}}/system/build.prop"
    if [ -r "$bp" ]; then
        ver=$(sed -n 's/^ro.build.version.release=//p' "$bp" 2>/dev/null | head -1)
        id=$(sed -n 's/^ro.build.id=//p' "$bp" 2>/dev/null | head -1)
        patch=$(sed -n 's/^ro.build.version.security_patch=//p' "$bp" 2>/dev/null | head -1)
    fi
    if [ -z "$ver" ] || [ -z "$id" ] || [ -z "$patch" ]; then
        [ -n "$ver" ]   || ver=${HUI__PLATFORM:-}
        [ -n "$id" ]    || id=${HUI__BUILD_ID:-}
        [ -n "$patch" ] || patch=${HUI__PATCH:-}
    fi


    # 构建配置：紧凑对齐表（左边缩写键、右边值对齐；ROM 全名在右上显示，这里不重复）
    used=$(wc -l < "$out" 2>/dev/null); used=${used:-0}
    _avail=$(( rows - 1 - used ))
    if [ "$_avail" -ge 3 ]; then
        {
            printf ' %s%s%s\n' "$hui__c_dim" "$(printf '─%.0s' $(seq 1 $((lw - 2))))" "$hui__c_rst"
            _n=1
            for kv in \
                "PLATFORM=${ver:-?}" \
                "DEVICE=${HUI__DEV:-${HUI__PRODUCT##*_}}" \
                "GMS=${HUI__WITH_GMS:-?}" \
                "VARIANT=${TARGET_BUILD_VARIANT:-?}" \
                "BUILD_ID=${id:-?}" \
                "PATCH=${patch:-?}"; do
                [ "$_n" -lt "$_avail" ] || break
                printf ' %s%-8s%s %s%s%s\n' "$hui__c_cyn" "${kv%%=*}" "$hui__c_rst" \
                    "${HUI__THEME_ACCENT2:-}" "$(hui__cut $(( lw - 12 )) "${kv#*=}")" "$hui__c_rst"
                _n=$((_n + 1))
            done
        } >> "$out"
    fi
}

# 右上：产品信息（我们自己的几项 + m 启动时打印的构建配置）
hui__dash_prod_pane() {
    local rw=$1 maxcfg=${2:-6}
    local out="$HUI__DASH_RTOP"
    local maxv=$(( rw - 8 ))
    [ "$maxv" -lt 8 ] && maxv=8

    local snap snaptxt graph romv
    romv=${HUI__ROM_NAME:-${HUI__PRODUCT:-?}-${TARGET_BUILD_VARIANT:-?}}
    snap=$(hui__cache_latest 2>/dev/null)
    snaptxt="无"; [ -n "$snap" ] && snaptxt=$(hui__short "$snap" 8)
    graph="缺失"
    if [ "${HUI__PHASE_MODE:-build}" = "graph" ]; then
        graph="生成中"
    elif [ -n "${HUI__PRODUCT:-}" ] && [ -f "$HUI_TOP/out/soong/build.$HUI__PRODUCT.ninja" ]; then
        graph="已就绪"
    fi

    {
        printf ' %s%s产品信息%s\n' "$hui__c_bld" "$hui__c_cyn" "$hui__c_rst"
        hui__kv_wrap "ROM" "$romv" "$maxv" 3 "$HUI__THEME_ACCENT2"
        hui__kv "PROD" "${HUI__PRODUCT:-?} / ${TARGET_BUILD_VARIANT:-?}" "$maxv"
        local phl ph
        phl=${HUI__PHASE_LABEL:-}
        if [ -n "${HUI__PHASE_STATE:-}" ]; then
            ph=$HUI__PHASE_STATE
            [ -n "$phl" ] && ph="$ph · $phl"
        else
            ph=${phl:-?}
        fi
        hui__kv "PHASE" "$ph" "$maxv"
        hui__kv "KERNEL" "${HUI__KS:-prebuilt}" "$maxv"
        hui__kv "SNAP" "$snaptxt" "$maxv"
        hui__kv "GRAPH" "$graph" "$maxv"

        local bw=$(( rw - 16 ))
        [ "$bw" -lt 6 ] && bw=6
        if [ -n "${HUI__PROG_PCT:-}" ] && [ "${HUI__PHASE_MODE:-build}" != "graph" ]; then
            printf ' %s%-6s%s [%s%s%s] %3s%%\n' "$hui__c_cyn" "PROG" "$hui__c_rst" \
                "${HUI__PROG_COLOR:-${HUI__THEME_ACCENT:-$hui__c_blu}}" "$(hui__bar "$HUI__PROG_PCT" "$bw")" \
                "$hui__c_rst" "$HUI__PROG_PCT"
        else
            printf ' %s%-6s%s [%s%s%s]  --\n' "$hui__c_cyn" "PROG" "$hui__c_rst" \
                "$hui__c_dim" "$(printf '░%.0s' $(seq 1 "$bw"))" "$hui__c_rst"
        fi

    } >| "$out"
}

# 最近完成的编译动作 + 各自耗时，拟 m 编译时下方那张「动作表」
#   数据源：out/.ninja_log（siso/ninja 每完成一条边就追加一行）
#     start_ms <TAB> end_ms <TAB> mtime <TAB> output <TAB> hash
#   秒数 = (end - start)，描述优先取日志正文里对应的那行，配不上就退回输出路径
hui__dash_recent() {
    local log=$1 n=$2 cols=$3
    local out=${HUI__DASH_RECENT:-/dev/null}
    : >| "$out" 2>/dev/null

    local nl="$HUI_TOP/out/.ninja_log"
    [ -f "$nl" ] || return 0

    # 上一次构建残留的日志不算数：文件得是本次阶段开始之后动过的
    local mt; mt=$(stat -c %Y "$nl" 2>/dev/null)
    case "$mt" in ''|*[!0-9]*) mt="" ;; esac
    if [ -n "$mt" ] && [ -n "${HUI__PHASE_START:-}" ] \
       && [ "$mt" -lt $(( HUI__PHASE_START - 3 )) ]; then
        return 0
    fi

    local w=$(( cols - 1 ))
    [ "$w" -lt 16 ] && return 0

    # .ninja_log 在完整构建里能到几十 MB，每次重画只吃尾部 128KB
    local nlf=${HUI__DASH_NL:-}
    if [ -n "$nlf" ]; then
        tail -c 131072 -- "$nl" 2>/dev/null | tail -n +2 >| "$nlf" 2>/dev/null
        [ -s "$nlf" ] || return 0
        nl=$nlf
    fi

    tail -n 400 "$log" 2>/dev/null |
        tr '\r' '\n' |
        sed -e 's/\033\[[0-9;?]*[a-zA-Z]//g' -e 's/\t/    /g' |
        HUI__NL="$nl" HUI__NREC="$n" HUI__NW="$w" \
        awk '
            function paint(t,   j, cand, vl, vc) {
                j = index(t, "/")
                if (j <= 1) return DIM t RST
                cand = substr(t, 1, j - 1)
                if (length(cand) > 26 || cand !~ /^[A-Za-z][A-Za-z0-9:+. _-]*$/) return DIM t RST
                vl = tolower(cand); vc = ""
                if (vl ~ /compile/)                       vc = CYN
                else if (vl ~ /serializ|generat/)         vc = BLU
                else if (vl ~ /link|install|copy|cp|creat/) vc = GRN
                else if (vl ~ /java|jar|apk|dex|packag|target/) vc = MAG
                if (vc == "") return DIM t RST
                return vc cand RST DIM substr(t, j) RST
            }
            BEGIN {
                e = 27
                cy = sprintf("%c[33m%c[1m", e, e)
                ce = sprintf("%c[31m%c[1m", e, e)
                cz = sprintf("%c[0m", e)
                RST = cz
                DIM = sprintf("%c[2m", e)
                CYN = sprintf("%c[36m", e)
                BLU = sprintf("%c[34m", e)
                GRN = sprintf("%c[32m", e)
                MAG = sprintf("%c[35m", e)
                n  = ENVIRON["HUI__NREC"] + 0
                w  = ENVIRON["HUI__NW"] + 0
                nl = ENVIRON["HUI__NL"]
                K  = 256
                cnt = 0
                while ((getline ln < nl) > 0) {
                    if (ln ~ /^#/) continue
                    if (split(ln, f, "\t") < 4) continue
                    cnt++
                    s = cnt % K
                    d = (f[2] + 0) - (f[1] + 0)
                    D[s] = (d > 0 ? d : 0)
                    O[s] = f[4]
                    B[s] = f[4]
                    sub(/.*\//, "", B[s])
                }
                close(nl)
                base = cnt - n + 1
                if (base < 1) base = 1
                for (i = 1; i <= n; i++) { seq[i] = base + i - 1; txt[i] = "" }
            }
            {
                ln = $0
                gsub(/\033\[[0-9;?]*[a-zA-Z]/, "", ln)
                gsub(/\033/, "", ln)
                gsub(/\t/, "    ", ln)
                gsub(/[\001-\010\013\014\016-\037\177]/, "", ln)
                for (i = 1; i <= n; i++) {
                    if (txt[i] != "" || seq[i] < 1 || seq[i] > cnt) continue
                    s = seq[i] % K
                    if (O[s] != "" && index(ln, O[s]) > 0) { txt[i] = ln; continue }
                    if (O[s] != "" && index(ln, "out/" O[s]) > 0) { txt[i] = ln; continue }
                    if (B[s] != "" && index(ln, B[s]) > 0) txt[i] = ln
                }
            }
            END {
                maxw = w - 9
                if (maxw < 12) maxw = 12
                for (i = 1; i <= n; i++) {
                    if (seq[i] < 1 || seq[i] > cnt) continue
                    s = seq[i] % K
                    d = int(D[s] / 1000)
                    pre = sprintf("   %2d:%02d ", int(d / 60), d % 60)
                    if (d >= 60)      pre = ce pre cz
                    else if (d >= 30) pre = cy pre cz
                    t = txt[i]
                    if (t != "") sub(/^ *\[[^]]*\] */, "", t)
                    else         t = O[s]
                    if (length(t) > maxw) {
                        t = substr(t, 1, maxw - 3)
                        gsub(/[^ -~]+$/, "", t)
                        t = t "…"
                    }
                    printf "%s%s\n", pre, paint(t)
                }
            }
        ' >| "$out" 2>/dev/null
}

# 构图阶段在跑什么：没有 ninja 边可数，只能看谁还活着。
# 由面板约每秒调一次（构图时机器很忙，别每帧都扫 /proc），结果缓存在 HUI__GRAPH_STAGE。
hui__graph_stage() {
    if command -v pgrep >/dev/null 2>&1; then
        if pgrep -x soong_build >/dev/null 2>&1; then
            printf 'soong 分析'
            return 0
        fi
        if pgrep -x ckati >/dev/null 2>&1; then
            printf 'kati 配置'
            return 0
        fi
        if pgrep -x soong_ui >/dev/null 2>&1; then
            printf 'soong bootstrap'
            return 0
        fi
    fi
    printf '分析中'
}

# 构图阶段的「最新输出」：此时 .ninja_log 还是上一次构建的，读它会显示陈旧动作；
# 直接截日志尾部，去掉空行/配置块，最后 n 行铺进右下框。
hui__graph_recent() {
    local log=$1 n=$2 cols=$3
    local out=${HUI__DASH_RECENT:-/dev/null} w
    : >| "$out" 2>/dev/null
    w=$(( cols - 1 )); [ "$w" -lt 16 ] && return 0
    [ "$n" -lt 1 ] && return 0
    tail -c 131072 -- "$log" 2>/dev/null |
        tr '\r' '\n' |
        sed -e 's/\033\[[0-9;?]*[a-zA-Z]//g' -e 's/\033//g' |
        LC_ALL=C tr -d '\001-\010\013\014\016-\037\177' |
        awk -v n="$n" -v w="$w" '
            function elide(s) {
                if (w > 4 && length(s) > w) {
                    s = substr(s, 1, w - 2)
                    gsub(/[^ -~]+$/, "", s)
                    s = s "…"
                }
                return s
            }
            BEGIN { k = 0 }
            /^[[:space:]]*$/ { next }
            /^[A-Z][A-Z0-9_]*=/ { next }
            /^=+$/ { next }
            { gsub(/\t/, "    "); buf[k % n] = $0; k++ }
            END {
                start = k - n
                if (start < 0) start = 0
                for (i = start; i < k; i++) printf "%s\n", elide(buf[i % n])
            }
        ' >| "$out" 2>/dev/null
}

hui__dash_draw() {
    local label=$1 jobs=$2 log=$3 off=${4:-0} tick=${5:-0}
    local sz rows cols lw rw r line lh rh top_h log_rows rcol prog pct acc
    local recent_h=0 rh2=0 sep_row=0 log_end=0 rebuild=1 graph=0

    sz=$(hui__dash_size)
    rows=${sz%% *}; cols=${sz##* }
    case "$rows" in ''|*[!0-9]*) rows=24 ;; esac
    case "$cols" in ''|*[!0-9]*) cols=80 ;; esac
    [ "$rows" -lt 12 ] && rows=12

    # 构图阶段（kati+soong 分析）：没有 ninja 边，进度区换成「阶段 + 已用时间」
    case "${HUI__PHASE_MODE:-build}" in graph) graph=1 ;; esac

    # 进度值这一帧稍后从日志里取；先沿用上一帧的，给右上产品信息用
    prog=${HUI__PROG_LINE:-}
    pct=${HUI__PROG_PCT:-}

    lw=0
    if [ "$cols" -ge 76 ]; then
        lw=$(( cols / 3 ))
        [ "$lw" -lt 26 ] && lw=26
        [ "$lw" -gt 36 ] && lw=36
    fi
    rcol=1; rw=$cols
    if [ "$lw" -gt 0 ]; then
        rcol=$(( lw + 2 ))
        rw=$(( cols - lw - 2 ))
    fi

    HUI__PHASE_LABEL=$label
    hui__mem_sample

    # 右上要显示多少条构建配置
    local maxcfg=$(( rows / 4 ))
    [ "$maxcfg" -lt 4 ] && maxcfg=4
    [ "$maxcfg" -gt 10 ] && maxcfg=10

    # 机器信息/产品信息这种重活 1 秒左右刷一次就够，进度行和日志仍然每帧刷，
    # 别让面板自己吃掉构建的 CPU
    if [ "$tick" -gt 0 ] && [ $(( tick % 3 )) -ne 0 ] \
       && [ -s "${HUI__DASH_RTOP:-}" ] && [ -s "${HUI__DASH_LEFT:-}" ]; then
        rebuild=0
    fi
    if [ "$rebuild" = "1" ]; then
        [ "$lw" -gt 0 ] && hui__dash_left_pane "$HUI__DASH_LEFT" "$lw" "$rows"
        hui__dash_prod_pane "$rw" "$maxcfg"
    fi

    lh=0
    [ "$lw" -gt 0 ] && lh=$(wc -l < "$HUI__DASH_LEFT" 2>/dev/null)
    rh=$(wc -l < "$HUI__DASH_RTOP" 2>/dev/null)
    case "$lh" in ''|*[!0-9]*) lh=0 ;; esac
    case "$rh" in ''|*[!0-9]*) rh=0 ;; esac
    top_h=$rh
    top_h=$(( top_h + 1 ))
    [ "$top_h" -gt $(( rows - 8 )) ] && top_h=$(( rows - 8 ))
    [ "$top_h" -lt 5 ] && top_h=5

    # 右下框：第一排显示进度，下面是最新完成的动作（高度 rows/3，4~10 行）
    if [ "$rows" -ge 20 ]; then
        recent_h=$(( (rows - 1 - top_h) * 4 / 10 ))
        [ "$recent_h" -gt 18 ] && recent_h=18
        [ "$recent_h" -lt 3 ] && recent_h=3
        HUI__RECENT_ON=1
        if [ "$rebuild" = "1" ]; then
            # 构图阶段 .ninja_log 还是上一次构建的：右边改刷日志尾部，别显示陈旧动作
            if [ "$graph" = "1" ]; then
                hui__graph_recent "$log" "$recent_h" "$rw"
            else
                hui__dash_recent "$log" "$recent_h" "$rw"
            fi
        fi
        rh2=$(( recent_h + 1 ))
    fi

    # 日志区占中间；rh2 = 进度行 + 动作行
    log_rows=$(( rows - top_h - 2 - recent_h ))
    [ "$log_rows" -lt 2 ] && log_rows=2

    sep_row=$(( rows - 1 - recent_h ))
    log_end=$(( sep_row - 1 ))

    # 一次读完：进度行 + 日志区那几行（每帧只起 tail+awk 两个进程）
    hui__dash_read "$log" "$log_rows" "$rw" "$off"
    prog=""; pct=""
    if [ -s "${HUI__DASH_PROG_LINE:-/dev/null}" ]; then
        { IFS= read -r prog; IFS= read -r pct; IFS= read -r HUI__PROG_COUNTS; IFS= read -r HUI__PROG_CMD; } \
            < "$HUI__DASH_PROG_LINE"
    fi
    case "$pct" in ''|*[!0-9]*) pct="" ;; esac
    [ -n "$prog" ] || prog="等待构建系统输出…"
    # 这一帧没读到带 [n/m] 的进度行时沿用上一帧，免得底行在两种格式之间来回跳
    if [ -n "${HUI__PROG_COUNTS:-}" ]; then
        HUI__PROG_KEEP=$prog
        HUI__PROG_LINE=$prog
        HUI__PROG_PCT=$pct
    elif [ -n "${HUI__PROG_KEEP:-}" ]; then
        prog=$HUI__PROG_KEEP
        pct=${HUI__PROG_PCT:-}
        HUI__PROG_LINE=$prog
        HUI__PROG_COUNTS=$(printf '%s' "$prog" | grep -o '[0-9][0-9]*/[0-9][0-9]*' 2>/dev/null | head -1)
        HUI__PROG_CMD=$(printf '%s' "$prog" | sed 's/^\[[^]]*\] *//')
    fi
    # 编译进度条全程蓝色（不随百分比变色）
    HUI__PROG_COLOR=${HUI__THEME_ACCENT:-$hui__c_blu}
    acc=$HUI__PROG_COLOR

    # 构图模式：没有 [n/m] 可数，硬画百分比只会停在 0%/100% 像卡死。
    # 进度行改成「阶段 + 已用时间 + 转圈」，细节让下面的「最新输出」区刷。
    if [ "$graph" = "1" ]; then
        if [ $(( tick % 3 )) -eq 0 ] || [ -z "${HUI__GRAPH_STAGE:-}" ]; then
            HUI__GRAPH_STAGE=$(hui__graph_stage)
        fi
        local gel gsp
        gel=$(( $(date +%s) - ${HUI__PHASE_START:-$(date +%s)} ))
        [ "$gel" -lt 0 ] && gel=0
        case $(( tick % 10 )) in
            0) gsp='⠋' ;; 1) gsp='⠙' ;; 2) gsp='⠹' ;; 3) gsp='⠸' ;; 4) gsp='⠼' ;;
            5) gsp='⠴' ;; 6) gsp='⠦' ;; 7) gsp='⠧' ;; 8) gsp='⠇' ;; *) gsp='⠏' ;;
        esac
        prog=$(printf '%s 构图 · %s · 已用 %02d:%02d:%02d' \
            "$gsp" "${HUI__GRAPH_STAGE:-分析中}" $((gel / 3600)) $((gel % 3600 / 60)) $((gel % 60)))
        HUI__PROG_COUNTS=""
        HUI__PROG_CMD=""
        HUI__PROG_PCT=""
        pct=""
    fi

    : >| "$HUI__DASH_FRAME" 2>/dev/null
    # 注意：exec 的重定向会永久作用于当前 shell —— 千万不能在这里顺手写 2>/dev/null，
    # 否则后面所有输出（包括往 stderr 发的整帧画面）全进黑洞，面板就一片空白
    if [ -n "${HUI__DASH_FRAME:-}" ]; then
        exec 4>> "$HUI__DASH_FRAME"
    else
        exec 4>> /dev/null
    fi
    # 每行直接写进帧缓冲（不起子 shell）——以前 $(_hui_row ... "$(printf ...)")
    # 每帧要 fork 四十多次，机器忙的时候面板就跟着卡
    if [ "$lw" -gt 0 ]; then
        r=1
        while IFS= read -r line; do
            [ "$r" -gt $(( rows - 1 )) ] && break
            _hui_row "$r" '\033[%d;1H%s\033[K' "$r" "$line"
            r=$((r + 1))
        done < "$HUI__DASH_LEFT"
        while [ "$r" -le $(( rows - 1 )) ]; do
            _hui_row "$r" '\033[%d;1H\033[K\033[%d;%dH│' "$r" "$r" "$lw"
            r=$((r + 1))
        done
    fi

    r=1
    while IFS= read -r line; do
        [ "$r" -ge "$top_h" ] && break
        if [ "$lw" -gt 0 ]; then
            _hui_row "$r" '\033[%d;%dH│\033[%d;%dH%s\033[K' "$r" "$lw" "$r" "$rcol" "$line"
        else
            _hui_row "$r" '\033[%d;%dH%s\033[K' "$r" "$rcol" "$line"
        fi
        r=$((r + 1))
    done < "$HUI__DASH_RTOP"
    while [ "$r" -lt "$top_h" ]; do
        if [ "$lw" -gt 0 ]; then
            _hui_row "$r" '\033[%d;%dH│\033[%d;%dH\033[K' "$r" "$lw" "$r" "$rcol"
        else
            _hui_row "$r" '\033[%d;%dH\033[K' "$r" "$rcol"
        fi
        r=$((r + 1))
    done

    if [ "$off" -gt 0 ]; then
        if [ "$lw" -gt 0 ]; then
            _hui_row "$top_h" '\033[%d;%dH│\033[%d;%dH%s─── 已上翻 %s 行 · End 回到实时 ───%s\033[K' \
                "$top_h" "$lw" "$top_h" "$rcol" "$hui__c_dim" "$off" "$hui__c_rst"
        else
            _hui_row "$top_h" '\033[%d;%dH%s─── 已上翻 %s 行 · End 回到实时 ───%s\033[K' \
                "$top_h" "$rcol" "$hui__c_dim" "$off" "$hui__c_rst"
        fi
    else
        if [ "$lw" -gt 0 ]; then
            _hui_row "$top_h" '\033[%d;%dH│\033[%d;%dH%s%s%s\033[K' \
                "$top_h" "$lw" "$top_h" "$rcol" "$hui__c_dim" \
                "$(printf '─%.0s' $(seq 1 $((rw - 1))))" "$hui__c_rst"
        else
            _hui_row "$top_h" '\033[%d;%dH%s%s%s\033[K' \
                "$top_h" "$rcol" "$hui__c_dim" \
                "$(printf '─%.0s' $(seq 1 $((rw - 1))))" "$hui__c_rst"
        fi
    fi

    r=$((top_h + 1))
    while IFS= read -r line; do
        [ "$r" -gt "$log_end" ] && break
        if [ "$lw" -gt 0 ]; then
            _hui_row "$r" '\033[%d;%dH│\033[%d;%dH%s\033[K' "$r" "$lw" "$r" "$rcol" "$line"
        else
            _hui_row "$r" '\033[%d;%dH%s\033[K' "$r" "$rcol" "$line"
        fi
        r=$((r + 1))
    done < "$HUI__DASH_TAIL"
    while [ "$r" -le "$log_end" ]; do
        if [ "$lw" -gt 0 ]; then
            _hui_row "$r" '\033[%d;%dH│\033[%d;%dH\033[K' "$r" "$lw" "$r" "$rcol"
        else
            _hui_row "$r" '\033[%d;%dH\033[K' "$r" "$rcol"
        fi
        r=$((r + 1))
    done

    if [ "$lw" -gt 0 ]; then
        _hui_row "$sep_row" '\033[%d;%dH│\033[%d;%dH%s%s%s\033[K' \
            "$sep_row" "$lw" "$sep_row" "$rcol" "$hui__c_dim" \
            "$(printf '─%.0s' $(seq 1 $((rw - 1))))" "$hui__c_rst"
    else
        _hui_row "$sep_row" '\033[%d;1H%s%s%s\033[K' "$sep_row" "$hui__c_dim" \
            "$(printf '─%.0s' $(seq 1 $((cols - 1))))" "$hui__c_rst"
    fi

    if [ "$rh2" -gt 0 ]; then
        # 第一排：进度
        r=$((sep_row + 1))
        if [ -n "${HUI__PROG_COUNTS:-}" ]; then
            if [ "$lw" -gt 0 ]; then
                _hui_row "$r" '\033[%d;%dH│\033[%d;%dH %s[%s %s%%]%s %s%s%s\033[K' \
                    "$r" "$lw" "$r" "$rcol" "$hui__c_dim" "$HUI__PROG_COUNTS" "${pct:-?}" \
                    "$hui__c_rst" "$acc" "$(hui__cut $((rw - 26)) "$HUI__PROG_CMD")" "$hui__c_rst"
            else
                _hui_row "$r" '\033[%d;1H %s[%s %s%%]%s %s%s%s\033[K' \
                    "$r" "$hui__c_dim" "$HUI__PROG_COUNTS" "${pct:-?}" \
                    "$hui__c_rst" "$acc" "$(hui__cut $((cols - 26)) "$HUI__PROG_CMD")" "$hui__c_rst"
            fi
        else
            if [ "$lw" -gt 0 ]; then
                _hui_row "$r" '\033[%d;%dH│\033[%d;%dH %s%s%s\033[K' \
                    "$r" "$lw" "$r" "$rcol" "$hui__c_dim" "$(hui__cut $((rw - 2)) "$prog")" "$hui__c_rst"
            else
                _hui_row "$r" '\033[%d;1H %s%s%s\033[K' \
                    "$r" "$hui__c_dim" "$(hui__cut $((cols - 2)) "$prog")" "$hui__c_rst"
            fi
        fi
        # 下面：最近完成的动作，铺到最底
        r=$((sep_row + 2))
        while IFS= read -r line; do
            [ "$r" -gt "$rows" ] && break
            if [ "$lw" -gt 0 ]; then
                _hui_row "$r" '\033[%d;%dH│\033[%d;%dH%s\033[K' "$r" "$lw" "$r" "$rcol" "$line"
            else
                _hui_row "$r" '\033[%d;%dH%s\033[K' "$r" "$rcol" "$line"
            fi
            r=$((r + 1))
        done < "${HUI__DASH_RECENT:-/dev/null}"
        while [ "$r" -le "$rows" ]; do
            if [ "$lw" -gt 0 ]; then
                _hui_row "$r" '\033[%d;%dH│\033[%d;%dH\033[K' "$r" "$lw" "$r" "$rcol"
            else
                _hui_row "$r" '\033[%d;%dH\033[K' "$r" "$rcol"
            fi
            r=$((r + 1))
        done
    else
        # 终端太矮：进度仍在最底行
        if [ -n "${HUI__PROG_COUNTS:-}" ]; then
            _hui_row "$rows" '\033[%d;1H %s[%s %s%%]%s %s%s%s' "$rows" \
                "$hui__c_dim" "$HUI__PROG_COUNTS" "${pct:-?}" "$hui__c_rst" \
                "$acc" "$(hui__cut $((cols - 26)) "$HUI__PROG_CMD")" "$hui__c_rst"
        else
            _hui_row "$rows" '\033[%d;1H %s%s%s' "$rows" \
                "$hui__c_dim" "$(hui__cut $((cols - 2)) "$prog")" "$hui__c_rst"
        fi
    fi
    exec 4>&-

    # 只把变化的行发给终端（并清掉上一帧多出来的行）——不闪，也不白喂终端
    local prev="$HUI__DASH_FRAME.prev" out
    [ -f "$prev" ] || : >| "$prev"
    out=$(awk '
        {
            i = index($0, "\t")
            if (i < 2) next
            r = substr($0, 1, i - 1); v = substr($0, i + 1)
            if (FILENAME == ARGV[1]) {
                if (r in p) p[r] = p[r] v; else p[r] = v
                next
            }
            if (r in c) c[r] = c[r] v; else c[r] = v
        }
        END {
            for (r in c) if (!(r in p) || p[r] != c[r]) printf "%s\033[K", c[r]
            for (r in p) if (!(r in c)) printf "\033[%d;1H\033[K", r
        }' "$prev" "$HUI__DASH_FRAME" 2>/dev/null)

    if [ -n "$out" ]; then
        printf '\033[?2026h%s\033[?2026l' "$out" >&2
    fi
    mv -f "$HUI__DASH_FRAME" "$prev" 2>/dev/null
}

hui__dash_loop() {
    local label=$1 jobs=$2 log=$3 off=0 key k1 k2 esc page=20 sz last_sz="" tick=0 pressed=0
    # 注意：zsh 里同一个函数内第二次执行 local 会把变量值打到屏幕上，
    # 所以循环体里用到的变量必须在这里一次性声明，绝不能在循环里 local
    local _fsz rest
    local parent=$PPID
    trap 'HUI__WINCH=1' WINCH
    local iv_ms t0 spent
    esc=$(printf '\033')
    iv_ms=$(awk -v i="${HUI_DASH_INTERVAL:-0.3}" 'BEGIN{ v=i*1000; if (v < 50) v = 50; printf "%d", v }')
    while :; do
        t0=$(hui__now_ms)
        # 窗口大小变了：立刻整屏清、丢帧缓存，下一步按新尺寸重画
        if [ "${HUI__WINCH:-0}" = "1" ]; then
            HUI__WINCH=0
            HUI__SIZE_FRESH=""
            printf '\033[2J\033[H' >&2
            rm -f "${HUI__DASH_FRAME}.prev" 2>/dev/null
        fi
        # 终端尺寸一变，旧画面会留在新多出来的行列里 —— 先整屏清一次
        if [ $(( tick % 5 )) -eq 0 ]; then
            _fsz=$(stty size < /dev/tty 2>/dev/null)
            case "${_fsz%% *}" in ''|0|*[!0-9]*) _fsz=$(stty size 2>/dev/null) ;; esac
            case "${_fsz%% *}" in
                ''|0|*[!0-9]*) HUI__SIZE_FRESH="" ;;
                *)             HUI__SIZE_FRESH=$_fsz ;;
            esac
        fi
        sz=$(hui__dash_size)
        if [ -n "$last_sz" ] && [ "$sz" != "$last_sz" ]; then
            printf '\033[2J\033[H' >&2
            rm -f "${HUI__DASH_FRAME}.prev" 2>/dev/null
        fi
        last_sz=$sz
        hui__dash_draw "$label" "$jobs" "$log" "$off" "$tick"
        [ $(( tick % 3 )) -eq 0 ] && printf '%s\n' "$(hui__psi_full10)" \
            >> "${HUI__PSI_LOG:-/dev/null}" 2>/dev/null
        tick=$(( tick + 1 ))
        # 定频：这一帧画了多久就从间隔里扣掉，别让时间显示一顿一顿
        spent=$(( $(hui__now_ms) - t0 ))
        [ "$spent" -lt 0 ] && spent=0
        if [ "$spent" -lt "$iv_ms" ]; then
            rest=$(( iv_ms - spent ))
            sleep "$(printf '%d.%03d' $(( rest / 1000 )) $(( rest % 1000 )))"
        fi
        # 父进程（阶段子 shell）没了就收摊：孤儿面板会跟新面板抢同一个终端
        kill -0 "$parent" 2>/dev/null || exit 0
        [ "$PPID" = "$parent" ] || exit 0
        if [ $(( tick % 10 )) -eq 0 ]; then
            hui__parent_alive "$parent" || exit 0
        fi

        # 收键盘：↑↓ 一行，PgUp/PgDn 一屏，End/e 回实时
        while hui__read_key key; do
            pressed=1
            case "$key" in
                "$esc")
                    hui__read_key k1
                    case "$k1" in
                        "[")
                            hui__read_key k2
                            case "$k2" in
                                A) off=$((off + 1)) ;;
                                B) off=$((off - 1)) ;;
                                5|6) hui__read_key k1
                                     if [ "$k2" = "5" ]; then off=$((off + page))
                                     else off=$((off - page)); fi ;;
                                H) off=$((off + page * 5)) ;;
                                F) off=0 ;;
                                [0-9]) # Ctrl/Alt+方向键这类长序列：吞到最后一位
                                    while hui__read_key k1; do
                                        case "$k1" in [A-Za-z~]) break ;; esac
                                    done ;;
                            esac ;;
                        "O") # application 模式的方向键
                            hui__read_key k2
                            case "$k2" in
                                A) off=$((off + 1)) ;;
                                B) off=$((off - 1)) ;;
                            esac ;;
                    esac
                    ;;
                k) off=$((off + 1)) ;;
                j) off=$((off - 1)) ;;
                g) off=$((off + page * 5)) ;;
                G|e|q) off=0 ;;
            esac
            [ "$off" -gt 5000 ] && off=5000
            [ "$off" -lt 0 ] && off=0
        done
        # 按过键就整帧重画一次：万一有东西糊到屏幕上，一并擦掉
        if [ "$pressed" = "1" ]; then
            rm -f "${HUI__DASH_FRAME}.prev" 2>/dev/null
            pressed=0
        fi
    done
}

# 构建失败、退出面板之后：把日志里真正像报错的行挑出来 + 给出完整日志路径
# （只打最后 40 行没用——失败时那 40 行多半是进度行，error 在更上面）
hui__fail_report() {
    local log=$1 max=${2:-40}
    local hits

    printf '\n%s失败报错：%s\n' "$hui__c_red" "$hui__c_rst" >&2
    hits=$(grep -n -i -E \
        'FAILED:|error:|fatal error|ninja: build stopped|soong bootstrap failed|out of memory|signal: killed|make(\[[0-9]+\])?: \*\*\*' \
        "$log" 2>/dev/null | tail -n "$max")

    if [ -n "$hits" ]; then
        printf '%s\n' "$hits" \
            | cut -c1-190 \
            | sed -e 's/^ *\([0-9][0-9]*\):/  \1 │ /' >&2
    else
        printf '%s  （日志里没有 error:/FAILED:，下面是最后 30 行）%s\n' \
            "$hui__c_dim" "$hui__c_rst" >&2
        hui__dash_tail "$log" 30 190 >&2
    fi

    printf '\n%s完整日志：%s %s\n' "$hui__c_yel" "$hui__c_rst" "${HUI__LOG_SHORT:-$log}" >&2
}

# ---------------------------------------------------------------------------
# 中断清理
# ---------------------------------------------------------------------------
# Ctrl-C 只保证同一个进程组收到 SIGINT；Runa 的 worker、内核 make 的子进程
# 可能另起进程组或者先被 reparent 到 init，父进程退了它们还在占内存。
# 所以中断时按进程树从叶子往根收：先 TERM 给机会退出，还不走再 KILL。
hui__kill_tree() {
    local pid=$1 sig=${2:-TERM} kid
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    [ "$pid" -gt 1 ] 2>/dev/null || return 0
    if command -v pgrep >/dev/null 2>&1; then
        for kid in $(pgrep -P "$pid" 2>/dev/null); do
            hui__kill_tree "$kid" "$sig"
        done
    fi
    kill -s "$sig" "$pid" 2>/dev/null
    return 0
}

hui__reap_build_tree() {
    local pid=$1 i
    case "$pid" in ''|*[!0-9]*) return 0 ;; esac
    [ "$pid" -gt 1 ] 2>/dev/null || return 0
    hui__kill_tree "$pid" TERM
    for i in 1 2 3 4 5 6 7 8 9 10; do
        kill -0 "$pid" 2>/dev/null || break
        sleep 0.2
    done
    if kill -0 "$pid" 2>/dev/null; then
        hui__kill_tree "$pid" KILL
    fi
    wait "$pid" 2>/dev/null
    return 0
}

# 阶段日志路径：<OUT_DIR>/hui/<codename>/hui-<产品>-<时间>.log
# 面板和非面板路径共用。目录建不出来时退到 OUT_DIR 根下；返回的路径仍可能
# 写不进去，调用方负责 `: >|` 失败后再回退 mktemp。
hui__log_file_new() {
    local out=${OUT_DIR:-out} dev=${HUI__DEV:-${HUI__PRODUCT##*_}} d
    [ -n "$dev" ] || dev=unknown
    case "$out" in
        /*) d="$out/hui/$dev" ;;
        *)  d="$HUI_TOP/$out/hui/$dev" ;;
    esac
    mkdir -p "$d" 2>/dev/null || {
        case "$out" in
            /*) d="$out" ;;
            *)  d="$HUI_TOP/$out" ;;
        esac
        mkdir -p "$d" 2>/dev/null
    }
    # 同一秒内起两个阶段（例如快速失败后重试）时别互相覆盖：重名就加 -2/-3
    local base f n=2
    base="$d/hui-${HUI__PRODUCT:-unknown}-$(date '+%Y%m%d-%H%M%S')"
    f="$base.log"
    while [ -e "$f" ]; do f="$base-$n.log"; n=$((n + 1)); done
    printf '%s' "$f"
}

# 记住最近一次阶段日志，给 hui__looks_like_oom / 失败复盘用
# （面板路径在子 shell 里跑，HUI__LOG_FILE 传不回来，只能落盘）。
hui__last_log_mark() {
    local log=$1 st
    st="${HUI_STATE:-$HUI_TOP/.hui}/.last-phase-log"
    mkdir -p "${st%/*}" 2>/dev/null
    printf '%s\n' "$log" >| "$st" 2>/dev/null
    return 0
}

hui__run_phase_dashboard() {
    local label=$1 jobs=$2; shift 2
    local mode=${HUI__PHASE_MODE:-build}
    if [ "$mode" = "graph" ]; then
        jobs=$(hui__graph_jobs "$jobs")
    fi
    (
        [ -n "${HUI_TOP:-}" ] || HUI_TOP=.
        [ -n "${HUI_STATE:-}" ] || HUI_STATE="$HUI_TOP/.hui"

        # stderr 被聊天/IDE 接成管道时，只要还有控制终端，就把面板画到 /dev/tty；
        # 否则面板会画进管道，终端上看起来就是“没有 TUI、像卡住”。
        if [ ! -t 2 ] && hui__have_tty; then
            exec 2>/dev/tty
        fi

        # 日志按 codename 归档：<OUT_DIR>/hui/<codename>/hui-<产品>-<时间>.log
        HUI__BUILD_START=$(date '+%Y-%m-%d %H:%M:%S')
        HUI__PHASE_LABEL=$label
        HUI__TARGET=${HUI__TARGET:-${*}}
        local log; log=$(hui__log_file_new)
        : >| "$log" 2>/dev/null || log=$(mktemp "${TMPDIR:-/tmp}/hui-build.XXXXXX")
        HUI__LOG_FILE=$log
        HUI__LOG_SHORT=${log#$HUI_TOP/}
        hui__last_log_mark "$log"
        local phase_exec; phase_exec=$(hui__executor)
        hui__highmem_refresh "$jobs"
        HUI__JOBS_MAX=$jobs
        hui__runa_like "$phase_exec" && HUI__JOBS_MAX=$(hui__jobs_max)
        [ "$mode" = "graph" ] && HUI__JOBS_MAX=$jobs
        HUI__PHASE_START=$(date +%s)
        HUI__STAT_FILE=$(mktemp "${TMPDIR:-/tmp}/hui-stat.XXXXXX" 2>/dev/null)
        HUI__DASH_LEFT=$(mktemp "${TMPDIR:-/tmp}/hui-left.XXXXXX" 2>/dev/null)
        HUI__DASH_RTOP=$(mktemp "${TMPDIR:-/tmp}/hui-top.XXXXXX" 2>/dev/null)
        HUI__DASH_TAIL=$(mktemp "${TMPDIR:-/tmp}/hui-tail.XXXXXX" 2>/dev/null)
        HUI__DASH_PROD=$(mktemp "${TMPDIR:-/tmp}/hui-prod.XXXXXX" 2>/dev/null)
        HUI__DASH_RECENT=$(mktemp "${TMPDIR:-/tmp}/hui-recent.XXXXXX" 2>/dev/null)
        HUI__DASH_NL=$(mktemp "${TMPDIR:-/tmp}/hui-nl.XXXXXX" 2>/dev/null)
        HUI__PSI_LOG=$(mktemp "${TMPDIR:-/tmp}/hui-psi.XXXXXX" 2>/dev/null)
        HUI__DASH_FRAME=$(mktemp "${TMPDIR:-/tmp}/hui-frame.XXXXXX" 2>/dev/null)
        HUI__DASH_PROG_LINE=$(mktemp "${TMPDIR:-/tmp}/hui-prog.XXXXXX" 2>/dev/null)
        : >| "${HUI__DASH_FRAME}.prev" 2>/dev/null

        # 前台这里 stdin 还是终端，先量一次交给后台渲染器
        HUI__SIZE_HINT=$(stty size < /dev/tty 2>/dev/null)
        [ -n "$HUI__SIZE_HINT" ] || HUI__SIZE_HINT=$(stty size 2>/dev/null)

        # 面板期间关掉终端回显：否则方向键/功能键的转义序列（^[[B 之类）
        # 会被 tty 驱动直接回显到屏幕上，糊在面板里
        HUI__TTY_SAVE=$(stty -g < /dev/tty 2>/dev/null)
        [ -n "${HUI__TTY_SAVE:-}" ] && stty -echo < /dev/tty 2>/dev/null

        HUI__RESTORED=0
        _hui_dash_cleanup() {
            rm -f "${HUI__STAT_FILE:-}" "${HUI__DASH_LEFT:-}" "${HUI__DASH_RTOP:-}" \
                "${HUI__DASH_TAIL:-}" "${HUI__DASH_PROD:-}" "${HUI__DASH_RECENT:-}" \
                "${HUI__DASH_NL:-}" "${HUI__DASH_PROG_LINE:-}" 2>/dev/null
            if [ -n "${HUI__DASH_FRAME:-}" ]; then
                rm -f "${HUI__DASH_FRAME}" "${HUI__DASH_FRAME}.prev" 2>/dev/null
            fi
            HUI__STAT_FILE=""
        }
        _hui_dash_restore() {
            [ "${HUI__RESTORED:-0}" = "1" ] && return 0
            HUI__RESTORED=1
            # 面板子进程必须收掉，否则它会变成孤儿继续往同一个终端画，
            # 下次构建再起一个面板就会「两块面板叠在一起」出现重复
            if [ -n "${dash:-}" ] && [ "$dash" -gt 1 ] 2>/dev/null; then
                kill -TERM "$dash" 2>/dev/null
            fi
            [ -n "${HUI__TTY_SAVE:-}" ] && stty "$HUI__TTY_SAVE" < /dev/tty 2>/dev/null
            # 面板期间 stderr 可能已重定向到 /dev/tty，统一走 stderr 收尾
            printf '\033[?25h\033[?1049l' >&2
        }
        # Ctrl-C：先收干净构建进程树，再收摊退出（rc=130），
        # 不要被当成「内存打爆」去自动重试
        local build_pid=""
        HUI__ABORTING=0
        _hui_dash_int() {
            [ "${HUI__ABORTING:-0}" = "1" ] && return 0
            HUI__ABORTING=1
            # 构建子 shell 是后台起的（SIGINT 会被忽略），Ctrl-C 只到 hui，
            # 必须显式收树，否则 Runa/make 的子进程会继续占着内存。
            if [ -n "${build_pid:-}" ]; then
                hui__reap_build_tree "$build_pid"
            fi
            _hui_dash_restore
            if [ -n "${dash:-}" ] && [ "$dash" -gt 1 ] 2>/dev/null; then
                kill -TERM "$dash" 2>/dev/null
            fi
            rm -f "${HUI__PSI_LOG:-}" 2>/dev/null
            _hui_dash_cleanup
            printf '\n%s[hui]%s 已中断，构建子进程已清理\n' \
                "$hui__c_yel" "$hui__c_rst" >&2
            exit 130
        }
        trap '_hui_dash_int' INT HUP TERM
        trap '_hui_dash_restore' EXIT
        printf '\033[?1049h\033[?25l\033[2J\033[H' >&2

        # 构图阶段没有执行器在跑，也没有可调的并发：起调速控制器只会写出没人读的文件
        if [ "$mode" != "graph" ]; then
            hui__runa_like "$phase_exec" || hui__ctrl_start
        fi
        hui__dash_loop "$label" "$jobs" "$log" &
        local dash=$!

        ( export NINJA_HIGHMEM_NUM_JOBS="${NINJA_HIGHMEM_NUM_JOBS:-$HUI_HIGHMEM_JOBS}"
          # ccache 直接命中模式：命中时跳过预处理器，增量编译明显更快
          # （AOSP 的 envsetup 默认关掉它；想关回来：export HUI_CCACHE_DIRECT=0）
          export CCACHE_DIRECT="${CCACHE_DIRECT:-${HUI_CCACHE_DIRECT:-1}}"
          # 满核构建但不抢前台：CPU/IO 优先级只降这个子 shell 这一支
          hui__lower_priority
          # 构图：只让 m 做 kati+soong 分析、写出三份图，不进编译。
          # 走和编译阶段同一套面板/日志/中断清理，只是面板切到「构图模式」。
          if [ "$mode" = "graph" ]; then
              hui__graph_ledger_guard m -j"$jobs" --skip-ninja "$@"
          else
              hui__m_run "$jobs" "$@"
          fi ) >| "$log" 2>&1 &
        build_pid=$!
        wait "$build_pid"
        local rc=$?
        build_pid=""

        kill -TERM "$dash" 2>/dev/null
        wait "$dash" 2>/dev/null
        dash=""
        hui__ctrl_stop
        _hui_dash_restore
        trap - EXIT INT TERM

        _hui_dash_cleanup

        local el=$(( $(date +%s) - HUI__PHASE_START ))
        HUI__LAST_SECONDS=$el

        # 把这次构建的并发/实测内存压力记下来，下次选 -j 时参考
        local pavg=0 pmax=0
        if [ -s "${HUI__PSI_LOG:-/dev/null}" ]; then
            read -r pavg pmax <<EOF
$(awk '{s+=$1; if($1>m)m=$1; n++} END{printf "%d %d", (n ? s/n : 0), m}' "$HUI__PSI_LOG")
EOF
        fi
        # 只有「跑完的成功构建」才拿去喂下次的并发决策：
        # 被中断 / 秒挂的短命构建 PSI 还没采到样，记进去会把统计带偏
        if [ "$rc" -eq 0 ] && [ "$el" -ge 60 ]; then
            printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
                "$(date '+%F %T')" "$jobs" "${pavg:-0}" "${pmax:-0}" "$el" "$rc" \
                >> "$(hui__perf_file)" 2>/dev/null
            tail -n 50 "$(hui__perf_file)" 2>/dev/null >| "$(hui__perf_file).tmp" 2>/dev/null
            mv -f "$(hui__perf_file).tmp" "$(hui__perf_file)" 2>/dev/null
        fi
        rm -f "${HUI__PSI_LOG:-}" 2>/dev/null
        if [ $rc -ne 0 ]; then
            printf '\n%s✗%s %s 失败 rc=%s · 用时 %02d:%02d:%02d\n' \
                "$hui__c_red" "$hui__c_rst" "$label" "$rc" \
                $((el / 3600)) $((el % 3600 / 60)) $((el % 60)) >&2
            hui__fail_report "$log"
        elif [ "${HUI__PHASE_QUIET_OK:-0}" != "1" ]; then
            printf '\n%s✓%s %s 完成 · 用时 %02d:%02d:%02d · 日志 %s\n' \
                "$hui__c_grn" "$hui__c_rst" "$label" \
                $((el / 3600)) $((el % 3600 / 60)) $((el % 60)) "$HUI__LOG_SHORT" >&2
        fi
        exit $rc
    )
}

hui__phase_banner() {
    local label=$1 jobs=$2; shift 2
    local snap; snap=$(hui__cache_latest 2>/dev/null)
    local snaptxt="无"; [ -n "$snap" ] && snaptxt=$(hui__short "$snap" 8)
    {
        printf '\n%s┌%s hui %s · %s / %s\n' "$hui__c_dim" "$hui__c_rst" "$HUI_VERSION" \
            "${HUI__PRODUCT:-${TARGET_PRODUCT:-?}}" "${TARGET_BUILD_VARIANT:-?}"
        if [ -n "${HUI__KS:-}" ]; then
            printf '%s│%s 内核   %s · 快照 %s\n' "$hui__c_dim" "$hui__c_rst" "$HUI__KS" "$snaptxt"
        else
            printf '%s│%s 内核   预编译\n' "$hui__c_dim" "$hui__c_rst"
        fi
        printf '%s│%s 阶段   %s → %s\n' "$hui__c_dim" "$hui__c_rst" "$label" "$*"
        if [ "${HUI__PHASE_MODE:-build}" = "graph" ]; then
            printf '%s│%s 并发   分析阶段：soong bootstrap 走 -j%s，kati/soong 串行\n' \
                "$hui__c_dim" "$hui__c_rst" "$jobs"
        else
            local minj; minj=$(hui__jobs_min)
            [ "$minj" -gt "$jobs" ] && minj=$jobs
            printf '%s│%s 并发   上限 %s（%s~%s，压力高时自动收）\n' "$hui__c_dim" "$hui__c_rst" \
                "$jobs" "$minj" "$jobs"
        fi
        printf '%s└%s 开始   %s\n\n' "$hui__c_dim" "$hui__c_rst" "$(date '+%H:%M:%S')"
    } >&2
}

hui__panel_line() {
    local avail_gb swap_gb score
    avail_gb=$(awk -v m="${HUI__AVAIL_MB:-0}" 'BEGIN{printf "%.1f", m/1024}')
    swap_gb=$(awk -v m="${HUI__SWAP_USED_MB:-0}" 'BEGIN{printf "%.1f", m/1024}')
    score=$(hui__pressure_score)
    printf '可用 %sG · swap %sG · 压力 %s%%' "$avail_gb" "$swap_gb" "$score"
}

hui__panel_loop() {
    local interval=${HUI_STATUS_INTERVAL:-15}
    local start=${HUI__PHASE_START:-$(date +%s)}
    local tgt="-" scr="-" parent=$PPID
    while :; do
        sleep "$interval"
        hui__parent_alive "$parent" || exit 0
        [ "$PPID" = "$parent" ] || exit 0
        [ -t 2 ] || exit 0
        if [ -n "${HUI__STAT_FILE:-}" ] && [ -f "$HUI__STAT_FILE" ]; then
            read -r tgt scr < "$HUI__STAT_FILE" 2>/dev/null || true
        fi
        [ "$tgt" = "-" ] && tgt=${HUI__JOBS_MAX:--}
        local t=$(( $(date +%s) - start ))
        hui__mem_sample
        if [ "${HUI__PHASE_MODE:-build}" = "graph" ]; then
            printf '%s[hui]%s %02d:%02d:%02d · 构图（kati+soong 分析，无编译进度）· %s\n' \
                "$hui__c_dim" "$hui__c_rst" \
                $((t / 3600)) $((t % 3600 / 60)) $((t % 60)) "$(hui__panel_line)" >&2
            continue
        fi
        printf '%s[hui]%s %02d:%02d:%02d · 并发 %s/%s · %s\n' \
            "$hui__c_dim" "$hui__c_rst" \
            $((t / 3600)) $((t % 3600 / 60)) $((t % 60)) \
            "${tgt:--}" "${HUI__JOBS_MAX:-?}" "$(hui__panel_line)" >&2
    done
}

# ---------------------------------------------------------------------------
# 构建图复用
#
# AOSP 的 m 每次都要跑 ckati + soong_build 重新生成 ninja 图，这棵树上是
# 12 分钟起步。如果图已经生成、而且输入没变，就没有理由再跑一遍：
#   1. 校验：Android.bp/.mk/glob/环境/产品变体 全部对得上
#   2. 用 siso 直接吃 out/combined-<product>.ninja（这里自己拼一份带 kati 的）
# 校验不做"大概齐"：任何一项拿不准就回退到完整 m，绝不拿旧图硬编。
# ---------------------------------------------------------------------------

hui__graph_mtime() {
    local out=${OUT_DIR:-out} f
    f="$HUI_TOP/$out/build-$HUI__PRODUCT.ninja"
    [ -f "$f" ] || f="$HUI_TOP/$out/soong/build.$HUI__PRODUCT.ninja"
    stat -c '%y' "$f" 2>/dev/null | cut -d. -f1
}

hui__graph_verify() {
    HUI__GRAPH_WHY=""
    local out=${OUT_DIR:-out}
    [ -s "$HUI_TOP/$out/soong/build.$HUI__PRODUCT.ninja" ] || { HUI__GRAPH_WHY="soong 图缺失"; return 1; }
    [ -s "$HUI_TOP/$out/build-$HUI__PRODUCT.ninja" ] || { HUI__GRAPH_WHY="kati 图缺失"; return 1; }
    [ -s "$HUI_TOP/$out/build-$HUI__PRODUCT-package.ninja" ] || { HUI__GRAPH_WHY="打包图缺失"; return 1; }
    if [ ! -f "$HUI_TOP/$out/siso_config/main.star" ] && ! hui__runa_ok; then
        HUI__GRAPH_WHY="siso 配置缺失（还没跑过完整构建）"; return 1
    fi
    command -v python3 >/dev/null 2>&1 || { HUI__GRAPH_WHY="没有 python3，跳过图复用"; return 1; }

    local res rc
    res=$(python3 - "$HUI_TOP" "$HUI__PRODUCT" "${TARGET_BUILD_VARIANT:-}" "$out" <<'PY' 2>/dev/null
import glob as pyglob
import json
import os
import re
import subprocess
import sys

TOP = os.path.abspath(sys.argv[1])
PRODUCT = sys.argv[2]
VARIANT = sys.argv[3] if len(sys.argv) > 3 else ""
OUT = sys.argv[4] if len(sys.argv) > 4 else "out"


def p(rel):
    return rel if rel.startswith("/") else TOP + "/" + rel


def mt(rel):
    try:
        return os.stat(p(rel)).st_mtime_ns
    except OSError:
        return None


def sz(rel):
    try:
        return os.path.getsize(p(rel))
    except OSError:
        return -1


def stale(msg):
    print("STALE " + msg)
    sys.exit(1)


def main():
    soong = OUT + "/soong/build." + PRODUCT + ".ninja"
    kati = OUT + "/build-" + PRODUCT + ".ninja"
    pkg = OUT + "/build-" + PRODUCT + "-package.ninja"
    stamp = OUT + "/.kati_stamp-" + PRODUCT
    globs = soong + ".globs"
    globs_time = soong + ".globs_time"
    depfile = soong + ".d"
    usedenv = OUT + "/soong/soong.environment.used." + PRODUCT + ".build"

    for x in (soong, kati, pkg, stamp, globs, globs_time, depfile):
        if mt(x) is None:
            stale("缺少 " + x)
        if sz(x) == 0:
            stale("空文件 " + x)

    soong_ns = mt(soong)
    kati_ns = mt(kati)

    # soong 主图会 subninja 分片，少一个 siso 就起不来
    with open(p(soong), "rb") as f:
        head = f.read(2 * 1024 * 1024).decode("utf-8", "replace")
    for sub in re.findall(r"^subninja (\S+)\s*$", head, re.M):
        if mt(sub) is None:
            stale("缺少分片 " + sub)

    # Android.bp：soong_build 自己写的 depfile 就是最准的输入清单
    try:
        raw = open(p(depfile), "r", encoding="utf-8", errors="replace").read()
    except OSError as e:
        stale("读不了 depfile: %s" % e)
    raw = raw.replace("\\\n", " ")
    toks = raw.split()
    deps = [t for t in toks[1:] if t and not t.endswith(":")]
    if not deps:
        stale("depfile 里没有依赖")
    for d in deps:
        st = mt(d)
        if st is None:
            stale("Android.bp 缺失: " + d)
        if st > soong_ns:
            if d.endswith("Android.bp.list"):
                stale("模块清单变了（新增/删除了 Android.bp），需要重分析")
            # out/ 里是构建自己生成的产品配置，mtime 本来就可能比图新；
            # 源侧变化由上面的 .mk/Android.bp 扫描和 kati 环境检查负责
            if d == OUT or d.startswith(OUT + "/"):
                continue
            stale("Android.bp 比图新: " + d)

    # 源文件 glob：只重跑目录 mtime 变了的那些，结果一致就继续
    def read_varint(f):
        shift = 0
        res = 0
        while True:
            b = f.read(1)
            if not b:
                raise EOFError
            b = b[0]
            res |= (b & 0x7F) << shift
            shift += 7
            if not (b & 0x80):
                return (res >> 1) ^ -(res & 1)

    def read_str(f):
        n = read_varint(f)
        return f.read(n).decode("utf-8", "replace")

    def read_list(f):
        n = read_varint(f)
        return [read_str(f) for _ in range(n)] if n else []

    gt = int(open(p(globs_time)).read().strip())
    changed = []
    with open(p(globs), "rb") as f:
        if f.read(26) != b"Soong glob file version 1\n":
            stale("globs 版本不认，重新分析")
        n = read_varint(f)
        for _ in range(n):
            pat = read_str(f)
            exc = read_list(f)
            mat = read_list(f)
            deps2 = read_list(f)
            hit = False
            for d in deps2:
                st = mt(d)
                if st is None or st // 1000 > gt:
                    hit = True
                    break
            if hit:
                changed.append((pat, exc, mat))

    for pat, exc, mat in changed:
        if exc:
            stale("glob 带 exclude 且目录变了: " + pat)
        if any(c in pat for c in "*?["):
            try:
                got = pyglob.glob(p(pat), recursive=True, include_hidden=True)
            except TypeError:
                got = pyglob.glob(p(pat), recursive=True)
            got = [os.path.relpath(g, TOP) for g in got]
            got = [g + "/" if os.path.isdir(p(g)) else g for g in got]
            got.sort()
            if got != sorted(mat):
                stale("glob 结果变了: " + pat)
        else:
            if os.path.exists(p(pat)):
                got = [pat + "/" if os.path.isdir(p(pat)) else pat]
            else:
                got = []
            if got != mat:
                # out/ 下的字面路径是构建自己的产物。典型：BOARD_PREBUILT_DTBOIMAGE
                # 指向 obj/DTBO_OBJ/.../dtbo.img —— 图生成时还没编内核（产物不存在），
                # 之后内核阶段才落盘。这种「产物新出现」不该让整张图作废：执行器按旧图
                # 照样会把它编出来。只有产物「消失」才可能让图里引用的 prebuilt 悬空，
                # 那种仍然判失效。
                if (pat == OUT or pat.startswith(OUT + "/")) and not mat and got:
                    continue
                stale("文件出现/消失: " + pat)

    # soong 编译环境：只比用户显式设置过的变量，避免把 soong_ui 算出来的默认值当变化
    ignore_env = {
        "ANDROID_JAVA_HOME", "ANDROID_JAVA8_HOME", "CC_WRAPPER", "CXX_WRAPPER",
        "CCACHE_EXEC", "OUT_DIR", "BUILD_DATETIME_FILE", "SOONG_GENERATES_NINJA_HINT",
        "TMPDIR", "PWD", "HOME", "PATH", "SHELL", "USER", "LOGNAME",
    }
    try:
        used = json.load(open(p(usedenv), encoding="utf-8"))
    except Exception as e:
        stale("读不了 soong used env: %s" % e)
    for item in used:
        k = item.get("Key", "")
        v = item.get("Value", "")
        if k in ignore_env or not k:
            continue
        cur = os.environ.get(k, "")
        # 只比"当前 shell 真的设了值"的变量：soong_ui 自己算出来的默认值
        # （ANDROID_JAVA_HOME/CC_WRAPPER 之类）在 shell 里可能没有，不能算变化
        if cur and cur != v:
            stale("构建环境变了 %s=%r（图里是 %r）" % (k, cur, v))

    # kati：stamp 里记录过的 makefile 不能少、不能比图新
    ckati = TOP + "/prebuilts/build-tools/linux-x86/bin/ckati"
    try:
        files = subprocess.run(
            [ckati, "--dump_stamp_tool", "--files", p(stamp)],
            capture_output=True, text=True, timeout=30,
        ).stdout.splitlines()
    except Exception as e:
        stale("ckati dump 失败: %s" % e)
    for x in files:
        rel = os.path.relpath(p(x), TOP)
        if rel == OUT or rel.startswith(OUT + "/"):
            continue  # out/ 里是构建自己生成的，源侧改动由下面的扫描负责
        st = mt(x)
        if st is None:
            stale("makefile 缺失: " + x)
        if st > kati_ns:
            stale("makefile 比图新: " + x)

    # 源侧定义文件：改过/新加的 .mk、Android.bp 都算
    try:
        hit = subprocess.run(
            ["find", TOP,
             "-path", p(OUT), "-prune", "-o",
             "-path", TOP + "/.repo", "-prune", "-o",
             "-path", TOP + "/.git", "-prune", "-o",
             "(", "-name", "*.mk", "-newer", p(kati), "-o",
             "-name", "Android.bp", "-newer", p(soong), ")",
             "-print", "-quit"],
            capture_output=True, text=True, timeout=120,
        ).stdout.strip()
    except Exception as e:
        stale("构建定义扫描失败: %s" % e)
    if hit:
        stale("构建定义比图新: " + hit)

    # 构建系统自身源码变了，图也可能过时。
    # 只看真正参与分析的代码：build/soong、build/blueprint 的 Go 源码
    # （编译进 soong_build）；build/make 里排除 tools/、scripts/ —— 那些是
    # 构建期脚本（gen_build_prop.py、releasetools 之类），改它们不影响 ninja 图，
    # 以前用 `-newer kati` 全扫会把这类改动误判成「构建工具源码变了」。
    # build/make 的 .mk / 全树的 Android.bp 已经由上面的扫描覆盖。
    scans = [
        ["find", TOP + "/build/soong", TOP + "/build/blueprint",
         "-type", "f", "-name", "*.go", "-newer", p(kati), "-print", "-quit"],
        ["find", TOP + "/build/make",
         "-path", "*/tools", "-prune", "-o", "-path", "*/scripts", "-prune", "-o",
         "-type", "f", "-newer", p(kati), "-print", "-quit"],
    ]
    for cmd in scans:
        try:
            hit = subprocess.run(cmd, capture_output=True, text=True, timeout=60).stdout.strip()
        except Exception as e:
            stale("构建工具扫描失败: %s" % e)
        if hit:
            stale("构建工具源码变了: " + hit)

    # 图里的产品/变体/OUT_DIR 必须和这次 lunch 一致
    cmd = ("exec '%s' --dump_stamp_tool --env '%s' | "
           "grep -aE '^(TARGET_PRODUCT|TARGET_BUILD_VARIANT|OUT_DIR|TARGET_RELEASE|WITH_GMS|SOONG_ONLY): '"
           % (ckati, p(stamp)))
    try:
        dump = subprocess.run(cmd, shell=True, capture_output=True, text=True, timeout=60).stdout
    except Exception as e:
        stale("读 kati 环境失败: %s" % e)
    envmap = {}
    for line in dump.splitlines():
        if ": " in line:
            k, v = line.split(": ", 1)
            envmap[k] = v
    if not envmap.get("TARGET_PRODUCT"):
        stale("图里读不到 TARGET_PRODUCT")
    checks = {"TARGET_PRODUCT": PRODUCT, "OUT_DIR": OUT}
    if VARIANT:
        checks["TARGET_BUILD_VARIANT"] = VARIANT
    for k, v in checks.items():
        got = envmap.get(k)
        if got is not None and got != v:
            stale("环境不匹配 %s=%s（图里是 %s）" % (k, v, got))
    for k in ("TARGET_RELEASE", "WITH_GMS", "SOONG_ONLY"):
        got = envmap.get(k)
        cur = os.environ.get(k, "")
        if got is not None and cur and got != cur:
            stale("环境不匹配 %s=%s（图里是 %s）" % (k, cur, got))

    # 分析用的 soong_build 要是重新编译过，也必须重跑分析
    sb = mt(OUT + "/host/linux-x86/bin/soong_build")
    if sb is not None and sb > soong_ns:
        stale("soong_build 比图新")

    print("OK")


try:
    main()
except SystemExit:
    raise
except Exception as e:
    print("ERR %s: %s" % (type(e).__name__, e))
    sys.exit(2)
PY
)
    rc=$?
    case "$res" in
        OK) return 0 ;;
        "STALE "*) HUI__GRAPH_WHY=${res#STALE }; return 1 ;;
        "ERR "*)   HUI__GRAPH_WHY=${res#ERR }; return 1 ;;
        *)         HUI__GRAPH_WHY=${res:-"校验脚本异常（rc=$rc）"}; return 1 ;;
    esac
}

# 自己拼一份 combined ninja：soong_ui 的 --config-only 会把 kati 图丢掉，
# 所以不能靠它，得保留 kati + package + soong 三份
hui__siso_combined() {
    local out=${OUT_DIR:-out} f product src depth
    product=${HUI__PRODUCT:-${TARGET_PRODUCT:-}}
    [ -n "$product" ] || return 1
    f="$HUI_TOP/$out/.hui-combined.$product.ninja"
    depth=${HUI_HIGHMEM_JOBS:-3}
    src="$HUI_TOP/$out/combined-$product.ninja"
    # 优先复用 soong 的 combined（保留 dist/distdir 等顶层变量），
    # 只把 highmem_pool 的 depth 换成这一阶段算出来的值。
    if [ -f "$src" ]; then
        awk -v d="$depth" '
            /^pool[[:space:]]+highmem_pool[[:space:]]*$/ { print; want = 1; next }
            want && /^[[:space:]]*depth[[:space:]]*=/ { print " depth = " d; want = 0; next }
            { print }
        ' "$src" >| "$f" 2>/dev/null && [ -s "$f" ] && return 0
    fi
    {
        printf 'builddir = %s\n' "$out"
        printf 'pool highmem_pool\n depth = %s\n\n' "$depth"
        printf 'subninja %s/build-%s.ninja\n' "$out" "$product"
        printf 'subninja %s/build-%s-package.ninja\n' "$out" "$product"
        printf 'subninja %s/soong/build.%s.ninja\n' "$out" "$product"
    } >| "$f" 2>/dev/null || return 1
    return 0
}

hui__siso_run() {
    local jobs=$1; shift
    local out=${OUT_DIR:-out} product siso="$HUI_TOP/prebuilts/siso/linux-x86/siso"
    product=${HUI__PRODUCT:-${TARGET_PRODUCT:-}}
    [ -n "$product" ] || { hui__err "认不出产品，无法复用构建图"; return 127; }
    [ -x "$siso" ] || { hui__err "缺少 $siso"; return 127; }
    [ -f "$HUI_TOP/$out/siso_config/main.star" ] || {
        hui__err "缺少 $out/siso_config，先完整跑一次 m"
        return 127
    }
    hui__siso_combined || { hui__err "写不了 $out/.hui-combined.$product.ninja"; return 127; }
    (
        export NINJA_HIGHMEM_NUM_JOBS="${NINJA_HIGHMEM_NUM_JOBS:-${HUI_HIGHMEM_JOBS:-3}}"
        export CCACHE_DIRECT="${CCACHE_DIRECT:-${HUI_CCACHE_DIRECT:-1}}"
        # 同 hui__runa_run：直连执行器要自己补 OUT_DIR，soong_ui 才会设。
        export OUT_DIR="${out%/}"
        export SISO_EXPERIMENTS="${SISO_EXPERIMENTS:-ignore-missing-out-in-depfile,allow-unexpected-rsp-remove,oom-score-adj}"
        export TMPDIR="$HUI_TOP/$out/soong/.temp"
        mkdir -p "$TMPDIR" 2>/dev/null
        export PATH="$HUI_TOP/prebuilts/build-tools/path/linux-x86:$HUI_TOP/$out/.path:$PATH"
        cd "$HUI_TOP" || return 1
        "$siso" ninja \
            -d keepdepfile -d keeprsp \
            --local_jobs "$jobs" \
            --log_dir "$out" \
            --config_repo_dir="$out/siso_config" \
            -f "$out/.hui-combined.$product.ninja" \
            "$@"
    )
}

# 直连执行器读不动构建图时，回退完整 m 一次
hui__siso_bad_graph() {
    tail -c 200000 "$HUI_TOP/${OUT_DIR:-out}/siso_output" 2>/dev/null |
        grep -qiE 'failed to load|failed to parse|no rule to make target|unknown target|manifest'
}

hui__runa_bad_graph() {
    local f=${HUI__LOG_FILE:-}
    [ -n "$f" ] && [ -f "$f" ] || return 1
    tail -c 200000 "$f" 2>/dev/null |
        grep -qiE "loading .*ninja|no rule to make target|unknown target|duplicate pool|failed to parse"
}

# Runa：启动时把 -j 设成硬上限（ceiling），真正的并发由控制文件动态决定。
# 改文件只影响还没启动的任务，运行中的编译器不会被中断。
hui__runa_run() {
    local jobs=$1; shift
    local out=${OUT_DIR:-out} product runa ceiling dir file rc
    product=${HUI__PRODUCT:-${TARGET_PRODUCT:-}}
    [ -n "$product" ] || { hui__err "认不出产品，无法复用构建图"; return 127; }
    # 进执行器之前最后确认一次账本：前面不管是构图、裸 m 还是别的 shell 动过它，
    # 只要 .hui 里还有 v6 备份就回滚 —— 否则这里一启动就是 22 万条边全量。
    hui__ledger_restore
    case "$(printf '%s' "${HUI_EXECUTOR:-auto}" | tr 'A-Z' 'a-z')" in
        runa|runa-ninja) runa=$(hui__runa_only_bin) ;;
        *)               runa=$(hui__runa_bin) ;;
    esac
    [ -n "$runa" ] || { hui__err "缺少执行器：prebuilts/hui/hui 和 prebuilts/runa/runa 都不可用"; return 127; }
    ceiling=${HUI_RUNA_CEILING:-$(hui__jobs_max)}
    case "$ceiling" in ''|*[!0-9]*) ceiling=$jobs ;; esac
    [ "$ceiling" -lt "$jobs" ] && ceiling=$jobs
    # 合并图：有 soong 的 combined 就复制并替换 highmem_pool depth，
    # 没有就自己拼；这样运行中算出的池子才能真正生效。
    hui__siso_combined || { hui__err "写不了 $out/.hui-combined.$product.ninja"; return 127; }
    local combined="$out/.hui-combined.$product.ninja"
    local adopt=${HUI_RUNA_ADOPT:-0}
    case "$adopt" in 1|true|yes|on) adopt=1 ;; *) adopt=0 ;; esac
    if [ "$adopt" = "0" ]; then
        case "$(printf '%s' "${HUI_EXECUTOR:-auto}" | tr 'A-Z' 'a-z')" in
            runa)
                # 显式切 Runa、树里是 siso 状态、Runa 还没有自己的日志：
                # 用 assumeexisting 接管已有输出，避免全量重编。
                if [ -e "$HUI_TOP/$out/.siso_deps" ] && [ ! -e "$HUI_TOP/$out/.ninja_log" ]; then
                    adopt=1
                fi ;;
        esac
    fi
    [ "$adopt" = "1" ] && hui__warn "Runa 首次接管：-d assumeexisting（信任磁盘已有输出，不重编）"
    dir=$(mktemp -d "${TMPDIR:-/tmp}/hui-admit.XXXXXX") || return 127
    file="$dir/jobs"
    printf '%s\n' "$jobs" >| "$file" 2>/dev/null || { rm -rf "$dir"; return 127; }
    hui__admit_start "$file" "$jobs" "$ceiling"
    (
        export NINJA_HIGHMEM_NUM_JOBS="${NINJA_HIGHMEM_NUM_JOBS:-${HUI_HIGHMEM_JOBS:-3}}"
        export CCACHE_DIRECT="${CCACHE_DIRECT:-${HUI_CCACHE_DIRECT:-1}}"
        # soong_ui 会给动作环境补 OUT_DIR；直连执行器绕过了它，得自己补，
        # 否则 gen_build_prop.py 会 startswith(None) 崩掉（odm-build.prop 失败）。
        export OUT_DIR="${out%/}"
        hui__pools_export "$jobs"
        export TMPDIR="$HUI_TOP/$out/soong/.temp"
        mkdir -p "$TMPDIR" 2>/dev/null
        export PATH="$HUI_TOP/prebuilts/build-tools/path/linux-x86:$HUI_TOP/$out/.path:$PATH"
        cd "$HUI_TOP" || exit 1
        hui__lower_priority
        # 只有支持 --duration-file 的执行器才传（Runa 不认识这个参数）
        local dur_args=() dur_file
        if [ -z "${HUI__DUR_OK:-}" ]; then
            if "$runa" --help 2>&1 | grep -q -- '--duration-file'; then
                HUI__DUR_OK=1
            else
                HUI__DUR_OK=0
            fi
        fi
        if [ "$HUI__DUR_OK" = "1" ]; then
            hui__durations_build
            dur_file=$(hui__durations_file)
            [ -n "$dur_file" ] && dur_args=(--duration-file "$dur_file")
        fi
        if [ "$adopt" = "1" ]; then
            "$runa" -f "$combined" \
                -j "$ceiling" --parallelism-file "$file" "${dur_args[@]}" \
                -d keepdepfile -d keeprsp -d assumeexisting "$@"
        else
            "$runa" -f "$combined" \
                -j "$ceiling" --parallelism-file "$file" "${dur_args[@]}" \
                -d keepdepfile -d keeprsp "$@"
        fi
    )
    rc=$?
    hui__admit_stop
    rm -rf "$dir"
    return $rc
}

# 增量账本（.ninja_log）版本和执行器不匹配时提前预警：
# 原生 ninja（AOSP 自带 1.9）写 v5，自建 hui（1.12.1）写 v6，
# 读到旧版本会 "starting over"，等于全量重建。
hui__ninja_log_guard() {
    local log v exe
    log=$(hui__ninja_log)

    # 账本可能在上一次构图（soong bootstrap 走 siso）或任何一次裸 m 里被
    # 截成 v5 头 —— 那种情况下自建执行器会 "starting over"，整树重编。
    # 只要 .hui 里还留着 v6 备份，这里就把它捡回来。
    hui__ledger_restore

    [ -s "$log" ] || return 0
    v=$(hui__ledger_version "$log" 2>/dev/null)
    [ -n "$v" ] || return 0
    exe=$(hui__executor)
    case "$exe" in
        hui|runa)
            [ "$v" -ge 6 ] && return 0
            hui__warn "增量账本是 v$v，自建执行器写 v6：这次会被当成全量重建（约 2~3 小时）"
            hui__dim "  .hui 里没有可用的 v6 备份，只能全量一次；编完会自动留一份给下次"
            hui__dim "  想保留现有增量：HUI_EXECUTOR=m hui build；长期用同一个执行器最稳"
            ;;
    esac
    return 0
}

# ---------------------------------------------------------------------------
# 构图阶段的账本保护
#
# hui 构图走 `m --skip-ninja`。soong 需要重新生成图时会先跑 bootstrap，
# 这棵树默认用 siso 做 bootstrap，而 siso 收尾会把 out/.ninja_log 重写成 v5。
# 自建执行器（ninja 1.12.1）只认 v6，读到 v5 会 unlink 账本，下一轮所有
# 非 generator 边都“command line not found in log”，整棵树重编。
# 构图只生成图、不动编译产物，所以在构图前备份 v6 账本、构图后恢复即可。
# HUI_STATE 允许是相对路径（help 里写 .hui）。统一解析到 tree 根目录下，
# 避免从子目录调用 hui 时把备份/Ctrl 日志写到没人看的地方。
hui__state_dir() {
    local d=${HUI_STATE:-.hui}
    case "$d" in
        /*) printf '%s' "$d" ;;
        *)  printf '%s' "${HUI_TOP:-.}/$d" ;;
    esac
}

hui__ledger_backup_path() {
    printf '%s' "$(hui__state_dir)/.ninja_log.v6-backup"
}

hui__ledger_version() {
    local f=$1 v
    [ -s "$f" ] || return 1
    v=$(head -n 1 "$f" 2>/dev/null | sed -n 's/^# ninja log v\([0-9][0-9]*\)$/\1/p')
    [ -n "$v" ] && printf '%s' "$v"
}

# 「好账本」常驻备份：当前是 v6 就刷新一份到 .hui（内容没变就跳过）。
# 以前的备份只活在「构图前 → 构图后」这一小段里，构图结束就删；于是
#   ① 构图前账本已经被别的东西（裸 m / 上次被 Ctrl-C 的 siso）截成 v5 时没得救；
#   ② 构图之后隔了一个 shell 再构建，备份早没了。
# 现在备份跨命令、跨 shell 都留着，任何一次 hui 构建开跑前都能回滚。
hui__ledger_sync() {
    local log bak
    log=$(hui__ninja_log)
    bak=$(hui__ledger_backup_path)
    [ "$(hui__ledger_version "$log" 2>/dev/null)" = "6" ] || return 1
    mkdir -p -- "${bak%/*}" 2>/dev/null
    cmp -s -- "$log" "$bak" 2>/dev/null && return 0
    cp -f -- "$log" "$bak" 2>/dev/null
}

# 账本不是 v6（被 siso / ninja 1.9 截成 v5 头，或者干脆被删）时用备份回滚。
# 返回 0 = 现在账本是 v6（本来就是，或刚恢复好）；1 = 没有可用的 v6 备份。
# 真回滚过会把 HUI__LEDGER_RESTORED 置 1（调用方在子 shell 里也能用来决定提示）。
hui__ledger_restore() {
    local log bak v bv
    log=$(hui__ninja_log)
    bak=$(hui__ledger_backup_path)
    v=$(hui__ledger_version "$log" 2>/dev/null)
    [ "$v" = "6" ] && return 0
    bv=$(hui__ledger_version "$bak" 2>/dev/null)
    [ "$bv" = "6" ] || return 1
    cp -f -- "$bak" "$log" 2>/dev/null || return 1
    HUI__LEDGER_RESTORED=1
    hui__warn "增量账本被写成 v${v:-?}（siso / ninja 1.9 的副作用），已用 .hui 备份恢复 v6 —— 本次不会全量"
    return 0
}

hui__ledger_restored_mark() {
    printf '%s' "${HUI_STATE:-$HUI_TOP/.hui}/.ledger-restored"
}

hui__graph_ledger_guard() {
    local log rc
    log=$(hui__ninja_log)

    # 构图前：把当前 v6 账本刷进常驻备份（账本已经是 v5 的话 sync 会失败，
    # 这时反而是上一份备份更值钱，不能删）。
    hui__ledger_sync

    # 别让 soong 用 siso 跑 bootstrap：siso 开跑就截断 out/.ninja_log，
    # 只写它自己那几百条 bootstrap 记录（hash 还是另一套算法），
    # 主账本 22 万条记录当场就没了。
    # 换成 AOSP 自带的 ninja 1.9：实测它读 v6 账本不检查版本、原样保留、
    # 只往后追加新条目，构图结束账本还是 v6，执行器直接增量。
    # 想回到 siso：HUI_GRAPH_SISO=1。
    if [ "${HUI_GRAPH_SISO:-0}" != "1" ]; then
        export SOONG_NINJA=ninja
    fi

    HUI__LEDGER_RESTORED=0
    "$@"
    rc=$?

    # 兜底：万一构图还是把账本改成了 v5（比如 ninja 侧发生 recompact），
    # 就用 v6 备份回滚。构图只生成图、不动产物，回滚是安全的。
    if hui__ledger_restore; then
        # 构图在面板子 shell 里跑，这里打的字只会落进阶段日志；
        # 留个标记，让主流程回终端补一句。
        if [ "${HUI__LEDGER_RESTORED:-0}" = "1" ]; then
            : >| "$(hui__ledger_restored_mark)" 2>/dev/null
        fi
    else
        printf '%s[hui]%s 构图把增量账本改成了 v%s，且 .hui 里没有 v6 备份 —— 这次构建会全量\n' \
            "$hui__c_yel" "$hui__c_rst" "$(hui__ledger_version "$log" 2>/dev/null || echo '?')" >&2
    fi
    return $rc
}

# 阶段完成提示：右上 PHASE 逐段追加（构建图完成 / 内核完成 / ROM完成）
hui__phase_done() {
    case " ${HUI__PHASE_STATE:-} " in
        *" $1 "*) return 0 ;;
    esac
    HUI__PHASE_STATE="${HUI__PHASE_STATE:+$HUI__PHASE_STATE · }$1"
}
# 所有阶段统一从这里起构建：图验证过就直接用执行器，否则老老实实 m。
# AOSP/Lineage 没有 siso 也能走 Runa；已经用 siso 建过的树继续 siso。
hui__m_run() {
    local jobs=$1; shift
    local exe rc
    if [ "${HUI__M_FAST:-0}" = "1" ] && [ "${HUI_GRAPH_REUSE:-1}" != "0" ] \
       && [ "${USE_RBE:-false}" != "true" ] && [ "${USE_RBE:-0}" != "1" ]; then
        exe=$(hui__executor)
        case "$exe" in
            runa|hui)
                if hui__runa_ok && hui__graph_files; then
                    hui__runa_run "$jobs" "$@"
                    rc=$?
                    if [ $rc -ne 0 ] && hui__runa_bad_graph; then
                        hui__warn "Runa 读不动构建图 → 回退完整 m（会重跑分析）"
                        m -j"$jobs" "$@"
                        return $?
                    fi
                    return $rc
                fi
                ;;
            siso)
                if [ -x "$HUI_TOP/prebuilts/siso/linux-x86/siso" ] \
                   && [ -f "$HUI_TOP/${OUT_DIR:-out}/siso_config/main.star" ]; then
                    hui__siso_run "$jobs" "$@"
                    rc=$?
                    if [ $rc -ne 0 ] && hui__siso_bad_graph; then
                        hui__warn "直连 siso 读不动构建图 → 回退完整 m（会重跑分析）"
                        m -j"$jobs" "$@"
                        return $?
                    fi
                    return $rc
                fi
                ;;
        esac
    fi
    # Runa 是 ninja 分支，能直接读 ninja 的 .ninja_log/.ninja_deps。
    # 如果首构建让 soong 默认走 siso，会留下 Runa 读不了的增量状态，
    # 之后 auto 只能一直 siso。所以选了 Runa 且树里还没有 siso 状态时，
    # 首构建显式用 ninja，第二次构建起由 Runa 接管。
    if hui__runa_like && [ ! -e "$HUI_TOP/${OUT_DIR:-out}/.siso_deps" ]; then
        export SOONG_NINJA=ninja
    fi
    m -j"$jobs" "$@"
}

# 内核目标：Lineage 系有独立 dtbo/dtb 目标。
# 开始前清完成标记，整段成功后才写——中断/失败不会留下「已编完」的假象。
hui__run_kernel_phase() {
    local label=$1 jobs=$2; shift 2
    local po rc
    po=$(hui__prodout "$HUI__PRODUCT")
    hui__kdone_clear "$po"
    if [ -f "$HUI_TOP/vendor/lineage/build/tasks/kernel.mk" ]; then
        hui__run_phase_retry "$label" "$jobs" kernel dtboimage dtbimage "$@"
    else
        hui__run_phase_retry "$label" "$jobs" kernel "$@"
    fi
    rc=$?
    if [ "$rc" -eq 0 ]; then
        # 整理 mtime + 写完成标记（标记里记的是 Image 的 mtime）
        hui__kernel_tidy "$po" || hui__warn "内核完成但写完成标记失败，hui save 会拒绝保存"
    fi
    return "$rc"
}

# 内核产物的 mtime 整理（只动 mtime，不动内容）。
# Lineage 的 kernel.mk 依赖链：
#   $(KERNEL_CONFIG): $(KERNEL_OUT) $(ALL_KERNEL_DEFCONFIG_SRCS)
#   $(TARGET_PREBUILT_INT_KERNEL): $(KERNEL_CONFIG) ... $(KERNEL_MODULES_PARTITION_FILE_LIST)
# 而内核构建自己会在 Image 之后继续改这些输入（Kbuild 收尾重写 .config、
# 拷贝/打包规则重写 file_list）。内核阶段一结束，紧随其后的第二次 m（ROM 阶段）
# 就会认为 config/Image 都过期，重跑 config + full-LTO 链接，和 ROM 编译并发
# 抢内存 —— 实测被 OOM kill（make: Error 137，ld.lld 45G VM）。
# 这里按依赖顺序把内核产物 mtime 抬到当前，第二次 m 就会认定内核已是最新。
hui__kernel_freshen() {
    local po=${1:-$(hui__prodout "$HUI__PRODUCT")} ka d f
    [ -n "${HUI__KS:-}" ] || return 0
    [ -d "$po/obj" ] || return 0
    ka=${HUI__KA:-arm64}
    for d in "$po/obj/KERNEL_OBJ" "$po/obj/DTBO_OBJ" "$po/obj/DTB_OBJ"; do
        [ -d "$d" ] || continue
        # 先 config：它的输入是 KERNEL_OUT 目录本身，目录 mtime 会比 config 新
        [ -f "$d/.config" ] && touch -- "$d/.config" 2>/dev/null
        # 再镜像：config 和 file_list 都是它的输入
        [ -d "$d/arch/$ka/boot" ] || continue
        while IFS= read -r f; do
            [ -n "$f" ] && touch -- "$f" 2>/dev/null
        done <<EOF
$(find "$d/arch/$ka/boot" -maxdepth 1 -type f 2>/dev/null)
EOF
    done
    # 最后是 $po 下的安装拷贝（它们依赖上面的镜像）
    for f in "$po/kernel" "$po/dtbo.img" "$po/dtb.img"; do
        [ -e "$f" ] && touch -- "$f" 2>/dev/null
    done
    return 0
}

# ninja 判定「输出过期」有两条规则（src/graph.cc RecomputeOutputDirty）：
#   1) 输出 mtime 比最近输入旧；
#   2) .ninja_log 里记录的该输出时间（entry->mtime）比最近输入旧 —— 即使
#      磁盘上的输出已经被 touch 新了，只要 log 里还是旧时间，照样判 dirty。
# 内核阶段刚编完，Kernel.mk 的收尾还会写新 .config / file_list，所以 ROM 阶段
# 第二次 m 会重编内核。这里只把 **内核产物** 对应的 log 记录时间改成当前
# （其它条目不动）：之后内核源码再变，输入 mtime 超过当前时间，照样会触发重编。
hui__ninja_log_restat_kernel() {
    local po=${1:-$(hui__prodout "$HUI__PRODUCT")}
    local log; log=$(hui__ninja_log)
    [ -s "$log" ] || return 0
    command -v python3 >/dev/null 2>&1 || return 0
    local now top dev
    now=$(date +%s%N)
    top=${HUI_TOP:-.}
    dev=${po##*/}
    python3 - "$top" "$log" "$now" "${OUT_DIR:-out}" "$dev" <<'PY' || return 0
import os, sys
TOP, LOG, NOW, OUT, DEV = sys.argv[1:6]
prod = os.path.join(TOP, OUT, "target/product", DEV)
prefixes = [
    os.path.join(prod, "obj/KERNEL_OBJ"),
    os.path.join(prod, "obj/DTBO_OBJ"),
    os.path.join(prod, "obj/DTB_OBJ"),
    os.path.join(prod, "kernel"),
    os.path.join(prod, "dtbo.img"),
    os.path.join(prod, "dtb.img"),
]
def hit(p):
    a = p if p.startswith("/") else os.path.join(TOP, p)
    return any(a == x or a.startswith(x + "/") for x in prefixes)
tmp = LOG + ".restat"
with open(LOG, "r", encoding="utf-8", errors="surrogateescape") as f, \
     open(tmp, "w", encoding="utf-8", errors="surrogateescape") as o:
    for line in f:
        if line.startswith("#"):
            o.write(line)
            continue
        parts = line.rstrip("\n").split("\t")
        if len(parts) == 5 and hit(parts[3]):
            parts[2] = NOW
            line = "\t".join(parts) + "\n"
        o.write(line)
os.replace(tmp, LOG)
PY
    return 0
}

# 整理内核 mtime + 写完成标记（标记里记了 Image 的 mtime，touch 之后必须重写，
# 否则 hui__kernel_ready 会把内核判成半成品）。
hui__kernel_tidy() {
    local po=${1:-$(hui__prodout "$HUI__PRODUCT")}
    # 注意：不能写成 local ko=... cfg="$ko/..." —— 同一个 local 里后面的赋值
    # 读不到前面刚声明的变量（set -u 下直接报 unbound，没开 -u 时静默变成
    # "/.config"，导致下面 stat 失败、目录 mtime 回退被跳过）。
    local ko cfg ct
    ko="$po/obj/KERNEL_OBJ"
    cfg="$ko/.config"
    hui__kernel_freshen "$po"
    hui__kdone_write "$po" || return 1
    # 完成标记就在 KERNEL_OBJ 里：写它会把该目录的 mtime 顶新，而 config 规则
    # 依赖这个目录，ROM 阶段又会判 config 过期。最后把目录 mtime 压回 .config 之前
    # （只动目录元数据，不碰文件内容）。
    ct=$(stat -c %Y -- "$cfg" 2>/dev/null)
    case "$ct" in
        ''|*[!0-9]*) : ;;
        *) touch -d "@$(( ct - 60 ))" -- "$ko" 2>/dev/null ;;
    esac
    # 文件 mtime 理顺还不够：ninja 还会拿 .ninja_log 里的记录时间跟输入比
    hui__ninja_log_restat_kernel "$po"
    return 0
}

# 进 ROM 阶段（第二次 m）前调用：内核已就绪时理顺 mtime 并重写完成标记。
hui__kernel_settle() {
    local po=${1:-$(hui__prodout "$HUI__PRODUCT")}
    [ -n "${HUI__KS:-}" ] || return 0
    hui__kernel_ready "$po" || return 0
    hui__kernel_tidy "$po" || hui__warn "重写内核完成标记失败"
    return 0
}

# 跑一个 m 阶段：-j 给的是天花板，实际并发由控制器连续调节
hui__run_phase() {
    local label=$1 jobs=$2; shift 2
    local mode=${HUI__PHASE_MODE:-build}
    if [ "$mode" = "graph" ]; then
        jobs=$(hui__graph_jobs "$jobs")
    fi
    if hui__dash_available; then
        hui__run_phase_dashboard "$label" "$jobs" "$@"
        return $?
    fi
    local t0=$SECONDS phase_exec
    phase_exec=$(hui__executor)
    hui__highmem_refresh "$jobs"
    HUI__JOBS_MAX=$jobs
    hui__runa_like "$phase_exec" && HUI__JOBS_MAX=$(hui__jobs_max)
    [ "$mode" = "graph" ] && HUI__JOBS_MAX=$jobs
    HUI__PHASE_START=$(date +%s)
    HUI__STAT_FILE=$(mktemp "${TMPDIR:-/tmp}/hui-stat.XXXXXX" 2>/dev/null)

    # 没面板也留一份阶段日志（和面板同一位置），失败时 hui__fail_report 用得上
    local log; log=$(hui__log_file_new)
    : >| "$log" 2>/dev/null || log=$(mktemp "${TMPDIR:-/tmp}/hui-build.XXXXXX")
    HUI__LOG_FILE=$log
    HUI__LOG_SHORT=${log#$HUI_TOP/}
    hui__last_log_mark "$log"
    hui__dim "  日志 ${HUI__LOG_SHORT}" >&2

    hui__phase_banner "$label" "$jobs" "$@"

    # 构图阶段没有执行器在读并发文件，控制器起来只会空转
    if [ "$mode" != "graph" ]; then
        hui__runa_like "$phase_exec" || hui__ctrl_start
    fi
    if [ "${HUI_PANEL:-1}" != "0" ]; then
        hui__panel_loop &
        HUI__PANEL_PID=$!
    fi

    # 构建放到后台起、前台 wait：这样 Ctrl-C 只到 hui 这一层，
    # 可以在收摊前先显式收掉构建进程树（后台子 shell 默认忽略 SIGINT）。
    local build_pid=""
    HUI__ABORTING=0
    HUI__ABORTED=0
    _hui_phase_int() {
        [ "${HUI__ABORTING:-0}" = "1" ] && return 0
        HUI__ABORTING=1
        HUI__ABORTED=1
        [ -n "${build_pid:-}" ] && hui__reap_build_tree "$build_pid"
        printf '\n%s[hui]%s 已中断，构建子进程已清理\n' \
            "$hui__c_yel" "$hui__c_rst" >&2
        return 0
    }
    trap '_hui_phase_int' INT HUP TERM
    # 输出直接写日志（进程退出即写完，不会和后面的 fail_report 抢），
    # 终端这边用 tail 实时跟随，保持和以前直接跑 m 一样的可见性。
    ( export NINJA_HIGHMEM_NUM_JOBS="${NINJA_HIGHMEM_NUM_JOBS:-$HUI_HIGHMEM_JOBS}"
      export CCACHE_DIRECT="${CCACHE_DIRECT:-${HUI_CCACHE_DIRECT:-1}}"
      hui__lower_priority
      if [ "$mode" = "graph" ]; then
          hui__graph_ledger_guard m -j"$jobs" --skip-ninja "$@"
      else
          hui__m_run "$jobs" "$@"
      fi ) >| "$log" 2>&1 &
    build_pid=$!
    local tail_pid=""
    if command -v tail >/dev/null 2>&1; then
        # 跟到 stdout，保持「重定向 stdout 能拿到构建输出」的老行为
        tail -n +1 -f --pid="$build_pid" --sleep-interval=0.2 "$log" 2>/dev/null &
        tail_pid=$!
    fi
    wait "$build_pid"
    local rc=$?
    build_pid=""
    if [ -n "$tail_pid" ]; then
        sleep 0.05
        kill -TERM "$tail_pid" 2>/dev/null
        wait "$tail_pid" 2>/dev/null
    fi
    trap - INT HUP TERM
    [ "${HUI__ABORTED:-0}" = "1" ] && rc=130

    if [ -n "${HUI__PANEL_PID:-}" ]; then
        kill -TERM "$HUI__PANEL_PID" 2>/dev/null
        wait "$HUI__PANEL_PID" 2>/dev/null
        HUI__PANEL_PID=""
    fi
    hui__ctrl_stop
    HUI__LAST_SECONDS=$(( SECONDS - t0 ))

    local el=$(( $(date +%s) - HUI__PHASE_START ))
    local tgt="-" scr="-"
    if [ -n "${HUI__STAT_FILE:-}" ] && [ -f "$HUI__STAT_FILE" ]; then
        read -r tgt scr < "$HUI__STAT_FILE" 2>/dev/null || true
        rm -f "$HUI__STAT_FILE"
    fi
    HUI__STAT_FILE=""
    if [ $rc -ne 0 ]; then
        # 130 = Ctrl-C：中断提示由 trap 打过，不再当“失败”刷一遍+复盘
        if [ "$rc" -ne 130 ]; then
            printf '%s[hui]%s 阶段「%s」失败 rc=%s · 用时 %02d:%02d:%02d\n' \
                "$hui__c_red" "$hui__c_rst" "$label" "$rc" \
                $((el / 3600)) $((el % 3600 / 60)) $((el % 60)) >&2
            hui__fail_report "$log"
        fi
    elif [ "${HUI__PHASE_QUIET_OK:-0}" != "1" ]; then
        if [ "$mode" = "graph" ]; then
            printf '%s[hui]%s 构图「%s」完成 · 用时 %02d:%02d:%02d\n' \
                "$hui__c_grn" "$hui__c_rst" "$label" \
                $((el / 3600)) $((el % 3600 / 60)) $((el % 60)) >&2
        else
            printf '%s[hui]%s 阶段「%s」完成 · 用时 %02d:%02d:%02d · 末次并发 %s/%s · 日志 %s\n' \
                "$hui__c_grn" "$hui__c_rst" "$label" \
                $((el / 3600)) $((el % 3600 / 60)) $((el % 60)) "${tgt:--}" "$jobs" \
                "${HUI__LOG_SHORT:-?}" >&2
        fi
    fi
    return $rc
}

# 失败如果像是内存打爆的，自动降一档重试一次
hui__looks_like_oom() {
    local st="${HUI_STATE:-$HUI_TOP/.hui}/.last-phase-log" f
    {
        tail -c 300000 "$HUI_TOP/${OUT_DIR:-out}/soong.log" 2>/dev/null
        tail -c 300000 "$HUI_TOP/${OUT_DIR:-out}/siso_output" 2>/dev/null
        [ -n "${HUI__LOG_FILE:-}" ] && tail -c 400000 "$HUI__LOG_FILE" 2>/dev/null
        # 面板路径的日志在子 shell 里，靠落盘的标记找到
        if [ -f "$st" ]; then
            f=$(cat "$st" 2>/dev/null)
            [ -n "$f" ] && [ "$f" != "${HUI__LOG_FILE:-}" ] && tail -c 400000 "$f" 2>/dev/null
        fi
    } | grep -qiE 'signal: killed|out of memory|oom-kill|killed process|已杀死|error 137|(^|[^[:alnum:]_])killed([^[:alnum:]_]|$)'
}

hui__run_phase_retry() {
    local label=$1 jobs=$2; shift 2
    hui__run_phase "$label" "$jobs" "$@"
    local rc=$?
    [ "$rc" -eq 130 ] && return 130
    local minj; minj=$(hui__jobs_min)
    if [ $rc -ne 0 ] && [ "$jobs" -gt "$minj" ] && hui__looks_like_oom; then
        local j2=$(( jobs - 3 ))
        [ "$j2" -lt "$minj" ] && j2=$minj
        hui__warn "看着像内存被打爆（日志里有 Error 137 / killed / 已杀死），自动降到 -j$j2 重试一次"
        hui__run_phase "$label 重试" "$j2" "$@"
        rc=$?
    fi
    return $rc
}

# 把「只生成构建图」当成一个正经阶段跑：kati+soong 那十几分钟照样有面板、
# 有日志、有 Ctrl-C 清理，而不是一次黑盒的前台 m。
# 返回 0 = 图已可复用（顺带设 HUI__M_FAST=1）；1 = 没生成出来，调用方回退完整 m；
#      130 = 被 Ctrl-C 打断。
hui__graph_first() {
    local jobs=$1; shift
    local prev_mode=${HUI__PHASE_MODE:-}
    hui__say "先生成构建图：m --skip-ninja（kati+soong 分析，不编译；这棵树 10~15 分钟）…"
    HUI__PHASE_MODE=graph
    hui__run_phase "构建图" "$jobs" "$@"
    local rc=$?
    if [ -n "$prev_mode" ]; then HUI__PHASE_MODE=$prev_mode; else unset HUI__PHASE_MODE; fi
    [ "$rc" -eq 130 ] && return 130
    if [ "$rc" -ne 0 ]; then
        hui__warn "m --skip-ninja 失败（rc=$rc），回退完整 m"
        return 1
    fi
    if hui__graph_verify; then
        HUI__M_FAST=1
        hui__ok "构建图已生成 → 交给 $(hui__executor) 编，跳过第二次分析"
        return 0
    fi
    hui__warn "图生成后校验仍未通过（${HUI__GRAPH_WHY:-未知}），回退完整 m"
    return 1
}

# ---------------------------------------------------------------------------
# codename -> 产品名，通用
# ---------------------------------------------------------------------------

hui__resolve_product() {
    local want=$1 f mk name first="" count=0 tmp
    local is_product='^[[:space:]]*PRODUCT_NAME[[:space:]]*:*='

    [ -n "$want" ] || return 1

    if [ -z "${HUI_TOP:-}" ] || [ ! -d "$HUI_TOP/device" ]; then
        hui__err "找不到源码树：HUI_TOP=${HUI_TOP:-未设置}"
        hui__dim "  在源码树里执行 source build/envsetup.sh；或 export HUI_TOP=/path/to/tree"
        return 1
    fi

    tmp=$(mktemp "${TMPDIR:-/tmp}/hui-resolve.XXXXXX") || return 1

    # 1) 参数本身就是产品名：树里存在 <want>.mk，且它真的是产品文件
    #    （不能只看文件名——device/generic/goldfish/board/kernel/arm64.mk 是内核 makefile）
    find "$HUI_TOP/device" "$HUI_TOP/vendor" -maxdepth 5 -name "$want.mk" 2>/dev/null >| "$tmp"
    while IFS= read -r f; do
        if grep -qE "$is_product" "$f" 2>/dev/null; then
            rm -f "$tmp"; printf '%s' "$want"; return 0
        fi
    done < "$tmp"

    # 2) 参数是 codename：找 device/**/<codename>/ 里的 PRODUCT_NAME。
    #    优先返回名字以 _<codename> 结尾的（lineage_nabu / aosp_cheetah_car），
    #    跳过 PRODUCT_NAME := lineage_$(DEVICE_CODENAME) 这种还没展开的。
    find "$HUI_TOP/device" -maxdepth 3 -type d -name "$want" 2>/dev/null >| "$tmp"
    while IFS= read -r d; do
        find "$d" -maxdepth 2 -name '*.mk' 2>/dev/null
    done < "$tmp" | sort >| "$tmp.mk"

    while IFS= read -r mk; do
        name=$(sed -n 's/^ *PRODUCT_NAME *:*= *//p' "$mk" 2>/dev/null | head -1)
        case "$name" in
            ""|*'$('*|*'$'*) continue ;;
            "$want"|*_"$want") rm -f "$tmp" "$tmp.mk"; printf '%s' "$name"; return 0 ;;
        esac
        count=$((count + 1))
        [ -z "$first" ] && first=$name
    done < "$tmp.mk"

    if [ -n "$first" ]; then
        if [ "$count" -gt 1 ]; then
            printf '%s[hui] !%s %s 下不止一个产品，先用 %s；不确定就传完整产品名\n' \
                "$hui__c_yel" "$hui__c_rst" "$want" "$first" >&2
        fi
        rm -f "$tmp" "$tmp.mk"
        printf '%s' "$first"
        return 0
    fi

    # 3) 兜底 lineage_<codename>
    find "$HUI_TOP/device" -maxdepth 5 -name "lineage_$want.mk" 2>/dev/null >| "$tmp"
    if [ -s "$tmp" ]; then
        rm -f "$tmp" "$tmp.mk"
        printf 'lineage_%s' "$want"
        return 0
    fi

    rm -f "$tmp" "$tmp.mk"
    return 1
}

# 内核相关的 make 目标：Lineage 系有独立的 dtbo/dtb 目标，其它树只编 kernel
hui__kernel_targets() {
    if [ -f "$HUI_TOP/vendor/lineage/build/tasks/kernel.mk" ]; then
        printf 'kernel dtboimage dtbimage'
    else
        printf 'kernel'
    fi
}

# ROM 短名：从产品名取前缀（lineage_nabu -> lineage，crDroid_nabu -> crDroid，
# aosp_cheetah_car -> aosp）。产品名认不出来时回退 lineage。
hui__rom() {
    local p=${HUI__PRODUCT:-${TARGET_PRODUCT:-}}
    [ -n "$p" ] || { printf 'lineage'; return 0; }
    printf '%s' "${p%%_*}"
}

# 默认构建目标，按优先级：
#   1. HUI_TARGET=<目标>
#   2. ROM 自带的总目标（vendor/<rom>/build/tasks/<rom>.mk 里的 <rom>:）
#   3. 产品前缀同名 target（crDroid: 之类）
#   4. Lineage 系通用的 bacon
#   5. 类原生 -> otapackage，纯 AOSP -> droid
hui__default_target() {
    local want=${HUI_TARGET:-} f hit="" rom tmp rd rf
    if [ -n "$want" ]; then printf '%s' "$want"; return 0; fi

    # ROM 自带的总目标：有的在自己的 vendor/<rom>/build/tasks 下，
    # 有的塞进 vendor/lineage/build/tasks/<rom>.mk（不针对某个具体 ROM）。
    for rd in lineage evolution crdroid yaap pixel arrow derp; do
        for rf in "$HUI_TOP/vendor/$rd/build/tasks/$rd.mk" \
                  "$HUI_TOP/vendor/lineage/build/tasks/$rd.mk"; do
            [ -f "$rf" ] || continue
            if grep -qsi -- "^$rd:" "$rf"; then printf '%s' "$rd"; return 0; fi
        done
    done

    rom=$(hui__rom)
    tmp=$(mktemp "${TMPDIR:-/tmp}/hui-target.XXXXXX") || { printf 'droid'; return 0; }
    {
        find "$HUI_TOP/vendor" -maxdepth 5 -path '*/build/tasks/*.mk' 2>/dev/null
        find "$HUI_TOP/build/make/core/tasks" -maxdepth 1 -name '*.mk' 2>/dev/null
    } >| "$tmp"

    if [ -n "$rom" ]; then
        while IFS= read -r f; do
            if grep -qs -- "^${rom}:" "$f"; then
                printf '%s' "$rom"; rm -f "$tmp"; return 0
            fi
        done < "$tmp"
    fi

    while IFS= read -r f; do
        if grep -qs '^bacon:' "$f"; then hit=1; break; fi
    done < "$tmp"
    rm -f "$tmp"
    if [ -n "$hit" ]; then printf 'bacon'; return 0; fi

    # 有 ROM 的 vendor 配置就是类原生，默认出 OTA 包；否则纯 AOSP 只编 images
    for f in vendor/lineage vendor/evolution vendor/crdroid vendor/yaap \
             vendor/pixel vendor/arrow vendor/derp; do
        [ -d "$HUI_TOP/$f" ] && { printf 'otapackage'; return 0; }
    done
    printf 'droid'
}

# ---------------------------------------------------------------------------
# hui：一条命令走完 内核 -> ROM
# ---------------------------------------------------------------------------

# 把 "nabu-user" / "nabu_user" / "lineage_nabu-user" / "lineage_nabu_user" / "nabu"
# 统一拆成 "<codename或产品名> <variant>"。认不出变体就默认 user。
hui__parse_cli() {
    local arg=$1 variant=""
    case "$arg" in
        *-*) variant=${arg##*-}; arg=${arg%-*} ;;
    esac
    if [ -z "$variant" ]; then
        case "$arg" in
            *_userdebug) variant=userdebug; arg=${arg%_userdebug} ;;
            *_user)      variant=user;      arg=${arg%_user} ;;
            *_eng)       variant=eng;       arg=${arg%_eng} ;;
        esac
    fi
    printf '%s %s' "$arg" "${variant:-user}"
}

hui__main() {
    local raw=${1:-} second=${2:-} third=${3:-}
    case "$raw" in
        ""|help|-h|--help) hui__cmd_help; return 1 ;;
        version) echo "hui $HUI_VERSION"; return 0 ;;
    esac

    # hui nabu-user                 -> codename=nabu variant=user
    # hui nabu-user bacon           -> 再指定构建目标
    # hui enchilada user            -> 老写法也兼容
    local codename variant target="" _pc
    _pc=$(hui__parse_cli "$raw")
    codename=${_pc%% *}
    variant=${_pc##* }
    case "$second" in
        user|userdebug|eng) variant=$second; target=$third ;;
        "") ;;
        *) target=$second ;;
    esac

    HUI_TOP=${HUI_TOP:-${ANDROID_BUILD_TOP:-$PWD}}
    if [ ! -f "$HUI_TOP/build/envsetup.sh" ]; then
        hui__err "这里不是 AOSP 源码树（找不到 $HUI_TOP/build/envsetup.sh）"
        return 1
    fi
    cd "$HUI_TOP" || return 1

    # 先认 codename，认不出来就别白跑一遍 envsetup
    local product
    if ! product=$(hui__resolve_product "$codename"); then
        # 兜底：整个参数本身可能就是产品名（含下划线的产品）
        if ! product=$(hui__resolve_product "$raw"); then
            hui__err "认不出 codename：$raw"
            hui__dim "  如果这是想执行命令，先看 hui help"
            hui__dim "  源码树   ${HUI_TOP:-未设置}"
            hui__dim "  device/  $(ls "$HUI_TOP/device" 2>/dev/null | head -4 | tr '\n' ' ')"
            hui__dim "  先确认：在源码树里 source build/envsetup.sh，再 hui <codename>-<variant>"
            return 1
        fi
        variant=${variant:-user}
    fi
    hui__say "构建 $product / $variant"

    if [ -z "${ANDROID_BUILD_TOP:-}" ] || ! command -v m >/dev/null 2>&1; then
        hui__say "加载 build/envsetup.sh"
        source "$HUI_TOP/build/envsetup.sh" >/dev/null 2>&1
    fi

    if ! lunch "${product}-${variant}" >/dev/null 2>&1; then
        hui__err "lunch ${product}-${variant} 失败"
        return 1
    fi

    # 构建本体统一走 cmd_build（图优先/内核优先/ROM 名/阶段提示都在那里），
    # 这里只负责 lunch 和默认目标。
    target=${target:-$(hui__default_target)}
    hui__cmd_build "$target"
    return $?
}

# ROM 全名：不同 ROM 的版本变量不同，按常见顺序取第一个非空的
hui__rom_full_name() {
    local v got
    for v in LINEAGE_VERSION EVOLUTION_VERSION CRDROID_VERSION AOSPA_VERSION YAAP_VERSION; do
        got=$(get_build_var "$v" 2>/dev/null)
        [ -n "$got" ] && { printf '%s' "$got"; return 0; }
    done
    return 1
}

# 时长：<1h 用 m:ss，>=1h 用 h:mm
hui__fmt_dur() {
    local s=${1:-0}
    case "$s" in ''|*[!0-9]*) s=0 ;; esac
    if [ "$s" -ge 3600 ]; then
        printf '%dh%02dm' $((s / 3600)) $((s % 3600 / 60))
    else
        printf '%dm%02ds' $((s / 60)) $((s % 60))
    fi
}

# 终端列数：优先 COLUMNS（交互 shell 会随窗口更新），其次 tput，最后 80
hui__term_cols() {
    local w=${COLUMNS:-}
    case "$w" in ''|*[!0-9]*) w=$(tput cols 2>/dev/null) ;; esac
    case "$w" in ''|*[!0-9]*) w=80 ;; esac
    [ "$w" -lt 20 ] && w=20
    [ "$w" -gt 100 ] && w=100
    printf '%s' "$w"
}

# 一个字符串的显示列宽（中文、… 按终端列算；拿不到 wc -L 就退回字符数）
hui__wlen() {
    local n
    n=$(printf '%s' "$1" | wc -L 2>/dev/null)
    case "$n" in ''|*[!0-9]*) n=${#1} ;; esac
    printf '%s' "$n"
}

# 按显示列宽截断到 n 列：head 保留开头，tail 保留结尾（日志文件名在结尾）
hui__fit_w() {
    local s=$1 n=$2 mode=${3:-head} len ew target keep cut
    case "$n" in ''|*[!0-9]*) n=60 ;; esac
    [ "$n" -lt 6 ] && n=6
    len=$(hui__wlen "$s")
    [ "$len" -le "$n" ] && { printf '%s' "$s"; return 0; }
    ew=$(hui__wlen "…")
    [ "$ew" -lt 1 ] && ew=1
    target=$((n - ew))
    [ "$target" -lt 1 ] && target=1
    if [ "$mode" = "tail" ]; then
        keep=$target
        while [ "$keep" -gt 1 ] && \
            [ "$(hui__wlen "$(printf '%s' "$s" | rev | cut -c1-"$keep" | rev)")" -gt "$target" ]; do
            keep=$((keep - 1))
        done
        printf '…%s' "$(printf '%s' "$s" | rev | cut -c1-"$keep" | rev)"
    else
        cut=$(printf '%s' "$s" | cut -c1-"$target")
        while [ "${#cut}" -gt 1 ] && [ "$(hui__wlen "$cut")" -gt "$target" ]; do
            cut=$(printf '%s' "$cut" | cut -c1-$(( ${#cut} - 1 )))
        done
        printf '%s…' "$cut"
    fi
}

# 构建收尾摘要：行宽跟终端走；日志路径过长时保留尾部（文件名），
# 其余行截断并加 …，保证整块都在分隔线以内。
hui__build_summary() {
    local rc=$1 total=$2 rom_s=$3
    local w av hdr line log state mark mchar pfx dur
    w=$(hui__term_cols)
    line=$(printf '─%.0s' $(seq 1 "$w"))
    log=$(cat "${HUI_STATE:-$HUI_TOP/.hui}/.last-phase-log" 2>/dev/null)
    [ -n "$log" ] || log=${HUI__LOG_FILE:-}
    [ -n "$log" ] && log=${log#$HUI_TOP/}
    dur=$(printf '%dh%02dm' $((total / 3600)) $((total % 3600 / 60)))
    printf '\n%s%s%s\n' "$hui__c_dim" "$line" "$hui__c_rst" >&2

    if [ "$rc" -eq 0 ]; then
        mchar="✓"
        mark="${hui__c_grn}${mchar}${hui__c_rst}"
        hdr="构建成功 · 总用时 ${dur} · ROM $(hui__fmt_dur "$rom_s")"
    elif [ "$rc" -eq 130 ]; then
        mchar="■"
        mark="${hui__c_yel}${mchar}${hui__c_rst}"
        hdr="构建已中断 · 总用时 ${dur} · ROM $(hui__fmt_dur "$rom_s")"
    else
        mchar="✗"
        mark="${hui__c_red}${mchar}${hui__c_rst}"
        hdr="构建失败 rc=${rc} · 总用时 ${dur} · ROM $(hui__fmt_dur "$rom_s")"
    fi
    pfx="[hui] ${mchar} "
    av=$((w - $(hui__wlen "$pfx")))
    [ "$av" -lt 6 ] && av=6
    printf '%s[hui]%s %s %s\n' "$hui__c_dim" "$hui__c_rst" "$mark" \
        "$(hui__fit_w "$hdr" "$av" head)" >&2

    pfx="[hui]   阶段  "
    av=$((w - $(hui__wlen "$pfx")))
    [ "$av" -lt 6 ] && av=6
    state="构建图 ${HUI__GRAPH_STATE:-?} · 内核 ${HUI__KERNEL_STATE:-?}"
    printf '%s[hui]%s   阶段  %s\n' "$hui__c_dim" "$hui__c_rst" \
        "$(hui__fit_w "$state" "$av" head)" >&2
    state=""
    case "${HUI__SAVE_STATE:-}" in
        skip)     state="内核快照已是最新${HUI__SAVE_FP:+（${HUI__SAVE_FP}）}" ;;
        saved)    state="内核快照已保存${HUI__SAVE_FP:+（${HUI__SAVE_FP}）}" ;;
        fail)     state="内核快照保存失败" ;;
        prebuilt) state="预编译内核，无需快照" ;;
    esac
    [ "$rc" -eq 0 ] && [ -n "$state" ] && \
        printf '%s[hui]%s   缓存  %s\n' "$hui__c_dim" "$hui__c_rst" \
            "$(hui__fit_w "$state" "$av" head)" >&2
    [ -n "$log" ] && printf '%s[hui]%s   日志  %s\n' "$hui__c_dim" "$hui__c_rst" \
        "$(hui__fit_w "$log" "$av" tail)" >&2
    printf '%s%s%s\n' "$hui__c_dim" "$line" "$hui__c_rst" >&2
    return 0
}

hui__cmd_build() {
    hui__require_env || return 1
    hui__build_lock || return 1
    # 计时从拿到锁开始：构图/恢复/内核/ROM 都算进摘要里的「总用时」
    local hui__t0; hui__t0=$(date +%s)
    HUI__GRAPH_STATE=""
    HUI__KERNEL_STATE=""
    HUI__SAVE_STATE=""
    HUI__SAVE_FP=""
    hui__kernel_vars || return 1
    [ -n "${HUI__KS:-}" ] || HUI__KERNEL_STATE="预编译"
    # ROM 全名（面板产品信息用）：Lineage/EVO/crDroid 等常见变量依次试；空则回退产品名
    if [ -z "${HUI__ROM_NAME:-}" ]; then
        HUI__ROM_NAME=$(hui__rom_full_name)
        [ -n "$HUI__ROM_NAME" ] || HUI__ROM_NAME="${HUI__PRODUCT:-?}-${TARGET_BUILD_VARIANT:-?}"
    fi
    # 面板配置表要的 PLATFORM / BUILD_ID / PATCH / GMS：构图时 build.prop 还没生成，
    # 先在构建前取一次 build var，别让面板显示「?」
    hui__panel_config
    local jobs; jobs=$(hui__jobs_start)
    hui__highmem_refresh "$jobs"
    hui__say "执行器 $(hui__executor_label "$(hui__executor)")"
    hui__say "并发 -j$jobs（上限 $(hui__jobs_max) · 运行中 $(hui__jobs_min)~$jobs）· 高内存 $HUI_HIGHMEM_JOBS 路"
    hui__pools_export "$jobs"
    local pool_line; pool_line=$(hui__pools_summary)
    [ -n "$pool_line" ] && hui__say "内存池${pool_line}"
    hui__mem_headsup

    # 账本格式预警：不同 ninja 版本的 .ninja_log/.ninja_deps 不通用，
    # 切换执行器会让 ninja 丢掉账本、把整棵树当脏（实测一次 22 万条边全量重建）。
    hui__ninja_log_guard

    # 先恢复内核快照，再校验/生成构建图：
    # restore 会把 obj/KERNEL_OBJ、DTBO_OBJ、DTB_OBJ 落回 out/，而
    # BOARD_PREBUILT_DTBOIMAGE 指向的 dtbo.img 会被 soong 记成 glob 输入。
    # 若先构图后 restore，图里记的是「文件不存在」，下次构建就会因为 glob
    # 结果变了又跑一遍完整分析（实测多花 9 分钟）。
    hui__restore; local rrc=$?
    if [ -z "${HUI__KERNEL_STATE:-}" ]; then
        if [ "$rrc" -eq 0 ]; then
            HUI__KERNEL_STATE="快照"
        elif [ -n "${HUI__KS:-}" ]; then
            HUI__KERNEL_STATE="未就绪"
        fi
    fi

    HUI__M_FAST=0
    [ "${HUI_GRAPH_REUSE:-1}" = "0" ] && HUI__GRAPH_STATE="强制重跑"
    if [ "${HUI_GRAPH_REUSE:-1}" != "0" ]; then
        hui__say "校验构建图（约 5~10 秒）…"
        if hui__graph_verify; then
            HUI__M_FAST=1
            HUI__GRAPH_STATE="复用（$(hui__graph_mtime)）"
            hui__ok "构建图 复用（$(hui__graph_mtime)，跳过 kati+soong）"
        else
            hui__GRAPH_STATE="回退完整 m"
            hui__say "构建图需要更新：$HUI__GRAPH_WHY"
            # 首次构建：只让 m 生成图（不编译），拿到图后切执行器编。
            # HUI_GRAPH_FIRST=0 恢复旧行为（一次性 m 编到底）。
            if [ "${HUI_GRAPH_FIRST:-1}" != "0" ] && hui__runa_like; then
                # 构图同样走面板（kati+soong 也能看到阶段/耗时，不再是黑盒 m）
                hui__graph_first "$jobs" "$@"
                local grc=$?
                [ "$grc" -eq 130 ] && return 130
                [ "$grc" -eq 0 ] && HUI__GRAPH_STATE="已生成"
            fi
        fi
    fi

    # 构图（soong bootstrap 走 siso）会把 out/.ninja_log 截成 v5；
    # 账本 guard 已经回滚成 v6，这里在终端补一句，别让人以为「什么都没发生」。
    if [ -f "$(hui__ledger_restored_mark)" ]; then
        hui__ok "构图把增量账本写成了 v5，已回滚 v6（本次是增量，不会全量）"
        hui__dim "  没这一下就是整树 22 万条边重编：siso 会截断账本，自建执行器只认 v6"
        rm -f -- "$(hui__ledger_restored_mark)" 2>/dev/null
    fi

    [ "$HUI__M_FAST" = "1" ] && hui__phase_done "构建图完成"

    if [ "$rrc" -eq 2 ] && [ -n "${HUI__KS:-}" ]; then
        hui__warn "内核快照缺失或不完整，先补内核（约 20~30 分钟）"
        hui__run_kernel_phase "内核" "$jobs"; rrc=$?
        [ "$rrc" -ne 0 ] && return "$rrc"
        HUI__KERNEL_STATE="已编"
        # 内核编完立刻存快照：后面 ROM 再失败/被 Ctrl-C，内核也不用重编
        hui__ok "内核完成，存快照"
        hui__save || hui__warn "快照保存失败（内核产物在位，本次继续编 ROM）"
    fi

    # 快照恢复后 out/ 里可能还没有最终内核镜像（例如刚清过 out/）。
    # 内核 full-LTO 链接单线程且吃内存，排在 ROM 后面会和 ROM 编译抢内存
    # （实测能把最后一步拖成半小时），所以先单独补内核再编 ROM。
    local po; po=$(hui__prodout "$HUI__PRODUCT")
    if [ "$HUI__M_FAST" = "1" ] && [ -n "${HUI__KS:-}" ] \
       && [ "${HUI_KERNEL_FIRST:-1}" != "0" ] \
       && hui__kernel_ready "$po" && [ ! -e "$po/kernel" ]; then
        hui__say "内核快照已恢复，但最终镜像还没进 out/：先单独补内核（避免 LTO 与 ROM 抢内存）"
        hui__run_kernel_phase "内核" "$jobs"
        rrc=$?
        [ "$rrc" -ne 0 ] && return "$rrc"
        HUI__KERNEL_STATE="已编"
        hui__ok "内核完成，存快照"
        hui__save || hui__warn "快照保存失败（内核产物在位，本次继续编 ROM）"
    fi

    if [ -n "${HUI__KS:-}" ] && hui__kernel_ready "$po"; then
        hui__phase_done "内核完成"
    fi

    # 补完内核后内存通常更宽裕，构建阶段重算一次准入
    local build_jobs; build_jobs=$(hui__jobs_start)
    if [ "$build_jobs" != "$jobs" ]; then
        hui__say "内存有变化：构建阶段并发 -j${build_jobs}（内核阶段是 -j${jobs}）"
        jobs=$build_jobs
    fi
    # 第二次 m（ROM 阶段）之前理顺内核 mtime：
    # 否则 Lineage kernel.mk 的 config→Image 依赖会被判过期，重跑一遍 full-LTO 链接，
    # 和 ROM 编译并发抢内存（实测被 OOM kill，make: Error 137）。
    hui__kernel_settle "$po"
    # 失败如果像内存打爆（Error 137 / 已杀死 / oom-kill）就降一档并发重试一次；
    # ROM 是增量续跑，重试只会补剩下的边，不会从头编。
    local rom_t0; rom_t0=$(date +%s)
    HUI__PHASE_QUIET_OK=1 hui__run_phase_retry "ROM" "$jobs" "$@"
    local rc=$?
    local rom_s=$(( $(date +%s) - rom_t0 ))
    if [ $rc -eq 130 ]; then
        # 中断提示 trap/面板已经打过，这里只补一块摘要
        hui__build_summary 130 "$(( $(date +%s) - hui__t0 ))" "$rom_s"
        return 130
    fi
    if [ $rc -eq 0 ]; then
        local total=$(( $(date +%s) - hui__t0 ))
        HUI__LAST_SECONDS=$total
        hui__phase_done "ROM完成"
        # 这轮编完账本是 v6 且最全，刷进 .hui 常驻备份：
        # 下次不管是构图还是裸 m 把账本截成 v5，都能回滚到「这次编完」的状态。
        hui__ledger_sync
        # 内核可能是在这次 m 里编的（没走 hui 的内核阶段）：补写完成标记，
        # 否则 hui save 会拒绝，下次构建还会误以为内核不完整。
        local po3; po3=$(hui__prodout "$HUI__PRODUCT")
        if [ -n "${HUI__KS:-}" ] \
           && [ -f "$po3/obj/KERNEL_OBJ/arch/$HUI__KA/boot/$HUI__KI" ] \
           && ! hui__kdone_ok "$po3"; then
            hui__dim "  内核是这次 m 里编的，补写完成标记"
            hui__kdone_write "$po3" || hui__warn "补写内核完成标记失败（hui save 可能被拒）"
            HUI__KERNEL_STATE="已编"
        fi
        HUI__SAVE_QUIET=1 hui__save || \
            hui__warn "内核快照保存失败（不影响本次构建）"
        hui__build_summary 0 "$total" "$rom_s"
    else
        hui__build_summary "$rc" "$(( $(date +%s) - hui__t0 ))" "$rom_s"
    fi
    return $rc
}

# 执行器的 ninja 日志（自建 hui / Runa / soong_ui 都写这一份）
hui__ninja_log() {
    local outd=${OUT_DIR:-out}
    case "$outd" in
        /*) printf '%s' "${HUI_NINJA_LOG:-$outd/.ninja_log}" ;;
        *)  printf '%s' "${HUI_NINJA_LOG:-$HUI_TOP/$outd/.ninja_log}" ;;
    esac
}

# 历史耗时：.ninja_log -> "<ms>\t<output>"；给执行器 --duration-file 用。
hui__durations_build() {
    local log fp
    log=$(hui__ninja_log)
    [ -s "$log" ] || return 0
    fp="${HUI_STATE:-$HUI_TOP/.hui}/${HUI__PRODUCT:-product}/durations.tsv"
    mkdir -p -- "${fp%/*}" 2>/dev/null || return 0
    awk -F'\t' '
        /^#/ { next }
        NF < 4 { next }
        { d = $2 - $1; if (d < 0) d = 0; if (d > seen[$4]) seen[$4] = d }
        END { for (p in seen) printf "%d\t%s\n", seen[p], p }
    ' "$log" >| "$fp.tmp" 2>/dev/null || return 0
    if [ -s "$fp.tmp" ]; then mv -f -- "$fp.tmp" "$fp"; else rm -f -- "$fp.tmp"; fi
    return 0
}

hui__durations_file() {
    local fp="${HUI_STATE:-$HUI_TOP/.hui}/${HUI__PRODUCT:-product}/durations.tsv"
    [ -s "$fp" ] && printf '%s' "$fp"
    return 0
}

# 没有 siso 指标时的 report：直接看执行器日志（.ninja_log）
hui__report_ninja_log() {
    local log n
    log=$(hui__ninja_log)
    [ -s "$log" ] || { hui__err "没有 $log（跑一次构建先）"; return 1; }
    n=$(awk -F'\t' '!/^#/ && NF >= 4 {c++} END {print c+0}' "$log")
    [ "$n" -gt 0 ] || { hui__err "$log 里没有记录（可能刚 clean 过）"; return 1; }

    hui__say "执行器耗时（$log，$n 条记录）"
    awk -F'\t' '
        /^#/ { next }
        NF < 4 { next }
        { i++; st[i] = $1 + 0; en[i] = $2 + 0; out[i] = $4
          d = en[i] - st[i]; if (d < 0) d = 0; dur[i] = d }
        END {
            total = i
            base = 1
            for (k = 2; k <= total; k++) if (st[k] < st[k-1]) base = k
            cnt = 0; sum = 0; mn = -1; mx = 0
            for (k = base; k <= total; k++) {
                cnt++; sum += dur[k]
                if (mn < 0 || st[k] < mn) mn = st[k]
                if (en[k] > mx) mx = en[k]
            }
            wall = mx - mn; if (wall <= 0) wall = 1
            printf "  最近一次构建：%d 个任务，墙钟 %.1f 分钟，任务累计 %.1f 分钟，平均并发 %.1fx\n",
                   cnt, wall / 60000, sum / 60000, sum / wall
        }
    ' "$log"
    echo
    hui__say "最长的 15 个任务"
    awk -F'\t' '!/^#/ && NF >= 4 { d = $2 - $1; if (d < 0) d = 0; printf "%d\t%s\n", d, $4 }' "$log" |
        sort -rn | head -15 |
        awk -F'\t' '{ p = $2; if (length(p) > 100) p = "…" substr(p, length(p) - 99); printf "  %7.1fs  %s\n", $1 / 1000, p }'
    echo
    hui__say "按产物类型"
    awk -F'\t' '
        /^#/ { next }
        NF < 4 { next }
        { name = $4; sub(/.*\//, "", name)
          ext = "无扩展名"
          if (name ~ /\./) { sub(/.*\./, "", name); ext = "." name }
          d = $2 - $1; if (d < 0) d = 0
          cnt[ext]++; sum[ext] += d }
        END { for (e in sum) printf "%d\t%d\t%s\n", sum[e], cnt[e], e }
    ' "$log" | sort -rn | head -12 |
        awk -F'\t' '{ printf "  %8.1f 分钟  %6d 个  %s\n", $1 / 60000, $2, $3 }'
    hui__dim "  提示：构建时 hui 会把这份日志汇总成 --duration-file，让长任务优先启动"
}

hui__cmd_report() {
    hui__require_env || return 1
    local f="$HUI_TOP/out/siso_metrics.json"
    if [ ! -f "$f" ]; then
        hui__report_ninja_log
        return $?
    fi
    HUI_REPORT_FILE=$f python3 - <<'PY'
import json, os, collections
p = os.environ['HUI_REPORT_FILE']
cat = collections.Counter(); t = collections.Counter()
rows = []
dur = None
with open(p, encoding='utf-8', errors='replace') as f:
    for line in f:
        line = line.strip()
        if not line.startswith('{'): continue
        try: d = json.loads(line)
        except Exception: continue
        if 'output' in d and 'run' in d:
            o = d['output']
            if   '/obj/PACKAGING/' in o:      k = '镜像/打包'
            elif 'KERNEL_OBJ' in o:           k = '内核'
            elif o.endswith(('.o', '.so', '.a')): k = 'C/C++'
            elif o.endswith(('.jar', '.apk')):    k = 'Java'
            elif '/.intermediates/' in o:     k = '其他中间产物'
            else:                             k = '其他'
            cat[k] += 1; t[k] += d['run']
            rows.append((d['run'], d['duration'], o))
        if 'duration' in d and 'build_id' in d:
            dur = d['duration']
tt = sum(t.values()) or 1
if dur:
    print(f"\n  上次构建 {dur:.0f}s（{dur/3600:.2f}h），串行执行总时长 {tt/3600:.2f}h")
else:
    print(f"\n  串行执行总时长 {tt/3600:.2f}h")
print(f"  {'类别':<12}{'动作数':>8}{'占比':>9}")
for k, v in t.most_common():
    print(f"  {k:<12}{cat[k]:>8}{v/tt*100:>8.1f}%")
print("\n  最慢的 8 个动作：")
for run, d, o in sorted(rows, reverse=True)[:8]:
    print(f"    {run:8.1f}s  {o[:96]}")
print()
PY
}

# ccache 目录：优先 CCACHE_DIR，否则 ~/.ccache
hui__ccache_dir() {
    local d="${CCACHE_DIR:-}"
    [ -n "$d" ] || d="${HOME:-/root}/.ccache"
    printf '%s' "$d"
}

# 注意：本文件所有「覆盖写」都用 >| 而不是 >
# 因为 zsh 的 noclobber 会让 > 拒绝写已存在的文件（我们的临时文件都是 mktemp 先建好的）

hui__bytes_of() { du -sb -- "$1" 2>/dev/null | cut -f1; }

# 只允许删这三个地方：out/、.hui/、ccache 目录
_hui_clean_guard() {
    local p=$1
    [ -n "$p" ] || return 1
    [ -L "$p" ] && { hui__err "拒绝：$p 是软链"; return 1; }
    case "$p" in
        "$HUI_TOP/out"|"$HUI_TOP/out/"*|"$HUI_TOP/.hui/"*) return 0 ;;
        "$(hui__ccache_dir)") return 0 ;;
        *) hui__err "拒绝：$p 不在 out/ 或 .hui/ 下"; return 1 ;;
    esac
}

hui__cmd_clean() {
    local codename="" yes=0 dry=0 do_ccache=0 only_snap=0 keep_snap=0

    while [ $# -gt 0 ]; do
        case "$1" in
            -y|--yes)      yes=1 ;;
            -n|--dry-run)  dry=1 ;;
            --ccache)      do_ccache=1 ;;
            --no-ccache)   do_ccache=0 ;;
            --snapshot)    only_snap=1 ;;
            --keep-snapshot|--no-snapshot|--out) keep_snap=1 ;;
            --all)         do_ccache=1 ;;
            -h|--help)     hui__help_cmd clean; return 0 ;;
            -*)            hui__err "未知参数：$1（hui clean --help）"; return 1 ;;
            *)             codename=$1 ;;
        esac
        shift
    done

    # 构建进行中拒绝清理：m clean 会删掉正在生成的 soong 图 / out 中间产物，
    # 带 codename 时还会删这个设备的内核快照。dry-run 只读，放行。
    if [ "$dry" != "1" ] && [ -n "${HUI_TOP:-}" ] && command -v flock >/dev/null 2>&1; then
        local _lock="${HUI_STATE:-$HUI_TOP/.hui}/build.lock"
        if [ -e "$_lock" ] && ! flock -n "$_lock" true 2>/dev/null; then
            hui__err "有 hui 构建正在跑，先等它结束再 clean"
            hui__dim "  clean 会删掉正在生成的构建图和 out/ 中间产物；带 codename 还会删内核快照"
            hui__dim "  确认没有构建在跑：看还有没有 hui/m/ninja/runa 进程"
            return 1
        fi
    fi

    hui__require_env >/dev/null 2>&1 || HUI__PRODUCT=""

    if [ -n "$codename" ]; then
        local cp
        cp=$(hui__resolve_product "$codename") || {
            hui__err "认不出 codename：$codename"; return 1; }
        HUI__PRODUCT=$cp
        # 设备名不要沿用当前 lunch 的，按传进来的 codename 推
        if [ -n "${HUI__PRODUCT##*_}" ] && [ "${HUI__PRODUCT##*_}" != "$HUI__PRODUCT" ] \
           && [ "$HUI__PRODUCT" != "$codename" ]; then
            HUI__DEV=${HUI__PRODUCT##*_}
        else
            HUI__DEV=$codename
        fi
    elif [ -z "${HUI__PRODUCT:-}" ]; then
        hui__err "还没 lunch：先 lunch <product>-<variant>，或 hui clean <codename>"
        return 1
    fi

    local cdir; cdir=$(hui__ccache_dir)

    # ---------- 默认：m clean + ccache + 当前产品的内核快照 ----------
    if [ -z "$codename" ] && [ "$only_snap" = "0" ]; then
        local out="$HUI_TOP/out"
        local snap="${HUI_STATE:-$HUI_TOP/.hui}/$HUI__PRODUCT"
        local had_snap=0; [ -d "$snap" ] && had_snap=1
        local bytes; bytes=$(hui__bytes_of "$out")
        if [ "$dry" = "1" ]; then
            if [ "$do_ccache" = "1" ]; then
                printf '\n  即将执行 m clean（等价）+ 清 ccache，会清掉：\n'
            else
                printf '\n  即将执行 m clean（等价，ccache 保留），会清掉：\n'
            fi
            printf '  %-8s %-48s %10s\n' "out" "out/" "$(hui__human "${bytes:-0}")"
            if [ "$keep_snap" != "1" ] && [ "$had_snap" = "1" ]; then
                printf '  %-8s %-48s %10s\n' "snapshot" "${snap#$HUI_TOP/}" "$(hui__human "$(hui__bytes_of "$snap")")"
            fi
            if [ "$do_ccache" = "1" ]; then
                printf '  %-8s %-48s %10s\n' "ccache" "$cdir" "$(hui__human "$(hui__bytes_of "$cdir")")"
            fi
            [ "$keep_snap" = "1" ] && hui__dim "  --keep-snapshot：内核快照 .hui/ 保留"
            return 0
        fi
        if [ "$yes" != "1" ]; then
            printf '将执行 m clean'
            if [ "$do_ccache" = "1" ]; then
                printf '、清 ccache'
            else
                printf '（ccache 保留）'
            fi
            if [ "$keep_snap" = "1" ]; then
                printf '、内核快照保留'
            else
                printf '、清当前产品内核快照'
            fi
            printf '。确认？[y/N] '
            read -r ans
            case "$ans" in
                y|Y|yes|YES) ;;
                *) hui__say "已取消"; return 0 ;;
            esac
        fi
        hui__say "执行 m clean …"
        if ! m clean; then
            hui__err "m clean 失败"
            return 1
        fi
        if [ "$keep_snap" != "1" ] && [ "$had_snap" = "1" ]; then
            hui__say "清理内核快照 ${snap#$HUI_TOP/}"
            _hui_clean_guard "$snap" && rm -rf --one-file-system -- "$snap"
        fi
        # out/ 都清了，账本备份也就没意义了；留着反而会在下次构建时
        # 把一堆早就不存在的产物记成「已编过」。
        rm -f -- "$(hui__ledger_backup_path)" "$(hui__ledger_restored_mark)" 2>/dev/null
        if [ "$do_ccache" = "1" ]; then
            hui__say "清理 ccache $cdir"
            ccache -C >/dev/null 2>&1 || rm -rf --one-file-system -- "$cdir"
        fi
        local done_msg="out/ 已清"
        if [ "$do_ccache" = "1" ]; then
            done_msg="$done_msg、ccache 已清"
        else
            done_msg="$done_msg、ccache 保留"
        fi
        if [ "$keep_snap" = "1" ]; then
            done_msg="$done_msg、内核快照保留"
        elif [ "$had_snap" = "1" ]; then
            done_msg="$done_msg、内核快照已清"
        else
            done_msg="$done_msg、无内核快照"
        fi
        hui__ok "clean 完成（$done_msg）"
        return 0
    fi

    # ---------- 指定 codename / --snapshot：只动这一份 ----------
    local po; po=$(hui__prodout "$HUI__PRODUCT")
    local snap="${HUI_STATE:-$HUI_TOP/.hui}/$HUI__PRODUCT"
    local tmp; tmp=$(mktemp "${TMPDIR:-/tmp}/hui-clean.XXXXXX") || return 1

    if [ "$only_snap" = "0" ] && [ -d "$po" ] \
       && [ "$po" != "$HUI_TOP/out/target/product" ] && [ "$po" != "$HUI_TOP/out" ]; then
        printf 'build\t%s\n' "$po" >> "$tmp"
    fi
    if [ -d "$snap" ]; then
        printf 'snapshot\t%s\n' "$snap" >> "$tmp"
    fi
    if [ "$do_ccache" = "1" ] && [ -d "$cdir" ]; then
        printf 'ccache\t%s\n' "$cdir" >> "$tmp"
    fi

    if [ ! -s "$tmp" ]; then
        hui__say "没有要清理的东西"
        rm -f "$tmp"
        return 0
    fi

    local label ppath bytes total=0
    printf '\n'
    while IFS="$(printf '\t')" read -r label ppath; do
        [ -n "$ppath" ] || continue
        bytes=$(hui__bytes_of "$ppath"); bytes=${bytes:-0}
        total=$((total + bytes))
        printf '  %-9s %-46s %10s\n' "$label" "${ppath#$HUI_TOP/}" "$(hui__human "$bytes")"
    done < "$tmp"
    printf '  %-9s %-46s %10s\n\n' "合计" "" "$(hui__human "$total")"

    if [ "$dry" = "1" ]; then
        hui__say "dry-run，什么都没删"
        rm -f "$tmp"
        return 0
    fi

    if [ "$yes" != "1" ]; then
        printf '确认清理？[y/N] '
        read -r ans
        case "$ans" in
            y|Y|yes|YES) ;;
            *) hui__say "已取消"; rm -f "$tmp"; return 0 ;;
        esac
    fi

    local before after
    before=$(df -B1 --output=used "$HUI_TOP" 2>/dev/null | tail -1)
    while IFS="$(printf '\t')" read -r label ppath; do
        [ -n "$ppath" ] || continue
        hui__say "清理 $label：${ppath#$HUI_TOP/}"
        case "$label" in
            ccache)
                ccache -C >/dev/null 2>&1 || rm -rf --one-file-system -- "$ppath" ;;
            *)
                _hui_clean_guard "$ppath" && rm -rf --one-file-system -- "$ppath" ;;
        esac
    done < "$tmp"
    rm -f "$tmp"
    after=$(df -B1 --output=used "$HUI_TOP" 2>/dev/null | tail -1)
    hui__ok "清理完成，释放 $(hui__human $(( ${before:-0} - ${after:-0} )))"
}


# ---------------------------------------------------------------------------
# Tab 补全
# ---------------------------------------------------------------------------

HUI__WORDS='build m status doctor graph report save restore finger clean version help tui'

# 候选目标：codename_variant。结果缓存到 .hui/completions，7 天过期
hui__complete_targets() {
    [ -n "${HUI_STATE:-}" ] || HUI_STATE="${HUI_TOP:-.}/.hui"
    local cache="$HUI_STATE/completions" now
    now=$(date +%s 2>/dev/null || echo 0)
    if [ -f "$cache" ]; then
        local ts=0
        ts=$(sed -n '1s/^#v2-ts=//p' "$cache" 2>/dev/null)
        case "$ts" in ''|*[!0-9]*) ts=0 ;; esac
        if [ $((now - ts)) -lt 604800 ]; then
            sed -n '2,$p' "$cache"
            return 0
        fi
    fi
    [ -d "${HUI_TOP:-}/device" ] || return 0
    mkdir -p "$HUI_STATE" 2>/dev/null
    {
        printf '#v2-ts=%s\n' "$now"
        find "$HUI_TOP/device" -maxdepth 3 -type d 2>/dev/null | while IFS= read -r d; do
            grep -lq '^[[:space:]]*PRODUCT_NAME' "$d"/*.mk 2>/dev/null && {
                n=${d##*/}
                printf '%s-user\n%s-userdebug\n%s-eng\n' "$n" "$n" "$n"
            }
        done
    } >| "$cache"
    sed -n '2,$p' "$cache"
}

hui__install_completion() {
    if [ -n "${ZSH_VERSION:-}" ]; then
        eval '
if ! command -v compdef >/dev/null 2>&1; then
    # -D: 不写 ~/.zcompdump，只在当前会话里建补全系统，不碰任何本地文件
    autoload -Uz compinit 2>/dev/null && compinit -C -D 2>/dev/null
fi
_hui_complete_zsh() {
    local -a cands
    if (( CURRENT == 2 )); then
        cands=( ${(f)"$(hui__complete_words)"} )
    else
        cands=( user userdebug eng bacon droid systemimage otapackage )
    fi
    compadd -a cands
}
compdef _hui_complete_zsh hui 2>/dev/null
'
    elif [ -n "${BASH_VERSION:-}" ]; then
        _hui_complete_bash() {
            local cur="${COMP_WORDS[COMP_CWORD]}"
            if [ "$COMP_CWORD" -le 1 ]; then
                COMPREPLY=( $(compgen -W "$(hui__complete_words)" -- "$cur") )
            else
                COMPREPLY=( $(compgen -W "user userdebug eng bacon droid systemimage otapackage" -- "$cur") )
            fi
        }
        complete -F _hui_complete_bash hui 2>/dev/null
    fi
    return 0
}

hui__complete_words() {
    printf '%s' "$HUI__WORDS"
    hui__complete_targets | sed 's/^/ /' | tr -d '\n'
    printf ' '
}

# ---------------------------------------------------------------------------
# TUI
# ---------------------------------------------------------------------------

hui__read1() {
    if [ -n "${ZSH_VERSION:-}" ]; then read -k1 -s "$1"; else read -rsn1 "$1"; fi
}
hui__read2() {
    if [ -n "${ZSH_VERSION:-}" ]; then read -k2 -s "$1"; else read -rsn2 "$1"; fi
}

hui__tui_label() {
    case "$1" in
        1) printf '构建（内核 → ROM）' ;;
        2) printf '只编内核' ;;
        3) printf '只编 ROM' ;;
        4) printf '状态 / 体检' ;;
        5) printf '上次构建耗时报告' ;;
        6) printf '保存内核快照' ;;
        7) printf '清理（产物 + 快照 + ccache）' ;;
        8) printf '换一个产品（lunch）' ;;
        9) printf '退出' ;;
    esac
}

hui__tui_draw() {
    local sel=$1 i=1 n=9 mark
    local rule
    rule=$(printf '─%.0s' $(seq 1 64))
    local snap; snap=$(hui__cache_latest 2>/dev/null)
    local graph="缺失"
    [ -f "$HUI_TOP/out/soong/build.$HUI__PRODUCT.ninja" ] && graph="已就绪"
    local avail disk
    avail=$(df -B1 --output=avail "$HUI_TOP" 2>/dev/null | tail -1)
    disk=$(hui__human "${avail:-0}")

    {
        printf '\033[H'
        printf '%s\n' "$rule"
        printf '  hui %s    %s / %s\n' "$HUI_VERSION" "${HUI__PRODUCT:-?}" "${TARGET_BUILD_VARIANT:-?}"
        printf '%s\n' "$rule"
        printf '  源码树   %s\n' "${HUI_TOP:-未设置}"
        [ -n "${HUI__PRODUCT:-}" ] || printf '  %s\n' '  当前未 lunch —— 选 8 挑一个产品' 
        if [ -n "${HUI__KS:-}" ]; then
            local snaptxt="无"
            [ -n "$snap" ] && snaptxt=$(hui__short "$snap" 8)
            printf '  内核     %s   快照 %s\n' "$HUI__KS" "$snaptxt"
        else
            printf '  内核     预编译\n'
        fi
        printf '  构建图   %s\n' "$graph"
        printf '  负载     %s\n' "$(hui__pressure_line)"
        printf '  磁盘     %s 可用\n' "$disk"
        printf '%s\n' "$rule"
        while [ "$i" -le "$n" ]; do
            if [ "$i" -eq "$sel" ]; then mark="▸"; else mark=" "; fi
            printf '   %s %d  %s\n' "$mark" "$i" "$(hui__tui_label "$i")"
            i=$((i + 1))
        done
        printf '%s\n' "$rule"
        printf '  ↑↓ / j k 选择    Enter 执行    1-9 直选    q 退出\n'
    } >&2
}

hui__tui_loop() {
    local sel=1 n=9 key rest esc nl
    esc=$(printf '\033'); nl=$(printf '\n')
    printf '\033[?25l' >&2
    trap 'printf "\033[?25h" >&2' EXIT INT TERM
    while :; do
        hui__tui_draw "$sel" || return 1
        if ! hui__read1 key; then printf 'quit'; return 0; fi
        case "$key" in
            "$esc")
                hui__read2 rest
                case "$rest" in
                    '[A') sel=$(( sel > 1 ? sel - 1 : n )) ;;
                    '[B') sel=$(( sel < n ? sel + 1 : 1 )) ;;
                esac ;;
            k|K) sel=$(( sel > 1 ? sel - 1 : n )) ;;
            j|J) sel=$(( sel < n ? sel + 1 : 1 )) ;;
            q|Q) printf 'quit'; return 0 ;;
            [1-9]) printf '%s' "$key"; return 0 ;;
            "$nl"|'') printf '%s' "$sel"; return 0 ;;
        esac
    done
}

hui__tui_switch() {
    local cn p
    printf 'codename（例如 enchilada / nabu）：'
    read -r cn
    [ -n "$cn" ] || return 0
    p=$(hui__resolve_product "$cn") || { hui__err "认不出 $cn"; return 1; }
    if lunch "${p}-${TARGET_BUILD_VARIANT:-user}" >/dev/null 2>&1; then
        HUI__PRODUCT=""; HUI__DEV=""; HUI__KV_LOADED=""
        HUI__KS=""; HUI__KC=""; HUI__KA=""; HUI__KI=""; HUI__KV=""
        hui__require_env >/dev/null 2>&1
        hui__ok "已切换到 ${HUI__PRODUCT:-$p}（变体 ${TARGET_BUILD_VARIANT:-user}）"
    else
        hui__err "lunch ${p} 失败"
        return 1
    fi
}

hui__cmd_tui() {
    # 聊天/IDE 终端经常把 stdout 接成管道（提示符还在，但 [ -t 1 ] 为假）。
    # 只要能打开 /dev/tty，就把 stdin/stdout 借到控制终端上，菜单照样能交互。
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        if hui__have_tty; then
            exec 3<>/dev/tty
            exec 0<&3 1>&3
            exec 3>&-
        fi
    fi
    if [ ! -t 0 ] || [ ! -t 1 ]; then
        hui__err "hui tui 需要交互终端（当前 stdin/stdout 不是 tty）"
        hui__dim "  检测：stdin tty=$([ -t 0 ] && echo yes || echo no) · stdout tty=$([ -t 1 ] && echo yes || echo no) · /dev/tty=$(hui__have_tty && echo yes || echo no)"
        hui__dim "  在普通终端里运行；管道/重定向下没有界面"
        return 1
    fi

    # 没 lunch 也能进界面（界面里可以选「换一个产品」）
    hui__require_env >/dev/null 2>&1 || HUI__PRODUCT=""
    [ -n "${HUI__PRODUCT:-}" ] && HUI_NO_KATI=1 hui__kernel_vars >/dev/null 2>&1

    printf '\033[H\033[2J'
    local pick
    pick=$(hui__tui_loop) || return 1
    printf '\033[?25h'
    printf '\033[H\033[2J'

    case "$pick" in
        1|2|3|6|7)
            if [ -z "${HUI__PRODUCT:-}" ]; then
                hui__err "还没 lunch：在菜单里选 8 挑一个产品，或退出后 lunch <product>-<variant>"
                return 1
            fi ;;
    esac

    case "$pick" in
        1) hui__main "$(hui__device "$HUI__PRODUCT")_${TARGET_BUILD_VARIANT:-user}" ;;
        2) hui__build_lock || return 1
           HUI__M_FAST=0
           hui__panel_config
           hui__restore
           if hui__graph_verify; then
               HUI__M_FAST=1; hui__ok "构建图 复用"
           elif [ "${HUI_GRAPH_FIRST:-1}" != "0" ] && hui__runa_like; then
               # 只编内核也要先有图：按默认目标生成（图本身与目标无关，kernel 规则也在里面）
               hui__graph_first "$(hui__jobs_start)" "$(hui__default_target)"
               [ $? -eq 130 ] && return 130
           fi
           hui__run_kernel_phase "内核" "$(hui__jobs_start)" && hui__save ;;
        3) hui__build_lock || return 1
           HUI__M_FAST=0
           hui__panel_config
           if hui__graph_verify; then
               HUI__M_FAST=1; hui__ok "构建图 复用"
           elif [ "${HUI_GRAPH_FIRST:-1}" != "0" ] && hui__runa_like; then
               hui__graph_first "$(hui__jobs_start)" "$(hui__default_target)"
               [ $? -eq 130 ] && return 130
           fi
           hui__kernel_settle "$(hui__prodout "$HUI__PRODUCT")"
           hui__run_phase_retry "ROM" "$(hui__jobs_start)" "$(hui__default_target)" ;;
        4) hui__cmd_status; hui__cmd_doctor; printf '\n按回车返回… '; read -r _ ;;
        5) hui__cmd_report; printf '\n按回车返回… '; read -r _ ;;
        6) hui__build_lock || return 1; hui__save ;;
        7) hui__build_lock || return 1; hui__cmd_clean ;;
        8) hui__tui_switch ;;
        *) return 0 ;;
    esac
}

hui__cmd_graph() {
    hui__require_env || return 1
    local out=${OUT_DIR:-out} nj kati pkg
    nj="$HUI_TOP/$out/soong/build.$HUI__PRODUCT.ninja"
    kati="$HUI_TOP/$out/build-$HUI__PRODUCT.ninja"
    pkg="$HUI_TOP/$out/build-$HUI__PRODUCT-package.ninja"
    echo
    printf '  产品        %s / %s\n' "$HUI__PRODUCT" "${TARGET_BUILD_VARIANT:-?}"
    printf '  soong 图    %s\n' "$(hui__human "$(stat -c %s "$nj" 2>/dev/null || echo 0)")"
    printf '  kati 图     %s\n' "$(hui__human "$(stat -c %s "$kati" 2>/dev/null || echo 0)")"
    printf '  打包图      %s\n' "$(hui__human "$(stat -c %s "$pkg" 2>/dev/null || echo 0)")"
    printf '  生成时间    %s\n' "$(hui__graph_mtime)"
    if [ "$(hui__executor)" = "runa" ]; then
        printf '  图执行      Runa（--parallelism-file，运行中可调）\n'
    elif [ "$(hui__executor)" = "hui" ]; then
        printf '  图执行      自建 hui（--parallelism-file，运行中可调）\n'
    elif [ -f "$HUI_TOP/$out/siso_config/main.star" ]; then
        printf '  siso 配置   在位\n'
    else
        printf '  siso 配置   %s缺失%s（还不能复用）\n' "$hui__c_yel" "$hui__c_rst"
    fi
    case "${1:-}" in
        --verify|-v)
            hui__dim "  校验中（约 5~10 秒）…"
            if hui__graph_verify; then
                hui__ok "验证通过：kernel / ROM 可以直接复用这张图，跳过 kati+soong"
            else
                hui__warn "不能复用：$HUI__GRAPH_WHY"
                return 1
            fi ;;
        "")
            hui__dim "  加 --verify 校验输入有没有变；构建时 hui 会自动做这一步" ;;
        *)
            hui__err "用法：hui graph [--verify]"
            return 1 ;;
    esac
}

hui__cmd_help() {
    cat <<'EOF'

  hui —— AOSP / 类原生 ROM 构建加速

  整包：hui <codename>-<variant>，例：
      hui nabu-user                 内核 → ROM（= lunch + 构建）
      hui nabu-userdebug            换变体
      hui nabu-user bacon           指定构建目标

  命令：
    构建  hui build [目标…]    恢复内核快照 + 自适应并发 + 构建，成功后存快照
          hui m     [目标…]    别名
    查看  hui status | doctor | graph [--verify] | report | finger
    维护  hui save [--force] | restore | clean […] | tui | version
    帮助  hui help | hui help <命令> | hui <命令> --help

  构建示例：
      hui build                    自动探测目标
      hui build systemimage        只出镜像
      hui build bacon              出 OTA 包
      hui build kernel             只编内核（dtboimage / dtbimage 可一起给）
      HUI_COMBINE=1 hui build      内核 + ROM 合成一次 m
      HUI_MEM_ADMIT=0 hui build    关掉内存准入（满核，危险）

  clean 常用：
      hui clean                  m clean + 清当前产品内核快照（ccache 保留）
      hui clean -n               预演；-y 不询问
      hui clean --snapshot       只清内核快照
      hui clean --keep-snapshot  清 out/，保留快照（下次秒恢复）
      hui clean --ccache|--all   连 ccache / 全清
      hui clean <codename>       只清这个设备：出包目录 + 它的快照

  行为：
    - 构建图输入没变时验证后直接编，跳过 kati+soong（这棵树 12 分钟起步）。
    - 首次构建没有图：先跑 m --skip-ninja 只生成图，再交给执行器编
      （构图也在面板里跑：显示子阶段 / 已用时间 / 最新输出；HUI_GRAPH_FIRST=0 可关）。
    - 内核快照命中但 out/ 里没落最终镜像：先单独补内核再编 ROM，避免
      full-LTO 链接和 ROM 抢内存（HUI_KERNEL_FIRST=0 可关）。
    - 执行器默认自建 hui（运行中可调并发、按任务分池）；HUI_EXECUTOR 可换。

  环境变量：hui help env     命令细节：hui help <命令>

EOF
}
hui__help_cmd() {
    case "${1:-}" in
        env)
            cat <<'EOF'

  常用：
    HUI_THEME=wallpaper       主题：从壁纸取强调色；default = 内置配色
    HUI_WALLPAPER=/path.jpg   指定壁纸（默认自动找 KDE/GNOME/Hyprland/sway 的）
    HUI_EXECUTOR=hui          执行器：hui（自建，默认）| runa | siso | m | auto
    HUI_EXECUTOR_BIN=…        指定执行器路径
    HUI_GRAPH_FIRST=0         关掉“首次构建只生成图再切执行器”
    HUI_KERNEL_FIRST=0        关掉“先单独补内核再编 ROM”
    HUI_GRAPH_REUSE=0         每次重跑 kati+soong
    HUI_TARGET=bacon          覆盖默认构建目标
    HUI_JOBS=20               并发硬上限（默认核数）
    HUI_MEM_ADMIT=0           关掉内存准入（危险）
    HUI_MEM_PER_JOB=1.2       每个编译进程按多少 G 估
    HUI_MEM_RESERVE_MB=2048   准入时给系统预留 MB
    HUI_MEM_SWAP_FRACTION=0.5 准入时把多少空闲 swap 算作可用内存
    HUI_GRAPH_JOBS=16         构图阶段并发（默认核数一半，再按内存封顶，≤32）
    HUI_GRAPH_SISO=1         构图 bootstrap 用回 siso（默认用 AOSP ninja，避免截断账本）
    HUI_CPU_SCALE=auto        按核数/内存自适应（off = 固定 1/2 路每秒、nproc/2 构图）
    HUI_NICE=10               构建进程 nice；0 = 不降
    HUI_IONICE=6              ionice 等级；HUI_IONICE_CLASS=3 = idle
    HUI_COMBINE=1             内核/ROM 合成一次 m
    HUI_HIGHMEM_JOBS=3        高内存池并发
    HUI_POOLS=0               关掉按任务类型分池
    HUI_POOL_SPEC=…           池预算：R8:5120 KOTLIN:5120 JAVA:2048 RUST:2048 LINK:4096
    HUI_POOL_R8_JOBS=2        覆盖单池池深（KOTLIN/JAVA/RUST/LINK 同理）
    HUI_CCACHE_DIRECT=0       关掉 ccache 直接命中
    HUI_KEEP=1                每个产品保留几份内核快照
    HUI_DEEP_HASH=1           指纹改用内容哈希（慢但更严格）

  进阶 / 调试：
    HUI_STATE=.hui            状态目录（快照、锁、日志）
    HUI_RUNA=/path/runa       Runa 路径
    HUI_RUNA_CEILING=32       Runa 运行中允许升到的上限
    HUI_RUNA_ADOPT=1          首轮 Runa 加 assumeexisting
    HUI_WATCHDOG=0            关掉 siso 运行中调速
    HUI_THROTTLE_AT=35        压力超过该分数才降并发
    HUI_JOBS_MIN=6            动态调速下限
    HUI_TICK=1                调速采样周期（秒）
    HUI_RAMP_STEP=1           每次升降步长
    HUI_FLOOR_MB=600          可用内存底线
    HUI_CRITICAL=90           压力超过就整段暂停
    HUI_POOL_RESERVE_MB=3072  分池时给系统留的内存
    HUI_STATUS_INTERVAL=15    状态行刷新间隔（秒）
    HUI_DASHBOARD=0           关掉底部仪表盘
    HUI_PANEL=0               关掉构建面板
    HUI_NO_KATI=1             图没生成时跳过 kati 分析（TUI 快速启动）
    HUI_NINJA_LOG=…           覆盖 .ninja_log 路径
    HUI_CTRL_DEBUG=1          调速控制器调试输出
    HUI_ADMIT_TICK=1          运行中准入采样周期（秒）
    HUI_ADMIT_POLICY=pid      准入策略：pid（前馈+PI(D)，默认）| legacy（台阶式）
    HUI_CTRL_SETPOINT=0.30    PID 目标压力（0~1.5，越大越激进）
    HUI_CTRL_KP=8             比例增益（路/单位误差）
    HUI_CTRL_KI=0.4           积分增益（路/(单位·秒)）
    HUI_CTRL_KD=0             微分增益（默认关，测量微分）
    HUI_CTRL_TAU=5            压力测量 EMA 时间常数（秒）
    HUI_CTRL_UP=1             升并发限速（路/秒）
    HUI_CTRL_DOWN=2           降并发限速（路/秒，急停时 ×2）
    HUI_CTRL_FLOOR=2          pid 策略的安全下限（HUI_JOBS_MIN 优先）
    HUI_CTRL_I_LIMIT=6        积分限幅（路）
    HUI_CTRL_FF_TAU=15        前馈(可用内存+swap)EMA 时间常数（秒）
    HUI_CTRL_CPU_FREEZE=70    CPU PSI 超过该值不再升档
    HUI_CTRL_CPU_DOWN=85      CPU PSI 超过该值小幅降档
    HUI_CTRL_CPU_MIN_FRACTION=0.5 CPU 降档时不低于核数的该比例
    HUI_CTRL_RAISE_EPS=0.03   只有压力低于设定值这么多才允许升档
    HUI_CTRL_HEADROOM_SLACK=1.1 前馈平滑值允许超过瞬时内存上限的比例
    HUI_CTRL_HOLD=15          急停后多少秒内禁止升档
    HUI_CTRL_EMERGENCY_PSI=40 急停 PSI 阈值（%）
    HUI_CTRL_EMERGENCY_SWAP_MB=32 急停换出速率（MB/s）
    HUI_CTRL_EMERGENCY_CONFIRM=3 换出急停需连续确认的采样数（硬急停不受限）
    HUI_CTRL_EMERGENCY_AVAIL_MB=1536 急停可用内存（MB）

  完整说明：README.md

EOF
            ;;
        build|m)
            cat <<'EOF'

  hui build [目标…]     恢复内核快照 → 校验/复用构建图 → 内核 → ROM
  hui m [目标…]         同 build

  目标就是 m 的目标（systemimage、otapackage、bacon…）；不给就自动探测
  （HUI_TARGET > ROM 自带总目标 > bacon > otapackage > droid）。

  流程：
    0. 没有构建图：先 m --skip-ninja 只生成图（同样在面板里跑），再切执行器编
       （HUI_GRAPH_FIRST=0 关）
    1. 内核快照指纹匹配 → 直接恢复，跳过内核编译
    2. 构建图输入没变（约 5~10 秒校验）→ 跳过 kati+soong
    3. 快照命中但 out/ 里还没落最终内核镜像 → 先单独补内核，再编 ROM
       （避免 full-LTO 链接和 ROM 抢内存；HUI_KERNEL_FIRST=0 关）
    4. 内核编完立刻存快照；ROM 失败/被 Ctrl-C 也不会重编内核
  失败或中断不写内核完成标记，半成品不会被当成快照。

  常用：
    hui build systemimage        只出镜像
    hui build bacon              出 OTA
    HUI_COMBINE=1 hui build      内核 + ROM 合成一次 m
    HUI_MEM_ADMIT=0 hui build    关掉内存准入（满核，危险）

  并发与内存准入：hui status / hui doctor；环境变量：hui help

EOF
            ;;
        status)
            cat <<'EOF'

  hui status

  只读，不会触发构建。显示：产品/变体、输出目录、机器核数与内存、
  建议并发（内存准入 + 硬上限）、执行器、构建图、内核快照、ccache、磁盘。

EOF
            ;;
        doctor)
            cat <<'EOF'

  hui doctor

  体检并给建议：内存准入是否把并发压得太低、swap/PSI 压力、执行器是否可用、
  构建图是否可复用、内核快照/ccache/磁盘空间、常见坑（没 lunch、树不完整）。

EOF
            ;;
        graph)
            cat <<'EOF'

  hui graph             看构建图文件大小、生成时间、siso 配置是否在位
  hui graph --verify    校验输入有没有变（约 5~10 秒）；能复用就返回 0

  构建时 hui 会自动做同样的校验：通过就直接编，跳过 kati+soong。

EOF
            ;;
        report)
            cat <<'EOF'

  hui report

  上一次构建的耗时分布：优先读 out/siso_metrics.json（siso 树），
  没有就回退到 .ninja_log（自建 hui / Runa / soong_ui 都写这份）。
  路径可用 HUI_NINJA_LOG 覆盖。

EOF
            ;;
        save)
            cat <<'EOF'

  hui save [--force]

  把当前内核产物（KERNEL_OBJ/DTBO_OBJ/DTB_OBJ）存成快照，按指纹命名。
  默认要求内核阶段完整跑完（有 .hui-kernel-done），失败/中断的产物不存。
    --force   确认产物完整时强存：会补写完成标记，恢复时不再被判为不完整

EOF
            ;;
        restore)
            cat <<'EOF'

  hui restore

  只按指纹恢复内核快照，不做构建。返回码：
    0  恢复成功
    2  没有可用快照（或指纹不匹配）
    1  出错

EOF
            ;;
        finger|fingerprint)
            cat <<'EOF'

  hui finger            打印当前内核指纹（源码 + defconfig + 工具链 + kernel.mk）
  hui fingerprint       同义

  默认用「路径+大小+mtime」算，快；HUI_DEEP_HASH=1 改成内容哈希（慢但更严格）。
  指纹是快照能不能复用的唯一依据，不一致绝不恢复。

EOF
            ;;
        clean)
            cat <<'EOF'

  hui clean                 m clean + 清当前产品内核快照（ccache 保留）
  hui clean -n              预演，只列出会清什么、占多大
  hui clean -y              不询问
  hui clean --snapshot      只清内核快照
  hui clean --keep-snapshot 清 out/，保留内核快照（下次秒恢复）
  hui clean --out           同 --keep-snapshot（旧写法）
  hui clean --ccache        连 ccache 一起清（默认不动 ccache）
  hui clean --all           清 out/ + 内核快照 + ccache
  hui clean <codename>      只清这个设备：出包目录 + 它自己的内核快照

  构建进行中会拒绝清理（会校验 build.lock），-n 预演不受影响。

EOF
            ;;
        tui)
            cat <<'EOF'

  hui tui

  交互式菜单：构建（内核→ROM）、只编内核、只编 ROM、状态/体检、保存快照等。
  适合不想记参数的时候用；底层调用的还是上面这些子命令。

EOF
            ;;
        version)
            cat <<'EOF'

  hui version           打印 hui 版本号

EOF
            ;;
        help|""|-h|--help)
            hui__cmd_help ;;
        *)
            hui__err "没有这个命令的帮助：$1"
            hui__dim "  可用的：build status doctor graph report save restore finger clean tui version env"
            return 1 ;;
    esac
}
# ---------------------------------------------------------------------------
# 入口
# ---------------------------------------------------------------------------

# ---------------------------------------------------------------------------
# 入口：hui <子命令>  或  hui <codename>-<variant>
# ---------------------------------------------------------------------------

hui__self_file() {
    local f
    for f in "${HUI_HOME:-}/hui.sh" "${HUI_TOP:-}/hui/hui.sh" "${HUI_TOP:-}/vendor/hui/hui.sh"; do
        [ -n "$f" ] && [ -f "$f" ] && { printf '%s' "$f"; return 0; }
    done
    return 1
}

hui() {
    # hui.sh 被改过 → 在当前 shell 里自动重新 source（不用重开终端）
    local _hf _st
    if _hf=$(hui__self_file); then
        _st=$(stat -c '%Y-%s' "$_hf" 2>/dev/null)
        if [ -n "$_st" ] && [ "$_st" != "${HUI__LOADED_STAMP:-}" ]; then
            . "$_hf" >/dev/null 2>&1
            HUI__LOADED_STAMP=$_st
            hui "$@"
            return $?
        fi
    fi
    # 整个调用放在子 shell 里跑：构建锁用的 fd 9 会随子 shell 退出关闭，
    # 不会留在交互 shell 里，把后续构建或者另一个终端一直挡在门外。
    (
        case "${1:-}" in
            build|m|status|doctor|graph|report|save|restore|finger|fingerprint|clean|tui|version|help|-h|--help|"")
                hui__dispatch "$@" ;;
            *)
                # 第一个参数不是子命令，就当 codename-variant 走完整流程
                hui__main "$@" ;;
        esac
    )
}

# 记录本文件加载时的时间戳，供自动重载判断
if _hui_self=$(hui__self_file); then
    HUI__LOADED_STAMP=$(stat -c '%Y-%s' "$_hui_self" 2>/dev/null)
    unset _hui_self
fi

hui__dispatch() {
    local sub=${1:-help}
    [ $# -gt 0 ] && shift

    # 帮助入口：hui help / hui help <命令> / hui <命令> -h|--help
    case "$sub" in
        help|-h|--help|"")
            if [ -n "${1:-}" ]; then
                hui__help_cmd "$1"
            else
                hui__cmd_help
            fi
            return $? ;;
    esac
    case "${1:-}" in
        -h|--help)
            hui__help_cmd "$sub"
            return $? ;;
    esac

    case "$sub" in
        build|m)     hui__cmd_build "$@" ;;
        status)      hui__cmd_status "$@" ;;
        doctor)      hui__cmd_doctor "$@" ;;
        graph)       hui__cmd_graph "$@" ;;
        report)      hui__cmd_report "$@" ;;
        save)        hui__require_env && hui__build_lock && hui__kernel_vars && hui__save "$@" ;;
        restore)     hui__require_env && hui__build_lock && hui__kernel_vars && hui__restore "$@" ;;
        finger|fingerprint) hui__require_env && hui__cmd_fingerprint "$@" ;;
        clean)       hui__cmd_clean "$@" ;;
        tui)         hui__cmd_tui "$@" ;;
        version)     echo "hui $HUI_VERSION" ;;
        *)           hui__err "未知子命令: $sub（hui $HUI_VERSION）"
                     hui__dim "  看命令列表：hui help；单个命令：hui help <命令>"
                     hui__dim "  如果刚更新过 hui，先重新 source build/envsetup.sh"
                     return 1 ;;
    esac
}

hui__install_completion

# 本文件由 build/envsetup.sh -> vendor/hui/vendorsetup.sh 自动 source。
# 单独执行没有意义，也不做判断（BASH_SOURCE 在 zsh 下不存在）。
