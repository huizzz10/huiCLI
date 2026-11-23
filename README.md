# hui

AOSP / LineageOS 等类原生 ROM 源码树的构建加速工具，随仓库带自建执行器。

一条命令走完 **构建图 → 内核 → ROM**：图能复用就直接编，内核产物跨清理复用，
并行度 = 核数硬上限 + 内存准入，运行中按内存压力动态升降，运行中的编译器不中断。

## 安装

**方式一：clone 进源码树（零安装，推荐）**

```bash
cd ~/android
git clone https://github.com/<you>/hui vendor/hui
source build/envsetup.sh
hui nabu-user
```

`build/envsetup.sh` 结尾会扫 `device/ vendor/ product/` 下 maxdepth 4 的
`vendorsetup.sh`，`vendor/hui/vendorsetup.sh` 正好在扫描范围内。克隆完直接可用，
不需要装任何东西，也没有改任何被 git 跟踪的文件。

改了 `hui.sh` 之后**不用重新 source**：下一条 `hui` 命令发现文件变了会自动重载
（按 mtime+size 判断，实测 bash/zsh 都通过）。

自建执行器（`prebuilts/hui/hui`，ninja 兼容）随仓库分发，所以 AOSP / LineageOS
这类没有 `prebuilts/siso` 的树也能用运行中动态并发。首次构建先用
`m --skip-ninja` 只生成构建图，随后交给执行器编；之后每次直接复用图。

**方式二：clone 到别处，装一次**

```bash
git clone https://github.com/<you>/hui ~/tools/hui
~/tools/hui/install.sh ~/android            # 默认软引用，改仓库即生效
~/tools/hui/install.sh ~/android --copy     # 或者拷进去，源码树自包含
~/tools/hui/install.sh ~/android -u         # 卸载
```

不想装也行，`export HUI_HOME=/path/to/hui` 后自己 source。

### 不改你的本地环境

所有效果都只在 `source build/envsetup.sh` 之后、**当前这个 shell 会话**里生效：

- 不写 `.zshrc` / `.bashrc` / 任何 rc 文件
- zsh 补全需要 `compinit` 时用 `compinit -C -D`：`-D` 明确不写 `~/.zcompdump`，
  只在内存里建补全系统
- 所有状态都在源码树的 `.hui/` 里，`rm -rf .hui` 就干净，不留痕
- `hui clean` 默认保留 ccache；要清显式加 `--ccache`

## 仓库结构

```
hui/
├── hui.sh              # 工具本体（被 source，不直接执行）
├── vendorsetup.sh      # envsetup 挂载点
├── install.sh          # 安装到任意源码树（link / copy / uninstall）
├── lib/admit.py        # Runa 运行时准入门（读写 --parallelism-file）
├── prebuilts/runa/runa # 随仓库分发的 ninja 兼容执行器（Linux x86_64）
├── README.md
└── LICENSE
```

运行时产生的（已在 .gitignore 里）：

```
<源码树>/.hui/       # 内核快照与状态，随时可以整个删掉
```

## 发布到 GitHub

```bash
cd ~/android/hui
git init -b main
git add .
git commit -m "hui: AOSP 构建加速工具"
git remote add origin git@github.com:<you>/hui.git
git push -u origin main
```

别人拿去用就是开头那两行：`git clone ... vendor/hui` + `source build/envsetup.sh`。

## 用

```bash
cd ~/android
source build/envsetup.sh

hui nabu-user                 # = lunch lineage_nabu-user + 编内核 + 编 ROM
```

一条命令走完 **构建图 → 内核 → ROM**：

```
认 codename → lunch → 校验构建图 → 内核（必要时）→ 存快照 → ROM → 结束
```

**构建图能复用**（图在、输入没变）：验证后直接 `siso` 编，跳过 12 分钟级的
kati+soong 分析。**图不在了 / 过期了**：这一次 `m` 会先重建图，再编内核。

**内核快照能命中时**：跳过内核，直接编 ROM。
**快照命中不了**：先编内核，成功立刻存快照，再编 ROM；ROM 挂了也不影响
内核快照。想回到「内核+ROM 一次 m」的老模式：`HUI_COMBINE=1`。

