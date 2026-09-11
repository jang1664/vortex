# Why naive currently gates input-child idle with !packetizer_active

## Answer

`!packetizer_active` is required by the **current naive command-completion protocol**, not by an intrinsic requirement that GEMM finish its output before accepting another input. It combines two distinct restrictions: keeping a completion NOTIFY behind physical writeback, and allowing only one command to own the packetizer's active head.

Current naive already has operand-register lifetime protection and tagged PSUM dependency tracking. Their absence is not the reason for this gate. Removing the gate alone neither supplies the missing admission/completion separation nor preserves the meaning of GEMM completion notifications.

## 1. The gate holds back NOTIFY, not just the next input DMA

In `VX_gemm_ctrl_naive`, the input child queue executes its head only when `gemm_ctrl_if.input_read_flag.idle` is true. The queue contains both normal input commands and NOTIFY commands. The FSM emits:

```text
Input(A) -> NOTIFY(G_done_A) -> WAIT(G_done_A) -> subsequent work
```

The NOTIFY goes into the same input child queue, while WAIT remains in the parent synchronization stream. In `VX_gemm_node_naive`:

```systemverilog
input_read_flag.idle = !input_notify_pending_r
                   && !packetizer_active
                   && packetizer_cmd_ready
                   && input_dma_ctrl_if.idle;

input_notify_req = input_read_ctrl.start
                && input_dma_ctrl_if.idle && input_is_notify;
```

Once accepted, NOTIFY sets `input_notify_pending_r`; the sync interface publishes the requested register/value. **There is no additional writeback check in that notification path.** The check happens indirectly through child idle: `packetizer_active` must clear before the NOTIFY can execute.

The retained M4 trace makes the distinction concrete:

| Event for command 12 | Cycle |
|---|---:|
| Last input admitted | 1527 |
| Input DMA idle | 1530 |
| Compute tagged writeback | 1543 |
| Physical write queues empty / packetizer completion | 1546 |
| Child idle; queued NOTIFY accepted | 1547 |
| NOTIFY sync update | 1548 |
| Parent GEMM WAIT satisfied | 1549 |

At cycle 1530, DMA idle and packetizer capacity are already available, but the command is not complete. With only `!packetizer_active` removed, the existing RTL would permit that queued NOTIFY as soon as the DMA becomes idle. This is a source-derived counterfactual, not a modified-RTL simulation result. It would change the meaning of G_done from “compute and physical writes completed” to something closer to “input DMA finished.” Parent WAIT, output-store launch, and buffer reuse depend on the former meaning.

This is the most direct correctness role of the gate. Treating it solely as a limit on how many input descriptors may be queued misses the notification dependency.

## 2. The packetizer has one head for both input admission and completion

`VX_gemm_input_packetizer` has a four-entry context FIFO, but its entries are not four independently advancing input streams:

```systemverilog
head_context = contexts[head_ptr];
command_active = (context_count != 0);
input_ready_out = head_valid && !head_context.ingress_done && input_ready;
```

The last admitted packet sets `contexts[head_ptr].ingress_done`. It **does not advance `head_ptr`**. Only `completion_fire`, driven by `common_writeback_drained`, clears that entry and advances the head.

Consequently, after A's last input:

```text
head = A, A.ingress_done = 1
    -> packet_ctrl.valid = 0 and input_ready_out = 0
    -> B may be queued behind A, but cannot supply packets
    -> A writeback/drain completes
    -> head advances to B
```

The metadata remain associated with A until A's writeback. The node even asserts that a tagged writeback's `work_seq` equals `packetizer_active_work_seq`. Therefore moving the head on ingress completion without introducing separate completion ownership would also violate the current association.

Removing the idle gate could permit earlier DMA preparation after an early NOTIFY, with B's data eventually backpressured. It would not, by itself, allow B's input to enter the MXU before A's completion, because the packetizer's head still blocks it.

## 3. Completion tracking assumes this serialization

The node uses one `gemm_done_pending_r` bit and an aggregate `gemm_wr_lane_pending_r` count. A tagged writeback sets the bit; the bit together with empty write queues produces `common_writeback_drained`. That pulse retires the current packetizer head.

