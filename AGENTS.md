# Setsuna: AIコーディングの指針

このファイルはリポジトリー全体に適用する。作業中のユーザー指示を優先し、
既存の変更を保護しながら、実装・検証・文書を整合させる。
ユーザーとの説明は原則として日本語で、結果と根拠を簡潔に伝える。

## 目標と現在の範囲

- 目標時期は2027年3月。Apple Silicon Macで開発できる環境と、
  教科書的な5段パイプライン（IF / ID / EX / MEM / WB）を基準にする。
- `sim/`はC17の単一hart・リトルエンディアンRV64GCベアメタルエミュレータ。
  ELF64/raw binaryの選択、CLIデバッグ、retirement traceを備える。
- `verilog/`はハードウェアへ移植中のRV64IM実装。simとRTLの対応範囲は異なる。
  C/A/F/D、CSR・特権モード・例外処理等を実装済みと扱わない。
- 現在の実機対象はTang Primer 20K + Dock。Tang Nano 20K等の設定と混同しない。
- 長期目標は138K規模のFPGAへRV64GCを載せてLinuxを起動すること。
  特権機能、MMU、割り込み、起動環境等も必要であり、GC命令対応だけで達成とはしない。
- DDR版の実機検証後に、資源・タイミングを測りながらキャッシュ容量を増やす方針。
  将来計画を現在の実装範囲や、個々の依頼への追加作業と混同しない。

## 作業前に確認すること

1. `git status --short`と現在のブランチを確認し、ユーザーの未コミット変更を保持する。
2. 現在の開発ブランチは`alpha-v1`。ブランチ選択が必要な場合は、`main`との
   コミット関係も調べる。名前だけで最新を決めず、関係ない変更の破棄・切替をしない。
3. 触る範囲に応じて以下を読む。

| 対象 | 主な参照先 |
| --- | --- |
| 全体の入口・コマンド | `README.md`、`Makefile` |
| Cエミュレータ | `docs/simulator.md`、`sim/` |
| RTL、バス、MMIO | `docs/rtl.md`、`verilog/` |
| FPGA、DDR、実機操作 | `docs/fpga.md`、`scripts/fpga/`、`fpga/tang-primer-20k/` |
| 当初の要件・計画 | `docs/development-plan.md` |

`docs/development-plan.md`には過去時点の状態も残っている。
現在の動作はソース、専用ガイド、実行ログで確認し、古い計画や合成値を
今回の検証結果として報告しない。

## 構成と実装方針

- `sim/`: CPU状態、段間状態、デコード、実行、メモリ、ローダー、デバッガー。
  可能な限りCで実装する。C++・Rustへの変更には具体的な利点と必要性を説明する。
- `verilog/core/`: パイプライン、演算器、レジスターファイル。
- `verilog/cache/`: 実際のキャッシュメモリ。通常のRAMや外部バスをキャッシュと呼ばない。
- `verilog/peripheral/`: GPIO/UART等の外部接続・MMIO。
- `verilog/memory/`: backing memoryの調停、DDRアダプター、boot loader、モデル。
- `fpga/`: ボード固有のトップ、ピン、クロック、デモ。
- `tests/`、`verilog/test/`: simとRTLの回帰テスト。
- `scripts/`: 依存取得、公開テスト、FPGA環境の再現手順。
- `third_party/`: Git submodule。ビルド生成物は`build*/`、ツールは`.tools/`へ置く。

段間レジスター、valid、stall、flushを明示した5段構成を維持する。
forwarding、load-use、分岐、長時間演算、メモリ待ちが重なる場合を考慮し、
若い命令のstoreや例外後の状態更新、二重retireを防ぐ。
ready/validバスは要求を完了まで保持し、read dataの有効サイクルを守る。
simとRTLでレイテンシーが異なるため、サイクル数の一致を機能正当性の条件にしない。

Cではゲストアドレスとホストポインターを区別し、境界チェックと整数のビット幅を守る。
符号付きオーバーフローやシフトの未定義動作に依存しない。
F/DはSoftFloatのRISC-V specializationを使用し、ホストの`float`/`double`だけで
丸めモード・NaN boxing・例外フラグを代用しない。
未対応CSRや命令を無条件に無視してテストを通さない。

## FPGA資源を使う際の教訓

- Verilogの配列や`ram_style`属性だけではBRAM使用の証拠にならない。
  データとタグを同期読み出しにし、RAM配列全体のresetを避け、validで無効化する。
  書き込みポートとbyte enableは対象BSRAMへ推論可能な形を保つ。
- データだけをBRAMに移しても、タグが大量のFFと読み出しMUXになる。
  容量変更時はタグも含め、LUT・全DFF系セル・BSRAMの増え方を確認する。
- ROMではゼロ初期化と`$readmemh`の書き込み範囲を重複させない。
  RTLシミュレーションが通っても、合成後のROM初期値が正しいとは限らない。
- RV64M乗算は共通の64×64積をDSPで計算し、上位積を符号補正する。
  除算・剰余は反復演算器で共有する。組み合わせの`/`・`%`へ安易に戻さない。
- 現行の反復除算は64ビットで64回、W命令で32回の反復を行い、EX段を保持する。
  メモリ待機中も完了値を失わず、ゼロ除算・符号・最小負数÷-1を維持する。
- 合成JSONの`SDPX9B`、`SPX9`、`MULT36X36`等を確認する。
  YosysのLUT4数とnextpnr packing後のLUT4数は区別して記録する。
