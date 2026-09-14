# Reuse the pin-graph mocks and first verify the unchanged improve profile.
source [file join [file dirname [info script]] test_lifted_owner.tcl]
set ::env(VORTEX_GEMM_BACKEND) naive
foreach spelling {g_slr/u_link g_slr.u_link} {
    foreach {stream owner} {
        {u_naive_dma_slr/g_mmio[0].u_request} 0
        {u_naive_dma_slr/g_mmio[1]/u_response} 1
        {u_naive_dma_slr/g_lmem[15].u_transport/u_request} 1
        {u_naive_dma_slr/g_lmem[0]/u_transport/u_response} 0
        u_naive_dma_slr/u_global/u_request 1
        u_naive_dma_slr/u_global/u_response 0
    } {
        fixture $spelling $stream
        accepted $owner naive_retained_endpoint
    }
}
fixture g_slr.u_link u_naive_dma_slr/u_request
rejected lost_naive_stream_identity
puts "PASS: $::checks improve/naive connectivity-proven lifted-owner checks"
