# Runa 的来源与可复现性（备忘，暂不处理）

记录时间：2026-11-22（会话时区 Asia/Shanghai）

> 2026-11-23 更新：默认执行器已切换为自建的 `prebuilts/hui/hui`
> （上游 ninja v1.12.1 + `hui.patch`，见 [hui-plan.md](hui-plan.md)）。
> Runa 仍作为**可选执行器**保留（`HUI_EXECUTOR=runa` 或 `HUI_RUNA=...`），
> 二者按 `--parallelism-file` 契约互换。本文档继续作为 Runa 的来源/许可记录。

状态：**已记录，暂不实施**。hui 目前使用 `prebuilts/runa/runa` 预编译二进制。
下面第 6 节是待办，等决定长期方案后再做。

## 1. Runa 是什么

- uwuAOSP 项目对 **Ninja** 的 fork，不是上游 Ninja 的正式功能。
- 在 Ninja 1.9 基础上增加了：
  - `--parallelism-file FILE`：运行中改并发，只影响还没启动的命令
  - `--control-socket FILE`：运行时调度控制
  - `-d assumeexisting`：接受 Ninja 日志缺失但磁盘上存在的输出
- 上游 Ninja 没有这些接口；它们属于 uwuAOSP 的私有扩展（Apache-2.0 许可）。

## 2. 源码位置

| 项 | 值 |
| --- | --- |
| 仓库 | https://github.com/uwuAOSP/platform_external_runa |
| 分支 | `uwu-17.0` |
| 许可证 | Apache-2.0（`COPYING`） |
| 维护者 | `uwu-gl <moegluwu0@gmail.com>`（uwuAOSP） |
| 本地源码 | `~/uwu/external/runa`（repo project） |
| 本地源码状态 | **浅克隆**，只有 `refs/uwu/archive/17.0.130` 的 `2172e6e` |
| 检查时远端 HEAD | `820fa4cd645064aa5f4743b16cb5d4f7f8c76930` |

## 3. hui 里的二进制

| 项 | 值 |
| --- | --- |
| 路径 | `hui/prebuilts/runa/runa` |
| 来源 | `~/uwu/vendor/uwu-prebuilts/runa/runa` |
| 版本 | `runa --version` → `1.9.0.git` |
| SHA-256 | `7aab8d67e0bfcf3423c0dddaaaf54fe3a3a178d9b08701bde887bc8c47ce667d` |
| 许可证文件 | `hui/prebuilts/runa/COPYING`（Apache-2.0） |
| 归属说明 | `hui/prebuilts/runa/NOTICE` |
| NOTICE 记录的源码 revision | `ec2a20576ebac608bc527ccb0fa9571221cd47d7` |

SHA-256 与 uwuAOSP 自己的 `vendor/uwu-prebuilts/runa/README.md` 一致。

## 4. 已知的可复现性缺口

- 二进制标注的源码 revision 是 `ec2a20576e…`，但**本地浅克隆里没有这个对象**
  （`git cat-file -t ec2a205…` 报错）；本地只有 `2172e6e`（archive ref）。
- 检查时远端分支 HEAD 已经到 `820fa4c`，也不等于标注的 revision。
- 因此：**当前无法只用本地源码逐行复现这份二进制**。能确认的是哈希与上游
  prebuilt 记录一致，且源码/许可证公开。

## 5. 不影响使用的事实

- Runa 只负责执行；构建规则仍是树里的 Soong/Kati/Ninja。
- 不想用 Runa 时：
  - `HUI_EXECUTOR=siso`（有 siso 的树）
  - `HUI_EXECUTOR=m`（原生）
  - `HUI_RUNA=/path/to/another/runa`（换一份自己构建的）
- 失去的只是“运行中从准入值往上升到上限”的能力；阶段准入、nice/ionice、
  图复用、内核快照都不依赖 Runa。

## 6. 待办（暂不实施）

> 2026-11-23 更新：已决定改用自建执行器 `hui` 执行器（上游 ninja + `--parallelism-file`
> 补丁），本节的长期方案转为记录历史。详见 [hui-plan.md](hui-plan.md)。

- [ ] 决定长期方案：继续用 prebuilt，还是 vendored 源码由 soong 构建
- [ ] 若源码构建：把 `external/runa` 作为 repo project 加进树，用其 `Android.bp`
      编出 `runa`，hui 通过 `HUI_RUNA` 或 `prebuilts/runa` 路径使用
- [ ] 若继续 prebuilt：按 NOTICE 里的 revision 拉全历史，重建并核对 SHA-256，
      把“可复现命令”写进本文件
- [ ] 在 `hui status` / 启动日志里显示 Runa 版本与 SHA-256，便于排查
- [ ] 评估是否需要在 CI 里校验 `prebuilts/runa/runa` 的哈希

## 7. 复核命令

```sh
runa --version
sha256sum hui/prebuilts/runa/runa
git -C ~/uwu/external/runa log -1 --format='%H %s'
git -C ~/uwu/external/runa cat-file -t ec2a20576ebac608bc527ccb0fa9571221cd47d7
git ls-remote https://github.com/uwuAOSP/platform_external_runa HEAD
```