- 容量超過をキャッシュやISAそのものの限界と即断しない。
  どの配列・演算器がどの資源へ展開されたか、クロックと配置制約も含めて調べる。

## 依存と再現性

外部プロジェクトはsubmoduleとして固定リビジョンで取り込む。
`make deps`は`git submodule update --init --recursive`相当であり、
`riscv-tests/env`の入れ子も取得する。無関係なsubmodule更新を含めない。
依存ソースへ変更が必要な場合は変更箇所と理由を明示し、上流への変更と
親リポジトリーのgitlink更新を追跡できる形にする。

FPGAツールは`scripts/fpga/oss-cad-suite.lock.json`の公式リリースとSHA-256を使う。
HomebrewやPATH上の別バージョンと混在させない。
ARM Mac以外でも再現できるよう、手順はMakefileまたはスクリプトとREADMEへ反映する。
ツール本体、bitstream、テストELF、大量のログをソースとしてコミットしない。

## ビルドと検証

変更に関係する検証を選び、結果と未検証範囲を報告する。
文書だけの変更には合成や全テストを繰り返す必要はない。

```sh
make deps                         # submoduleが未取得の場合
make -j4                          # C17 sim + ホスト向けSoftFloat
make test                         # simの回帰。クロスコンパイラー不要
make test-riscv                   # 公開ISAテスト。RISC-V GCCが必要
make test-rtl                     # RTL testbench + Yosys構造・BRAM・ROM初期値検査
python3 scripts/rtl_test.py core core_m cache  # 対象を絞る例
make fpga-setup                   # 固定版ツールの導入が必要な場合
make fpga-doctor                  # 実際のツール版を確認
make fpga-sim FPGA_BOOT=rom
make fpga-sim FPGA_BOOT=ddr        # transaction-level DDRモデル
make fpga-synth FPGA_BOOT=rom
make fpga-pack                     # 合成とpackingまで。書き込み用イメージは作らない
make fpga-build FPGA_BOOT=rom      # 配置配線・bitstreamまで
```

simの公開検証基準は`riscv-tests`の`p`環境。
対象は`rv64ui/um/ua/uf/ud/uc`で、Zacas等の対象外をPASSに数えない。
`make test-riscv`の成功をRTLのISA検証済みという意味で使わない。
現行RTLテストは`core`、`core_m`、`cache`、`boot_rom`、`peripheral`、
`dram_memory`、`ddr_cdc`、`dram_boot`、`setsuna`。新しいRTLファイルを追加したら、
`scripts/rtl_test.py`の明示的なソース一覧も更新する。

FPGAの既定は`FPGA_BOOT=ddr`。ROM起動は明示する。
比較用に`FPGA_ARGS='--disable-m'`、容量指定に`FPGA_ARGS='--cache-lines 128'`を使える。
現行CLIのキャッシュライン数は2〜256の2の累乗、ボード既定値は256ラインでI/D各2 KiB。
容量を増やす変更ではCLI検証、index幅、文書、合成結果も更新する。
条件比較には`--build-dir build/fpga/<比較名>`を指定して生成物を分離する。

## DDRと実機検証での注意

- 固定ツール環境でのnative DDR PHYはDQS BELの配置制限で停止する。
  ツール更新時は現状を再確認し、過去の制限を永久的なハードウェア制約と扱わない。
- portable PHYは実験用。差動I/O、read capture、timingは実機検証未完了。
  transaction-level DDRモデルの成功は物理DDRの動作証明にならない。
- CPUはROM/DDR版とも27 MHz。DDR controllerは約99.5625 MHzで動き、
  `ddr3_command_cdc`を通す。DDRのCPU起動前には全イメージをreadback照合する。
  `clocks.sdc`の実クロックで評価し、ROM版のFmaxをDDR版のtiming closureに流用しない。
- `make fpga-export-gowin`は未改変の上流DLL/calibration付きvendor用プロジェクトを
  出力する代替経路。Gowin EDA本体は別途必要で、export成功をvendor合成成功と扱わない。
- 成功は「RTL」「合成」「packing」「配置配線とtiming」「bitstream生成」
  「書き込み」「実機動作」を区別する。書き込み100%だけでDDR起動成功と報告しない。
- 実機操作は依頼された範囲で行う。`fpga-program`は再ビルド後のSRAMロード、
  `fpga-load`はmanifestで照合した既存イメージのSRAMロード、`fpga-flash`は永続Flash書き換え。
  manifest・SHA-256・boot/M/cache設定の照合と実験用ガードを維持する。
- 接続失敗時は同じ再接続を何度も試さない。USB認識、JTAG側ポート、電源・DIP、
  macOSのアクセサリ許可、実ツール版を証拠で切り分ける。
  バージョン・USB実装・別ツールやボード不要の検証等、別のアプローチを検討する。
- LEDはactive-lowの6ビット2進カウンターが基準。観察上の左右とLED番号の
  対応が逆の場合も考慮し、見えていない表示や動作を推測で断定しない。

## 作業を終えるとき

実装に対応するテスト・ビルド結果と、残っている制限をREADMEまたは専用ガイドへ反映する。
`git diff --check`で差分の体裁を確認し、実行した工程・結果・未実施の工程を簡潔に伝える。
コミット・プッシュはユーザーの指示がある場合に行い、対象ブランチと内容を確認する。
依頼と無関係な変更や生成物を混ぜず、完了後はコミットIDとリモート同期状態を報告する。
