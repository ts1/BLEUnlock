# BLEUnlock

![CI](https://github.com/ts1/BLEUnlock/workflows/CI/badge.svg)
![Github All Releases](https://img.shields.io/github/downloads/ts1/BLEUnlock/total.svg)
[![Buy me a coffee](img/buymeacoffee.svg)](https://www.buymeacoffee.com/tsone)

BLEUnlockはiPhone, Apple Watchやその他のBluetooth Low Energyデバイスの距離によってMacをロック・アンロックする小さなメニューバーユーティリティーです。

## 特徴

- iPhoneアプリは必要ありません
- 定期的に信号を送出するBLEデバイスなら何でも使えます ([静的なMACアドレス](#macアドレスについて)である必要があります)
- BLEデバイスがMacの近くにあればMacのロック画面を自動的に解除します
- BLEデバイスがMacから離れると画面をロックします
- ロック・アンロック時にスクリプトを実行することができます
- BLEデバイスがMacに近づくと画面スリープを解除することができます
- BLEデバイスがMacから離れる/近づくと音楽や動画の再生を一時停止/再生することができます
- パスワードはキーチェーンに安全に保管されます

## 必要なもの

- Bluetooth Low EnergyをサポートするMac
- macOS 10.13 (High Sierra) 以上
- iPhone 5s以上, Apple Watch (すべて), または定期的に信号を[静的なMACアドレス](#macアドレスについて)から送信するBLEデバイス

## インストール

### Homebrew Caskを使う方法

```
$ brew install bleunlock
```

### 手動でインストールする方法

[Releases](https://github.com/ts1/BLEUnlock/releases)からzipファイルをダウンロードし、解凍してアプリケーションフォルダに移動します。

## セットアップ

初回起動時、以下の許可を要求します。適切に許可してください。

許可 | 説明
---|---
Bluetooth | 当然ながら、Bluetoothへのアクセスが必要です。
アクセシビリティ | ロック画面を解除するために必要です。システム環境設定の画面で左下のロックアイコンをクリックしてアンロックし、BLEUnlockをオンにしてください。
キーチェイン | (要求されない場合もあります) 要求された場合、必ず**常に許可**を選んでください。ロック中に必要になるためです。
通知 | (任意) BLEUnlockはロック中に通知メッセージを表示します。正しく動作しているか確認するのに役立ちます。Big Sur以降、デフォルトでロック画面ではメッセージが表示されません。メッセージを表示するには*通知*環境設定パネルで*プレビューを表示*を*常に*に設定してください。

|　必要になる許可はmacOSのバージョンが上がるにつれ増えています。古いmacOSをお使いの場合は上に挙げた許可が表示されない場合があります。

次にあなたのログインパスワードを聞いてきます。これはロック画面を解除するために必要です。キーチェインに安全に保存されます。

最後に、メニューバーアイコンから*デバイス*を選択してください。近くにあるBLEデバイスのスキャンが始まります。使いたいデバイスを選べば完了です。

## オプション

### 今すぐロック
BLEデバイスが近くにあるかどうかに関わらず、画面をロックします。BLEデバイスが一度遠ざかり、再び近づくと解除されます。席を離れる前に確実にロックするのに有効です。

### アンロック信号強度
ロック解除に必要なBluetooth信号の強度です。値が大きいほどBLEデバイスがMacの近くにないとロック解除しません。*無効にする*を選ぶとBLEデバイスが近くにあってもロック解除をしません。

### ロック信号強度
MacをロックするBluetooth信号の強度の閾値です。値が小さいほどBLEデバイスがMacから遠い時点でロックをします。*無効にする*を選ぶとBLEデバイスが遠くなるもしくは信号がなくなってもロックをしません。

### ロックするまでの遅延

BLEデバイスが遠ざかってから実際にロックをするまでの時間です。BLEデバイスがこの時間内に再び近づくと、ロックは行われません。

### 無信号タイムアウト

最後に信号を受信してからロックするまでの時間です。意図せず「デバイスからの信号がありません」でロックされる場合、この値を増やしてください。

### 画面スリープから復帰

ロック中にBLEデバイスが近づいてきたとき、ディスプレイをスリープ画面から復帰させます。

### ロック中 "再生中" を一時停止

ロック時に音楽や動画の再生を一時停止し、ロック解除時に再開します。対応しているのはApple Music, QuickTime Player, Spotifyなど、*再生中*ウィジェットやキーボードの⏯キーで制御できるアプリです。

### スクリーンセーバーでロック

ロック時にスクリーンセーバーを起動します。このオプションが正しく動作するには、*セキュリティとプライバシー*システム環境パネルで*スリープとスクリーンセーバーの解除にパスワードを要求*を*すぐに*に設定する必要があります。

### パスワードを設定...

Macのログインパスワードを変更したときに、このオプションを使って変更してください。

### パッシブモード

デフォルトでBLEUnlockはBLEデバイスに接続を確立し信号強度を読み取ろうとします。これはサポートされているデバイスでは最も安定して信号強度を読み取ることができる方法です。しかしながら、キーボード、マウス、トラックパッドや特にインターネット共有など、他のBluetooth機器を使用している場合、このモードが干渉することがあります。2.4GHz帯のWiFiも干渉する可能性があります。Bluetoothが不安定になる場合は、パッシブモードを有効にしてください。

### 最小RSSIを設定

このRSSI未満のデバイスはデバイススキャンリストに表示されません。

## トラブルシューティング

### デバイスがリストに表示されない

Apple製以外のBLEデバイスでは、BLEUnlockはデバイスの名前を取得できない場合があります。その場合、デバイスはUUID（ハイフンで区切られた長い16進数）で表示されます。

デバイスを識別するには、Macから遠ざけたり近づけたりして、信号強度（dB値）がそれに応じて変化するかどうかを確認してください。

### アンロックされない

*システム環境設定* > *セキュリティとプライバシー* > *アクセシビリティ* でBLEUnlockがオンになっているか確認してください。すでにオンになっている場合、一度オフにしてもう一度オンにしてみてください。

もしキーチェインの許可を求められた場合、*常に許可*を選択してください。ロック中に必要になるためです。

### "デバイスからの信号がありません" が頻繁に発生する場合

*無信号タイムアウト*を大きくしてください。それでも解決しない場合、*パッシブモード*を試してください。

### Bluetoothキーボード、マウス、インターネット共有その他Bluetoothがおかしくなった

*パッシブモード*をオンにしてください。

## MACアドレスについて

クラシックBluetoothと違い、Bluetooth Low Energyデバイスは*プライベート*MACアドレスを使うことができます。プライベートアドレスはランダムで、時間が経つと変わることがあります。

最近のスマートデバイスは、iOSとAndroidともに、15分ほどで変わるランダムアドレスを使う傾向にあります。おそらくトラッキング防止のためだと思われます。

一方で、BLEUnlockは、BLEデバイスをトラッキングするために、MACアドレスは静的である必要があります。

幸運なことに、Appleのデバイスでは、Macと同じApple IDでサインインしていれば、真の（パブリック）MACアドレスが取得できます。

Android等、その他のデバイスに関しては、今のところMACアドレスを解決する方法は分かりません。非Apple製デバイスでMACアドレスが時間が経つと変わる場合、残念ながらBLEUnlockはサポートできません。

MACアドレスが正しく解決されているかチェックするには、*デバイス*のリストに表示されるMACアドレスと、BLEデバイスのアドレスを比較してください。

## ロック・アンロック時にスクリプトを実行する

BLEUnlockはロック・アンロック時に以下のスクリプトを実行します。

```
~/Library/Application Scripts/jp.sone.BLEUnlock/event
```

スクリプトにはイベントに応じて以下の引数の一つが渡されます。

|Event|Argument|
|-----|--------|
|信号強度のためBLEUnlockによりロックされた|`away`|
|無信号のためBLEUnlockによりロックされた|`lost`|
|BLEUnlockによりアンロックされた|`unlocked`|
|手動でアンロックされた|`intruded`|

> 注意: `intruded` イベントが正常に働くには、システム環境設定の *セキュリティとプライバシー* で *スリープとスクリーンセーバの解除にパスワードを要求* を **すぐに** に設定してください。

### サンプル

例としてLINE Notifyにメッセージを送るスクリプトを示します。
手動でアンロックされた場合Macの前にいる人の写真を添付します。

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

`SnapshotUnlocker` はスクリプトエディタで作った .app で、内容は以下のとおりです。

```
do shell script "/usr/local/bin/ffmpeg -f avfoundation -r 30 -i 0 -frames:v 1 -y /tmp/unlock-$(date +%Y%m%d_%H%M%S).jpg"
```

このappはBLEUnlockにカメラのパーミッションがないため必要となります。このappにパーミッションを与えることによりパーミッションの問題を回避できます。

## FUNDING

1.9.0以降のバイナリリリースはAppleによって公証されていません。
このため、**起動するには右クリックして開き、Keychain等のパーミッションを再認証する必要があります**。

現在私の会社ではMacやiOSのアプリを開発していないため、有料のApple Developerアカウントにアクセスできません。

このアプリを気に入っていただけたら、Apple Developer Programの費用を自分で払うことができるよう、[Buy Me a Coffee](https://www.buymeacoffee.com/tsone) もしくは [PayPal.Me](https://paypal.me/takeshisone) で寄付をいただけるとありがたいです。

## クレジット

- peiit: 中国語の翻訳
- wenmin-wu: 最小RSSIと移動平均
- stephengroat: CI
- joeyhoer: Homebrew Cask

アイコンはmaterialdesignicons.comからダウンロードしたSVGファイルをもとにしています。これらはGoogleによってデザインされApache License version 2.0でライセンスされています。

## ライセンス

MIT

Copyright © 2019-2021 Takeshi Sone.
