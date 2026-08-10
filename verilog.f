// Include directories
-Irtl

rtl/pkg/mnist_pkg.sv
rtl/mnist_accelerator.sv

sim/tb_mnist_fpga.sv
sim/memory/weight_bram_model.sv
sim/memory/activation_bram_model.sv


// RTL required by the current systolic-array testbench
-y rtl
-y rtl/systolic_array
-y rtl/memory
-y rtl/accumulator