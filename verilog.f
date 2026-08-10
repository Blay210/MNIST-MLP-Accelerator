// Include directories
-Irtl

rtl/pkg/mnist_pkg.sv
rtl/mnist_accelerator.sv

sim/tb_mnist_fpga.sv
sim/memory


// RTL required by the current systolic-array testbench
-y rtl
-y rtl/systolic_array
-y rtl/memory
-y rtl/accumulator