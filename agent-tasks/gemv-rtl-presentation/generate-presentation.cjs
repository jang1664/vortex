#!/usr/bin/env node

const fs = require('fs');
const path = require('path');
const PptxGenJS = require('pptxgenjs');
const KO_TEXT = require('./ko-translations.json');

const OUT_DIR = __dirname;
const SLIDE_DIR = path.join(OUT_DIR, 'slides');
const PPTX_PATH = path.join(OUT_DIR, 'gemv-rtl-architecture.pptx');
fs.mkdirSync(SLIDE_DIR, { recursive: true });

const W = 1600;
const H = 900;
const C = {
  bg: '#FFFFFF',
  bg2: '#FFFFFF',
  panel: '#F7F7F7',
  panel2: '#EEF2F5',
  line: '#BCC5D0',
  white: '#111827',
  text: '#1F2937',
  muted: '#667085',
  blue: '#315F87',
  blue2: '#6F8DA7',
  cyan: '#466E76',
  green: '#55735A',
  amber: '#946B2D',
  orange: '#9B5B42',
  magenta: '#6D5C83',
  red: '#954F4F',
};

function koText(value) {
  return KO_TEXT[value] || value;
}

const KO_NOTES = [
  '범위는 fpint 기준 구조에서 feat/gemv까지의 RTL 변화이다. 발표 흐름은 병목, 아키텍처 해결책, 최종 하드웨어 순서이며 IMPROVE를 먼저 설명하고 NAIVE와 공유 구현은 뒤에서 다룬다.',
  '기존 IMPROVE 노드의 명령 진행, 피연산자 이동, compute/ACC, 출력 drain 경계를 보여준다. 주요 RTL 경로는 hw/rtl/core/gemm/VX_gemm_node.sv의 기존 IMPROVE 구조이다.',
  'ACC read/write count를 microtile 전체에 걸쳐 중앙 관리하면서 Input에서 ACC memory까지의 가변 latency가 공유 counter와 pipeline_empty 제약으로 전파됐다. 분석한 improve_th32 실행에서는 약 25 compute cycle 뒤 약 14 cycle의 명령·동기화·preload 공백이 관찰됐다.',
  '기존에는 중앙 ACC RD/WR counter와 pipeline_empty가 여러 microtile 진행을 해석했다. 변경 후 accept된 packet이 ACC 주소, R/W, work_seq, 정확한 generation과 last를 데이터와 같은 pipeline register로 운반한다. 관련 RTL은 VX_gemm_unit_v2.sv, VX_gemm_compute_core.sv, VX_gemm_acc_internal.sv이다.',
  'backpressure-ready 구조 전에는 GEMM unit 입구에서 Weight, Scale, Zero-point ready를 먼저 확인해야 해 unit-to-tree latency가 그대로 노출됐다. 구현은 elastic PRE/POST와 고정 latency MXU 영역으로 나누고 실제 consumer에서 정확한 W/S/Z bank와 generation을 확인한다. 5-cycle tree와 1-cycle feedback을 위해 depth-6 merged-result FIFO와 등록된 credit 반환을 사용한다. 근거는 gemm-unit-backpressure-opt spec과 VX_gemm_compute_core.sv이다.',
  '중앙 count 기반 dependency 대신 transaction과 microtile local 상태를 사용한다. ACC read를 미리 scheduling하고 짧은 RAW dependency는 forwarding하며 credit, ownership, backpressure를 해당 흐름에만 적용한다.',
  '물리 ACC bank를 두 실행 group으로 나누고 한 group을 compute하는 동안 다른 group을 drain한다. 출력 read는 전역 pipeline_empty가 아니라 같은 group 충돌에서만 차단한다.',
  '독립 WAIT와 NOTIFY opcode를 제거하고 writer-wait, 완료 notify, generation, work_seq metadata를 DMA와 compute 명령에 포함한다. 각 실행 block이 자신의 dependency를 확인하고 완료를 보고한다.',
  'tag가 있는 다중 명령 HBM DMA queue와 look-ahead chaining으로 N이 retire되기 전에 N+1을 시작한다. Scale과 ZP Local DMA를 분리하고 최종 실제 destination write에서 순서와 retire를 보장한다.',
  'VX_microtile_readiness_scheduler가 가장 먼저 실행 가능해질 microtile을 기준으로 부족한 I/W/S/Z traffic을 우선 처리한다. look-ahead는 제한하며 feedback은 register하고 local ready와 정확한 generation/fence를 최종 조건으로 유지한다.',
  'source 응답은 순서가 바뀔 수 있지만 destination write, notify, retire는 명령 순서를 유지한다. prefetch는 정확한 generation과 writer fence로 제한하며 stall 중 valid, payload, priority를 안정적으로 유지한다. 완료는 마지막 실제 write이다.',
  '최종 IMPROVE 흐름은 metadata admission, overlap된 operand 이동, elastic compute/ACC, 동시 output drain이다. 정확한 generation, 제한된 look-ahead, local ACC ownership과 순서 보장 final write가 정확성 fence가 된다.',
  'NAIVE 노드는 row-major 주소식과 LMEM 중심 operand/ACC 이동, 외부 output DMA를 사용한다. IMPROVE와 다른 memory 특성을 가진 독립 아키텍처로 소개한다. 주요 RTL은 VX_gemm_node_naive.sv이다.',
  '기존 NAIVE compute 경로는 ready/valid가 아니라 고정 timing에 control과 completion을 맞췄다. backpressure와 가변 ACC latency에 강하게 만들되 row-major 주소식, LMEM mapping, output DMA는 유지한다.',
  'accept된 Input packet을 안정적인 data+control record로 만들고 정확한 W/S/Z generation과 tag가 있는 LMEM ACC 요청을 사용한다. 명령 완료는 마지막 물리 LMEM write 이후에만 발생한다. 관련 RTL은 VX_gemm_node_naive.sv와 VX_gemm_acc_lmem.sv이다.',
  '두 아키텍처는 같은 elastic compute contract를 사용하지만 memory system이 다르다. IMPROVE는 TMEM scheduling과 내부 double-buffered ACC를, NAIVE는 row-major LMEM과 기존 외부 출력 경로를 사용한다.',
  '집중 RTL test는 RAW forwarding, 가변 ACC latency, scheduler, DMA ordering, node integration을 포함한다. IMPROVE XRT-VCS integration 7개 case가 통과했으며 최종 성능·utilization 수치는 benchmark configuration 확정 후 입력한다.',
  'VX_gemm_compute_core가 공유 elastic 연산과 packet-control contract를 제공한다. IMPROVE는 VX_gemm_acc_internal을, NAIVE는 VX_gemm_acc_lmem adapter를 연결해 각 memory 의미를 유지한다.'
];

const LIGHT_FILL = {
  '#10182A': '#FAFAFA',
  '#101A2C': '#F6F7F8',
  '#111A2C': '#F7F7F7',
  '#111D31': '#F5F7F9',
  '#121B2D': '#F7F7F7',
  '#12253B': '#EEF3F7',
  '#12263A': '#EEF3F7',
  '#12304A': '#E8EFF5',
  '#13233A': '#EEF3F7',
  '#142036': '#F1F3F5',
  '#142238': '#F3F5F7',
  '#14243A': '#EEF3F7',
  '#14263C': '#EEF3F7',
  '#142A27': '#EFF3EF',
  '#141D30': '#F3F4F6',
  '#151D2E': '#F3F4F6',
  '#153026': '#EFF3EF',
  '#15344C': '#E8EFF5',
  '#161D2F': '#F7F7F7',
  '#161D30': '#F7F7F7',
  '#17192A': '#FAF8F5',
  '#1B1E2D': '#F7F7F7',
  '#241A23': '#F8F1F1',
  '#241C35': '#F3EFF6',
  '#251923': '#F8F1F1',
  '#261A24': '#F8F1F1',
  '#271E3B': '#F3EFF6',
  '#291822': '#F8F1F1',
  '#2A2114': '#F8F4EC',
};

const sections = {
  baseline: { label: 'IMPROVE · BASELINE', color: C.amber },
  improve: { label: 'IMPROVE · ARCHITECTURE', color: C.blue },
  guard: { label: 'IMPROVE · CORRECTNESS', color: C.green },
  naive: { label: 'NAIVE · ARCHITECTURE', color: C.magenta },
  compare: { label: 'SYNTHESIS', color: C.cyan },
  appendix: { label: 'APPENDIX', color: C.muted },
};

function esc(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;');
}

function attrs(obj) {
  return Object.entries(obj)
    .filter(([, v]) => v !== undefined && v !== null && v !== false)
    .map(([k, v]) => `${k}="${esc(v)}"`)
    .join(' ');
}

function rect(x, y, w, h, fill = C.panel, stroke = C.line, r = 20, extra = {}) {
  const normalizedFill = LIGHT_FILL[fill] || fill;
  return `<rect ${attrs({ x, y, width: w, height: h, rx: Math.min(r, 8), fill: normalizedFill, stroke, 'stroke-width': stroke === 'none' ? 0 : 2, ...extra })}/>`;
}

function line(x1, y1, x2, y2, color = C.line, width = 3, extra = {}) {
  return `<line ${attrs({ x1, y1, x2, y2, stroke: color, 'stroke-width': width, 'stroke-linecap': 'round', ...extra })}/>`;
}

function arrow(x1, y1, x2, y2, color = C.blue, width = 4, dashed = false, marker = true) {
  return line(x1, y1, x2, y2, color, width, {
    'stroke-dasharray': dashed ? '10 9' : undefined,
    'marker-end': marker ? 'url(#arrow)' : undefined,
  });
}

function txt(x, y, content, size = 26, color = C.text, weight = 400, anchor = 'start', extra = {}) {
  return `<text ${attrs({ x, y, fill: color, 'font-family': 'Noto Sans CJK KR, Malgun Gothic, Aptos, Arial, sans-serif', 'font-size': size, 'font-weight': weight, 'text-anchor': anchor, ...extra })}>${esc(koText(content))}</text>`;
}

function mono(x, y, content, size = 20, color = C.text, weight = 500, anchor = 'start') {
  return `<text ${attrs({ x, y, fill: color, 'font-family': 'Noto Sans Mono CJK KR, D2Coding, Aptos Mono, Consolas, monospace', 'font-size': size, 'font-weight': weight, 'text-anchor': anchor })}>${esc(koText(content))}</text>`;
}

function lines(x, y, contentLines, opts = {}) {
  const size = opts.size || 25;
  const color = opts.color || C.text;
  const weight = opts.weight || 400;
  const anchor = opts.anchor || 'start';
  const lh = opts.lineHeight || Math.round(size * 1.28);
  const family = opts.mono ? 'Noto Sans Mono CJK KR, D2Coding, Aptos Mono, Consolas, monospace' : 'Noto Sans CJK KR, Malgun Gothic, Aptos, Arial, sans-serif';
  const spans = contentLines.map((s, i) => `<tspan x="${x}" dy="${i === 0 ? 0 : lh}">${esc(koText(s))}</tspan>`).join('');
  return `<text ${attrs({ x, y, fill: color, 'font-family': family, 'font-size': size, 'font-weight': weight, 'text-anchor': anchor })}>${spans}</text>`;
}

function circle(cx, cy, r, fill, stroke = 'none', sw = 0) {
  return `<circle ${attrs({ cx, cy, r, fill, stroke, 'stroke-width': sw })}/>`;
}

function bulletPanel(out, items, color = C.blue) {
  out.push(rect(84, 150, 1432, 118, '#FAFAFA', C.line, 4));
  items.slice(0, 3).forEach((item, i) => {
    const yy = 184 + i * 32;
    out.push(circle(112, yy - 7, 4.5, color));
    out.push(txt(132, yy, item, 20, C.text, 500));
  });
}

