# hui

AOSP / LineageOS 等类原生 ROM 源码树的构建加速工具，随仓库带自建执行器。

一条命令走完 **构建图 → 内核 → ROM**：图能复用就直接编，内核产物跨清理复用，
并发按内存准入起步、运行中随压力升降，且不打断已经在跑的编译器。

## 安装

**克隆进源码树**（推荐，零安装）：

```bash
cd ~/android
git clone https://github.com/<you>/hui vendor/hui
source build/envsetup.sh
hui nabu-user
```

`build/envsetup.sh` 会扫 `device/ vendor/ product/` 下 maxdepth 4 的 `vendorsetup.sh`，
`vendor/hui/vendorsetup.sh` 正好在范围内。克隆完直接可用，不改任何被 git 跟踪的文件。

**装到任意源码树**：

```bash
git clone https://github.com/<you>/hui ~/tools/hui
~/tools/hui/install.sh ~/android          # 默认软引用，改仓库即生效
~/tools/hui/install.sh ~/android --copy   # 拷进去，源码树自包含
~/tools/hui/install.sh ~/android -u       # 卸载
```

不想装也行：`export HUI_HOME=/path/to/hui` 后自己 source `hui.sh`。

所有效果只在 `source build/envsetup.sh` 之后的**当前 shell 会话**生效：不写
`.zshrc` / `.bashrc` 等任何 rc 文件；状态全在源码树的 `.hui/` 里，`rm -rf .hui` 即干净。

## 用法

```bash
hui nabu-user              # = lunch lineage_nabu-user + 编内核 + 编 ROM
hui nabu                   # 变体默认 user
hui nabu-userdebug         # 换变体
hui nabu-user bacon        # 指定构建目标
hui lineage_nabu-user      # 直接给 lunch 串
```

流程：`认 codename → lunch → 校验构建图 → 内核（必要时）→ 存快照 → ROM`。

- **构建图能复用**：验证后直接交执行器编，跳过 kati + soong 分析。
- **内核快照命中**：跳过内核直接编 ROM；内核编完立刻存快照，ROM 挂了也不影响。
- 回到「内核 + ROM 一次 `m`」的老模式：`HUI_COMBINE=1`。

「内核编完了」不看 `Image` 在不在，而看 `KERNEL_OBJ/.hui-kernel-done`：标记只在
`kernel + dtboimage + dtbimage` 整段 `m` 返回 0 后写入，记录产物 size + mtime；
中断或失败不写，半成品不会被当成快照（要强存用 `hui save --force`）。

### 子命令

| 命令 | 作用 |
|---|---|
| `hui <codename>-<variant>` | 构建图 → 内核 → ROM 全流程 |
| `hui build [目标…]` / `hui m` | 只跑构建（快照恢复 + 图复用 + 自适应并发） |
| `hui status` | 产品 / 构建图 / 内核缓存 / ccache / 磁盘 |
| `hui doctor` | 体检并给建议 |
| `hui graph --verify` | 单独校验构建图能否直接复用 |
| `hui report` | 上次构建耗时分布（最慢任务 / 产物类型） |
| `hui tui` | 交互式菜单（没 lunch 也能进） |
| `hui save [--force]` / `restore` / `finger` | 内核快照保存 / 恢复 / 查看 |
| `hui clean […]` | `m clean` + 清当前产品内核快照（ccache 默认保留） |
| `hui version` / `hui help [env\|<命令>]` | 版本 / 帮助 |

Tab 补全载入时自动注册（bash `complete -F`、zsh `compdef`），子命令和
`<codename>-<variant>` 都能补，不用额外配置。

构建时有个全屏面板：左栏机器与产品信息，右栏实时日志尾部，右下当前进度；
终端太窄或太矮会自动退回普通输出。

## 构建图复用

`m` 每次都要重跑 kati + soong_build 生成 ninja 图，本机上 12 分钟起步。hui 先校验现有图：
soong depfile 里的 `Android.bp` 没变没少、`.globs` 结果没变、环境 / 产品 / 变体 /
`OUT_DIR` 与图一致、`build/soong` 等没改。全过就由执行器直接读合并图
`out/.hui-combined.<product>.ninja` 开编（图加载 2~6 秒）；
任何一项拿不准就回退完整 `m`，**不拿旧图硬编**。

```bash
hui graph --verify     # 看看为什么能 / 不能复用
HUI_GRAPH_REUSE=0      # 本次强制重跑分析
```

注意直连执行器会跳过 soong_ui 的 product config / build number 更新，增量编译没问题，
但 `ro.build.version.incremental` 不会因这次构建变化；要完整走 soong_ui 时用 `HUI_GRAPH_REUSE=0`。

## 内核快照