**「内核编完了」怎么判定**：不是看 `Image` 在不在，而是看
`KERNEL_OBJ/.hui-kernel-done`。这个标记只在 `kernel + dtboimage + dtbimage`
整段 `m` 返回 0 之后才写，开始编之前先删，里面记着 `Image`/`dtbo.img` 等产物的
size+mtime。所以中断、失败、或产物被单独改过，复检都不会当成就绪，
`hui save` 也会拒绝保存半成品（确认完整要强存：`hui save --force`）。
注意：老版本存的快照没有这个标记，恢复后会按「不完整」处理并重编一次内核；
编完的新快照会带上标记。

参数格式就是 `<codename>-<variant>`（下划线写法也认）。等价写法：

```bash
hui nabu                      # 变体默认 user
hui nabu-userdebug            # 换变体
hui nabu-user bacon           # 指定构建目标
hui lineage_nabu-user         # 直接给 lunch 串
```

## 子命令

| 命令 | 作用 |
|---|---|
| `hui <codename>-<variant>` | 构建图 → 内核 → ROM 全流程 |
| `hui build [目标…]` | 只跑构建（恢复内核快照 + 图复用 + 自适应并发） |
| `hui m [目标…]` | 同上 |
| `hui status` | 产品 / 构建图 / 内核缓存 / ccache / 磁盘 |
| `hui doctor` | 体检并给建议 |
| `hui graph --verify` | 单独校验构建图能不能直接复用 |
| `hui report` | 上次构建耗时分布（siso 指标或 `.ninja_log`，含最慢任务/产物类型） |
| `hui tui` | 交互式菜单界面 |
| `hui save [--force]` | 手动保存当前内核产物 |
| `hui restore` / `hui finger` | 内核快照管理 |
| `hui clean` | 等价 `m clean` + 清当前产品内核快照（ccache 默认保留，`--ccache` 才清）；`--keep-snapshot` 保留快照；`hui clean <codename>` 只清单个设备 |
| `hui version` / `hui help` | 版本 / 帮助 |

## 构建中的全屏面板

`hui <codename>-<variant>` / `hui build` 时，构建输出全部收进日志文件，
屏幕上是一块面板（左栏三段用分隔线隔开）：

```
 编译机器                              │  产品信息
 ────────────────────────────────      │  ROM    EvolutionX-17.0-20261124-nabu-12.4-Unofficial
 CPU   [████████░░░░░░░░░░░]  43%      │  PROD   lineage_nabu / user
 LOAD  13.98 10.42 6.63                │  PHASE  构建图完成 · 内核完成 · ROM
 MEM   [█░░░░░░░░░░░░░░░░░░]  10%      │  KERNEL kernel/xiaomi/nabu
 AVAIL 27.6 GiB                        │  SNAP   3425452d
 SWAP  [███████████░░░░░░░░]  58%      │  GRAPH  已就绪
 PSI   12%  jobs 22/32                 │  PROG   [██████████░░░░░░░░░░]  45%
 DISK  506G free                       │ ──────────────────────────────────
 TIME  00:12:34                        │ [ 45% 1234/5678] CC pkg/mod.o
 LOG   out/hui/nabu/hui-build-...log   │ [ 50% 1300/5678] LINK libx.so
 ────────────────────────────────      │ ...
 OS    Arch Linux                      │
 KERNEL 7.3.5-zen1-1-zen               │
 CPU   i9-13980HX · 24C/32T            │
 RAM   31 GiB                          │
 DISK  931G                            │
 ────────────────────────────────      │
 PLATFORM 17                           │
 DEVICE   nabu                         │
 GMS      true                         │
 VARIANT  user                         │
 BUILD_ID CP2A.260605.016              │
 PATCH    2026-11-01                   │
                                       │ ──────────────────────────────────
                                       │ [1234/5678 21%] LINK libx.so
                                       │     0:45 compile out/.../foo.a
                                       │     1:15 link out/.../libx.so
```