function diagramLabel(x, y, label, color = C.muted) {
  return txt(x, y, label, 15, color, 800, 'start', { 'letter-spacing': 1.1 });
}

function fifoIcon(x, y, w, h, label, color = C.blue, entries = 4) {
  const out = [rect(x, y, w, h, '#FFFFFF', C.line, 3)];
  const cellH = (h - 28) / entries;
  for (let i = 0; i < entries; i++) {
    out.push(rect(x + 12, y + 10 + i * cellH, w - 24, cellH - 5, i === 0 ? '#E8EFF5' : '#F7F7F7', color, 1, { 'stroke-width': 1 }));
  }
  out.push(txt(x + w / 2, y + h + 22, label, 16, C.text, 650, 'middle'));
  return out.join('');
}

function pipelineRegIcon(x, y, w, h, label = '') {
  const out = [rect(x, y, w, h, '#FFFFFF', C.blue, 2)];
  for (let i = 1; i < 4; i++) out.push(line(x, y + (h * i) / 4, x + w, y + (h * i) / 4, C.line, 1));
  out.push(line(x + w / 2, y, x + w / 2, y + h, C.line, 1));
  if (label) out.push(txt(x + w / 2, y + h + 18, label, 14, C.muted, 600, 'middle'));
  return out.join('');
}

function macArrayIcon(x, y, w, h, label = 'MAC array') {
  const out = [rect(x, y, w, h, '#FFFFFF', C.blue, 3)];
  const cols = 4, rows = 3, gx = 10, gy = 10;
  const cw = (w - gx * (cols + 1)) / cols;
  const ch = (h - gy * (rows + 1)) / rows;
  for (let r = 0; r < rows; r++) {
    for (let c = 0; c < cols; c++) {
      const cx = x + gx + c * (cw + gx);
      const cy = y + gy + r * (ch + gy);
      out.push(rect(cx, cy, cw, ch, '#EEF3F7', C.blue2, 1, { 'stroke-width': 1 }));
      out.push(txt(cx + cw / 2, cy + ch / 2 + 5, '×+', 14, C.blue, 700, 'middle'));
    }
  }
  out.push(txt(x + w / 2, y + h + 22, label, 16, C.text, 650, 'middle'));
  return out.join('');
}

function sramIcon(x, y, w, h, label = 'ACC SRAM', banks = 4) {
  const out = [];
  const gap = 8;
  const bw = (w - gap * (banks - 1)) / banks;
  for (let b = 0; b < banks; b++) {
    const bx = x + b * (bw + gap);
    out.push(rect(bx, y, bw, h, '#F7F7F7', C.green, 2));
    for (let r = 1; r < 5; r++) out.push(line(bx, y + (h * r) / 5, bx + bw, y + (h * r) / 5, C.line, 1));
    out.push(txt(bx + bw / 2, y - 8, `B${b}`, 12, C.green, 700, 'middle'));
  }
  out.push(txt(x + w / 2, y + h + 22, label, 16, C.text, 650, 'middle'));
  return out.join('');
}

function muxIcon(x, y, w, h, label = 'MUX') {
  const points = `${x},${y} ${x + w * 0.72},${y} ${x + w},${y + h / 2} ${x + w * 0.72},${y + h} ${x},${y + h}`;
  return [
    `<polygon ${attrs({ points, fill: '#FFFFFF', stroke: C.amber, 'stroke-width': 2 })}/>` ,
    txt(x + w * 0.48, y + h / 2 + 6, label, 14, C.amber, 750, 'middle'),
  ].join('');
}

function counterIcon(x, y, w, h, label = 'RD / WR state') {
  const out = [rect(x, y, w, h, '#FFF8EE', C.red, 3)];
  out.push(txt(x + 14, y + 27, label, 16, C.red, 750));
  const names = ['rd_cnt', 'wr_cnt', 'empty'];
  const step = (h - 42) / 3;
  const cellH = Math.max(11, Math.min(18, step - 5));
  names.forEach((n, i) => {
    const yy = y + 38 + i * step;
    out.push(txt(x + 14, yy + cellH, n, 12, C.muted, 600));
    for (let b = 0; b < 4; b++) out.push(rect(x + Math.min(92, w * 0.44) + b * 22, yy, 16, cellH, '#FFFFFF', C.red, 1));
  });
  return out.join('');
}

function operandRegIcon(x, y, w, h, label, color = C.cyan) {
  const out = [rect(x, y, w, h, '#FFFFFF', color, 2)];
  const rows = 3;
  for (let i = 0; i < rows; i++) {
    out.push(rect(x + 10, y + 9 + i * 20, w - 20, 14, i === 0 ? '#E8EFF5' : '#F7F7F7', color, 1, { 'stroke-width': 1 }));
  }
  out.push(txt(x + w / 2, y - 8, label, 12, color, 800, 'middle'));
  out.push(txt(x + w / 2, y + h + 18, 'bank + generation', 11, C.muted, 600, 'middle'));
  return out.join('');
}

function readyGateIcon(x, y, w, h, label = 'consumer ready', color = C.amber) {
  const left = x + w * 0.42;
  const d = `M ${x} ${y} L ${left} ${y} A ${w * 0.58} ${h / 2} 0 0 1 ${left} ${y + h} L ${x} ${y + h} Z`;
  return [
    `<path ${attrs({ d, fill: '#FFFFFF', stroke: color, 'stroke-width': 2 })}/>` ,
    txt(x + w * 0.43, y + h / 2 + 7, '&', 20, color, 800, 'middle'),
    txt(x + w / 2, y + h + 22, label, 14, C.text, 650, 'middle'),
  ].join('');
}

function creditIcon(x, y, w, h, count = 6) {
  const out = [rect(x, y, w, h, '#FFFFFF', C.green, 2)];
  const gap = 4;
  const cellW = (w - 18 - gap * (count - 1)) / count;
  for (let i = 0; i < count; i++) {
    out.push(rect(x + 9 + i * (cellW + gap), y + 12, cellW, h - 24, '#EFF3EF', C.green, 1, { 'stroke-width': 1 }));
  }
  out.push(txt(x + w / 2, y + h + 18, `${count} reserved slots`, 12, C.green, 700, 'middle'));
  return out.join('');
}

function operandStateIcon(x, y, w, h, label = 'Exact operand readiness') {
  const out = [rect(x, y, w, h, '#FFFFFF', C.line, 2)];
  const rowH = h / 3;
  ['W', 'S', 'Z'].forEach((name, i) => {
    const yy = y + i * rowH;
    if (i) out.push(line(x, yy, x + w, yy, C.line, 1));
    out.push(txt(x + 14, yy + rowH * 0.65, name, 12, C.cyan, 800));
    out.push(txt(x + 42, yy + rowH * 0.65, 'bank', 10, C.muted, 600));
    out.push(rect(x + 77, yy + 7, 20, Math.max(12, rowH - 14), '#E8EFF5', C.cyan, 1));
    out.push(txt(x + 112, yy + rowH * 0.65, 'gen', 10, C.muted, 600));
    out.push(rect(x + 138, yy + 7, w - 148, Math.max(12, rowH - 14), '#F7F7F7', C.cyan, 1));
  });
  out.push(txt(x + w / 2, y + h + 19, label, 13, C.text, 650, 'middle'));
  return out.join('');
}

function dataBus(x1, y1, x2, y2, color = C.blue, width = 8, dashed = false) {
  return arrow(x1, y1, x2, y2, color, width, dashed, true);
}

function fsmIcon(x, y, w, h, label = 'FSM', color = C.amber) {
  const out = [rect(x, y, w, h, '#FFFFFF', C.line, 3)];
  const states = [
    [x + w * 0.25, y + h * 0.38, 'I'],
    [x + w * 0.50, y + h * 0.25, 'M'],
    [x + w * 0.75, y + h * 0.38, 'C'],
    [x + w * 0.50, y + h * 0.63, 'D'],
  ];
  out.push(arrow(states[0][0] + 14, states[0][1] - 5, states[1][0] - 14, states[1][1] + 5, color, 1.5));
  out.push(arrow(states[1][0] + 14, states[1][1] + 5, states[2][0] - 14, states[2][1] - 5, color, 1.5));
  out.push(arrow(states[2][0] - 4, states[2][1] + 14, states[3][0] + 14, states[3][1] - 4, color, 1.5));
  out.push(arrow(states[3][0] - 14, states[3][1] - 4, states[0][0] + 4, states[0][1] + 14, color, 1.5));
  states.forEach(([cx, cy, s]) => {
    out.push(circle(cx, cy, 15, '#FFFFFF', color, 2));
    out.push(txt(cx, cy + 5, s, 12, color, 750, 'middle'));
  });
  out.push(txt(x + w / 2, y + h + 20, label, 16, C.text, 650, 'middle'));
  return out.join('');
}

function dmaIcon(x, y, w, h, label = 'DMA', color = C.cyan) {
  const out = [rect(x, y, w, h, '#FFFFFF', C.line, 3)];
  out.push(txt(x + 12, y + 22, 'cmd', 12, C.muted, 700));
  for (let i = 0; i < 3; i++) out.push(rect(x + 12 + i * 31, y + 30, 25, 24, '#EEF3F7', color, 1));
  out.push(txt(x + 12, y + 78, 'addr', 12, C.muted, 700));
  for (let i = 0; i < 4; i++) out.push(rect(x + 52 + i * 22, y + 62, 17, 20, '#FFFFFF', color, 1));
  for (let i = 0; i < 3; i++) out.push(line(x + w - 68, y + 28 + i * 24, x + w - 14, y + 28 + i * 24, color, 2));
  out.push(txt(x + w / 2, y + h + 20, label, 16, C.text, 650, 'middle'));
  return out.join('');
}

function tagTableIcon(x, y, w, h, label = 'Tag table', color = C.blue) {
  const out = [rect(x, y, w, h, '#FFFFFF', C.line, 3)];
  const cols = [0, 0.25, 0.62, 1];
  const rows = 5;
  for (let c = 1; c < cols.length - 1; c++) out.push(line(x + w * cols[c], y, x + w * cols[c], y + h, C.line, 1));
  for (let r = 1; r < rows; r++) out.push(line(x, y + (h * r) / rows, x + w, y + (h * r) / rows, C.line, 1));
  out.push(txt(x + w * 0.12, y + 18, 'tag', 11, color, 700, 'middle'));
  out.push(txt(x + w * 0.43, y + 18, 'addr / seq', 11, color, 700, 'middle'));
  out.push(txt(x + w * 0.81, y + 18, 'state', 11, color, 700, 'middle'));
  for (let r = 1; r < rows; r++) {
    out.push(txt(x + w * 0.12, y + (h * (r + 0.65)) / rows, String(r - 1), 11, C.muted, 600, 'middle'));
  }
  out.push(txt(x + w / 2, y + h + 20, label, 16, C.text, 650, 'middle'));
  return out.join('');
}

function arbiterIcon(x, y, w, h, label = 'Arbiter', color = C.amber, inputs = 4) {
  const out = [];
  const points = `${x + w * 0.2},${y} ${x + w},${y + h * 0.28} ${x + w},${y + h * 0.72} ${x + w * 0.2},${y + h} ${x},${y + h * 0.72} ${x},${y + h * 0.28}`;
  out.push(`<polygon ${attrs({ points, fill: '#FFFFFF', stroke: color, 'stroke-width': 2 })}/>`);
  for (let i = 0; i < inputs; i++) {
    const iy = y + 14 + i * ((h - 28) / Math.max(1, inputs - 1));
    out.push(line(x - 28, iy, x + 4, iy, color, 1.5));
  }
  out.push(txt(x + w * 0.5, y + h / 2 + 6, 'PRI', 14, color, 800, 'middle'));
  out.push(txt(x + w / 2, y + h + 20, label, 16, C.text, 650, 'middle'));
  return out.join('');
}

