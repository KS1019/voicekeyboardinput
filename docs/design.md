# Voice Keyboard Design

## 目的

Voice Keyboard は、iOS 26+ のキーボード拡張として「音声入力が使えそうに見えるが、実際には未検証の機能」を誇張しないことを最優先にする。現時点の UI は、録音・文字起こしが利用可能だと錯覚させるよりも、検証状態、制約、通常キーの信頼性を明確に伝えるためのプロダクト UI である。

## 現状のデザイン

### キーボード拡張

現状の `KeyboardRootView` は、システム標準色と Dynamic Type を使った控えめな UIKit UI で構成されている。

- 背景: `systemBackground`
- 本文: `body`
- 補助情報: `caption1`
- 補助色: `secondaryLabel`, `tertiaryLabel`
- 状態色: presentation layer の `PresentationTone` から UIKit color へ変換
- レイアウト: 縦 stack、6pt spacing、左右 12pt margin
- 最小高さ: 180pt

表示要素は、上から voice input preview、key controls の2行に絞る。voice input preview は transcript、状態ラベル、meter を1つの横並び preview として扱う。全体の狙いは「小さい keyboard height の中で、今入力できるか、音声入力を開始できるか、基本キーが使えるかを最短で理解できる」ことである。

### ホストアプリ

現状の `ContentView` は、SwiftUI `List` と `Section` を使う設定・QA 画面である。デザインは実用寄りで、オンボーディング、Manual QA、Command Preview、Voice Validation をセクション単位で分けている。

QA 入力欄は複数行 `TextField(axis: .vertical)` で、Keyboard Extension の Delete / Return を手動確認しやすい。

## カラーパレット

現状は独自ブランド色をほぼ持たず、iOS semantic color に依存している。今後も「ブランド色を増やす」より「状態を誤読させない」ことを優先する。

| 用途 | 現状 | 意図 |
| --- | --- | --- |
| 背景 | `systemGroupedBackground` | iOS の設定・ユーティリティ画面に自然に馴染ませる |
| 面 | `systemBackground` / `.regularMaterial` | 情報のまとまりを軽く分ける |
| 本文 | `label` / default text color | 可読性優先 |
| 補助文 | `secondaryLabel` | 状態説明を主張しすぎない |
| inactive meter | `tertiaryLabel` + alpha | 非アクティブ状態を低コントラストで表す |
| primary action | `systemBlue` | 音声入力開始など、今押すべき操作 |
| warning | `systemOrange` | 未検証・確認中 |
| positive | `systemGreen` | listening / probe 成功 |
| critical | `systemRed` | unavailable / failed |

運用ルール:

- 色だけで状態を伝えない。必ず label、SF Symbol、meter/pill の形を併用する。
- 音声入力の主役色は青、録音中は緑、危険・不可は赤、検証待ちはオレンジに固定する。
- キーボード拡張では背景画像、強いグラデーション、装飾的な光彩を使わない。
- Material / Liquid Glass 的な質感は panel / control strip に限定し、本文の背後には置きすぎない。

W3C WCAG 2.2 は、コントラストの目的を "Text can be seen by more people." と説明し、実装上は "Provide sufficient contrast between text and its background." としている。通常テキストは 4.5:1、大きなテキストは 3:1 が基準なので、独自色を増やす場合はこの基準を下回らないことを前提にする。

## 狙っている雰囲気

狙いは「派手な音声入力アプリ」ではなく、「低レイテンシで信用できる入力ツール」である。

- Calm: 小さい領域でも焦らせない
- Honest: 未検証状態を ready と見せない
- Dense: キーボード領域なので説明過多にしない
- Native: iOS の標準 controls と Dynamic Type に寄せる
- Observable: 音声状態は meter / bars / status で見える化する

## Web Research からの示唆

Apple の HIG / Liquid Glass 公式ページは JavaScript 必須で本文取得はできなかったが、公式ページの存在は確認した。iOS 26 の Liquid Glass は、Apple Developer Documentation 上で扱われている。参照対象は Apple HIG の Color / Typography / Icons と Liquid Glass の Technology Overview。