- **左栏**：两段，用分隔线隔开——
  1) 编译机器：CPU / 内存 / swap 按阈值变色（<50% 绿、<80% 黄、≥80% 红）+ LOAD、
     可用内存、PSI、磁盘、已用时间、日志；
  2) 机器信息：OS / KERNEL / CPU 型号+核线程 / RAM / DISK；
  最后是**紧凑对齐表**：`PLATFORM / DEVICE / GMS / VARIANT / BUILD_ID / PATCH`，
  左边键对齐、右边值对齐（值用次强调色；ROM 全名只在右上第一行显示，这里不重复）
- **右上**：产品信息——第一行是 ROM 全名（窄了自动折行），下面 PROD/PHASE/KERNEL/
  SNAP/GRAPH + 进度条（颜色跟随壁纸主题，`HUI_THEME=default` 时为蓝色）
- **右列**：编译日志实时尾部（右上栏下面开始），`↑↓` / `PgUp/PgDn` 翻页、`End` 回到实时
- **右下框**：第一排是进度行（`[已编/总数 百分比] 当前在编什么`），下面跟最近动作 + 耗时；
  数据取自 `out/.ninja_log` 尾部 128KB；终端太矮时进度行退回最底行
- **PHASE**：逐段显示「构建图完成 · 内核完成 · ROM」，构建结束再补 `ROM完成`
- **自适应**：宽 <76 列收起左栏；尺寸变化整屏重画；行数 <16 退回普通输出

## 交互界面：`hui tui`

```
────────────────────────────────────────────────────────────────
  hui 5.2.0    lineage_nabu / user
────────────────────────────────────────────────────────────────
  源码树   /home/user/android
  内核     kernel/xiaomi/nabu   快照 3425452d
  构建图   缺失
  负载     可用 27259MB / swap 1611MB/81919MB / PSI 0% → 压力 0%，目标并发 32/32
  磁盘     412.7 GiB 可用
────────────────────────────────────────────────────────────────
     1  构建（内核 → ROM）
   ▸ 2  只编内核
     3  只编 ROM
     4  状态 / 体检
     5  上次构建耗时报告
     6  保存内核快照
     7  清理（产物 + 快照 + ccache）
     8  换一个产品（lunch）
     9  退出
────────────────────────────────────────────────────────────────
  ↑↓ / j k 选择    Enter 执行    1-9 直选    q 退出
```

- **没 lunch 也能进**：界面里按 8 直接挑产品；需要产品的动作会提示先选
- **不会卡在 kati**：构建图缺失时，界面不去跑 `get_build_var`，只显示"未知"
- 纯 ANSI，不依赖 dialog / whiptail / 任何 TUI 库
- bash 和 zsh 都能跑（读键分别用 `read -n1` / `read -k1`）
- 界面在子 shell 里画，选完退出回到正常屏幕再执行，不会把你的终端留在 raw 模式
- 非交互终端会直接拒绝，不会卡住脚本

## Tab 补全

载入时自动注册，不用额外配置。

**bash**：`complete -F`，`hui <TAB>` 列出子命令，`hui nab<TAB>` 补 `nabu-user`。

**zsh**：走 `compdef`。如果你的 zsh 还没跑过 `compinit`（有些精简配置没有），
工具会自己 `autoload -Uz compinit && compinit -C` 一次——不动你已有的补全。

候选来自两处：

- 子命令：`build m status doctor report save restore finger clean tui version help`
- 构建目标：扫 `device/*/*/` 里真正定义了 `PRODUCT_NAME` 的目录，生成
  `<codename>-user / -userdebug / -eng`，缓存在 `.hui/completions`（7 天过期）

这台机器上总共 126 个候选。

## 执行器：自建 hui（默认）/ Runa / siso / m

仓库自带一个自建的 Linux x86_64 执行器 `prebuilts/hui/hui`：上游 ninja v1.12.1
（`third_party/ninja`，Apache-2.0）+ [hui.patch](third_party/ninja/hui.patch)，用
`hui/tools/build-executor.sh` 一键重建。补丁只加两个能力：

- `--parallelism-file FILE`：运行中改总并发，**只影响还没启动的任务**，已经在跑的
  编译器不会被中断——「有空间就满载、没空间就收」靠的就是它；
