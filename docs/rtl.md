# Setsuna RTL

`verilog/`は、C版simと同じ命令処理をハードウェアへ移すためのRTL実装。
現在は最初の移植段階として、5段パイプラインとRV64IM整数命令、キャッシュ、
GPIO/UART外部接続を実装している。RV64GC全体の移植完了を意味しない。

## 構成

```text
setsuna
├── core
│   ├── IF ─ ID ─ EX ─ MEM ─ WB
│   ├── decode / execute
│   └── 32 x 64-bit integer register file
├── instruction cache ─ instruction backing-memory bus
└── data cache ─ peripheral bus
                 ├── GPIO
                 ├── UART TX
                 └── data backing-memory bus
                                  │
                    memory arbiter / DDR3 adapter
                                  │
                  Tang Primer 20K DDR3 controller
```

- `verilog/core/`: IF/ID、ID/EX、EX/MEM、MEM/WBの段間レジスターを持つ、
  インオーダー・単一発行の5段パイプライン。
- `verilog/cache/`: 64-bit line、ライン数可変のdirect-mapped write-back cache。
  命令用とデータ用に同じモジュールを2個使う。ラインデータとタグは同期読み出し・
  書き込みのブロックRAM、valid/dirtyはFFで保持する。
- `verilog/peripheral/`: MMIOデコード、GPIO、UART送信。
- `verilog/memory/`: boot image転送、I/D調停、64-bit busから16-bit DDR commandへの変換、
  simulation用DDRモデル。
- `verilog/setsuna.v`: コア、I/D cache、peripheralを接続するトップ。
- `verilog/test/`: 各階層と統合トップの自己検証テストベンチ。

## 現在の命令範囲

RV64Iの整数演算、分岐・ジャンプ、load/store、`FENCE`/`FENCE.I`の順序化不要な
単一hartでのno-op動作、`ECALL`/`EBREAK`停止、およびRV64Mの乗除算を実装。
32-bitの`*W`結果は64-bitへ符号拡張する。

実装済みのパイプライン制御:

- EX/MEMとMEM/WBからの整数forwarding、および同一cycleのWB-to-ID bypass。
- load-use依存への1 bubble挿入。
- 命令・データready/validバスによるメモリ待ち。データ待ち中は全段を保持する。
- EX段での分岐解決と、not-taken経路のflush。
- 分岐・jumpの解決までは命令要求を止め、未完了のcache要求とredirect先PCの混同を防止。
- illegal instructionと`ECALL`の若い命令を破棄し、WBでpreciseに停止。
- `EBREAK`後の若いstoreを破棄して正常停止。
- x0の書き込み禁止、cycle/retiredカウンター、レジスターdebug read port。

まだ移植していないもの:

- C拡張の16-bit命令fetch/decompress。
- A拡張のLR/SC・AMO。
- F/Dレジスターファイルと浮動小数点演算器。
- Zicsr、M-mode CSR、`mtvec`トラップ遷移、`mret`。
- 割り込み、MMU、PMP、S-mode、複数hart。
- 非整列accessの分割、cache flush/invalidate命令、命令cache coherence。
- 乗算器のタイミング改善。現在はDSPを使う組み合わせ64×64積をEX段で計算する。

`core`と`setsuna`の`ENABLE_M` parameterを0にすると、M命令をillegal instructionとして
扱い、乗除算器を合成結果から除去できる。Tang Primer 20Kの既定構成ではMを有効にする。
乗算は一つの64×64積をDSPで計算し、`MULH`/`MULHSU`の上位半分は符号補正で得る。
除算・剰余は1サイクルに商の1ビットを求める反復除算器を共有し、最大64サイクルの間
EX段を保持する。`DIV[U]W`/`REM[U]W`は32サイクル、ゼロ除算は直ちに結果を返す。
符号付き除算は絶対値で計算して商・余りの符号を戻す。除数ゼロと
最小負数÷-1の場合もRISC-Vの規定値を返す。メモリ待機と除算待機が重なる場合も
完了値を保持し、旧い命令のretireと後続命令の停止を分ける。
従来の組み合わせ除算ではYosysが除算を幅の数だけ比較・減算段に展開する。
この変更ではDSPを4個使用し、256ラインROM版のYosys合成LUT4は
M無効の6,458個からM有効の7,395個へ増加した。配置配線後も27 MHz制約を通過した。
DDR PHYの制限は`docs/fpga.md`を参照。
また、`CACHE_LINE_COUNT`と
`CACHE_INDEX_BITS`でI/D cache容量を指定でき、同ボードの既定値は各256 line（2 KiB）。
`scripts/fpga/run.py --cache-lines N`で2〜256 lineの2の累乗を指定できる。

次の移植順は、C fetch/decompress、CSR/例外、A、F/D。
F/DはSoftFloatをそのままRTL化できないため、IEEE 754演算器または検証済みのFPU IPを
選び、RISC-Vの丸めモード、例外フラグ、NaN boxingをcore側で接続する。

## バス

core側の命令・データバスとcacheのbacking-memoryバスはready/valid方式。
要求側は`valid`、address、write情報を`ready`まで保持する。read/write完了は
`valid && ready`のcycle。memory read dataはそのcycleに有効。

