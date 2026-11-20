# Gemini Desktop Bridge

本机 Antigravity MCP。桥接通过 macOS 辅助功能控制已登录的 Gemini Desktop，可自动启动 Gemini 并等待窗口。默认工作流是在新会话进入「任务」模式，选择用户授权的目录，提交一次并轮询结果。普通问答有单独的工具。

## 安装与配置

1. 安装 Gemini Desktop 并登录。安装 Apple Command Line Tools 或 Xcode，以便使用系统 Swift 编译器和 Python 3。
2. 在仓库运行 `./script/build_and_run.sh --request-access`。
3. 在「系统设置 → 隐私与安全性 → 辅助功能」启用 **Gemini Desktop Bridge**。如果列表里没有它，可手动添加 `~/Applications/Gemini Desktop Bridge.app`。
4. 在 Antigravity 的全局 `~/.gemini/config/mcp_config.json` 的 `mcpServers` 中合并下面的条目。将示例路径里的用户名换成本机用户名。打开新的 Antigravity 会话或重新加载 MCP。

```json
{
  "mcpServers": {
    "gemini-desktop": {
      "command": "/usr/bin/python3",
      "args": ["/Users/YOUR_USER/Library/Application Support/Gemini Desktop Bridge/server.py"]
    }
  }
}
```

也可用 Antigravity CLI 注册。

```sh
agy mcp add gemini-desktop /usr/bin/python3 "$HOME/Library/Application Support/Gemini Desktop Bridge/server.py"
agy mcp list
```

应用和服务端安装在固定的用户路径，可从其他项目使用。运行时使用系统 Python 和 Swift 编译产物。重新运行安装脚本时，辅助应用源码不变就保留现有签名。更新辅助应用后 macOS 可能要求重新开启权限。终端中的安装环境需要有效的 GUI 登录会话，运行时 Mac 要解锁。

## 工具

| 工具 | 参数 | 行为 |
| --- | --- | --- |
| `gemini_submit_task` | `task_id`、`message`，新建时必填 `directory`，可选 `continue_from_task_id`、`timeout_seconds`、`model` | 新建任务并选择真实目录，或通过 `continue_from_task_id` 在原任务会话中继续追问。仅传入用户已同意交给 Gemini 的最小必要目录。 |
| `gemini_submit_chat` | `task_id`、`message`，可选 `continue_from_task_id`、`timeout_seconds`、`model` | 以普通对话模式新建会话，或通过 `continue_from_task_id` 在原对话中继续发送消息。 |
| `gemini_list_models` | `mode`（`chat` 或 `task`） | 空闲时实时打开该模式的模型菜单，返回当前选中、完整标签和可用状态。 |
| `gemini_get_result` | `task_id` | 返回当前状态或完整回复。建议每隔 3–5 秒查询。 |
| `gemini_get_weekly_quota` | 无 | 读取 Gemini 设置中的五小时与每周用量、剩余比例及重置时间。 |
| `gemini_health` | 无 | 检查本机辅助功能、键盘权限和辅助应用。 |
| `gemini_release` | `task_id`、`confirmed: true` | 用户检查旧任务已结束后，解除超时或未确认任务的占用。旧任务 ID 仍会被记录。 |

`task_id` 可使用 1 至 80 位 ASCII 字母、数字、连字符和下划线。为每个不同的动作使用新 ID。重复提交同一 ID 和相同参数只返回已有状态，参数不同会报错。一次只执行一个 Gemini 会话。常规任务默认超时 300 秒，可设为 30 到 3600 秒。

`running` 时继续查询，`completed` 携带 `reply`。收到 `timed_out` 或 `submission_unknown` 时，仍按原 ID 查询。客户端或服务重启后状态可恢复。若返回 `conversation_not_found`，先在 Gemini 打开原会话，然后继续用同一 ID 查询。收到 `not_submitted` 时可查看 `code` 和 `detail`，处理后以新 ID 发起一次明确的重试。登录、系统授权及未知弹窗须在 Mac 上处理。桥接只确认预期目录的访问提示。

普通对话优先在后台通过辅助功能填写和提交，Antigravity 可以留在前台。若 Gemini 无法直接填写，桥接会尝试自动切到 Gemini 进行粘贴。目录选择仍使用系统前台选择器。

额度工具返回 `five_hour` 与 `weekly`，两个对象各自报告状态、用量、剩余比例和界面显示的重置时间。顶层字段继续对应周额度，兼容原有调用。界面只显示已使用百分比时，剩余比例按 `100 - 已使用百分比` 计算，并用 `remaining_source` 标明来源。缺失值返回 `null`。查询使用 Gemini 原生设置页。调用结束时会尝试关闭本次查询打开的设置窗口，已打开的设置窗口会保留。Google 将「当前用量」对应的短周期说明为五小时。[Gemini 官方额度说明](https://support.google.com/gemini/answer/16275805)

指定模型时先调用 `gemini_list_models`，再将可用条目的完整 `label` 填为 `model`。提交前会在当前界面核对菜单确实已选中该项。省略模型时沿用 Gemini 当前选择。模型列表会随账户和模式变化。查询会切换到一个新的空白输入页，且不会发送消息。

任务提示中会带一个短标记供桥接核对会话。任务记录和已完成回复保存在 `~/Library/Application Support/Gemini Desktop Bridge/tasks.sqlite3`，其父目录仅本用户有访问权。Gemini Desktop 的注册目录和历史由 Gemini 自身管理。桥接依赖 Gemini 当前的辅助功能控件，中文界面已实测。Gemini 界面变化可能导致控件诊断状态，修改配置前可先运行 `gemini_health`。

## Antigravity 分工

Antigravity 负责拆解要求和明确目录范围。无文件访问的文本工作可交给对话工具，需要访问本地文件的工作交给任务工具。Antigravity 自己执行命令、读实际文件、看 diff、跑测试和给出最终结论。将 Gemini 的回复当作待核验的结果。

要断开 MCP，可以用 `agy mcp remove gemini-desktop` 或在配置中仅删除对应条目。随后可在系统设置撤销辅助功能权限。

图标由 `script/make_icon.swift` 生成，源图在 `assets/GeminiDesktopBridge.png`。安装脚本将其打包成多尺寸 macOS `.icns`。

## 许可

本项目使用 [MIT 许可证](LICENSE)。
