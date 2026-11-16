import Foundation

/// Decodes a FLOW 8 SysEx state dump into a `DumpSnapshot`.
///
/// Ported from the Rust reference implementation
/// (see the reference implementation in `ref-flow8-midi`). Parameters are stored as
/// IEEE-754 32-bit floats in little-endian order, packed into four 7-bit data
/// bytes whose MSB (bit 7) is carried separately by a shared "MSB byte". The
/// MSB byte position rotates through the stream, which is why each parameter
/// lists an explicit MSB offset plus the four data byte offsets and the bit
/// index each data byte takes from the MSB byte.
///
/// All functions are pure and static; the offset tables are `let` constants,
/// so the type is safe to call from any thread.
enum SysExParser {

    // MARK: - Dump validation constants

    private static let sysexStart: UInt8 = 0xF0
    private static let sysexEnd: UInt8 = 0xF7
    private static let behringerID: [UInt8] = [0x00, 0x20, 0x32]
    private static let flow8Model: UInt8 = 0x21
    private static let minDumpSize = 100

    // MARK: - Parameter ranges (mirrors the Rust constants)

    private static let levelDBMin: Float = -70.0
    private static let levelDBMax: Float = 10.0
    private static let gainMin: Float = -20.0
    private static let gainMax: Float = 60.0
    private static let eqMin: Float = -15.0
    private static let eqMax: Float = 15.0
    private static let panMin: Float = -1.0
    private static let panMax: Float = 1.0
    private static let compMin: Float = 0.0
    private static let compMax: Float = 1.0
    private static let balanceMin: Float = -1.0
    private static let balanceMax: Float = 1.0
    private static let limiterMin: Float = -30.0
    private static let limiterMax: Float = 0.0
    private static let lowCutMinHz: UInt16 = 20
    private static let lowCutMaxHz: UInt16 = 600

    // MARK: - Channel name region

    private static let namesStart = 0x0554
    private static let namesStride = 0x1E
    private static let nameScanLen = 14

    // MARK: - Encoding primitives

    /// Four data bytes (`dataOffsets`) whose bit 7 is restored from
    /// `bitIndices` of the byte at `msbOffset`.
    private struct FloatParam {
        let msbOffset: Int
        let dataOffsets: [Int]   // exactly 4, little-endian float bytes
        let bitIndices: [UInt8]  // exactly 4, MSB bit feeding each data byte
    }

    private static func floatParam(
        _ msbOffset: Int,
        _ dataOffsets: [Int],
        _ bitIndices: [UInt8]
    ) -> FloatParam {
        FloatParam(msbOffset: msbOffset, dataOffsets: dataOffsets, bitIndices: bitIndices)
    }

    /// Two 7-bit bytes holding a 14-bit little-endian integer (Hz for low cut).
    private struct LowCutParam {
        let loOffset: Int
        let hiOffset: Int
    }

    /// Single 0x00/0x01 flag byte.
    private struct BoolParam {
        let offset: Int
        let inverted: Bool
    }

    /// FX slots are plain byte offsets (not packed floats).
    private struct FXLayout {
        let param1Offset: Int
        let param2Offset: Int
        let presetOffset: Int
    }

    // MARK: - Channel parameter tables (7 channels: Ch1...Ch7/USB-BT)

    private static let channelLevels: [FloatParam] = [
        floatParam(0x0067, [0x0068, 0x0069, 0x006A, 0x006B], [0, 1, 2, 3]),
        floatParam(0x00B4, [0x00B2, 0x00B3, 0x00B5, 0x00B6], [3, 2, 0, 1]),
        floatParam(0x00FA, [0x00FD, 0x00FE, 0x00FF, 0x0100], [2, 3, 4, 5]),
        floatParam(0x0147, [0x0148, 0x0149, 0x014A, 0x014B], [0, 1, 2, 3]),
        floatParam(0x0194, [0x0192, 0x0193, 0x0195, 0x0196], [3, 2, 0, 1]),
        floatParam(0x01DA, [0x01DD, 0x01DE, 0x01DF, 0x01E0], [2, 3, 4, 5]),
        floatParam(0x0227, [0x0228, 0x0229, 0x022A, 0x022B], [0, 1, 2, 3])
    ]

    private static let channelGains: [FloatParam] = [
        floatParam(0x0739, [0x0736, 0x073A, 0x073B, 0x073C], [4, 0, 1, 2]),
        floatParam(0x077A, [0x077B, 0x077C, 0x077D, 0x077E], [0, 1, 2, 3]),
        floatParam(0x07BD, [0x07BB, 0x07BC, 0x07BE, 0x07BF], [3, 2, 0, 1]),
        floatParam(0x07FD, [0x07FA, 0x07FE, 0x07FF, 0x0800], [4, 0, 1, 2]),
        floatParam(0x083E, [0x083F, 0x0840, 0x0841, 0x0842], [0, 1, 2, 3]),
        floatParam(0x0881, [0x087F, 0x0880, 0x0882, 0x0883], [3, 2, 0, 1]),
        floatParam(0x08C1, [0x08BE, 0x08C2, 0x08C3, 0x08C4], [4, 0, 1, 2])
    ]