指纹 = 内核源码清单（相对路径 + size + mtime）+ defconfig 片段 + clang 版本 + `kernel.mk`，
约 300ms（`HUI_DEEP_HASH=1` 改成内容哈希）。内核编成功后把 `obj/KERNEL_OBJ`（及
`DTB_OBJ` / `DTBO_OBJ`）用 `cp -a --reflink=auto` 存进 `.hui/<产品>/kernel/<指纹>/`；
构建前指纹命中就拷回去，保留纳秒级 mtime，ninja 直接跳过内核。

nabu 实测（3.5 GiB / 17,341 个文件）：保存 10.9s、增量约 +24MB、恢复后 mtime 逐一致
——用 11 秒换掉 20~30 分钟的内核重编。未命中时会打印是哪些文件变了。

## 并发

核数是硬上限，起手并发按内存准入：

```
admit = (MemAvailable − HUI_MEM_RESERVE_MB) / HUI_MEM_PER_JOB
jobs  = min(nproc, admit)        # 30.9G 这台约 -j19~21
```

为什么不是直接 `-j32`：30.9G 装不下 32 个 clang/linker。实测 `-j32` 时可用内存掉到
538MB、swap 用 40G、PSI 67%、memory stall 999ms/s。

- 准入值在内核开始、ROM 开始各重算一次，内核腾出的内存 ROM 阶段能用上。
- 自建 hui / Runa 用 `--parallelism-file` 实时升降，只影响还没启动的任务。
- siso 没有运行中改总并发的接口，只能收；用占空比停 / 放调度器做软调速。
- 高内存任务（链接 / 打包）单独限流：`P = max(1, min(J, (A − 3G) / 4G))`。
- 按任务类型分池：r8 / kotlin 5G、javac / rust 2G、链接器 4G，按 rule 名分类。
- 构建子进程统一 `nice 10` + ionice best-effort，只在有竞争时让路。

想无视内存满核：`HUI_MEM_ADMIT=0 HUI_JOBS=max`（会重现 40G swap 的悬崖，不推荐）。
想固定并发不调速：`HUI_WATCHDOG=0`。

## 执行器

仓库自带 Linux x86_64 执行器 `prebuilts/hui/hui`（ninja 兼容）：上游 ninja v1.12.1
（`third_party/ninja`，Apache-2.0）+ [hui.patch](third_party/ninja/hui.patch)，
可用 `tools/build-executor.sh` 一键重建。补丁加了三件事：

- `--parallelism-file`：运行中改总并发，只影响还没启动的任务；
- `HUI_POOL_<CLASS>_JOBS`：按任务类型分池限流（r8 / kotlin / javac / rust / 链接器）；
- `--duration-file`：把历史耗时喂给关键路径调度，长任务优先启动。

`source build/envsetup.sh` 后自动选：

| 树的状况 | 执行器 |
|---|---|
| 干净树 / 没装 siso 的 AOSP、Lineage | **自建 hui**（默认） |
| 已经用 siso 建过的树（有 `out/.siso_deps`） | siso（换执行器会丢增量状态） |
| 图还没生成（第一次构建） | 原生 `m`，但显式 `SOONG_NINJA=ninja` 建一份执行器能读的增量状态；第二次起用自建 hui |
| 手动指定 | `HUI_EXECUTOR=hui` / `runa` / `siso` / `m`；`HUI_EXECUTOR_BIN` 指定任意兼容执行器 |

Runa（`prebuilts/runa/runa`）保留为可选执行器，来源与许可见
[docs/runa-provenance.md](docs/runa-provenance.md)。从 siso 树切到 Runa 时
`HUI_EXECUTOR=runa` 会自动加 `-d assumeexisting` 接管已有输出，避免全量重编
（不想信任已有产物：`HUI_RUNA_ADOPT=0`）。

## 适配各种类原生

- **产品识别**：`TARGET_PRODUCT` 的下划线前缀就是 ROM 名（`lineage_nabu` → lineage，
  `crDroid_nabu` → crDroid，`aosp_cheetah_car` → aosp），只用于显示和默认目标。
- **默认构建目标**：`HUI_TARGET` → ROM 自带总目标（`evolution:` / `crDroid:` 等）→
  Lineage 系的 `bacon` → 类原生（有 `vendor/<rom>`）用 `otapackage` → 纯 AOSP 用 `droid`。
- **产品解析**：`hui nabu` / `hui nabu-user` 扫 `device/**/*_<codename>.mk`，任意 ROM 前缀
  都能认；最后兜底 `lineage_<codename>`。一个目录有多个产品时会提示改传完整产品名。
- **ROM 全名**：`LINEAGE_VERSION` → `EVOLUTION_VERSION` → `CRDROID_VERSION` →
  `AOSPA_VERSION` → `YAAP_VERSION`，最后回退 `产品-变体`。
- **内核**：读 `TARGET_KERNEL_SOURCE`；为空（预编译 / 外置内核）时自动跳过内核阶段，
  只做图复用 + ROM 构建。换设备每个产品独立快照目录，互不影响。

