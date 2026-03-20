# Vivado Implementation Strategy for Robust Timing

이 문서는 Vivado implementation 시 setup/hold slack을 최대화하여 실제 하드웨어에서 더 안정적으로 동작하도록 하는 옵션들을 정리한다. 성능(Fmax)이나 면적보다 **타이밍 마진 확보**를 우선시하는 전략이다.

## 배경

Default implementation strategy에서 Vivado는 WNS(Worst Negative Slack) ~ 0ns에서 최적화를 멈춘다. 이는 타이밍을 "겨우 만족"하는 상태로, 실제 실리콘에서 온도/전압 변동이나 aging에 의해 failure가 발생할 수 있다. 아래 옵션들을 적용하면 면적과 컴파일 시간을 희생하는 대신 slack을 더 크게 확보할 수 있다.

## 적용 방법

### v++ (Vitis) 프로젝트

`vitis.ini`의 `[vivado]` 섹션에 `prop=` 라인으로 추가한다. 본 프로젝트에서는 `gen_vitis_ini.py`가 `vitis.ini`를 생성하므로, 해당 스크립트를 수정하거나 생성된 파일에 직접 추가한다.

```ini
[vivado]
prop=run.impl_1.STEPS.OPT_DESIGN.ARGS.DIRECTIVE=<directive>
prop=run.impl_1.STEPS.PLACE_DESIGN.ARGS.DIRECTIVE=<directive>
# ...
```

### Vivado GUI / Tcl

```tcl
set_property STEPS.PLACE_DESIGN.ARGS.DIRECTIVE ExtraTimingOpt [get_runs impl_1]
```

## Implementation Strategy (Built-in)

한 줄로 전체 전략을 설정할 수 있다:

```ini
prop=run.impl_1.STRATEGY=<strategy_name>
```

| Strategy | 설명 |
|---|---|
| `Performance_ExtraTimingOpt` | place_design에서 추가 타이밍 최적화 수행. **가장 추천** |
| `Performance_ExplorePostRoutePhysOpt` | post-route phys_opt까지 자동 활성화. 런타임 가장 길지만 슬랙 극대화 |
| `Performance_Explore` | 모든 단계에서 `Explore` directive 사용, 여러 알고리즘 시도 |
| `Performance_Retiming` | 레지스터 리타이밍으로 critical path 분산 |

> Built-in strategy를 지정하면 각 단계 directive가 자동 설정된다.
> 개별 단계를 직접 오버라이드하려면 strategy 대신 아래 방법을 사용한다.

## 개별 단계 Directive

각 단계별로 세밀하게 제어할 수 있다.

### opt_design

논리 최적화 단계. constant propagation, retarget 등.

```ini
prop=run.impl_1.STEPS.OPT_DESIGN.ARGS.DIRECTIVE=Explore
```

| Directive | 설명 |
|---|---|
| `Explore` | 여러 최적화 기법을 시도하여 최선의 결과 선택 |
| `ExploreArea` | 면적 최소화 방향 탐색 (타이밍 목적에는 비추천) |
| `ExploreWithRemap` | Explore + LUT remap 최적화 추가 |
| `Default` | 기본 최적화 |

### place_design

배치 단계. 타이밍 마진에 가장 큰 영향을 미치는 단계.

```ini
prop=run.impl_1.STEPS.PLACE_DESIGN.ARGS.DIRECTIVE=ExtraTimingOpt
```

| Directive | 설명 |
|---|---|
| `ExtraTimingOpt` | 배치 후 추가 타이밍 최적화 반복. 면적/런타임 증가하지만 슬랙 개선. **추천** |
| `ExtraNetDelay_high` | net delay에 pessimistic 가중치 부여, 보수적으로 배치. 라우팅 후 슬랙 개선에 효과적 |
| `ExtraNetDelay_low` | `ExtraNetDelay_high`의 약한 버전 |
| `ExtraPostPlacementOpt` | 배치 후 추가 최적화 패스 수행 |
| `Explore` | 여러 배치 알고리즘 탐색 |
| `SSI_SpreadLogic_high` | SLR이 있는 SSI 디바이스에서 로직을 분산 배치 (U55C 등에 해당) |
| `SSI_SpreadSLLs` | SLL(Super Long Line) 자원을 분산, SLR 간 타이밍 개선 |
| `Default` | 기본 배치 |

### phys_opt_design (Post-Placement)

배치 후 물리 최적화. 기본적으로 **비활성화** 상태이므로 명시적으로 켜야 한다.

```ini
prop=run.impl_1.STEPS.PHYS_OPT_DESIGN.IS_ENABLED=1
prop=run.impl_1.STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE=AggressiveExplore
```