function addressGenIcon(x, y, w, h, label = 'Address generator', color = C.magenta) {
  const out = [rect(x, y, w, h, '#FFFFFF', C.line, 3)];
  ['row', 'col', 'stride'].forEach((name, i) => {
    out.push(txt(x + 10, y + 22 + i * 28, name, 11, C.muted, 650));
    out.push(rect(x + 62, y + 8 + i * 28, 50, 22, '#F7F7F7', color, 1));
  });
  out.push(circle(x + w - 35, y + h / 2, 20, '#FFFFFF', color, 2));
  out.push(txt(x + w - 35, y + h / 2 + 6, '+', 20, color, 750, 'middle'));
  out.push(txt(x + w / 2, y + h + 20, label, 16, C.text, 650, 'middle'));
  return out.join('');
}

function tokenIcon(x, y, fields, label = 'Control token', color = C.amber) {
  const out = [];
  let fx = x;
  fields.forEach((field) => {
    const fw = Math.max(34, field.length * 8 + 14);
    out.push(rect(fx, y, fw, 32, '#FFF8EE', color, 1, { 'stroke-width': 1 }));
    out.push(txt(fx + fw / 2, y + 22, field, 11, color, 700, 'middle'));
    fx += fw + 4;
  });
  out.push(txt((x + fx - 4) / 2, y + 54, label, 14, C.text, 650, 'middle'));
  return { svg: out.join(''), endX: fx - 4 };
}

function bulletList(x, y, items, opts = {}) {
  const size = opts.size || 23;
  const color = opts.color || C.text;
  const bullet = opts.bullet || C.blue;
  const gap = opts.gap || 56;
  const out = [];
  items.forEach((item, i) => {
    const yy = y + i * gap;
    out.push(circle(x, yy - 7, 5, bullet));
    if (Array.isArray(item)) out.push(lines(x + 20, yy, item, { size, color, lineHeight: size + 6 }));
    else out.push(txt(x + 20, yy, item, size, color, 400));
  });
  return out.join('');
}

function titleText(parts, x = 84, y = 172, size = 48) {
  const spans = parts.map((p) => `<tspan fill="${p.color || C.white}" font-weight="${p.weight || 700}">${esc(koText(p.text))}</tspan>`).join('');
  return `<text x="${x}" y="${y}" font-family="Noto Sans CJK KR, Malgun Gothic, Aptos Display, Aptos, Arial, sans-serif" font-size="${size}" letter-spacing="-0.7">${spans}</text>`;
}

function base(slideNo, section, title, subtitle = '') {
  const sec = typeof section === 'string' ? sections[section] : section;
  const out = [
    `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`,
    `<defs>
      <marker id="arrow" markerWidth="11" markerHeight="11" refX="9" refY="5.5" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L10,5.5 L0,11 Z" fill="context-stroke"/></marker>
    </defs>`,
    `<rect width="${W}" height="${H}" fill="${C.bg}"/>`,
    `<rect x="0" y="0" width="6" height="${H}" fill="${sec.color}"/>`,
    txt(84, 48, sec.label, 15, sec.color, 800, 'start', { 'letter-spacing': 1.8 }),
    txt(1516, 48, String(slideNo).padStart(2, '0'), 16, C.muted, 700, 'end', { 'letter-spacing': 1.2 }),
    txt(84, 108, title, 38, C.white, 750, 'start', { 'letter-spacing': -0.4 }),
  ];
  out.push(line(84, 132, 1516, 132, C.line, 2));
  return out;
}

function footer(out, slideNo, accent, source = '') {
  out.push(line(84, 846, 1516, 846, C.line, 1.5));
  out.push(txt(84, 874, 'VORTEX · GEMV RTL ARCHITECTURE', 14, C.muted, 650, 'start', { 'letter-spacing': 1.1 }));
  if (source) out.push(txt(1516, 874, source, 13, C.muted, 400, 'end'));
  out.push('</svg>');
  return out.join('');
}

function lane(y, label, color = C.blue) {
  return [txt(90, y + 24, label, 17, C.muted, 700), line(260, y + 18, 1480, y + 18, C.line, 2)].join('');
}

function laneAt(y, label, labelX, lineX1, lineX2) {
  return [txt(labelX, y + 24, label, 17, C.muted, 700), line(lineX1, y + 18, lineX2, y + 18, C.line, 2)].join('');
}

function segment(x, y, w, label, color, h = 38, opts = {}) {
  return [
    rect(x, y, w, h, opts.fill || color, opts.stroke || color, opts.r || 9, { opacity: opts.opacity || 1 }),
    txt(x + w / 2, y + h / 2 + 7, label, opts.size || 16, opts.textColor || C.bg, 750, 'middle'),
  ].join('');
}

function closeSimple(out) {
  out.push('</svg>');
  return out.join('');
}

const slides = [];

// P1
slides.push({
  section: 'compare',
  title: 'GEMV RTL Architecture Evolution',
  notes: 'Scope: RTL changes from the fpint baseline to feat/gemv. Narrative: bottleneck → architectural solution → resulting hardware. Main body: IMPROVE first, then NAIVE; shared modules in the appendix.',
  render() {
    const out = [
      `<svg xmlns="http://www.w3.org/2000/svg" width="${W}" height="${H}" viewBox="0 0 ${W} ${H}">`,
      `<defs><marker id="arrow" markerWidth="11" markerHeight="11" refX="9" refY="5.5" orient="auto" markerUnits="strokeWidth"><path d="M0,0 L10,5.5 L0,11 Z" fill="context-stroke"/></marker></defs>`,
      `<rect width="${W}" height="${H}" fill="${C.bg}"/>`,
      `<rect x="0" y="0" width="6" height="${H}" fill="${C.blue}"/>`,
      txt(86, 86, 'VORTEX · RTL ARCHITECTURE REVIEW', 18, C.muted, 700, 'start', { 'letter-spacing': 1.2 }),
      txt(86, 242, 'GEMV RTL Architecture', 64, C.white, 750),
      txt(86, 320, 'Evolution', 64, C.white, 750),
      txt(90, 380, 'fpint baseline → feat/gemv', 26, C.blue, 650),
      line(90, 430, 760, 430, C.line, 2),
      lines(90, 484, ['Bottleneck', 'Architectural solution', 'Resulting hardware'], { size: 27, color: C.text, lineHeight: 52 }),
      rect(930, 235, 470, 250, C.panel, C.line, 6),
      txt(970, 286, 'PRESENTATION ORDER', 17, C.muted, 750, 'start', { 'letter-spacing': 1.1 }),
      txt(970, 350, '1. IMPROVE', 30, C.blue, 750),
      txt(970, 405, '2. NAIVE', 30, C.magenta, 750),
      txt(970, 460, '3. Comparison + evidence', 24, C.text, 600),
      rect(930, 535, 470, 118, C.panel, C.line, 6),
      txt(970, 580, 'IMPROVE', 22, C.blue, 750),
      txt(1120, 580, 'TMEM · tile-major', 22, C.text, 500),
      txt(970, 625, 'NAIVE', 22, C.magenta, 750),
      txt(1120, 625, 'LMEM · row-major', 22, C.text, 500),
      txt(90, 782, 'August 2026', 20, C.muted, 500),
      line(90, 824, 1510, 824, C.line, 2),
      txt(90, 858, 'VORTEX', 16, C.white, 800, 'start', { 'letter-spacing': 2 }),
      txt(1510, 858, '01 / 18', 16, C.muted, 600, 'end'),
      '</svg>',
    ];
    return out.join('');
  },
});

// P2
slides.push({
  section: 'baseline',
  title: 'IMPROVE Baseline: Tile-Major GEMM on TMEM',
  notes: 'High-level presentation boundary only: command progress, operand movement, compute/ACC, and output drain. Source modules: hw/rtl/core/gemm/VX_gemm_node.sv and the original IMPROVE path.',
  render() {
    const out = base(2, 'baseline', this.title, 'The starting point: one tile-major node, four responsibility zones.');
    bulletPanel(out, [
      'Original IMPROVE executes tile-major GEMM from TMEM.',
      'The node contains command control, operand DMA, compute/ACC, and output drain.',
      'This baseline exposes the boundaries optimized in later slides.',
    ], C.amber);
    out.push(diagramLabel(100, 304, 'HARDWARE BLOCK DIAGRAM'));
    out.push(fsmIcon(100, 330, 160, 115, 'Controller FSM', C.amber));
    out.push(dataBus(260, 388, 310, 388, C.amber, 2, true));
    out.push(dmaIcon(310, 330, 160, 105, 'Operand DMA', C.cyan));
    out.push(dataBus(470, 388, 520, 388, C.cyan, 3));
    out.push(sramIcon(520, 330, 160, 110, 'TMEM banks', 4));
    out.push(dataBus(680, 388, 750, 388, C.blue, 3));
    out.push(macArrayIcon(750, 320, 180, 125, 'GEMM array'));
    out.push(dataBus(930, 388, 1000, 388, C.blue, 3));
    out.push(sramIcon(1000, 330, 150, 110, 'ACC banks', 4));
    out.push(dataBus(1150, 388, 1210, 388, C.green, 3));
    out.push(dmaIcon(1210, 330, 180, 105, 'Output DMA', C.green));
    out.push(line(180, 445, 180, 480, C.amber, 1.5));
    out.push(line(180, 480, 1300, 480, C.amber, 1.5, { 'stroke-dasharray': '6 5' }));
    [390, 840, 1300].forEach((cx) => out.push(arrow(cx, 480, cx, 435, C.amber, 1.5, true)));
    out.push(txt(740, 510, 'controller phase enable / completion feedback', 13, C.amber, 700, 'middle'));
    out.push(diagramLabel(100, 548, 'BASELINE TIMING'));
    out.push(laneAt(580, 'Node', 100, 240, 1460));
    out.push(segment(260, 581, 230, 'ISSUE', C.amber, 42));
    out.push(segment(490, 581, 270, 'MOVE OPERANDS', C.cyan, 42));
    out.push(segment(760, 581, 370, 'COMPUTE + ACC', C.blue, 42));
    out.push(segment(1130, 581, 290, 'OUTPUT DRAIN', C.green, 42));
    out.push(txt(840, 680, 'Mostly sequential command phases', 22, C.muted, 600, 'middle'));
    return footer(out, 2, C.amber, 'Scope boundary for the IMPROVE story');
  },
});

