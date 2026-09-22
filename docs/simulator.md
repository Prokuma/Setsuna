# Setsuna simulator

C17で実装した単一hartのベアメタルRV64GCエミュレータ。
Clang/GCCの128bit整数拡張を乗算上位ビットの計算とSoftFloatで使用する。
CPU本体はC、テスト実行スクリプトのみPython 3、依存取得はPOSIX shell。

## ビルドと実行

Apple Silicon MacではXcode Command Line ToolsのCコンパイラーとmakeを使用する。
初回の依存取得にはネットワークが必要。

```sh
make deps
make -j4
make test
make test-riscv
./build/setsuna-sim --elf build/riscv-tests/rv64ui-p-add
./build/setsuna-sim --elf build/riscv-tests/rv64uc-p-rvc --debug
./build/setsuna-sim --elf program.elf --trace trace.jsonl --max-cycles 10000000
./build/setsuna-sim --binary program.bin --load-address 0x80000000 --entry 0x80000000 --tohost 0x80001000
```

`make test`はクロスコンパイラー不要。`make test-riscv`はPATH上の
`riscv64-unknown-elf-gcc`を使用する。コンパイラーを指定する場合:

```sh
python3 scripts/riscv_tests.py --cc /path/to/riscv64-unknown-elf-gcc --groups rv64ui rv64um
```

外部プロジェクトは`third_party/`以下のGit submoduleとして管理し、取得するリビジョンは
親リポジトリーのgitlinkで固定する。`make deps`は`git submodule update --init --recursive`を
実行し、riscv-tests内の`env`も取得する。生成物のみGit対象外とする。
依存のビルド手順は[README](../README.md)を参照。`make softfloat`でホスト向けライブラリー、
`make riscv-tests`でテスト用ELFのみをビルドできる。SoftFloatのライセンスは
`third_party/softfloat/COPYING.txt`、riscv-testsは`third_party/riscv-tests/LICENSE`を参照。
バイナリ再配布時にもそれぞれのライセンス条件を守る。

## 実行環境

- RV64I/M/A/F/D/C、Zicsr、Zifencei。浮動小数点はBerkeley SoftFloatのRISCV specialization。
- リトルエンディアン、単一hart、64 MiBのRAMを`0x80000000`に配置。
- ELF64 RISC-Vの静的実行形式をロード。PT_LOAD、BSS、entry、`tohost`シンボルを扱う。
  仮想アドレスと物理アドレスが同じイメージを対象とする。
- M-modeで起動。整数・FPレジスターとRAMはゼロ初期化。スタック設定はゲスト側で行う。
- M/U-mode、基本的なM-mode CSR、同期例外、`mret`を実装。
  未実装CSRへのアクセスはillegal instructionとなる。riscv-testsの起動時の
  S-mode/PMP/RNMI機能プローブも通常のトラップとして処理する。
- 通常のRAM load/storeは非整列アクセスを許可。atomicは自然アラインメントを要求。
  LR/SCは予約範囲へのstoreで予約を無効化し、SCの成功・失敗どちらでも予約を解除する。
- `tohost`へ1を書けば成功、それ以外の非ゼロを書けば失敗。
  ELFから検出できない場合は`--tohost`で指定する。
- `ecall`はゲストのトラップハンドラーへ渡す。Linux syscallやHTIFの汎用サービスは実装しない。
- `mtvec=0`で例外が発生した場合はエラーとして停止する。
- S-mode、MMU、割り込み、タイマー/周辺機器、Linux起動、複数hartは対象外。
  PMPも実装していない。全RAMを実行環境の共有メモリとして扱い、ELFの権限を
  メモリ保護としては適用しない。

## パイプライン

IF / ID / EX / MEM / WBの間に4つの段間レジスターを置く。
サイクルごとに現在状態から次状態を計算する。
EX/MEMからのforwarding、WB後のレジスター読み取り、load-use時の1サイクルstall、
EXでの分岐解決と若い命令のflushを実装する。予測はnot-taken。