| Directive | 설명 |
|---|---|
| `AggressiveExplore` | 가장 공격적인 최적화. 모든 기법(replication, retiming, rewire) 동원. **추천** |
| `Explore` | 여러 기법 시도하되 보수적 |
| `ExploreWithHoldFix` | Explore + hold violation 수정 |
| `ExploreWithAggressiveHoldFix` | hold violation을 적극적으로 수정. hold slack이 부족할 때 사용 |
| `AlternateReplication` | fanout이 큰 net의 driver를 복제하여 타이밍 개선 |
| `AggressiveFanoutOpt` | high fanout net 최적화에 집중 |
| `AddRetime` | 레지스터 리타이밍 수행 |
| `Disabled` | 비활성화 (기본값) |

### route_design

라우팅 단계.

```ini
prop=run.impl_1.STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE=NoTimingRelaxation
```

| Directive | 설명 |
|---|---|
| `NoTimingRelaxation` | 라우팅 실패 시에도 타이밍 요구를 완화하지 않음. 슬랙 양보 방지. **추천** |
| `MoreGlobalIterations` | 라우팅 반복 횟수 증가. 더 나은 해를 탐색 |
| `HigherDelayCost` | delay에 높은 cost 부여, 더 짧은 경로 선호 |
| `Explore` | 여러 라우팅 전략 시도 |
| `Default` | 기본 라우팅 |

### post_route_phys_opt_design

라우팅 후 물리 최적화. 마지막 슬랙 개선 기회. 기본적으로 **비활성화**.

```ini
prop=run.impl_1.STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED=1
prop=run.impl_1.STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE=AggressiveExplore
```

post-route에서는 이미 라우팅이 완료된 상태이므로 수정 범위가 제한적이지만, WNS를 수백 ps 개선할 수 있다. `AggressiveExplore`가 가장 효과적.

## set_clock_uncertainty (추가 타이밍 마진)

Vivado에게 클럭 불확실성을 더 크게 보고하여, 실질적으로 setup 목표를 빡빡하게 만드는 방법이다. 예를 들어 0.5ns를 추가하면 Vivado는 WNS 0.5ns 이상을 목표로 최적화한다.

본 프로젝트에서는 `pre_opt_hook.tcl`에서 적용한다:

```tcl
set setup_margin_ns 0.5
foreach clk [get_clocks -quiet *kernel_00*] {
    set_clock_uncertainty -setup $setup_margin_ns $clk
    puts "INFO: Added ${setup_margin_ns}ns setup margin to clock [get_property NAME $clk]"
}
```

> `pre_opt_hook.tcl`은 `gen_vitis_ini.py`에 의해 `OPT_DESIGN PRE` hook으로 등록되어 있다.
> 현재 주석 처리되어 있으므로 활성화하면 된다.

**주의사항:**
- 값이 너무 크면 (예: 1.0ns 이상) 타이밍 클로저 자체가 실패할 수 있다.
- 0.3~0.5ns 정도가 적절한 시작점이다.
- 100MHz (10ns period) 기준으로 0.5ns는 5%의 추가 마진에 해당한다.

## 추천 설정

다음은 robust hardware를 위한 추천 조합이다:

```ini
[vivado]
# Implementation directives
prop=run.impl_1.STEPS.OPT_DESIGN.ARGS.DIRECTIVE=Explore
prop=run.impl_1.STEPS.PLACE_DESIGN.ARGS.DIRECTIVE=ExtraTimingOpt
prop=run.impl_1.STEPS.PHYS_OPT_DESIGN.IS_ENABLED=1
prop=run.impl_1.STEPS.PHYS_OPT_DESIGN.ARGS.DIRECTIVE=AggressiveExplore
prop=run.impl_1.STEPS.ROUTE_DESIGN.ARGS.DIRECTIVE=NoTimingRelaxation
prop=run.impl_1.STEPS.POST_ROUTE_PHYS_OPT_DESIGN.IS_ENABLED=1
prop=run.impl_1.STEPS.POST_ROUTE_PHYS_OPT_DESIGN.ARGS.DIRECTIVE=AggressiveExplore
```

+ `pre_opt_hook.tcl`에서 `set_clock_uncertainty -setup 0.5` 활성화

### 트레이드오프

| 항목 | 영향 |
|---|---|
| 컴파일 시간 | 2~3배 증가 |
| LUT 사용량 | 소폭 증가 (replication에 의한) |
| Setup slack | 크게 개선 |
| Hold slack | `ExploreWithAggressiveHoldFix` 사용 시 개선 |

## 참고 자료

