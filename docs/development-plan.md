# Setsuna 開発計画

更新日: 2026-09-22 / 目標: **2027年3月**

## 決定した目標

1. Sipeed Tang系（まずTang Primer 20K + Dock）で検証できる環境を整備する。
2. 現在のApple Silicon / ARM Macで開発・ビルド・検証できるようにする。
3. `sim`を、教科書的な5段パイプラインを持つRV64GCエミュレータとして完成させる。

simは指定したバイナリを実行でき、公開テストを実行でき、MakefileまたはCMakeで
ビルドでき、デバッグ機能を備える。実装は可能な限りCとする。
C++やRustへ変更する場合は、具体的な利点と必要性を説明してから判断する。

以前の「Kasumiより優れた分岐予測」「パイプライン多段化」は研究の方向として残す。
まず5段の基準実装を完成させ、改良前後を比較できる状態を作る。

以下は開発時の設計案・完成条件案。現在の実装・使用方法・制約は
[simulator.md](simulator.md)を参照する。

## simの設計案

### 実行対象とビルド

- C17を基本とし、最初はMakefileでビルドする。CMakeの同時整備は必須としない。
- 単一hart、リトルエンディアンのRV64GCを対象とする。
- 命令範囲はRV64I / M / A / F / D / C / Zicsr / Zifencei。
  参照するISA仕様の版を実装開始時に固定する。
- 最初の対象はベアメタルのテストプログラム。RV64GC対応だけでLinux用実行ファイルが
  動くわけではないため、Linux ABI・OS起動・MMUは初期完成条件に含めない案とする。
- 標準入力形式はRISC-V ELF64とする。ロード可能セグメント、ゼロ初期化領域、
  エントリーポイントを処理し、形式・範囲・サイズを検証する。
- raw binaryもロード先・開始PCを明示して実行できるようにする。
- ゲスト物理アドレスは`uint64_t`で管理し、ホストのポインターと区別する。
- RAM範囲、起動状態、終了方法を文書化し、未対応命令・不正メモリアクセスを報告する。
- 公開テストの起動コードが要求するM-mode CSR・トラップ・`mret`等を調べ、
  必要な特権機能を実装する。CSRへのアクセスを無条件に無視してテストを通すことはしない。

CLIの使用例（テスト用ELFは別途用意する）:

```sh
make
./build/setsuna-sim --elf tests/example.elf
./build/setsuna-sim --binary example.bin --load-address 0x80000000 --entry 0x80000000
./build/setsuna-sim --elf tests/example.elf --debug
./build/setsuna-sim --elf tests/example.elf --trace trace.jsonl --max-cycles 1000000
make test
```

### 5段パイプライン

- IF / ID / EX / MEM / WBを、段間レジスターを持つサイクル単位のモデルとして実装する。
  5つの関数を命令ごとに順番に呼ぶだけでは完成としない。
- 現在状態と次サイクル状態を分け、validビット・stall・flushを明示する。
- 最初はインオーダー・単一発行とし、分岐はnot-takenを基準にする。
- forwarding、load-use hazard、分岐・ジャンプによるflushを実装する。
- C拡張の16bit / 32bit命令混在、命令境界をまたぐフェッチを扱う。
- 乗除算・浮動小数点の複数サイクル処理は、まず実行完了までstallする設計とする。
- 例外では先行命令の結果を保持し、後続命令や誤った分岐経路のstore等が
  アーキテクチャ状態へ反映されないことを保証する。
- サイクル数、完了命令数、stall・flush回数を表示する。
  メモリと演算器のレイテンシーを明記し、実機の速度と同一視しない。

### Cでの実装方針

CPU、メモリ、段間状態を構造体にまとめ、命令デコード・実行・ローダー・デバッガーを
分離すれば、Cで実装可能。現段階でC++・Rustへ変更する必要性はない。

