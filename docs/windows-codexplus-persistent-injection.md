# Windows Codex++ 持久注入设计

## 1. 需求分析

### 1.1 用户反馈

- Codex++ 启动后，Dashi Taskboard 面板可以正常显示。
- 重启 Codex++ 后，面板消失。
- 重启前面板可见，重启后不可见。
- 用户确认需要面板在 Codex++ 重启后自动恢复。

### 1.2 当前故障路径

1. 用户启动 Codex++。
2. Codex++ 启动 Microsoft Store 版 `ChatGPT.exe`，并传入 `--remote-debugging-port=9229`。
3. Dashi 源码服务运行在 `127.0.0.1:47823`。
4. `scripts/codex-injector.mjs` 负责将 Taskboard 注入 Codex 页面。
5. Windows 上 `codexAppProcesses()` 无条件调用 `/bin/ps`，无法枚举当前 Codex 进程。
6. 没有持久运行的注入器，Codex++ 重启后也不会重新注入。
7. `--open` 模式在 CDP 连接断开后没有新的打开请求，注入器可能继续运行但不会恢复新页面。

### 1.3 目标

- 保持现有 Codex++ 窗口，不切换为 Dashi 独立托管的 Codex 实例。
- Codex++ 重启后，Dashi 注入器自动重新识别新的 `ChatGPT.exe` 根进程并恢复面板。
- 不修改或替换官方 Codex App。
- 不删除或迁移现有 Taskboard 数据。
- 不依赖官方 Tauri 托盘启动器；官方启动器会要求重启 Codex，且会创建独立托管实例。
- 最小改动：修复 Windows 进程枚举，并提供可持久运行的后台启动入口。

## 2. 方案选型

### 2.1 否决方案

- **官方 Tauri 桌面启动器**：其 Windows 流程检测到现有 Codex 后会请求关闭并重启 Codex，然后使用私有 CDP pipe 启动独立实例。这与“保持当前 Codex++ 窗口”的目标冲突。
- **修改 Codex++ 源码**：未确认存在可用的 Codex++ 钩子；改动 Codex++ 不在本仓库范围内，风险和不必要的依赖更高。
- **每次手动运行 `npm run codex:inject`**：只能修复一次，不能解决重启后消失的问题。

### 2.2 推荐方案

在 Dashi 仓库内完成两件事：

1. 为 `scripts/codex-injector.mjs` 增加 Windows 进程枚举分支。
2. 增加一个 Windows 后台启动脚本，等待 Codex 的 CDP 端口就绪后启动注入器，并在注入器退出后自动重启。

启动入口使用 PowerShell 轮询 `http://127.0.0.1:9229/json/version`，不主动启动或杀死 Codex。注入器以 `--watch --open --port 9229 --app-path <ChatGPT.exe>` 模式运行，复用 Codex++ 已经打开的 CDP 端口。

### 2.3 服务复用与数据目录

注入器内部已有 `createTaskboardSupervisor()`，会在 Taskboard 服务不可用时自行启动服务。因此不需要一个新的长期服务进程；启动脚本只负责保持注入器进程存活。注入器和已有服务使用同一个 `.data` 目录，保留现有数据。

启动前确认已有服务是否能通过 `127.0.0.1:47823` 访问。可复用同一服务和同一 `.data` 目录；只有端口或数据目录冲突时才需要停止或调整旧服务，不需要例行杀掉服务。

## 3. 接口设计

### 3.1 代码变更

#### `scripts/codex-injector.mjs`

在 `codexAppProcesses(appPath)` 中增加 Windows 分支：

- 输入：`appPath`，即 Microsoft Store Codex 的 `ChatGPT.exe` 绝对路径。
- 输出：`Array<{ pid: number, command: string }>`。
- Windows 实现：
  - 使用 PowerShell WMI 枚举 `Win32_Process`。
  - 过滤名称和可执行路径匹配 `ChatGPT.exe` 的进程。
  - 根据 `ParentProcessId` 识别根进程。
  - 只保留命令行包含 `--remote-debugging-port=` 的根进程。
  - 返回 PID 和完整命令行，供现有 `codexProcessDebuggingPort()` 和监视逻辑复用。
- 非 Windows 分支保持不变。

#### 新增 `scripts/dashi-codex-plus-launcher.ps1`

启动入口：

