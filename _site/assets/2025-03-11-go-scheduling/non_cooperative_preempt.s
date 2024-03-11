// $ dlv exec ./myprogram
// (dlv) disassemble -l main.fibonacci
    main.go:11      0x1023e8890     900b40f9        MOVD 16(R28), R16
    main.go:11      0x1023e8894     f1c300d1        SUB $48, RSP, R17
    main.go:11      0x1023e8898     3f0210eb        CMP R16, R17
    main.go:11      0x1023e889c     090c0054        BLS 96(PC)
    main.go:11      0x1023e88a0     fe0f15f8        MOVD.W R30, -176(RSP)
    main.go:11      0x1023e88a4     fd831ff8        MOVD R29, -8(RSP)
    main.go:11      0x1023e88a8     fd2300d1        SUB $8, RSP, R29
    main.go:11      0x1023e88ac     e05f00f9        MOVD R0, 184(RSP)
    main.go:11      0x1023e88b0     ff1b00f9        MOVD ZR, 48(RSP)
    main.go:12      0x1023e88b4     1f0400f1        CMP $1, R0
    main.go:12      0x1023e88b8     4d000054        BLE 2(PC)
    main.go:12      0x1023e88bc     05000014        JMP 5(PC)
    main.go:13      0x1023e88c0     e01b00f9        MOVD R0, 48(RSP)
    main.go:13      0x1023e88c4     fdfb7fa9        LDP -8(RSP), (R29, R30)
    main.go:13      0x1023e88c8     ffc30291        ADD $176, RSP, RSP
    main.go:13      0x1023e88cc     c0035fd6        RET
    main.go:15      0x1023e88d0     ff1f00f9        MOVD ZR, 56(RSP)
    main.go:15      0x1023e88d4     e10340b2        ORR $1, ZR, R1
    main.go:15      0x1023e88d8     e12700f9        MOVD R1, 72(RSP)
    main.go:16      0x1023e88dc     e1037fb2        ORR $2, ZR, R1
    main.go:16      0x1023e88e0     e12300f9        MOVD R1, 64(RSP)
    main.go:16      0x1023e88e4     01000014        JMP 1(PC)
    main.go:16      0x1023e88e8     e25f40f9        MOVD 184(RSP), R2
    main.go:16      0x1023e88ec     e32340f9        MOVD 64(RSP), R3
    main.go:16      0x1023e88f0     5f0003eb        CMP R3, R2
    main.go:16      0x1023e88f4     4a000054        BGE 2(PC)
    main.go:16      0x1023e88f8     44000014        JMP 68(PC)
    main.go:17      0x1023e88fc     ffff08a9        STP (ZR, ZR), 136(RSP)
    main.go:17      0x1023e8900     ffff09a9        STP (ZR, ZR), 152(RSP)
    main.go:17      0x1023e8904     e1230291        ADD $136, RSP, R1
    main.go:17      0x1023e8908     e13700f9        MOVD R1, 104(RSP)
    main.go:17      0x1023e890c     e05f40f9        MOVD 184(RSP), R0
    main.go:17      0x1023e8910     6078fd97        CALL runtime.convT64(SB)
    main.go:17      0x1023e8914     e03300f9        MOVD R0, 96(RSP)
    main.go:17      0x1023e8918     e13740f9        MOVD 104(RSP), R1
    main.go:17      0x1023e891c     3b008039        MOVB (R1), R27
    main.go:17      0x1023e8920     e2000090        ADRP 114688(PC), R2
    main.go:17      0x1023e8924     42000f91        ADD $960, R2, R2
    main.go:17      0x1023e8928     220000f9        MOVD R2, (R1)
    main.go:17      0x1023e892c     9b0800f0        ADRP 1126400(PC), R27
    main.go:17      0x1023e8930     62034ab9        MOVWU 2560(R27), R2
    main.go:17      0x1023e8934     42000034        CBZW R2, 2(PC)
    main.go:17      0x1023e8938     02000014        JMP 2(PC)
    main.go:17      0x1023e893c     06000014        JMP 6(PC)
    main.go:17      0x1023e8940     b8f0fe97        CALL runtime.gcWriteBarrier2(SB)
    main.go:17      0x1023e8944     200300f9        MOVD R0, (R25)
    main.go:17      0x1023e8948     220440f9        MOVD 8(R1), R2
    main.go:17      0x1023e894c     220700f9        MOVD R2, 8(R25)
    main.go:17      0x1023e8950     01000014        JMP 1(PC)
    main.go:17      0x1023e8954     200400f9        MOVD R0, 8(R1)
    main.go:17      0x1023e8958     e02340f9        MOVD 64(RSP), R0
    main.go:17      0x1023e895c     4d78fd97        CALL runtime.convT64(SB)
    main.go:17      0x1023e8960     e02f00f9        MOVD R0, 88(RSP)
    main.go:17      0x1023e8964     e13740f9        MOVD 104(RSP), R1
    main.go:17      0x1023e8968     3b008039        MOVB (R1), R27
    main.go:17      0x1023e896c     e2000090        ADRP 114688(PC), R2
    main.go:17      0x1023e8970     42000f91        ADD $960, R2, R2
    main.go:17      0x1023e8974     220800f9        MOVD R2, 16(R1)
    main.go:17      0x1023e8978     9b0800f0        ADRP 1126400(PC), R27
    main.go:17      0x1023e897c     62034ab9        MOVWU 2560(R27), R2
    main.go:17      0x1023e8980     42000034        CBZW R2, 2(PC)
    main.go:17      0x1023e8984     02000014        JMP 2(PC)
    main.go:17      0x1023e8988     06000014        JMP 6(PC)
    main.go:17      0x1023e898c     a5f0fe97        CALL runtime.gcWriteBarrier2(SB)
    main.go:17      0x1023e8990     200300f9        MOVD R0, (R25)
    main.go:17      0x1023e8994     250c40f9        MOVD 24(R1), R5
    main.go:17      0x1023e8998     250700f9        MOVD R5, 8(R25)
    main.go:17      0x1023e899c     01000014        JMP 1(PC)
    main.go:17      0x1023e89a0     200c00f9        MOVD R0, 24(R1)
    main.go:17      0x1023e89a4     e23740f9        MOVD 104(RSP), R2
    main.go:17      0x1023e89a8     5b008039        MOVB (R2), R27
    main.go:17      0x1023e89ac     01000014        JMP 1(PC)
    main.go:17      0x1023e89b0     e23b00f9        MOVD R2, 112(RSP)
    main.go:17      0x1023e89b4     e4037fb2        ORR $2, ZR, R4
    main.go:17      0x1023e89b8     e43f00f9        MOVD R4, 120(RSP)
    main.go:17      0x1023e89bc     e44300f9        MOVD R4, 128(RSP)
    main.go:17      0x1023e89c0     40000090        ADRP 32768(PC), R0
    main.go:17      0x1023e89c4     00580591        ADD $342, R0, R0
    main.go:17      0x1023e89c8     c10580d2        MOVD $46, R1
    main.go:17      0x1023e89cc     e30304aa        MOVD R4, R3
    main.go:17      0x1023e89d0     10e6ff97        CALL fmt.Printf(SB)
    main.go:18      0x1023e89d4     e52740f9        MOVD 72(RSP), R5
    main.go:18      0x1023e89d8     e61f40f9        MOVD 56(RSP), R6
    main.go:18      0x1023e89dc     c500058b        ADD R5, R6, R5
    main.go:18      0x1023e89e0     e52b00f9        MOVD R5, 80(RSP)
    main.go:18      0x1023e89e4     e62740f9        MOVD 72(RSP), R6
    main.go:18      0x1023e89e8     e61f00f9        MOVD R6, 56(RSP)
    main.go:18      0x1023e89ec     e52700f9        MOVD R5, 72(RSP)
    main.go:18      0x1023e89f0     01000014        JMP 1(PC)
    main.go:16      0x1023e89f4     e22340f9        MOVD 64(RSP), R2
    main.go:16      0x1023e89f8     42040091        ADD $1, R2, R2
    main.go:16      0x1023e89fc     e22300f9        MOVD R2, 64(RSP)
    main.go:16      0x1023e8a00     e1037fb2        ORR $2, ZR, R1
    main.go:16      0x1023e8a04     b9ffff17        JMP -71(PC)
    main.go:20      0x1023e8a08     e02740f9        MOVD 72(RSP), R0
    main.go:20      0x1023e8a0c     e01b00f9        MOVD R0, 48(RSP)
    main.go:20      0x1023e8a10     fdfb7fa9        LDP -8(RSP), (R29, R30)
    main.go:20      0x1023e8a14     ffc30291        ADD $176, RSP, RSP
    main.go:20      0x1023e8a18     c0035fd6        RET
    main.go:11      0x1023e8a1c     e00700f9        MOVD R0, 8(RSP)
    main.go:11      0x1023e8a20     e3031eaa        MOVD R30, R3
    main.go:11      0x1023e8a24     dbe7fe97        CALL runtime.morestack_noctxt(SB)
    main.go:11      0x1023e8a28     e00740f9        MOVD 8(RSP), R0
    main.go:11      0x1023e8a2c     99ffff17        JMP main.fibonacci(SB)