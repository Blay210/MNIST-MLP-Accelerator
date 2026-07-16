# Verilog Develop Settings

verilog 개발 환경 세팅 과정에서 가장 크게 고려한 부분은 **simulation**이다.   
vivado simulation이 편하지만, vivado project는 크고 무겁고 복잡하기 때문에 이것저것 사용해보고 고민한 끝에 verilator를 선택했다.  
Verilator는 WSL 환경에서 쉽게 세팅이 가능하기 때문에 모든 세팅을 **wsl - ubuntu** 환경을 기반으로 세팅하였다.  


## WSL - Ubuntu
1. Text Editor - VSCode
2. Simulation - Verilator


## How to simulate with Verilator
#### 1. Convert SystemVerilog to C++ and compile C++ file
```
verilator --binary --trace-fst --timing -Wno-fatal \
-Irtl {source files} {simulation file} --top-module {top module file} -o {execution file}
```
#### 2. Execute Simulation File
```
./obj_dir/sim_out
```
#### 3. Visualize WaveForm
```
gtkwave wave.fst
```