// P3
slides.push({
  section: 'baseline',
  title: 'Why the Original Structure Left Throughput on the Table',
  notes: 'ACC read/write counts were managed centrally across microtiles. Variable Input→ACC-memory latency propagated through shared counters and broad pipeline-empty restrictions. Measurement context: docs/hw_analysis/gemm_improve/gemv_analysis.md reports ~25 compute cycles followed by ~14 command/synchronization/preload cycles in the analyzed run.',
  render() {
    const out = base(3, 'baseline', this.title, 'A latency variation in one microtile became everyone else’s problem.');
    bulletPanel(out, [
      'ACC read/write progress was tracked across microtiles by shared counters.',
      'Variable latency in an earlier microtile blocked later independent work.',
      'Output drain also waited on a broad global pipeline-empty condition.',
    ], C.amber);
    out.push(diagramLabel(100, 304, 'TIMING DIAGRAM · LATENCY PROPAGATES THROUGH SHARED STATE'));
    [338, 430, 522, 614].forEach((y, i) => out.push(laneAt(y, ['Microtile 0', 'Shared ACC', 'Microtile 1', 'Output'][i], 100, 270, 1460)));
    out.push(segment(300, 339, 280, 'compute M0', C.blue, 38));
    out.push(segment(580, 339, 170, 'late ACC', C.orange, 38));
    out.push(segment(750, 339, 120, 'WB', C.blue, 38));
    out.push(segment(420, 431, 360, 'shared read / write counters', C.amber, 38));
    out.push(segment(750, 523, 260, 'M1 blocked', C.red, 38));
    out.push(segment(1010, 523, 300, 'compute M1', C.magenta, 38));
    out.push(segment(750, 615, 560, 'wait for pipeline_empty', C.line, 38, { textColor: C.text }));
    out.push(line(750, 320, 750, 680, C.red, 2, { 'stroke-dasharray': '8 7' }));
    out.push(txt(750, 720, 'bubble begins here', 18, C.red, 700, 'middle'));
    out.push(txt(1310, 720, '~25 compute cycles + ~14-cycle gap', 18, C.muted, 600, 'end'));
    return footer(out, 3, C.amber, 'Measured run: improve_th32 GEMV analysis');
  },
});

// P4
slides.push({
  section: 'improve',
  title: 'Solution 1: Carry ACC Control with the Datapath',
  notes: 'Before: centralized ACC read/write counters and pipeline-empty state interpreted progress across microtiles. After: accepted packets carry ACC address, read/write intent, work sequence, exact generations, and final markers through the same pipeline registers as data. The aligned request reaches the local ACC backend, where forwarding and physical bank access are resolved. Source: hw/rtl/core/gemm/VX_gemm_unit_v2.sv, VX_gemm_compute_core.sv, and VX_gemm_acc_internal.sv.',
  render() {
    const out = base(4, 'improve', this.title);
    bulletPanel(out, [
      'Before: one central ACC RD/WR tracker controlled progress across the whole pipeline.',
      'Change: ACC address, R/W intent, work_seq, generations, and last travel with each packet.',
      'After: data and control cross the same registers and arrive aligned at the local ACC backend.',
    ], C.blue);
    out.push(diagramLabel(92, 296, 'BEFORE · CENTRALIZED ACC RD / WR CONTROL', C.red));
    out.push(diagramLabel(650, 296, 'AFTER · CONTROL TOKEN PIPELINED WITH DATA', C.blue));
    out.push(line(605, 302, 605, 806, C.line, 2));

    // BEFORE: centralized state fans out to otherwise separate datapath components.
    out.push(counterIcon(190, 328, 270, 145, 'Central ACC RD / WR'));
    out.push(fifoIcon(98, 548, 105, 120, 'Input FIFO', C.cyan));
    out.push(macArrayIcon(250, 535, 190, 135, 'MAC array'));
    out.push(sramIcon(486, 540, 92, 130, 'ACC SRAM', 2));
    out.push(dataBus(203, 608, 250, 608, C.blue, 3));
    out.push(dataBus(440, 608, 486, 608, C.blue, 3));
    out.push(line(325, 473, 150, 548, C.red, 3));
    out.push(line(325, 473, 345, 535, C.red, 3));
    out.push(line(325, 473, 532, 540, C.red, 3));
    out.push(txt(120, 505, 'global enable', 13, C.red, 700));
    out.push(txt(344, 512, 'rd / wr count', 13, C.red, 700, 'middle'));
    out.push(txt(530, 515, 'pipeline_empty', 13, C.red, 700, 'middle'));
    out.push(line(105, 724, 568, 724, C.red, 6));
    out.push(txt(336, 754, 'one late transaction blocks the shared state', 16, C.red, 700, 'middle'));
    out.push(txt(336, 785, 'Control is inferred centrally, not attached to the packet.', 15, C.muted, 500, 'middle'));

    // AFTER: a paper-style datapath with parallel data and control pipelines.
    out.push(txt(650, 329, 'DATA', 13, C.blue, 800));
    out.push(fifoIcon(650, 365, 78, 105, 'packet', C.cyan));
    out.push(dataBus(728, 417, 755, 417, C.blue, 3));
    out.push(circle(785, 417, 28, '#FFFFFF', C.cyan, 2));
    out.push(txt(785, 424, '×', 24, C.cyan, 750, 'middle'));
    out.push(txt(785, 466, 'scale', 14, C.muted, 600, 'middle'));
    out.push(dataBus(813, 417, 835, 417, C.blue, 3));
    out.push(pipelineRegIcon(835, 356, 38, 122, 'R0'));
    out.push(dataBus(873, 417, 900, 417, C.blue, 3));
    out.push(macArrayIcon(900, 344, 178, 145, 'GEMM tree'));
    out.push(dataBus(1078, 417, 1100, 417, C.blue, 3));
    out.push(pipelineRegIcon(1100, 356, 38, 122, 'R1'));
    out.push(dataBus(1138, 417, 1162, 417, C.blue, 3));
    out.push(muxIcon(1162, 380, 78, 74, 'post'));
    out.push(dataBus(1240, 417, 1262, 417, C.blue, 3));
    out.push(pipelineRegIcon(1262, 356, 38, 122, 'R2'));
    out.push(dataBus(1300, 417, 1335, 417, C.blue, 3));
    out.push(muxIcon(1335, 382, 66, 70, 'RAW'));
    out.push(dataBus(1401, 417, 1420, 417, C.green, 3));
    out.push(sramIcon(1420, 352, 90, 130, 'ACC banks', 2));
    out.push(arrow(1420, 474, 1370, 474, C.green, 2, true));
    out.push(txt(1396, 497, 'read rsp', 12, C.green, 650, 'middle'));

    out.push(txt(650, 532, 'CONTROL TOKEN', 13, C.amber, 800));
    const fields = [['addr', 34], ['R/W', 30], ['seq', 28], ['gen', 28], ['last', 28]];
    let fx = 650;
    fields.forEach(([label, fw]) => {
      out.push(rect(fx, 550, fw, 34, '#FFF8EE', C.amber, 1, { 'stroke-width': 1 }));
      out.push(txt(fx + fw / 2, 572, label, 11, C.amber, 700, 'middle'));
      fx += fw + 4;
    });
    out.push(dataBus(fx + 2, 567, 835, 567, C.amber, 2, true));
    out.push(pipelineRegIcon(835, 532, 38, 70, 'C0'));
    out.push(dataBus(873, 567, 1100, 567, C.amber, 2, true));
    out.push(pipelineRegIcon(1100, 532, 38, 70, 'C1'));
    out.push(dataBus(1138, 567, 1262, 567, C.amber, 2, true));
    out.push(pipelineRegIcon(1262, 532, 38, 70, 'C2'));
    out.push(dataBus(1300, 567, 1365, 567, C.amber, 2, true));
    out.push(line(1365, 567, 1365, 454, C.amber, 2, { 'stroke-dasharray': '7 6' }));
    out.push(txt(1380, 548, 'aligned ACC request', 14, C.amber, 700));

    out.push(diagramLabel(650, 654, 'PIPELINE ALIGNMENT'));
    out.push(laneAt(680, 'Data', 650, 760, 1498));
    out.push(laneAt(736, 'Control', 650, 760, 1498));
    ['R0', 'R1', 'R2', 'ACC'].forEach((v, i) => {
      const sx = 790 + i * 165;
      out.push(segment(sx, 681, 120, v, i === 3 ? C.green : C.blue, 28, { size: 13 }));
      out.push(segment(sx, 737, 120, v, i === 3 ? C.green : C.amber, 28, { size: 13 }));
    });
    out.push(txt(1120, 802, 'same register boundaries → same stall / advance decision', 16, C.blue, 700, 'middle'));
    return footer(out, 4, C.blue, 'RTL: VX_gemm_unit_v2 / compute_core / acc_internal');
  },
});

