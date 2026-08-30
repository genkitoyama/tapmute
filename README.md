# MeetMute

EarPods の中央ボタン（再生/一時停止）で **Zoom / Google Meet / Microsoft Teams** のミュートを
切り替える macOS メニューバーアプリ。

会議が検出されているときだけメディアキーを横取りし、それ以外は下流にそのまま流すので、
会議していないときのボタンはこれまでどおり音楽の再生/停止として働く。

---

## 動作

```
EarPods 中央ボタン
   ↓
MeetingDetector（3 秒ごとにバックグラウンドで走査。キー押下時はキャッシュを読むだけ）
   ↓
会議あり ──→ NowPlayingShield が Now Playing の座を掴んでいる
             → メディアキーは Music ではなく MeetMute に配送される
             → MuteController が Zoom : ⇧⌘A をそのまま送出（グローバルショートカット）
                              Meet / Teams : 前面化 → キー送出 → 元のアプリに復帰
会議なし ──→ 座を掴まない → 音楽アプリが普通に反応する
```

### なぜ「イベントを消費する」だけでは駄目なのか

素直な実装は `CGEventTap` でメディアキーを捕まえて消費することだが、**この macOS では効かない**。
実機で両方のタップ位置を試した結果:

| タップ位置 | PLAY を捕捉 | 消費した結果 |
|---|---|---|
| `cgSessionEventTap` | できる | **Music が起動する**（消費できていない） |
| `cghidEventTap` | できる | **Music が起動する**（消費できていない） |

メディアキーの now playing 配送（`mediaremoted`）は CG イベントパイプラインの外にいるため、
タップで消しても届いてしまう。「ミュートはできたのに音楽も再生される」がこれで起きる。

効くのは **Now Playing の座を奪うこと**だけ。`MPRemoteCommandCenter` にコマンドを登録し、
無音のループを再生して「いま再生しているアプリ」になると、OS は再生/一時停止を
Music ではなくこちらへ配送する。**会議中だけ**座を奪うのが肝で、常時奪うと音楽の操作ができなくなる。

イベントタップは今も「押された瞬間を知る」ために使っている（配送より早く、確実に拾えるため）。
Now Playing 側のコマンドは通常は握り潰すだけの盾で、入力監視が切れてタップが動いていないときだけ
そちらがミュートを実行するフォールバックになる。

### 現在のミュート状態の読み方

ミュート操作のコントロールが「何を提案しているか」を AX から読む。Zoom の会議中ツールバーなら:

```
ミュート中    → AXButton desc="自分のオーディオをミュート解除する"
             → AXTabGroup desc="… , ミュートされたコンピュータ オーディオ"
ミュート解除中 → AXButton desc="自分のオーディオをミュートする"
```

「解除」を提案している＝いまミュート中、と読む。文言はアプリと言語で変わるので
`MeetingProfile.muteHints` に値として持たせてある。読めなければ `.unknown` を返し、
状態表示をやめる（嘘をつかないため）。

なお **CoreAudio の入力稼働フラグはミュート状態には使えない**。Zoom はミュート中も
入力ストリームを掴んだままなので、常に「使用中」に見える（実測で確認済み）。
これは通話中かどうかの目安にはなるが、ミュート状態の判定には使えない。

## 対応アプリ

| アプリ | 既定のショートカット | 既定の検出パターン（正規表現） | 前面化 |
|---|---|---|---|
| Zoom (`us.zoom.xos`) | ⇧⌘A | `Meeting` / `ミーティング` | 不要 |
| Google Meet（Chrome / Dia / Arc / Edge / Brave / PWA） | ⌘D | `^Meet\s*[-–—]` / `^Meet$` | 必要 |
| Microsoft Teams (`com.microsoft.teams2`) | ⇧⌘M | `Meeting` / `会議` / `ミーティング` | 必要 |

- Meet は**非アクティブタブでも検出する**。タブを一瞬切り替えて ⌘D を送り、元のタブと元のアプリに戻す。
- 検出パターンは Zoom / Teams のバージョンと言語設定で変わる。**設定画面から編集できる**。

## 必要な権限

| 権限 | 要否 | 用途 |
|---|---|---|
| アクセシビリティ | 必須 | ウィンドウ走査・キー送出・前面化 |
| 入力監視 | 必須 | メディアキーの押下検知。これがないと `CGEvent.tapCreate` が nil を返して沈黙する |
| 画面収録 | 推奨 | **別デスクトップ（Space）にある会議ウィンドウの題名を読む** |

画面収録が「推奨」である理由は実機検証で分かった macOS の性質による。
`kAXWindowsAttribute` は**現在の Space にあるウィンドウしか返さない**。会議を別デスクトップに
置いて手前で作業する運用だと、AX だけでは会議ウィンドウが 0 件になり検出が沈黙する。
このアプリは次の 3 経路を束ねて回避している。