外部情報では、iOS 26 の Liquid Glass は透明感、反射、屈折、流動性を特徴とし、Apple プラットフォーム全体の統一テーマとして説明されている。一方で、透明度が高すぎる UI は可読性を落とし、Apple も beta 中に frosted / opacity を調整したという報告がある。

このプロジェクトでは、Liquid Glass 的な雰囲気を取り入れる場合でも、キーボード拡張の小さい領域では透明感を主役にしない。特に、録音状態・未検証状態・エラー状態はコントラストと明確な文言を優先する。

参考:

- Apple Developer Documentation: Liquid Glass, https://developer.apple.com/documentation/technologyoverviews/liquid-glass
- Apple Human Interface Guidelines: Color, https://developer.apple.com/design/human-interface-guidelines/color
- Apple Human Interface Guidelines: Typography, https://developer.apple.com/design/human-interface-guidelines/typography
- Apple Human Interface Guidelines: Icons, https://developer.apple.com/design/human-interface-guidelines/icons
- W3C WCAG 2.2 Understanding SC 1.4.3 Contrast (Minimum), https://www.w3.org/WAI/WCAG22/Understanding/contrast-minimum.html
- Nielsen Norman Group: 10 Usability Heuristics, https://www.nngroup.com/articles/ten-usability-heuristics/
- Material Design 3: Buttons, Color, Elevation, https://m3.material.io/
- The Verge: Apple が Liquid Glass の透明度を beta 中に調整したという報告
- Wired / TechRadar 系記事: Liquid Glass の可読性・目の疲れへの懸念

追加で採用した判断:

- NN/g の "Visibility of System Status" を、録音中 / 待機中 / 不可状態の capsule、色、meter に反映する。
- NN/g の "Aesthetic and Minimalist Design" を、説明文を増やさず transcript、state、mic key の視覚階層で表す判断に使う。
- Material 3 の button / surface / elevation の考え方は、host app の大きい primary action と panel 階層に限定して使う。Android 的な形状や色には寄せない。
- AI voice UI / transcription app の影響は、large mic hero ではなく live transcript bar と waveform feedback に変換する。

## グラフィック / インスピレーション

このプロダクトの第一画面は、マーケティングではなく実際の入力ツールである。主役にするグラフィックは写真や抽象イラストではなく、実際の音声状態と入力状態を表す UI そのものにする。

- iOS Settings / Shortcuts 的な、余白のある operational dashboard
- SF Symbols の `mic.fill`, `waveform`, `keyboard`, `lock.shield`, `delete.left`, `return`
- 音量 meter / waveform bars を、音声入力中であることを示す唯一の装飾要素にする
- host app は広めの panel、keyboard extension は compact pill / key row で密度を変える
- host app の最初の panel は voice console として扱い、status capsule、mic/waveform surface、primary action をひとまとまりにする
- keyboard extension は voice input preview と key row の2行に整理する
- host app の背景は semantic grouped background を基本にし、状態色は voice console 内の surface と badge に限定する
- keyboard の active mic は塗りキーで示し、glow / shadow は使わない
- keyboard の補助キーは icon-only に寄せ、`Speak` だけを文字付き primary action にする
- 今後マーケティング画面を作る場合は、生成イラストより実機スクリーンショットを第一素材にする

### Aqua Voice からの示唆

Aqua Voice は「速い音声入力」よりも「話した内容が、その場に合う文章へ整う」体験を前面に出している。公式サイトは、Hold Space / Press and speak の単純な起動、リアルタイム整形、アプリ横断、画面コンテキスト、履歴、辞書、カスタム指示を強調している。

このプロジェクトでは、Aqua の方向性をそのまま真似るより、Keyboard Extension の制約に合わせて次の形に変換する。

- キーボード上は Aqua のような大きな機能説明を出さず、`voice input preview + keys` だけにする
- ホストアプリ側に履歴、辞書、整形方針、検証メモを逃がす
- 将来の整形機能は「録音後に一回だけ適用」ではなく、入力先に合わせた style preset として見せる
- 技術語や固有名詞の精度は、Aqua の Avalon / custom dictionary の訴求に近い方向で、辞書管理と technical vocabulary を明確な価値にする
- iOS keyboard の最初の体験は「Aqua に切り替える」画像のように、地球儀キーから切り替える導線をスクリーンショット中心で説明する