F/Dの演算ではホストの`float` / `double`任せにせず、丸めモード、例外フラグ、
NaN、符号付きゼロ等を検証する。C実装の
[Berkeley SoftFloat](https://www.jhauser.us/arithmetic/SoftFloat.html)を採用候補とし、
RISC-V固有のNaN boxing、canonical NaN、CSRへの反映はsim側で扱う。
導入時にライセンス、固定バージョン、ARM Macでのビルド方法を記録する。

### デバッグ機能の最低要件案

- 継続実行、一命令完了までのステップ、一サイクルのステップ。
- PC指定のブレークポイント。停止時にどこまで命令が完了しているかを明確にする。
- PC、整数・浮動小数点レジスター、CSR、メモリの表示。
- 各段の命令PC、valid、stall、flushの表示。
- 完了命令のPC・命令ビット列・レジスター更新・メモリ更新・例外のトレース出力。
- 実行上限による無限ループ検出と、異常終了時の状態出力。

GDB remote接続は追加候補とし、まず内蔵CLIデバッガーを完成させる。

## 公開テストと完成判定

検証基準は[公式riscv-tests](https://github.com/riscv-software-src/riscv-tests)に確定。
Kasumiでも同じテストを使用している。
ソースとテスト環境が公開されているため、固定コミットから対象ELFを生成する構成を基本とする。
生成済みバイナリの配布だけには依存しない。

- まず仮想メモリなしの`p`環境を対象に、`rv64ui`からM/A/F/D/Cへ拡張する。
- テスト環境の起動・終了規約を調べ、`tohost`等による合否通知を扱う。
- 全テストに実行上限を設け、pass / fail / timeout / unsupportedを分けて報告する。
- 実行したテスト名、ソースのコミット、ツールチェーンの版、結果を記録する。
- ELF破損、即値・符号拡張、依存命令、load-use、flush、例外等の自前テストを追加する。
- F/Dの端数・NaN・丸め、AのLR/SC予約、Cの命令長など、拡張固有の境界条件を検証する。
- [RISC-V Architectural Tests](https://github.com/riscv/riscv-arch-test)を追加候補にする。
  ツールの版とターゲット構成を合わせ、テスト通過を無条件に正式認証とは呼ばない。
- 必要に応じて[Spike](https://github.com/riscv-software-src/riscv-isa-sim)等と
  命令完了時の結果を比較する。参照モデルのサイクル数とは比較しない。

完成条件は、ARM Macのクリーンなチェックアウトからビルドし、指定ELFを実行し、
対象RV64GCテストの合否を再現でき、5段パイプラインのhazard処理を検証でき、
上記デバッグ機能を使用できること。対象テストと未対応の実行環境は一覧にする。

## ARM Mac / Tang環境

2026-09-22、追加の指示によりTang Primer 20K + Dockの環境構築を実施。
OSS CAD Suiteの取得・合成・書き込みをスクリプト化し、ARM MacからテストRTLの
bitstream生成とSRAM書き込みまで確認した。手順は[fpga.md](fpga.md)を参照。
以下は当初の計画。UARTによる結果回収とCPU本体の搭載は引き続き今後の作業。

第一候補は[OSS CAD Suite](https://github.com/YosysHQ/oss-cad-suite-build)のdarwin-arm64版。
Yosys、nextpnr、Apicula、openFPGALoader等を組み合わせる。
Gowin向けの手順は[Apicula](https://github.com/YosysHQ/apicula)を参照する。
[openFPGALoaderの対応表](https://trabucayre.github.io/openFPGALoader/compatibility/board.html)
にはTang Nano 20Kが掲載されている。

整備の手順と完了条件:

1. ボード型番・リビジョン・FPGA品番・ピン割り当て・クロックを確認する。
2. ARM Mac用ツールを導入し、バージョンを固定して再現手順を残す。
3. 小さなLED点滅回路でRTLシミュレーション、合成、配置配線、bitstream生成を確認する。
4. USB経由で実機のSRAMへロードし、動作確認する。
5. UARTでテスト結果を回収する経路を用意する。
6. ボード設定を共通RTLと分離し、他のTang系へ展開できる構成にする。

環境整備完了は、ツールが存在するだけでなく、上の実機往復がARM Macから再現できること。
Tang Nano 20KへのRV64GC全体の搭載可否は合成結果で判断する。
ボード検証環境の整備と、CPU全体の実機搭載は別の達成項目として扱う。

2026-09-22のローカル確認では、`uname -m`は`arm64`。
PATH上に`cc`、`make`、`cmake`、`brew`、`iverilog`が見つかった。
`verilator`、`yosys`、`nextpnr-himbaechel`、`openFPGALoader`はその時点のPATHでは見つからなかった。
インストール全体の有無、バージョン互換性、ボード接続・実機動作は未確認。

## 実装順序と日程案

| 時期 | 主な作業 | 到達点 |
| --- | --- | --- |
| 2026年9〜10月 | ARM Mac / Tangの最小検証、simのビルド・CPU状態・メモリ・ELFローダー | LED点滅の実機確認と小さなRV64Iプログラムの実行 |
| 2026年10〜11月 | RV64I、必要なCSR・トラップ、公開テスト実行基盤 | 整数テストの結果を自動収集 |
| 2026年11〜12月 | 5段パイプライン、hazard・flush、M/C | サイクル実行と依存・分岐テストの通過 |
| 2027年1月 | A/F/D、浮動小数点の境界条件 | RV64GC命令範囲の実装 |
| 2027年2月 | デバッガー完成、差分検証、回帰テスト | 実行結果を追跡して不一致を調査可能 |
| 2027年3月 | 不具合修正、クリーン環境再現、仕様と制約の文書化 | simとTang検証環境の完成条件を確認 |

日程は作業量を測る前の案。デバッグ用トレースとテストは初期から作り、各段階で拡充する。
FPGA環境整備とsim開発は独立して進められる。sim完成後のRTL本体の完成日程は、
必要なFPGA資源と残作業を評価して別途具体化する。

## 現在の状態

`alpha-v1`と`main`をリモート取得後に比較し、どちらも`0412f93`で差分がないことを確認。
現在の`alpha-v1`で作業を継続している。

`sim/`にC17のエミュレータ、5段パイプライン、ローダー、デバッガー、Makefile、
公開テスト実行基盤を実装した。実装の範囲と制約は[simulator.md](simulator.md)に記載。
乗除算・FP演算のレイテンシーは現在1 EXサイクルのモデルとし、複数サイクル化は今後の拡張点。
`verilog/`は既存の骨組みのまま。別途`fpga/tang-primer-20k/`のテストRTLで、
ARM Macからの合成・配置配線・SRAM書き込みを確認済み。
