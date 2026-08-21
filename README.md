# DeepSeek 浮窗（macOS）

[![Build & Release](https://github.com/zhangshaobo608/deepseek-widget/actions/workflows/build-release.yml/badge.svg)](https://github.com/zhangshaobo608/deepseek-widget/actions)

一个原生 Swift/AppKit 桌面悬浮小窗，实时展示你的 DeepSeek 开放平台账号**当天**用量：

- **V4-Flash / V4-Flash-Vision-Exp / V4-Pro**：各模型每 100 万 token 的平均费用（= 当天成本 ÷ 当天 token 数 × 100 万）
- **缓存命中率**：命中 token ÷（命中 + 未命中）
- 今日总成本、余额、请求数，以及当前"峰时/闲时"标识（北京时间 9:00–12:00、14:00–18:00 为峰时）

悬浮窗置顶、可拖拽、支持所有桌面空间，5 分钟自动刷新，右键菜单可刷新/设置/退出。

## 一键运行

```bash
./build.sh                          # 编译并打包 build/DeepSeek浮窗.app
open "build/DeepSeek浮窗.app"       # 启动（已在运行会直接显示）
```

可把 `build/DeepSeek浮窗.app` 拖到 `/Applications`，再到「系统设置 → 通用 → 登录项」加入开机自启。

## 配置 token（只需一次）

数据来自 `platform.deepseek.com` 平台内部用量接口，需要用你账号的 `userToken`（本机保存，不联网上传）。任选一种方式：

1. **设置窗口**：右键浮窗 →「设置 Token…」粘贴 token。
2. **从 Chrome 读取**：在 Chrome 登录 `platform.deepseek.com` 后，点设置窗口里的「从 Chrome 读取」，自动从本机 Chrome / Edge / Brave 导入。
3. **环境变量**：`DEEPSEEK_USER_TOKEN=xxx open "build/DeepSeek浮窗.app"`。

获取 token：登录 `platform.deepseek.com` → F12 打开开发者工具 → Console 执行（`copy()` 会把 token **直接放进剪贴板**，无需手动选中输出）：

```js
copy(JSON.parse(localStorage.getItem('userToken')).value)
```

然后直接 Cmd+V 粘贴。想要更省事，可把下面这段**存成浏览器书签**，在 `platform.deepseek.com` 页面上点一下即自动复制：

```
javascript:(()=>{const v=JSON.parse(localStorage.getItem('userToken')).value;navigator.clipboard.writeText(v).then(()=>alert('token 已复制'))})()
```

## 命令行自检（验证数据链路）

```bash
./build/DeepSeekWidget --selftest                    # 自动读 Chrome / 环境变量里的 token
./build/DeepSeekWidget --selftest --token '<userToken>'  # 显式传 token
```

输出当天 Flash / Vision Exp / Pro 的 token 数、缓存命中/未命中、成本、命中率、每百万 token 平均费用等 JSON。

## 数据与价格说明

- 用量/费用接口：`platform.deepseek.com/api/v0/usage/by_api_key/{amount,cost}`（平台前端同款内部接口，非公开 API，可能随时变化；本工具仅本机使用）。
- 余额：`/api/v0/users/get_user_summary`。
- 峰谷参考价（元/百万 tokens，2026-08-17 起，高峰时段为北京时间 9:00–12:00、14:00–18:00，闲时半价）：

| 模型 | 时段 | 输入·缓存命中 | 输入·未命中 | 输出 |
|---|---|---|---|---|
| V4-Flash | 峰 | 0.10 | 3.00 | 9.00 |
| V4-Flash | 闲 | 0.05 | 1.50 | 4.50 |
| V4-Pro | 峰 | 0.30 | 9.00 | 27.00 |
| V4-Pro | 闲 | 0.15 | 4.50 | 13.50 |

鼠标悬停在模型卡片上可查看参考价提示；卡片上的平均费用是你账号的真实账单口径，已包含峰谷价差。
Vision Exp 暂不内置参考价提示，但仍按平台返回的实际成本独立计算并展示账单均价。

## 文件

- `Sources/main.swift` — 全部源码（UI + 拉取 + 计算 + Chrome token 导入）
- `build.sh` — 一键构建脚本
- `Info.plist` — 应用清单（LSUIElement，无 Dock 图标）

## 常见问题

- **显示"Token 无效或已过期"**：token 过期，重新从 Chrome 读取或粘贴新的。
- **不想让它一直置顶**：右键 →「始终置顶」取消勾选。
- **退出**：右键 →「退出」（无 Dock 图标，只能从这里退出）。
- **卸载**：退出后删除 .app 即可；token 存在 `~/Library/Preferences/com.deepseekwidget.floating.plist`。