backing-memory busは64-bit単位。address下位3bitを含めて渡すが、通常メモリは
8-byte境界のwordを返す。byte/half/word load/storeはcoreのshiftとbyte strobeで扱う。
現在、line sizeも64-bitなのでburstは使用しない。

cacheは`0x00000000f0000000`から`0x00000000ffffffff`をuncachedとしてperipheralへ通す。
ヒットも同期RAMの読み出し後に判定するため、通常メモリ要求には1サイクルの参照段を設ける。
ラインデータとタグはリセットせず、valid bitのクリアで無効化する。両配列とも
同期読み出しと単一書き込みでGowin BSRAMへ推論させる。256ラインのROM起動トップでは
I/Dキャッシュに`SDPX9B`が各4個（データ2個＋タグ2個）、合計8個使われる。
boot ROMは別に`SPX9` 4個を使う。`make test-rtl`で単体のBRAM割り当ても検査する。

ROM起動トップのYosys合成比較（同じツール・ボード構成、I/D同容量）:

| cache構成 | LUT4 | FF（DFFE+DFF） | cache用BSRAM |
| --- | ---: | ---: | ---: |
| 2ライン、タグをFFに保持 | 5,778 | 2,698 | 4 |
| 16ライン、タグをFFに保持 | 6,780 | 4,296 | 4 |
| 16ライン、タグをBSRAMに保持 | 5,950 | 2,472 | 8 |
| 128ライン、タグをBSRAMに保持 | 5,970 | 2,584 | 8 |
| 256ライン、タグをBSRAMに保持 | 6,508 | 2,712 | 8 |

256ラインは各2 KiBのデータに加えタグも同じ8個のBSRAMに収まり、
16ラインと比べてBRAM個数を増やさずに容量を16倍にできる。

### BRAM推論から得た教訓

合成結果を増やしたキャッシュ容量に対して確認すると、ラインデータだけをBRAMにしても
タグ配列がFFに展開され、2→16ラインでFFが2,698→4,296個、LUT4が5,778→6,780個に
増えた。タグもBSRAMへ移すことで、16ライン時点でFFは2,472個、LUT4は5,950個へ下がり、
256ラインまで容量を増やしてもFFは2,712個、LUT4は6,508個に収まった。

BRAM推論では属性だけでなく、同期読み出し、単純な書き込みポート、RAM配列を初期化・
リセットしない記述が重要だった。valid bitだけをリセットすればRAM内容は無効扱いできる。
タグとデータを要求受付時に同期読み出しし、その次の段でhit判定する構成にした。
推論されたと思い込まず、YosysのGowinマッピング後JSONで`SDPX9B`の実数を確認し、
配置配線後のLUT/FF/BSRAM利用率とタイミングも合わせて評価する。

## MMIO

| Address | Read | Write |
| --- | --- | --- |
| `0xf0000000` | GPIO input | GPIO output |
| `0xf0000010` | 0 | UART TX byte。busy中はreadyを下げる |
| `0xf0000018` | bit 0: UART busy | ignored |

UARTは8-N-1。`CLOCK_HZ`と`UART_BAUD`は`setsuna` parameterから指定する。

## テスト

OSS CAD Suiteを導入済みなら、その固定版のIcarus VerilogとYosysを使う。
未導入の場合はPATH上の`iverilog`、`vvp`、`yosys`を使う。

```sh
make fpga-setup
make test-rtl

# 一部だけ実行
python3 scripts/rtl_test.py core cache
```

`make test-rtl`の検証内容:

- `core`: forwarding、WB-to-ID bypass、load-use、データmemory wait、taken branch flush、RV64M、
  store/load、precise `EBREAK`。
- `core_m`: DIV/REMの符号付き・符号なしとW命令、ゼロ除算、最小負数のオーバーフロー、
  依存命令を挟んだEX停止、MULH系とMULW。
- `cache`: cold miss、read hit、byte write、dirty eviction/write-back、MMIO bypass。
- `peripheral`: GPIO read/write、UART busy/waveform、通常memoryへのforward。
- `setsuna`: core + I/D cache + peripheralの統合実行。命令をmemoryからfetchし、
  MMIO storeでGPIOを更新して停止する。
- `dram_memory`: boot imageをDDRモデルへ転送した後、I/D read、partial writeの
  read-modify-write、refreshを検証する。
- 全RTLをトップ`setsuna`として再コンパイルし、Yosysでhierarchy展開、process変換、
  structural checkを実行する。ログは`build/rtl-tests/yosys-check.log`。

テストは生成物を`build/rtl-tests/`へ置き、ソースツリーを変更しない。
Tang Primer 20K用トップはonboard DDR3接続まで実装済みで、RTL testbenchではDDR boot後に
GPIOの6-bit binary counterが`1, 2, 3`へ進む。現行OSS CAD SuiteではDQS primitiveを
nextpnrが配置できないため、CPU+DDR版の実機bitstream生成は配置前で停止する。
実験用portable PHYは通常OSER8とfabric入力へ置換するが、物理PHYの検証は未完了。
`fpga-sim`の成功は物理DDR接続の成功を意味しない。詳細は[FPGAガイド](fpga.md)を参照。
既存の`fpga/tang-primer-20k/blink.v`はFPGAツール経路を検証する独立した回路。