    private static let channelPans: [FloatParam] = [
        floatParam(1286, [1284, 1285, 1287, 1288], [3, 2, 0, 1]),
        floatParam(1286, [1289, 1290, 1291, 1292], [2, 3, 4, 5]),
        floatParam(1295, [1293, 1294, 1296, 1297], [3, 2, 0, 1]),
        floatParam(1300, [1298, 1299, 1301, 1302], [3, 2, 0, 1]),
        floatParam(1300, [1303, 1304, 1305, 1306], [2, 3, 4, 5]),
        floatParam(1309, [1307, 1308, 1310, 1311], [3, 2, 0, 1]),
        floatParam(1314, [1312, 1313, 1315, 1316], [3, 2, 0, 1])
    ]

    private static let channelCompressors: [FloatParam] = [
        floatParam(0x073D, [0x073E, 0x073F, 0x0740, 0x0741], [0, 1, 2, 3]),
        floatParam(0x077C, [0x077F, 0x0780, 0x0781, 0x0782], [2, 3, 4, 5]),
        floatParam(0x07C0, [0x07C1, 0x07C2, 0x07C3, 0x07C4], [0, 1, 2, 3]),
        floatParam(0x0801, [0x0802, 0x0803, 0x0804, 0x0805], [0, 1, 2, 3]),
        floatParam(0x0840, [0x0843, 0x0844, 0x0845, 0x0846], [2, 3, 4, 5]),
        floatParam(0x0884, [0x0885, 0x0886, 0x0887, 0x0888], [0, 1, 2, 3]),
        // USB-BT placeholder (Rust skips this slot via has_compressor()).
        floatParam(0x0884, [0x0885, 0x0886, 0x0887, 0x0888], [0, 1, 2, 3])
    ]

    private static let channelLowCuts: [LowCutParam] = [
        LowCutParam(loOffset: 0x0742, hiOffset: 0x0743),
        LowCutParam(loOffset: 0x0784, hiOffset: 0x0785),
        LowCutParam(loOffset: 0x07C5, hiOffset: 0x07C6),
        LowCutParam(loOffset: 0x0806, hiOffset: 0x0807),
        LowCutParam(loOffset: 0x0848, hiOffset: 0x0849),
        LowCutParam(loOffset: 0x0889, hiOffset: 0x088A),
        // USB-BT has no low cut (Rust skips via has_low_cut()).
        LowCutParam(loOffset: 0, hiOffset: 0)
    ]

    private static let channelEQLow: [FloatParam] = [
        floatParam(1860, [1863, 1864, 1865, 1866], [2, 3, 4, 5]),
        floatParam(1930, [1928, 1929, 1931, 1932], [3, 2, 0, 1]),
        floatParam(1993, [1994, 1995, 1996, 1997], [0, 1, 2, 3]),
        floatParam(2056, [2059, 2060, 2061, 2062], [2, 3, 4, 5]),
        floatParam(2126, [2124, 2125, 2127, 2128], [3, 2, 0, 1]),
        floatParam(2189, [2190, 2191, 2192, 2193], [0, 1, 2, 3]),
        floatParam(2252, [2255, 2256, 2257, 2258], [2, 3, 4, 5])
    ]

    private static let channelEQLowMid: [FloatParam] = [
        floatParam(1867, [1868, 1869, 1870, 1871], [0, 1, 2, 3]),
        floatParam(1930, [1933, 1934, 1935, 1936], [2, 3, 4, 5]),
        floatParam(2000, [1998, 1999, 2001, 2002], [3, 2, 0, 1]),
        floatParam(2063, [2064, 2065, 2066, 2067], [0, 1, 2, 3]),
        floatParam(2126, [2129, 2130, 2131, 2132], [2, 3, 4, 5]),
        floatParam(2196, [2194, 2195, 2197, 2198], [3, 2, 0, 1]),
        floatParam(2259, [2260, 2261, 2262, 2263], [0, 1, 2, 3])
    ]