- `HUI_POOL_<CLASS>_JOBS=N`：按任务类型分池限流（r8 / kotlin / javac / rust / 链接器），
  池深由 hui 按内存预算算好导出；
- `--duration-file FILE`：把历史耗时喂给 ninja 的关键路径调度，长任务优先启动。hui 每次
  构建前会把 `out/.ninja_log` 汇总成 `.hui/<product>/durations.tsv` 自动传进去；`hui report`
  也用同一份数据（没有 siso 指标时）。

Runa（`prebuilts/runa/runa`）保留为可选执行器，来源与许可见
[docs/runa-provenance.md](docs/runa-provenance.md)。

`source build/envsetup.sh` 后自动选执行器：

| 树的状况 | 执行器 |
|---|---|
| 干净树 / 没装 siso 的 AOSP、Lineage | **自建 hui**（`prebuilts/hui/hui`） |
| 已经用 siso 建过的树（有 `out/.siso_deps`） | siso（换执行器会丢增量状态） |
| 图还没生成（第一次构建） | 原生 `m`，但会显式 `SOONG_NINJA=ninja` 建一份执行器能读的增量状态；从第二次构建起用自建 hui |
| 手动指定 | `HUI_EXECUTOR=hui` / `runa` / `siso` / `m`；`HUI_EXECUTOR_BIN` 指定任意兼容执行器 |
| 想从 siso 树切到 Runa | `HUI_EXECUTOR=runa`：检测到 siso 状态且 Runa 无日志时，自动加 `-d assumeexisting` 接管已有输出，避免全量重编；不想信任已有产物可 `HUI_RUNA_ADOPT=0` |

自建 hui、Runa 和 siso 都直接吃 hui 拼的合并图（kati + package + soong 三份），所以
AOSP / LineageOS 这类树不需要改构建系统。`vendor/hui` 在
`build/envsetup.sh` 的 vendorsetup 扫描范围内，克隆进去就能用。

### 按任务类型分池

总并发之外，执行器还按任务类型限流（只对自建 hui 生效；Runa 会忽略这些变量）：

```
pool = max(1, min(总并发, (MemAvailable − HUI_POOL_RESERVE_MB) / 该类预算))
```

默认预算：r8 5G、kotlin 5G、javac 2G、rust 2G、链接器 4G。分类按 rule 名匹配
（`r8` / `kotlin` / `javac` / `rust` / `.ld`），在真实 soong 图上对应
`g.java.r8`、`g.java.kotlinc`、`g.java.javac`、`g.rust.*`、`g.cc.ld`。

## 适配任意类原生

hui 不假设构建系统是 Lineage 还是其它类原生 ROM：

- **产品识别**：`TARGET_PRODUCT` 取 `_` 前缀得到 ROM 名（`lineage_nabu` → lineage、
  `crDroid_nabu` → crDroid、`aosp_cheetah_car` → aosp），只用于显示和默认目标。
- **默认构建目标**按优先级探测：`HUI_TARGET` → ROM 自带的总目标（`evolution:` /
  `crDroid:` 之类）→ Lineage 系通用的 `bacon` → 类原生（有 `vendor/<rom>`）用
  `otapackage` → 纯 AOSP 用 `droid`。换 ROM 树不用改代码。
- **产品解析**：`hui nabu` / `hui nabu-user` 扫 `device/**/*_<codename>.mk`，
  任意 ROM 前缀都能认；`hui nabu-user bacon` 可显式给目标。
- **ROM 全名**：`LINEAGE_VERSION` → `EVOLUTION_VERSION` → `CRDROID_VERSION` →
  `AOSPA_VERSION` → `YAAP_VERSION` 依次取第一个非空的，最后回退 `产品-变体`；
  换 ROM 树（包括 LineageOS）不用改代码。
- **内核**：读 `TARGET_KERNEL_SOURCE` 等 Lineage 系变量；为空（预编译内核 / 外置
  内核）时自动跳过内核阶段，只做图复用 + ROM 构建。

## 并行度：核数硬上限 + 内存准入 + 运行中调节

硬上限是核数，实际起手并发由「内存准入」算：

