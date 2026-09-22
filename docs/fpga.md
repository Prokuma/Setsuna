# Tang Primer 20K Dock 開発環境

OSS CAD Suiteの公式配布バイナリーをローカルに展開し、テストRTLのシミュレーション、
合成、配置配線、bitstream生成、JTAG書き込みをスクリプトで実行する。
対象は **Tang Primer 20K + Dock**。Nano 20KやPrimer 25Kの設定とは異なる。

## 初回セットアップ

必要なもの:

- macOS 13以降のARM64/x86-64、またはLinux ARM64/x86-64。WindowsではWSL2でビルドし、
  USB接続には別途USBパススルー設定が必要。Windowsネイティブはこのスクリプトの対象外。
- Git、Make、curl、Python 3.12以降（または`tarfile.data_filter`がバックポートされたPython）。
- 約0.5〜0.75 GBのダウンロードと、展開・一時ファイル用の数GBの空き容量。
- データ通信対応USBケーブル、Primer 20K Dock。

```sh
git clone --branch alpha-v1 --recurse-submodules https://github.com/Prokuma/Setsuna.git
cd Setsuna
# 既存チェックアウトでは:
make deps
make fpga-setup
make fpga-doctor
```

`make fpga-setup`は`oss-cad-suite.lock.json`に記録した日付付きリリースを選び、
OS/CPUに合うアーカイブを取得する。サイズとSHA-256が一致した場合だけ展開する。
途中で切断したダウンロードは`.part`から再開する。取得元は公式GitHub Releasesのみ。

現在の固定リリースは **2026-09-22**。配置先:

```text
.tools/cache/                                      # 検証対象アーカイブ
.tools/oss-cad-suite/2026-09-22/<host>/oss-cad-suite/  # ツール本体
```

システム全体へのインストールやシェル設定の書き換えは行わない。
スクリプトは固定版の実行ファイルを絶対パスで呼ぶため、Homebrew等の別バージョンと混在しない。
macOSでは検証済み展開物のquarantine属性を除去する。通常の実行でsudoは不要。
upstreamのnextpnrラッパーはユーザーの`.config/yosyshq`と`.local/share/yosyshq`を作成する。
実行環境がこれらを制限する場合は書き込み許可が必要。

`third_party/oss-cad-suite-build`はビルド定義の参照用submoduleとして固定している。
ツール本体をローカルでソースからコンパイルする構成ではなく、公式配布アーカイブを利用する。
ダウンロードしたバイナリーはGitに含めない。アーカイブに含まれる各ツールのライセンスに従う。

## 合成まで（ボード不要）

```sh
make fpga-sim    # RTL単体テスト
make fpga-build  # RTLテスト → Yosys → nextpnr-himbaechel → gowin_pack
```

既定の`cpu`デザインは`verilog/`のSetsunaコア、各2-lineのI/D cache、GPIO peripheral、
ボード内ROMを合成する。ROM上のRV64IプログラムがGPIO MMIOを介して6個のactive-low LEDを
順番に点灯する。Tang Primer 20K構成では組合せRV64M演算器を除外している。
`make fpga-sim`はROMプログラムが連続する2つのLED状態を書き込むまでを検証する。

独立したツールチェーン確認用blink回路も残している。

```sh
make fpga-blink-build
make fpga-blink-program
# または任意のfpga-* targetへ FPGA_DESIGN=blink を指定
```

| 設定 | 値 |
| --- | --- |
| FPGA | GW2A-LV18PG256C8/I7 |
| Yosys family | gw2a |
| nextpnr / gowin_pack family | GW2A-18 |
| 外部クロック | H11、27 MHz |
| LED0〜5 | L16、L14、N14、N16、A13、C13 |
| I/O電圧 | LVCMOS33 |
| 配置配線seed | 1 |

生成物は`build/fpga/tang-primer-20k/`:

- `setsuna.fs`: 既定CPUデザインの書き込み用bitstream。
- `blink.fs`: `FPGA_DESIGN=blink`で生成するsmoke-test bitstream。
- `synth.json` / `routed.json`: 合成・配置配線結果。
- `timing.json`: タイミング・使用資源レポート。
- `build-manifest.json`: ツール版、OS/CPU、入力とbitstreamのSHA-256、実行コマンド。
- 各工程の`.log`: 失敗した工程の切り分けに使用。

```sh
# 出力先を変える場合（空白を含むパスは直接Pythonに渡す）
python3 scripts/fpga/run.py build --build-dir /path/to/output
```

## 接続・SRAM書き込み

DockのJTAG側USBへ接続し、コアを有効にする。今回の実機ではDIPスイッチ1をONに設定した。
macOSで「アクセサリの接続を許可」が出たら許可する。

```sh
make fpga-scan     # USBデバッガーの列挙
make fpga-detect   # JTAG経由でFPGAを識別
make fpga-program # 現在のRTLを再ビルド → SRAMへ書き込み
make fpga-load     # 直前のmanifestとbitstreamを照合 → SRAMへ書き込み
```