- 自动读取 `Get-AppxPackage -Name OpenAI.Codex` 得到 `InstallLocation`，拼出 `app\ChatGPT.exe`。
- 等待 `http://127.0.0.1:9229/json/version` 可访问。
- 设置：
  - `CODEX_TASKBOARD_HOST=127.0.0.1`
  - `CODEX_TASKBOARD_PORT=47823`
  - `CODEX_TASKBOARD_DATA_DIR=<项目根>\.data`
- 循环执行：
  `node scripts/codex-injector.mjs --watch --open --port 9229 --app-path <ChatGPT.exe>`
- 注入器退出后等待短暂时间再重新执行。
- 所有输出写入项目 `.data\dashi-codex-plus.log`，避免后台进程打开可见窗口。
- 不使用 `Add-Content` 并行追加这两个重定向日志文件；文件由 `Start-Process` 子进程独占，避免日志占用导致启动失败。

#### 启动方式

初次配置时：

1. 在仓库目录安装依赖，并确认 Node.js `>=22.5`：`npm install`。
2. 执行 `npm run build:web`，准备当前网页资源。
3. 确认 Codex++ 已使用 CDP `9229` 启动，并确认 `127.0.0.1:47823` 上的现有 Taskboard 服务和该仓库 `.data` 目录可复用。
4. 运行一次后台启动脚本。
5. 需要登录 Windows 后自动运行时，执行脚本的 `-InstallStartup`；该参数只注册 Startup 快捷方式后立即返回，不会在当前命令中启动后台注入器。随后由 Windows 登录流程启动快捷方式。

### 3.2 环境变量

| 变量 | 值 | 用途 |
| --- | --- | --- |
| `CODEX_TASKBOARD_HOST` | `127.0.0.1` | 限制服务只监听本机 |
| `CODEX_TASKBOARD_PORT` | `47823` | 固定 Taskboard 服务端口 |
| `CODEX_TASKBOARD_DATA_DIR` | 项目 `.data` | 复用现有 SQLite 数据 |

### 3.3 数据结构

不新增数据库或数据表。`scripts/codex-injector.mjs` 继续使用现有 `.data/taskboard.sqlite`，并继续向 `.data/launcher-runtime.json` 写入运行时描述。新增日志文件：

- `.data/dashi-codex-plus.log`

## 4. 关键流程

### 4.1 首次启动

1. 用户登录 Windows，后台启动脚本开始运行。
2. 脚本检测到 CDP `9229` 尚未就绪时持续等待。
3. Codex++ 启动 `ChatGPT.exe`，CDP `9229` 变为可访问。
4. 脚本启动注入器。
5. 注入器确认 Taskboard 服务可达或自行启动服务。
6. 注入器通过 Windows WMI 找到根 `ChatGPT.exe`，使用其 `--remote-debugging-port=9229` 连接。
7. 注入 Taskboard 用户脚本，恢复侧边栏入口和任务面板。

### 4.2 Codex++ 重启

1. Codex++ 关闭旧根进程。
2. 注入器的 CDP 连接失效。
3. 注入器监视到 Codex 退出，继续运行并等待新的 Codex 根进程。
4. Codex++ 启动新的 `ChatGPT.exe`，仍使用 `--remote-debugging-port=9229`。
5. 连接断开时，注入器递增打开请求代次；重新枚举根进程后发出新的打开请求并注入新页面。

### 4.3 注入器异常退出

1. 后台启动脚本检测到注入器进程退出。
2. 脚本等待后重新执行注入器。
3. 注入器重新等待 CDP 并恢复注入。

## 5. 风险与边界

- **服务复用**：注入器和已有源码服务必须使用同一端口与 `.data` 目录；服务可达时直接复用，不需要例行停止。只有检测到端口或数据目录冲突时才处理旧服务。
- **不主动停止 Codex++**：启动脚本只等待和读取现有 CDP，不调用 `taskkill`、不重启 Codex。
- **不在代码中写死 Codex 版本号**：每次通过 Appx 包查询路径，避免 Windows 更新后失效。
- **不修改官方安装包**：官方安装包保留，但本方案使用仓库源码和内置依赖。
- **不新增第三方依赖**：只使用 Node 标准库、PowerShell/WMI 和现有 `ws`/SQLite 依赖。

## 6. 使用边界

- 启动脚本只等待并读取现有 CDP，不主动启动或杀死 Codex++。
- 注入器复用 Codex++ 的 `ChatGPT.exe`、CDP `9229`、Taskboard 服务和 `.data` 数据目录。
- `-InstallStartup` 只负责注册登录启动快捷方式；首次验证仍需单独运行不带该参数的启动脚本。