```
ceiling = nproc
admit   = (MemAvailable − HUI_MEM_RESERVE_MB) / HUI_MEM_PER_JOB
jobs    = min(ceiling, admit)              # 31G 这台约 -j19~21
```

为什么不是直接 `-j32`：30.9G 内存装不下 32 个 clang/linker。实测 -j32 时
可用内存掉到 538MB、swap 用到 40G、PSI 67%、memory stall 999ms/s。

**准入值按阶段重算**：内核开始、ROM 开始各算一次，内核腾出的内存 ROM 阶段
能用上。阶段内：

- **Runa** 用 `--parallelism-file` 实时升降，上限 `HUI_RUNA_CEILING`：
  压力持续 2/6/20 秒就降 25%，冷却 20 秒；连续 15 秒健康（可用内存 ≥
  max(6G, total/5)、PSI<10、无 swap）后每 15 秒加 `max(1, initial/6)`。
  从 `initial` 往上加还要求至少一个核真正空闲（idle，不含 iowait）。
- **siso** 没有运行中改并发的接口，`--local_jobs` 启动后固定，控制器只能
  往下收；往上加要等下一个阶段重新起 siso。

- **高内存任务**（链接/打包）单独限流，按 uni 的池公式在每个阶段开始时重算：
  `P = max(1, min(J, floor((A − 3G) / 4G)))`（`NINJA_HIGHMEM_NUM_JOBS`；
  显式设置 `HUI_HIGHMEM_JOBS` 可覆盖）；
- **内核阶段**的 `-j` 由 `KERNEL_MAKE_FLAGS` 决定（`-j$(getconf _NPROCESSORS_ONLN)`），
  与 ROM 阶段分开；
- **ROM/Soong** 走执行器：Runa 用控制文件，siso 用 `--local_jobs`。

构建子进程统一降优先级（`nice 10` + `ionice` best-effort 6），只在有竞争时让路；
想关：`HUI_NICE=0`。

**siso 的补充控制器（默认开）**：压力低于 `HUI_THROTTLE_AT` 不降；高过就从
准入值往 `HUI_JOBS_MIN` 收，降是立刻落到目标，升是连续 3 秒低压才 +1。
执行层用占空比停/放 siso 调度器——不打断已经在跑的编译器。

想无视内存直接满核：`HUI_MEM_ADMIT=0 HUI_JOBS=max`（不推荐，会重现 40G swap 的悬崖）。

**siso 的压力评分 score ∈ [0,100]，四项线性加权**

| 信号 | 权重 | 打满条件 |
|---|---|---|
| 可用内存 `MemAvailable` | 40% | ≤2G（≥8G 记 0） |
| PSI `memory full avg10` | 25% | 40% |
| **swap 换入速率**（`pswpin`） | 20% | 3000 pages/s（约 12MB/s） |
| **swap 占用率** | 15% | 70% |

swap 换入那条是重点：换入速率代表"真缺页"，比占用率更早、更准地反映系统在抖。

**siso 的目标并发**：score ≤ `HUI_THROTTLE_AT` → 准入值；高过之后从准入值收到
下限（`HUI_JOBS_MIN`，默认 6）。降立即落到目标，升要连续 3 秒低压才 +1。

**siso 的执行层用占空比，不是开关**

```
ratio = target / max
每轮：停 siso (1-ratio) 秒 → 放行 ratio 秒
```

target 15 / max 20 → 25% 的时间暂停派发、75% 正常跑，平均并发贴着 15。

**siso 的临界阀**：可用内存 < 600MB 或 score ≥ 90 时，把派发目标压到下限，
**不暂停构建**：已经在跑的编译器继续跑完并释放内存，siso 只是不再加新任务；
内存一宽裕就按 3 秒节奏慢慢爬回准入值。Runa 没有这个阀：它只改控制文件，
运行中的任务本来就不会被打断。

**阶段感知**：构建图分析（soong_build）是单线程，没有 siso 进程，这时候
siso 控制器不调也不停。

**内核阶段的限制**：`kernel` 目标内部是 `make -j32`（写在 `KERNEL_MAKE_FLAGS`
里），执行器管不到它的并发；调节主要作用在 ROM/Soong 阶段。想改内核并发
得改设备配置并重新生成图。

