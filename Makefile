CC = cc
CFLAGS ?= -O2 -g -std=c17 -Wall -Wextra -Werror
CPPFLAGS += -Isim -Ithird_party/softfloat/source/include -DSOFTFLOAT_FAST_INT64
BUILD ?= build
SOURCES := $(wildcard sim/*.c)
OBJECTS := $(patsubst sim/%.c,$(BUILD)/%.o,$(SOURCES))
SF_SOURCE := $(abspath third_party/softfloat/source)
SF_LIBRARY := $(BUILD)/softfloat/softfloat.a
.PHONY: all deps softfloat riscv-tests test test-riscv test-rtl clean
all: $(BUILD)/setsuna-sim
$(BUILD)/setsuna-sim: $(OBJECTS) $(SF_LIBRARY)
	$(CC) $(CFLAGS) $(LDFLAGS) $(OBJECTS) $(SF_LIBRARY) -o $@
$(BUILD)/%.o: sim/%.c sim/types.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD):
	mkdir -p $@
softfloat: $(SF_LIBRARY)
$(SF_LIBRARY): sim/softfloat/platform.h $(wildcard third_party/softfloat/source/*.c third_party/softfloat/source/include/*.h third_party/softfloat/source/RISCV/*) $(wildcard third_party/softfloat/build/Linux-RISCV64-GCC/Makefile)
	@test -f third_party/softfloat/source/include/softfloat.h || { echo 'Run make deps first'; exit 1; }
	mkdir -p $(BUILD)/softfloat
	cp sim/softfloat/platform.h $(BUILD)/softfloat/platform.h
	$(MAKE) -C $(BUILD)/softfloat -f $(abspath third_party/softfloat/build/Linux-RISCV64-GCC/Makefile) SOURCE_DIR=$(SF_SOURCE) 'COMPILE_C=$(CC) -c -std=c17 -O2 -DSOFTFLOAT_FAST_INT64 -DSOFTFLOAT_ROUND_ODD -DINLINE_LEVEL=5 -I. -I$(SF_SOURCE)/RISCV -I$(SF_SOURCE)/include -o $$@'
deps:
	sh scripts/deps.sh
test: all
	python3 tests/test_sim.py $(BUILD)/setsuna-sim
test-riscv: all
	python3 scripts/riscv_tests.py --sim $(BUILD)/setsuna-sim
test-rtl:
	python3 scripts/rtl_test.py
riscv-tests:
	python3 scripts/riscv_tests.py --sim $(BUILD)/setsuna-sim --build-only
clean:
	$(RM) $(OBJECTS) $(OBJECTS:.o=.d) $(BUILD)/setsuna-sim
-include $(OBJECTS:.o=.d)

FPGA_DESIGN ?= cpu
.PHONY: fpga-setup fpga-doctor fpga-sim fpga-build fpga-scan fpga-detect fpga-program fpga-load fpga-flash fpga-blink-build fpga-blink-program
fpga-setup:
	python3 scripts/fpga/setup.py
fpga-doctor fpga-sim fpga-build fpga-scan fpga-detect fpga-program fpga-load fpga-flash:
	python3 scripts/fpga/run.py $(patsubst fpga-%,%,$@) --design $(FPGA_DESIGN) $(FPGA_ARGS)
fpga-blink-build:
	python3 scripts/fpga/run.py build --design blink $(FPGA_ARGS)
fpga-blink-program:
	python3 scripts/fpga/run.py program --design blink $(FPGA_ARGS)