// P5
slides.push({
  section: 'improve',
  title: 'Solution 2: Hide Operand-Ready Latency with Local Backpressure',
  notes: 'Before backpressure-ready flow control, Input admission checked Weight, Scale, and Zero-point readiness before entering the GEMM unit. The GEMM-unit-to-tree latency therefore remained visible and kept the next operand load from reusing a live bank. The implementation partitions VX_gemm_compute_core into elastic pre-process and post-process regions around a fixed-latency GEMM-tree/correction island. Exact W/S/Z bank and generation readiness is checked at each real consumer. A depth-six merged-result FIFO and registered credit return cover the five-cycle tree plus one-cycle feedback without a combinational ready path through the MXU. Sources: agent-tasks/gemm-unit-backpressure-opt/gemm-unit-backpressure-opt-spec.md, docs/future_optim/gemv/gemm_improve/gemm_unit_backpressure_opt.md, and hw/rtl/core/gemm/VX_gemm_compute_core.sv.',
  render() {
    const out = base(5, 'improve', this.title);
    bulletPanel(out, [
      'Before ready, Input waited for W/S/Z before entering the GEMM unit, exposing pre-to-tree latency.',
      'Now Input advances early; exact bank + generation readiness is checked at the actual consumer.',
      'Pre/Post are elastic; the fixed MXU is protected by a depth-6 result FIFO and registered credits.',
    ], C.blue);

    out.push(diagramLabel(92, 304, 'BEFORE · READY CHECKED BEFORE INPUT ISSUE', C.red));
    out.push(diagramLabel(690, 304, 'AFTER · READY CHECKED AT THE CONSUMER', C.blue));
    out.push(line(660, 310, 660, 574, C.line, 2));

    // Before: operand readiness gates admission, so the frontend latency cannot hide a later load.
    out.push(fifoIcon(88, 350, 78, 92, 'Input Q', C.cyan));
    out.push(dataBus(166, 396, 220, 396, C.blue, 2));
    out.push(readyGateIcon(220, 362, 78, 68, 'entry W/S/Z gate', C.red));
    out.push(dataBus(298, 396, 338, 396, C.blue, 2));
    [338, 397, 456].forEach((x, i) => out.push(pipelineRegIcon(x, 345, 34, 102, `L${i}`)));
    out.push(line(372, 396, 397, 396, C.blue, 2));
    out.push(line(431, 396, 456, 396, C.blue, 2));
    out.push(dataBus(490, 396, 520, 396, C.blue, 2));
    out.push(macArrayIcon(520, 340, 118, 112, 'GEMM tree'));
    out.push(operandStateIcon(92, 478, 188, 68, 'W/S/Z must all be ready'));
    out.push(arrow(236, 478, 250, 430, C.red, 1.8, true));
    out.push(line(332, 470, 490, 470, C.red, 2, { 'stroke-dasharray': '6 5' }));
    out.push(line(332, 458, 332, 470, C.red, 2));
    out.push(line(490, 458, 490, 470, C.red, 2));
    out.push(txt(411, 497, 'visible frontend latency', 13, C.red, 750, 'middle'));
    out.push(arrow(580, 452, 280, 528, C.red, 1.5, true));
    out.push(txt(474, 548, 'live bank blocks the next load', 13, C.red, 700, 'middle'));

    // After: elastic regions surround a non-stallable fixed-latency island.
    out.push(fifoIcon(690, 350, 62, 92, 'Input', C.cyan));
    out.push(dataBus(752, 396, 775, 396, C.blue, 2));
    out.push(circle(798, 396, 23, '#FFFFFF', C.cyan, 2));
    out.push(txt(798, 403, '×', 20, C.cyan, 750, 'middle'));
    out.push(txt(798, 451, 'QROW S', 12, C.muted, 700, 'middle'));
    out.push(dataBus(821, 396, 838, 396, C.blue, 2));
    out.push(pipelineRegIcon(838, 347, 32, 100, 'P0'));
    out.push(line(870, 396, 884, 396, C.blue, 2));
    out.push(pipelineRegIcon(884, 347, 32, 100, 'P1'));
    out.push(dataBus(916, 396, 938, 396, C.blue, 2));
    out.push(readyGateIcon(938, 362, 78, 68, 'W/Z consume', C.amber));
    out.push(dataBus(1016, 396, 1040, 396, C.blue, 2));
    out.push(macArrayIcon(1040, 340, 118, 112, 'MXU · L=5'));
    out.push(dataBus(1158, 396, 1182, 396, C.blue, 2));
    out.push(fifoIcon(1182, 340, 88, 112, 'FIFO [6]', C.green, 6));
    out.push(dataBus(1270, 396, 1297, 396, C.green, 2));
    out.push(circle(1320, 396, 23, '#FFFFFF', C.green, 2));
    out.push(txt(1320, 403, '×', 20, C.green, 750, 'middle'));
    out.push(txt(1320, 451, 'QCOL S', 12, C.muted, 700, 'middle'));
    out.push(dataBus(1343, 396, 1360, 396, C.green, 2));
    out.push(pipelineRegIcon(1360, 347, 32, 100, 'post'));
    out.push(dataBus(1392, 396, 1418, 396, C.green, 2));
    out.push(sramIcon(1418, 342, 92, 110, 'ACC banks', 2));

    out.push(arrow(938, 332, 718, 332, C.green, 1.5, true));
    out.push(txt(828, 324, 'elastic PRE ready', 12, C.green, 750, 'middle'));
    out.push(arrow(1470, 332, 1212, 332, C.green, 1.5, true));
    out.push(txt(1340, 324, 'elastic POST ready', 12, C.green, 750, 'middle'));

    out.push(operandStateIcon(735, 490, 220, 66, 'bank + exact LOAD generation'));
    out.push(arrow(780, 490, 798, 419, C.cyan, 1.5, true));
    out.push(arrow(905, 490, 970, 430, C.cyan, 1.5, true));
    out.push(line(955, 536, 1320, 570, C.cyan, 1.5, { 'stroke-dasharray': '6 5' }));
    out.push(arrow(1320, 570, 1320, 419, C.cyan, 1.5, true));
    out.push(creditIcon(1065, 494, 176, 48, 6));
    out.push(line(1226, 452, 1226, 494, C.green, 1.5));
    out.push(arrow(1065, 518, 985, 430, C.green, 1.5, true));
    out.push(txt(1146, 592, 'FIFO pop → registered credit return', 12, C.green, 700, 'middle'));

    out.push(diagramLabel(92, 616, 'TIMING · FRONTEND LATENCY MOVES INSIDE THE OVERLAP WINDOW'));
    [646, 696, 746, 796].forEach((y, i) => out.push(laneAt(y, [
      'Before · Input',
      'Before · next W/S/Z',
      'After · Input',
      'After · next W/S/Z',
    ][i], 92, 310, 1510)));
    out.push(segment(330, 647, 180, 'wait ready', C.red, 30));
    out.push(segment(510, 647, 210, 'frontend latency', C.amber, 30));
    out.push(segment(720, 647, 130, 'consume', C.blue, 30));
    out.push(segment(330, 697, 390, 'bank live / load blocked', C.line, 30, { textColor: C.text }));
    out.push(segment(720, 697, 190, 'next load', C.cyan, 30));
    out.push(segment(330, 747, 250, 'issue early + PRE', C.blue, 30));
    out.push(segment(580, 747, 120, 'check', C.amber, 30));
    out.push(segment(700, 747, 150, 'consume', C.blue, 30));
    out.push(segment(380, 797, 200, 'load overlaps PRE', C.cyan, 30));
    out.push(segment(580, 797, 120, 'ready', C.green, 30));
    out.push(line(580, 728, 580, 827, C.amber, 2, { 'stroke-dasharray': '7 6' }));
    return footer(out, 5, C.blue, 'Elastic PRE/POST · fixed MXU · depth-6 credit protection');
  },
});

// P6
slides.push({
  section: 'improve',
  title: 'Solution 3: Make ACC Hazards Local and Pipeline-Safe',
  notes: 'Replace central count dependency tracking with transaction- and microtile-local state. Schedule reads early, forward short RAW dependencies, and use local credits, ownership, and backpressure. Sources: gemm-unit-v2 specs and forwarding specs under agent-tasks/gemv-gemm-unit-v2*.',
  render() {
    const out = base(6, 'improve', this.title, 'Track the dependency where it lives—and forward the value when SRAM is stale.');
    bulletPanel(out, [
      'ACC hazards are tracked per transaction and microtile instead of globally.',
      'Reads are scheduled early; a short RAW dependency forwards the newest writeback.',
      'Credits and bank ownership backpressure only the affected flow.',
    ], C.blue);
    out.push(diagramLabel(100, 304, 'HARDWARE BLOCK DIAGRAM'));
    out.push(tagTableIcon(100, 330, 210, 115, 'Local request tracker', C.blue));
    out.push(dataBus(310, 388, 360, 388, C.blue, 2, true));
    out.push(fifoIcon(360, 330, 92, 105, 'Read queue', C.cyan));
    out.push(dataBus(452, 388, 510, 388, C.cyan, 3));
    out.push(sramIcon(510, 330, 150, 110, 'ACC banks', 4));
    out.push(arrow(660, 388, 730, 388, C.green, 2, true));
    out.push(muxIcon(730, 350, 90, 76, 'RAW'));
    out.push(dataBus(820, 388, 890, 388, C.blue, 3));
    out.push(macArrayIcon(890, 320, 180, 125, 'Compute array'));
    out.push(dataBus(1070, 388, 1140, 388, C.green, 3));
    out.push(fifoIcon(1140, 330, 100, 105, 'Writeback Q', C.green));
    out.push(arrow(1190, 330, 790, 330, C.green, 2, true));
    out.push(txt(990, 318, 'forward newest writeback', 13, C.green, 700, 'middle'));
    out.push(tagTableIcon(1280, 330, 190, 110, 'Credit / bank owner', C.red));
    out.push(line(1280, 388, 1240, 388, C.red, 2, { 'stroke-dasharray': '6 5' }));
    out.push(diagramLabel(100, 532, 'TIMING DIAGRAM · SHORT RAW FORWARDING'));
    [562, 632, 702].forEach((y, i) => out.push(laneAt(y, ['ACC read', 'SRAM response', 'Writeback / forward'][i], 100, 300, 1460)));
    out.push(segment(340, 563, 180, 'read A', C.blue, 34));
    out.push(segment(760, 633, 210, 'stale SRAM A', C.line, 34, { textColor: C.text }));
    out.push(segment(560, 703, 240, 'new A writeback', C.green, 34));
    out.push(arrow(800, 720, 920, 650, C.green, 3, true));
    out.push(segment(970, 703, 230, 'forward new A', C.amber, 34));
    out.push(txt(1220, 728, 'No global wait', 18, C.green, 700));
    return footer(out, 6, C.blue, 'Local state replaces central ACC dependency counts');
  },
});

// P7
slides.push({
  section: 'improve',
  title: 'Solution 4: Overlap Compute and Output with ACC Double Buffering',
  notes: 'Physical ACC banks are divided into two execution groups. Drain one group while computing in the other. Output reads are gated on same-group conflicts rather than global pipeline_empty. Sources: docs/future_optim/gemv/gemm_improve/done/output_double_buf.md and gemm_unit_backpressure_opt.md.',
  render() {
    const out = base(7, 'improve', this.title, 'Two bank groups turn output drain from a global barrier into a local conflict check.');
    bulletPanel(out, [
      'The four physical ACC banks are divided into execution groups A and B.',
      'Compute uses one group while output drain reads the other group.',
      'Output stalls only on a conflict with the same group, not on global pipeline_empty.',
    ], C.blue);
    out.push(diagramLabel(100, 304, 'HARDWARE BLOCK DIAGRAM'));
    out.push(macArrayIcon(100, 325, 180, 120, 'Compute array'));
    out.push(dataBus(280, 385, 350, 385, C.blue, 3));
    out.push(circle(380, 385, 26, '#FFFFFF', C.blue, 2));
    out.push(txt(380, 391, 'G', 16, C.blue, 800, 'middle'));
    out.push(txt(380, 435, 'group select', 13, C.muted, 600, 'middle'));
    out.push(arrow(406, 375, 500, 350, C.blue, 2));
    out.push(arrow(406, 395, 500, 420, C.blue, 2));
    out.push(sramIcon(500, 310, 190, 105, 'ACC Group A · banks 0–1', 2));
    out.push(sramIcon(500, 420, 190, 105, 'ACC Group B · banks 2–3', 2));
    out.push(arrow(690, 360, 790, 385, C.green, 2));
    out.push(arrow(690, 470, 790, 405, C.green, 2));
    out.push(muxIcon(790, 360, 100, 80, 'drain'));
    out.push(dataBus(890, 400, 970, 400, C.green, 3));
    out.push(fifoIcon(970, 345, 110, 105, 'Output FIFO', C.green));
    out.push(dataBus(1080, 400, 1160, 400, C.green, 3));
    out.push(dmaIcon(1160, 345, 190, 100, 'Output DMA', C.green));
    out.push(tagTableIcon(1370, 345, 110, 100, 'Group owner', C.blue));
    out.push(diagramLabel(100, 566, 'TIMING DIAGRAM'));
    [596, 656, 716].forEach((y, i) => out.push(laneAt(y, ['Group A', 'Group B', 'Output'][i], 100, 260, 1460)));
    out.push(segment(290, 597, 330, 'compute A', C.blue, 32));
    out.push(segment(650, 597, 330, 'drain A', C.green, 32));
    out.push(segment(1010, 597, 330, 'compute A', C.blue, 32));
    out.push(segment(290, 657, 330, 'drain B', C.green, 32));
    out.push(segment(650, 657, 330, 'compute B', C.cyan, 32));
    out.push(segment(1010, 657, 330, 'drain B', C.green, 32));
    out.push(segment(290, 717, 330, 'read B', C.green, 32));
    out.push(segment(650, 717, 330, 'read A', C.green, 32));
    out.push(segment(1010, 717, 330, 'read B', C.green, 32));
    return footer(out, 7, C.blue, 'Two execution groups · local conflict gating');
  },
});

