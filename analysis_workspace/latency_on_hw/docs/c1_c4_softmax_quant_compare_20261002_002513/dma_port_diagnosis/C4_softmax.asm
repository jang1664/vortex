<kernel_softmax(kernel_arg_t*)>:
180000094: 13 01 01 f7 	addi	sp, sp, -0x90
180000098: 23 34 11 08 	sd	ra, 0x88(sp)
18000009c: 23 30 81 08 	sd	s0, 0x80(sp)
1800000a0: 23 3c 91 06 	sd	s1, 0x78(sp)
1800000a4: 23 38 21 07 	sd	s2, 0x70(sp)
1800000a8: 23 34 31 07 	sd	s3, 0x68(sp)
1800000ac: 23 30 41 07 	sd	s4, 0x60(sp)
1800000b0: 23 3c 51 05 	sd	s5, 0x58(sp)
1800000b4: 23 38 61 05 	sd	s6, 0x50(sp)
1800000b8: 23 34 71 05 	sd	s7, 0x48(sp)
1800000bc: 23 30 81 05 	sd	s8, 0x40(sp)
1800000c0: 23 3c 91 03 	sd	s9, 0x38(sp)
1800000c4: 23 38 a1 03 	sd	s10, 0x30(sp)
1800000c8: 23 34 b1 03 	sd	s11, 0x28(sp)
1800000cc: 23 30 a1 02 	sd	a0, 0x20(sp)
1800000d0: 97 55 00 00 	auipc	a1, 0x5
1800000d4: 83 b5 05 f5 	ld	a1, -0xb0(a1)
1800000d8: 03 26 85 03 	lw	a2, 0x38(a0)
1800000dc: 83 26 c5 03 	lw	a3, 0x3c(a0)
1800000e0: 03 27 05 04 	lw	a4, 0x40(a0)
1800000e4: b3 85 45 00 	add	a1, a1, tp
1800000e8: 83 a5 05 00 	lw	a1, 0x0(a1)
1800000ec: 33 86 c6 02 	mul	a2, a3, a2
1800000f0: bb 06 e6 02 	mulw	a3, a2, a4
1800000f4: 33 b6 d5 00 	sltu	a2, a1, a3
1800000f8: 0b 27 16 00 	vx_split_n	a4, a2
1800000fc: 63 0a 06 4c 	beqz	a2, 0x1800005d0 <kernel_softmax(kernel_arg_t*)+0x53c>
180000100: 23 30 e1 00 	sd	a4, 0x0(sp)
180000104: 17 56 00 00 	auipc	a2, 0x5
180000108: 03 36 46 f1 	ld	a2, -0xec(a2)
18000010c: 17 57 00 00 	auipc	a4, 0x5
180000110: 83 38 c7 f2 	ld	a7, -0xd4(a4)
180000114: 03 37 05 02 	ld	a4, 0x20(a0)
180000118: 23 3c e1 00 	sd	a4, 0x18(sp)
18000011c: 03 37 85 02 	ld	a4, 0x28(a0)
180000120: 23 38 e1 00 	sd	a4, 0x10(sp)
180000124: 33 06 46 00 	add	a2, a2, tp
180000128: 23 34 c1 00 	sd	a2, 0x8(sp)
18000012c: b3 88 48 00 	add	a7, a7, tp
180000130: f3 22 40 cc 	csrr	t0, tmask
180000134: 37 06 80 ff 	lui	a2, 0xff800
180000138: d3 07 06 f0 	fmv.w.x	fa5, a2
18000013c: 13 03 80 3c 	li	t1, 0x3c8
180000140: 93 03 40 3c 	li	t2, 0x3c4
180000144: 13 0e 20 3c 	li	t3, 0x3c2
180000148: 93 0e 10 3c 	li	t4, 0x3c1
18000014c: 13 0f 00 3c 	li	t5, 0x3c0
180000150: 53 07 00 f0 	fmv.w.x	fa4, zero
180000154: 37 06 00 80 	lui	a2, 0x80000
180000158: d3 06 06 f0 	fmv.w.x	fa3, a2
18000015c: 93 0f 00 01 	li	t6, 0x10
180000160: 6f 00 40 02 	j	0x180000184 <kernel_softmax(kernel_arg_t*)+0xf0>
180000164: 0b 30 06 00 	vx_join	a2
180000168: 17 56 00 00 	auipc	a2, 0x5
18000016c: 03 26 86 f8 	lw	a2, -0x78(a2)
180000170: bb 05 b6 00 	addw	a1, a2, a1
180000174: 33 b6 d5 00 	sltu	a2, a1, a3
180000178: 13 46 16 00 	xori	a2, a2, 0x1
18000017c: 8b 50 56 00 	vx_pred_n	a2, t0
180000180: 63 16 06 44 	bnez	a2, 0x1800005cc <kernel_softmax(kernel_arg_t*)+0x538>
180000184: 03 26 85 04 	lw	a2, 0x48(a0)
180000188: 33 06 b6 02 	mul	a2, a2, a1
18000018c: 03 27 05 04 	lw	a4, 0x40(a0)
180000190: 13 16 06 02 	slli	a2, a2, 0x20
180000194: 13 5b 06 02 	srli	s6, a2, 0x20
180000198: 03 39 81 01 	ld	s2, 0x18(sp)
18000019c: 33 09 69 01 	add	s2, s2, s6
1800001a0: 3b f6 e5 02 	remuw	a2, a1, a4
1800001a4: 83 24 45 04 	lw	s1, 0x44(a0)
1800001a8: 03 27 c5 04 	lw	a4, 0x4c(a0)
1800001ac: 07 26 05 05 	flw	fa2, 0x50(a0)
1800001b0: 83 37 81 00 	ld	a5, 0x8(sp)
1800001b4: 03 ec 07 00 	lwu	s8, 0x0(a5)
1800001b8: 1b 06 16 00 	addiw	a2, a2, 0x1
1800001bc: b3 37 96 00 	sltu	a5, a2, s1
1800001c0: 33 56 f6 0e 	czero.eqz	a2, a2, a5
1800001c4: b3 f7 f4 0e 	czero.nez	a5, s1, a5
1800001c8: 33 66 f6 00 	or	a2, a2, a5
1800001cc: 33 56 e6 0e 	czero.eqz	a2, a2, a4
1800001d0: f3 2a 30 fc 	csrr	s5, nw
1800001d4: 83 a7 08 00 	lw	a5, 0x0(a7)
1800001d8: 33 f7 e4 0e 	czero.nez	a4, s1, a4
1800001dc: 33 6a c7 00 	or	s4, a4, a2
1800001e0: 1b 06 0c 00 	sext.w	a2, s8
1800001e4: 93 97 27 03 	slli	a5, a5, 0x32
1800001e8: 93 d7 07 02 	srli	a5, a5, 0x20
1800001ec: b3 8a fa 00 	add	s5, s5, a5
1800001f0: b3 3b 46 01 	sltu	s7, a2, s4
1800001f4: 0b a6 1b 00 	vx_split_n	a2, s7
1800001f8: d3 85 f7 20 	fmv.s	fa1, fa5
1800001fc: 63 84 0b 08 	beqz	s7, 0x180000284 <kernel_softmax(kernel_arg_t*)+0x1f0>
180000200: 13 14 1c 00 	slli	s0, s8, 0x1
180000204: 33 04 89 00 	add	s0, s2, s0
180000208: f3 29 40 cc 	csrr	s3, tmask
18000020c: 53 85 f7 20 	fmv.s	fa0, fa5
180000210: 93 0c 0c 00 	mv	s9, s8
180000214: 6f 00 40 02 	j	0x180000238 <kernel_softmax(kernel_arg_t*)+0x1a4>
180000218: 0b 30 07 00 	vx_join	a4
18000021c: 13 04 04 02 	addi	s0, s0, 0x20
180000220: 9b 8c 0c 01 	addiw	s9, s9, 0x10
180000224: 33 b7 4c 01 	sltu	a4, s9, s4
180000228: 13 47 17 00 	xori	a4, a4, 0x1
18000022c: 8b 50 37 01 	vx_pred_n	a4, s3
180000230: 53 85 b5 20 	fmv.s	fa0, fa1
180000234: 63 18 07 04 	bnez	a4, 0x180000284 <kernel_softmax(kernel_arg_t*)+0x1f0>
180000238: 87 15 04 00 	flh	fa1, 0x0(s0)
18000023c: d3 85 25 40 	fcvt.s.h	fa1, fa1
180000240: d3 75 b6 10 	fmul.s	fa1, fa2, fa1
180000244: 1b d7 0c 01 	srliw	a4, s9, 0x10
180000248: 93 37 17 00 	seqz	a5, a4
18000024c: 0b a7 17 00 	vx_split_n	a4, a5
180000250: 63 8a 07 00 	beqz	a5, 0x180000264 <kernel_softmax(kernel_arg_t*)+0x1d0>
180000254: 9b 87 0c 00 	sext.w	a5, s9
180000258: 93 97 27 00 	slli	a5, a5, 0x2
18000025c: b3 87 fa 00 	add	a5, s5, a5
180000260: 27 a0 b7 00 	fsw	fa1, 0x0(a5)
180000264: 0b 30 07 00 	vx_join	a4
180000268: 53 17 b5 a0 	flt.s	a4, fa0, fa1
18000026c: 33 47 07 00 	xor	a4, a4, zero
180000270: b3 37 e0 00 	snez	a5, a4
180000274: 0b a7 07 00 	vx_split	a4, a5
180000278: e3 90 07 fa 	bnez	a5, 0x180000218 <kernel_softmax(kernel_arg_t*)+0x184>
18000027c: d3 05 a5 20 	fmv.s	fa1, fa0
180000280: 6f f0 9f f9 	j	0x180000218 <kernel_softmax(kernel_arg_t*)+0x184>
180000284: 03 37 01 01 	ld	a4, 0x10(sp)
180000288: 33 0b 67 01 	add	s6, a4, s6
18000028c: 0b 30 06 00 	vx_join	a2
180000290: 53 86 05 e0 	fmv.x.w	a2, fa1
180000294: 13 16 06 02 	slli	a2, a2, 0x20
180000298: 13 56 06 02 	srli	a2, a2, 0x20
18000029c: 0b 56 66 02 	<unknown>
1800002a0: 53 05 06 f0 	fmv.w.x	fa0, a2
1800002a4: 1b 04 8c 00 	addiw	s0, s8, 0x8
1800002a8: 13 36 04 01 	sltiu	a2, s0, 0x10
1800002ac: 53 97 a5 a0 	flt.s	a4, fa1, fa0
1800002b0: 33 76 e6 00 	and	a2, a2, a4
1800002b4: 33 46 06 00 	xor	a2, a2, zero
1800002b8: 33 37 c0 00 	snez	a4, a2
1800002bc: 0b 26 07 00 	vx_split	a2, a4
1800002c0: 63 14 07 00 	bnez	a4, 0x1800002c8 <kernel_softmax(kernel_arg_t*)+0x234>
1800002c4: 53 85 b5 20 	fmv.s	fa0, fa1
1800002c8: 0b 30 06 00 	vx_join	a2
1800002cc: 53 06 05 e0 	fmv.x.w	a2, fa0
1800002d0: 13 16 06 02 	slli	a2, a2, 0x20
1800002d4: 13 56 06 02 	srli	a2, a2, 0x20
1800002d8: 0b 56 76 02 	<unknown>
1800002dc: d3 05 06 f0 	fmv.w.x	fa1, a2
1800002e0: 9b 0c 4c 00 	addiw	s9, s8, 0x4
1800002e4: 13 b6 0c 01 	sltiu	a2, s9, 0x10
1800002e8: 53 17 b5 a0 	flt.s	a4, fa0, fa1
1800002ec: 33 76 e6 00 	and	a2, a2, a4
1800002f0: 33 46 06 00 	xor	a2, a2, zero
1800002f4: 33 37 c0 00 	snez	a4, a2
1800002f8: 0b 26 07 00 	vx_split	a2, a4
1800002fc: 63 14 07 00 	bnez	a4, 0x180000304 <kernel_softmax(kernel_arg_t*)+0x270>
180000300: d3 05 a5 20 	fmv.s	fa1, fa0
180000304: 0b 30 06 00 	vx_join	a2
180000308: 53 86 05 e0 	fmv.x.w	a2, fa1
18000030c: 13 16 06 02 	slli	a2, a2, 0x20
180000310: 13 56 06 02 	srli	a2, a2, 0x20
180000314: 0b 56 c6 03 	<unknown>
180000318: 53 05 06 f0 	fmv.w.x	fa0, a2
18000031c: 1b 0d 2c 00 	addiw	s10, s8, 0x2
180000320: 13 36 0d 01 	sltiu	a2, s10, 0x10
180000324: 53 97 a5 a0 	flt.s	a4, fa1, fa0
180000328: 33 76 e6 00 	and	a2, a2, a4
18000032c: 33 46 06 00 	xor	a2, a2, zero
180000330: 33 37 c0 00 	snez	a4, a2
180000334: 0b 26 07 00 	vx_split	a2, a4
180000338: 63 14 07 00 	bnez	a4, 0x180000340 <kernel_softmax(kernel_arg_t*)+0x2ac>
18000033c: 53 85 b5 20 	fmv.s	fa0, fa1
180000340: 0b 30 06 00 	vx_join	a2
180000344: 53 06 05 e0 	fmv.x.w	a2, fa0
180000348: 13 16 06 02 	slli	a2, a2, 0x20
18000034c: 13 56 06 02 	srli	a2, a2, 0x20
180000350: 0b 56 d6 03 	<unknown>
180000354: d3 05 06 f0 	fmv.w.x	fa1, a2
180000358: 9b 0d 1c 00 	addiw	s11, s8, 0x1
18000035c: 13 b6 0d 01 	sltiu	a2, s11, 0x10
180000360: 53 17 b5 a0 	flt.s	a4, fa0, fa1
180000364: 33 76 e6 00 	and	a2, a2, a4
180000368: 33 46 06 00 	xor	a2, a2, zero
18000036c: 33 37 c0 00 	snez	a4, a2
180000370: 0b 26 07 00 	vx_split	a2, a4
180000374: 63 14 07 00 	bnez	a4, 0x18000037c <kernel_softmax(kernel_arg_t*)+0x2e8>
180000378: d3 05 a5 20 	fmv.s	fa1, fa0
18000037c: 0b 30 06 00 	vx_join	a2
180000380: 53 86 05 e0 	fmv.x.w	a2, fa1
180000384: 13 16 06 02 	slli	a2, a2, 0x20
180000388: 13 56 06 02 	srli	a2, a2, 0x20
18000038c: 0b 76 e6 03 	<unknown>
180000390: d3 05 06 f0 	fmv.w.x	fa1, a2
180000394: 8b a0 1b 00 	vx_split_n	ra, s7
180000398: 53 05 e7 20 	fmv.s	fa0, fa4
18000039c: 63 88 0b 08 	beqz	s7, 0x18000042c <kernel_softmax(kernel_arg_t*)+0x398>
1800003a0: 73 26 40 cc 	csrr	a2, tmask
1800003a4: 53 05 e7 20 	fmv.s	fa0, fa4
1800003a8: 93 09 0c 00 	mv	s3, s8
1800003ac: 6f 00 00 02 	j	0x1800003cc <kernel_softmax(kernel_arg_t*)+0x338>
1800003b0: 0b b0 07 00 	vx_join	a5
1800003b4: 53 75 05 00 	fadd.s	fa0, fa0, ft0
1800003b8: 9b 89 09 01 	addiw	s3, s3, 0x10
1800003bc: 33 b7 49 01 	sltu	a4, s3, s4
1800003c0: 13 47 17 00 	xori	a4, a4, 0x1
1800003c4: 8b 50 c7 00 	vx_pred_n	a4, a2
1800003c8: 63 10 07 06 	bnez	a4, 0x180000428 <kernel_softmax(kernel_arg_t*)+0x394>
1800003cc: 1b d7 09 01 	srliw	a4, s3, 0x10
1800003d0: 13 37 17 00 	seqz	a4, a4
1800003d4: 93 97 09 02 	slli	a5, s3, 0x20
1800003d8: 13 d3 07 02 	srli	t1, a5, 0x20
1800003dc: 8b 27 17 00 	vx_split_n	a5, a4
1800003e0: 13 18 23 00 	slli	a6, t1, 0x2
1800003e4: 63 08 07 00 	beqz	a4, 0x1800003f4 <kernel_softmax(kernel_arg_t*)+0x360>
1800003e8: 33 83 0a 01 	add	t1, s5, a6
1800003ec: 07 20 03 00 	flw	ft0, 0x0(t1)
1800003f0: 6f 00 80 01 	j	0x180000408 <kernel_softmax(kernel_arg_t*)+0x374>
1800003f4: 13 13 13 00 	slli	t1, t1, 0x1
1800003f8: 33 03 69 00 	add	t1, s2, t1
1800003fc: 07 10 03 00 	flh	ft0, 0x0(t1)
180000400: 53 00 20 40 	fcvt.s.h	ft0, ft0
180000404: 53 70 06 10 	fmul.s	ft0, fa2, ft0
180000408: 0b b0 07 00 	vx_join	a5
18000040c: 53 70 b0 08 	fsub.s	ft0, ft0, fa1
180000410: 0b 00 00 06 	<unknown>
180000414: 8b 27 17 00 	vx_split_n	a5, a4
180000418: e3 0c 07 f8 	beqz	a4, 0x1800003b0 <kernel_softmax(kernel_arg_t*)+0x31c>
18000041c: 33 88 0a 01 	add	a6, s5, a6
180000420: 27 20 08 00 	fsw	ft0, 0x0(a6)
180000424: 6f f0 df f8 	j	0x1800003b0 <kernel_softmax(kernel_arg_t*)+0x31c>
180000428: 13 03 80 3c 	li	t1, 0x3c8
18000042c: 0b b0 00 00 	vx_join	ra
180000430: 53 06 05 e0 	fmv.x.w	a2, fa0
180000434: 13 16 06 02 	slli	a2, a2, 0x20
180000438: 13 56 06 02 	srli	a2, a2, 0x20
18000043c: 0b 56 66 02 	<unknown>
180000440: 53 00 06 f0 	fmv.w.x	ft0, a2
180000444: 33 37 f4 01 	sltu	a4, s0, t6
180000448: 0b 26 07 00 	vx_split	a2, a4
18000044c: 63 14 07 00 	bnez	a4, 0x180000454 <kernel_softmax(kernel_arg_t*)+0x3c0>
180000450: 53 80 d6 20 	fmv.s	ft0, fa3
180000454: 0b 30 06 00 	vx_join	a2
180000458: 53 75 05 00 	fadd.s	fa0, fa0, ft0
18000045c: 53 06 05 e0 	fmv.x.w	a2, fa0
180000460: 13 16 06 02 	slli	a2, a2, 0x20
180000464: 13 56 06 02 	srli	a2, a2, 0x20
180000468: 0b 56 76 02 	<unknown>
18000046c: 53 00 06 f0 	fmv.w.x	ft0, a2
180000470: 33 b7 fc 01 	sltu	a4, s9, t6
180000474: 0b 26 07 00 	vx_split	a2, a4
180000478: 63 14 07 00 	bnez	a4, 0x180000480 <kernel_softmax(kernel_arg_t*)+0x3ec>
18000047c: 53 80 d6 20 	fmv.s	ft0, fa3
180000480: 0b 30 06 00 	vx_join	a2
180000484: 53 75 05 00 	fadd.s	fa0, fa0, ft0
180000488: 53 06 05 e0 	fmv.x.w	a2, fa0
18000048c: 13 16 06 02 	slli	a2, a2, 0x20
180000490: 13 56 06 02 	srli	a2, a2, 0x20
180000494: 0b 56 c6 03 	<unknown>
180000498: 53 00 06 f0 	fmv.w.x	ft0, a2
18000049c: 33 37 fd 01 	sltu	a4, s10, t6
1800004a0: 0b 26 07 00 	vx_split	a2, a4
1800004a4: 63 14 07 00 	bnez	a4, 0x1800004ac <kernel_softmax(kernel_arg_t*)+0x418>
1800004a8: 53 80 d6 20 	fmv.s	ft0, fa3
1800004ac: 0b 30 06 00 	vx_join	a2
1800004b0: 53 75 05 00 	fadd.s	fa0, fa0, ft0
1800004b4: 53 06 05 e0 	fmv.x.w	a2, fa0
1800004b8: 13 16 06 02 	slli	a2, a2, 0x20
1800004bc: 13 56 06 02 	srli	a2, a2, 0x20
1800004c0: 0b 56 d6 03 	<unknown>
1800004c4: 53 00 06 f0 	fmv.w.x	ft0, a2
1800004c8: 33 b7 fd 01 	sltu	a4, s11, t6
1800004cc: 0b 26 07 00 	vx_split	a2, a4
1800004d0: 63 14 07 00 	bnez	a4, 0x1800004d8 <kernel_softmax(kernel_arg_t*)+0x444>
1800004d4: 53 80 d6 20 	fmv.s	ft0, fa3
1800004d8: 0b 30 06 00 	vx_join	a2
1800004dc: 53 75 05 00 	fadd.s	fa0, fa0, ft0
1800004e0: 53 06 05 e0 	fmv.x.w	a2, fa0
1800004e4: 13 16 06 02 	slli	a2, a2, 0x20
1800004e8: 13 56 06 02 	srli	a2, a2, 0x20
1800004ec: 0b 77 e6 03 	<unknown>
1800004f0: 0b a6 1b 00 	vx_split_n	a2, s7
1800004f4: 63 8a 0b 08 	beqz	s7, 0x180000588 <kernel_softmax(kernel_arg_t*)+0x4f4>
1800004f8: 53 05 07 f0 	fmv.w.x	fa0, a4
1800004fc: 37 07 80 3f 	lui	a4, 0x3f800
180000500: 53 00 07 f0 	fmv.w.x	ft0, a4
180000504: 53 75 a0 18 	fdiv.s	fa0, ft0, fa0
180000508: 13 14 1c 00 	slli	s0, s8, 0x1
18000050c: 33 04 8b 00 	add	s0, s6, s0
180000510: d3 95 b5 20 	fneg.s	fa1, fa1
180000514: f3 29 40 cc 	csrr	s3, tmask
180000518: 93 0b 0c 00 	mv	s7, s8
18000051c: 6f 00 40 04 	j	0x180000560 <kernel_softmax(kernel_arg_t*)+0x4cc>
180000520: 93 97 17 00 	slli	a5, a5, 0x1
180000524: b3 07 f9 00 	add	a5, s2, a5
180000528: 07 90 07 00 	flh	ft0, 0x0(a5)
18000052c: 53 00 20 40 	fcvt.s.h	ft0, ft0
180000530: 43 70 c0 58 	fmadd.s	ft0, ft0, fa2, fa1
180000534: 0b 00 00 06 	<unknown>
180000538: 0b 30 07 00 	vx_join	a4
18000053c: 53 70 05 10 	fmul.s	ft0, fa0, ft0
180000540: 53 70 00 44 	fcvt.h.s	ft0, ft0
180000544: 27 10 04 00 	fsh	ft0, 0x0(s0)
180000548: 13 04 04 02 	addi	s0, s0, 0x20
18000054c: 9b 8b 0b 01 	addiw	s7, s7, 0x10
180000550: 33 b7 4b 01 	sltu	a4, s7, s4
180000554: 13 47 17 00 	xori	a4, a4, 0x1
180000558: 8b 50 37 01 	vx_pred_n	a4, s3
18000055c: 63 16 07 02 	bnez	a4, 0x180000588 <kernel_softmax(kernel_arg_t*)+0x4f4>
180000560: 1b d7 0b 01 	srliw	a4, s7, 0x10
180000564: 13 38 17 00 	seqz	a6, a4
180000568: 93 97 0b 02 	slli	a5, s7, 0x20
18000056c: 93 d7 07 02 	srli	a5, a5, 0x20
180000570: 0b 27 18 00 	vx_split_n	a4, a6
180000574: e3 06 08 fa 	beqz	a6, 0x180000520 <kernel_softmax(kernel_arg_t*)+0x48c>
180000578: 93 97 27 00 	slli	a5, a5, 0x2
18000057c: b3 87 fa 00 	add	a5, s5, a5
180000580: 07 a0 07 00 	flw	ft0, 0x0(a5)
180000584: 6f f0 5f fb 	j	0x180000538 <kernel_softmax(kernel_arg_t*)+0x4a4>
180000588: 0b 30 06 00 	vx_join	a2
18000058c: 3b 07 8a 01 	addw	a4, s4, s8
180000590: b3 37 97 00 	sltu	a5, a4, s1
180000594: 0b a6 17 00 	vx_split_n	a2, a5
180000598: e3 86 07 bc 	beqz	a5, 0x180000164 <kernel_softmax(kernel_arg_t*)+0xd0>
18000059c: f3 27 40 cc 	csrr	a5, tmask
1800005a0: 53 06 00 f0 	fmv.w.x	fa2, zero
1800005a4: 53 76 06 44 	fcvt.h.s	fa2, fa2
1800005a8: 13 18 07 02 	slli	a6, a4, 0x20
1800005ac: 13 58 f8 01 	srli	a6, a6, 0x1f
1800005b0: 33 08 0b 01 	add	a6, s6, a6
1800005b4: 27 10 c8 00 	fsh	fa2, 0x0(a6)
1800005b8: 1b 07 07 01 	addiw	a4, a4, 0x10
1800005bc: 33 38 97 00 	sltu	a6, a4, s1
1800005c0: 0b 50 f8 00 	vx_pred	a6, a5
1800005c4: e3 1e 08 fc 	bnez	a6, 0x1800005a0 <kernel_softmax(kernel_arg_t*)+0x50c>
1800005c8: 6f f0 df b9 	j	0x180000164 <kernel_softmax(kernel_arg_t*)+0xd0>
1800005cc: 03 37 01 00 	ld	a4, 0x0(sp)
1800005d0: 0b 30 07 00 	vx_join	a4
1800005d4: 83 30 81 08 	ld	ra, 0x88(sp)
1800005d8: 03 34 01 08 	ld	s0, 0x80(sp)
1800005dc: 83 34 81 07 	ld	s1, 0x78(sp)
1800005e0: 03 39 01 07 	ld	s2, 0x70(sp)
1800005e4: 83 39 81 06 	ld	s3, 0x68(sp)
1800005e8: 03 3a 01 06 	ld	s4, 0x60(sp)
1800005ec: 83 3a 81 05 	ld	s5, 0x58(sp)
1800005f0: 03 3b 01 05 	ld	s6, 0x50(sp)
1800005f4: 83 3b 81 04 	ld	s7, 0x48(sp)
1800005f8: 03 3c 01 04 	ld	s8, 0x40(sp)
1800005fc: 83 3c 81 03 	ld	s9, 0x38(sp)
180000600: 03 3d 01 03 	ld	s10, 0x30(sp)
180000604: 83 3d 81 02 	ld	s11, 0x28(sp)
180000608: 13 01 01 09 	addi	sp, sp, 0x90
18000060c: 67 80 00 00 	ret
