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
```

- `verilog/core/`: IF/ID、ID/EX、EX/MEM、MEM/WBの段間レジスターを持つ、
  インオーダー・単一発行の5段パイプライン。
- `verilog/cache/`: 64-bit line、16-entryのdirect-mapped write-back cache。
  命令用とデータ用に同じモジュールを2個使う。
- `verilog/peripheral/`: MMIOデコード、GPIO、UART送信。
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
- 乗除算の複数サイクル化。現在は組合せEXとして記述しており、機能シミュレーション用。

`core`と`setsuna`の`ENABLE_M` parameterを0にすると、M命令をillegal instructionとして
扱い、組合せ乗除算器を合成結果から除去できる。Tang Primer 20Kの現在のボード構成では、
限られた論理資源へ収めるためこのRV64I構成を使う。また、`CACHE_LINE_COUNT`と
`CACHE_INDEX_BITS`でI/D cache容量を指定でき、同ボードでは各2 lineに設定する。

次の移植順は、C fetch/decompress、CSR/例外、A、複数サイクルM、F/D。
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
- `cache`: cold miss、read hit、byte write、dirty eviction/write-back、MMIO bypass。
- `peripheral`: GPIO read/write、UART busy/waveform、通常memoryへのforward。
- `setsuna`: core + I/D cache + peripheralの統合実行。命令をmemoryからfetchし、
  MMIO storeでGPIOを更新して停止する。
- 全RTLをトップ`setsuna`として再コンパイルし、Yosysでhierarchy展開、process変換、
  structural checkを実行する。ログは`build/rtl-tests/yosys-check.log`。

テストは生成物を`build/rtl-tests/`へ置き、ソースツリーを変更しない。
この段階ではTang Primer 20KへのCPU RTLの配置配線・実機書き込みは行っていない。
既存の`fpga/tang-primer-20k/blink.v`はFPGAツール経路を検証する独立した回路。
