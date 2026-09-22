CC = cc
CFLAGS ?= -O2 -g -std=c17 -Wall -Wextra -Werror
CPPFLAGS += -Isim -Ithird_party/softfloat/source/include -DSOFTFLOAT_FAST_INT64
BUILD ?= build
SOURCES := $(wildcard sim/*.c)
OBJECTS := $(patsubst sim/%.c,$(BUILD)/%.o,$(SOURCES))
SF_SOURCE := $(abspath third_party/softfloat/source)
SF_LIBRARY := $(BUILD)/softfloat/softfloat.a
.PHONY: all deps test test-riscv clean
all: $(BUILD)/setsuna-sim
$(BUILD)/setsuna-sim: $(OBJECTS) $(SF_LIBRARY)
	$(CC) $(CFLAGS) $(LDFLAGS) $(OBJECTS) $(SF_LIBRARY) -o $@
$(BUILD)/%.o: sim/%.c sim/types.h | $(BUILD)
	$(CC) $(CPPFLAGS) $(CFLAGS) -MMD -MP -c $< -o $@
$(BUILD):
	mkdir -p $@
$(SF_LIBRARY): sim/softfloat/platform.h
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
clean:
	$(RM) $(OBJECTS) $(OBJECTS:.o=.d) $(BUILD)/setsuna-sim
-include $(OBJECTS:.o=.d)
