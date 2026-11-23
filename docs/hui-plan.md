# hui 执行器：脱离 Runa 的方案（决定记录，暂未实施）

记录时间：2026-11-23（Asia/Shanghai）
状态：**已实现（原型）**，默认执行器已切到 `prebuilts/hui/hui`；Runa 保留为可选回退。
定位：Runa 不是要删掉，而是**可替换的执行器**——hui 的执行器本来就是可插拔的；
新执行器就绪后默认切到 `hui`，Runa 保留为可选/回退路径。

## 1. 结论

**采用路线 1：vendored 上游 ninja + 一个小补丁，作为 hui 的执行器（二进制名 `hui`）。**

不做自研执行器（路线 2），不做命令门闩包装（路线 3）。

- 执行器 = 上游 ninja（Apache-2.0）+ `--parallelism-file` 补丁（约 100 行 C++），
  仓库内叫 `hui`（与 hui.sh 同一个项目，不另起代号）。
- 目的：脱掉对 uwuAOSP `platform_external_runa` 的分支/二进制依赖（来源、可复现、许可），
  **不追求比 ninja 更快**。
- 分池（Java/Kotlin/R8/Rust）不在执行器里做，放 hui 侧改合并图的 pool 深度。

## 2. 为什么不是另外两条

| 路线 | 性能 | 结论 |
| --- | --- | --- |
| 1. ninja + 补丁 | **= ninja 基线**（Runa 也是 ninja fork，换过去不掉速） | 选它 |
| 2. 自研执行器（Go/Rust） | 执行层大概率慢 10~30%（1.6GB 合并图的解析/启动、GC）；只有调度可能小胜 | 不划算 |
| 3. 命令门闩包装 | 最差：每条命令多一次 fork/exec + 常驻 gate 进程 | 不选 |

真正决定构建时间的不是执行器：内核 LTO 链接（单线程）、内存准入/分池、图复用、
内核快照、ccache。执行器只占秒级。

参照数据（本树 4.3M edges 的实测）：图加载 ~1.2 s、`.ninja_log` 217 ms、
`.ninja_deps` 139 ms、峰值 RSS 21 GB——这是执行器本体的成本，自研很难做得更好。

## 3. 接口契约

`hui` 必须是 ninja 兼容执行器，并额外支持：

```
--parallelism-file FILE   运行中读取并发上限；文件内容为十进制整数
                          （1..-j 给的上限），每 ~250 ms 重读一次，
                          只影响还没启动的命令
```

- `-j N`：天花板，运行中只能降/升到 N 以内。
- 其余选项沿用上游 ninja：`-f`、`-C`、`-k`、`-l`、`-v`、`--quiet`、`-n`、
  `-d keepdepfile`、`-d keeprsp`、`-t`、`-w`、`-o`。
- **不实现** Runa 私有的 `-d assumeexisting`、`--control-socket`、`--frontend_file`。
  hui 只在"从 siso 切换执行器"时用 assumeexisting，届时走正常增量或退回 siso/m。
- `hui --help` 必须包含 `--parallelism-file`（hui 用它探测执行器能力）。

## 4. 实现要点

1. 上游版本：ninja **v1.11.1**（或 v1.12.1），Apache-2.0。
2. 补丁点（预计）：
   - `src/ninja.cc`：解析 `--parallelism-file`，存进 `Options`。
   - `src/build.h` / `src/build.cc`：`BuildConfig` 增加"当前并发"字段；
     `RealCommandRunner::CanRunMore()` 用当前值；主循环周期检查文件 mtime/内容并更新。
   - 并发下限 1，上限 = `-j` 传入值；文件缺失/非法时保持当前值并在 stderr 提示一次。
3. 构建：`./configure.py --bootstrap`（python3 + 宿主 g++），产物 `hui`。
4. 发布形态：
   - `hui/third_party/ninja/`：vendored 源码（带上游 tag）+ `hui.patch`；
   - `hui/tools/build-hui.sh`：一键构建 + 打补丁；
   - `hui/prebuilts/hui/hui`（二进制名就叫 `hui`）+ `COPYING` + `NOTICE`；
   - provenance 文档记录：上游 tag、补丁 SHA-256、二进制 SHA-256、可复现命令。
5. hui 侧接入（执行器可插拔，不删 Runa）：
   - 执行器探测顺序：`hui` → `runa` → `siso` → `m`（有新执行器就优先用它）；
   - `HUI_EXECUTOR=hui|runa|siso|m` 显式选择，`HUI_EXECUTOR_BIN=/path/to/hui` 指定路径；
   - `HUI_RUNA` 保留为兼容别名，`hui__runa_*` 继续支持 Runa；
   - `hui status` / 启动日志显示执行器名称、版本、SHA-256。
6. 分池（独立改动，不碰执行器）：
   - 在生成合并图时按命令特征分配 pool：`r8` / `kotlinc` / `javac` / `rustc` / 其他高内存；
   - 池深参考 uni 的比例：Java 2 G、Rust 2 G、高内存 4 G、R8 5 G、Kotlin 5 G；
   - 保留 `NINJA_HIGHMEM_NUM_JOBS` 等覆盖入口。
7. 回退：`HUI_EXECUTOR=ninja|siso|m`；没有 `hui` 时行为不变。

## 5. 待办

- [x] vendored 上游 ninja v1.12.1 到 `hui/third_party/ninja`（`src/`、`misc/`、`configure.py`、`COPYING`）
- [x] 写补丁 `hui.patch`：`--parallelism-file` + `HUI_POOL_<CLASS>_JOBS` 分池
- [x] `hui/tools/build-executor.sh` 自举构建，产出 `hui/prebuilts/hui/hui`（含 COPYING/NOTICE）
- [x] 合成图测试：动态并发 2 → 6 → 1；分池 r8=2/kotlin=3/javac=4/rust=1/ld=2 全部生效
- [x] hui 接入：执行器探测 `HUI_EXECUTOR_BIN` → `HUI_RUNA` → `prebuilts/hui/hui` → `prebuilts/runa/runa`
- [x] hui 侧算池深并导出 `HUI_POOL_*`（`HUI_POOLS` / `HUI_POOL_SPEC` / `HUI_POOL_<CLASS>_JOBS` 可调）
- [x] 真实图冒烟：`hui build nothing` 走自建执行器通过
- [ ] 真实增量/全量构建验证（同图同机器对比 Runa 的 `perf.tsv` 墙钟与 PSI）
- [ ] （可选，后续）评估是否继续打包 Runa；不删也能正常用

## 6. 风险

- **替换风险低**：执行器契约只有"ninja 兼容 + `--parallelism-file`"一条，
  Runa、自建 `hui`、以后别家的执行器都能互换；探测/回退逻辑已经存在。
- 没有 `--parallelism-file` 的执行器（原生 ninja / siso）也能用，只是失去运行中升并发。

- 维护 C++ fork：跟上游 rebase，一年一两次；补丁面小（只动选项解析和调度上限）。
- 增量正确性：`hui` 是上游 ninja，行为一致；补丁不碰 `RecomputeDirty`/日志格式。
- 启动开销：与 ninja 相同，不引入额外解析层。
- 与"适配所有类原生"的关系：执行器与 ROM 无关；自建后不再跟随 uwuAOSP 的分支节奏。
