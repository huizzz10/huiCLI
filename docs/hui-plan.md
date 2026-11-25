# hui 执行器：方案与实现记录

更新时间：2026-11-25（Asia/Shanghai）
状态：**已上线**——默认执行器为 `prebuilts/hui/hui`（上游 ninja v1.12.1 + `hui.patch`）。
**Runa 保留为可选回退**（2026-11-25 决定，不删除打包）。

## 1. 结论

采用路线 1：**vendored 上游 ninja + 一个小补丁**，作为 hui 的执行器（二进制名 `hui`）。

- 不做自研执行器（Go/Rust），不做命令门闩包装。
- 执行器 = 上游 ninja（Apache-2.0）+ `--parallelism-file` / `HUI_POOL_<CLASS>_JOBS`
  补丁（约 350 行 patch）。
- 目的：脱掉对 uwuAOSP `platform_external_runa` 的分支/二进制依赖，
  **不追求比 ninja 更快**；分池不在执行器里做，放 hui 侧改合并图的 pool 深度。
- Runa 仍作为可选执行器保留：`HUI_EXECUTOR=runa`、`HUI_RUNA=/path` 或
  `HUI_EXECUTOR_BIN=/path` 均可切回；来源与许可见
  [runa-provenance.md](runa-provenance.md)。

路线对比（保留自最初的决策记录）：

| 路线 | 性能 | 结论 |
| --- | --- | --- |
| 1. ninja + 补丁 | = ninja 基线 | 选它 |
| 2. 自研执行器 | 执行层大概率慢 10~30% | 不划算 |
| 3. 命令门闩包装 | 每条命令多一次 fork/exec + 常驻 gate | 不选 |

真正决定构建时间的是内核 LTO 链接、内存准入/分池、图复用、内核快照和 ccache；
执行器本身只占秒级。

## 2. 现状

### 2.1 默认与回退

- 默认：`prebuilts/hui/hui`（ninja 1.12.1），支持运行中并发与分池。
- 回退：Runa（`prebuilts/runa/runa`，来源见 [runa-provenance.md](runa-provenance.md)）。
- 再回退：siso / 原生 `m`。

### 2.2 仓库内文件

| 文件 | 用途 |
|---|---|
| `third_party/ninja/` | 上游 ninja v1.12.1 源码 + `hui.patch` |
| `tools/build-executor.sh` | 打补丁并 `./configure.py --bootstrap`，产出 `prebuilts/hui/hui` |
| `prebuilts/hui/{hui,COPYING,NOTICE}` | 默认执行器二进制 + 许可/声明 |
| `prebuilts/runa/{runa,COPYING,NOTICE}` | 可选回退（保留决定见 §7） |
| `docs/runa-provenance.md` | Runa 来源、哈希与许可记录 |

### 2.3 与 hui.sh 的关系（v5.5.3 起）

- 执行器写 `.ninja_log` **v6**；AOSP 自带 ninja 1.9 和 siso 写 **v5**。
- hui 执行器读到 v5 会 unlink 账本、把所有边判脏（全量重编）。
- 因此 hui.sh 在构图阶段（`m --skip-ninja`，soong bootstrap 走 siso）做
  v6 账本备份/恢复：构图前备份、构图后若被改写成 v5 则还原。详见 `hui.sh`
  的 `hui__graph_ledger_guard`。

## 3. 接口契约

`hui` 必须是 ninja 兼容执行器，并额外支持：

```
--parallelism-file FILE   运行中读取并发上限；文件内容为十进制整数
                          （1..-j 给的上限），每 ~200 ms 重读一次，
                          只影响还没启动的命令
```

- `-j N`：天花板，运行中只能降/升到 N 以内。
- 其余选项沿用上游 ninja：`-f`、`-C`、`-k`、`-l`、`-v`、`--quiet`、`-n`、
  `-d keepdepfile`、`-d keeprsp`、`-t`、`-w`、`-o`。
- `HUI_POOL_<CLASS>_JOBS=N`：按命令类别限制并发（r8 / kotlin / javac / rust / .ld），
  由执行器在启动时读取；池深由 hui.sh 计算后通过环境变量传入。
- **不实现** Runa 私有的 `-d assumeexisting`、`--control-socket`、`--frontend_file`。
  hui.sh 只在显式切 **Runa** 且需要接管 siso 输出时，才给 Runa 传
  `-d assumeexisting`；自建 `hui` 执行器永远不会收到这个参数。
- `hui --help` 必须包含 `--parallelism-file`（hui.sh 用它探测执行器能力）。

## 4. Provenance（可复现性）

- 上游：ninja **v1.12.1**，<https://github.com/ninja-build/ninja>，Apache-2.0。
- 源码：`third_party/ninja/`（含 `src/`、`misc/`、`configure.py`、`COPYING`）。
- 补丁：`third_party/ninja/hui.patch`
  - SHA-256：`b73375ce7f7b3477563f2d6c94774afba2d1097d8a2e1278fb7df0647e710342`
- 二进制：`prebuilts/hui/hui`（`--version` 输出 `1.12.1`）
  - SHA-256：`58d77518809addee7d374f5646f366aa1ab907a9185ac22488163c69f875e3a0`
- 重建：

  ```bash
  hui/tools/build-executor.sh      # python3 + 宿主 g++，产物覆盖 prebuilts/hui/hui
  ```

