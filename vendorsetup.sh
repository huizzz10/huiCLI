# Copyright (C) 2026 hui contributors
# SPDX-License-Identifier: MIT
#
# hui —— AOSP / LineageOS 构建加速工具
#
# build/envsetup.sh 会扫描 device/ vendor/ product/ 下 maxdepth 4 的
# vendorsetup.sh 并 source。本文件就是那个挂载点。
#
# 两种用法都能生效：
#
#   1) clone 进源码树（推荐，零安装）
#        cd ~/android && git clone https://github.com/huizzz10/HuiCLI.git vendor/hui
#        source build/envsetup.sh
#
#   2) clone 到别处，再装一次
#        git clone https://github.com/huizzz10/HuiCLI.git ~/tools/hui && ~/tools/hui/install.sh ~/android
#
# 想手动指定工具位置：export HUI_HOME=/path/to/hui

_hui_home="${HUI_HOME:-}"

if [ -z "$_hui_home" ] && [ -n "${T:-}" ]; then
    # clone 到 vendor/hui 的情况
    if [ -f "$T/vendor/hui/hui.sh" ]; then
        _hui_home="$T/vendor/hui"
    # 工具放在源码树根的 hui/ 下的情况（本仓库自己的开发布局）
    elif [ -f "$T/hui/hui.sh" ]; then
        _hui_home="$T/hui"
    fi
fi

if [ -n "$_hui_home" ] && [ -f "$_hui_home/hui.sh" ]; then
    HUI_HOME=$_hui_home
    export HUI_HOME
    if [ -n "${T:-}" ]; then
        HUI_TOP="$T"
    fi
    # 这棵源码树固定用自建 hui 执行器；找不到二进制时 hui.sh 会自动回退。
    # 想覆盖：export HUI_EXECUTOR=auto|runa|siso|m
    : "${HUI_EXECUTOR:=hui}"
    export HUI_EXECUTOR
    # shellcheck disable=SC1091
    . "$_hui_home/hui.sh"
fi

unset _hui_home