SRAM書き込みは電源断で失われる。Flashの既存内容は書き換えない。
`fpga-program`は合成から書き込みまでを一度に行う。`fpga-load`は、直前の
`build-manifest.json`に記録されたdesign名、ファイル名、SHA-256が一致する場合だけ、
再ビルドを省いて同じbitstreamを書き込む。書き込み処理自体がJTAG chainを識別するため、
独立した`--detect`を重ねて実行しない。

書き込み後、DockのLEDがCPUの実行により順番に点灯することを目視確認する。
書き込み成功時は`program-manifest.json`と`program.log`を保存する。

複数のデバッガーを接続している場合は、`fpga-scan`で得たUSBシリアルを指定する。

```sh
python3 scripts/fpga/run.py program --serial '<USB serial>'
# 不安定なJTAGリンクの切り分けでは周波数を下げる
make fpga-detect FPGA_ARGS='--jtag-hz 1000000'
```

既定のJTAG要求周波数は2.5 MHz。今回のデバッガーでは実周波数2 MHzに丸められた。

## Flash書き込み（必要な場合のみ）

```sh
make fpga-flash
```

再ビルド・検出の後、openFPGALoaderの`-f`を使用して外部Flashに書き込む。
既存のFlash内容を置き換え、再起動後も回路を保持する。今回の確認はSRAM書き込みまでで、
Flash書き込みの実機検証は行っていない。

## 問題が起きた場合

再接続を繰り返す前に、失敗している層を分ける。

1. **ツール実行**: `make fpga-doctor`で実際の版を記録する。
   Primer 20KにはopenFPGALoader v0.9.0未満で書き込みが遅い・停止する既知問題があるため、
   doctorとビルドでv0.9.0以上を要求する。最新版かどうかだけでなく、固定版での実動作を確認する。
2. **USB列挙**: `make fpga-scan`が空なら、データ対応ケーブル、JTAG側ポート、macOSの
   アクセサリ許可、ハブ経由かどうかを確認する。OSにも機器がない段階では、
   FPGAの合成設定やJTAG速度を変えても改善しない。今回のMacではアクセサリ許可後に認識した。
3. **USBは見えるが開けない**: Linuxではlibusb/udev権限を確認する。
   必要なudevルールは[openFPGALoaderの導入手順](https://trabucayre.github.io/openFPGALoader/guide/install.html)
   に従って管理者が導入する。スクリプトはシステムの権限設定を自動変更しない。
4. **USBは開くがJTAG IDが取れない**: コアの電源・DIP設定、ボード型番、JTAG速度を確認する。
   デバッガーが列挙されたときのVID/PIDや種類を記録し、該当する公式ファームウェアの
   既知問題を調べる。NanoのファームウェアをPrimerに流用しない。
5. **合成・配置配線で失敗**: `yosys.log`、`nextpnr.log`、`pack.log`を確認する。
   別リリースとの比較が必要なら、lockファイルの日付・全プラットフォームのURL・サイズ・
   SHA-256を公式リリース情報に合わせて変更し、別ディレクトリに展開される版で同じRTLを検証する。
   動いた版を採用してlockファイルをコミットする。暗黙のアップグレードや自動降格はしない。

macOSのUSB情報だけを見る例:

```sh
ioreg -p IOUSB -l -w 0 | grep -E '"(USB Product Name|idVendor|idProduct)"'
```

`gowin_pack`のNumpy / Msgspec / fastcrc不在メッセージは、この配布版では高速化用の
オプション依存に関する警告。今回、bitstream生成は終了コード0で完了した。

## 確認結果（2026-09-22）

ARM Mac、OSS CAD Suite 2026-09-22で以下を確認:

- Yosys 0.69+117、nextpnr 0.11.1-31-g3edea68e、openFPGALoader v1.1.1。
- RTLテスト成功、合成・配置配線・bitstream生成成功。27 MHz制約PASS。
- USB: Sipeed FTDI2232互換JTAG Debugger（VID:PID `0403:6010`）。
- JTAG: IDCODE `0x81b`、Gowin GW2A(R)-18(C)。
- SRAMへの書き込み100%、openFPGALoader正常終了。
- ユーザーの目視確認により、DockのLEDが約0.5秒ごとに順番に点灯することを確認。
- Setsuna RV64Iコア、2-line I/D cache、GPIO MMIO、内蔵ROMを含む`setsuna.fs`を生成し、
  SRAMへの書き込み100%、openFPGALoader正常終了。CPU版のLED動作はRTL testbenchで確認。
- Linux/Intel Macの同じ手順用アーカイブとチェックサムは固定済みだが、各ホストでの実行は未検証。

## 参照

- [OSS CAD Suiteの公式配布とインストール](https://github.com/YosysHQ/oss-cad-suite-build)
- [ApiculaのPrimer 20K用ビルド設定](https://github.com/YosysHQ/apicula/blob/master/examples/Makefile)
- [Sipeed公式ピン設定](https://github.com/sipeed/TangPrimer-20K-example/blob/main/Litex/sipeed_tang_primer_20k/src/sipeed_tang_primer_20k.cst)
- [Sipeed Primer 20Kガイド](https://wiki.sipeed.com/hardware/en/tang/tang-primer-20k/primer-20k.html)
- [openFPGALoaderの既知問題](https://trabucayre.github.io/openFPGALoader/guide/troubleshooting.html)
