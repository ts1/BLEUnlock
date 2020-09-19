# BLEUnlock

BLEUnlockはiPhone, Apple Watchやその他のBluetooth Low EnergyデバイスでMacをロック・アンロックする小さなメニューバーユーティリティーです。


## 特徴

- iPhoneアプリは必要ありません
- 定期的に信号を送出するBLEデバイスなら何でも使えます
- デバイスがMacの近くにあればMacのロック画面を自動的に解除します - もうパスワードを入力する必要はありません
- デバイスがMacから離れると画面をロックします
- デバイスがMacに近づくと画面スリープを解除します (オプション)
- デバイスがMacから離れる/近づくとiTunesの再生を一時停止/再生します (オプション)
- パスワードはキーチェーンに安全に保管されます

## 必要なもの

- Bluetooth Low EnergyをサポートするMac
- macOS 10.13 (High Sierra) 以上
- iPhone 5s以上, Apple Watch (すべて), または定期的に信号を送信するBLEデバイス

## インストール

[Releases](https://github.com/ts1/BLEUnlock/releases)からzipファイルをダウンロードし、解凍してアプリケーションフォルダにコピーします。

最初の起動であなたのログインパスワードを聞いてきます。
これはロック画面を解除するために必要です。
キーチェーンに保管されるため安全です。

次にアクセシビリティの許可を求めてきます。
システム環境設定の画面でロックアイコンをクリックしてアンロックし、BLEUnlockをオンにしてください。
これもロック画面を解除するために必要です。

最後に、メニューバーアイコンから "デバイス" を選択してください。
近くにあるBLEデバイスのスキャンが始まります。
使いたいデバイスを選べば完了です。

## トラブルシューティング

ロック解除に失敗する場合、"システム環境設定" → "セキュリティとプライバシー" →
"プライバシー" → "アクセシビリティ" でBLEUnlockがオンになっているか確認してください。
すでにオンになっている場合、一度オフにしてもう一度オンにしてみてください。

もしBLEUnlock自身のパスワードにアクセスする許可を求められた場合、"常に許可" してください。ロック画面中に必要になるためです。

もし "信号がありません" が頻発する場合、MacのBluetoothを一度オフにしてからオンにしてみてください。
もしくはより頻繁に信号を送出するデバイスを使ってください。

### ロック解除に時間がかかる場合

短い答え: iPhoneのスリープを解除してください。

バージョン1.4.1から、BLEUnlockはシステムスリープ中Bluetoothがパワーオフしたとき (システムスリープから15〜30秒後)、デバイスが離れたと仮定するようになりました。
これはセキュリティのために必要です。
結果として、スリープ解除後、ロック解除されるまで最大で数秒かかるようになりました。

これはデバイスとのコネクションが切れ、デバイスが信号を送ってくるのを待っているためです。
デバイス側もスリープ中は信号送出の間隔が長いので、デバイスのスリープを解除すれば、大抵の場合すぐに信号が送られ、ロック解除されます。

### パッシブモードとBluetoothインターネット共有

BLEUnlockはデフォルトで能動的にデバイスに接続して信号強度を読み取ります。
これはiPhoneなどサポートされているデバイスでは最も安定して信号強度を取得する方法です。
しかしながら、この方法はBluetoothインターネット共有と相性良くありません。

パッシブモードではデバイスから発せられる信号を受動的に受け取ります。
これはBluetoothインターネット共有と干渉しません。

Bluetoothインターネット共有を使う場合、パッシブモードをオンにしてください。
そうでなければオフにしてください。

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

> 注意: `intruded` イベントが正常に働くには、 *セキュリティとプライバシー* で *スリープとスクリーンセーバの解除にパスワードを要求* を **すぐに** に設定してください。

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

`SnapshotUnlocker` は Script Editor で作られた .app で、内容は以下のとおりです。

```
do shell script "/usr/local/bin/ffmpeg -f avfoundation -r 30 -i 0 -frames:v 1 -y /tmp/unlock-$(date +%Y%m%d_%H%M%S).jpg"
```

これはBLEUnlockにカメラのパーミッションがないため必要となります。このappにパーミッションを与えることによりパーミッションの問題を回避できます。

## クレジット

- peiit: 中国語の翻訳
- wenmin-wu: 最小RSSIと移動平均
- stephengroat: CI

アイコンはmaterialdesignicons.comからダウンロードしたSVGファイルをもとにしています。これらはGoogleによってデザインされApache License version 2.0でライセンスされています。

## ライセンス

MIT

Copyright © 2019 Takeshi Sone.