- 许可：执行器本体 Apache-2.0，见 `prebuilts/hui/COPYING`；
  本地修改说明见 `prebuilts/hui/NOTICE` 和 `THIRD_PARTY_NOTICES.md`。

## 5. hui 侧接入

实际选择顺序（`hui__executor()`）：

1. 显式 `HUI_EXECUTOR=hui|runa|siso|m` / `HUI_EXECUTOR_BIN=...`；
2. 树里已有 `out/.siso_deps` 且 siso 可用 → 继续 siso（保住 siso 增量状态）；
3. 探测 `--parallelism-file`：`prebuilts/hui/hui` 优先，其次 `prebuilts/runa/runa`；
4. 回退 siso；
5. 回退原生 `m`。

兼容入口：

- `HUI_RUNA=/path`：指定 Runa（或任意 ninja 兼容执行器）路径；
- `HUI_EXECUTOR_BIN=/path`：直接指定执行器；
- `HUI_JOBS` / `HUI_JOBS_MIN` / `HUI_MEM_*` / `HUI_CTRL_*`：并发与准入参数
  （v5.5.3 起运行中是 前馈 + PI(D) 控制器，见 README）。

`hui status` / 启动面板目前显示执行器**名称与路径**；**版本号和 SHA-256 尚未显示**
（见 §7 的待办）。

## 6. 分池

- hui.sh 按 `HUI_POOL_SPEC`（默认 `R8:5120 KOTLIN:5120 JAVA:2048 RUST:2048 LINK:4096`）
  计算每类池深，导出 `HUI_POOL_<CLASS>_JOBS`。
- 执行器按规则名分类（`r8` / `kotlin` / `javac` / `rust` / `.ld`），启动时读取；
  运行中不会重算池深。
- `HUI_POOLS=0` 关闭分池；单池可用同名环境变量覆盖。
- `NINJA_HIGHMEM_NUM_JOBS` 等旧入口保留。

## 7. 完成情况

- [x] vendored 上游 ninja v1.12.1 到 `third_party/ninja/`
- [x] `hui.patch`：`--parallelism-file` + `HUI_POOL_<CLASS>_JOBS`
- [x] `tools/build-executor.sh` 自举构建，产出 `prebuilts/hui/hui`（含 COPYING/NOTICE）
- [x] 合成图测试：动态并发 2 → 6 → 1；分池 r8=2 / kotlin=3 / javac=4 / rust=1 / ld=2
- [x] hui 接入：探测 + 显式选择 + `HUI_RUNA` / `HUI_EXECUTOR_BIN` 兼容
- [x] hui 侧计算池深并导出 `HUI_POOL_*`
- [x] 真实图冒烟：`hui build nothing` 走自建执行器通过
- [x] **Runa 保留**（2026-11-25 决定）：继续打包 `prebuilts/runa/`，作为
      `HUI_EXECUTOR=runa` 的可选回退
- [ ] 严格同图 A/B（同机器、同图，对比 Runa 的 `perf.tsv` 墙钟与 PSI）——
      未做；已有真实构建记录（见 §8），但不是受控对比
- [ ] `hui status` / 启动日志显示执行器版本与 SHA-256——未做
- [ ] （可选）`prebuilts/hui/hui` 当前未 strip（约 7.6M），可 `strip --strip-debug`
      压到约 400K，并同步 `build-executor.sh`

## 8. 实测记录（非受控对比）

自建执行器已经用于本机真实构建，记录在 `.hui/perf.tsv` 与各阶段日志：

- 2026-11-25 13:37：全量重建 224,763 条边；15:03 因内核 kconfig 失败中止，
  15:18 续跑，15:43 出包；
- 2026-11-25 16:09：增量构建 3,486 条边，约 40 分钟（SystemUI glob 变更后）；
- 2026-11-24 20:25 / 21:32 / 22:27：增量/全量混合阶段，786~2,077 秒。

执行器切换前的 `perf.tsv` 有 13,489s / 9,462s 等记录（当时可能是 Runa/siso），
树状态、图和内存条件不同，**不能直接当作 A/B 结论**。要严格对比，需要在同一张图上
各跑一次并固定其他变量。

## 9. 风险与维护

- **替换风险低**：契约只有“ninja 兼容 + `--parallelism-file`”，Runa、自建 hui、
  以后别家的执行器都能互换；探测/回退逻辑已经存在。
- 没有 `--parallelism-file` 的执行器（原生 ninja / siso）也能用，只是失去运行中升降。
- 维护 C++ fork：跟上游 rebase，一年一两次；补丁面小（选项解析 + 调度上限 + 分池）。
- 增量正确性：`hui` 是上游 ninja，补丁不碰 `RecomputeDirty` / 日志格式；
  但与 AOSP ninja 1.9 / siso 的 v5 账本不通用，靠 hui.sh 的构图备份/恢复兜底。
- 启动开销与 ninja 相同，不引入额外解析层。
- 执行器与 ROM 无关；自建后不再跟随 uwuAOSP 的分支节奏。

## 10. 后续（可选）

1. `hui status` / 启动日志补版本 + SHA-256；
2. strip `prebuilts/hui/hui` 并同步构建脚本；
3. 有需要时在 CI 校验二进制哈希；
4. 真正的同图 A/B（成本较高，按需）；
5. Runa 的上游可复现性/许可核对（见 `runa-provenance.md` 第 6 节，已决定保留）。
