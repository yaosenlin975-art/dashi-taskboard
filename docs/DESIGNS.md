# Dashi Taskboard Codex++ 设计

## 架构

- `scripts/dashi-codex-plus-launcher.ps1` 在 Windows 登录后等待 Codex CDP 端口，并保持注入器进程运行。
- `scripts/codex-injector.mjs` 连接现有 Codex++ 的 CDP，注入 Taskboard，并在 Codex 重启后继续监视和重新注入。
- Taskboard 服务使用固定本机地址 `127.0.0.1:47823` 和现有 `.data` 目录，复用原 SQLite 数据。
- 运行前需要已安装依赖、Node.js `>=22.5`、完成 `npm run build:web`，并确认 Codex++ 已提供 CDP `9229`。

## 核心数据流

Windows 启动脚本 → CDP `9229` 就绪检测 → 注入器 → Codex 页面 → Taskboard 面板。

## 关键流程

1. 启动脚本轮询 Codex CDP，端口就绪后启动注入器。
2. 注入器枚举 Codex 根进程，连接页面并注入面板。
3. Codex++ 重启导致连接失效时，注入器继续运行，等待新根进程并重新注入。
4. 注入器退出时，启动脚本等待两秒后重新启动它。
5. 连接断开时，注入器更新打开请求代次，确保 `--open` 模式能向新页面发起恢复请求。

## 运行约束

- 不启动、关闭或替换官方 Codex App。
- 启动脚本通过 `Start-Process` 重定向注入器输出和错误日志。
- 重定向日志文件由子进程独占；启动脚本不再并行追加生命周期日志。
- `-InstallStartup` 只注册 Windows 登录启动快捷方式，不负责当前会话的立即启动。
- 已可达的 Taskboard 服务直接复用；服务与注入器必须指向同一端口和 `.data` 目录。