- [UG904 - Vivado Implementation User Guide: Strategy Descriptions](https://docs.amd.com/r/en-US/ug904-vivado-implementation/Implementation-Strategy-Descriptions)
- [Vitis Tutorials: Controlling Vivado Implementation](https://xilinx.github.io/Vitis-Tutorials/2022-1/build/html/docs/Hardware_Acceleration/Feature_Tutorials/06-controlling-vivado-implementation/README.html)
- [UG949 - UltraFast Design Methodology Guide](https://docs.amd.com/r/en-US/ug949-vivado-design-methodology)

**RTL 레벨 — 가장 효과가 큼**

**Pipeline stage 추가.** Implementation directive로 아무리 최적화해도 combinational depth가 깊으면 한계가 있어. Critical path에 register를 한 단계 더 넣으면 slack이 period 절반 이상 벌어질 수 있고, 이건 어떤 directive보다 효과가 크다. Latency 1 cycle 추가되는 trade-off지만 robustness 관점에서는 가장 확실해.

**SLR crossing에 전용 register stage 삽입.** U55C는 3-SLR SSI 디바이스라 SLR 경계의 SLL routing delay가 크다. RTL에서 SLR boundary마다 명시적으로 1~2단 FF를 넣고 `(* DONT_TOUCH = "yes" *)` attribute를 걸면 tool이 최적화로 제거하는 걸 방지할 수 있어. `SSI_SpreadLogic` directive보다 훨씬 예측 가능하고 확실해.

**CDC path에 synchronizer 단수 증가.** 2-FF synchronizer가 기본이지만 3-FF로 올리면 MTBF가 수십 배 이상 증가해. `(* ASYNC_REG = "TRUE" *)` attribute도 반드시 걸어야 Vivado가 동일 slice에 packing해줘.

**High-fanout signal에 RTL 레벨 replication.** Tool의 `AggressiveExplore` replication에 의존하는 것보다 RTL에서 직접 reset tree나 enable signal을 복제하는 게 더 안정적이야. Tool replication은 run마다 결과가 달라질 수 있거든.

---

**Constraint 레벨**

**클럭 주파수를 내리는 게 가장 단순하고 강력해.** 100MHz → 75MHz로 낮추면 period가 10ns → 13.3ns로 늘어나서 3.3ns의 추가 margin이 생겨. `set_clock_uncertainty` 0.5ns와는 비교가 안 되는 수준이야. Vitis flow에서는 `kernel.xml`이나 `--kernel_frequency` 옵션으로 조절 가능하고.

**Pblock으로 placement locality 강제.** Critical module을 특정 SLR이나 clock region에 묶어두면 routing delay variance가 줄어들어. 특히 U55C처럼 die가 큰 디바이스에서는 tool이 module을 여러 SLR에 흩뿌릴 수 있는데, Pblock으로 방지할 수 있어:

```tcl
create_pblock pblock_core
add_cells_to_pblock pblock_core [get_cells u_your_module]
resize_pblock pblock_core -add {SLR1}
```

**`set_max_delay -datapath_only`** 로 async path에 explicit bound를 거는 것도 중요해. False path로 처리된 경로가 실제로는 functional하게 쓰이면서 timing이 수십 ns까지 늘어나는 경우가 있거든.

---

**Bitstream / Configuration 레벨 — SEU 방어**

FPGA는 SRAM-based라 cosmic ray에 의한 Single Event Upset이 실제로 발생해. 특히 장시간 운용 시:

**CRC frame check 활성화:**
```tcl
set_property BITSTREAM.GENERAL.CRC Enable [current_design]
```

**Internal scrubbing 활성화** (UltraScale+에서 지원):
```tcl
set_property BITSTREAM.SEU.ESSENTIALBITS yes [current_design]
```

SEM (Soft Error Mitigation) IP를 instantiate하면 runtime에 configuration memory를 주기적으로 scan하고 1-bit error는 자동 correction, 2-bit은 detection해줘. Long-running application이면 이게 robustness에 실질적으로 기여해.

**ECC on BRAM/URAM 활성화.** Data integrity가 중요하면 BRAM을 ECC mode로 쓰는 게 좋아. Width가 줄어드는 trade-off가 있지만 soft error로 인한 silent data corruption을 막을 수 있어.

---

**요약하면 impact 순으로:**

가장 큰 것부터 — 클럭 주파수 낮추기 > RTL pipeline 추가 > SLR crossing register > Pblock constraint > 문서에 있는 implementation directives > `set_clock_uncertainty` > SEU mitigation. 성능을 포기할 수 있다고 했으니, 주파수를 내리고 pipeline을 넉넉히 넣는 게 directive 튜닝보다 훨씬 효과적이야.