// P8
slides.push({
  section: 'improve',
  title: 'Solution 5: Remove WAIT / NOTIFY from the FSM',
  notes: 'Separate synchronization opcodes serialized checks and signaling. Writer-wait, completion-notify, generation, and work-sequence metadata are embedded in DMA and compute commands. Each execution block checks its own dependencies and reports completion. Source: docs/future_optim/gemv/gemm_improve/done/command_schedule_opt.md.',
  render() {
    const out = base(8, 'improve', this.title, 'Move dependency semantics into work commands so ready work can keep issuing.');
    bulletPanel(out, [
      'Standalone WAIT and NOTIFY opcodes are removed from the FSM command stream.',
      'DMA and compute commands carry writer-wait, notify, generation, and work_seq metadata.',
      'Each execution block checks dependencies locally, so ready commands keep issuing.',
    ], C.blue);
    out.push(diagramLabel(100, 304, 'COMMAND TIMING · BEFORE'));
    out.push(laneAt(334, 'FSM', 100, 240, 1460));
    const old = [['WAIT', C.red, 170], ['DMA', C.cyan, 190], ['NOTIFY', C.amber, 190], ['WAIT', C.red, 170], ['COMPUTE', C.blue, 250], ['NOTIFY', C.amber, 190]];
    let xx = 270;
    old.forEach(([l, c, w]) => { out.push(segment(xx, 335, w, l, c, 38)); xx += w; });
    out.push(diagramLabel(100, 454, 'COMMAND TIMING · AFTER'));
    out.push(laneAt(484, 'FSM', 100, 240, 1460));
    out.push(segment(270, 485, 330, 'DMA cmd + dependency metadata', C.cyan, 38));
    out.push(segment(600, 485, 380, 'COMPUTE cmd + generation / work_seq', C.blue, 38));
    out.push(segment(980, 485, 330, 'DMA N+1 + metadata', C.cyan, 38));
    out.push(diagramLabel(100, 604, 'HARDWARE BLOCK DIAGRAM'));
    out.push(fifoIcon(120, 630, 86, 90, 'Command FIFO', C.blue));
    out.push(dataBus(206, 675, 270, 675, C.blue, 2));
    out.push(fsmIcon(270, 625, 150, 95, 'Issue FSM', C.blue));
    out.push(dataBus(420, 675, 490, 675, C.blue, 2));
    out.push(dmaIcon(490, 625, 150, 90, 'DMA executor', C.cyan));
    out.push(macArrayIcon(700, 620, 150, 100, 'Compute executor'));
    out.push(line(420, 675, 700, 675, C.blue, 2));
    out.push(arrow(640, 675, 920, 675, C.green, 2, true));
    out.push(arrow(850, 675, 920, 675, C.green, 2, true));
    out.push(tagTableIcon(920, 625, 200, 90, 'Inflight completion tags', C.green));
    out.push(dataBus(1120, 675, 1190, 675, C.green, 2));
    out.push(counterIcon(1190, 620, 240, 105, 'Notify / generation'));
    return footer(out, 8, C.blue, 'No standalone WAIT / NOTIFY / CLEAR opcodes');
  },
});

// P9
slides.push({
  section: 'improve',
  title: 'Solution 6: Overlap DMA Work Across Commands',
  notes: 'Add tagged multi-command HBM DMA queues and aligned look-ahead chaining. Split the shared qparam Local DMA into independent Scale and ZP engines with resource-specific fences, bounded queues, and exact generations. Source: docs/future_optim/gemv/gemm_improve/done/multi_cmd_dma.md and related DMA optimization plans.',
  render() {
    const out = base(9, 'improve', this.title, 'Tag the work, split the qparam engines, and start command N+1 before N retires.');
    bulletPanel(out, [
      'Tagged HBM DMA queues allow command N+1 to start before command N retires.',
      'Scale and Zero-point use independent Local DMA engines.',
      'Destination writes and retirement remain ordered at the final actual write.',
    ], C.blue);
    out.push(diagramLabel(100, 304, 'TIMING DIAGRAM · BEFORE'));
    [334, 394, 454].forEach((y, i) => out.push(laneAt(y, ['HBM DMA', 'QPARAM DMA', 'Compute'][i], 100, 270, 1460)));
    out.push(segment(310, 335, 280, 'N load', C.cyan, 32));
    out.push(segment(590, 335, 200, 'wait retire', C.line, 32, { textColor: C.text }));
    out.push(segment(790, 335, 280, 'N+1 load', C.cyan, 32));
    out.push(segment(310, 395, 280, 'Scale then ZP', C.amber, 32));
    out.push(segment(410, 455, 360, 'compute N', C.blue, 32));
    out.push(diagramLabel(100, 536, 'TIMING DIAGRAM · AFTER'));
    [566, 626, 686, 746].forEach((y, i) => out.push(laneAt(y, ['HBM DMA', 'Scale LDMA', 'ZP LDMA', 'Compute'][i], 100, 270, 1460)));
    out.push(segment(310, 567, 360, 'N', C.cyan, 32));
    out.push(segment(610, 567, 420, 'N+1 look-ahead', C.cyan, 32));
    out.push(segment(350, 627, 300, 'Scale N', C.green, 32));
    out.push(segment(700, 627, 300, 'Scale N+1', C.green, 32));
    out.push(segment(420, 687, 300, 'ZP N', C.magenta, 32));
    out.push(segment(770, 687, 300, 'ZP N+1', C.magenta, 32));
    out.push(segment(520, 747, 370, 'compute N', C.blue, 32));
    out.push(segment(850, 747, 370, 'compute N+1', C.blue, 32));
    return footer(out, 9, C.blue, 'HBM multi-command queue · Scale/ZP LDMA split');
  },
});

// P10
slides.push({
  section: 'improve',
  title: 'Solution 7: Schedule TMEM by Earliest Runnable Microtile',
  notes: 'VX_microtile_readiness_scheduler prioritizes traffic that enables the earliest runnable work. Add partial-width, multi-outstanding Weight wide reads and prefetch credits. Feedback is registered; exact generations and fences remain authoritative. Keep restricted channel-to-bank mapping rather than a full crossbar. Sources: VX_microtile_readiness_scheduler.sv and microtile_readiness_scheduler_opt.md.',
  render() {
    const out = base(10, 'improve', this.title, 'Prioritize the missing resource that completes the nearest executable bundle.');
    bulletPanel(out, [
      'The scheduler finds the earliest microtile that can become runnable.',
      'It prioritizes the missing I/W/S/Z resource for that microtile.',
      'Look-ahead is bounded; feedback is registered and local ready remains authoritative.',
    ], C.blue);
    out.push(diagramLabel(100, 304, 'HARDWARE BLOCK DIAGRAM'));
    out.push(fifoIcon(100, 330, 90, 105, 'Descriptor Q', C.blue));
    out.push(dataBus(190, 385, 250, 385, C.blue, 2));
    out.push(tagTableIcon(250, 320, 250, 120, 'Readiness scoreboard', C.amber));
    out.push(arrow(500, 385, 590, 385, C.amber, 2, true));
    out.push(arbiterIcon(590, 330, 130, 110, 'TMEM priority arbiter', C.amber, 4));
    out.push(dataBus(720, 385, 790, 385, C.cyan, 2));
    out.push(sramIcon(790, 320, 230, 120, 'TMEM banks', 4));
    out.push(dataBus(1020, 385, 1090, 385, C.cyan, 3));
    out.push(fifoIcon(1090, 330, 95, 105, 'Operand FIFO', C.green));
    out.push(dataBus(1185, 385, 1250, 385, C.green, 2));
    out.push(macArrayIcon(1250, 320, 170, 120, 'Consumer'));
    out.push(line(1335, 440, 1335, 480, C.green, 1.5, { 'stroke-dasharray': '6 5' }));
    out.push(line(1335, 480, 470, 480, C.green, 1.5, { 'stroke-dasharray': '6 5' }));
    out.push(arrow(470, 480, 470, 440, C.green, 1.5, true));
    out.push(txt(900, 500, 'registered consumer feedback', 13, C.green, 700, 'middle'));
    out.push(diagramLabel(100, 540, 'READINESS TIMING · EARLIEST TILE WAITS FOR WEIGHT'));
    [570, 640, 710].forEach((y, i) => out.push(laneAt(y, ['µtile 7 state', 'Weight fetch', 'Compute issue'][i], 100, 300, 1460)));
    out.push(segment(330, 571, 320, 'I ready · W missing', C.amber, 34));
    out.push(segment(650, 571, 260, 'W response', C.cyan, 34));
    out.push(segment(910, 571, 300, 'all resources ready', C.green, 34));
    out.push(segment(520, 641, 390, 'prioritized Weight request', C.cyan, 34));
    out.push(segment(930, 711, 300, 'issue µtile 7', C.blue, 34));
    return footer(out, 10, C.blue, 'Scheduler hint; local ready remains authoritative');
  },
});

// P11
slides.push({
  section: 'guard',
  title: 'Guardrails: What Overlap Must Not Change',
  notes: 'Correctness invariants: source responses may return out of order, but admission, destination writes, notifications, and retirement remain command-ordered; completion is the final actual write. Prefetch is bounded and generation-safe. Valid/payload/priority stable under stall. Preserve 64-byte interleaving and restricted topology; ACC double buffering does not imply output-LMEM double buffering.',
  render() {
    const out = base(11, 'guard', this.title, 'More concurrency is allowed only inside explicit correctness fences.');
    bulletPanel(out, [
      'Source responses may reorder, but destination writes, notify, and retirement remain ordered.',
      'Prefetch is bounded and guarded by exact generations and writer fences.',
      'valid / payload stay stable on stall; scheduler priority never overrides local ready.',
    ], C.green);
    out.push(diagramLabel(100, 304, 'ORDERING BLOCK DIAGRAM'));
    out.push(fifoIcon(100, 330, 100, 105, 'Response slots', C.cyan));
    out.push(txt(215, 355, 'R1', 14, C.cyan, 700));
    out.push(txt(215, 410, 'R0', 14, C.cyan, 700));
    out.push(arrow(235, 355, 300, 375, C.cyan, 2));
    out.push(arrow(235, 410, 300, 395, C.cyan, 2));
    out.push(tagTableIcon(300, 320, 250, 120, 'Reorder / command table', C.blue));
    out.push(dataBus(550, 385, 620, 385, C.blue, 2));
    out.push(fifoIcon(620, 330, 95, 105, 'Ordered drain', C.blue));
    out.push(dataBus(715, 385, 790, 385, C.green, 2));
    out.push(sramIcon(790, 325, 230, 115, 'Destination banks', 4));
    out.push(dataBus(1020, 385, 1090, 385, C.green, 2));
    out.push(counterIcon(1090, 325, 230, 115, 'Notify / retire state'));
    out.push(dataBus(1320, 385, 1380, 385, C.green, 2));
    out.push(fifoIcon(1380, 330, 95, 105, 'Retire Q', C.green));
    out.push(diagramLabel(100, 532, 'STALL TIMING · PAYLOAD MUST HOLD'));
    [562, 632, 702].forEach((y, i) => out.push(laneAt(y, ['valid', 'ready', 'payload / priority'][i], 100, 300, 1460)));
    out.push(segment(340, 563, 600, 'valid = 1', C.blue, 34));
    out.push(segment(340, 633, 260, 'ready = 0', C.red, 34));
    out.push(segment(600, 633, 340, 'ready = 1', C.green, 34));
    out.push(segment(340, 703, 600, 'stable while stalled', C.amber, 34));
    out.push(txt(1240, 720, 'Completion = final actual write', 18, C.green, 700));
    return footer(out, 11, C.green, 'Concurrency inside fences · ordered architectural effects');
  },
});

