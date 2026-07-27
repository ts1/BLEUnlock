# BLEUnlock

## 請注意：本應用程式未在 Mac App Store 發布，你可以在這裡免費取得！

![CI](https://github.com/ts1/BLEUnlock/workflows/CI/badge.svg)
![Github All Releases](https://img.shields.io/github/downloads/ts1/BLEUnlock/total.svg)
[![Buy me a coffee](img/buymeacoffee.svg)](https://www.buymeacoffee.com/tsone)

BLEUnlock 是一個小型選單列工具程式，會依 iPhone、Apple Watch 或其他 Bluetooth Low Energy 裝置與 Mac 的距離來鎖定及解鎖 Mac。

本文件亦提供[英文版](README.md)與[日文版](README.ja.md)。

## 功能

- 不需要安裝 iPhone App
- 可搭配任何會定期傳送訊號且具有[固定 MAC 位址](#關於-mac-位址)的 BLE 裝置使用
- 當 BLE 裝置靠近 Mac 時，無須輸入密碼即可為你解鎖 Mac
- 當 BLE 裝置遠離 Mac 時鎖定 Mac
- 可選擇在鎖定／解鎖時執行自訂指令稿
- 可選擇從螢幕睡眠中喚醒
- 可選擇在離開及返回時暫停與繼續播放音樂／影片
- 密碼會安全地儲存在鑰匙圈

## 系統需求

- 支援 Bluetooth Low Energy 的 Mac
- macOS 10.13（High Sierra）或更新版本
- iPhone 5s 或更新機型、任何 Apple Watch，或其他具有[固定 MAC 位址](#關於-mac-位址)並定期傳送訊號的 BLE 裝置

## 安裝

### 使用 Homebrew Cask

```
brew install bleunlock
```

### 手動安裝

從 [Releases](https://github.com/ts1/BLEUnlock/releases) 下載 zip 檔、解壓縮後移至「應用程式」資料夾。

## 初始設定

第一次啟動時，程式會要求下列權限，請務必允許：

權限 | 說明
-----------|---
藍牙 | 顯然需要藍牙存取權。請選擇 *好*。
輔助使用 | 這是用來解鎖鎖定畫面所必需。按一下 *開啟系統偏好設定*，按一下左下角的鎖頭解鎖，再啟用 BLEUnlock。
鑰匙圈 | （不一定會詢問）如果出現提示，必須選擇 **永遠允許**，因為螢幕鎖定時仍需要此權限。
通知 | （選用）BLEUnlock 鎖定螢幕時會在鎖定畫面顯示訊息，有助於確認程式是否正常運作。此外，若要在鎖定畫面看到訊息，必須在「通知」偏好設定中將 *顯示預覽* 設為 *永遠*。

> 注意：每個版本的 macOS 所需權限都會增加；若你使用較舊的作業系統，可能不會被要求一項或多項權限。

接著程式會詢問你的登入密碼以解鎖鎖定畫面。
密碼會安全地儲存在鑰匙圈中。

最後，從選單列圖示選擇 *裝置*。
程式會開始掃描附近的 BLE 裝置。
選取你的裝置後，設定即完成！

## 選項

選項 | 說明
-------|---
立即鎖定螢幕 | 不論 BLE 裝置是否在附近都會鎖定螢幕；裝置先遠離、再靠近時才會解鎖。這可確保你離開座位前螢幕已鎖定。
解鎖 RSSI | 用於解鎖的藍牙訊號強度。數值越大，表示 BLE 裝置必須更靠近 Mac 才會解鎖。選擇 *停用* 可關閉解鎖功能。
鎖定 RSSI | 用於鎖定的藍牙訊號強度。數值越小，表示 BLE 裝置必須離 Mac 更遠才會鎖定。選擇 *停用* 可關閉鎖定功能。
鎖定前延遲 | 偵測到 BLE 裝置遠離後，鎖定 Mac 前的等待時間。若裝置在此時間內再次靠近，就不會鎖定。
無訊號逾時 | 從最後一次接收訊號到鎖定之間的時間。若經常因「訊號遺失」而鎖定，請增加此值。
接近時喚醒 | 鎖定時 BLE 裝置靠近，便從睡眠中喚醒顯示器。
喚醒但不解鎖 | 無論是由「接近時喚醒」自動喚醒或手動喚醒顯示器，BLEUnlock 都不會解鎖 Mac。這可相容 macOS 內建的 Apple Watch 解鎖功能（可在 BLEUnlock 喚醒螢幕後立即運作），也適合只想更快看到鎖定畫面而不想自動解鎖的情況。
鎖定時暫停「播放中」 | 鎖定／解鎖時，BLEUnlock 會暫停／繼續播放由 *播放中* 小工具或鍵盤 ⏯ 鍵控制的音樂或影片（包括 Apple Music、QuickTime Player 與 Spotify）。
使用螢幕保護程式鎖定 | 設定此選項後，BLEUnlock 會啟動螢幕保護程式而非直接鎖定。為使此選項正常運作，需在「安全性與隱私權」偏好設定中將 *進入睡眠或啟動螢幕保護程式後需要密碼* 設為 **立即**。
鎖定時關閉螢幕 | 鎖定時立即關閉顯示器。
設定密碼… | 若你變更登入密碼，請使用此功能。
被動模式 | 預設會主動嘗試連線至 BLE 裝置並讀取 RSSI。多數情況建議使用預設值，且運作穩定；但若使用藍牙鍵盤、滑鼠、觸控板，尤其是藍牙個人熱點，預設模式可能彼此干擾，2.4 GHz Wi-Fi 也可能造成干擾。若藍牙不穩定，請開啟被動模式。
登入時啟動 | 登入時啟動 BLEUnlock。
設定最小 RSSI | RSSI 低於此值的裝置不會顯示在裝置掃描列表中。

## 疑難排解

### 裝置沒有出現在列表中

若你的 BLE 裝置不是 Apple 裝置，BLEUnlock 可能無法辨識裝置名稱。
此時會以 UUID（長串十六進位數字與連字號）顯示裝置。
要辨識裝置，請嘗試讓裝置靠近或遠離 Mac，並查看 RSSI（dB 值）是否隨之變化。

若列表中完全沒有任何裝置，請嘗試依下述方式重設藍牙模組。

### 無法解鎖

確認已在 *系統偏好設定* > *安全性與隱私權* > *隱私權* > *輔助使用* 中啟用 BLEUnlock。
若已啟用，請嘗試先關閉再重新開啟。

若程式要求在鑰匙圈中存取自己的密碼，必須選擇 *永遠允許*，因為螢幕鎖定時仍需要該密碼。

### 經常出現「訊號遺失」

請增加 *無訊號逾時*。
或者嘗試使用 *被動模式*。

### 藍牙鍵盤、滑鼠、個人熱點或其他藍牙裝置異常

首先，在選單列或控制中心按住 Shift + Option 再按藍牙圖示，然後按一下 *重設藍牙模組*。

在 macOS 12 Monterey 中，此選項已不再提供。
請改在終端機輸入下列指令以重設藍牙模組：

```
sudo pkill bluetoothd
```

這個指令會要求輸入你的登入密碼。

若問題持續，請開啟 *被動模式*。

## 關於 MAC 位址

不同於傳統藍牙，Bluetooth Low Energy 裝置可使用*私有* MAC 位址。
該私有位址可能是隨機的，也可能不時變更。

近年的智慧裝置（iOS 與 Android）傾向使用約每 15 分鐘變更一次的私有位址，這可能是為了防止追蹤。

另一方面，BLEUnlock 要追蹤你的裝置，其 MAC 位址必須是固定的。

幸運的是，對於與 Mac 使用相同 Apple ID 登入的 Apple 裝置，MAC 位址會解析為真正的（公開）位址。

至於包括 Android 在內的其他裝置，目前不知道如何解析該位址。
若非 Apple 裝置的 MAC 位址會隨時間變更，很遺憾 BLEUnlock 無法支援。

要確認 MAC 位址是否正確解析，請比較 BLEUnlock *裝置* 掃描列表中顯示的 MAC 位址，與裝置上顯示的 MAC 位址。

## 鎖定／解鎖時執行指令稿

鎖定與解鎖時，BLEUnlock 會執行位於以下路徑的指令稿：

```
~/Library/Application Scripts/jp.sone.BLEUnlock/event
```

會依事件類型傳入一個引數：

|事件|引數|
|-----|--------|
|BLEUnlock 因 RSSI 過低而鎖定|`away`|
|BLEUnlock 因沒有訊號而鎖定|`lost`|
|BLEUnlock 解鎖|`unlocked`|
|手動解鎖|`intruded`|

> 注意：要讓 `intruded` 事件正確運作，必須在「安全性與隱私權」偏好設定中將 *進入睡眠後需要密碼* 設為 **立即**。

### 範例

以下範例指令稿會傳送 LINE Notify 訊息；若 Mac 是手動解鎖，則會附上 Mac 前方人物的照片。

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

`SnapshotUnlocker` 是使用「指令稿編寫程式」建立的 App，其內容如下：

```
do shell script "/usr/local/bin/ffmpeg -f avfoundation -r 30 -i 0 -frames:v 1 -y /tmp/unlock-$(date +%Y%m%d_%H%M%S).jpg"
```

因為 BLEUnlock 沒有相機權限，所以需要這個 App。授予此 App 權限即可解決問題。

## 贊助

年度 Apple Developer Program 費用由捐款支應。

若你喜歡這個 App，歡迎透過 [Buy Me a Coffee](https://www.buymeacoffee.com/tsone) 或 [PayPal Me](https://www.paypal.com/paypalme/my/profile) 捐款，協助作者持續維護。

## 致謝

- [peiit](https://github.com/peiit)：中文翻譯
- [wenmin-wu](https://github.com/wenmin-wu)：最小 RSSI 與移動平均
- [stephengroat](https://github.com/stephengroat)：CI
- [joeyhoer](https://github.com/joeyhoer)：Homebrew Cask
- [Skyearn](https://github.com/Skyearn)：Big Sur 風格圖示
- [cyberclaus](https://github.com/cyberclaus)：德文、瑞典文、挪威文（Bokmål）與丹麥文在地化
- [alonewolfx2](https://github.com/alonewolfx2)：土耳其文在地化
- [wernjie](https://github.com/wernjie)：喚醒但不解鎖
- [tokfrans03](https://github.com/tokfrans03)：語言修正

圖示以從 materialdesignicons.com 下載的 SVG 為基礎。
原始設計者為 Google LLC，並依 Apache License 2.0 授權。

## 授權

MIT

Copyright © 2019–2022 Takeshi Sone.