    private static let channelEQHiMid: [FloatParam] = [
        floatParam(1874, [1872, 1873, 1875, 1876], [3, 2, 0, 1]),
        floatParam(1937, [1938, 1939, 1940, 1941], [0, 1, 2, 3]),
        floatParam(2000, [2003, 2004, 2005, 2006], [2, 3, 4, 5]),
        floatParam(2070, [2068, 2069, 2071, 2072], [3, 2, 0, 1]),
        floatParam(2133, [2134, 2135, 2136, 2137], [0, 1, 2, 3]),
        floatParam(2196, [2199, 2200, 2201, 2202], [2, 3, 4, 5]),
        floatParam(2266, [2264, 2265, 2267, 2268], [3, 2, 0, 1])
    ]

    private static let channelEQHi: [FloatParam] = [
        floatParam(1874, [1877, 1878, 1879, 1880], [2, 3, 4, 5]),
        floatParam(1944, [1942, 1943, 1945, 1946], [3, 2, 0, 1]),
        floatParam(2007, [2008, 2009, 2010, 2011], [0, 1, 2, 3]),
        floatParam(2070, [2073, 2074, 2075, 2076], [2, 3, 4, 5]),
        floatParam(2140, [2138, 2139, 2141, 2142], [3, 2, 0, 1]),
        floatParam(2203, [2204, 2205, 2206, 2207], [0, 1, 2, 3]),
        floatParam(2266, [2269, 2270, 2271, 2272], [2, 3, 4, 5])
    ]


    private static let channelSendMon1: [FloatParam] = [
        floatParam(0x0052, [0x0050, 0x0051, 0x0053, 0x0054], [3, 2, 0, 1]),
        floatParam(0x0098, [0x009B, 0x009C, 0x009D, 0x009E], [2, 3, 4, 5]),
        floatParam(0x00E5, [0x00E6, 0x00E7, 0x00E8, 0x00E9], [0, 1, 2, 3]),
        floatParam(0x0132, [0x0130, 0x0131, 0x0133, 0x0134], [3, 2, 0, 1]),
        floatParam(0x0178, [0x017B, 0x017C, 0x017D, 0x017E], [2, 3, 4, 5]),
        floatParam(0x01C5, [0x01C6, 0x01C7, 0x01C8, 0x01C9], [0, 1, 2, 3]),
        floatParam(0x0212, [0x0210, 0x0211, 0x0213, 0x0214], [3, 2, 0, 1])
    ]

    private static let channelSendMon2: [FloatParam] = [
        floatParam(0x0052, [0x0053, 0x0054, 0x0057, 0x0058], [0, 1, 4, 5]),
        floatParam(0x0098, [0x0096, 0x0097, 0x009D, 0x009E], [3, 2, 4, 5]),
        floatParam(0x00EC, [0x00E8, 0x00E9, 0x00ED, 0x00EE], [5, 4, 0, 1]),
        floatParam(0x0132, [0x0133, 0x0134, 0x0137, 0x0138], [0, 1, 4, 5]),
        floatParam(0x0178, [0x0176, 0x0177, 0x017D, 0x017E], [3, 2, 4, 5]),
        floatParam(0x01CC, [0x01C8, 0x01C9, 0x01CD, 0x01CE], [5, 4, 0, 1]),
        floatParam(0x0212, [0x0213, 0x0214, 0x0217, 0x0218], [0, 1, 4, 5])
    ]

    private static let channelSendFX1: [FloatParam] = [
        floatParam(0x0059, [0x005A, 0x005B, 0x005C, 0x005D], [0, 1, 2, 3]),
        floatParam(0x00A6, [0x00A4, 0x00A5, 0x00A7, 0x00A8], [3, 2, 0, 1]),
        floatParam(0x00EC, [0x00EF, 0x00F0, 0x00F1, 0x00F2], [2, 3, 4, 5]),
        floatParam(0x0139, [0x013A, 0x013B, 0x013C, 0x013D], [0, 1, 2, 3]),
        floatParam(0x0186, [0x0184, 0x0185, 0x0187, 0x0188], [3, 2, 0, 1]),
        floatParam(0x01CC, [0x01CF, 0x01D0, 0x01D1, 0x01D2], [2, 3, 4, 5]),
        floatParam(0x0219, [0x021A, 0x021B, 0x021C, 0x021D], [0, 1, 2, 3])
    ]

    private static let channelSendFX2: [FloatParam] = [
        floatParam(0x0060, [0x005E, 0x005F, 0x0061, 0x0062], [3, 2, 0, 1]),
        floatParam(0x00A6, [0x00A9, 0x00AA, 0x00AB, 0x00AC], [2, 3, 4, 5]),
        floatParam(0x00F3, [0x00F4, 0x00F5, 0x00F6, 0x00F7], [0, 1, 2, 3]),
        floatParam(0x0140, [0x013E, 0x013F, 0x0141, 0x0142], [3, 2, 0, 1]),
        floatParam(0x0186, [0x0189, 0x018A, 0x018B, 0x018C], [2, 3, 4, 5]),
        floatParam(0x01D3, [0x01D4, 0x01D5, 0x01D6, 0x01D7], [0, 1, 2, 3]),
        floatParam(0x0220, [0x021E, 0x021F, 0x0221, 0x0222], [3, 2, 0, 1])
    ]

