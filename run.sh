verilator --binary --trace-fst --timing -Wno-fatal \
-Irtl rtl/*.sv sim/tb_systolic_array.sv --top-module tb_systolic_array -o sim_out
./obj_dir/sim_out
gtkwave wave.fst