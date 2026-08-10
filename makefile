TOP        ?= tb_mnist_fpga
FILELIST   ?= verilog.f

OBJ_DIR    ?= obj_dir
SIM_BIN     = $(OBJ_DIR)/V$(TOP)
WAVE_FILE  ?= wave.fst

SLANG      ?= slang
VERILATOR  ?= verilator
GTKWAVE    ?= gtkwave

SLANG_FLAGS := \
	--lint-only \
	--top $(TOP)

VERILATOR_FLAGS := \
	--binary \
	--sv \
	--timing \
	--assert \
	--trace-fst \
	--trace-structs \
	--top-module $(TOP) \
	--Mdir $(OBJ_DIR) \
	-Wall \
	-Wno-fatal

.PHONY: all lint compile run sim wave clean rebuild sources help

all: lint sim

# Slang을 이용한 SystemVerilog lint
lint:
	$(SLANG) $(SLANG_FLAGS) -f $(FILELIST)

# Verilator를 이용한 testbench 빌드
compile:
	$(VERILATOR) $(VERILATOR_FLAGS) -f $(FILELIST)

# 빌드된 simulation 실행
run: compile
	$(SIM_BIN)

sim: run

# testbench가 생성한 waveform 열기
wave:
	@test -f $(WAVE_FILE) || { \
		echo "Waveform not found: $(WAVE_FILE)"; \
		echo "Run 'make sim' first."; \
		exit 1; \
	}
	$(GTKWAVE) $(WAVE_FILE)

# 현재 filelist 내용 확인
sources:
	@sed -e '/^[[:space:]]*\/\//d' \
	     -e '/^[[:space:]]*$$/d' \
	     $(FILELIST)

clean:
	rm -rf $(OBJ_DIR)
	rm -f $(WAVE_FILE)

rebuild: clean all

help:
	@echo "make lint      Run Slang lint"
	@echo "make compile   Build with Verilator"
	@echo "make sim       Build and run simulation"
	@echo "make wave      Open $(WAVE_FILE) in GTKWave"
	@echo "make sources   Show the active file list"
	@echo "make clean     Remove generated simulation files"
	@echo "make rebuild   Clean, lint, build, and run"