    // MARK: - Bus parameter tables (5 buses: Main, Mon1, Mon2, FX1, FX2)

    private static let busLevels: [FloatParam] = [
        floatParam(1223, [1224, 1225, 1226, 1227], [0, 1, 2, 3]),
        floatParam(824, [827, 828, 829, 830], [2, 3, 4, 5]),
        floatParam(908, [906, 907, 909, 910], [3, 2, 0, 1]),
        floatParam(985, [986, 987, 988, 989], [0, 1, 2, 3]),
        floatParam(1062, [1065, 1066, 1067, 1068], [2, 3, 4, 5])
    ]

    private static let busBalances: [FloatParam] = [
        floatParam(1356, [1354, 1355, 1357, 1358], [3, 2, 0, 1]),
        floatParam(1356, [1354, 1355, 1357, 1358], [3, 2, 0, 1]),
        floatParam(1356, [1354, 1355, 1357, 1358], [3, 2, 0, 1]),
        floatParam(1356, [1354, 1355, 1357, 1358], [3, 2, 0, 1]),
        floatParam(1356, [1354, 1355, 1357, 1358], [3, 2, 0, 1])
    ]

    /// Rust only has three limiter parameters (Main, Mon1, Mon2);
    /// `has_limiter()` is false for the two FX buses.
    private static let busLimiters: [FloatParam] = [
        floatParam(2889, [2885, 2886, 2887, 2888], [5, 4, 3, 2]),
        floatParam(2306, [2302, 2303, 2304, 2305], [5, 4, 3, 2]),
        floatParam(2423, [2419, 2420, 2421, 2422], [5, 4, 3, 2])
    ]

    // MARK: - Nine-band bus EQ tables
    //
    // Per bus: Main(0), Mon1(1), Mon2(2), FX1(3), FX2(4).
    // Mon2 shares SysEx memory with Mon1, so its ranges may appear narrower.
    // In Rust, apply_nine_band_eq() skips FX buses via has_nine_band_eq(),
    // but the offsets exist for all five buses in the reference tables.

    private static let nineBand62Hz: [FloatParam] = [
        floatParam(2889, [2890, 2891, 2892, 2893], [0, 1, 2, 3]),
        floatParam(2308, [2306, 2307, 2309, 2310], [3, 2, 0, 1]),
        floatParam(2420, [2423, 2424, 2425, 2426], [2, 3, 4, 5]),
        floatParam(2889, [2890, 2891, 2892, 2893], [0, 1, 2, 3]),
        floatParam(2889, [2890, 2891, 2892, 2893], [0, 1, 2, 3])
    ]

    private static let nineBand125Hz: [FloatParam] = [
        floatParam(2896, [2894, 2895, 2897, 2898], [3, 2, 0, 1]),
        floatParam(2308, [2311, 2312, 2313, 2314], [2, 3, 4, 5]),
        floatParam(2427, [2428, 2429, 2430, 2431], [0, 1, 2, 3]),
        floatParam(2896, [2894, 2895, 2897, 2898], [3, 2, 0, 1]),
        floatParam(2896, [2894, 2895, 2897, 2898], [3, 2, 0, 1])
    ]

    private static let nineBand250Hz: [FloatParam] = [
        floatParam(2896, [2899, 2900, 2901, 2902], [2, 3, 4, 5]),
        floatParam(2315, [2316, 2317, 2318, 2319], [0, 1, 2, 3]),
        floatParam(2434, [2432, 2433, 2435, 2436], [3, 2, 0, 1]),
        floatParam(2896, [2899, 2900, 2901, 2902], [2, 3, 4, 5]),
        floatParam(2896, [2899, 2900, 2901, 2902], [2, 3, 4, 5])
    ]

    private static let nineBand500Hz: [FloatParam] = [
        floatParam(2903, [2904, 2905, 2906, 2907], [0, 1, 2, 3]),
        floatParam(2322, [2320, 2321, 2323, 2324], [3, 2, 0, 1]),
        floatParam(2434, [2437, 2438, 2439, 2440], [2, 3, 4, 5]),
        floatParam(2903, [2904, 2905, 2906, 2907], [0, 1, 2, 3]),
        floatParam(2903, [2904, 2905, 2906, 2907], [0, 1, 2, 3])
    ]

