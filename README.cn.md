# BLEUnlock

## 请注意：本应用不在 Mac App Store 发布，你可以在这里免费获取。

![CI](https://github.com/Skyearn/BLEUnlock/workflows/CI/badge.svg)
![Github All Releases](https://img.shields.io/github/downloads/Skyearn/BLEUnlock/total.svg)

BLEUnlock 是一款常驻菜单栏的小工具，可以根据 iPhone、Apple Watch 或其他蓝牙低功耗设备与 Mac 的距离，自动锁定或解锁 Mac。

本文档也提供 [English](README.md) 和 [Japanese (日本語)](README.ja.md) 版本。

> 本仓库是原始项目 [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock) 的 fork，原项目由 Takeshi Sone 创建。感谢 Takeshi Sone 以 MIT 协议开源 BLEUnlock，也感谢所有为原项目贡献代码、翻译和想法的贡献者。

## 功能

- 不需要 iPhone 端 App
- 支持任意会周期性广播、并且使用 [静态 MAC 地址](#关于-mac-地址) 的 BLE 设备
- 当 BLE 设备靠近 Mac 时自动解锁，无需手动输入密码
- 当 BLE 设备远离 Mac 时自动锁屏
- 可在锁定/解锁时执行你自己的脚本
- 可在靠近时唤醒显示器
- 可在离开和返回时暂停/恢复音乐或视频播放
- 密码安全保存在钥匙串中
- 已解析出 MAC 地址的设备以黑色显示，未解析的以灰色显示，一目了然。
- 按住 ⌥ 键展开设备列表可查看完整的 MAC 地址和 UUID，松开重新展开恢复简洁显示。

## 安全须知

BLEUnlock 通过 BLE MAC 地址识别设备，并根据 RSSI 信号强度判断距离。BLE 广播是公开且未加密的，这意味着附近的攻击者可以：

1. 嗅探你已配对 BLE 设备的 MAC 地址
2. 用市面上的 BLE 开发板伪造相同的 MAC 地址广播
3. 靠近你的 Mac 触发自动解锁

这是所有基于 RSSI 距离感知方案的固有限制，BLE 广播层本身不具备加密认证能力。

此外，由于 BLEUnlock 不需要在被监测设备上安装配套 App，它无法判断设备本身是否处于锁定状态。如果设备遗失后被他人拾取，拾取者只需携带该设备靠近你的 Mac 即可触发自动解锁 —— Mac 只看到了 BLE 信号，并不知道设备是否已解锁。

**建议**：如果你对安全性要求较高，请**禁用 RSSI 自动解锁**（在 *解锁设置* 中选择 *禁用*）。RSSI 自动**锁定**（离开时自动锁屏）可以放心使用，因为它只会锁定 Mac，不会授予访问权限。

如果你同时需要安全性和便利性，可以考虑用 Apple 自带的 Apple Watch 解锁功能来处理解锁，仅用 BLEUnlock 来执行离开时自动锁屏。

## 运行要求

- 一台支持 Bluetooth Low Energy 的 Mac
- macOS 10.13 (High Sierra) 或更高版本
- iPhone 5s 及以上、任意 Apple Watch，或任意会周期性广播且使用 [静态 MAC 地址](#关于-mac-地址) 的 BLE 设备

## 安装

### 使用 Homebrew Cask

```sh
brew install --cask Skyearn/tap/bleunlock
```

> 这里使用的是这个 fork 自己维护的 Homebrew tap。Homebrew 官方仓库里的 `bleunlock` cask 可能仍然指向上游项目。

### 手动安装

从 [Releases](https://github.com/Skyearn/BLEUnlock/releases) 下载 dmg 文件，打开后将 BLEUnlock 拖到“应用程序”文件夹。

> 注意：这个 fork 没有加入 Apple Developer Program，因此发布版本无法使用 Apple Developer ID 进行分发签名和公证。首次启动时，macOS 可能会拦截应用。
>
> 首次双击打开时，macOS 会弹出「无法验证是否包含恶意软件」的提示，只有「完成」和「移到废纸篓」两个按钮。请按下面的流程处理：
> 1. 先将 `BLEUnlock.app` 移动到 `/Applications`。
> 2. 打开终端，执行以下命令清除隔离标记：`sudo xattr -rd com.apple.quarantine /Applications/BLEUnlock.app`
> 3. 如果仍被拦截，打开 **系统设置** -> **隐私与安全性**，滚动到页面底部，对 BLEUnlock 点击 **仍要打开**。
> 4. 再次启动应用，并在弹窗中确认 **打开**。
> 5. 应用启动后，再按提示授予蓝牙、辅助功能、钥匙串和通知等权限。
>
> 为了尽量减少更新后的重复授权，请始终覆盖 `/Applications/BLEUnlock.app`，不要从不同目录运行多个副本。

## 初次设置

首次启动时，应用会请求以下权限，请全部按提示授权：

权限 | 说明
---|---
蓝牙 | 显然需要蓝牙访问权限，选择 *好* / *允许*。
辅助功能 | 用于在锁屏状态下输入密码并完成解锁。点击 *打开系统设置* / *打开系统偏好设置*，解锁设置页后启用 BLEUnlock。
钥匙串 | （不一定每次都会弹）如果弹出，请选择 **始终允许**，因为锁屏状态下也需要读取保存的密码。
通知 | （可选）锁屏时 BLEUnlock 会显示通知，便于确认它是否正常工作。如果希望在锁屏界面也显示通知，需要在通知设置里把 *显示预览* 设为 *始终*。

> 注意：不同 macOS 版本需要授予的权限数量并不完全相同。系统越新，通常需要的权限越多。

然后应用会要求你输入登录密码，用于自动解锁锁屏界面。密码会安全地保存在钥匙串中。

最后，点击菜单栏图标，打开 *设备列表*。
BLEUnlock 会开始扫描附近的 BLE 设备。选择你的设备后即可开始使用。

## 选项说明

选项 | 说明
---|---
立刻锁定屏幕 | 无论 BLE 设备是否仍在附近，都立刻锁屏。设备需要先离开再重新靠近，才会再次自动解锁。适合离开座位前强制锁屏。
解锁设置 | 将解锁逻辑和解锁 RSSI 合并在同一个子菜单中。逻辑用于选择“任一”已选设备靠近即可解锁，还是“全部”已选设备都靠近才解锁；RSSI 用于控制设备需要靠多近才会触发解锁。在该菜单中选择 *禁用* 可关闭自动解锁。
锁定设置 | 将锁定逻辑和锁定 RSSI 合并在同一个子菜单中。逻辑用于选择“任一”已选设备远离就锁定，还是“全部”已选设备都远离才锁定；RSSI 用于控制设备需要离多远才会触发锁定。在该菜单中选择 *禁用* 可关闭自动锁屏。
延迟锁定 | 检测到设备远离后，实际执行锁屏前等待的时间。如果设备在这段时间内重新靠近，则不会锁屏。
无信号超时 | 从最后一次收到信号到执行锁屏的超时时间。如果经常因为“信号丢失”而误锁屏，可以调大这个值。
靠近唤醒 | 当设备靠近且 Mac 处于锁定状态时，唤醒显示器。
唤醒时不解锁 | 无论是通过“靠近唤醒”自动唤醒，还是手动唤醒屏幕，BLEUnlock 都不会在唤醒后立即解锁。这个选项适合与 macOS 自带的 Apple Watch 解锁功能配合使用，或者你希望锁屏更快出现，但不想自动输入密码。
锁定时暂停"播放中" | 在锁定/解锁时，暂停/恢复 *正在播放* 控件可控制的音乐或视频，包括 Apple Music、QuickTime Player 和 Spotify。
用屏保来锁定它 | 如果启用该选项，BLEUnlock 会启动屏幕保护程序而不是直接锁屏。要让它正常工作，需要在系统的“安全性与隐私”里将“进入睡眠或开始屏幕保护程序后要求输入密码”设为“立即”。
锁定时关闭屏幕 | 锁定时立即关闭显示器。
设置密码... | 当你修改了 Mac 登录密码后，需要通过这里重新保存密码。
被动模式 | 默认情况下，BLEUnlock 会主动连接设备并读取 RSSI，这通常更稳定。但如果你同时使用蓝牙键盘、鼠标、触控板、蓝牙个人热点，或者 2.4GHz Wi‑Fi 环境干扰较大，可能会造成蓝牙不稳定。这种情况下可以启用被动模式。
开机启动 | 登录后自动启动 BLEUnlock。
设置最小 RSSI | RSSI 低于该值的设备不会显示在设备扫描列表中。

## 故障排除

### 设备列表里找不到我的设备

如果你的 BLE 设备不是 Apple 设备，BLEUnlock 可能无法读取设备名称。
这种情况下，它会显示为 UUID（一串带连字符的长十六进制字符串）。

要识别具体是哪台设备，可以尝试把设备靠近或远离 Mac，观察 RSSI（dBm 值）是否随之变化。

如果列表里完全没有任何设备，先尝试按下文所述重置蓝牙模块。

### 切换 macOS 用户后无法扫描到设备

BLEUnlock 依赖 macOS 的 CoreBluetooth 扫描。多个 macOS 用户同时登录时，尤其是使用快速用户切换时，macOS 可能会把蓝牙扫描资源继续绑定在上一个用户的 BLEUnlock 进程上。此时另一个用户里的 BLEUnlock 可能已经获得蓝牙权限、蓝牙也处于开启状态，但设备列表仍然扫描不到任何设备。

如果你需要在多个 macOS 用户账号之间使用 BLEUnlock，建议在切换用户前先手动退出当前用户里的 BLEUnlock，然后再切换到目标用户并启动 BLEUnlock。这样可以完整释放上一个用户的蓝牙扫描会话，比让 BLEUnlock 留在后台更可靠。

BLEUnlock 不会尝试自动处理这个场景。可靠的自动方案需要额外的 helper 或 launch agent 持续跟踪用户会话状态，在用户切出时退出 BLEUnlock，并在用户切回时重新拉起它。这会是一个改动很大、非常具有侵入性的生命周期管理方案，而且行为上会很像一个在后台不断自我拉起的程序。因此这个 fork 选择记录这个限制，而不是内置这样的 helper。

### 无法自动解锁

确认 BLEUnlock 已在 *系统设置* / *系统偏好设置* > *隐私与安全性* > *辅助功能* 中启用。
如果已经启用，尝试先关闭再重新开启。

如果系统弹出访问钥匙串中密码的对话框，必须选择 **始终允许**，否则在锁屏时无法自动读取密码。

### 经常出现“信号丢失”

可以调大 *无信号超时*，或尝试启用 *被动模式*。

### 蓝牙键盘、鼠标、个人热点或其他蓝牙设备变得不稳定

首先可以按住 `Shift + Option`，点击菜单栏或控制中心中的蓝牙图标，然后选择 *重置蓝牙模块*。

在 macOS 12 Monterey 中，这个菜单项已经被移除。
可以改为在终端执行：

```sh
sudo pkill bluetoothd
```

这条命令会要求输入你的登录密码。

如果问题仍然存在，建议启用 *被动模式*。

## 关于 MAC 地址

与经典蓝牙不同，Bluetooth Low Energy 设备可以使用 *私有* MAC 地址。
私有地址可能是随机的，并且会定期变化。

现在很多智能设备，无论是 iOS 还是 Android，都会使用大约每 15 分钟变化一次的随机地址，以减少被追踪的可能。

但 BLEUnlock 要持续跟踪一台设备，就必须依赖它的 MAC 地址保持稳定。

幸运的是，对于 Apple 设备，只要它和你的 Mac 使用相同的 Apple ID 登录，系统通常可以把 BLE 地址解析到真实的公共地址。

### 使用已配对设备

如果某个设备使用轮换私有地址，只需要在 *系统设置* > *蓝牙* 里和 Mac 配对一次。配对后，BLEUnlock 即可从系统读取设备的 MAC 地址并显示在设备列表中。这意味着：

- **可靠识别**：MAC 地址直接显示在设备名旁，一眼就知道是哪台设备。
- **自动重追踪**：当设备 BLE UUID 因断连或系统重启发生变化时，BLEUnlock 会自动通过 MAC 地址匹配将追踪重映射到新 UUID，无需手动重新配置。

单纯“配对一次”本身通常不会明显增加续航负担。对续航影响更大的，一般是后续频繁的主动蓝牙连接或轮询，而不是这一步配对操作。

## 在锁定/解锁时执行脚本

当锁定或解锁发生时，BLEUnlock 会执行以下位置的脚本：

```sh
~/Library/Application Scripts/com.github.Skyearn.BLEUnlock/event
```

根据事件类型，会传入以下参数之一：

| 事件 | 参数 |
|---|---|
| 因 RSSI 低而被 BLEUnlock 锁定 | `away` |
| 因完全收不到信号而被 BLEUnlock 锁定 | `lost` |
| 被 BLEUnlock 自动解锁 | `unlocked` |
| 被手动解锁 | `intruded` |

第二个参数是最近一次的 RSSI，尚未收到信号时省略。第三个参数是其状态变化触发该事件的受监控设备名称：`away` 和 `lost` 总会传入，`unlocked` 在因设备靠近而触发时传入。若事件并非由设备状态变化触发（例如 Mac 唤醒后的解锁尝试），则省略。传入第三个参数但没有 RSSI 时，第二个参数为空字符串。

> 注意：要让 `intruded` 事件正常工作，需要在系统设置中的“安全性与隐私”里把“进入睡眠后要求输入密码”设为 **立即**。

### 示例

下面是一个示例脚本：当 Mac 被手动解锁时，发送一条 LINE Notify 消息，并附上一张站在 Mac 前的人像照片。

```sh
#!/bin/bash

set -eo pipefail

LINE_TOKEN=xxxxx

notify() {
    local message=$1
    local image=$2
    if [ "$image" ]; then
        img_arg="-F imageFile=@$image"
    else
        img_arg=""
    fi
    curl -X POST -H "Authorization: Bearer $LINE_TOKEN" -F "message=$message" \
        $img_arg https://notify-api.line.me/api/notify
}

capture() {
    open -Wa SnapshotUnlocker
    ls -t /tmp/unlock-*.jpg | head -1
}

case $1 in
    away)
        notify "$(hostname -s) is locked by BLEUnlock because iPhone is away."
        ;;
    lost)
        notify "$(hostname -s) is locked by BLEUnlock because signal is lost."
        ;;
    unlocked)
        #notify "$(hostname -s) is unlocked by BLEUnlock."
        ;;
    intruded)
        notify "$(hostname -s) is manually unlocked." $(capture)
        ;;
esac
```

`SnapshotUnlocker` 是一个用“脚本编辑器”制作的 `.app`，内容如下：

```applescript
do shell script "/usr/local/bin/ffmpeg -f avfoundation -r 30 -i 0 -frames:v 1 -y /tmp/unlock-$(date +%Y%m%d_%H%M%S).jpg"
```

之所以需要这个 app，是因为 BLEUnlock 本身没有相机权限。
把相机权限授予这个 app，就可以绕过这个限制。

## Fork 来源

这个 fork 基于 Takeshi Sone 的原始项目 [ts1/BLEUnlock](https://github.com/ts1/BLEUnlock)，并在当前仓库中继续维护、发布和进行功能调整。

感谢 Takeshi Sone 打下的项目基础，也感谢所有长期贡献修复、本地化和使用反馈的贡献者。

## 致谢

- [Takeshi Sone](https://github.com/ts1): BLEUnlock 原作者与项目基础
- [peiit](https://github.com/peiit): 中文翻译
- [wenmin-wu](https://github.com/wenmin-wu): 最小 RSSI 和移动平均
- [stephengroat](https://github.com/stephengroat): CI
- [joeyhoer](https://github.com/joeyhoer): Homebrew Cask
- [cyberclaus](https://github.com/cyberclaus): 德语、瑞典语、挪威语（Bokmål）和丹麦语本地化
- [alonewolfx2](https://github.com/alonewolfx2): 土耳其语本地化
- [wernjie](https://github.com/wernjie): 唤醒时不解锁
- [tokfrans03](https://github.com/tokfrans03): 语言修正

图标基于 materialdesignicons.com 提供的 SVG 文件制作，
原始设计由 Google LLC 提供，遵循 Apache License 2.0。

## 许可证

MIT

Copyright © 2019-2022 Takeshi Sone. MIT Licensed.<br>Copyright © 2026 Skyearn. MIT Licensed.
