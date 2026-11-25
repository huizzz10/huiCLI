# hui

AOSP / 类原生 ROM 源码树的构建加速工具，随仓库带自建 ninja 兼容执行器。

一条命令走完 **构建图 → 内核 → ROM**：图能复用就跳过 kati+soong，内核快照跨 `out/` 清理复用，
并发按内存准入、运行中随压力升降。

## 特性

- **构建图复用**：输入没变就直接读合并图编，跳过 10~15 分钟分析；拿不准就回退完整 `m`。
- **内核快照**：内核产物按指纹缓存，恢复后 ninja 直接跳过内核（实测 11 秒换 20~30 分钟）。
- **全屏面板**：构图 / 内核 / ROM 都有阶段、日志与进度；终端太小或非 TTY 自动退回普通输出。
- **内存准入 + 动态并发**：起手按「可用内存 + 一半空闲 swap」算 `-j`；运行中是 前馈 + PI(D) 控制器（PSI/换出速率/可见内存），升降限速、抗饱和、急停兜底；高内存任务和 r8/kotlin/javac/rust 分池。
- **失败兜底**：内核/ROM 阶段 OOM（`Error 137` / `已杀死`）自动降 3 路并发重试一次；无面板也写阶段日志和失败复盘。

## 安装

```bash
# 推荐：克隆进源码树，source 即用（不改被 git 跟踪的文件）
cd ~/android
git clone https://github.com/huizzz10/HuiCLI.git vendor/hui
source build/envsetup.sh

# 或者装到任意源码树：默认软链；--copy 拷入；-u 卸载
git clone https://github.com/huizzz10/HuiCLI.git ~/tools/hui
~/tools/hui/install.sh ~/android
```

效果只作用于 `source build/envsetup.sh` 之后的当前 shell；状态在源码树 `.hui/`，删掉即干净。

## 用法

```bash
hui nabu-user            # lunch lineage_nabu-user + 内核 + ROM
hui nabu                 # 变体默认 user
hui nabu-user bacon      # 指定 m 目标
hui build                # 已 lunch 时只跑构建
```

流程：`认 codename → lunch → 校验/生成构建图 → 内核（必要时）→ 存快照 → ROM`。

- 没有图：先在面板里跑 `m --skip-ninja` 生成三份图（`HUI_GRAPH_FIRST=0` 关）。
- 图可复用：直接交执行器编（`HUI_GRAPH_REUSE=0` 强制重跑分析）。
- 内核快照命中：跳过内核；内核编完立刻存快照，ROM 失败/中断也不重编。
- ROM 阶段不会重编内核：会理顺 `.config`、`Image*` 的 mtime 和 `.ninja_log` 记录时间。
- 任意 ROM：`lineage_` / `crDroid_` / `aosp_` 前缀和 `device/**/<codename>` 自动识别。

## 子命令

| 命令 | 作用 |
|---|---|
| `hui <codename>-<variant>` | 构建图 → 内核 → ROM 全流程 |
| `hui build [目标…]` / `hui m` | 只构建（快照恢复 + 图复用 + 自适应并发） |
| `hui status` / `hui doctor` | 状态 / 体检建议 |
| `hui graph --verify` | 单独校验图能否复用 |
| `hui report` | 上次构建耗时分布 |
| `hui tui` | 交互菜单（没 lunch 也能进） |
| `hui save [--force]` / `restore` | 内核快照保存 / 恢复 |
| `hui clean […]` | `m clean` + 清当前产品快照（ccache 保留） |
| `hui version` / `hui help [env\|<命令>]` | 版本 / 帮助 |

Tab 补全载入时自动注册（bash / zsh）。

## 面板、日志与失败

- 全屏面板：左栏机器与产品信息，右栏日志，右下进度；构图阶段显示子阶段和已用时间。
- 非 TTY / 终端过小：退回普通输出，但每个阶段照样写
  `<OUT_DIR>/hui/<codename>/hui-<产品>-<时间>.log`。
- 失败时打印「失败报错」摘要和完整日志路径。
- 构建结束输出摘要：总用时、阶段（图复用/重生成、内核快照/已编）、缓存、日志路径。

## 清理

```bash
hui clean                  # out/ + 当前产品快照，ccache 保留
hui clean --keep-snapshot  # 只清 out/，留快照（下次秒恢复）
hui clean --ccache|--all   # 连 ccache / 全清
hui clean <codename>       # 只清该设备：出包目录 + 快照
```