    private static let nineBand1kHz: [FloatParam] = [
        floatParam(2910, [2908, 2909, 2911, 2912], [3, 2, 0, 1]),
        floatParam(2322, [2325, 2326, 2327, 2328], [2, 3, 4, 5]),
        floatParam(2441, [2442, 2443, 2444, 2445], [0, 1, 2, 3]),
        floatParam(2910, [2908, 2909, 2911, 2912], [3, 2, 0, 1]),
        floatParam(2910, [2908, 2909, 2911, 2912], [3, 2, 0, 1])
    ]

    private static let nineBand2kHz: [FloatParam] = [
        floatParam(2910, [2913, 2914, 2915, 2916], [2, 3, 4, 5]),
        floatParam(2329, [2330, 2331, 2332, 2333], [0, 1, 2, 3]),
        floatParam(2448, [2446, 2447, 2449, 2450], [3, 2, 0, 1]),
        floatParam(2910, [2913, 2914, 2915, 2916], [2, 3, 4, 5]),
        floatParam(2910, [2913, 2914, 2915, 2916], [2, 3, 4, 5])
    ]

    private static let nineBand4kHz: [FloatParam] = [
        floatParam(2917, [2918, 2919, 2920, 2921], [0, 1, 2, 3]),
        floatParam(2336, [2334, 2335, 2337, 2338], [3, 2, 0, 1]),
        floatParam(2448, [2451, 2452, 2453, 2454], [2, 3, 4, 5]),
        floatParam(2917, [2918, 2919, 2920, 2921], [0, 1, 2, 3]),
        floatParam(2917, [2918, 2919, 2920, 2921], [0, 1, 2, 3])
    ]

    private static let nineBand8kHz: [FloatParam] = [
        floatParam(2924, [2922, 2923, 2925, 2926], [3, 2, 0, 1]),
        floatParam(2336, [2339, 2340, 2341, 2342], [2, 3, 4, 5]),
        floatParam(2455, [2456, 2457, 2458, 2459], [0, 1, 2, 3]),
        floatParam(2924, [2922, 2923, 2925, 2926], [3, 2, 0, 1]),
        floatParam(2924, [2922, 2923, 2925, 2926], [3, 2, 0, 1])
    ]

    private static let nineBand16kHz: [FloatParam] = [
        floatParam(2924, [2927, 2928, 2929, 2930], [2, 3, 4, 5]),
        floatParam(2343, [2344, 2345, 2346, 2347], [0, 1, 2, 3]),
        floatParam(2462, [2460, 2461, 2463, 2464], [3, 2, 0, 1]),
        floatParam(2924, [2927, 2928, 2929, 2930], [2, 3, 4, 5]),
        floatParam(2924, [2927, 2928, 2929, 2930], [2, 3, 4, 5])
    ]

    private static let nineBandTables: [[FloatParam]] = [
        nineBand62Hz, nineBand125Hz, nineBand250Hz,
        nineBand500Hz, nineBand1kHz, nineBand2kHz,
        nineBand4kHz, nineBand8kHz, nineBand16kHz
    ]

    // MARK: - Boolean parameter tables (single 0x00/0x01 byte)

    private static let channelMutes: [BoolParam] = [
        BoolParam(offset: 0x04CC, inverted: false),
        BoolParam(offset: 0x04CD, inverted: false),
        BoolParam(offset: 0x04CF, inverted: false),
        BoolParam(offset: 0x04D0, inverted: false),
        BoolParam(offset: 0x04D1, inverted: false),
        BoolParam(offset: 0x04D2, inverted: false),
        BoolParam(offset: 0x04D3, inverted: false)
    ]

    private static let channelSolos: [BoolParam] = [
        BoolParam(offset: 0x04DF, inverted: false),
        BoolParam(offset: 0x04E0, inverted: false),
        BoolParam(offset: 0x04E1, inverted: false),
        BoolParam(offset: 0x04E2, inverted: false),
        BoolParam(offset: 0x04E4, inverted: false),
        BoolParam(offset: 0x04E5, inverted: false),
        BoolParam(offset: 0x04E6, inverted: false)
    ]

    /// Only XLR channels 1 and 2 have phantom power.
    private static let channelPhantoms: [BoolParam] = [
        BoolParam(offset: 0x0737, inverted: false),
        BoolParam(offset: 0x0778, inverted: false)
    ]

    // MARK: - FX parameters (plain byte offsets)

    private static let fxLayouts: [FXLayout] = [
        FXLayout(param1Offset: 3013, param2Offset: 3014, presetOffset: 3017),
        FXLayout(param1Offset: 3021, param2Offset: 3023, presetOffset: 3025)
    ]

    /// Index of the USB-BT channel; it has no gain, compressor or low cut.
    private static let usbBTIndex = 6

    // MARK: - Public entry point