// P12
slides.push({
  section: 'improve',
  title: 'IMPROVE Resulting Architecture and Execution Flow',
  notes: 'Consolidated final IMPROVE architecture: metadata-driven admission → overlapped operand movement → elastic compute/ACC → concurrent output drain. Key fences: exact generation/writer fences, bounded look-ahead, local ACC ownership, ordered final write.',
  render() {
    const out = base(12, 'improve', this.title, 'The final node is a pipeline of independently backpressured concurrency domains.');
    bulletPanel(out, [
      'Final flow: metadata admission → overlapped movement → elastic compute/ACC → concurrent drain.',
      'Concurrency is bounded by exact generations, look-ahead limits, and local ACC ownership.',
      'Architectural completion remains the final ordered destination write.',
    ], C.blue);
    out.push(diagramLabel(100, 304, 'FINAL IMPROVE HARDWARE BLOCK DIAGRAM'));
    out.push(fsmIcon(80, 325, 135, 105, 'Admission FSM', C.amber));
    out.push(dataBus(215, 380, 260, 380, C.amber, 2, true));
    out.push(tagTableIcon(260, 320, 185, 110, 'Command tags', C.blue));
    out.push(dataBus(445, 380, 490, 380, C.cyan, 2));
    out.push(dmaIcon(490, 325, 160, 100, 'HBM + S/Z DMA', C.cyan));
    out.push(dataBus(650, 380, 700, 380, C.cyan, 2));
    out.push(sramIcon(700, 320, 180, 110, 'TMEM banks', 4));
    out.push(dataBus(880, 380, 930, 380, C.blue, 2));
    out.push(arbiterIcon(930, 325, 110, 100, 'Readiness arbiter', C.amber, 4));
    out.push(dataBus(1040, 380, 1090, 380, C.blue, 2));
    out.push(macArrayIcon(1090, 315, 170, 120, 'Elastic compute'));
    out.push(dataBus(1260, 380, 1310, 380, C.green, 2));
    out.push(sramIcon(1310, 320, 150, 110, 'ACC A / B', 4));
    out.push(fifoIcon(1475, 325, 65, 100, 'drain', C.green));
    out.push(arrow(1460, 380, 1475, 380, C.green, 2));
    out.push(diagramLabel(100, 552, 'EXECUTION TIMING'));
    [582, 642, 702, 762].forEach((y, i) => out.push(laneAt(y, ['DMA N+1', 'Compute N', 'Drain N−1', 'Retire'][i], 100, 290, 1460)));
    out.push(segment(330, 583, 520, 'prefetch / install N+1', C.cyan, 32));
    out.push(segment(520, 643, 470, 'compute N', C.blue, 32));
    out.push(segment(330, 703, 430, 'drain N−1', C.green, 32));
    out.push(segment(990, 763, 270, 'final write → retire', C.green, 32));
    return footer(out, 12, C.blue, 'Final IMPROVE flow');
  },
});

// P13
slides.push({
  section: 'naive',
  title: 'NAIVE Baseline: Row-Major GEMM on LMEM',
  notes: 'Introduce the original NAIVE node independently: FSM, LMEM/DMA operand path, compute/ACC, and output path. Contrast local-memory row-major execution with IMPROVE without discussing shared implementation yet. Source: hw/rtl/core/gemm/VX_gemm_node_naive.sv.',
  render() {
    const out = base(13, 'naive', this.title, 'A different memory personality: row-major addressing and LMEM-centered data movement.');
    bulletPanel(out, [
      'NAIVE executes row-major GEMM using LMEM for operands and accumulation.',
      'Its FSM/address equations and external output DMA are distinct from IMPROVE.',
      'The baseline compute path assumes fixed timing around LMEM PSUM traffic.',
    ], C.magenta);
    out.push(diagramLabel(100, 304, 'HARDWARE BLOCK DIAGRAM'));
    out.push(fsmIcon(90, 330, 145, 105, 'NAIVE FSM', C.magenta));
    out.push(addressGenIcon(270, 330, 180, 105, 'Row-major address', C.magenta));
    out.push(arrow(235, 382, 270, 382, C.magenta, 2));
    out.push(dataBus(450, 382, 500, 382, C.cyan, 2));
    out.push(dmaIcon(500, 330, 170, 100, 'LMEM gather DMA', C.cyan));
    out.push(dataBus(670, 382, 720, 382, C.cyan, 2));
    out.push(sramIcon(720, 325, 220, 110, 'LMEM banks', 4));
    out.push(dataBus(940, 382, 990, 382, C.blue, 2));
    out.push(macArrayIcon(990, 320, 180, 120, 'Compute + PSUM'));
    out.push(dataBus(1170, 382, 1220, 382, C.green, 2));
    out.push(fifoIcon(1220, 330, 90, 100, 'Write Q', C.green));
    out.push(dataBus(1310, 382, 1360, 382, C.green, 2));
    out.push(dmaIcon(1360, 330, 150, 100, 'Output DMA', C.green));
    out.push(diagramLabel(100, 548, 'BASELINE TIMING'));
    out.push(laneAt(580, 'Node', 100, 240, 1460));
    out.push(segment(270, 581, 250, 'LMEM load', C.cyan, 40));
    out.push(segment(520, 581, 300, 'PSUM read', C.magenta, 40));
    out.push(segment(820, 581, 330, 'compute + write', C.blue, 40));
    out.push(segment(1150, 581, 270, 'output DMA', C.green, 40));
    return footer(out, 13, C.magenta, 'Baseline NAIVE node · row-major LMEM');
  },
});

// P14
slides.push({
  section: 'naive',
  title: 'Why the NAIVE Compute Path Needed to Change',
  notes: 'Fixed timing assumptions made backpressure, ACC latency, and actual command completion difficult to handle robustly. Preserve row-major address equations, LMEM mapping, and output DMA; do not import IMPROVE TMEM scheduling. Source: docs/future_optim/gemv/gemm_naive/naive_compute_pipeline_parity_opt.md.',
  render() {
    const out = base(14, 'naive', this.title, 'Control was aligned to expected cycles—not to the movement of real data.');
    bulletPanel(out, [
      'Control moved by fixed delay instead of actual ready/valid handshakes.',
      'Backpressure or variable ACC latency could misalign control and physical completion.',
      'Row-major addressing, LMEM mapping, and output DMA must remain unchanged.',
    ], C.magenta);
    out.push(diagramLabel(100, 304, 'OLD COMPUTE / ACC BLOCK DIAGRAM'));
    out.push(fifoIcon(100, 330, 90, 100, 'Packet FIFO', C.magenta));
    out.push(dataBus(190, 382, 250, 382, C.blue, 2));
    [250, 310, 370].forEach((x, i) => out.push(pipelineRegIcon(x, 330, 38, 105, `D${i}`)));
    out.push(line(288, 382, 310, 382, C.blue, 2));
    out.push(line(348, 382, 370, 382, C.blue, 2));
    out.push(dataBus(408, 382, 480, 382, C.cyan, 2));
    out.push(sramIcon(480, 330, 220, 105, 'LMEM PSUM banks', 4));
    out.push(dataBus(700, 382, 780, 382, C.blue, 2));
    out.push(macArrayIcon(780, 320, 190, 120, 'Compute'));
    out.push(dataBus(970, 382, 1050, 382, C.green, 2));
    out.push(fifoIcon(1050, 330, 95, 100, 'Write Q', C.green));
    out.push(dataBus(1145, 382, 1210, 382, C.green, 2));
    out.push(sramIcon(1210, 330, 220, 105, 'LMEM destination', 4));
    out.push(line(250, 460, 408, 460, C.red, 2, { 'stroke-dasharray': '6 5' }));
    out.push(line(250, 448, 250, 460, C.red, 2));
    out.push(line(408, 448, 408, 460, C.red, 2));
    out.push(txt(329, 486, 'fixed-delay control taps', 13, C.red, 700, 'middle'));
    out.push(diagramLabel(100, 516, 'TIMING MISMATCH'));
    [546, 616, 686].forEach((y, i) => out.push(laneAt(y, ['Expected control', 'Actual LMEM response', 'Completion'][i], 100, 300, 1460)));
    out.push(segment(340, 547, 600, 'fixed-delay control window', C.amber, 34));
    out.push(segment(520, 617, 620, 'variable response / backpressure', C.cyan, 34));
    out.push(segment(820, 687, 250, 'old done pulse', C.red, 34));
    out.push(segment(1070, 687, 270, 'final LMEM write', C.green, 34));
    out.push(line(1070, 530, 1070, 745, C.red, 2, { 'stroke-dasharray': '8 7' }));
    return footer(out, 14, C.magenta, 'Change flow control; preserve NAIVE memory semantics');
  },
});

// P15
slides.push({
  section: 'naive',
  title: 'NAIVE Resulting Architecture and Execution Flow',
  notes: 'Each accepted Input packet becomes a stable control record aligned with data. Use exact W/S/Z load generations, tagged final completion, and physical LMEM request drain. The node instantiates VX_gemm_compute_core and VX_gemm_acc_lmem. Sources: VX_gemm_node_naive.sv, VX_gemm_acc_lmem.sv, and naive_compute_pipeline_parity_opt.md.',
  render() {
    const out = base(15, 'naive', this.title, 'The memory topology stays NAIVE; the compute contract becomes transaction-accurate.');
    bulletPanel(out, [
      'Each accepted Input packet creates a stable data + control record.',
      'Exact W/S/Z generations and tagged LMEM ACC requests replace fixed timing assumptions.',
      'Command completion occurs only after the final physical LMEM write.',
    ], C.magenta);
    out.push(diagramLabel(100, 304, 'FINAL NAIVE HARDWARE BLOCK DIAGRAM'));
    out.push(addressGenIcon(80, 330, 170, 105, 'Row-major FSM', C.magenta));
    const pkt = tokenIcon(285, 350, ['addr', 'W/S/Z', 'tag'], 'Packet record', C.magenta);
    out.push(pkt.svg);
    out.push(arrow(250, 382, 285, 382, C.magenta, 2));
    out.push(dataBus(pkt.endX, 366, 540, 366, C.blue, 2));
    out.push(pipelineRegIcon(540, 330, 38, 105, 'R0'));
    out.push(dataBus(578, 382, 640, 382, C.blue, 2));
    out.push(macArrayIcon(640, 320, 180, 120, 'Elastic compute'));
    out.push(dataBus(820, 382, 880, 382, C.green, 2));
    out.push(tagTableIcon(880, 325, 210, 110, 'ACC LMEM tags', C.green));
    out.push(dataBus(1090, 382, 1150, 382, C.green, 2));
    out.push(sramIcon(1150, 325, 220, 110, 'LMEM banks', 4));
    out.push(dataBus(1370, 382, 1420, 382, C.green, 2));
    out.push(fifoIcon(1420, 330, 80, 100, 'Output Q', C.green));
    out.push(diagramLabel(100, 532, 'COMPLETION TIMING'));
    [562, 622, 682, 742].forEach((y, i) => out.push(laneAt(y, ['Packet', 'LMEM requests', 'Final write', 'done'][i], 100, 300, 1460)));
    out.push(segment(340, 563, 260, 'accepted + tagged', C.magenta, 32));
    out.push(segment(520, 623, 500, 'read / response / write requests', C.cyan, 32));
    out.push(segment(1020, 683, 250, 'write handshake', C.green, 32));
    out.push(segment(1270, 743, 170, 'done', C.blue, 32));
    return footer(out, 15, C.magenta, 'NAIVE final flow · exact generations + physical completion');
  },
});