This representation is sufficient for the current serialized ownership. It is not a per-command completion queue: it does not assign physical write-drain acknowledgments to multiple independently admitted command contexts. An overlapping design needs an explicit rule for which command each completion/fence acknowledges; simply replacing `completion_valid` with `ingress_complete` would announce physical completion too early.

## 4. PSUM and W/S/Z hazards are already partially handled below this gate

The relevant existing mechanisms are:

- `VX_gemm_acc_lmem` records accepted transaction tags and write addresses. Its read issue logic checks earlier accepted writes to the same address before issuing a PSUM read. This covers a producer that has been accepted but has not yet presented its physical write.
- The naive node's `psum_wr_pending_by_set` and current-write conflict logic cover physical PSUM writes pending through lane splitting and LMEM submission.
- The shared compute core has weight/scale/zero busy and pre-consumption tracking, writer backpressure, and exact load-version checks. These mechanisms also exist when instantiated by naive.

Thus it would be incorrect to explain `!packetizer_active` as “naive has no scoreboard” or “the next command always needs the previous result.” The naive FSM advances N microtiles before advancing K; neighboring commands can target different PSUM slices. A later K contribution to the same slice has a real dependency, while independent slices need not wait for all prior outputs as a mathematical requirement.

These mechanisms are useful foundations for overlap, but they do not repair early G_done notification, the shared packetizer head, or completion ownership. Nor does their existence establish that every currently serialized schedule is safe when overlapped; command resources and final stores still require validation under the new protocol.

## 5. What improve separates

| Responsibility | naive | improve |
|---|---|---|
| Select metadata for the next input | `head_ptr` | `input_admit_ptr_r` |
| Select context whose completion is acknowledged | Same `head_ptr` | `input_complete_ptr_r` |
| Advance input selection | Physical completion | Last input admission |
| Ordinary input-command retirement | Physical write drain | Registered ingress completion |
| Writeback fence | Last packet of every input command | Commands explicitly marked `notify_on_writeback` |

Improve can move its admission pointer forward while older computation is still running. Ordinary command completion and required writeback fences have distinct meanings; input admission also checks its resource/context conditions. It is not simply ignoring output completion.

To give naive similar overlap, the work is therefore a protocol change: separate input admission from physical completion, keep required NOTIFY/WAIT fences tied to their real completion event, retain per-command metadata/ownership, and validate the existing PSUM and operand-register protections with multiple commands in flight. Broadly waiting for `!packetizer_active` can then be replaced with the appropriate condition for each command type. A one-line gate deletion does not implement that change.

## Sources and evidence

- [Naive node](../../../hw/rtl/core/gemm/VX_gemm_node_naive.sv): child idle, notification, write-drain completion, packetizer connection, PSUM pending writes, and work-sequence assertion.
- [Packetizer](../../../hw/rtl/core/gemm/VX_gemm_input_packetizer.sv): head selection, ingress-done gate, and completion-only head advancement.
- [Naive controller](../../../hw/rtl/core/gemm/VX_gemm_ctrl_naive.sv), [FSM](../../../hw/rtl/core/gemm/VX_gemm_fsm_naive.sv), and [sync engine](../../../hw/rtl/core/gemm/VX_gemm_sync_naive.sv): ordered input/NOTIFY/WAIT routing.
- [LMEM accumulator backend](../../../hw/rtl/core/gemm/VX_gemm_acc_lmem.sv), [common compute core](../../../hw/rtl/core/gemm/VX_gemm_compute_core.sv): transaction dependencies and operand-register lifetime checks.
- [Improve node](../../../hw/rtl/core/gemm/VX_gemm_node.sv): separate admission/completion pointers and conditional writeback fences.
- [Existing FSDB transitions](fsdb_m4/naive/root_cause/transitions.json), [stage timing report](fpint_gemm_naive_input_gap_root_cause.md).

This follow-up is RTL and retained-waveform analysis. No gate-removal experiment or RTL modification was performed.