1. `kAXWindows` — 現在の Space。AX 要素が取れるので前面化やタブ操作ができる
2. `kAXMainWindow` / `kAXFocusedWindow` — 別 Space のアプリでも題名が取れる
3. `CGWindowList` — 全 Space を横断できるが、題名の取得に画面収録権限が要る

## ビルドとインストール

```sh
make            # build/MeetMute.app を作る
make run        # ビルドして起動
make install    # /Applications へ配置
make clean
```

初回起動でオンボーディング画面が出る。3 つの権限をここから設定して、**MeetMute を再起動**する。

### Zoom 側の設定（必須）

Zoom → 設定 → キーボードショートカット → 「ミュート/ミュート解除」の
**「グローバルショートカットを有効にする」を ON**。
これが OFF だと Zoom が最前面のときしか反応しない。

### 署名と TCC（権限が維持される仕組み）

権限は「どのアプリか」を **designated requirement** で判定して紐づく。署名方式でこれが変わる。

| 署名 | designated requirement | 再ビルド後 |
|---|---|---|
| アドホック（`-`） | `cdhash H"114f…"` | **毎回リセット**。1 行直しただけで別アプリ扱いになる |
| Developer ID / Apple Development | `identifier "com.example.meetmute" and … certificate leaf[subject.OU] = <TeamID>` | **維持される** |

Makefile は `security find-identity -v -p codesigning` から Developer ID / Apple Development の
署名 ID を自動で拾って使う。証明書が 1 つもない環境ではアドホックに落ちる。

```sh
make install                              # 署名 ID を自動検出
make install SIGN_IDENTITY="Apple Development: ..."   # 明示指定
```

署名方式を切り替えた直後（アドホック → Developer ID など）は要件が変わるので、
そのときだけ権限を付け直す。古いエントリが残っていると無言で拒否されるため、リセットしてから許可する。

```sh
for s in Accessibility ListenEvent ScreenCapture; do tccutil reset $s com.example.meetmute; done
```

## 検出がうまくいかないとき

1. **会議中に**メニューバー → 「ウィンドウ一覧をログ出力」。全ウィンドウの題名がクリップボードに入る
2. 会議ウィンドウの実際の題名を確認する
3. 設定 → 会議アプリ → 該当アプリの「タイトル」に、その題名に当たる正規表現を足す

ターミナルからも同じことができる。

```sh
make probe-windows   # 検出結果と全ウィンドウ題名を出す
make probe-keys      # メディアキーが届いているかだけを見る（イベントは消費しない）
```

`probe-*` はターミナル自身の権限で動くので、アプリに権限を与える前の切り分けに使える。

### 誤検出（会議中でないのにボタンが効かない）

設定 → 全般 → **「マイク使用中のときだけ会議とみなす」** を ON にすると、
入力デバイスが誰かに掴まれているときだけ会議と判定する。
会議アプリはミュート中も入力ストリームを開いたままなので、ミュート解除もできる。

## 既知の制限

- Meet / Teams の前面化では、会議ウィンドウが別 Space やフルスクリーンにあると **Space が切り替わる**。
  macOS の仕様で、キーを届けるにはフォーカスが要るため回避できない
- 非アクティブタブの Meet は、そのブラウザウィンドウが**現在の Space にあるときだけ**見つかる
  （タブ一覧は AX 経由でしか取れないため）
- メニューバーのアイコンは EarPods の形。**現在のミュート状態**を表す

| アイコン | 意味 |
|---|---|
| EarPods（斜線あり） | ミュート中 — 押すと解除 |
| EarPods（通常） | ミュート解除中 — 押すとミュート |
| EarPods（薄い） | 会議なし — 押すと音楽の再生/停止 |
| 一時停止 | 一時停止中 |
| ⚠️ 警告 | 権限が不足している |

  状態が読めなかったときは通常表示に戻し、メニューに「状態不明」と出す。
  読めないものを状態として表示すると嘘をつくことになるため。
  `earbuds` に斜線版が無いので、SF Symbols と同じ手順（線の周囲をくり抜いてから線を引く）で合成している。

## ファイル構成

```
Sources/
  main.swift               エントリポイント / CLI プローブ
  AppDelegate.swift        起動・結線・キー押下時の分岐
  MediaKeyTap.swift        メディアキーの押下検知
  NowPlayingShield.swift   会議中だけ Now Playing の座を奪う（Music に行かせない）
  MeetingDetector.swift    会議の検出（3 秒キャッシュ + ワークスペース通知）
  MeetingProfile.swift     Zoom / Meet / Teams の差分を値として持つ
  MuteController.swift     ミュート操作の実行（前面化の往復を含む）
  AccessibilityHelper.swift AX と WindowServer のラッパー（3 経路の統合）
  MicMonitor.swift         入力デバイスの稼働状態（CoreAudio）
  StatusBarController.swift メニューバー UI とトースト
  PermissionManager.swift  権限の確認と誘導
  OnboardingWindow.swift   初回セットアップ画面
  SettingsWindow.swift     設定画面
  Preferences.swift        設定の永続化
  Shortcut.swift           "cmd+shift+a" ↔ キーコードの変換と送出
```