例外はWBで確定し、若い命令を破棄する。store、CSR、FPフラグ、LR/SC予約の更新も
WBで確定するため、誤った経路や例外後の命令が状態を書き換えない。
CSR、fence、atomicは保守的に直列化する。

現モデルではRAMは1 MEMサイクル、乗除算・浮動小数点を含む演算は1 EXサイクル。
実FPGAの演算器レイテンシー、キャッシュ、バス競合はモデル化していない。
表示するサイクル数はこの基準モデルの値であり、実機の性能予測ではない。
演算器の複数サイクル化は今後の拡張点。

## デバッグ

`--debug`で内蔵CLIに入る。

| コマンド | 動作 |
| --- | --- |
| `c` | 継続実行 |
| `s` | 次の1命令が完了するまで進める（例外命令は完了数に含めない） |
| `t` | 1サイクル進める |
| `r` | 整数レジスター、フェッチPC、段間状態、累積stall/flushを表示 |
| `f` | FPレジスターをビット列で表示 |
| `csr 300` | CSRの保存値を表示（番号は16進数） |
| `x 80000000 32` | メモリ表示（アドレスは16進数、長さは10進数、上限256バイト） |
| `b 80000004` | ブレークポイントを設定（1個） |
| `delete` | ブレークポイントを解除 |
| `q` / EOF | 終了 |

ブレークポイントは指定PCの命令がWBで確定する直前に停止する。
若い命令がパイプライン内に存在する場合があるが、それらの結果はまだ確定していない。
停止後は`s`で対象命令を進める。GDB接続・逆実行・シンボル付き逆アセンブルは未実装。

`--trace`は完了命令とトラップをJSON Lines形式で記録する。
PC、命令ビット列、レジスター結果、store情報、トラップ原因が含まれる。

終了コード: 0=テスト成功、1=テスト失敗、2=入力/例外エラー、3=実行上限、4=デバッガー終了。

## 検証

`riscv-tests`の固定コミットから、改変せずに`p`環境のELFをビルドして実行する。
対象は`rv64ui`、`rv64um`、`rv64ua`、`rv64uf`、`rv64ud`、`rv64uc`。
`rv64ua`に同梱されるZacasの`amocas_w/d/q`はRV64GC外のため、理由付きでOUT_OF_SCOPEとする。
対象外をPASSとして数えない。

結果は実行バイナリと同じディレクトリの`riscv-tests/results.json`に出力する。
各テストのログ、ソースのコミット、コンパイラーの版、ホスト情報、simのSHA-256を保存する。
このテストの通過はRISC-Vの正式認証や、全ての特権仕様への対応を意味しない。

Sanitizerでの確認:

```sh
make -j4 BUILD=build-sanitize CFLAGS='-O1 -g -std=c17 -Wall -Wextra -Werror -fsanitize=address,undefined -fno-omit-frame-pointer' LDFLAGS='-fsanitize=address,undefined'
python3 tests/test_sim.py build-sanitize/setsuna-sim
python3 scripts/riscv_tests.py --sim build-sanitize/setsuna-sim
```

上記はsim本体を計装する。外部SoftFloatライブラリーは通常の最適化ビルド。

### 2026-09-22の検証結果

Apple Silicon (`arm64`)、Apple Clang 21、RISC-V GCC 11.1.0で確認。
通常ビルドとAddressSanitizer / UndefinedBehaviorSanitizer付きビルドの両方で、
独自回帰テスト13件と下記の公開テスト110件が成功。Sanitizer診断なし。

| 対象 | 成功数 |
| --- | ---: |
| rv64ui | 54 |
| rv64um | 13 |
| rv64ua（Zacasを除く） | 19 |
| rv64uf | 11 |
| rv64ud | 12 |
| rv64uc | 1 |

独自テストでは、forwarding、x0、load-use stall、誤分岐経路のstore/不正命令の破棄、
例外の順序、16/32bit混在フェッチ、BSS、壊れたELF、タイムアウト、未処理トラップ、
デバッガー、tohostの失敗通知を確認した。