## 清理

`hui clean` 等价于 `m clean` + 清当前产品内核快照，ccache 默认保留：

```bash
hui clean                   # out/ + 当前产品快照，ccache 不动
hui clean --ccache          # 连 ccache 一起清
hui clean --keep-snapshot   # 清 out/，保留快照（下次秒恢复）
hui clean -n / -y           # 预演 / 不询问
hui clean enchilada         # 只清单个设备：出包目录 + 它的快照
hui clean --snapshot        # 只清内核快照
```

执行的是构建系统自己的 clean 目标，语义与 AOSP 一致。安全约束：只允许删 `out/`、
`.hui/`、ccache 三处；目标是软链就拒绝；`rm -rf --one-file-system`；带 codename 时
产物目录必须精确到该设备，且先列大小再确认；ccache 走 `ccache -C`，保留 `max_size` 等配置。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `HUI_EXECUTOR` | `hui` | `auto` / `hui` / `runa` / `siso` / `m` |
| `HUI_EXECUTOR_BIN` | 空 | 指定执行器路径（优先于自带 `prebuilts/hui/hui`） |
| `HUI_THEME` | `wallpaper` | 从桌面壁纸取强调色；`default` = 内置配色 |
| `HUI_WALLPAPER` | 自动探测 | 指定壁纸；默认找 KDE / GNOME / Hyprland / sway 配置 |
| `HUI_TARGET` | 自动探测 | 覆盖默认构建目标（`bacon` / `otapackage` / …） |
| `HUI_JOBS` | 核数 | 并发硬上限；`max` = 满核 |
| `HUI_MEM_ADMIT` | `1` | `0` = 关内存准入（危险） |
| `HUI_MEM_PER_JOB` | `1.2` | 每个编译进程按多少 G 估 |
| `HUI_MEM_RESERVE_MB` | `2048` | 准入时给系统预留多少 MB |
| `HUI_GRAPH_REUSE` | `1` | `0` = 每次重跑 kati + soong |
| `HUI_GRAPH_FIRST` | `1` | 首次没图时先 `m --skip-ninja` 只生成图，再交执行器编 |
| `HUI_KERNEL_FIRST` | `1` | 快照命中但 `out/` 没最终镜像时，先补内核再编 ROM |
| `HUI_COMBINE` | `0` | `1` = 内核 / ROM 合成一次 `m`（老流程） |
| `HUI_WATCHDOG` | `1` | `0` = 关掉运行中调速，固定并发 |
| `HUI_THROTTLE_AT` | `35` | 压力分数超过它才降并发 |
| `HUI_POOLS` | `1` | `0` = 关掉按任务类型分池 |
| `HUI_POOL_SPEC` | `R8:5120 KOTLIN:5120 JAVA:2048 RUST:2048 LINK:4096` | 类名:单任务预算（MB） |
| `HUI_HIGHMEM_JOBS` | `3` | `NINJA_HIGHMEM_NUM_JOBS` |
| `HUI_KEEP` | `1` | 每个产品保留几份内核快照 |
| `HUI_NICE` | `10` | 构建进程 nice 值；`0` = 不降优先级 |
| `HUI_DEEP_HASH` | `0` | `1` = 内核指纹改用内容哈希 |

完整列表：`hui help env`。

## 注意

- 改了内核源码 / defconfig / clang / `kernel.mk`，指纹会变，自动走完整重编——这是对的。
- `reflink` 在 ext4 上会退化成完整拷贝（3.5G × 2），功能不受影响。
- 怀疑内核状态不对：`hui clean` 后重来一次。
- `.hui/` 可以随时整个删掉，没有副作用。
- 不缓存 `out/soong/.intermediates`（那是 Soong 的活）；不动 ccache / siso 共享状态；
  不改任何被 git 跟踪的文件。

## 仓库结构

```
hui/
├── hui.sh                  # 工具本体（被 source，不直接执行）
├── vendorsetup.sh          # build/envsetup.sh 的挂载点
├── install.sh              # 安装到任意源码树（link / copy / uninstall）
├── lib/admit.py            # Runa 运行时准入门（读写 --parallelism-file）
├── prebuilts/hui/hui       # 自建执行器（ninja 兼容，Linux x86_64）
├── prebuilts/runa/runa     # 可选执行器 Runa
├── third_party/ninja/      # 上游 ninja 源码 + hui.patch
├── tools/build-executor.sh # 从 third_party/ninja 重建执行器
├── docs/                   # 执行器方案与 Runa 来源记录
├── README.md
└── LICENSE
```

运行时产生的 `<源码树>/.hui/`（内核快照与状态，随时可删）已在 `.gitignore` 里。

## 许可

MIT，见 [LICENSE](LICENSE)。`third_party/ninja` 与 `prebuilts/` 下的执行器为 Apache-2.0，
见各自的 `COPYING` / `NOTICE`。
