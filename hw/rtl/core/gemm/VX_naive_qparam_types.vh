`ifndef VX_NAIVE_QPARAM_TYPES_VH
`define VX_NAIVE_QPARAM_TYPES_VH
// Local adapter descriptor, not an ISA opcode or unified-command replacement.
// Fixed P0 physical address ceiling. Include inside a module/package scope.
`define VX_NAIVE_QPARAM_TYPES \
    typedef struct packed { \
        logic [33:0] base; \
        logic [31:0] stride; \
        logic [15:0] segments; \
        logic [15:0] useful_bytes; \
        logic buffer_id; \
        logic [31:0] generation; \
    } naive_qparam_source_t; \
    typedef struct packed { \
        logic bank; \
        logic qrow; \
        logic [15:0] offset; \
        logic [15:0] stride; \
        logic [37:0] writer_wait; \
        logic [31:0] install_target; \
    } naive_qparam_dest_t; \
    typedef struct packed { \
        naive_qparam_source_t source; \
        naive_qparam_dest_t dest; \
    } naive_qparam_desc_t;
`endif