// P16
slides.push({
  section: 'compare',
  title: 'Final Comparison: IMPROVE and NAIVE Hardware Architectures',
  notes: 'Side-by-side architecture comparison by controller, operand memory system, compute/ACC, and output path. Focus on the throughput/correctness consequences of each memory personality.',
  render() {
    const out = base(16, 'compare', this.title, 'One elastic compute contract, two intentionally different memory systems.');
    bulletPanel(out, [
      'Both architectures use the same elastic compute contract.',
      'IMPROVE couples it to TMEM scheduling and internal double-buffered ACC storage.',
      'NAIVE couples it to row-major LMEM and the existing external output path.',
    ], C.cyan);
    out.push(diagramLabel(100, 304, 'IMPROVE HARDWARE'));
    out.push(diagramLabel(830, 304, 'NAIVE HARDWARE', C.magenta));
    out.push(fsmIcon(100, 330, 100, 80, 'Control', C.amber));
    out.push(arrow(200, 370, 230, 370, C.line, 1.5));
    out.push(sramIcon(230, 330, 120, 78, 'TMEM', 4));
    out.push(arrow(350, 370, 385, 370, C.line, 1.5));
    out.push(arbiterIcon(385, 330, 90, 78, 'Scheduler', C.cyan, 3));
    out.push(arrow(475, 370, 510, 370, C.line, 1.5));
    out.push(macArrayIcon(510, 325, 120, 88, 'Compute'));
    out.push(arrow(630, 370, 665, 370, C.line, 1.5));
    out.push(sramIcon(665, 330, 120, 78, 'ACC A/B', 4));
    out.push(addressGenIcon(830, 330, 125, 80, 'FSM / addr', C.magenta));
    out.push(arrow(955, 370, 990, 370, C.line, 1.5));
    out.push(sramIcon(990, 330, 120, 78, 'LMEM', 4));
    out.push(arrow(1110, 370, 1145, 370, C.line, 1.5));
    out.push(macArrayIcon(1145, 325, 120, 88, 'Compute'));
    out.push(arrow(1265, 370, 1300, 370, C.line, 1.5));
    out.push(tagTableIcon(1300, 330, 110, 78, 'ACC tags', C.green));
    out.push(arrow(1410, 370, 1440, 370, C.line, 1.5));
    out.push(fifoIcon(1440, 330, 70, 78, 'Output', C.green));
    out.push(diagramLabel(100, 500, 'EXECUTION TIMING'));
    out.push(laneAt(530, 'IMP DMA', 100, 260, 1460));
    out.push(laneAt(590, 'IMP compute', 100, 260, 1460));
    out.push(laneAt(650, 'IMP drain', 100, 260, 1460));
    out.push(segment(300, 531, 420, 'DMA N+1', C.cyan, 32));
    out.push(segment(500, 591, 430, 'compute N', C.blue, 32));
    out.push(segment(330, 651, 390, 'drain N−1', C.green, 32));
    out.push(laneAt(730, 'NAIVE', 100, 260, 1460));
    out.push(segment(300, 731, 270, 'LMEM load', C.cyan, 32));
    out.push(segment(570, 731, 300, 'compute', C.blue, 32));
    out.push(segment(870, 731, 300, 'final LMEM write', C.green, 32));
    out.push(segment(1170, 731, 230, 'output DMA', C.green, 32));
    return footer(out, 16, C.cyan, 'Architecture choices by memory personality');
  },
});

// P17
slides.push({
  section: 'compare',
  title: 'Takeaway and Evidence',
  notes: 'Evidence sources include VCS unittests for gemm_unit_v2, backpressure/forwarding, programmable ACC, ACC LMEM adapter, microtile scheduler, stream DMA queue, Weight gather, and node integration. agent-tasks/gemv-gemm-unit-v2-xrt-integration/STATUS.yaml records seven IMPROVE xrt-vcs-sim cases passing. The NAIVE phase plan records WLOAD8 readiness and focused parity tests. Measured performance/utilization remains a placeholder pending a selected benchmark configuration.',
  render() {
    const out = base(17, 'compare', this.title, 'The reusable principle is architectural; the proof remains backend-specific.');
    bulletPanel(out, [
      'Architectural principle: separate compute flow control from backend memory systems.',
      'Focused RTL tests cover RAW forwarding, variable ACC latency, scheduling, and DMA ordering.',
      'Final XRT-VCS integration passed; measured performance remains a benchmark placeholder.',
    ], C.cyan);
    out.push(diagramLabel(100, 304, 'VERIFICATION FLOW'));
    out.push(rect(120, 330, 230, 120, '#FFFFFF', C.blue, 3));
    out.push(diagramLabel(138, 354, 'STIMULUS'));
    out.push(`<polyline ${attrs({ points: '145,405 175,405 175,370 210,370 210,420 245,420 245,385 315,385', fill: 'none', stroke: C.blue, 'stroke-width': 3 })}/>`);
    out.push(txt(235, 474, 'directed + randomized tests', 15, C.text, 650, 'middle'));
    out.push(dataBus(350, 390, 430, 390, C.blue, 2));
    out.push(macArrayIcon(430, 325, 160, 110, 'DUT datapath'));
    out.push(sramIcon(620, 330, 150, 100, 'DUT memory', 4));
    out.push(arrow(590, 390, 620, 390, C.green, 2));
    out.push(dataBus(770, 390, 850, 390, C.green, 2));
    out.push(circle(890, 390, 34, '#FFFFFF', C.green, 3));
    out.push(txt(890, 399, '=', 30, C.green, 800, 'middle'));
    out.push(txt(890, 450, 'scoreboard', 15, C.text, 650, 'middle'));
    out.push(dataBus(924, 390, 1000, 390, C.green, 2));
    out.push(tagTableIcon(1000, 330, 220, 100, 'Coverage / completion', C.cyan));
    out.push(dataBus(1220, 390, 1290, 390, C.green, 2));
    out.push(rect(1290, 330, 210, 100, '#EFF3EF', C.green, 3));
    out.push(txt(1395, 372, '7 / 7', 32, C.green, 800, 'middle'));
    out.push(txt(1395, 408, 'XRT-VCS PASS', 16, C.green, 700, 'middle'));
    out.push(diagramLabel(100, 540, 'EVIDENCE COVERAGE'));
    out.push(laneAt(570, 'Compute', 100, 260, 1460));
    out.push(segment(300, 571, 330, 'elastic + RAW', C.blue, 34));
    out.push(laneAt(630, 'Memory', 100, 260, 1460));
    out.push(segment(420, 631, 430, 'variable ACC + scheduler', C.cyan, 34));
    out.push(laneAt(690, 'System', 100, 260, 1460));
    out.push(segment(650, 691, 450, 'node + XRT-VCS', C.green, 34));
    out.push(rect(1120, 650, 360, 90, C.panel, C.amber, 4, { 'stroke-dasharray': '8 6' }));
    out.push(txt(1300, 690, 'PERFORMANCE', 18, C.amber, 800, 'middle'));
    out.push(txt(1300, 720, 'benchmark placeholder', 18, C.muted, 500, 'middle'));
    return footer(out, 17, C.cyan, 'Focused RTL tests + final XRT-VCS integration');
  },
});

// P18
slides.push({
  section: 'appendix',
  title: 'Appendix: Shared Compute-Path Implementation',
  notes: 'Implementation detail: VX_gemm_compute_core supplies the shared elastic arithmetic and packet-control contract. IMPROVE uses VX_gemm_unit_v2 with VX_gemm_acc_internal; NAIVE uses VX_gemm_acc_lmem. This appendix is for implementation questions, not the main architecture narrative.',
  render() {
    const out = base(18, 'appendix', this.title, 'Shared arithmetic contract; backend adapters preserve each architecture’s memory semantics.');
    bulletPanel(out, [
      'VX_gemm_compute_core provides the shared elastic arithmetic and packet-control contract.',
      'IMPROVE connects the core to VX_gemm_acc_internal.',
      'NAIVE connects the same core to VX_gemm_acc_lmem and row-major packet control.',
    ], C.muted);
    out.push(diagramLabel(100, 304, 'SHARED IMPLEMENTATION BLOCK DIAGRAM'));
    const impTok = tokenIcon(100, 360, ['addr', 'seq', 'gen'], 'IMPROVE token', C.blue);
    out.push(impTok.svg);
    out.push(addressGenIcon(100, 560, 170, 100, 'NAIVE packetizer', C.magenta));
    out.push(arrow(impTok.endX, 376, 430, 445, C.blue, 2));
    out.push(arrow(270, 610, 430, 535, C.magenta, 2));
    out.push(pipelineRegIcon(430, 425, 38, 130, 'R0'));
    out.push(dataBus(468, 490, 530, 490, C.blue, 2));
    out.push(circle(565, 490, 28, '#FFFFFF', C.cyan, 2));
    out.push(txt(565, 497, '×', 24, C.cyan, 750, 'middle'));
    out.push(dataBus(593, 490, 640, 490, C.blue, 2));
    out.push(macArrayIcon(640, 410, 210, 150, 'VX_gemm_compute_core'));
    out.push(dataBus(850, 490, 920, 490, C.blue, 2));
    out.push(pipelineRegIcon(920, 425, 38, 130, 'R1'));
    out.push(arrow(958, 470, 1080, 400, C.green, 2));
    out.push(arrow(958, 520, 1080, 615, C.magenta, 2));
    out.push(muxIcon(1080, 365, 80, 70, 'RAW'));
    out.push(sramIcon(1190, 350, 220, 100, 'VX_gemm_acc_internal', 4));
    out.push(arrow(1160, 400, 1190, 400, C.green, 2));
    out.push(tagTableIcon(1080, 570, 180, 95, 'LMEM tag adapter', C.magenta));
    out.push(sramIcon(1290, 570, 180, 95, 'VX_gemm_acc_lmem', 4));
    out.push(arrow(1260, 618, 1290, 618, C.magenta, 2));
    out.push(laneAt(730, 'Contract', 100, 260, 1460));
    out.push(segment(360, 731, 850, 'data + control lockstep · ready / valid · credits · tagged retire', C.blue, 32));
    return footer(out, 18, C.muted, 'Implementation detail for Q&A');
  },
});

async function main() {
  if (slides.length !== 18) throw new Error(`Expected 18 slides, found ${slides.length}`);
  if (KO_NOTES.length !== slides.length) throw new Error(`Expected ${slides.length} Korean notes, found ${KO_NOTES.length}`);

  const pptx = new PptxGenJS();
  pptx.layout = 'LAYOUT_WIDE';
  pptx.author = 'Vortex RTL Team';
  pptx.company = 'Vortex';
  pptx.subject = 'fpint 기준 구조에서 feat/gemv까지의 GEMV RTL 아키텍처 변화';
  pptx.title = 'GEMV RTL 아키텍처 변화 과정';
  pptx.lang = 'ko-KR';
  pptx.theme = {
    headFontFace: 'Noto Sans CJK KR',
    bodyFontFace: 'Noto Sans CJK KR',
    lang: 'ko-KR',
  };
  pptx.defineSlideMaster({
    title: 'FULL_BLEED_SVG',
    background: { color: C.bg.replace('#', '') },
    objects: [],
    slideNumber: { x: 12.6, y: 7.15, w: 0.4, h: 0.2, color: '0B1020', transparency: 100 },
  });

  const manifest = [];
  slides.forEach((spec, idx) => {
    const svg = spec.render();
    const slideNo = idx + 1;
    const svgName = `${String(slideNo).padStart(2, '0')}.svg`;
    const svgPath = path.join(SLIDE_DIR, svgName);
    fs.writeFileSync(svgPath, svg, 'utf8');
    const slide = pptx.addSlide('FULL_BLEED_SVG');
    const data = `data:image/svg+xml;base64,${Buffer.from(svg).toString('base64')}`;
    slide.addImage({ data, x: 0, y: 0, w: 13.333333, h: 7.5 });
    slide.addNotes(KO_NOTES[idx]);
    manifest.push({ slide: slideNo, title: koText(spec.title), svg: `slides/${svgName}`, notes: KO_NOTES[idx] });
  });

  await pptx.writeFile({ fileName: PPTX_PATH, compression: true });
  fs.writeFileSync(path.join(OUT_DIR, 'presentation-manifest.json'), `${JSON.stringify(manifest, null, 2)}\n`, 'utf8');
  process.stdout.write(`Created ${PPTX_PATH}\n`);
}

main().catch((err) => {
  console.error(err.stack || err);
  process.exit(1);
});
