// Preserve linear traversal for prefill, but skip padded tile rows for the
// power-of-two generation batch sizes.
#define SILU_USE_LINEAR_TILED 1
#define SILU_LINEAR_SKIP_PAD_ROWS 1
#include "kernel.cpp"