    /// Returns `nil` if the data is not a valid FLOW 8 SysEx dump.
    static func parse(_ data: Data) -> DumpSnapshot? {
        let bytes = [UInt8](data)
        guard validateDump(bytes) else { return nil }

        var snapshot = DumpSnapshot()
        snapshot.names = applyChannelNames(bytes)
        snapshot.levels = applyChannelLevels(bytes)
        snapshot.gains = applyChannelGains(bytes)
        snapshot.pans = applyChannelPans(bytes)
        snapshot.comps = applyChannelCompressors(bytes)
        snapshot.lowCuts = applyChannelLowCuts(bytes)
        snapshot.eqs = applyChannelEQs(bytes)
        snapshot.sends = applyChannelSends(bytes)
        snapshot.mutes = applyChannelMutes(bytes)
        snapshot.solos = applyChannelSolos(bytes)
        snapshot.phantoms = applyChannelPhantoms(bytes)
        snapshot.busLevels = applyBusLevels(bytes)
        snapshot.busBalances = applyBusBalances(bytes)
        snapshot.busLimiters = applyBusLimiters(bytes)
        snapshot.busEQs = applyNineBandEQs(bytes)
        snapshot.fx = applyFxStates(bytes)
        return snapshot
    }

    // MARK: - Validation

    /// Mirrors the Rust `validate_sysex_dump()`: size, F0/F7 framing,
    /// Behringer manufacturer ID and FLOW 8 model byte.
    private static func validateDump(_ data: [UInt8]) -> Bool {
        guard data.count >= minDumpSize else { return false }
        guard data[0] == sysexStart else { return false }
        guard data[data.count - 1] == sysexEnd else { return false }
        guard Array(data[1..<4]) == behringerID else { return false }
        guard data[4] == flow8Model else { return false }
        return true
    }

    // MARK: - Low-level decoding

    /// Restores bit 7 of `data[pos]` from the rotating MSB byte, exactly like
    /// the Rust `restore_sysex_byte()`. Returns `nil` for bytes that carry an
    /// MSB byte themselves (or that are out of bounds).
    private static func restoreSysExByte(_ data: [UInt8], at pos: Int) -> UInt8? {
        guard pos >= 0, pos < data.count else { return nil }
        let groupPos = (pos + 2) % 7
        if groupPos == 0 { return nil }          // this position *is* an MSB byte
        if pos < groupPos { return data[pos] }    // no MSB byte exists yet
        let msbOffset = pos - groupPos
        if msbOffset >= data.count { return data[pos] }
        let msb = data[msbOffset]
        let bitIndex = groupPos - 1
        var value = data[pos]
        if (msb >> UInt8(bitIndex)) & 1 != 0 {
            value |= 0x80
        }
        return value
    }

    /// Decodes a channel name: restore the 14 scanned bytes, skip leading
    /// control bytes, stop at the first NUL and decode as (lossy) UTF-8.
    private static func decodeName(_ data: [UInt8], start: Int) -> String {
        let end = min(start + nameScanLen, data.count)
        var restored: [UInt8] = []
        if start < end {
            for pos in start..<end {
                if let byte = restoreSysExByte(data, at: pos) {
                    restored.append(byte)
                }
            }
        }

        let nameStart = restored.firstIndex(where: { $0 >= 0x20 }) ?? restored.count
        let tail = restored[nameStart...]
        let nameEnd = tail.firstIndex(of: 0x00) ?? restored.endIndex
        let rawBytes = Array(restored[nameStart..<nameEnd])
        // `String(decoding:as:)` substitutes U+FFFD for invalid sequences,
        // matching Rust's `String::from_utf8_lossy`.
        return String(decoding: rawBytes, as: UTF8.self)
    }

    /// Decodes a 5-byte packed float (little-endian IEEE-754 binary32).
    /// Returns `nil` on out-of-bounds offsets or non-finite values.
    private static func decodeFloat(_ data: [UInt8], _ param: FloatParam) -> Float? {
        guard param.dataOffsets.count == 4, param.bitIndices.count == 4 else { return nil }
        guard let maxOffset = param.dataOffsets.max() else { return nil }
        guard param.msbOffset >= 0, maxOffset < data.count,
              param.msbOffset < data.count else { return nil }

        let msb = data[param.msbOffset]
        var bits: UInt32 = 0
        for i in 0..<4 {
            var byte = data[param.dataOffsets[i]]
            if (msb >> param.bitIndices[i]) & 1 != 0 {
                byte |= 0x80
            }
            bits |= UInt32(byte) << (8 * i)
        }

        let value = Float(bitPattern: bits)
        guard value.isFinite else { return nil }
        return value
    }