只允许删 `out/`、`.hui/`、ccache 三处；目标是软链就拒绝；带 codename 时先列大小再确认。

## 环境变量（常用）

| 变量 | 默认 | 说明 |
|---|---|---|
| `HUI_EXECUTOR` | `hui` | `hui` / `runa` / `siso` / `m` / `auto` |
| `HUI_TARGET` | 自动 | 覆盖默认构建目标（`bacon` / `otapackage` / …） |
| `HUI_JOBS` | 核数 | 并发硬上限；`max` = 满核 |
| `HUI_GRAPH_REUSE` / `HUI_GRAPH_FIRST` | `1` | 强制重分析 / 首次只构图 |
| `HUI_KERNEL_FIRST` | `1` | 快照命中但 `out/` 缺最终镜像时先补内核 |
| `HUI_COMBINE` | `0` | `1` = 内核 + ROM 合成一次 `m` |
| `HUI_MEM_ADMIT` | `1` | `0` 关内存准入（危险） |
| `HUI_MEM_PER_JOB` | `1.2` | 每个编译进程按多少 G 估 |
| `HUI_MEM_SWAP_FRACTION` | `0.5` | 准入时把多少空闲 swap 算作可用内存 |
| `HUI_ADMIT_POLICY` | `pid` | 运行中准入策略：`pid`（前馈+PI(D)）/ `legacy`（台阶式） |
| `HUI_CTRL_SETPOINT` / `HUI_CTRL_UP` / `HUI_CTRL_DOWN` | `0.30` / `1` / `2` | PID 目标压力 / 升速 / 降速（路每秒） |
| `HUI_CTRL_FF_TAU` / `HUI_CTRL_CPU_FREEZE` | `15` / `70` | 前馈平滑时间常数（秒）/ CPU PSI 升档门控（%） |
| `HUI_CTRL_EMERGENCY_CONFIRM` | `3` | 换出急停需连续确认的采样数（硬急停不受限） |
| `HUI_GRAPH_JOBS` | 核数一半 | 构图阶段并发（再按内存封顶、≤32，不超过编译并发） |
| `HUI_CPU_SCALE` | `auto` | 按核数/内存自适应；`off` = 固定 1/2 路每秒、nproc/2 构图 |
| `HUI_POOLS` / `HUI_POOL_SPEC` | `1` / … | 任务分池开关与预算 |
| `HUI_WATCHDOG` / `HUI_THROTTLE_AT` | `1` / `35` | 运行中调速开关 / 压力阈值 |
| `HUI_THEME` / `HUI_WALLPAPER` | `wallpaper` | 面板配色 |

完整列表：`hui help env`。

## 执行器

默认 `prebuilts/hui/hui`（ninja v1.12.1 + `hui.patch`）：支持 `--parallelism-file`
（运行中改并发，只影响未启动任务）、`HUI_POOL_*` 分池、`--duration-file`（历史耗时喂关键路径）。
`tools/build-executor.sh` 可从 `third_party/ninja/` 重建。

树里已有 siso 状态时继续用 siso；也可 `HUI_EXECUTOR=runa|siso|m` 或 `HUI_EXECUTOR_BIN`
指定其他兼容执行器。Runa 为可选回退，来源见 [docs/runa-provenance.md](docs/runa-provenance.md)。

## 注意

- 改内核源码 / defconfig / clang / `kernel.mk` 会改指纹，自动完整重编。
- 直连执行器会跳过 soong_ui 的 product config，`ro.build.version.incremental` 不随本次构建变化；
  要完整走 soong_ui 用 `HUI_GRAPH_REUSE=0`。
- `reflink` 在 ext4 上会退化成完整拷贝（功能不受影响）。
- 内核状态可疑：`hui clean` 重来；`.hui/` 可随时整删。
- 不缓存 soong 中间产物、不动 ccache / siso 共享状态、不改任何被 git 跟踪的文件。

## 许可

自有代码 MIT，见 [LICENSE](LICENSE)。以下组件为 Apache-2.0，见
[LICENSE-APACHE-2.0](LICENSE-APACHE-2.0) 与 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)：
`third_party/ninja/`、`prebuilts/hui/hui`、`prebuilts/runa/runa`、`lib/admit.py`。
调度策略参考 [uwuAOSP/uwuCLI](https://github.com/uwuAOSP/uwuCLI)（Apache-2.0）。
