# Overview
- softmax node를 coprocessor로 붙인다.
- gemm node랑 비슷하게 MMIO reg를 이용해서 control 한다.
- DMA node와 local memory를 활용한다.
- softmax node는 local memory에 있는 data를 활용해서 연산하고 dram <-> local memory는 이미 있는 DMA node를 활용한다.
- kernel.cpp에서는 DMA node를 사용해서 dram <-> local memory를 하는 code와 local memory에 data를 준비 시킨 이후에는 softmax node를 사용해서 연산 하는 code가 있어야한다.
- double buffering으로 구현할 것이다.