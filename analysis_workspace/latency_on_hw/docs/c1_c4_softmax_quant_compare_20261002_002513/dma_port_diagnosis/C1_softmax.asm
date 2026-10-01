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
1800000fc: 63 0e 06 4c 	beqz	a2, 0x1800005d8 <kernel_softmax(kernel_arg_t*)+0x544>
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
18000013c: 93 03 80 3c 	li	t2, 0x3c8
180000140: 13 0e 40 3c 	li	t3, 0x3c4
180000144: 93 0e 20 3c 	li	t4, 0x3c2
180000148: 13 0f 10 3c 	li	t5, 0x3c1
18000014c: 93 0f 00 3c 	li	t6, 0x3c0
180000150: 53 07 00 f0 	fmv.w.x	fa4, zero
180000154: 37 06 00 80 	lui	a2, 0x80000
180000158: d3 06 06 f0 	fmv.w.x	fa3, a2
18000015c: 13 04 00 01 	li	s0, 0x10
180000160: 6f 00 40 02 	j	0x180000184 <kernel_softmax(kernel_arg_t*)+0xf0>
180000164: 0b 30 06 00 	vx_join	a2
180000168: 17 56 00 00 	auipc	a2, 0x5
18000016c: 03 26 86 f8 	lw	a2, -0x78(a2)
180000170: bb 05 b6 00 	addw	a1, a2, a1
180000174: 33 b6 d5 00 	sltu	a2, a1, a3
180000178: 13 46 16 00 	xori	a2, a2, 0x1
18000017c: 8b 50 56 00 	vx_pred_n	a2, t0
180000180: 63 1a 06 44 	bnez	a2, 0x1800005d4 <kernel_softmax(kernel_arg_t*)+0x540>
180000184: 03 26 85 04 	lw	a2, 0x48(a0)
180000188: 33 06 b6 02 	mul	a2, a2, a1
18000018c: 03 27 05 04 	lw	a4, 0x40(a0)
180000190: 13 16 06 02 	slli	a2, a2, 0x20
180000194: 93 5b 06 02 	srli	s7, a2, 0x20
180000198: 83 39 81 01 	ld	s3, 0x18(sp)
18000019c: b3 89 79 01 	add	s3, s3, s7
1800001a0: 3b f6 e5 02 	remuw	a2, a1, a4
1800001a4: 03 29 45 04 	lw	s2, 0x44(a0)
1800001a8: 03 27 c5 04 	lw	a4, 0x4c(a0)
1800001ac: 07 26 05 05 	flw	fa2, 0x50(a0)
1800001b0: 83 37 81 00 	ld	a5, 0x8(sp)
1800001b4: 83 ec 07 00 	lwu	s9, 0x0(a5)
1800001b8: 1b 06 16 00 	addiw	a2, a2, 0x1
1800001bc: b3 37 26 01 	sltu	a5, a2, s2
1800001c0: 33 56 f6 0e 	czero.eqz	a2, a2, a5
1800001c4: b3 77 f9 0e 	czero.nez	a5, s2, a5
1800001c8: 33 66 f6 00 	or	a2, a2, a5
1800001cc: 33 56 e6 0e 	czero.eqz	a2, a2, a4
1800001d0: 73 2b 30 fc 	csrr	s6, nw
1800001d4: 83 a7 08 00 	lw	a5, 0x0(a7)
1800001d8: 33 77 e9 0e 	czero.nez	a4, s2, a4
1800001dc: b3 6a c7 00 	or	s5, a4, a2
1800001e0: 1b 86 0c 00 	sext.w	a2, s9
1800001e4: 37 07 06 00 	lui	a4, 0x60
1800001e8: 33 87 e7 02 	mul	a4, a5, a4
1800001ec: 13 17 07 02 	slli	a4, a4, 0x20
1800001f0: 13 57 07 02 	srli	a4, a4, 0x20
1800001f4: 33 0b eb 00 	add	s6, s6, a4
1800001f8: 33 3c 56 01 	sltu	s8, a2, s5
1800001fc: 0b 26 1c 00 	vx_split_n	a2, s8
180000200: d3 85 f7 20 	fmv.s	fa1, fa5
180000204: 63 04 0c 08 	beqz	s8, 0x18000028c <kernel_softmax(kernel_arg_t*)+0x1f8>
180000208: 13 93 1c 00 	slli	t1, s9, 0x1
18000020c: 33 83 69 00 	add	t1, s3, t1
180000210: f3 24 40 cc 	csrr	s1, tmask
180000214: 53 85 f7 20 	fmv.s	fa0, fa5
180000218: 13 8a 0c 00 	mv	s4, s9
18000021c: 6f 00 40 02 	j	0x180000240 <kernel_softmax(kernel_arg_t*)+0x1ac>
180000220: 0b 30 07 00 	vx_join	a4
180000224: 13 03 03 02 	addi	t1, t1, 0x20
180000228: 1b 0a 0a 01 	addiw	s4, s4, 0x10
18000022c: 33 37 5a 01 	sltu	a4, s4, s5
180000230: 13 47 17 00 	xori	a4, a4, 0x1
180000234: 8b 50 97 00 	vx_pred_n	a4, s1
180000238: 53 85 b5 20 	fmv.s	fa0, fa1
18000023c: 63 18 07 04 	bnez	a4, 0x18000028c <kernel_softmax(kernel_arg_t*)+0x1f8>
180000240: 87 15 03 00 	flh	fa1, 0x0(t1)
180000244: d3 85 25 40 	fcvt.s.h	fa1, fa1
180000248: d3 75 b6 10 	fmul.s	fa1, fa2, fa1
18000024c: 1b 57 fa 00 	srliw	a4, s4, 0xf
180000250: 93 37 37 00 	sltiu	a5, a4, 0x3
180000254: 0b a7 17 00 	vx_split_n	a4, a5
180000258: 63 8a 07 00 	beqz	a5, 0x18000026c <kernel_softmax(kernel_arg_t*)+0x1d8>
18000025c: 9b 07 0a 00 	sext.w	a5, s4
180000260: 93 97 27 00 	slli	a5, a5, 0x2
180000264: b3 07 fb 00 	add	a5, s6, a5
180000268: 27 a0 b7 00 	fsw	fa1, 0x0(a5)
18000026c: 0b 30 07 00 	vx_join	a4
180000270: 53 17 b5 a0 	flt.s	a4, fa0, fa1
180000274: 33 47 07 00 	xor	a4, a4, zero
180000278: b3 37 e0 00 	snez	a5, a4
18000027c: 0b a7 07 00 	vx_split	a4, a5
180000280: e3 90 07 fa 	bnez	a5, 0x180000220 <kernel_softmax(kernel_arg_t*)+0x18c>
180000284: d3 05 a5 20 	fmv.s	fa1, fa0
180000288: 6f f0 9f f9 	j	0x180000220 <kernel_softmax(kernel_arg_t*)+0x18c>
18000028c: 03 37 01 01 	ld	a4, 0x10(sp)
180000290: b3 0b 77 01 	add	s7, a4, s7
180000294: 0b 30 06 00 	vx_join	a2
180000298: 53 86 05 e0 	fmv.x.w	a2, fa1
18000029c: 13 16 06 02 	slli	a2, a2, 0x20
1800002a0: 13 56 06 02 	srli	a2, a2, 0x20
1800002a4: 0b 56 76 02 	<unknown>
1800002a8: 53 05 06 f0 	fmv.w.x	fa0, a2
1800002ac: 1b 83 8c 00 	addiw	t1, s9, 0x8
1800002b0: 13 36 03 01 	sltiu	a2, t1, 0x10
1800002b4: 53 97 a5 a0 	flt.s	a4, fa1, fa0
1800002b8: 33 76 e6 00 	and	a2, a2, a4
1800002bc: 33 46 06 00 	xor	a2, a2, zero
1800002c0: 33 37 c0 00 	snez	a4, a2
1800002c4: 0b 26 07 00 	vx_split	a2, a4
1800002c8: 63 14 07 00 	bnez	a4, 0x1800002d0 <kernel_softmax(kernel_arg_t*)+0x23c>
1800002cc: 53 85 b5 20 	fmv.s	fa0, fa1
1800002d0: 0b 30 06 00 	vx_join	a2
1800002d4: 53 06 05 e0 	fmv.x.w	a2, fa0
1800002d8: 13 16 06 02 	slli	a2, a2, 0x20
1800002dc: 13 56 06 02 	srli	a2, a2, 0x20
1800002e0: 0b 56 c6 03 	<unknown>
1800002e4: d3 05 06 f0 	fmv.w.x	fa1, a2
1800002e8: 1b 8d 4c 00 	addiw	s10, s9, 0x4
1800002ec: 13 36 0d 01 	sltiu	a2, s10, 0x10
1800002f0: 53 17 b5 a0 	flt.s	a4, fa0, fa1
1800002f4: 33 76 e6 00 	and	a2, a2, a4
1800002f8: 33 46 06 00 	xor	a2, a2, zero
1800002fc: 33 37 c0 00 	snez	a4, a2
180000300: 0b 26 07 00 	vx_split	a2, a4
180000304: 63 14 07 00 	bnez	a4, 0x18000030c <kernel_softmax(kernel_arg_t*)+0x278>
180000308: d3 05 a5 20 	fmv.s	fa1, fa0
18000030c: 0b 30 06 00 	vx_join	a2
180000310: 53 86 05 e0 	fmv.x.w	a2, fa1
180000314: 13 16 06 02 	slli	a2, a2, 0x20
180000318: 13 56 06 02 	srli	a2, a2, 0x20
18000031c: 0b 56 d6 03 	<unknown>
180000320: 53 05 06 f0 	fmv.w.x	fa0, a2
180000324: 9b 8d 2c 00 	addiw	s11, s9, 0x2
180000328: 13 b6 0d 01 	sltiu	a2, s11, 0x10
18000032c: 53 97 a5 a0 	flt.s	a4, fa1, fa0
180000330: 33 76 e6 00 	and	a2, a2, a4
180000334: 33 46 06 00 	xor	a2, a2, zero
180000338: 33 37 c0 00 	snez	a4, a2
18000033c: 0b 26 07 00 	vx_split	a2, a4
180000340: 63 14 07 00 	bnez	a4, 0x180000348 <kernel_softmax(kernel_arg_t*)+0x2b4>
180000344: 53 85 b5 20 	fmv.s	fa0, fa1
180000348: 0b 30 06 00 	vx_join	a2
18000034c: 53 06 05 e0 	fmv.x.w	a2, fa0
180000350: 13 16 06 02 	slli	a2, a2, 0x20
180000354: 13 56 06 02 	srli	a2, a2, 0x20
180000358: 0b 56 e6 03 	<unknown>
18000035c: d3 05 06 f0 	fmv.w.x	fa1, a2
180000360: 9b 80 1c 00 	addiw	ra, s9, 0x1
180000364: 13 b6 00 01 	sltiu	a2, ra, 0x10
180000368: 53 17 b5 a0 	flt.s	a4, fa0, fa1
18000036c: 33 76 e6 00 	and	a2, a2, a4
180000370: 33 46 06 00 	xor	a2, a2, zero
180000374: 33 37 c0 00 	snez	a4, a2
180000378: 0b 26 07 00 	vx_split	a2, a4
18000037c: 63 14 07 00 	bnez	a4, 0x180000384 <kernel_softmax(kernel_arg_t*)+0x2f0>
180000380: d3 05 a5 20 	fmv.s	fa1, fa0
180000384: 0b 30 06 00 	vx_join	a2
180000388: 53 86 05 e0 	fmv.x.w	a2, fa1
18000038c: 13 16 06 02 	slli	a2, a2, 0x20
180000390: 13 56 06 02 	srli	a2, a2, 0x20
180000394: 0b 76 f6 03 	<unknown>
180000398: d3 05 06 f0 	fmv.w.x	fa1, a2
18000039c: 0b 26 1c 00 	vx_split_n	a2, s8
1800003a0: 53 05 e7 20 	fmv.s	fa0, fa4
1800003a4: 63 08 0c 08 	beqz	s8, 0x180000434 <kernel_softmax(kernel_arg_t*)+0x3a0>
1800003a8: f3 24 40 cc 	csrr	s1, tmask
1800003ac: 53 05 e7 20 	fmv.s	fa0, fa4
1800003b0: 13 8a 0c 00 	mv	s4, s9
1800003b4: 6f 00 00 02 	j	0x1800003d4 <kernel_softmax(kernel_arg_t*)+0x340>
1800003b8: 0b b0 03 00 	vx_join	t2
1800003bc: 53 75 05 00 	fadd.s	fa0, fa0, ft0
1800003c0: 1b 0a 0a 01 	addiw	s4, s4, 0x10
1800003c4: 33 37 5a 01 	sltu	a4, s4, s5
1800003c8: 13 47 17 00 	xori	a4, a4, 0x1
1800003cc: 8b 50 97 00 	vx_pred_n	a4, s1
1800003d0: 63 10 07 06 	bnez	a4, 0x180000430 <kernel_softmax(kernel_arg_t*)+0x39c>
1800003d4: 1b 57 fa 00 	srliw	a4, s4, 0xf
1800003d8: 13 37 37 00 	sltiu	a4, a4, 0x3
1800003dc: 93 17 0a 02 	slli	a5, s4, 0x20
1800003e0: 93 d7 07 02 	srli	a5, a5, 0x20
1800003e4: 8b 23 17 00 	vx_split_n	t2, a4
1800003e8: 13 98 27 00 	slli	a6, a5, 0x2
1800003ec: 63 08 07 00 	beqz	a4, 0x1800003fc <kernel_softmax(kernel_arg_t*)+0x368>
1800003f0: b3 07 0b 01 	add	a5, s6, a6
1800003f4: 07 a0 07 00 	flw	ft0, 0x0(a5)
1800003f8: 6f 00 80 01 	j	0x180000410 <kernel_softmax(kernel_arg_t*)+0x37c>
1800003fc: 93 97 17 00 	slli	a5, a5, 0x1
180000400: b3 87 f9 00 	add	a5, s3, a5
180000404: 07 90 07 00 	flh	ft0, 0x0(a5)
180000408: 53 00 20 40 	fcvt.s.h	ft0, ft0
18000040c: 53 70 06 10 	fmul.s	ft0, fa2, ft0
180000410: 0b b0 03 00 	vx_join	t2
180000414: 53 70 b0 08 	fsub.s	ft0, ft0, fa1
180000418: 0b 00 00 06 	<unknown>
18000041c: 8b 23 17 00 	vx_split_n	t2, a4
180000420: e3 0c 07 f8 	beqz	a4, 0x1800003b8 <kernel_softmax(kernel_arg_t*)+0x324>
180000424: 33 08 0b 01 	add	a6, s6, a6
180000428: 27 20 08 00 	fsw	ft0, 0x0(a6)
18000042c: 6f f0 df f8 	j	0x1800003b8 <kernel_softmax(kernel_arg_t*)+0x324>
180000430: 93 03 80 3c 	li	t2, 0x3c8
180000434: 0b 30 06 00 	vx_join	a2
180000438: 53 06 05 e0 	fmv.x.w	a2, fa0
18000043c: 13 16 06 02 	slli	a2, a2, 0x20
180000440: 13 56 06 02 	srli	a2, a2, 0x20
180000444: 0b 56 76 02 	<unknown>
180000448: 53 00 06 f0 	fmv.w.x	ft0, a2
18000044c: 33 37 83 00 	sltu	a4, t1, s0
180000450: 0b 26 07 00 	vx_split	a2, a4
180000454: 63 14 07 00 	bnez	a4, 0x18000045c <kernel_softmax(kernel_arg_t*)+0x3c8>
180000458: 53 80 d6 20 	fmv.s	ft0, fa3
18000045c: 0b 30 06 00 	vx_join	a2
180000460: 53 75 05 00 	fadd.s	fa0, fa0, ft0
180000464: 53 06 05 e0 	fmv.x.w	a2, fa0
180000468: 13 16 06 02 	slli	a2, a2, 0x20
18000046c: 13 56 06 02 	srli	a2, a2, 0x20
180000470: 0b 56 c6 03 	<unknown>
180000474: 53 00 06 f0 	fmv.w.x	ft0, a2
180000478: 33 37 8d 00 	sltu	a4, s10, s0
18000047c: 0b 26 07 00 	vx_split	a2, a4
180000480: 63 14 07 00 	bnez	a4, 0x180000488 <kernel_softmax(kernel_arg_t*)+0x3f4>
180000484: 53 80 d6 20 	fmv.s	ft0, fa3
180000488: 0b 30 06 00 	vx_join	a2
18000048c: 53 75 05 00 	fadd.s	fa0, fa0, ft0
180000490: 53 06 05 e0 	fmv.x.w	a2, fa0
180000494: 13 16 06 02 	slli	a2, a2, 0x20
180000498: 13 56 06 02 	srli	a2, a2, 0x20
18000049c: 0b 56 d6 03 	<unknown>
1800004a0: 53 00 06 f0 	fmv.w.x	ft0, a2
1800004a4: 33 b7 8d 00 	sltu	a4, s11, s0
1800004a8: 0b 26 07 00 	vx_split	a2, a4
1800004ac: 63 14 07 00 	bnez	a4, 0x1800004b4 <kernel_softmax(kernel_arg_t*)+0x420>
1800004b0: 53 80 d6 20 	fmv.s	ft0, fa3
1800004b4: 0b 30 06 00 	vx_join	a2
1800004b8: 53 75 05 00 	fadd.s	fa0, fa0, ft0
1800004bc: 53 06 05 e0 	fmv.x.w	a2, fa0
1800004c0: 13 16 06 02 	slli	a2, a2, 0x20
1800004c4: 13 56 06 02 	srli	a2, a2, 0x20
1800004c8: 0b 56 e6 03 	<unknown>
1800004cc: 53 00 06 f0 	fmv.w.x	ft0, a2
1800004d0: 33 b7 80 00 	sltu	a4, ra, s0
1800004d4: 0b 26 07 00 	vx_split	a2, a4
1800004d8: 63 14 07 00 	bnez	a4, 0x1800004e0 <kernel_softmax(kernel_arg_t*)+0x44c>
1800004dc: 53 80 d6 20 	fmv.s	ft0, fa3
1800004e0: 0b 30 06 00 	vx_join	a2
1800004e4: 53 75 05 00 	fadd.s	fa0, fa0, ft0
1800004e8: 53 06 05 e0 	fmv.x.w	a2, fa0
1800004ec: 13 16 06 02 	slli	a2, a2, 0x20
1800004f0: 13 56 06 02 	srli	a2, a2, 0x20
1800004f4: 0b 77 f6 03 	<unknown>
1800004f8: 0b 26 1c 00 	vx_split_n	a2, s8
1800004fc: 63 0a 0c 08 	beqz	s8, 0x180000590 <kernel_softmax(kernel_arg_t*)+0x4fc>
180000500: 53 05 07 f0 	fmv.w.x	fa0, a4
180000504: 37 07 80 3f 	lui	a4, 0x3f800
180000508: 53 00 07 f0 	fmv.w.x	ft0, a4
18000050c: 53 75 a0 18 	fdiv.s	fa0, ft0, fa0
180000510: 13 93 1c 00 	slli	t1, s9, 0x1
180000514: 33 83 6b 00 	add	t1, s7, t1
180000518: d3 95 b5 20 	fneg.s	fa1, fa1
18000051c: f3 24 40 cc 	csrr	s1, tmask
180000520: 13 8a 0c 00 	mv	s4, s9
180000524: 6f 00 40 04 	j	0x180000568 <kernel_softmax(kernel_arg_t*)+0x4d4>
180000528: 93 97 17 00 	slli	a5, a5, 0x1
18000052c: b3 87 f9 00 	add	a5, s3, a5
180000530: 07 90 07 00 	flh	ft0, 0x0(a5)
180000534: 53 00 20 40 	fcvt.s.h	ft0, ft0
180000538: 43 70 c0 58 	fmadd.s	ft0, ft0, fa2, fa1
18000053c: 0b 00 00 06 	<unknown>
180000540: 0b 30 07 00 	vx_join	a4
180000544: 53 70 05 10 	fmul.s	ft0, fa0, ft0
180000548: 53 70 00 44 	fcvt.h.s	ft0, ft0
18000054c: 27 10 03 00 	fsh	ft0, 0x0(t1)
180000550: 13 03 03 02 	addi	t1, t1, 0x20
180000554: 1b 0a 0a 01 	addiw	s4, s4, 0x10
180000558: 33 37 5a 01 	sltu	a4, s4, s5
18000055c: 13 47 17 00 	xori	a4, a4, 0x1
180000560: 8b 50 97 00 	vx_pred_n	a4, s1
180000564: 63 16 07 02 	bnez	a4, 0x180000590 <kernel_softmax(kernel_arg_t*)+0x4fc>
180000568: 1b 57 fa 00 	srliw	a4, s4, 0xf
18000056c: 13 38 37 00 	sltiu	a6, a4, 0x3
180000570: 93 17 0a 02 	slli	a5, s4, 0x20
180000574: 93 d7 07 02 	srli	a5, a5, 0x20
180000578: 0b 27 18 00 	vx_split_n	a4, a6
18000057c: e3 06 08 fa 	beqz	a6, 0x180000528 <kernel_softmax(kernel_arg_t*)+0x494>
180000580: 93 97 27 00 	slli	a5, a5, 0x2
180000584: b3 07 fb 00 	add	a5, s6, a5
180000588: 07 a0 07 00 	flw	ft0, 0x0(a5)
18000058c: 6f f0 5f fb 	j	0x180000540 <kernel_softmax(kernel_arg_t*)+0x4ac>
180000590: 0b 30 06 00 	vx_join	a2
180000594: 3b 87 9a 01 	addw	a4, s5, s9
180000598: b3 37 27 01 	sltu	a5, a4, s2
18000059c: 0b a6 17 00 	vx_split_n	a2, a5
1800005a0: e3 82 07 bc 	beqz	a5, 0x180000164 <kernel_softmax(kernel_arg_t*)+0xd0>
1800005a4: f3 27 40 cc 	csrr	a5, tmask
1800005a8: 53 06 00 f0 	fmv.w.x	fa2, zero
1800005ac: 53 76 06 44 	fcvt.h.s	fa2, fa2
1800005b0: 13 18 07 02 	slli	a6, a4, 0x20
1800005b4: 13 58 f8 01 	srli	a6, a6, 0x1f
1800005b8: 33 88 0b 01 	add	a6, s7, a6
1800005bc: 27 10 c8 00 	fsh	fa2, 0x0(a6)
1800005c0: 1b 07 07 01 	addiw	a4, a4, 0x10
1800005c4: 33 38 27 01 	sltu	a6, a4, s2
1800005c8: 0b 50 f8 00 	vx_pred	a6, a5
1800005cc: e3 1e 08 fc 	bnez	a6, 0x1800005a8 <kernel_softmax(kernel_arg_t*)+0x514>
1800005d0: 6f f0 5f b9 	j	0x180000164 <kernel_softmax(kernel_arg_t*)+0xd0>
1800005d4: 03 37 01 00 	ld	a4, 0x0(sp)
1800005d8: 0b 30 07 00 	vx_join	a4
1800005dc: 83 30 81 08 	ld	ra, 0x88(sp)
1800005e0: 03 34 01 08 	ld	s0, 0x80(sp)
1800005e4: 83 34 81 07 	ld	s1, 0x78(sp)
1800005e8: 03 39 01 07 	ld	s2, 0x70(sp)
1800005ec: 83 39 81 06 	ld	s3, 0x68(sp)
1800005f0: 03 3a 01 06 	ld	s4, 0x60(sp)
1800005f4: 83 3a 81 05 	ld	s5, 0x58(sp)
1800005f8: 03 3b 01 05 	ld	s6, 0x50(sp)
1800005fc: 83 3b 81 04 	ld	s7, 0x48(sp)
180000600: 03 3c 01 04 	ld	s8, 0x40(sp)
180000604: 83 3c 81 03 	ld	s9, 0x38(sp)
180000608: 03 3d 01 03 	ld	s10, 0x30(sp)
18000060c: 83 3d 81 02 	ld	s11, 0x28(sp)
180000610: 13 01 01 09 	addi	sp, sp, 0x90
180000614: 67 80 00 00 	ret