**想固定并发不调速**：siso 下 `HUI_WATCHDOG=0`；Runa 下把 `HUI_RUNA_CEILING`
设成和初始值一样（或 `HUI_EXECUTOR=siso` 用老路径）。

## 构建图复用：验证后直接编

AOSP 的 `m` 每次都要 ckati + soong_build 重新生成 ninja 图，这棵树上 12 分钟起步。
`hui` 在构建前先校验现有图：

- soong depfile 里的 `Android.bp` 没变、没少
- `.globs` 里源文件 glob 结果没变（只有目录 mtime 变了才重跑那些 glob）
- 新增/删除的 `Android.bp`、`Android.mk`、`*.mk` 会触发重分析
- soong used env / 产品 / 变体 / `OUT_DIR` / `TARGET_RELEASE` 与图一致
- `build/soong`、`build/blueprint`、`build/make` 没改，`soong_build` 没重编
- kati stamp 里的 makefile 没变、soong 图的分片齐全

全过 → 用 `siso ninja -f out/.hui-combined.<product>.ninja` 直接编，跳过
kati+soong（图加载约 2~6 秒）。任何一项拿不准就回退到完整 `m`，**不拿旧图硬编**。

```bash
hui graph --verify     # 单独校验，看看为什么能/不能复用
HUI_GRAPH_REUSE=0      # 本次强制重跑分析
```

注意：直连 siso 会跳过 soong_ui 的 product config / build number 更新。
增量编译没问题，但 `ro.build.version.incremental` 之类不会因为这次构建而变化；
要完整走一遍 soong_ui 时用 `HUI_GRAPH_REUSE=0`。

## 内核复用

1. **指纹** = 内核源码清单（相对路径+大小+mtime）+ defconfig 片段 + clang 版本 + `kernel.mk`
   - 约 300ms；`HUI_DEEP_HASH=1` 可改成内容哈希
2. **保存**：成功后把 `obj/KERNEL_OBJ`（及 `DTB_OBJ`/`DTBO_OBJ`）
   `cp -a --reflink=auto` 到 `.hui/<产品>/kernel/<指纹>/`
3. **恢复**：构建前指纹命中就拷回去，保留纳秒级 mtime，ninja 直接跳过内核
4. 未命中时打印**哪几个文件变了**

实测（nabu，3.5GiB / 17,341 个文件）：

```
保存耗时    10.9s        实际占用增量  约 +24MB（reflink）
指纹计算    300ms        恢复后 mtime  与源逐一致
```

**11 秒 + 24MB，换掉 20~30 分钟的内核重编。**

## 通用性

**产品解析**（`hui <codename>-<variant>` 里的 codename）：

1. 树里存在 `<codename>.mk` 且里面有 `PRODUCT_NAME` → 直接当产品名
2. 找 `device/**/<codename>/`，读其中的 `PRODUCT_NAME`，优先取 `<厂商>_<codename>` 形态
3. 兜底 `lineage_<codename>`

真机树都覆盖：`enchilada → lineage_enchilada`、`nabu → lineage_nabu`、
`cheetah_car → aosp_cheetah_car`、`arm64 → mini_arm64`。
一个目录里有多个产品时会提示，让你改传完整产品名。
只认真正的产品文件——`board/kernel/arm64.mk` 这种内核 makefile 不会被误当成产品。

**内核**：

- 有 `TARGET_KERNEL_SOURCE` 且目录存在 → 编内核
  （Lineage 系带 `dtboimage dtbimage`，其它树只编 `kernel`）
- 源码没检出 / 预编译内核 → 自动跳过内核阶段，只编 ROM
- 指纹里的构建规则按存在性取：`vendor/lineage/build/tasks/kernel.mk` →
  `build/make/core/tasks/kernel.mk` → `build/kernel/build.sh`

**构建目标**：有 ROM 自带总目标（`evolution:` / `crDroid:`…）→ 用它；有 `bacon:` → `bacon`；否则 `droid`。

**换设备**：每个产品独立快照目录，互不影响。
**换 ROM**：只要还是 AOSP 系（`build/envsetup.sh` + `m`），逻辑不变。