避ける方向:

- 紫・青の大きなグラデーション背景
- 装飾的な orb / bokeh / glow
- 透明度の高いカードを本文の背後に重ねる表現
- 録音未検証なのに「常時録音できる」ように見える大型マイク演出

## 改善で試す方向性

### Pattern A: Native Utility

現状を保ちつつ、余白、キー形状、状態表示だけを少し整理する。最も安全で、キーボード拡張の制約に合う。

- 背景は system background
- 状態行を compact に保つ
- Mic / Delete / Return は明確なキーとして見せる
- Visual meter は小さく、読みやすさを邪魔しない

### Pattern B: Frosted Control Strip

Liquid Glass を控えめに反映し、controls 周辺だけを薄い frosted surface として扱う。

- 上部情報は白地/黒地で明確に
- control strip だけ半透明・角丸
- 状態色はアクセントとして限定使用
- 透明度は低めにして可読性を確保

### Pattern C: Voice Focus

音声入力の視覚 UI を中心に据える。meter を大きめにし、Mic の状態が一目で分かるようにする。

- voice activity を中央の主役にする
- capability は副情報へ下げる
- Mic key を primary action として強調
- ただし extension 内録音が未検証の現段階では、ready 感を出しすぎない

## 現時点の推奨

まずは Pattern A を基準に、Pattern B の frosted control strip をごく薄く取り込む。Pattern C は実機 probe が動き始めた後に再検討する。

理由:

- Keyboard Extension は高さ・メモリ・寿命が厳しい
- 音声入力が未検証の段階で voice-first にしすぎると誤解を招く
- iOS 26 の透明 UI は魅力がある一方、可読性リスクがある
- 現状の検証 UI は「できることを正直に見せる」目的に合っている

## 今回の改善方針

現状の弱点は、ホストアプリが設定テキストの羅列に見え、キーボード拡張も状態と操作が同じ重みで並んでいること。改善では、情報量を増やさずに階層を付ける。

## 情報設計

初期表示では、利用者が次の操作を決めるために必要な情報だけを出す。診断、実装メモ、検証の補助情報は、ホストアプリ側の Developer Details に畳む。

### 表示する情報

- Keyboard Extension: voice input preview、入力キー
- Host App: 音声入力開始、Keyboard Extension QA、必要時の Developer Details

### 隠す情報

- Keyboard Extension: capability の詳細、重複する status 文、検証メモ
- Host App: command preview、setup、validation notes の常時表示

### 判断基準

- キーボード上では「今入力できるか」「Mic を押せるか」「Delete / Return が使えるか」を優先する
- 音声入力の制約や検証状況は、必要なときだけホストアプリで読む
- 同じ意味の文言を transcript、pill、status に重ねて出さない

### ホストアプリ

- `List` ベースの設定画面から、縦スクロールの運用ダッシュボードに寄せる
- 最初の画面で「現在の音声入力状態」「Start Voice Input」「Keyboard QA field」が見えるようにする
- 説明文は短いカードに圧縮し、設定手順と検証メモは Developer Details に下げる
- 独自色は minimal にし、iOS semantic color と Material を基本にする
- Primary action は塗り、補助操作は控えめにする

### キーボード拡張

- 上段は transcript、状態、meter を統合した voice input preview のみにする
- Mic 状態は preview 内の小さな label と meter で見せ、capability 詳細はアクセシビリティ値に寄せる
- controls はキーらしい矩形に整理し、Mic だけ状態色を使う
- 小さい keyboard height でも `Speak` が主操作として読め、Next / Delete / Return は icon-only で潰れないことを優先する
- Extension 内 probe は experimental なので、成功表示以外で「録音アプリらしさ」を出しすぎない

## 検証観点

デザインパターンを試すときは、次を見る。

- 小さい高さで文字が潰れないか
- Mic unavailable / probe needed / ready が混同されないか
- Delete / Return / Next が普通のキーとして見えるか
- Dynamic Type で破綻しないか
- 透明感が可読性を下げないか
- スクリーンショットで状態差が説明できるか
- unavailable / listening / compact の Preview を維持し、状態差を画像で確認できるか