    private static func decodeLowCut(_ data: [UInt8], _ param: LowCutParam) -> UInt16? {
        guard param.loOffset >= 0, param.hiOffset >= 0,
              param.loOffset < data.count, param.hiOffset < data.count else { return nil }
        return UInt16(data[param.loOffset]) + UInt16(data[param.hiOffset]) * 128
    }

    // MARK: - Value conversions (mirrors Rust)

    /// -70...+10 dB -> CC 1...127, anything below -70 dB -> CC 0 (OFF).
    private static func dbToCC(_ db: Float) -> Int {
        if db < levelDBMin { return 0 }
        let clamped = min(max(db, levelDBMin), levelDBMax)
        let cc = 1.0 + ((clamped - levelDBMin) / (levelDBMax - levelDBMin)) * 126.0
        return Int(min(max(cc.rounded(), 0.0), 127.0))
    }

    /// Linear range mapping used for gain, pan/balance, EQ and limiter.
    private static func rangeToCC(_ value: Float, _ lower: Float, _ upper: Float) -> Int {
        let clamped = min(max(value, lower), upper)
        let normalized = (clamped - lower) / (upper - lower)
        return Int((normalized * 127.0).rounded())
    }

    /// Rust maps low cut linearly in Hz (20...600 Hz -> CC 0...127).
    private static func lowCutHzToCC(_ hz: UInt16) -> Int {
        let clamped = min(max(hz, lowCutMinHz), lowCutMaxHz)
        let ratio = Float(clamped - lowCutMinHz) / Float(lowCutMaxHz - lowCutMinHz)
        return Int((ratio * 127.0).rounded())
    }

    // MARK: - Channel groups

    private static func applyChannelNames(_ data: [UInt8]) -> [String] {
        var names = [String](repeating: "", count: 7)
        for i in 0..<7 {
            let offset = namesStart + i * namesStride
            guard offset + nameScanLen <= data.count else { continue }
            names[i] = decodeName(data, start: offset)
        }
        return names
    }

    private static func applyChannelLevels(_ data: [UInt8]) -> [Int] {
        var values = [Int](repeating: 0, count: 7)
        for (i, param) in channelLevels.enumerated() {
            if let db = decodeFloat(data, param) {
                values[i] = dbToCC(db)
            }
        }
        return values
    }

    private static func applyChannelGains(_ data: [UInt8]) -> [Int] {
        var values = [Int](repeating: 0, count: 7)
        for i in 0..<min(channelGains.count, usbBTIndex) {   // Rust: has_gain()
            if let db = decodeFloat(data, channelGains[i]) {
                values[i] = rangeToCC(db, gainMin, gainMax)
            }
        }
        return values
    }

    private static func applyChannelPans(_ data: [UInt8]) -> [Int] {
        var values = [Int](repeating: 64, count: 7)
        for (i, param) in channelPans.enumerated() {
            if let value = decodeFloat(data, param) {
                values[i] = rangeToCC(value, panMin, panMax)
            }
        }
        return values
    }

    private static func applyChannelCompressors(_ data: [UInt8]) -> [Int] {
        var values = [Int](repeating: 0, count: 7)
        for i in 0..<min(channelCompressors.count, usbBTIndex) {  // Rust: has_compressor()
            if let value = decodeFloat(data, channelCompressors[i]) {
                let clamped = min(max(value, compMin), compMax)
                values[i] = Int((clamped * 100.0).rounded())
            }
        }
        return values
    }

    private static func applyChannelLowCuts(_ data: [UInt8]) -> [Int] {
        var values = [Int](repeating: 0, count: 7)
        for i in 0..<min(channelLowCuts.count, usbBTIndex) {      // Rust: has_low_cut()
            if let hz = decodeLowCut(data, channelLowCuts[i]) {
                values[i] = lowCutHzToCC(hz)
            }
        }
        return values
    }

    /// Four bands per channel: low, low-mid, hi-mid, high (-15...+15 dB).
    private static func applyChannelEQs(_ data: [UInt8]) -> [[Int]] {
        var values = [[Int]](repeating: [Int](repeating: 64, count: 4), count: 7)
        let bands: [[FloatParam]] = [channelEQLow, channelEQLowMid, channelEQHiMid, channelEQHi]

        for (bandIndex, bandParams) in bands.enumerated() {
            for (channelIndex, param) in bandParams.enumerated() {
                guard channelIndex < values.count, bandIndex < 4 else { continue }
                if let db = decodeFloat(data, param) {
                    values[channelIndex][bandIndex] = rangeToCC(db, eqMin, eqMax)
                }
            }
        }
        return values
    }