某个设备要是已经有自己专门的一套构建流程，直接别拿 `hui` 跑它就行。
工具不注册任何全局钩子，只是 `source build/envsetup.sh` 时多定义一个 `hui` 函数，
和别的脚本互不干扰。

## 清理：`hui clean`

**默认等价于 `m clean` + 清当前产品的内核快照**（ccache 保留）：

```bash
hui clean                   # = m clean + 清当前产品内核快照（ccache 不动）
hui clean --ccache          # 额外清 ccache
hui clean --keep-snapshot   # 清 out/，保留内核快照（下次秒恢复）
hui clean -n                # 先看会清多少
hui clean -y                # 不询问
```

实际执行的是构建系统自己的 `clean` 目标，不是我们另外写一套删除逻辑——
所以语义和 AOSP 完全一致，也不会有"删漏了"的风险。

**带 codename 就只清那一个设备**：

```bash
hui clean enchilada             # out/target/product/enchilada + .hui/lineage_enchilada
hui clean enchilada --ccache    # 额外清 ccache
hui clean --snapshot            # 只清内核快照
```

带 codename 时会先列大小再确认：

```
  build     out/target/product/nabu                    3.5 GiB
  snapshot  .hui/lineage_nabu                          3.5 GiB
  ccache    ~/.ccache                                38.7 MiB
  合计                                                 7.0 GiB

确认清理？[y/N]
```

安全约束：

- 只允许删 `out/`、`.hui/`、ccache 目录三处，其它路径一律拒绝
- 目标是软链就拒绝
- `rm -rf --one-file-system`，不跨挂载点
- 带 codename 时产物目录必须精确到该设备，解析成 `out/target/product` 本身就不删
- ccache 走 `ccache -C`：只清条目，保留 `max_size` 等配置

## 它不做什么

- 不缓存 `out/soong/.intermediates`（那是 Soong 的活）
- 不动 ccache / siso 共享状态
- 不改任何被 git 跟踪的文件：工具本体和挂载点都是 untracked，`repo sync` 不会删

## 配色主题

默认从**桌面壁纸**提取强调色（标题、分隔线、进度条都跟着变），红/绿/黄等语义色不动：

- **壁纸发现**：KDE（`plasma-org.kde.plasma.desktop-appletsrc` 的 `Image=file://…`）、
  GNOME（`gsettings`）、Hyprland（`hyprpaper` 的 `preload` / `swww` 缓存）、
  sway/i3（`swaybg -i` / `feh --bg-*`）；也可 `HUI_WALLPAPER=/path.jpg` 直接指定。
- **取色**：ImageMagick 缩图量化 → 选饱和度最高的主色，再挑一个色相差 ≥40° 的
  次强调色 → HSL 提亮（饱和度 ≥50%、亮度 62–78% 保证终端可读）。
  主色用于标签/标题/进度条，**次色用于 ROM 名和构建配置等号后的值**；
  truecolor 终端用 24-bit，否则退 256 色。
- **缓存**：`.hui/theme`（键 = 壁纸路径 + mtime/size），壁纸不换就不重算。
- **回退**：没壁纸 / 没 magick / 没 python3 → 静默用内置配色；
  `HUI_THEME=default` 强制内置。

## 环境变量

