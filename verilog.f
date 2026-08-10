// Include directories
-Irtl

rtl/pkg/mnist_pkg.sv
rtl/mnist_accelerator.sv

sim/tb_systolic_array.sv
sim/tb_bram_controller.sv
sim/tb_requantizer.sv
sim/tb_gemm_controller.sv
sim/tb_mnist_mlp.sv

// RTL required by the current systolic-array testbench
-y rtl
-y rtl/systolic_array
-y rtl/memory
-y rtl/accumulator