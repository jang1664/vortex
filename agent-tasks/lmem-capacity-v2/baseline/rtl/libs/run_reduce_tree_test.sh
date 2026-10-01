#!/bin/bash

# VX_reduce_tree_pipelined testbench simulation script

VORTEX_HOME="/home/jaeyongjang/project.local/vortex"
RTL_DIR="${VORTEX_HOME}/hw/rtl"
LIBS_DIR="${RTL_DIR}/libs"
TEST_DIR="${LIBS_DIR}"

echo "=================================================="
echo "VX_reduce_tree_pipelined Testbench Simulation"
echo "=================================================="

# Check if iverilog is available
if command -v iverilog &> /dev/null; then
    SIMULATOR="iverilog"
    echo "Using Icarus Verilog simulator"
elif command -v vcs &> /dev/null; then
    SIMULATOR="vcs"
    echo "Using VCS simulator"
else
    echo "ERROR: No supported simulator found (iverilog or vcs)"
    exit 1
fi

# Create work directory
mkdir -p work
cd work

if [ "$SIMULATOR" = "iverilog" ]; then
    # Icarus Verilog simulation
    echo ""
    echo "Compiling with Icarus Verilog..."
    
    iverilog -g2012 \
        -I${RTL_DIR} \
        -I${LIBS_DIR} \
        -o reduce_tree_sim \
        ${LIBS_DIR}/VX_reduce_tree_pipelined.sv \
        ${LIBS_DIR}/VX_elastic_buffer.sv \
        ${LIBS_DIR}/VX_pipe_buffer.sv \
        ${LIBS_DIR}/VX_stream_buffer.sv \
        ${LIBS_DIR}/VX_fifo_queue.sv \
        ${LIBS_DIR}/VX_reduce_tree_pipelined_tb.sv
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "Running simulation..."
        vvp reduce_tree_sim
        
        if [ $? -eq 0 ]; then
            echo ""
            echo "Simulation completed successfully!"
            if [ -f "VX_reduce_tree_pipelined_tb.vcd" ]; then
                echo "Waveform file: work/VX_reduce_tree_pipelined_tb.vcd"
                echo "View with: gtkwave work/VX_reduce_tree_pipelined_tb.vcd"
            fi
        else
            echo "ERROR: Simulation failed"
            exit 1
        fi
    else
        echo "ERROR: Compilation failed"
        exit 1
    fi
    
elif [ "$SIMULATOR" = "vcs" ]; then
    # VCS simulation
    echo ""
    echo "Compiling with VCS..."
    
    vcs -sverilog \
        +v2k \
        -timescale=1ns/1ps \
        +incdir+${RTL_DIR} \
        +incdir+${LIBS_DIR} \
        -o reduce_tree_sim \
        ${LIBS_DIR}/VX_reduce_tree_pipelined.sv \
        ${LIBS_DIR}/VX_elastic_buffer.sv \
        ${LIBS_DIR}/VX_pipe_buffer.sv \
        ${LIBS_DIR}/VX_stream_buffer.sv \
        ${LIBS_DIR}/VX_fifo_queue.sv \
        ${LIBS_DIR}/VX_reduce_tree_pipelined_tb.sv
    
    if [ $? -eq 0 ]; then
        echo ""
        echo "Running simulation..."
        ./reduce_tree_sim
        
        if [ $? -eq 0 ]; then
            echo ""
            echo "Simulation completed successfully!"
        else
            echo "ERROR: Simulation failed"
            exit 1
        fi
    else
        echo "ERROR: Compilation failed"
        exit 1
    fi
fi

echo ""
echo "=================================================="