| 变量 | 默认 | 说明 |
|---|---|---|
| `HUI_THEME` | `wallpaper` | 从桌面壁纸提取强调色；`default` = 内置配色（红绿黄蓝） |
| `HUI_WALLPAPER` | 自动探测 | 指定壁纸文件；默认按 KDE / GNOME / Hyprland / sway 配置找 |
| `HUI_EXECUTOR` | `hui` | `auto` / `hui` / `runa` / `siso` / `m`；本设备树 vendorsetup 默认 `hui`，找不到自建执行器时自动回退 |
| `HUI_TARGET` | 自动探测 | 覆盖默认构建目标（`bacon` / `otapackage` / ROM 同名 target…） |
| `HUI_RUNA` | 空 | Runa 路径（默认用仓库自带的 `prebuilts/runa/runa`） |
| `HUI_RUNA_CEILING` | 核数 | Runa 运行中允许升到的上限 |
| `HUI_ADMIT_TICK` | `2` | Runa 准入采样周期（秒） |
| `HUI_RUNA_ADOPT` | `0` | `1` = 首轮加 `-d assumeexisting`（信任磁盘已有输出）；`0` = 不信任。强制 `HUI_EXECUTOR=runa` 切 siso 树时默认自动开 |
| `HUI_JOBS` | 核数 | 硬上限；`max` = 满核（默认） |
| `HUI_MEM_ADMIT` | `1` | `0` = 关掉内存准入，按硬上限起步（危险） |
| `HUI_MEM_PER_JOB` | `1.2` | 每个编译进程按多少 G 估（准入用） |
| `HUI_MEM_RESERVE_MB` | `2048` | 准入时给系统预留多少 MB |
| `HUI_NICE` | `10` | 构建进程的 nice 值；`0` = 不降优先级 |
| `HUI_IONICE` | `6` | ionice best-effort 等级 |
| `HUI_IONICE_CLASS` | `2` | `3` = idle 级 IO |
| `HUI_WATCHDOG` | `1` | `0` = 关掉运行中调速，固定并发 |
| `HUI_THROTTLE_AT` | `35` | 压力超过这个分数才降并发 |
| `HUI_GRAPH_FIRST` | `1` | 首次没有构建图时，先 `m --skip-ninja` 只生成图，再交给执行器编；`0` = 旧行为（一次性 m 编到底） |
| `HUI_KERNEL_FIRST` | `1` | 内核快照命中但 `out/` 里没有最终 kernel 镜像时，先单独补内核再编 ROM（避免 full-LTO 和 ROM 抢内存）；`0` 关 |
| `HUI_GRAPH_REUSE` | `1` | `0` = 每次重跑 kati+soong，不复用构建图 |
| `HUI_COMBINE` | `0` | `1` = 内核/ROM 合成一次 `m`（老流程；省一次图加载，但内核快照要等 ROM 结束） |
| `HUI_JOBS_MIN` | `6` | 并发下限 |
| `HUI_TICK` | `1` | 采样周期（秒） |
| `HUI_RAMP_STEP` | `1` | 每个 tick 最多变动几个并发 |
| `HUI_AVAIL_HIGH_MB` | `8192` | 可用内存高于它记 0 分 |
| `HUI_AVAIL_LOW_MB` | `2048` | 可用内存低于它记满分 |
| `HUI_CRITICAL` | `90` | 临界的压力阈值 |
| `HUI_FLOOR_MB` | `600` | 临界的可用内存阈值 |
| `HUI_CTRL_DEBUG` | `0` | `1` = 每 tick 打印评分与目标 |
| `HUI_KEEP` | `1` | 每个产品保留几份内核快照；默认只留最近一份，指纹不匹配时旧快照直接删除 |
| `HUI_HIGHMEM_JOBS` | `3` | `NINJA_HIGHMEM_NUM_JOBS` |
| `HUI_EXECUTOR_BIN` | 空 | 指定执行器路径（优先于自带 `prebuilts/hui/hui`） |
| `HUI_POOLS` | `1` | `0` = 关闭按任务类型分池 |
| `HUI_POOL_SPEC` | `R8:5120 KOTLIN:5120 JAVA:2048 RUST:2048 LINK:4096` | 类名:单任务预算（MB） |
| `HUI_POOL_RESERVE_MB` | `3072` | 分池时给系统预留的 MB |
| `HUI_POOL_<CLASS>_JOBS` | 自动 | 覆盖单个池的池深（如 `HUI_POOL_R8_JOBS=2`） |
| `HUI_DEEP_HASH` | `0` | `1` = 内核源码内容哈希 |

## 注意

- 改了内核源码 / defconfig / clang / `kernel.mk`，指纹会变，自动走完整重编——这是对的
- 怀疑内核状态不对：`hui clean` 后重来一次
- `reflink` 在 ext4 上会退化成完整拷贝（3.5G×2），功能不受影响
- `.hui/` 可以随时整个删掉，没有任何副作用
# HuiCLI