    /// Four sends per channel: Mon1, Mon2, FX1, FX2 (level / dB mapping).
    private static func applyChannelSends(_ data: [UInt8]) -> [[Int]] {
        var values = [[Int]](repeating: [Int](repeating: 0, count: 4), count: 7)
        let sends: [[FloatParam]] = [channelSendMon1, channelSendMon2, channelSendFX1, channelSendFX2]

        for (sendIndex, sendParams) in sends.enumerated() {
            for (channelIndex, param) in sendParams.enumerated() {
                guard channelIndex < values.count, sendIndex < 4 else { continue }
                if let db = decodeFloat(data, param) {
                    values[channelIndex][sendIndex] = dbToCC(db)
                }
            }
        }
        return values
    }

    private static func applyChannelMutes(_ data: [UInt8]) -> [Bool] {
        boolValues(data, channelMutes)
    }

    private static func applyChannelSolos(_ data: [UInt8]) -> [Bool] {
        boolValues(data, channelSolos)
    }

    private static func applyChannelPhantoms(_ data: [UInt8]) -> [Bool] {
        var values = [Bool](repeating: false, count: 7)
        for (i, param) in channelPhantoms.enumerated() where i < values.count {
            guard param.offset < data.count else { continue }
            let raw = data[param.offset]
            values[i] = param.inverted ? raw == 0x00 : raw != 0x00
        }
        return values
    }

    private static func boolValues(_ data: [UInt8], _ params: [BoolParam]) -> [Bool] {
        var values = [Bool](repeating: false, count: 7)
        for (i, param) in params.enumerated() where i < values.count {
            guard param.offset < data.count else { continue }
            let raw = data[param.offset]
            values[i] = param.inverted ? raw == 0x00 : raw != 0x00
        }
        return values
    }

    // MARK: - Bus groups

    private static func applyBusLevels(_ data: [UInt8]) -> [Int] {
        var values = [Int](repeating: 0, count: 5)
        for (i, param) in busLevels.enumerated() where i < values.count {
            if let db = decodeFloat(data, param) {
                values[i] = dbToCC(db)
            }
        }
        return values
    }

    /// Only the Main bus exposes a balance in the Rust controller, but the
    /// reference table carries offsets for all five buses, so all are decoded.
    private static func applyBusBalances(_ data: [UInt8]) -> [Int] {
        var values = [Int](repeating: 64, count: 5)
        for (i, param) in busBalances.enumerated() where i < values.count {
            if let value = decodeFloat(data, param) {
                values[i] = rangeToCC(value, balanceMin, balanceMax)
            }
        }
        return values
    }

    /// Rust only has three limiter parameters (Main, Mon1, Mon2). The two FX
    /// buses keep the neutral default of 127 (0 dB, limiter off).
    private static func applyBusLimiters(_ data: [UInt8]) -> [Int] {
        var values = [Int](repeating: 127, count: 5)
        for (i, param) in busLimiters.enumerated() where i < values.count {
            if let value = decodeFloat(data, param) {
                values[i] = rangeToCC(value, limiterMin, limiterMax)
            }
        }
        return values
    }

    /// 9 bands per bus, band-major tables flattened into `[bus][band]`.
    private static func applyNineBandEQs(_ data: [UInt8]) -> [[Int]] {
        var values = [[Int]](repeating: [Int](repeating: 64, count: 9), count: 5)
        for (bandIndex, bandParams) in nineBandTables.enumerated() {
            for (busIndex, param) in bandParams.enumerated() {
                guard busIndex < values.count, bandIndex < 9 else { continue }
                if let db = decodeFloat(data, param) {
                    values[busIndex][bandIndex] = rangeToCC(db, eqMin, eqMax)
                }
            }
        }
        return values
    }

    // MARK: - FX slots

    /// FX slots are stored with a 1-based preset byte (1...16), a percent
    /// parameter byte and a boolean flag byte. Rust converts the parameter
    /// bytes with `byte * 127 / 100` for its CC-based state; here we keep the
    /// native percent value (`param1`) and apply the same conversion only to
    /// derive the on/off flag, matching `FxSlot::param2_is_on` (CC > 63).
    private static func applyFxStates(_ data: [UInt8]) -> [FXSlotState] {
        var slots: [FXSlotState] = []
        for (i, layout) in fxLayouts.enumerated() {
            var slot = FXSlotState(id: i, preset: 1, param1: 50, param2: false)

            if layout.presetOffset < data.count {
                let raw = Int(data[layout.presetOffset])
                if raw >= 1 && raw <= 16 {
                    slot.preset = raw
                }
            }
            if layout.param1Offset < data.count {
                slot.param1 = min(Int(data[layout.param1Offset]), 100)
            }
            if layout.param2Offset < data.count {
                slot.param2 = data[layout.param2Offset] != 0
            }

            slots.append(slot)
        }
        return slots
    }
}
