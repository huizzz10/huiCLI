#!/bin/sh
# 把 hui 安装进一个 AOSP 源码树。
#
#   ./install.sh                 # 装进 $ANDROID_BUILD_TOP 或当前目录
#   ./install.sh ~/android          # 指定源码树
#   ./install.sh ~/android --copy   # 把 hui.sh 拷进去（树自包含，不在意外部仓库）
#   ./install.sh ~/android -u       # 卸载
#
# 装完只需要：
#   cd ~/android && source build/envsetup.sh
#   hui enchilada_user           # 换成你的 codename_variant

set -u

src_dir=$(cd "$(dirname "$0")" && pwd)
mode="link"
tree=""
uninstall=0

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \{0,1\}//'
}

for arg in "$@"; do
    case "$arg" in
        --copy)       mode="copy" ;;
        --link)       mode="link" ;;
        -u|--uninstall) uninstall=1 ;;
        -h|--help)    usage; exit 0 ;;
        -*)           echo "install.sh: 未知参数 $arg" >&2; exit 1 ;;
        *)            tree="$arg" ;;
    esac
done

[ -n "$tree" ] || tree="${ANDROID_BUILD_TOP:-$(pwd)}"
tree=$(cd "$tree" 2>/dev/null && pwd) || { echo "install.sh: 目录不存在: $tree" >&2; exit 1; }

if [ ! -f "$tree/build/envsetup.sh" ]; then
    echo "install.sh: $tree 不像 AOSP 源码树（没有 build/envsetup.sh）" >&2
    exit 1
fi

hook_dir="$tree/vendor/hui"
hook="$hook_dir/vendorsetup.sh"

if [ "$uninstall" = "1" ]; then
    rm -rf -- "$hook_dir"
    echo "已卸载: $hook"
    exit 0
fi

mkdir -p "$hook_dir" || exit 1

if [ "$mode" = "copy" ]; then
    cp "$src_dir/hui.sh" "$hook_dir/hui.sh" || exit 1
    [ -d "$src_dir/lib" ] && cp -R "$src_dir/lib" "$hook_dir/lib"
    if [ -d "$src_dir/prebuilts/runa" ]; then
        mkdir -p "$hook_dir/prebuilts"
        cp -R "$src_dir/prebuilts/runa" "$hook_dir/prebuilts/runa"
    fi
    {
        echo "# 由 hui/install.sh 生成 ${mode} 模式"
        echo "# 卸载：rm -rf $hook_dir"
        echo "if [ -n \"\${T:-}\" ] && [ -f \"$hook_dir/hui.sh\" ]; then"
        echo "    HUI_HOME=\"$hook_dir\""
        echo "    export HUI_HOME"
        echo "    HUI_TOP=\"\$T\""
        echo "    . \"$hook_dir/hui.sh\""
        echo "fi"
    } >| "$hook" || exit 1
    where="$hook_dir/hui.sh（拷贝）"
else
    {
        echo "# 由 hui/install.sh 生成 link 模式"
        echo "# 卸载：rm -rf $hook_dir"
        echo "HUI_HOME=\"$src_dir\""
        echo "export HUI_HOME"
        echo "if [ -n \"\${T:-}\" ]; then HUI_TOP=\"\$T\"; fi"
        echo ". \"\$HUI_HOME/vendorsetup.sh\""
    } >| "$hook" || exit 1
    where="$src_dir（软引用）"
fi

echo "已安装到: $tree"
echo "  挂载点  $hook"
echo "  工具    $where"
echo
echo "接下来:"
echo "    cd $tree"
echo "    source build/envsetup.sh"
echo "    hui <codename>_<variant>      # 例如 hui enchilada_user"
