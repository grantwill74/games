-- title:   Magispells
-- author:  Grant Williams
-- desc:    A word-spelling puzzle game. Inspired by Bookworm.
-- site:    grantwilliams.info/games
-- license: AGPL-3.0-or-later
-- version: 0.5
-- script:  lua
-- input: mouse
-- saveid: Magispells_Save0

-- see here for annotation language: https://luals.github.io/wiki/annotations/

---------------------------- System constants ----------------------------------

SAVEID = 'Magispells s1'

TAU = math.pi * 2
SCREEN_W_px = 240
SCREEN_H_px = 136
TILE_W_px = 8
TILE_H_px = 8
MAX_WORD_LEN = 8
MIN_WORD_LEN = 3
SUB_STATE_DELAY = 30
SUBMIT_DELAY_TICKS = 60

LETTER_TILE_W_px = TILE_W_px * 2
LETTER_TILE_H_px = TILE_H_px * 2

IDEAL_VOWEL_PROP = 0.2

---@type integer
SCREEN_W_tiles = SCREEN_W_px / TILE_W_px
---@type integer
SCREEN_H_tiles = SCREEN_H_px / TILE_H_px

DebugMode = false
CheatMode = false

N_HIGH_SCORES = 10
HIGH_SCORE_PMEM_ADDR = 0
HIGH_SCORE_STRIDE = 4

---@class Highscore
---@field points integer
---@field level integer
---@field nTicks integer
---@field bestWord string
---@field bestWordScore integer
Highscore = {}

---@param points integer
---@param level integer
---@param ticks integer
---@param bestWord string
---@param bestWordScore integer
---@return Highscore
function Highscore.new(points, level, ticks, bestWord, bestWordScore)
    return setmetatable({
        points = points,
        level = level,
        nTicks = ticks,
        bestWord = bestWord,
        bestWordScore = bestWordScore,
    }, {__index = Highscore})
end

---pack highscore into two integers for saving to persistent memory
---@return [integer, integer, integer, integer]
function Highscore:pack()
    --- points gets a whole integer. ticks and levels share a 24-bit and 8-bit
    --- field within a 32-bit word. 24-bits of ticks is ~77 hours of gameplay,
    --- which should be more than enough, because the goal is for time to be low
    --- rather than high.
    local points = math.min(self.points, 0xFFFFFFFF)
    local ticks = math.min(self.nTicks, 0xFFFFFF)
    local level = math.min(self.level, 0xFF)
    local level_ticks = (ticks << 8) | level

    -- in theory we could store words as integers using the Dawg to enumerate
    -- them. It's a cool idea, but it seems easier to store the letters.
    -- Especially because I keep adding and removing words from the Dawg, and 
    -- it would be nice if doing that wouldn't break the high scores.

    --- packing letters: 
    --- words have between 3 and 8 letters, and an optional '!' at the end
    --- encode each letter as an 5-bit integer. 0 means no letter, 1 is a, 26 is z.
    --- the exclamation point is a single bit in the last packed word. 
    --- the lower 4 bits of each letter are in Word 3, first letter in MSB.
    --- the MSB byte of word 4 is the upper bit of each letter.
    --- The next bit is whether there's an exclamation point
    --- the next 7 bits are unused
    --- the lower 16 bits are word score
    --- Diagram, assume word is ABCDEFGH!:
    --- word 3: hhhhggggffffeeeeddddccccbbbbaaaa
    --- word 4: HGFEDCBA!0000000SSSSSSSSSSSSSSSS

    ---@type integer
    local word3 = 0
    local word4 = 0
    for i=1, 8 do
        if self.bestWord:sub(i, i) == '!' then break end

        local c = self.bestWord:byte(i, i)
        if not c then break end
        c = c - ('a'):byte(1, 1) + 1

        -- assert(c > 0 and c < 27)

        word3 = word3 | ((c & 0xf) << (i - 1) * 4)
        word4 = word4 | (((c >> 4) & 1) << (24 + i - 1))
    end
    
    -- handle '!'
    if self.bestWord:sub(#self.bestWord, #self.bestWord) == '!' then
        word4 = word4 | (1 << 23)
    end

    -- load score into word4
    local score = math.min(self.bestWordScore, 0xFFFF)
    word4 = word4 | score

    return {points, level_ticks, word3, word4}
end

---see Highscore:pack() for info on how highscores are stored in persistent
---memory.
---@param data [integer, integer, integer, integer]
function Highscore.unpack(data)
    local points = data[1]
    local level = data[2] & 0xFF
    local ticks = data[2] >> 8
    local word3 = data[3]
    local word4 = data[4]
    local letters = {}

    for i=1, 8 do
        local lo = (word3 >> ((i - 1) * 4)) & 0xF
        local hi = (word4 >> (24 + i - 1)) & 1
        local enc = (hi << 4) | lo
        if enc == 0 then break end
        local c = string.char(enc - 1 + ('a'):byte())
        table.insert(letters, c)
    end

    if word4 & (1 << 23) > 0 then
        table.insert(letters, '!')
    end

    local hsWord = table.concat(letters)
    local wordScore = word4 & 0xFFFF

    local score = Highscore.new(points, level, ticks, hsWord, wordScore)
    return score
end

--- returns the points, time, and level as strings
---@return string, string, string
function Highscore:toStr()
    local points, time, level

    if self.points == math.maxinteger then
        points = "Tons!"
    else
        points = tostring(self.points)
    end

    if self.nTicks == 0xFFFFFF then
        time = "Long!"
    else
        time = tostring(self.nTicks)
    end

    if self.level == 0xFF then
        level = "High!"
    else
        level = tostring(self.level)
    end

    return points, time, level
end

---determine whether the given score is high enough to go in the table. if so,
---save it and push the other scores down, cutting off the lowest.
---@param hs Highscore
---@returns interger|nil # final rank (1-based) or nil
function SaveHighScoreIfHighEnough(hs)
    if hs.points <= 0 then return nil end

    local i = 0
    while i < N_HIGH_SCORES do
        local which = pmem(HIGH_SCORE_PMEM_ADDR + HIGH_SCORE_STRIDE * i)
        if which < hs.points then
            break
        end
        i = i + 1
    end

    if i >= N_HIGH_SCORES then return nil end
    local saveTo = i

    -- overwrite the highscores below to make room
    for i=(N_HIGH_SCORES - 1), saveTo + 1, -1 do
        local base = HIGH_SCORE_PMEM_ADDR + HIGH_SCORE_STRIDE * i
        for j=0, (HIGH_SCORE_STRIDE - 1) do
            local dest = base + j
            local value = pmem(dest - HIGH_SCORE_STRIDE)
            pmem(dest, value)
        end
    end

    -- save the high score
    local packed = hs:pack()
    for j = 0, (HIGH_SCORE_STRIDE - 1) do
       pmem(HIGH_SCORE_PMEM_ADDR + HIGH_SCORE_STRIDE * saveTo + j, packed[j + 1])
    end
    return saveTo + 1
end

function ClearHighScores()
    for i=0, (N_HIGH_SCORES - 1) * HIGH_SCORE_STRIDE do
        pmem(HIGH_SCORE_PMEM_ADDR + i, 0)
    end
end

---@return Highscore[]
function LoadHighScores()
    local hs = {}

    for i=0, (N_HIGH_SCORES - 1) do
        local data = {}
        for j=0, (HIGH_SCORE_STRIDE - 1) do
            local word = pmem(HIGH_SCORE_PMEM_ADDR + i * HIGH_SCORE_STRIDE + j)
            table.insert(data, word)
        end
        local unpacked = Highscore.unpack(data)

        if unpacked.points == 0 then break end

        table.insert(hs, unpacked)
    end

    return hs
end



PALETTE_ADDR = 0x3FC0

---default palette colors
PALETTE = {
    BLACK = 0,
    PURPLE = 1,
    RED = 2,
    ORANGE = 3,
    YELLOW = 4,
    LIME = 5,
    GREEN = 6,
    TEAL = 7,
    NAVY = 8,
    BLUE = 9,
    SKY = 10,
    CYAN = 11,
    WHITE = 12,
    LT_GRAY = 13,
    MID_GRAY = 14,
    DK_GRAY = 15,
}

-- TODO: there's other code that messes with the palette that should be refactored
-- to use this function

---Set the color in the palette
---@param palIndex integer
---@param color PalEntry
function PokePalColor(palIndex, color)
    local addr = PALETTE_ADDR + palIndex * 3
    poke(addr, color.r)
    poke(addr + 1, color.g)
    poke(addr + 2, color.b)
end

---@param palIndex integer
---@return PalEntry
function PeekPalColor(palIndex)
    local addr = PALETTE_ADDR + palIndex * 3
    local r = peek(addr)
    local g = peek(addr + 1)
    local b = peek(addr + 2)
    return { r = r, g = g, b = b }
end


---@type Rgb[]
DefaultPalette = {}
for i = 0, 15 do
    local color = PeekPalColor(i)
    table.insert(DefaultPalette, color)
end

---these colors cycle in vbank 2
CYCLE_COLORS = {
    PALETTE.LIME,
    PALETTE.GREEN,
    PALETTE.CYAN,
    PALETTE.SKY,
}

---@alias Rgb {r: integer, g: integer, b: integer}

---the color at which this palette entry is dimmest
---@type table<integer, Rgb>
CYCLE_LOW_COLOR = {}
CYCLE_LOW_COLOR[5] = {r = 0x81, g = 0xBE, b = 0x5D}
CYCLE_LOW_COLOR[6] = {r = 0x1C, g = 0x7D, b = 0x2C}
CYCLE_LOW_COLOR[10] = {r = 0x30, g = 0x51, b = 0x95}
CYCLE_LOW_COLOR[11] = {r = 0x3C, g = 0xcA, b = 0xDA}

---the color at which this palette entry is brightest
---@type table<integer, Rgb>
CYCLE_HIGH_COLOR = {}
CYCLE_HIGH_COLOR[5] = {r = 0xB7, g = 0xFF, b = 0x80}
CYCLE_HIGH_COLOR[6] = {r = 0x38, g = 0xB7, b = 0x64}
CYCLE_HIGH_COLOR[10] = {r = 0x41, g = 0xBA, b = 0xFF}
CYCLE_HIGH_COLOR[11] = {r = 0x73, g = 0xEF, b = 0xFF}

---how long it takes to complete a color cycle in tics
CYCLE_COLOR_TICS = 60 * 2 -- 4 seconds

---@type integer
ColorCyclePhase = 0

TAU = 2 * math.pi

---@param lo Rgb
---@param hi Rgb
---@param phase number
---@return Rgb
function CycleCurColor(lo, hi, phase)
    local t = phase / CYCLE_COLOR_TICS * TAU
    local cos = math.cos(t)
    local alpha = (cos + 1) / 2
    local result = {
        r = math.floor(0.5 + lo.r + (hi.r - lo.r) * alpha),
        g = math.floor(0.5 + lo.g + (hi.g - lo.g) * alpha),
        b = math.floor(0.5 + lo.b + (hi.b - lo.b) * alpha),
    }

    return result
end


CHANCE_TO_DRAW_CHARGED = 0.15

--- The number of regex entries to be processed before yielding (i.e., to
--- update the loading screen)
---@type integer
LOAD_STATES_PER_YIELD = 2100

--- The number of times we expect to yield before loading is complete. This 
--- number is the denominator in the loading progress.
---@type integer
EXPECTED_N_YIELDS_TO_LOAD = 9

---@type table<string, integer>
LETTER_SPRITES = {
    a = 384, b = 386, c = 388, d = 390, e = 392, f = 394, g = 396, h = 398,
    i = 416, j = 418, k = 420, l = 422, m = 424, n = 426, o = 428, p = 430,
    q = 448, r = 450, s = 452, t = 454, u = 456, v = 458, w = 460, x = 462,
    y = 480, z = 482, -- ex = 484,
}
LETTER_SPRITES['!'] = 484

SFX_CHANNEL = 3
SFX = {
    tileSelect = 48,
    tileDeselect = 49,
    levelUp = 50,
    gameOver = 51,
    badWord = 52,
    goodWord = 53,
    bestWord = 54,
    cant = 55,
    blockBreak = 56,
    clearData = 57,
}



TILE_ELEMENTS = {
    normal = 494,
    charged = 492,
    frozen = 490,
}

TILE_HILITE = 488
TILE_SELECTED = 486

LETTER_CHROMAKEY = PALETTE.WHITE

---@type table<string, number>
LETTER_FREQ = {
    a = .078, b = .020, c = .040, d = .038, e = .110, f = .014, g = .030,
    h = .023, i = .086, j = .0025,k = .0097,l = .053, m = .027, n = .072,
    o = .061, p = .028, q = .0019,r = .073, s = .087, t = .067, u = .033,
    v = .010, w = .0091,x = .0027,y = .016, z = .0044, -- ex= .001
}

VOWEL_SPAWN_RATE = {
    a = .2,
    e = .2,
    i = .2,
    o = .2,
    u = .2,
}

CONSONANT_SPAWN_RATE = {
    b = .033,
    c = .063,
    d = .061,
    f = .023,
    g = .048,
    h = .037,
    j = .005,
    k = .016,
    l = .084,
    m = .044,
    n = .114,
    p = .045,
    q = .004,
    r = .116,
    s = .138,
    t = .106,
    v = .017,
    w = .015,
    x = .005,
    y = .026,
}

CONSONANT_SPAWN_RATE['!'] = .01 -- it's not a consonant, but we want it to spawn
LETTER_FREQ['!'] = .01

---@type table<string, boolean>
VOWEL = {
    a = true,
    e = true,
    i = true,
    o = true,
    u = true,
}

---@type [string, number][]
LetterDraw = {}
---@type [string, number][]
VowelDraw = {}
---@type [string, number][]
ConsonantDraw = {}

for letter, freq in pairs(LETTER_FREQ) do
    table.insert(LetterDraw, {letter, freq})
end
for letter, freq in pairs(VOWEL_SPAWN_RATE) do
    table.insert(VowelDraw, {letter, freq})
end
for letter, freq in pairs(CONSONANT_SPAWN_RATE) do
    table.insert(ConsonantDraw, {letter, freq})
end


LETTER_SCORE = {
    a = 1, b = 4, c = 2, d = 3, e = 1, f = 4, g = 3, h = 4, i = 1,
    j = 20,k = 5, l = 2, m = 3, n = 1, o = 2, p = 4,q = 20, r = 1,
    s = 1, t = 1, u = 2, v = 6, w = 6,x = 20, y = 6,z = 10, -- ex= 80
}
LETTER_SCORE['!'] = 8

WORD_SCORE_MULT = 10
CHARGE_SCORE_MULT = 4

---@type string
Dawg =
"!;!s0;g0;e0;d0;s0;n2;y0;t0;n0;!d0s0;e1;l0;r0;t1;g1;n1;h0;r1;c0;m0;d0r1;!e4s0;s5;a0;eA;a1;r0s8;l3;l1;e4;!e5;t3;nF;e17;!d0r1s0;d0s0;d1;d0r0;eD;!e4i6s0;u5;k0;e5;eAi6;i13;a9e9;!s0y0;n8;n3;k1;!d0r0s0;m1;o9;s3;uC;e12;!e26s0;!l7;s11;o1;aC;!t0;t7;r7;o0;y1;eDn2;e23i6;p0;i4;!e15i6s0;e33;r3;h1;g3;i9;b1C;s1F;e0y0;s8;r4;!e0;i0;c2A;i18;o10;p1;i2By0;n4;i1;e9;lB;i10;i5;!l7s0;c11;a9;a20;e30;!i6;c3;e1Bn2;d0r1s0;!e24;d3;aD;w0;e8;x0;r16;m3;!i13s0;c32;lC;e24;g7;!l0;eE;u14;!y0;d0r0s0;e4i6;l4F;i6;c1;!e0s0;gB;a7;r14;!d0;i20;t16;!e1s0;n2s11;i31;tB;e1D;o14;a10;r2F;!e4s0y0;e1B;nB;nE;eDl7n2;w1;!aCs0;k3;a8;s14;h8;a4;m0t0;a51;a12;h68;o4;!e5s0;i45;l18;eC;!r0s0;e10;r25;o8;l4;a42;o74;!n0s0;a14;e15i6;v3;e1n2;!e24i6;t11;iE;f0;h1F;r0s3E;oD;i3B;e82;o29;rB;sE;n25;a0c0;e1BnF;i35;iC;o81;d0r0s8;e5i5;u3;u1D;p3;r9;n7;t27;a0u14;e1Bl7n2;i13y0;u1;e5n2;a1D;i8;d0r2F;c8;i3F;e1i13;t2D;r1A;u8;l19;r2A;e3;n18;r8;iB;r18;aE;i1D;n2o9;!e26s0y0;oE;l7;o6B;n16;!n0;l16;s3u5;n8t3;b1;r0s0;o45;!s0t0;o9D;l1A;h3;!m2E;dB;i25;u0;eAy0;i73y0;e42;!r0;o31;n2o9v3;!e79;e8C;m18;a4A;e0m0t0;z0;m7;a54;i7D;!r1s0;d0r1t1;l3A;a30;m0t1;f1;a25;eAoD;d0r1s8;e98;!r0s3E;!r0s8;s3z3;n1A;o9v3;a59;!e4i6s0y0;uD;iBB;!e67i6;sB;d27;i77;e26;!e1;f7;i3D;!g0s0;n2D;i1A;oC5;h0m0;uB;d7;t19;e25;n39;i69;e6E;rE;s19;i0o0;uE;r39;!l7r0s8;i36;i3;n52;eDl7;o2A;o25;!e15i21s0;!h1s0;!e4l7s0;r10;d0t0;k16;hFA;!e4oDs0;o34;!d0i6s0;l1D;!h9F;a75u14;!l1s0;!e4i43s0y0;aE8;e17g1;t1E;a1e1;!g1s0;eB;eA2;d0r7;d0n0;e0i13;a72;!r7s0;g19;e1Bl7;d0e1r1;!s0t1;e0t0;o1C;!o6F;o54;v27;d0r0s3E;t1A;r55;d0r16;n65;!aC;s99;t39;o50;!a0s0;b0;!l0s0;s5t1;rAA;r3D;oD7;!eDs0;c19;o57;c0n0;t41;t18;eAi6y0;i96;g97;i1C;b7B;m1A;i27y0;x1F;s7;g5F;a50;!i6s0;eE5;l44;o46;nFs11;l0n0;o42;e1y0;oA6;a34;u34;r35;d0t1;d16;!d0r2Fs0;t2F;t4A;cE;e1Bl7nF;i21;l0t3;e5nF;aCeA;d0e0;e17g0;!eDl7;o41;h7;h78;e33y0;oC;!eD;aCe1;a0e0;iD;!e15i43s0y0;o49;!t38;aA4;i6D;!e4r7s0;!a0;yC;e18;c1C;!x0;l2C;u12;o7;o5;w9;o6F;cB;i61;i0u5;d0s5;n11E;b1A;f8;i111;o12;lB1;k1A;n149;e0i3F;e1E;p11;mB;e23i43y0;n2A;s0t0;a40;r1s0;!a1s0;e50;!i3Bs0;a52;eF7;!t27;u59;o32;!s0t3;!s0t1E;l1E;!e12i6s0;a57;o134;c3t0;a4B;a3B;k28;i54;e72;!l1Es0;!h0;n85;i32;h1A;!i2Bs0y0;e0m0;n5;u36;e1nF;o9E;u105;a36;!d0f37s0;a45;aBE;s122;lA8;aCe33;r32;r8D;r0t3;e90;u1A8;r40;o36;e79;o6D;l48;l5F;!e15f37i6s0;!s0x0;eA9;n93;n2s8;a31;c7;o40;c0s0;p1C;h27;t20;r19;i0o1;e1s11;aCe1i13;c0s14;l1C;!d0s0t1;lA0;rD8;!g0;c7t0;a11;o2;d0l1;i8F;r34;!d0n0s0;e49;!e0l0s0;h18;e23i6y0;!e5i5;!n1s0;h116;a71;iC8;d0n1r1s8;e7;!e4i91s0y0;lE;i94;t28;iBy0;e103;n1r0s8;o92;o1AD;l2D;z3;e4i6y0;d0n0r1;g9;i73y64;aCe5;s68;a5;s5E;!g1Es0;aDe1;!c0;iAC;r1s8;!i0s0;o8A;a6B;n2F;h2F;i57;e1n2s11;n2o10;i30;l8;e6A;!eAi6;n55;hAE;c4A;i18y0;c18;t5E;!e4;!t18;i1F2y0;e17y0;c3t1;!i3F;!e0r0s0;hB;tBD;!i69;!e0t3;oDA;n179;i49;s0t1;t13D;w16;t47;!i9s0;eAi43y0;a17;!aCe26s0;eA6;a4C;n70;p7;d0l1r1;r5;m16;e1i6;!e26l7s0;l25;t3C;a2;k53;n7E;o30;!e26oDs0;t26D;c7t1;!t3;e6D;a75;l35;!s1F;n60;!aCe4s0;g41;!i13;sFEz3;oA5;aF;!d0e1r1s0;i133y0;h3A;n2t0;a92;d0e0r0;eAt1;u1F7;gC2;n2s14;i142;t7E;!d0l7r0s3E;g3A;u49;m2F;i12;kB;aCu14;a65;s3t7z3;r53;l53;!i3Fl7;d1t1;m0s0;e24n2;e31;hE;l0r7;b3;e4y0;!d1s0;c0t3;t53;e0i0;a69;l198;p8;l2A;y16;wA9;!g7As0;e8y0;eB3n2;i1FE;d19;o3C;!e4f37i6s0;a1o1;!h0s0;!e4i21s0;e0o0;g11;d93;b16;r2D;o20;!eEs0;t70;!e4i66s0y0;!d0r1s0y0;w10;s99t7;n1E;i16D;i41;m1t1;a49;sFEt7z3;!e15i6s0y0;s5Et2D;pE;aBA;f3;aE9;c41;!o29s0;!e5y0;cEF;r45;m19;n2t1;!e79y0;m2E;eAiDF;!e4l7s0y0;d39;n2t7;d0e1;!s0t18;oC4;i72;l6A;y5;!l3s0;n53;e5B;!e8s0;d1C;o71;!o0;e15i6y0;e1g1;e3Ai3F;c15F;c0n2;i35o40;e3A;n32;c7t3;n2s122;c4Ft0;r36;!k1s0;r5A;o135;u19;d0r1y1;fB1;t38;a2A;oC6;o139;e15i21;p16;e17i94;l41;n2t3;d5F;u4E;l29;!d0e0r0s0;iBBy0;h2CF;n77;l232;tD2;lF4;l28;!k4C;!d0r1s0t1;e0g0;i27;!e0l0;u76;r41;!p7As0;e1A;!e24y0;eEAl7n2;eDn2s11;o5C;t60;k2F;n2v3;o35;t40;!e0r0;f16;k1E;e1F0;t12C;iAF;!e26i6s0;e61;l1t3;!eAi6s0;h5A;i1C0;!o10;s41;tB6;i8Ey0;!r1;e23i21;a24E;d1t0;i132;n20;!d0n0r1s0;a0o9;y28B;s107;c3D;l19C;n28;c4Ft1;g1E;c3C;p27;a5A;h38;!o9;i0s0;d1A;i1E;eDr7;a6D;e1Bl7n146;e6B;!i3Fs0;sC1t2D;p1E;i56;e1o1;oF;d3A;k0m0;eDl7n2s11;o59;iF;o1D;r3C;lE3;!i96s0;i13u5;h53;i14;e26y0;m164;n19;e10E;e114;t5A;sC1;e14;!g7s0;c215;pB;!e12s0;aD7;a137;e166;!g1;e95;k7;aD9;n16r0s8;a0i0;r95;p4A;!e4iADs0;a94;nEC;g18;!e0g0;l39;n2EC;n3C;a7D;i65;e92;a1De23i6;!d0f37r1s0;a214;s52;o100;!d0s0y0;t2B;aCy0;e45;!d0r1;m115;e1EC;!t1;eD0;a32;l3C;aDE;d6A;a1e0;e5s8;n41;!e4i6l7s0;!n2;e126;e33oD;gCA;a2CC;!i2By0;r60;i51;e15i43y0;!i14s0;v19;c48;!s1;g3t3;o9A;u10;u3B;e189i6;l5;iC4;a140;a53;!i1s0;b1CgB;e1Bl7n193;k18;!l11As0;n2s99;eDy0;a165;t1C;h16;m1E;e11F;o51;!s0t27;r74;d1s0;g27;a30e23i6;g1C;e34;i152y0;y20;n1u5;n3D;!e281s0;l5A;o56;h311;e1i13y0;f7n2;s1E;s2A;o16;b1E;u1C;e12E;!s8;i59;!d1Es0;e1i18;eA2n2;!e9;e0n0;d5;eDC;!d0e1s0;p5;t1CC;n24C;o12A;e10Dn2;l182;a6;k3n3;o95;e1Bl7n2s11;o124;m0t70;s18;!e4f37i91s0y0;i2A;o8F;uA0;p9D;!e8;e20;e59;r48;n20C;n1o10;o2D;n1r1;e109;l4C;h1E;eDA;n0r1;!b7As0;u20;z1C;n83;!eCFi6s0;!l0t3;wC;e212;d0r1s3E;t341;o199;o1F;!e67i43y0;w80;!m2Es0;k5;d0n16;g48;!r7;d0r8D;h131;oD5;u32;!o0s0;o1B8;e1g0;o13E;g1A;r1t1;eEAl7;m45;e0l0;sB2;g2C;c1A;c196;zFF;i4u5;d2F;a0o0;!d0r16s0;b18;o6;!n8s0;h9F;l83;eB3l7;a6F;u9;k27;o1E0;s55;u69;lE2;i50;d5B;t5;a1BD;l17A;i3Fo29;t95;r3CF;e0h0;e2F5;!i18;a7E;e103i6;e1Bn2s11;!e15i91s0y0;e81;i246;i2C6;e4i43y0;t55;d0r39;n2E3;d3C;d41;n3t3;l148;r7t3;d0g0;a0s0;lC8;s4C;d0n1;!l1;mCA;b1Cw80;!i3B;yC4;!e12;s35;t3A;!i18s0;c23A;a60;l32C;i2;d0t16;d3Ar1;z1F;!e187i6s0;oF1;l80;!l7s0t7;o23E;r58;r1u12;d48;!m2Et27;h2CA;i3C;o211;e12i6;c0s1DEz3;!e1B8;z27;v38;!aCs0y0;r46;aDi0u5;f108;d0r7s0;d9B;d0r2Fs0;!d0m2Er1s0;o1A;s2D;l27;!e4i6m2Es0;r5E;g2F;eA1;!e17s0;m1p11;c93;r7E;g4A;!b1C;e3D;d4B;u30;!lBs0;d0l0;z1A;a90;a1F5;eEAn2;!lA8s0;e154;tFF;!a30s0;lAC;!e0l0t3;!s0tB;i305;m48;d0r0t0;i279;i63;r65;aCi13;b1CnF;i6y0;e17i3DA;i88;!e4i27s0y0;!n0r1s0;i1DF;!i5;e1i3F;e0oC;a16E;c46;!l18s0;d3D;c0n3;l1n1;y14;u3D;r1D;i6F;c7t3A;o18;e40;!i14;oF3;oAF;e15Al7;d18;i4n0;eAiF9;!e4iF9s0;b27;!e1B;eB3;!l7r7s0;o3;e15i91y0;!d0n8s0;eCFi6;rE0;aA2;oCB;!n1;n19B;o4C;r4C;h0t1;!e0r0t3;!d0l7r1s3E;s48;u72;h5B;e6C;l77;a553;s3A;!m1Es0;n2sE;r28;qC2;!n22;a5D;i90;c0u14;aA2e1;h0m0t1;c316;g3C;eC7;e139;l7E;e1i5;e9iD9;!e4i13s0;!e3s0;t4F;c9C;t8;w39;!eDl7s0;!d0r1s1;!e5i2By0;k5A;eAiDFo12;d1E;!i4s0;o1CA;d0r1t0;f7t7;r70;eB1;c0s1F;e4i91y0;!f37s0;l1D8;a180;e54;!d0n8r1s0;d0n1r0s8;!i27y0;!tB;!e1Bl7;e5i13;eAi27y0;m28;d1s3;e1Bn146;!i50s0;t10A;!p1Es0;eAm0t1;n0r2A;!eAs0;c11D;!a4Be15i6s0;b7;aCn2;a20eAi6;r6C;!d7As0;n16E;a8F;t150;l1s0;tB4;!b1Es0;a249;!d0l22s0;a1B5;a114;m70;h29;t2C;o98;d0rE0;c0s99;n26F;!a9s0;m2D;b1Ct10A;n0s0;i31o46;eFC;aDC;c3n7;!e24i43y0;r1E;e23i91y0;n4B;k17C;g3l0;m1s1F;fBF;l165;d3i4;t196;!s0t2D;n0r0;d0l1s0;e0n2;a18F;m55;v1A;e12Fi3F;i34;u25;!eE;l58;s9C;e7y0;!tF8;!e4s0t0;l6C;rC;e263;a7F;!eA;!aCl7s0;bB0;n289;c1k1;a30C;uAF;s4E;c55;i444;!eCFi43s0y0;e17i6D;tDC;!i6m2E;c2AlC;i111o40;!a1;n0t3;u57;b1Ct19;e1Bl7s11;!a1e4i6s0;d47;l4BD;!d0s1;a49o9D;a13;h1D6;l143;r87;!r0s0t3;i40Fy0;n3s11;!e4i6lBs0;nA1;c0s155z3;l1r1;a1y0;t31E;e4F6i6;!a1De15i6s0;n16B;s3D;o3F8;m5B;!aCi13s0;m5;d0n2;a87;p7E;d138;!s0uD;!s0u5;!s0tAB;aCe0;a1e5;b19;!e4i6l1Es0;!e1B2i6s0;i4EF;e1i27y0;!e15iADs0y0;!e521;i3B4;e5F;nFsE;i2DC;o2D0;i22Dy0;uF;c62;e166i94;eE2;!o36s0;l70;!d0r0s3E;w8D;!d0r7s0;x68;!d0n0r0s0;g62;n203;c0e5;!eCs0y0;i1AF;lE0;!i20s0;t52;c0s3z3;k47;i4t0;n30A;t4C;n3F;a0i13;e15iCCy0;l694;!e192oDs0;aA9;t14E;!e24l7;t93;l7n2;!iBs0;uD0;l3o10;v48;l170;!l3Cs0;u50;u71;h0t0;e27;!l7n1r0s8;a2DAi36;!i0o0s0;i2E9;oA0;t2A9;a75i13;l714;r138;e77;e0nF;!l7r0s3E;e1u5;n1s11;eA0;a1C;e10En2;u60;i38Cy0;!e13As0;e11;e1BnFs11;r0t1;i4m18;!e9s0;!d0s0uD;h14A;a4E2;!e1Bl7n22;a1i9;d3Ar1s0;u4CC;l32D;!e12i21s0;!e4i6o12s0;n525;a1i13;!e0l7;c0t3u14;t29;eEi10;eB3l7nF;t5B;n1FC;l1F1;o94;uB8;d0n0r0;r77;l52;h2D;!lB;n4F;aC4;!c7s0;k38;a479;d53;eAi21;k41;l47;k19;!i3s0;n2p1;a1D9;r9F;e686y0;eAF;d78;m39;o6E;aB9;g3l1;s368;n371;a303;aAC;e300oD;a26A;d2Bs0;r2DD;w27;!d0l1s0t1;!a0e4s0;s48z48;!a54;e35D;y31;s53;d0y1;c0d1;!a51;aF7u14;e51;e35;t49;k78;!d0r1s3E;i13o5;h0m0t0;u1A;sFC;a1i3;d40;oDD;e2;m3D;!e10s0;aDA;oB;c32nF;!i96;iB7;i63F;w28;a28D;s1C1;d1n3;m61;!e1g1s0;!i20;m63;n5A;a504e9;e13F;r85;r13;a2EA;d194;h173;n39r0s8;r78;e10DnF;k4C;o230;e1Bs11;!d0r1s0y1;n19sE;!n3s0;sF3;u4;aF3;b1Cr1;aAF;r13A;g35F;l25B;iA6;k39;s0y0;aCu5;r191;d0r1s5;e57;l0t0;t194;o6D4;d35;!g11As0;x5E;!n3;eB9;e9l3;e15i66y0;d0r2D2;l0tB6;!e4i27Fs0;t58;!aBE;h35;d9E;aCu34;eAi13;a9n3;l2DB;eB3l7n2;i2B2;n1t1;e17i6;a4BeAi6;eF;e1C;u1E;e4i13;eA2l7n2;d28;cD1;!i13y0;n2C;!s52;!s3;i25o46;!l7n22r0s8;eAiDFo40;s36;r29;!e21Ci6l7s0;i4s3;!d3As0;n0s8;uC5;i172;!hA5;!u49;!e1Bi3Bl7;f28;s1DEz3;e5C;!d0r0s0t0;d16A;e5y0;l63;vB;d0r5;p28;!e5h0;a315;o3Cu1;u4CA;r294;tEF;e30x1F;aDeA;t266;!d0s0t0;d0s0t0;!e24s0;h52;o2A3;o476;!i1E8;u5C;e4i27y0;l75;rF6;hB4;a96;e55Di6;i207;c32k1;e300;d293;iF1;a25d0;n6A;!lA0s0;!e0s0t3;o19D;i62;r1s3;a110;aE5;i4n1;o23F;a410;o244;t35;!a0s0u14;!e4i6l22s0y0;o11F;h4C;i542;r1BD;d0r1t16;l1BF;h41;i291;n20B;eB8;s155z3;r1E6;s0t11;e12n2;d19B;m27;e14D;!m0;!i160;rA1;w1E;c2C;e1o46;oB9;a31A;e1nFs11;r7C;oB1;!f1s0;aCo9;e1n2s8;y6F;m53;k5B;i1y1;u54;e1r1;d0r78s8;l0n8;k3n2;!nBs0;q123;e4BAi6;e17i27y0;!d0s0t16;!i133s0y0;u6D;!l18;a105;t5F;n194;rF;n2DE;r1EA;d70;uCD;a12A;e0i0o0;a1EB;l32;gF4;a2AE;a2D6;d1n2;g44;v18;e6Bo6B;l5D;c0d0;r236;e17i31;l46B;s19z19;s234;n1D2;r5F;h8B;n1A7;i206;r1uD;sC7;iD9;aCB;!s3t0;kF3;aCi0u5;!m1s0;m1s0;e1i8Ey0;e12F;aEE;eF7y0;g2D;e56;t138;bD6;!e26r7s0;!a0e0;!s0w1;h18A;!r2F;e84;l62;r272;a4n8;y5CA;r3AC;l1C7;g3n8;g1C8;d0r7t1;e109o5C;n398;d1n1;b5A;a2An13A;!fC3s0;b53;a2A4;e10Bi86;s41u5;!i228;aCeAi6;i21y0;v2C;c3s11;i1DA;e50F;l2BE;!c3Cs0;d0t20;k306;n795;e45p8;d0n0r1s0;!e1Bi3Fl7;e83Ai6;l17E;n1r16;eEy0;rCE;g7B;!i9;r25F;z41;a46;t7C;i71;!e382i6s0;bCE;iB8;r0t0;e756;!e4s0t1;l14;!i3Ds0;!e4i1BAs0;!l7r0s8t7;n36;e1i16D;i178;!s0u1;!aCi13s0y0;e7D;dFB;l4D5;e330i6;d1f1;n3E;!n8;k1F8;oB4;v62;uBE;e1B8;u84;d0e1r16;r101;!e15iCCs0y0;s327;rEB;e482;t909;e14Ci6y0;eAiCCy0;y1C;e33m0t1;c6C;t148;e590i6y0;a6Be6B;dE3;c32s5;!f37i133s0y0;mE9;dB4;j4AD;t641;tD8;i73o81y0;i4E0;t15C;h3F;r1s3E;!i206s0;c49;n272;m513;!i54;!h1D7;e3F5;t1CD;n25D;c3n8y1;s96F;a59eE;!e15i6s1F;m0y0;iA1Ay0;l61;g0s0;k0t0;l5E;n5F;l1n8;l85;e1o0;c163;!e4iC9s0y0;!eDo10;n752;m1A4;g1s0;a0o1;cBt0;c0tB;o239;!d0o29s0;o3C5;!t1A;!a258;o261;e1o71;tE;e15i6l2C;s29;rAF;d3m3;p4F;!d0e4i6s0;hB44;i29E;c5C;e12rA1;e2y0;o708;n3t7;g3s3;p1A;rF5;o21;n118;d2A1;s248;!aCi96s0;eAi6r44;s106;eAm0;!m18s0;r3y1;l352;eBi1;h7E;e0n3;s1EA;u53;k36B;a0t3u14;mCE;p2F;aD3;e0i5;e0i1;a83B;!a0i13;e1EB;e10Bi6;a1n2;a9i4;!e15i66s0y0;e8D6;!e10Bi6l7s0;n0t1;r3A;i26B;i3y0;!i1As0;o34C;c0n0u14;u175;v95;a30eAi6;rCA;!s0u14;v0;a1FC;e5n2s11;n46;d0r1y0;!e15f37i6l22s0;u47F;l171;d2B0;g2BE;e12Fi35;i47C;e1EoDA;a70D;i18t2D;l119;u6;i5y0;i370;aB1;oDE;o94F;o29A;h129;t609;a1De1;e4E5i6;!e23i6;v3F9;eA60;!k0;b29;e4t0;a4Be15i6;a2CD;c7l1;!l44s0;nEtB;o42A;w2F;o109;l87;fCA;eAi6t19;e4i18Dy0;a7Ee0;nA4D;n1A3;r3E;i25Eu1D;r76;e33o1;s0t7;n205;e6C5;uEv27;uB0C;!e4i6l48s0;oBE;lEB;e5s11;u63;!i10Fs0;t921;!k1A;!d1;a0e0o0;!i1A;!e4i6;i355;a9e1;e1Bl7n149;r2Ft1;!a4Be15f37i6s0;rB7;uD9;i13s7;e4i66y0;c0e24;r89;o291;!d0l7s0;w2A;!e24oD;i1B5;e24sE;!o10s0;e12rB;e4i35;b5C;a100;c227;d0n3s0;o2DC;e0o36;o5F3;a2DA;a7C6;a33A;a1u34;!e26r7s0y0;!l19s0;i25n0;a1EDe1i0u5;n1s3;!d0l6Cs0;p29;s5D;eDs122;n1As107t9CB;o2C3;d3g3;!i31s0;c414;!d0m2Es0;eA2n2s11;a52E;x7;!l7n22r0s3Et58;o1EB;l1r7;n2DF;l5B;!a8;r2;eEA;!eEA;!tBA4;o818;u45;tB6C;e209;b38;d1g1;!e0s0tB6;e2B7;rA9;!d3Ar1s0;r7tB4;!e4i1B3s0;e2A;!b7Bs0;dAA;n4B0;!o1s0;n337;r56;a8C;i4t1;e10Dn11Es11;d0s5t1;d0s0t1;iE5u5;b1Co10v3;s503z19;t21E;e23i2FC;a5B;e79l7n2;e140;lBu292;e15i6l44;!l41s0;!s0y1;!t5B;s8t0;aB;a37;t46;a360;!i1Ey0;r4B;!e0n1s0;n443;m83;e85;o1CB;oB57;n192;eCD;y40;o53;!o14;!e15i6o12s0;!l3;a5C;e5n2s3z3;c324;l4p1;t2E7;p38;a180e1;h106;cBd39sB;a3n2;eEi21;e5i0u5;e4l3;u16E;a11F;e288i6;oA9C;zD6;sB08;t102;!a20s0;!e1E;d0t1y1;!e24i21;a1EF;e81o49;v3D;e26i6;!r7s0t3;hA01;e10D;a4De15i21;e3o8;o358;u5D;a0o9u14;a416;n146;!iBs0y0;d0l0r0s0;c17E;m41;t186;!e17;d1m1;a4B1e9;!eCs0;c1A4;j3C;i18Bo392;e104i6y0;a50u1D;r398;n236;g3r78;!b1Cs0;!e727i6s0;a0e0i0o0;sBD;d0t150;b18v18;dA1;e3D4;c889;o114;s603;s8t3;n14B;e25s5;f1C;a20o29;s5B;!o29;!gBs0;k1C;s12C;r83;o74y10F;d0rA9;s3t1;a4Be23i6;e12s0;aD0;!l1r1s0;!e15s0;y18;l195;iA4;!o40s0;e0i56;i18A;d0e1r1s0;d1y0;e1i7D;nD0;!b1s0;!t0y0;t0y0;fB;aDu14;f47;b1CB;!s0t11A;e1h1i13;aE8eB;u7;e643;a30e0;cD6;n38;x8;l700;a299;m2B;oE9;c4Ag4A;g5;e32;e38;!uB0;i32F;iADAy0;!e15i6r7s0;b3C;e381;a75e1u14;e12r35;i1t53;i2B;i4s3u5;d0n0s0;r25C;eEi6;n3A5;w32;e208;i13o9;!i133y0;!c3s0;e4h0;aA0A;n14E;t2B0;!hEB;!e15i86s0;!i18s0y0;d2D;g97t1;n6D;r2D2;!h3A;!w20E;t3B2;s516;a1o9;t61;g97n4;u865;i11C;i440;!h1;c53;t1A5;g528;!n8s0t3;n2B;!i290l29Bs0;!h238;n22;t16E;eDg1;cA02;n276;r796;!d0l6Cr1s0;!a92;!i3;d4F;h6C;e18C;r195;d0r1t2F;r500;o284;h1A6;!t16;eAi5A0;n2oD;c3n2;e4o9;b7Bn1D2;e12A;nEt19;!e4s0w80;l55;d3z3;!a4Bs0;l9;b134;d7i4u5;g35;eDr3;r185;t426;c0l3;eAi6o10;b1F4;a5A1;w1D;n1A5;a9n2;a0y0;!e12i43s0y0;m4C;!sE;e1Dn2;a8CeAi6;!e5i1;n2s5B4;lADF;a4De23i6;i51C;aCe26;e779;r1E4;e5D9;d0r1s0t1;n4C;!a9i18s0;i38;o2BC;!aCs0u5;u4C;i13o0;a20i13;e4n2;!i13s0y0;!e15iBCs0y0;i4o29;r1sB;i8ADy0;i29D;c8e1;!g176s0;k436;!r18;n2s8z3;e40i3B;a61;!e4i6n0s0;l1n8t3;!a1Ds0;r20E;i4A7;iD0;iA4A;oAA;l25nE;d38;d77;r1AE;!c32;iA1;!e5t1;e1t1;e1i2By0;!e5iBy0;r8B;eA9i6;r198;i28E;!a88s0;iB1;k6C;t48;!l4Cs0;n163;!i13r7s0;lCn4;y604;!i10F;uDD;i10F;l0n3;m1t2D;n8s3;tC7;!e4r7s0y0;i5BB;t268;o258;a31Ae1;d39sB;!eC0i6l7s0;lA74;m1n2;pD5;s18z18;!d1E;n13D;t1CF;d85;e82o1;!e8C9;e10Dl7n2;u2D9;o4E;n1s8;c197;s1A;z17D;l1n3;i4E;h89;!e20Fi6s0;!o41s0;i19;lA1D;z1E;e632;c0m0n0;p0y0;t2AE;e4iCCy0;r7F;o327;a2DC;i9y0;s178;u223;r4y1;b1Cl1;z18;lC2;!e153i6s0;n40D;a74;tE0;l612;n2o10v3;n1p1;x2D;n0t0;i0y0;e23i509;a8F7;r62;aDe4;n916;c1s8;t467;!f37l7s0y0;!k7s0;r1t3;s37C;rCB;m5A;u2C;j1A;eAC;n8t19;!h9Fm2E;!o6;!s0t1C;n8s0;e15Al7n146;!a4Be4i6s0;b3o14;eACA;!i35;i334;i2E5;oAAA;e10Dl7;r145;oDC;e79l7;!e1i2C1l7s0;e4l3y0;!i2BBl7;c9Ct38;t19C;m0t2D;!e4g19i6s0;d0r1DD;v1F8;r11D;a42oD7;!t56;t56;a39C;t77;tFB;i2By1;e14Ci6;a1g1;g38;n13A;i7Do0;a252;c1n2;!l2C;e0t1;lEC;lE1;eAiF9o40;eDs11;n438;o38D;!l39s0;d0e0r1;rB94;e3Fo29;c4F;h85;!d0n5Fr1s0;!d0f37r0s0;c0f7t7;t48D;e374;!t6A;t6A;!l3A;e1f7;c5;!e4i21s0y0;e319;i7E3;!a20e4i6s0;c4C;a1i25;!a52s0;!e5nFs0;i9Ey0;k27n0;t1A3;a0i32;!e14Di6s0;dAA0;e12lB;a29E;r0uD;i31y0;!s0t16;r49;!m2Et38;s5t0;m35;u164;r27;g3lC;eCiC;a51i59;p61;a630;!iF1;d150;a1DeAi6;a178;z5D;i110;e1Bl7nFs11;r218;o370;uD1;eEi94;o60;!e12i21;!d0r3s0;!i0;s1BB;!d0l1r1s0;d0l1r1s0;r431;a3o29;i4p9D;s7FAt2D;!t7;a1e12;p178;b986;d0y0;g61;e0l18;lB7;l25C;e578;i862;n947;l102;eB3n2s11;!t2D;a537;!l7t7;e12r3D;e1i1A;s185;n43F;g40;a10y0;oD3;!e104i6s0;a3BE;d1l6A;r2C9;h1AC;g14E;a51oD7;!e192s0;iB9;i53;!e30s0;d3s0;e383;o10v3;!iBy0;i1Fy0;d1C4;a21;lBD;aE5i13o9;hBE;aCe1o1;!s0t11;a1eA;m1C8;oAC;!e15iADs0;o27;i160;i1BA;h1r1;u44;!o8s0;a7Ei13o46;i3Do10;eA3i10;p55;aC6;r4F;s27E;u18;d52;e13;d0n39r0s8;c0s19z19;!e15i21s0y0;oA4;n84;!u5;oA9;l0r0;r115;o12r1A2;!e67i91y0;e5Bi2By0;aCe0oC;a75o9;r2C;i68A;e4i21;n2s0;s3t3;s78;!pABs0;r42B;!e36Al7n22;s287;aCe5s3z3;c1s99;!e1i13s0;d2B0t3;!l1t3;aDe1i0u5;m2B3;!a4Dd0f37l22r1s0;u2B1;u89;!n2Bs0;e0i35;l98;eDn3;!n0r0s0;t16F;o6F4;z5C;!d0r8Ds0;!r1As0;s32;e4t1;l25A;g1i13;d55;e6Bo2A5;y1D;d0n26F;vD9;aF1;k113;r56Cs1B6;t8D;!i9E2s0;s0t2D;n12C;!a42s0;r164;n148;c171;d0o9r1s0;c24F;!cB2;l5C;r356;r4AC;!e24i6s73;n294;c0s8;!d0l1s0;g36B;!e1s0y0;a3A1;!g43As0;!e5i6n3;e106;!e26n1s0;h95;h9;iB4;!i10s0;e15C;n8t1;e1Bn193;!u14;!a7Fe15i66s0y0;h26A;n6C;h5E;!oD;s3t7;d1n0;f0n0u8;c0f7;lEE;y1BD;e6CoA5;wE0;nCA;!d0r1s0uD;!n0s0y0;!e33;l278;d0n3A;!g3s0;i6C7;e1i0o46u5;e1o9;l411;!i152s0y0;m29;a9EC;n3s3;eEC;a1EDi0u5;g167;l1FB;o2BA;s549;!e153i6o12s0;r0s8t1;c2B;e3C4;r933;o54B;i2A2;!e697;!l55s0;!i285;!h38s0;d0n1r1;d0r1t2D;!e15i6s0u4E;!bABs0;!e15i21l22s0y0;r1C7;eAA;s14t7;s20;!o1BE;mA1;!i61;l3o9v3;h58;!i8s0;o401;n0r0s8;!t1E;dC8;m0s1F;eB3l7n193;m57;e15i6l19;e281;o21F;n31;s6C;!a1i1;a1i1;a9e5s8;d0n8;!s0tB6;a4C4;m3r3;o5A;l9C5;!aCe15i6s0;z38;!e5i8Ey0;d0l0r1;!e15i6m2Es0;r821;a4Ae12;e5C1;d16k16;t88;l1AB;!uCE;e15i6l48;t38B;!f37;h4B8;!e79s0;!e4i887s0y0;o28;n2s3z3;!a137s0;a277;c13C;i19y7C;!p1s0;e309i43y0;o287;n268;i140;!aCe5;d0r138;!e42;!n119s0;i57Cy0;d56;e5i4;a75c0u14;l0n1t3;eAnF;h121;nECs8;e201;c13B;e23i6o29;d16t0;d0r16t16;!e4l3s0;c7t1A3;!a5;!nFs0;!l5F;!e14Ds0;a15E;c0o9;d83;m2F6;!eDl7y0;!e1i6;!e4i34Ds0y0;m4B4;o29u14;r303;e498Ah10Ci8C0y0;a15DD;!e15i6l216s0;f3A;b28n62;rABF;h7Ci6F;d0l1r1t16;e212i6l1E;!k1l2Ds0;a0i13o10;e2C3nCD;o98y0;!a1e6ED;a32d0l1Dn8;m3CA9s22Ct1AFB;a4Bd19Ei6EDs0tA57;o2945;!e1Di2E9r14Fs0uB5D;!e15f37i6l1819s0;!e13Fl3A9r2D85;c4B2;e4i66o1B1Au4Ey0;!e5u3EE;aCeAi6k16A;!o71;!a223Be23h0i4244s0t2C60y0;gA1;r451z1A79;l7C;e3D43i3522;n19s8CB;f7n0o9v3;!a1e82i6s0;e81i28EoE;!d0l790r1s251;i935o2894;!c89dC34eAg2ABDi979k47l22nABs17D5;b181c3040i79Fr0;cD43;!b4386e1F9i2F71m382Bp4F75s0;a2291eD3rDCEu12B;!i0u5;h70E;a4DeDoDEFr9D0;aCc1E08e23g1148i4298k3531n879o2A74p1DE5r2E92t3470y0;!a443Fe2B9i4FFp2F8s0y0;a4De104iBCl44y0;oA6u72;a5Ch2C;!n276s0;c32r2F;iF5B;b0e0s8;o449;i883l7Cn5BFo29r1DDCt35D8;d0r2Fy1;!t64F;h1C5iF1lF1t105DyF1z9B;c0s122;!d0n16r1s0;!f7;e510Di4C21o1907;!a2978d74De12BDi2D4s0t224D;!e187i6oE4s0;a2A42b294Ec2895d1D28e1548f4677g1A53k1DCFl1572m43E2n4280p45ADrFB9s48F7t29D9z15F7;!k4Cs0y0;a15AFb32E8c4F17d1CC0e4C49f27F4g3426h29E1i1B7Ej1226kA89l3C53m3200n24F5o374Ap4836q3D8ErEBDs35C7t3601uC77v3758w2F74x0y433Az314F;t49D5;!e15f99Ei6s0t0;a125E;t205x68;!d1B7m6Ar41A2s0yC6F;z433;e7E9;cBd2Cn118t4DC3;!a30e25f37i998m2Es0y0;h14D8;!gBn8s0;!r3Cs0t1B1;eAh526i6o405C;!e4i313s0y0;u244;u3965;a20FCi76Fo2E45;a103o1u1981;eEi5;a1e8B5;cB2e3D4t28;eA3h5Fi81Fy44B;g336Fm63;g581;a14F2d3CE9e36C1f2165g28i1A6Dk1n18o1932y5z41;k4E8A;!e1iACo8Cr1A2;n37F8;d1e1l28p2DDt28;!e1EB9i3184s0y0;t4183;u21;l1Dr40;g4An16B;!eB6Fi6l3s0;a351m0;!b1F3d0h121i21l2D51r1s0t20A;s34F1;!b39Fs0t20A;i10Fo0;p2342;m11D;r10C;eE23i4Du42D;c3E45l221m1AD7n2031r4483;d0e0s3;e23iF9o40;p401Bt186;!a9d51En3;b27e1Bn2;a174e23f24Ai6l1B1m63s1Ft2E8;i109;!a229Ad2653e0g46E2h0i4DCAk4A87l7Cn1C67r75Cs394tF75y1A1;o4736u43A4;a13A8e3F56i7Do13E;!f1E3n312Es0;c1B16d1EBDeAg28h2D7i979k1n49E4z4F1F;o12p1C;!a17C4c25DFe9CCf340i11Cr4C64s3F0v407;e5n149;e573i9FE;d1A3;eAi6o1;a42B0k28m28p436r482Dt28;o25u3649;a180n3o29;a9e79o9;s943;c32n86Et2AE;a0c2FEe1h2970i31k1m1As4B6Ct2206;e6DrA65;a386Bo28B;a59i31y0;r19t19;!d0s5;!a2A4e24i1435;h3FD1u57;nFt200z2C;e5o4748;!e1g5Fs0;n44q2F1;!i1Dl3Ar4F45s0;c499Bs11;a22Ed3C2En25s2B21t84;l293;!a134Be93Ag208Ch1A1i2755l40Co1887r13DDs0u24AE;a105eClBu34;e594;z4C;!e32F0i21o3548s0;aCi3021oE7;r620;h2877;r3037;!l7n8;b41;!a84Fe9i8Ek5Ds0y0;!a4Bd8AhEDi3Bl220s141;a0nB;!a3A76s0t384F;a20EEiA09o17;e44BAiBCy0;!e4B71m162;l3989;d0n1r2F;e0h36C0iB;a249e163B;i258C;!e9i3Bl5B1n43Fo159s0;e0n248;a3D3;o33Et10A;a8E3g62n84t1v106;e2FF3o28C;a21e12;!b396d0l7Cs0w169y0;!i31;a75o10u14;a13C8e23i6;a160;z306;!d0r7s0y0;a1o61B;!e0l0n8s0t3;!e1l7s0;aA4z1A1;!oB32;a1Dc4BB8k4CnFs12D4t45D7;!a1C73dABe1f53Cg311Bi1l7CoF2r3BFs11E8w3A3z89A;u31;a105eAi2E6k28u4E;!e15s0t38y0;!d0m63r2Fs0;e1Do34;e25l1;!i2F57s0;!e14Ci6l19s0;n1899r413s345Bt2F4;!a4Be15i313l20Em2Es0w80y0;eA1o8A;a32FAe3BFCi1094;a3394e4B4Ci1241l26FBo433D;!a660b367e12i17Fl7n22;!l7o12u202;!a42eAi6;r61C;n2731p4BEFs2CEEt339E;e3912i1B3A;a13ADe33i3A7u4571y0;r3B1B;!a228Bc12F3d1DF1e119Ef39C4g1778i4F1Ej37C7k76Bn41E5o2721q352Ds182Bt3492u49v3D3Cy0;!e67i5ABy0;g3CnFr0;!e1s0z4C8A;m353;c62i16Bk2Cl129E;l1r1t1;aA54e9;b1Ct2EBF;!d0s0w1D7;!a12c3s0;a3Bi94;d1Ek1E;a1e1o1;!c2Cn4351r1D7Es0t145D;e0f3F7AvB;g2C7;a40o10u69;e5s430z3;a9d0r1;nFtB;!eCFi21l112o50s0y9A;!d0i6r1s0;c161d83l123Cn9C6r6EA;a9E0u3C3;h280;fF86nF;a1830;a2AD6;a16DDr26C;i3D6A;eB75u4FB8;g61n2o10;!n1FCs0;!tD5D;!a10B7b24EAg2034h424l3712o21s0w3D6;f3i10nEr14s19;eC5;a3176o472;i5o19D;a3C8Ae50F9g149EhC9Fi3921lBE8m1An4148o1036r4B09u3DAB;e1478i1FFFsFCDu0;r9A1;r3195s3876;cE40h376i4F48m37ACn1ECFp6A0s2239t46A1;!i40Fy0;!d0e82s0;!d0e4s0;!l80;m4220t839;d0t25A;l1Dr40sE;t276;!a3A6e12i21s0y0;d1DD1n151t2C;i25l1;e0n0y0;aA4o1398r89;!e15i30F7l7o12s0;!a10b23C7e344Bg1F66iBl248Do1526s0u5y625;a3A70e50i6o460A;!d39n1Es0;rA62;h1ClB;!n1Es0t0;r137Fu59;m115r7FF;a1093e0i17o30B6;g20;!a33F;e1k3;f2C38iEEt8B;!n3Ar2F;c298g298s2867;!e0i2DE5s0y0;!aCi39ACo46s0;!b150Bf352rB8D;g14Aj7C8k35Cn1CBArCD;oBA;d19lE3n25;g3F4B;r636;a35Dh4635o367Cy49E8;!a10c2BBCe2576g6B5i3866m4404n47A0o3716p2B76q4CC3r1505s3F4At2F3Fu22FE;!eA24s0tD73;a374;!d0e0f37r1s0;!e13Fi6l2D5Es0;!e4i6o9Es0;!a3153b3305e481Ei10k1DCl2Co32C2r217Cs0u1C11;aC4o9D;b5BDi47B;!i24;a1D18p3Dt39DC;l2829t70A;!e26o1s0;!e104i2A23s0y64;a143bDDe1f3k2Cn25o2B52p1CCE;cBgB;f235Bt0;e18Co7FBu3403;i111o8C;a12oDD;g33Bm174n26Er26Es1D99t1;a9e0k1;!b363cAE6e15i40C4m61s0wFACy0;e49Ah5Ai495k2069o31FAp2AFs314u4E;!p27s0;!i2FDEs0;nCAr2D;i193Fl1;e263i1A;a2453b713c1B4Ed283Cl5138s25CAt3019x0;!i4n8s0;!e15iCCo1sF0y0;e90oC6;e67iBCy0;!e5i21t1;gD2;!gD2;aD6iBAo202rB43u44;a7i9;a15Ec24Fe4n3572r5FBxAE;d3ECEe12n40BsE;a4Bi35;bCA1c2E87dF27e37Fg2EDDhED2l1598m2450nBE0p2E57s360At2210;a3743i4110o0u5;u2460;!d8Ae1B2i6l4D16s141;!b5A4s0;iBo71u71;y3E5A;!cB2FdB53l812n35B3t1367v1745;!e4i66Es0y0;!e4i312s0y0;!i20o417s0y0;!e0l0r381FtB;!d0e9l7n2A8Ar4214s8w36Fx1F;!e30r980s0;!d0l22m2Er1s0t1D0w2E02;a30iE6o84r2B9AuBAz3C;h1A5;aA06;!s0w2AD3;a32e3D4Dt5E8;l5032;o13D0;c982l50B2;bA62d6A;g38n56oB;!e0gBl0r0s0t3;d1i5DD;!a20o29s0u34;!e23i6o3550p2F8s0;l2EC8oFB4;aB96l19F2m50B5pB8;b3B5Ed3Cf5F6k1t3;aCo12;pEC;iA38s0y0;!iA38s0y0;!c302d8Ae3061fB5i21k67Al3BBEn36Eo1436r21Es141t438Fv2Cw253;a52F;a4BeD;l40rD8;d154DnD3;!gBl0t3;g3C1;!cB2d19Ek3735l1m144s11B;!d0i6r0s3E;c1F53e4009gBl1824n2C77r1CD6s2BC0t278;c32d408k2A11l3A8An0q123r2B87t4A;!e62Al47s0;m41F6;n218;r31B9;a2F06cDBe3339i2BD6k1EF4l13DAo314Br327Bu3DEC;a7Dg175s1A9;!i1DA;c44m44t1CDu21F;!e4iB7Fo29s0;nF6t384;!pB56s0;a151e15iC9y0;a9D5e9u60;!n65s0;a501e0o46E8s4C;e0m16p1E;a4DBDe1510i593o211;p4Av19D;nC91;eAi317;!a25;!a12d1A9e3405g350AiA32k36E2m5031nABo93Bs0t28;!l7r7;i20o6B2;lCr0;g127;!b1F3e15iC9l22s0w253y0;!v27;c1eDn2;!h9Fi69;a42h1895i36;a30e381oC4;e427;e1i12;n1267r450;e25m44A2;a0e4575o2A9B;!a4Be15iADl48m2Es0;g8A1;g55l1C7;m3A;!e12t0;h6As19t19;lDFFn16Bt2B;rD4;r124A;r2F40;!e697i6k21D;s22Et4A;o607;e2C87iB;gD70m9B1r42BDu34;!d0i6r33Ds3Ev3D;!c4313e46BDh2F55k1m2646o10q123s35tBD6;!e12f37i6l6A3s0;o85EyC;!g4F1p173r20EBs0;!d3DBBs0;b4720;k3n2t0;e17o2FB3;a19DBb23D8c25E5g18D5m1C4p1r23BFs44z14D6;a527d0e4l3419n3B5FtC7u4AAD;eDl7n2s5B4;e592i4859o9E;e41E3i6;o2907;e4i3B;g97t0;e2921;a8n3;i1316;!e32DFi21p318;l16v1E;o4304;a2DBEb2A0Ad4DADe3E77i41F7k1AE2l1m227Cn478o279Ep2EB2rF21s3128t93u1C1Av657;r72As20;d0g97;!l7u12;m63n366;!a371Bc301Ad4113eBg3177iA9k179Cm1B90nDBo1A32p4FBDr459DsBB7t1B7u4E;rC63;!c171l102s0;!r5Fs0;p200r1A7;e162Fi21;tA90;r2489;m1BD;!a14d38ElA10s9F3tACD;eAi2095o12r1A2u49;k36A7r3F88vB6;r25FC;!a4888e2615h2148i6n1C42o139Bp1Es0u168;l264m3s117u36;!l1n1r7s0;l2B03n509A;lA51n24C;!l0r58s0t4C67v62;i229Fn83y8F;a340A;!e67i66y0;e23i66y0;!e23i66y0;e957i43y0;e47F3i6;e189h1C74i21k190At1171;t23F7;t436;i282B;b7Bm4F14s7BBt4CD2;e5CFi5;f2F;n1p7;!d17Di3Bk1n2AFs0t36E;b1A8Ae1n2s11;a1eD;eD0Fi343y0;gBm1;a8m14B;!s0t4B9;!a283d0f183l28E4m2Ep162s0wA7;!b6Cs0;e4i190l227Ey0;r16E0;c3Cn2o10;a50FC;!e17i2C1l7s0;e1F28;e9FD;a62C;iF6Ey64;!e21Cf37i86l7s0;d0r1w1;l3CAEm217Fr1sC1;!c231Ee1Bf2Dn2;g2401kAFE;!r229s0;e4778i6;!eB02i6;e8CiBy0;a0cFD1e0o9sD3;e17i3DAo6;d1Em1Er1E;b6Am92A;!d450;u4FE;i4l2E58t0y17B;r1C76;g0k3005;u6B1;!a1641c13Bg42CEl143m2Es2D0vDEw28;aADEeB;!d0f37l3DD7r8Ds0;m131;b1Cn20Cr7v5A;aD0Ce2DA4i34C1o4C26u20A6;e1n2o9;a52Eo31;g3C9;!s0t391;a88e4D9Fi813o420Au34;p4B97;a4Be6EBi73y64;e30iE93;e4iAD;c11n7t39;!e233Ei6;sDE;a2E41d2ECBe3B88h219Ei29F7l19D2o2235r5053u34F4w6B0y2FC9;mA3AnF;!a5083c9DBe110Ci47EBo2EFr3CACs7E4u4BBDy2033;a4F9i7A4;d1F4e404g14B2i3Bk28;!e9iA17l22s0y0;!e0k1l22p9Er2F3Es0;i96lCAr420E;t114;r0s26C4;n323;e4B1Ci21l7C;h7D4l3862n1t30B1;e1n2t3;a23BEe12h16E5;m3C87;e201o1;!a7Fe15i66s0w4271y0;!a1Dd0eAi6n3991r1s385;u45F;!g242Cs0uE6;n3Cs2527;rEu40;!a4Ae4i6l296Fo9s0;i8r44F1;!e60Fi21s0;!e15Af37i6;r33F0;a222Dd3895e33A1i3898n1806p8u40A6w28y1;e98i1B5o31;!s1A4u5;!aFC;aFC;!a31A4b321Fc1DC6d2F88eC5Ag313Ai11FCk5Dl18Em49C2n2AB8o14D4p174Dr31AEs36DEt4CD4u55Cw7BD;e28E;m7D9;kB9A;t3F07;!i10Fl7t7;g19v21D;c4BF5sE;p178s424Et2D;!eE6AiBCt1y0;r34F2;t60w16;!d0e1r3E5Es0;c11s35;n154;!cB2i1Am1EEs0t7Az1BC5;g654n13Bs5028t48A;u52;!u3;a3597e23i66o127y0;o29u710;e21C5;!a2ACBeEFBi448Dl22oCs0u453w169;!a3A67e4i6l404Es0;a20i4D4o29;b7Bn77;c8n1t0;a35C3n3u14;e85z24A2;n16r1;!e4i6l2Cs60Bu4E;c9D3d4E18e4891fBFn4285;a310o25B3;!lABs0;d48e189nF;!f13F7l0m2811nBr3s0t3C7;u7E;t38E;e25o6D;dD2t3;!i6r17E;a30n337;c1eDf7n2s3E;e210Ao50B9;n167B;t1B72;!d0i4CEs7A8;a50i3B;iB4o8A;u7CB;i297A;i2F2E;a387Ac2C2Dn2121s257Et4E1;c0g5Bs4D6v6A;w5102;!k4EC4mCDn3385s0;!i2581s0y0;c1DChA6E;eAo9;!aCe1o1F90s0;!e12Fi2C1l7o46s0;c0e5s155z3;!d0sA8Dt8;b431c4C8e40Es1F11;eAp0;a1De1i3BA4;!a1936b601e4BA4i3435l3FA9o16AFs0u27C3v8B0;y517;!f37s951t229w169;!i279s0;h47Ei2463uC55;!c0n3u14;!a90e67i21;!hD2p29Bs0;a1F9CiB23o4947yC;v2609;!h3542s0;f113;n3AEC;r228;r4Bw10;!a27EBi465s0;!e22Ai6s0;!a403e6BDi21m2Es0wA7;aAFl80oDA;l7F0p3144u21BF;i13r18;r41B7t39;!s4DBB;r55t10A;!a3222c3Ce2F7Bh0k89l1502o12F9r3AB6s0t2981u1223;o875;j80;a18B6b3970c37FDd38C6e2B82g1327h1FDAi1718k1360l4F6Fn30B9o115Es1792t4C5Cu1F1EvDEx3997y44A3;!e4i1A40o1Fs0;eAi6z49F;c2A46e1A1Ff1BECm4627n2FC8p3FCBq2632t4392vCF3;a1C3Eb31Dc4A7Be24C7g1AiABEl4EB4m29A7s3t1F4D;n2o29u34;aEd0y19;a3AA1n49Fo5Cu14;e35F4l1E97o168;m265;p9C1;g25;t3w1;!e12f37i2158s0u3D;n5r150;!k2865u8B4;l2304mB93n17A3;o12r148u12w124;r5037;!c6Ad0fE2m2Es0w80y0;a268Fe2E95i41A3y0;r4E03;e0t39;!a4D14e1s0;a26C1c4340d329g3752i336m2973o2DBAp44sE39t4A4Au4BA9v342Fw13C2y8F;!i4CE5o2439s0;!a0e4iF9s0;!a39C1i3CE5k5Dm129n89o158Ap33D2s0u2C2A;aCi0l4Cn0u5;!d0lA7r1s0;s19t0;e5g1;a4De4225i18Dy0;e25E4i25El764r421uB3C;!a4DdB40e15f37i21l6FFmF97s0;e1664i6;f1E7Bt45E7;!a388c36Fe4i66s0y0;h1A60o1;n45E5;l145s13C;!d349s0;!k1As0;g475Ci35;h0r0;a4Ae192i6;a3D30e17i88EoF;a12e50B;!e68Bi6s0;eDl7s11;aADDe23i6u19;k0o34;n1D2r1t1;k6A;d0r1DDt1;cEg48;h671;hCA;!e15i2000l2FAm2Es25D5w588;g5Bi4lA8m3s5Et2D;s3t3z3;!a2AF6b167Ei9F1o133Bs0u8EC;iF77;lE6n8;c2A0n54Dt2C;f28B9o0;a58AoF;g2F47n1362s477Ft2562xAE;e14Ci87Ey0;a40iB54;y1A;!a4De15i21l22m63o12s0;a1rEB;a1019d224Ce1DDAg3356i3A60n89o3451t4B61uF48v6A4;e23i21k89t19E;c4EC2i3C3k2Ct1Ev89;a4AiBy0;g1k28q36AA;kA97;a4D4Fd1e303Di2328k3428l50E7o28p3418t2B8u1CDAv3FE8;!eBi204l1A47sA0By0;u1EA0;oAFw10;!d0m61s0;eAgDBAi6;e188l1D8p257r2C4s4E;n2869;!a4DeD83hBB2i21s0t5B;!a4Ed37EDe2325i50FAs0;t1A50;!g331s0;!a3A5Bi56u34y0;c6DAl2004r3B6;!o28s0;l1AE3;h13A1s0;n47BB;b601d0g423Do1p8A9t1FDv29EE;a4DB7e2878i238Co3373u2DB3yA75;!aEF5d4C71e3582g2B32i17BCk47l76n1608s153Dt114Fu4Ey0;aFl44o1;o19;a4A9Fe4329o4983u10;c84r70E;e30A5o2251;!m4As0v1;i45o49;!k53;!a7Fe1Bl2Cs0;a47A;c22D9n2o10;!l76s0;e5Bh5F;!e8C;!d2CCFl28n58r1s8t47z194B;u585;m4651;m4Cp36t3;gBn749;a30e288i3D05y0;a504Db383EcE54d182Ee4F43g18D4i327Ej43F4k9D4l4AB5m1464n3D7Ap405Fq32EAr323Bs4929t18B9v14B6w22F2x4833y1;!a1B4e4i110Do1s0y64;!a3FFd0o2F7Fr1s0;e1Dy76;a8nE;eB9i3D18o125;e1i16E;l1500u1;a8e72;n398rC2B;!i7B9;!r802;!d0n1o9r1s0;d2Fi4u5;a1F5b15Ck1Al1m5043r9FAs1F;e3500h23Bt4C4E;d29B;s1B6;b7Bn24Ct19;i18t0;a5o14;a1o14;a7e45;!e351h414Ai38s3B60;f85;!l14;a30e4853i20C2o4A4Dr4D07;nBt3;n1D06r4F52s3;a9c0d3t3u14;t3E21;!e3Ai111;a403Ae1E4i175Do452uB9y2C4;!e15i6oBs0;s4C07;aCc33FDd0n2sB2;lA8rFD;i4l35Ao29;l244Fn8;e1uF76;b7Bs1D4Ev538;d1DC;!g5Bi25mA1p835sEC2u5x2DC7z4AA;!d0r1s3Ex0;!d0r5Fs0;a2C44e38F4i1CF2o333E;i57D;c2F16d3738l2FC4r13A9sEtD66;!i290l7s0;e25BAr2027;a249b579;!e1p4510s0;r6F;!b3EA3iA3EmABo11Fs0;a319o2D3F;!c2EEs0;r194t11;o1B7z147B;i1248u5;o41A0;i185;b147d0e14n4159r1;!f37i6l22mABs0;bEEn14CDv4577;l291Fn4;z4F8;!e1Bm76n22t126B;z176;e5m1DA1;!p58s0;n1F1;e1h2D0i3DkD55;!l1As3783t4734;!a0e0s0;d0g1t150;a67De9o50;l12E0;!d0s0w25D;gDB;!s0t4D81u1;!h515t2686;a8e10D7o10;i24E1o258uD88y64;i3Bo267;aA64;e4BD1;h4F2o45E;e20AAi317o299;o2DD3;!e73Bi6l22s0;e108;!l2AFs0;l136B;iBBo29y0;k21Ep47r1A38s25BtFDw325;e4h1E;!e12i6;a4C74e9o50;!e5n2BsC62;l3453;i4773;!n7s0;l1n2v191;a36e208pCEt3Dw0;r4B2F;a30Ci178o9;!e4i6r237s251;b1FBeAi6n28;!a72e2836h9Ft1FD;e4i6o239;!i465o29s0;!i31o1s0t19;!e21F5h4638i4B86oD5r2D76s0;c0l2882;a3181e2694i86;m4B4r74E;a3i41;!c127Fl2F9Am168Bn297Dp30FrC93t4A20u125B;r39s0;!a0i160l1Es0;i2A17;e1lBs1F;eAi2E6;a30o8;a300Ce30i896o51;s52t6A;p27vB2B;n4s3;!c9CeAi6s0t4C2A;g5Bs1A5u5x1A5;c32g1;a65Bu55C;c173l2DB0o12r12Bx1A5;b1126dC05e13Fg3100i260Fm29C3n3F32r42E5s4C99;!aD3s0y0;a24D7lBuA0;e1iBBy0;e309i5F5;d3E63g11r1449;b24C1e1g3E7Bi915m26E2n3BA0p406At3996u244w1575y1;n52s14;n3s14;!a36E8b4D69c2BDCd3AF0e3F4Ch3066i2ACEk89l2B5An3BADp32CAr1E74s0t2B29u36AFv1Aw1A2D;sE9C;e4i190y0;!a2FCAe110i25B7l22o3C23s0;d3An2;!a9CDn310Ar14E8s2C4A;!a218Ec2EA2d1E72e411Cf1E3g2FD6h50B0i4B49j21Ak4FA1l108Fn1687o254Bp40A1r19E0s4492t38B9uEDDy493C;p6C0;!d43D4l192m1p1s2Cz2C;a0i20;n8t677;a11DAd0s5t0;aA4e1f4815iEEt8B;r471;r240B;e4n1E;h50BB;!e15AfF5l7n22s0;!pABs0tBD;l144t1;!a7Fs251;i6E0;!eEt27;!rEs0;a1048i2C30o2518r185;p33DA;aE5s8u14;d3CBr1z3F4;i4D4;a41B;!uD;!b31Dr1A;!e4f37i313s0y0;!a4Dd0i21l210r1s2365;iBo42;a65eEi31;i1r9B2;h14D3o1;e4i4430y0;!a10e50E2l220p2D3Es0u50D;e1s4D6;e6Do81;!a2B7Ce3DC7h11C6i3443o5Cr512Cs0t4DAy21F0;g0o0;g3DA2j185Ck1l28n4B5t3D19;i5CA;a24B8d4222p44FqA72r1941s702x4A58;n0r7BA;bDC;!a4De235i4EB0o504Bs3EyF2;!e21Ci4E48l7s0uAA2;e72i6Fo8A5;eF6Ao1u9F1;v19B;h38uB;a1919;uC00;b27eAi6;a20e6C;!eDB5i1F6Ds0y0;r0s903;a0t3;e159;i1B7B;t2ED0;e3DA9l1;e14kB;i56uB7;a2A3i36;tA77;!s50FDtB8;d27t1;eAi2696o1B66;h407;!e9l18Es0u14y0;i2C0Eo4255;e2786;e3598i31;c11s11;a49o1736;u1158;g167i25m513s1AE;!a5088e376Eg2845i1BE2oB16s0uC11y0;n6F5;d288Ck5Bl19m1Ep3F9r1Ev6C9;!a3E2Ee4i6s0;e12i96;g4B48;h1F08;!d0e1nBs0;!e64EiCCr7s0y0;l82B;a2E5Be4D51i21l28o9Er1788;i2E3By0;!e2F2i3EC7s0y0;i4E56;dE3m19;h100;d3Cf7;a431FeD3An4E2As3AEAw0;a9e9o50;b1Cn2;mD2;u4F65;cEi10qC2;i17;s68t1;c121i18;bFF1g231n4465;e10Eo1;!b1FB;!aECs0;h44B0;!fF5lA0oA0;a259A;eDs1A;!aCi2648s0;aCc1s14;!e68Bi6s0v5A;e12n3;a1Db4511c4EB7d3C7Df3A91i372Fk5Cl9C8m2501n2CAEp16A9s50CAt23DFu46F7v1755y22D3z3635;v266E;m63z87;!i3D;i272;r2179;!o54s0;!d34CEe65Dl47n502ArBs47D7tB47;!c0n3A5s6CA;i50y0;a39D5i3544o364E;d0e1n0r1s0;!aF1b1F23f920i2B5Cl6Co5Ep308Ds0;o10rAA;e28C2i275Cy3376;e1k2219l7Ct441EuB8;l16r60t16;!e0i0;e12r46;!a0e4iF9o12s0;!e67fE2i43u57y0;a1739e4B7Ao1CB;d0n29C;e35D3i4E;e192;e608i6;s3CtDC;!a10b3E2e4f3A3i21o2D1Es0;!b29Bs0;!a322i10Fs0;e92v2659;!p1C47s0;eA31;!d14B8e23i21;fEi10m0tB;!a4Ad1838e15i21n0pB0s0y38;a24Ee1i4683o29y0;a4C35e9;m1931;!a432De39F9iE1Co30D0u45Fy4C6D;!l3B7Cs0t4B9;e4BAi2CE;a5060c2B19e162Ei2D57k4A29m50F7o25EDp3DB7s14FBt44BFy971;!aCi160s0;e3E9i2EEAoA5B;k110A;i1F9l0n11Dt21B;d5A;n7r55;n0r1DD;n84r1;aCb58e1o29;rDB;!e26o2s0;c20AB;aBAeE4;e1022;a7FeCCCi6;!a4616b58e4F3i451Ao263DrF9Cs0t396FuE0A;nFs19z19;i44AAy0;d0r1s71A;b42Cc1C96d314Df1F24g3625l1E0Am3E9FnCAAp424Ds3B8Dt1322z2E9F;!iEs0;b2DBt136;e9i3Co260;!iAFm1r3Cs0;d78l3Ap1Es35v19;!e0l293t19C7;a205D;!b181e2D5h58Ei1515l1793s1Fy0;!a5050b48A0c4578d40B4e49E7f13E2g4BF2h32E1i2A25k16D8l1D27o10E1p1A5Cq30Dr2B80s211Ct3A77u32BBv226D;aDn0;e90i0;!c393d1B0l1n22C8s1ABBt28;d7Ft457;l18m2F;r35t20;a177e3D88i21o653;t1D;e336iE;e17i344DoBA;!a10C2d2578e2F9Cf45BFi21l2CB7m39F7n12FCp49ECr16BFs0t1EAFv4948;dBt195;!a42d48DFi2Bs0y0;!a4Be109;!d3n0;i287;a1C00oF1yC;!a94o134s0;!g22A3lF3n27C2s3D58t838;!a40e22Ai6s0;l62nB0rA82;a1i27y0;!c3D;l253A;!c15F;!g286Ai6nCCEo4r33A2u4C00;i775r5A;!p2989s0;i1C0u9AF;!h4F2l87s0t272ByC;!e4s0t3;tBE;k4C7;a4BEAe3321h1F3Ei1A5Bl458Cn12F7o4A3Ar1E70t4581u4982w34y170Dz34D1;!e4m2B3nC64r147w9;!d229s0;a2457e4i21r165F;b337Cp47;!b62e1g1r667s0;a399;n6Du14;i1128;r7uD;l4846r1A;c2Am3;e228s11;l1Dm4022n4418r1B0Au50;l71A;!l19C;c1gBi12;d0l4DEr16;!i7Dr1A2s0tB;a2B0Ae3421i3A7u312Fy0z1A1;a85Eh1AEo2BC4y113B;r163;a8c7t3;fB3D;p4B41;!e15i6l4A90s0;!eC0i6D2n22o9Er27As0y0;a37EB;!b4968n1F1s0;pE2;r555;r22F;!r1A;!e1i2D35;a1e5103i37Fp1F4u5A5;!e36Ai3Bl7n22;gBl3A;n2s1F8;c1A7D;iB21;!a4Bi96r7s0;f7o10t19;c358As0t2C6E;u1BBF;aBAo177;!d0l1n0r2Fs0;!c9Bd9Be2B3BgAA8i42D7k9Bl462Bo3DACrE84s0u68Cv1E77;l614o28;!g7Ao10s0;!a92e1D16o6F;a4396d1Ae33FBi2E5Eo0r2B;!e4r0s0;a36h523o449t2AD;!g398Fl248s0;iBBt1;c2Ci4n687y1CF;tAE5;p20D;g50Em913;!e15h156i21s0;a36e1i27o36;!cE3i6;a0o2425;i1C8D;c9Cd151g2Ct2FED;!e0l3As0;a3D65dBe18F2i819l3456p8r42BFv5B;!e23i36C2s0;aB2C;a52i13;a227;!c9D3f364Bn2698rA9FsFA3z18D3;c4E6AeDCt0;!c171e4940g6C2l56pBs0;n1r1D6;e166i2560y0;a47BEi514Do23CB;l16n3BD;d0r1s65;l1EFFr584;a8e24;i47DDy0;r9F9;d0e3Bs0;!d0l17A1r1s0;l4E4n1s36EDy16;n24F2;!e2467i86l7n22s0y0;!a3B4e470Dh156i23DlCEo56p162rF6s0;!e36Ah0l7n22;f160Bi150F;!e1i2Bl7s0y0;!a51n28s431Ay0z176;!i1E8l7s0y0;s51Ft7;!e5i27y0;e1i19Ay0;h346Fk0o2846;l5s49Ct2D;!b6CCm229p38s37BF;a88i2ACFv27;!a2412d3BD8e1i1033o25B8s0u19BD;a10b3ACFc1C38eC14g2D54i4o29ADp2E9Cs1790t3A4Eu324Ev13DFw383By4;a382De1C72h279Ai6n310tBDu4548w9A;n3B5;a5t24A8;e26o6B;a30eE;d3EAF;e33oDy0;mA1n65r34;f309Ei1A;lCm3s8;a125e62o2F33;d0r4E4;c11k39v191;e1m0t1;m8Br21A;!h1s0tAB;r3s99;eDl7n11E;b2AB;k39qC2r7;s2B50t117;a88i701o39B4;!e5n2Bs0;i31o36;!i3E47l7;a2EEi4E;o258u6;a549;b9A2;b1Cg167;e61h1D46;e1o29y0;a88i2D4Fo98Cy227;a30BFe2C22i1224;!c240Fd14A2e1E3Bg3CE0h7C8i4A43k3lC0Am14C2nBCFr3C3Fs2223t28D6u267v40F3w144Cy3316;a6EeBB8h213i2ABAo1DCAr7F9u9;o42E;i46EEp41;a57l23B;a52i0u5;a978c0e5;t4966;d2DFs2C;c1802d1D9Eg4847kFB2l2CD1m214EnBFCo4268p4CFEr4278s341Et4919x78B;e12g38;l4EF7m5Bs3B79;a4C69e1850i6o487;n3t5E;t688;!n3t5E;b369;!e4Ch2FE4i45B1s0;e0i289Ay0;!d1e4s0;!a17e4F7i23Cl7s0y0;!e14Ci86s0;a324Ad4B55k5Dl15C3n2DE4o3F6Br1t2B54;bFE7g3Cm3224rB;!a1e4h1Ai6s0;c84Ee1Bf4299n22s1381;c6BAd1B02e536l494Bn332q3DD6t1C2Cu425x260A;a4C32u14;!a6E8c1C9Be23h151Bi6jF2k47l5Do2173q9EBs2B8At4C60u28A6;n5EDp130D;a100d1l8r40;m1r48;l1r0;s4BFE;d4AD1;!e46DDhEDi3Bs0;m63t2E8;a12o31;l188nE7Ar3600;e1Bt1;n30As8;o36y31;!c9Ce12o3E18;!a0e12o46;e109i69;!d0n5115r4650s0;!bD6s0;h70t102;!e15i43o9Es0y0;e6Di2E48;!d0l22r1s0t125;aD0u69;l187Cs36DC;!cC2d0l1qC2r1A3s0t1CC;!b1E9Fd60Df823g167l2586n460Fs44CD;j6C;u62;a3296e1640o3E1Au71;!s0t839;a1oD;!e10Bi486pA5s0y0;e1Bl7n193s35;!d3Al7r0s0;s2E4u5;!a257Ce44D7i2017n38oAE4r3602s0u4874;b227gE4l12BnB0r30CAt2C;!c56e12i8El2Cs0y0;!eA9;g2B9Cl83n102s42Et186;!d0e10l1349m0s0;e24f7n2;a249e23i6;i4DB9;d1Ae1B4i1B4o17D7u2E8A;d1s14;n284B;o392;a51r31;e26B8i86;aCe82;aCe4;c48i4;n47CBs8u5;i4y16A;r5C9;d0nFr39;!eC0i91l19p4Cs0y0;i51o134;b2788;h77;!a4025e26C5hE1Ai96Do1r3FBDs0;!e0r78t3;d51E;!e24h10Ci6o28C;!a44FFe4i0s0u5;!b2E2s0;c2Cd4168i4s9Ct60w2ACy17B;aCo29;r1B9;!e1Bi1C8y0;!eB3i27y0;m70t2D;r393Cs7E6;!e24i21u1;e1s7C;b1C26c3F5Dd4CB0iD8Bm1B11n494Fr2ADEs4C9Bu3BB0z4A1A;e500Bi86;h16y16;r36s0;m87;e17i565o46;!n84t1B7;!n4795;f18Bv24F7;e8Ci73y0;d46n7;pD2;t1E5B;m1ACu4E;o2C7F;!c2Bd6E6g20An30BEsBA5t47;t4A5D;!b4BBs0;l2BrDE;i31l2CE4;e4987y3955;!c11d17Bl0r0s0wA7;eB61;a1eBi1;eAiADy0;l55B;a5084e529;!a20F4c3B35e30E2i4D00r3497s0t4273u3CB2;k8F3;!k28;!y1C;i8E5;a7Fe33F7;eEi3F0F;!e15f37i27A3j238l48s0u57y0;b1Cd80;eAi13o36;!a0dA3e4i6s0;n1r354;s3t19;l3DDE;d28e10En28;a125e0i148AoF50y75;iC6o1;n1C4;!e15i31D6s0y0;a1d249Ce346i3E26m34C7n336ErD14s536t200u833x115;a40e85i19FDo103;a1AAAe1AA;iC6;a2DEBc4A60e423Ah3E2Ck2F34oF9DrFF5t4F10u12E4;e1Ao310;a1130e3EB1i1E49o2723u28D4y4746;a36o49;!a308Fi3B8Eo2314s0u50By0;n4s8;g33BiA3Bs446u21Fy47;u2850;e7ECrF2t41FA;!aF1i4D0o10s0;r16s0;!r16s0;e12nF;!p357s0;l433;!a20iB54o12r1A2s0u5;t662;!t662;m301sC1t2D;a3382;h350p16Cr483vB;a10e2C5Dr522;!d1e201g1B1Fl4DF5m6F1n199Br2BFCs4FB0t2E21;o972;!e21Cf37i97Cl7o1s0;!a4s0;n0r1A;eCiCo9;c890e1s107t58;aDC0;!d3Ce0i8rE;i33BBp1FDt4242;fBFu5;s34FA;c1B39d11Df386t1B7;e3Fl29;a763o94;l76;a20u19;m113n1;c36E5d511El1D52nBD1t2D32;!c3D9Be417Bh21F7i6l18Es357Ft14F9;n15F2;a212De339Cg2D4Bi4El3F44m18o1C1Er3BC8;!a378Cb575c3AFFe46E7fEg10i37C6m4C8FnC8Eo3E8Br4D79s1442t2AC6u29E3w190Cy0;e4i1B3y0;c1FA9d3B00f1B63g2A6l16BAm10A1n26DFp3CB9r37ECs27BDt44B4z218F;b1n4A9;r2As3;e45B;c0n2o9s8;!e4fB26i6r318s0;bBd1f3E3g35FlE6o3B7Ft34DEu48E4w1623y1C;iB0Ao5CD;e292Ch35;a1EDe1i9o29;a17e831i43D;!b1Cn294s0t21EC;!a349Fb4B7Fc2844d2593e10F9f378i1597lF98n16A5r1BD0s2255t12A7u1Cv4301;!f6D5sC7u1w1;!d0s0y1;c32kBn2o10rB;a51e4i43l19y0;!bA7Bd3D9Eg2FBl1E83m6F3n8r40Cs422Et3963;!e33BDi2883s0;e3ED6i6r5B2;l0t19;b2C7;i1EFAy0;!bAD2eDF1o5Cr37F6s0;a28De90k458t24C6uB7;c361Bg4355m101En49C9p8A9v4F20;u4441;!o0s8B9;n8r78t3;e1F5;m1586;o810;a2B9Ee38B8i2762l2FA3o1F64r44ACu14C4;b2DEC;a258Eb28e428Ai26FAo301Br3229u16E1;e15i22B4y0;e17i5130y0;a571e152Di3850o3510u4E;a16Be297Bi2DFo52A;a4360e400k47r28t144;e1938i86l48y0;i185o260;!d0r131s0y0;e4Dl35o46CtC7;v4AC;t3988;!d7Ae423Ci21l2FAm2EsA5F;!d0i6l222p155Er136s0;i239Fy64;!e4h1i6s0;!f7o10t2A9;a3CABe98;!e4i21A0s0;a3741eAi10EF;aD4eA70;n351Fp1A9;eFF;!b2B35e15i21n0r1As0;e17i21;e153i6;a0e23i3AEEk27C7l1A2Bm3FC4p1FBBq123s4BA6t268Du0v44A1w9By0;uE35;!e10Bi21l170n22s0;y6D;b3FDCe2705p1716s241u689;!e4i6s0t142;e15Al7n2;eC0l7n2;eAi21l1A91y0;a4A9Et29B7;c39E0d169CgC2s2854t1990;h3A50;m4DDt234;c84r84;d16l0r370s92D;f2A2A;!a1A74m0n2922o366As0;n41t1;l28r1;!iAFs0;e1g1i3F;s7CD;n18Cs2Cz2C;e1Dl22;!i10y1;n1o9p1t1w1;aCD;n2s1FD8;!m2Eo1;e49C5u5;i1835;!e14Di512Am2Es0y0;!a75e4i2ED5o6s0u14;!a4610g836i359Fl4192s0u1A59;!e4i6oEs0;a18Fg1;a4C28r9F;e12u12;!eEh501DpE1t10ECuB0;i152l44u8y0;!a53AeAi6p229s0y0;!g44m4DDn3y47;e15Di66o0y0;!d0m2En0p3A2s0;!a3A6e15i3720s0;c5025d2BD1g2EE4lD1Em1428o45p4F99rEE2s1181t2789z3B8;e6B6;oF51;b1CAc24Fo10s11;bA5;d2Fe1791i2EC1k1C4o292v4BBE;b17E3r101;i25m1A;i146E;!a1i13s0;rC7F;b5Cg3;!d0j6Cs0;i11F;cEi10n277;gBk4C;!e1i5042s0;c7t3C1;!e3A10i86l2D64s0u49;a177;lEn8p1ACt19;!c13CCg233Ck1n3B5s15FF;!a4BA1e23i6oAEDs0y4A0;y25D;e0iB4F;a202;d0nA3Fr266;aA06dB0Dm790;!a252i9k1ElBs0;lA8n37Du59;o4D76;b46c1Eg46F4m276;!d80m2Et27;!l2F1s0;!a151m63r7AsEEEt28;sBt347E;l1E0D;!iEmCEn1r36s0;!c48s0t2D;!d1B54l959m203p1ACBs0t3E2;cCEe24;!a11F5b132Dc4224d3937e44C3f13D8g23ECh1EEiE48j7EFk1F16l46C9mE10n2692p25C0r213Fs17D2t3B21u34w209Cz1BFB;l9Bn325Cr425A;f108m4CD;a4Ce166;e32ADi31EDo3C32u47B5;!a4DfC3i2D9Ds0t8BDu1;!b24F9e15fB5h2F7iB19l37DBpE1s484Ew888y0;!d7BFe0i4800l1nDB8sB51t12CBy1;a539i318Do1BEDu117;!nCCF;i4lA8s4DCu5;a4962cB2dA3e1f322Dl27CBo474Fp22A9y0;s1Av9B;b407wA7;e24l1Cn1;a2E94n40Do3E4sD3;!b1Cg1418l1n65s0t3;!a299dD6eAg5Ci2D4k4251s0;m514Cn213E;e4F82;a3529e7BEr3050u1C05;e5A2p3B08;d0r698;r1E2;h11B9;h857;!lB5Fs0;aCg0;!a3734s0;r82C;a2CEDe2ED7i44B6o45B8t2FE3u110;d0lBDn366o45Es11B;l4C7B;!b1C7Cl806m3026p5Cs326w2C0;!d8Ai2EB;c44iEv2D3A;e464Fi6l22F;!e2EB9h1B7i21k3697m2EsF0;a0c0s14;a51i59o1192;u295;h4415;a393A;b38p4813s27D;!k4Ct39;m175;aC69u335;!b1Cc7m114s0t3286;nFs1F;nFs11B;i10y0;o6y0;a434Cr87;g22Dx1F;!i6pE;b1Ce24n2s11;dBi4lA8n1s1839;p1r1;a7C3e633l1B50n48CAo10w1;!b1D7j323Fk2DFBmDDn1C08p162s4A2FwA7;l292;!c221CeA22i3A7l6Cm2Ep84Bs47B6y0;!e4i6l216s0;a8c8t3x0;d0r3EB3;!e532s0;!a2543lBo0s732;a12l2Co4D7;e2D9Ei23C;e36B;t79D;!c1E6;e47DFi6;eDr42F6;h4120i3Cl3;g28Al2A22n3A0t1CD;aCc121n3;e348By0;l44u93D;!a57s0;e1Di2C6y0;aCe443Dh2EAEi6A7;r8s5;e7i8E;n401;o86B;l3836s161B;i4FAE;n2o9t1;r2AD;e10E8;g11n1;aCr3D;k10F7;e989;e201i3C;!e67f37i66r135y0;c11t16;!d3D48e37Eg4D2Ch2D7i491Ek30ADl4FnF41s0t2796w4551y0z3;r758;!e750r7s0;!a143e17i610s0;g4Al360Ft47;e6Ei797oE4;!e1i1FA;a51e17n1s11;e126p377;!e569i8C0s8B7y0;!a4Be15i43s0y0;!b1Ch25As0t44DF;a4De49Ai18Do9Ey0;a4Bo12r1A2;!i13s0u3;e62;a1e388i46A5m89p3AB0;nE81;a4Be208i2C04oDr1;r3s11;r24B7;c3A71fBFn2s3DEt989;a600;!d0s0t27vC2;g47k306;!a3B6BiD86l5FDo1E73s0u1B0C;u20v19;d8Dg16;l38D9;a1i30C1;!n70s0t84D;e3FEF;c114Cf4282g4DA5sB2t282Dv2C;l43EBt28;!aBF3cF2d920eEi16Bk4455l2D2Co8Fs0u489;!a392BeF99l7n22s489B;k398;!a42e4i41DFoE30s0;!e1Bi299Cl7n22s0y0;n13B0;e0t11;e1C9Ai45B5;e33i5t1;u11FA;!n4FrEs31BEt85u59;a4BeCFi43y0;d1n2531p3B3Ct4992v5E3;h68t27;a2C4Fb1AAc45FDd4AD0e3B5Di4172l3BBFm26ECn4545o1A4Fr1FECs17B8tC51u34w2F83y2CC6;i142t40;!c629e3F1h1m89Cs0;b473i1D3Cn83;c188Di45BBs76u1F56w2BBBy38;e2Fi855y0;k2C;a2A57e536i250AoEF9;a3C76d458Be3D12g716i3CC1k353Fl1254m2B04pB55r397Dt33Cv18;!d0r0s8;aCe23i2E6y0;d3CCnB;e51Bi66y0;!a4De43AAi6t45A8y0;n40BsE;!p19B5s0;!e256i28E;b1Ct1E;!l0s674;a0eEi4o67Bu14y4E;!d0f37s0t20;s35B;a8A4e330F;t1F4;!e90h3213i4B87k339As0t2EC3u62F;eDoD;g97k48t0v19;h543;e30n2;aE5n2s99t7;c2558l2FB;!a29E2l7E1s0;!e5hFA;e1hFA;!m354;m354;m2142;b3737c3ED7e4A94k14Bl1E34m4F88n3C22p4435r3A47s2DEDv38z20F7;c423f147g3768n378z1E;d4;a1De27Ci6o12;s11t58;d0r16A;o15D4;!e4i486s0y0;!e4i3CDs0y0;mD41n49D;r3B81;l3CFD;a1D8Ab416Fe4E35f1F3Fi2B46m42DFo2EBAp4FDBrAF7s864u4E;!e2B62i96Dl7n22o305;m9Bn1A;cD1d0n49D;a1A7r5AD;a125;e1i3C;aDEc13CdD0AtCD;c84;a4F22eAF9i547;a3E4BiFBo258u246;!a3575c406e24BBh3801k3E04l19r5069s0u333D;hF8i5146l58A;a1e352l216o1;a30A8e2505h1ECEi1C57l1EEEo32FFr455Eu2736;i2BB4v19y0;!a4De23i23DuB8;r733;eC17i25B4;!b1E2d0f37l481m63r1s0t125;d26Cn1D1C;n8r1t102;a269BeC9Bi480Dl108Ao1463r127Cu3DB6;!c2C0fC3h10Ck47l22n397s0t0;aD4u2D41;!e224i204l7s0;!i27s0;i458Ay0;i59o54;l1n221s15E1;b11FFc3B18d4300f259gD68h1i20FAk1290l40F8m1D4Bn14EEp2355r2585s3691tA2Au2D2Ev3C6Dw4CBEy1;c32n1r25;t39u20v48;!d0s0t8D;e5n179t2967;c1AB6d46DE;e4i6u1C;!a38DFe6BDiADm2Es0y0;i2BCFp50DFs89t1CD1;e5t7;d22F;lA1Bt4B2;nFu47C;aD4i17q9BB;l1EnFs27Et7;rB4;b1F15g2CE6t32E;e4i3C4Bo1s0;i2074y0;l32C7;a9c39B5f8g1C4k4DEEl265Dm204Dp3C01rEs0;m213n227D;!r452s0;m2ErE;i0o134u5;b7Bm1161r3B6;d5E9g5Ck28l72Dn4710o3771r4ED9s461Et23FF;!a4B4Fb2C5c31CDe3CFBf4DAi3D39l4E37m1EE8o3BDCp2CBAs19ACt36FDu1873v4860;a34F0e0i3255o12y1B92;hAC1;a6De35i35;a47B8h21C4o1645r83;a12gB;i13lA0n494t1602;a4Et1750z0;a541e24D0i1230r7A5y64;a40e281Di4D2Fl2611oD4r3B9s2F54u4AF8;n287;!e17o46s0;aCi1FE;h171o56;h318E;!aAC0e9Bi25o27E3s0y52;!s18t1;!l0pC4s0;!d0l453n48E9r163Es0;!e15i405Ds0;i4F4B;!b5B3e4f4152i6k1AF0s804tB93;a188c62;b1F3s5Et2D;g1r1;nACF;a4D65;r21C9;e0iAA4;!e5n2D;a474Ae32o213Bu71;a1e3C68u3555;a0e1Di420o4E3y44B;i72o164;!g115i96l1;a3Ci2C7B;i13r2D7;i333;i13yC;a9c0e5;a20u69;e3EAE;i20E8;e17l2B;a46C6e18Ci1363o3AC6u2C4;d0n0r0t0;b1CBsAEt0;l3r85;d1C16m2041r3BC1;oB39;h1r368;l1199;!a11D8c4D77eCDi4l11FBo481Cr38BEsB04t2088uB8z1F;m4AF4;!a45c440Ee0l55m1673n4CCFp1A4r1B56s389AtB6y28;r3583;!c53e1;n2As11;n65t16;!m3B2Fr1s0;c182t1;aCi29D;e1i233o5u5;f19v19;n3192;!e4708i6o0s0;e462Ah1l16BEu4Ey5E2;a9B6f7m27t49E;d39t16;d1102e1v3D;a36i3CF1;d0lBn1;!a4Dn8r16s0;!a174eAi21o12r22s0;!e1i465s0;e3FAl7o10;a0i13o9;!a0i13o9;a20F1b32E7c15CAd180Be422Df369Cg2E00hCDi344Ek224Bl3C9Am34CAn24B4o181Fp263Cr2AE7s5108t28DDu2995v340Dw2C7y188FzD51;r1v1A;m163;a281Ae0oE7;a2B41;!m3F45p41D1s1F;a4A5Ei2F03oF2u8;h583o10;!e4iBCl25Bs0y0;e0i1FE;!c197d1n39s0v48;x115;r3BD;!s0t41;e220E;d38FBr47;!b2CF3e1Bi3Bj101l275FmFC1n22r51As0t506EwA7;!e4r7s0t3;!c522n2t4FB;e0k1n0t11;f7n2t3;a10t1646;d3m7;!a3F6Dd3CBg4314i6l381En22C3r2A9Cs16C1;uF4A;!l8B6s0;s2B7;!l2F95s0;h0l4197rF59s333F;b1141c33CdEABe4C19f362Bg74i17Fn3268r2F15s2EFE;c0f7s19z19;g14n2s3;i20oE;e4i312y0;a2DB2e1438h3AAFi44D3o3901r4436u672;!a16s0;a487Ab3353c1240d2E8Ce3556f33Fg4D48h12FDk18El4933m16D9n4D1Ao365Dp46D5r17B2s2C9Ct2F02v1070x3BE2z3427;!i2BBl1Es0;!n203;!a5E1s0;g27F7l278;e95l3;!eDs8;e1EF0i6o29;d182m16As0;m1787n4FC9r1C63s26E;!i9s0t1;!b156c428d437g2606i4n332s0t1320x115;e1Bn1D72;a1976s0;e43C2;c2EE6o127s2462t113;!e1fBFo159p12B1r1E7s1A7Ct0w84A;!e46Di91m2Ey0;h477o81;!eC74t101;d39t1;e9i9;!d0i6r7s0;kE0mE0;zE34;a2062i73y64;l4AFEn1;!r4123s11;!e290Ch2Bi139Ck4698m29o2853q1AA7r32FCs0t1A02uEB7y0;r2B6;d0l1565r0s8;!a7Fb12De15fC3i21l22s0;aCe0i290;e15DBo4D3u4006;!e46Di91y0;o7Dr2B3E;c11tE0;!o10s0u14;nFv1F8;!h27s0tAB;r2BDy1;a31E;!aFDAd0e1Dl22s157t3C;e16D0u2E54z349;e1i15C4;!a4FBFb7eAi6C1o923s0u12A0y0;!n5F;e8BAp8DA;b5Al2FF1o5014t5Aw1;a31EB;!a4De12i21l54Fn0s0t4A;c1n1;aC5DeD7Eg28k28o224Ft41;g97k16n3261t47D2;a2897e288i2D4;d151n18Cr2Cs26Et50F1v106;c41t3;l4822n4E9r7s3C3x1E;cB8n1F42r1s3D73t1u30;c19l1D;!eAh41i6;c14AE;e3E34i2By0;!d16;u26A;l3D3Bn33ADs8;eAi14;!a270c49EAd2E2Ae4F32g1A41i4D41k2EC2m68En2753o4868s0t44FDu4D8x0y1A1;e27D4;!e5f7n3s52z3;!i6C3s0;!hFBs0t464;a33D5e32F4;cF4t0z1A;a1B0Ei5100u315;!a6B;!a270e13E5i18Dy0;i2CDu47F;e9l2C;e13BE;!e4i6o9Er28Fs0;!e8DDi6s0;aB0;r1F38;!b1FB7e5i56s4250t0;!d0n39s0;aCeB7;a2BCBe9B5i132l87;n0r5C8t1EB8;e5i31l19o46u1C;!b3CAe129Bi296m2Eo4E3p1169s0w253y2D5B;c0d3t3;a180e1k5Dn267Ao29q98A;iA9;g19n1;a13c0sFEz3;!d564e12;!a45DDe32B0h161Ci359o2669p7As0yF2B;nE3F;eAi8Ey0;a265Fe2362i1540o4D15u285A;!a399Fe2D6BfC3iBCo2440y0;!e5h27s1F;a4B0;!f7s619t7;!a20CFe1DfC3g2CA9m2En462p1BDBs0u1281w4E1A;o1BD;f1E7p253F;!nFtB4v3;k4F06s1F;i1B9;d0r409s0;!e4i665s0y0;!a4Be1B2i1A46s0;hEE;a70F;e10B0i6l2C;f46n1C2pC2Er318;!e1A97i6w80;e2801h2A02o1440;!a6A4h76k183Co339s0;i45D6;i41E9;!b17Dm3413p932s78;a4056b1765c3EBCd180Df50E6g5000h45FEkF20l30BBm3C16n33A6o4F2Fp2200r461Bs21C1t3815v355Ew5Ex40A0zC6B;e9i2B90o45DB;a1DA;!k4Co1CpCE;a1cD1g783l46CDn2423p38s3D7D;e1v3;!g3F3Du34;l3035r4y5;a12i2By0;!a31BBe4B47g62i1t38E;!e4fE2g306i6k1l28n0s0t4B62;r4A55u116C;e1u3;rEs19;e831;gD8l163;c2Ae5n2;c26DBd0g231i79FnD56tA0Du5E1w59Ay2866;c459Ed369g8B2i4n544r2080t468Fy13F;!i5C3s0y0;r186C;b46A;c11d1;t245B;r5C8;e23i6l19y0;!i1E1l22m2Es18DCwA25;e63Eh35FDi21;i655;!i77s0;!r1s5;!d419e4s0;!a4EB8g2331l1B0Bm2Eo3B77s0uB;!e13Ai296s0y0;e6Bo6By0;!b286Cs0;a322;eDo10;!e4i95Eo50s0;l1D0u1D;u4D9E;m5An2;s1AD9;r3EF9;c257n19F0r1FB1s84;!c4DC8k1As0;!m1n1;m1n1;!a18Be15i21l1FBs0;r161;a31iB23;m0s34;p135;d1461n266C;a3D5Ee1i5p1B0;a2FFAi2572;!b1937cD1d10F0f3008l31Fp1DF5r56sF4Ct56v6B3w5D1;eB24g4138h35F0r4306;!d3Cs0;!d0h3Cr1s0;!b69Es0;g3E7F;g0s5;e94B;l28n2C2;fBFtACBz1C2;a2B51d1513e242Bi39BBoF2tD6u22E;e351l44;m4Ds55;a41D9e104Ai529o408B;e1w5F;c511;!a9EDe23i6C6s0;a1441e17E1i3187o121Eu379C;i31E;!eEAn3;e1BE;!a2CDAb36F9d42BAeCB6f99Eh10Ci3298n1F1o4D7s0w41Ey4230;n35F3;e1337;p16Av6C9;i8C5;sBt16;i548;a45E8e41D4h32Bk39BFo1r18AAtBD;a0o5;!f570;!n63r161s42BBuBA;a1568b38F2e15B0i1B98mB0o506Dp43CCs3B8u4CD6;c7Es3v3;c9Bt4EA1;!d0l22r0s0;e4C5g1i1A82;a36e1;c0d19n11Bs19t3z19;!e6ABl7m8En22pD23;a137h918;!b3C34c2674eB2Di3D7l4C46m2FE7n22r16ECs2785w1249y611;oCu14;!l1Eo29s0u31;o4486;d22D5i187Bt16;!a0l85;e23iDFr35;i3Fo313Cy1A7;c19CAk28t3F6;c8r1;!a108d41n1B2Do34A9s2A38t28;!d0e1h1D7r1DDs0;d38e3603f1l338Am1p28t38;m3F33;a1C6E;oAE2;m2En2DEo10;e17i40Fo1619y0;!d226e4i21o9s0;e5048i66y0;!d0mD2r1s0t2Dy16;c2Aw80;i1369y426F;!e40i420s0y0;aCBb4584c2833d2D6DeAFCf1991g49F2k1760lED6mBD2n2273p2F10r1624s2703t2C83v1890x1F58zCA9;aD0e1676f2096h9Fi3792mCEo34u7B0;a11y0;!a1DCg2A0Cl3DA6n2E55p8Br1As48D9t1v4385;i25El225oDEr421;c0d19f7lBtB;n1Ar48BD;g1769k5F4t38;a54r652;p199;aB84;a188c13Bo13B;e1m28;c15C9n1C2;i837o81y0;b50ADc1D5d3E99g26D9i2575j26F6kC47l1EC2m68Cn37CEo4657p8A7r37ABs0u4F1Dw2361;!a4De4ECi5017s0y0;!b34AAcD5e590i6l2A7w80;!g1DC3s0;!l685s0;!e9s0y0;d0n4C63s7C0;a4B06b1589c1CEFd43A1e1B5Ef4EF2g4533h1i5EDk50AEl38C3m3CC3n331Ao1220p16C9r4AE2s3753t462Cu4814v34D9x4DD1y5ED;aCr19s1F;m4F;e12r288D;c257;b1d5EFl18y1A;!a51eB58s0;e45ABg38i1AF5o10BBr318;e3E1E;!d1Ee15i6s0;h85l2Cu2D9y0;a0c3BFe2EF3h105Fi4AE7k21ACl4328o3EAq30Dy0;r2Ds1F;l2AD4;!i6FDs0;o81uF4E;a258;!nECs0;a1F33;h75B;n12AC;!a7De15f37i43s0y0;i4D3Fo81y64;!e23i285l19s0y0;e15i7D8;n3DD0;e11B;e4DC9r17D4;iC8o46;e459B;!a4DC4e430Ef6A0i2500k14Al2A36m35E5o1BACp1125s4855t49B0u4F46y0;e5l7n2;t3436;a3C51c425Fh1AE9k2515;d44lF2s1B6;!e502EiBCl22sF0w253y0;!d0l6E4o29r1s0;!e22AfB5i18Dl2FAm8CFo1s0w4D92y0;n2v53;!m2E2s0;c7EAe493g58n2;l1CEr32BD;c2Ad1;!eAh311i6;lB45;!o496D;a124o54;i2Bl2Co71y0;e2B63i6k16;e4i14BAy0;d9Bt9B;a125o29;l4A1s5E;m102t1BAE;e5i1D;i280El399t3281u2F82;o1u14;c339n70s2E4;s0t20E1;e33A;!e0m35r7;!e67i43l7y0;d315FmB;a1Dn94Ct3;h5Do164;eA6r3;a4AF6e6B;s278;a4Ce12;c32t1w80;!d0s0t1379;l8Bu37F4;!h1CDDp114u49y0;rE5;!g14El1s0;!e5i45FFw120C;!dA7eBAl58s0;aDCg48iEs1116;!l2Cs0;!a0e79iC9r237y0;i684o20A7;!a1168eCEBi418Eo33EEu4760w248A;eAh3AC2i6;!d234Fg3596k28n58s0t459F;!sCB;n4AD8;n4A9t3C8D;d4C95;!b1D1e153f37i21s0;m499;r1A6;b14F;fEw9;t39v48;e2B59iCCl170u1Dy0;a4F9e32Ai4558u5C;eF74;cAAn1;d0r4442;a7C7h477iBAo4060r1D0;aCFBe562f0h184i1771l4990m46E9o236At4B5Bv392A;!a508e4i6s0;!d0l6Cr7s0;u2AA;eAo46;aA58i441Do10u4D0y0;!e4D98i636s0;!r55;c18s2A;a4DA8iCo3CC7;a4By1C;a1666;a36l3u5;n342;b9D;a3F04b129Dc4E82d1B88e183Bg2FE8i1719k1756l2Cm1D33n251Co19BAp3AD9q29D7r4513s1E01t35A3u4EEBv3756y448;c0o8ED;cEr1;!aD0c2AAEe62Ai171El80m2D9Cn4073r1C46s17C5t131v3Dw6A;!l3E1s0;!a48Ce3i6s0;d0p0;e1k4Cn2;e6DiB3Fo2BAu814;!m1As0x1F;d0r2Fs8;f30B;kB7;!e67i1E1l5Dm2Ey0;n372;a1F80;aCe1iE5u5;a1E6;!c2548d4F96e2099f906g3709hE99i1C1Ck41A6l29B2m1D4n1CCFr2E09s221Et1C65v37D5yF71;a20eA;!a4D39e67i4594kF6l22m2EoD5p253u4Ew3B1;!d5Be1;o5Du47F;b22EFe2598u35C;a32nF;!bABi5Cl443As0;!b50Ec1A29d0e38A0gBn499CoD3p48FEr3DD3s0t0;e4i6r1863s0;!g2F8h158CrA56s0;e23i4567o46y0;!e1Bi7EBl7n22p62r1B7Fy0;!d0r0s0w80;!e1s1;!b512c36CdB6l4D29n4D7Es0t307Cu90;e69F;a3076e195Ei60o1F86u14;!a10e3E9Bg2BBDn1175o2CD7s0u8F;sC1u5;lDB;uDA;a330Ee4A39g22Fi2F63o12B8u36E7;!a1EFl87rDBs0;!aCi61s0;a72i72o81;i9l3;a321d4EB2e61k1l1F6t19A;!eBg2F8Cl87o147Ds460;!i1Do12u202;f3FC8l29C;h12FE;d429n151p0r1Et60v2C;!l349s0;l5Fr16;c276E;c419;e4By1C;!aCe0l3n2s1Ft63;r16s8;!d0l22r3DA4s0;u163;t156;r4770;c120h184;a50BE;!a20e31i13oC;iE6m1Et234;c1n8;d4AnF;c11i9;a36e2AD1o1Cy1C;o4232;i25B2m7u3B3;!m63s0t3D0B;d0r2Fs0yB;!e15f37i3053s0y0;!e15i6p2B43s0;e1Bo239;e4721i39A0l7Cy0;a10lEEn2309o3205;m63n29Cs3t4664;!nF6s0;i753;m6CF;!c461e9ADi159oAEs0t4F5B;!aB79e90i13B5s0;fBFg3BB8l669;k0t1;!l248s0;!a16D3cD27i473Fk135FlBm2Es0;l0n4DF8p1605;n25D8t2D;n19A;l1FA4;n27;n1C8;e2E0Eo2F46;e16EFi6;a280Fd4E33e19AEi21l2C;a0o3878;hBk250C;!aABBb3460dBe2EB7i21l11F8s0t2FD8;c2D7;!a169Bs0;!lE0m16n7s0;a2714b2410c137Ad4276e334Dg45DEi3E79k1l3E0Bm1o3622r166Ds7D6t3FE3y14C7;eBA;e43CiCCl2Cu34DDy0;!b33EFe1E32i6A7m58o2B18p28s0u33C2;r2B73;a985o5C;c2F62;a221d2399i124n59Eo3E28p30Fs3F22t28EDu148CvFBw46CBy1;!a3096e1E3Em8Bs0;e23f440Ai6t1;i3B28;eA05;!a4Bm2Es0;l278Fn13E;!cA5;e1F8Ai3B;eA2o1;c2BF7r45AAu5;c17Ed0eB8Ci39BAl2715m25C8o4A10pE79v2C;!b4144i3530n119sBE3;n18CAo143BrF;e3132i3B;rA56;b1Cn2u34;i8l44;g19t3;u59w9;g2Cl1CEn113Ap502r1965s3EC8t3u18F4;e3DB8oCDr4AB0u34;r39FCuD;eDu5;i25l625r4B69;r201D;a7EeECn2oDF7u14;a520i8Fo284;!n1F6s0t16;l1n13Ar2Ft3;!e4i1FAs0;d293f38gA3;t1E8C;a1CCu2FF;a2B71e2EF1i2BA4o3EC6r30BAu765;u3E4D;m93sB89;g1E2i20;a1064;a4De2CA3i1BA;e8Ci3By0;a7Fd3Cl63;b86Dc402Ad4930e5g355Ai40D5m3A55n4505p345Cq237Fr3940s436EtA2AuCCDv49DBw1B55x56y5062;e235l7nF;!m42C3s0u1F0C;!e17i4E0s0;!d0f37l478m63s0;d0r1t16uD;a41CFi57;d0e10n16r2F;b50C3c40ADd40B9f4DFEg15D8k1l41E4m388Bn18DAp1559r24ECs139Ft3740v44w1186;i331mBn1sC7;e1i4F4Dr2DB1;d0r8D0t1y19;dEF8;!a4644e4i6s0;y1E;e7DEl488rB;!c485eAh2DE9i6oA24p98FsBt38uB8;d1i10;l948n29r18;a116Ae1ED7l197Fm2322n8CAo13AAr42C1s1C7Du2050;g2F1l4A4Fr35C1s3D3Dt1E95;!c557s0;a22CBc4DB1d36B0e192Df3312g15A9i3DE5k41F8l3F63m11D0n4FE6o2C4Bp1273q2B57r4862sF17t2A77u2C9Aw42BEx2C00;t2FFC;i3D3;g3t1;!n1At3D;e139i38;!hEDi204s0y0;d22Ds0;b5Ac3490e27B7f599g1E5FlAA9n235Eo5Cs56;r3y5;oCs16F;b1Cg3n65;e5i62B;a1BCDeB05h19A6k76r3B11;i31nEt10A;d18s287;eB3l7n146;!cB2eAi6s0t27FE;c39A8;b407g62wA7;!e0i0s0t1;b46f16n16;a3C5k5D;s1Fu5;e1iB;!e5iB;c0n0s14t3;e51D;a51o51;c3EDAs292E;c717;a10e1D;w3A4;r4Bt3;e104i21;a0eA2;e12C8iC9o6Fy0;!i13o46;!a4Be15i6n0s0;!a942i1s0v2BD8;k421B;aCb7Be23i285;e50o1E4D;!i3A5Dk53Es0;n6Cw80;h4F77l3;n2t3E2A;!a644b396d34Ae15f255i21m2En49A7o820s0;!e0n3;i6E2;!e6DEi86s0y0;aEo32;a1AE4b45DFc4449d3543e4E99f467Cg3F93hB8CiD2Fj265Bk36B9l4A1Dm42FFn2DF0o175p447Aq12AFrD7Bs4DE2t31DAu3CD0v22DFw1333y4A7Az3CCC;aCi59Do46u5y0;!aFsB8B;l2B24n59B;!s4096;!n22t3D8;w22Fz4E6;a530e20B9h4C7C;!d0i6l22n65Es141t16C;r13ED;!a4C97d0i0o29r1s0u295w7FE;rD8uC;a3338e46E3i3C82l1ED0o41A4r4B98s6A8t4Au465D;!e224i3Bl7s0w98;!m0o10t0;!e189i6l2C;e2295;e0h0iAC3o29u15C;f18DE;l3o10v3;e1i206o9;d0t46A;h3B04;a7Fe223Di3B;e1C79i3B;v4;i71l5D;p84;!e15i6l7s2941;e4BBFi6o71s0;i8Fo71;!p11F6s0;h3FB6;c3487h34C4k1s44C6t3400;!d241r1s0t78;a26D6eFB6i2B6Dv3D28;n26CEt509B;!a8i8;e1C6;d879;c2Ar9;aB8e4;h867m0t9B7;a7BAe411Dy72;!a28BCb371Di1Al3D96n12Dr1As0u6ECw1B8C;d1f4DE9l58v28A3;o9t4F;n1A3t0;d0r2Fs3Eu5;a19F4b40AAe1F07i4131l1Am1EE2n2A00o4ACAp4DB5r3433t10B3u2360y2770;!l85s0;!c219d140EeAg7iF61k136r7s0;!e2A88g0;t4DC;!a6ACe22FBuEE;r1FC5u12E;a4DCFe1oF1;a137e363Co176C;!bF8d0l22r1s0w5B7;!i272l7;a4De3FC0i21l348y0;l386r14F8xAE;!d0s0t1w80;!d38e15fC3i43Ds0;a1Dy31C;n2383;!a125c2D7e24i6;l2D2;eEo74;!e0l7s0;e1i0;aA35e8CE;aAE0o4B7C;!i3Bn22;m14E;k28t2B99;g83i49D8r3C;!a52n3Ds0;n115;c32lFF;f5B;i50E0;s16BtF8F;e1BnFs4C3t3C;mD2n2D;!e1i13r7s0;!a7AEb39DgF5Fh28s0;i111u5;c0n372;nA58;!i870r4312s0;!a105h199i56o103u34;e4i43B5y64;aE9bD06l20DoE9;!s0t14E;e19Ag0i73o29y0;i29F2u5;e4DE8i190y0;o10t1;!e24f37i43y0;a4CB7e98i3208o4u4292;!e5i43y0;h3D6Fp2F78;!e4i21l3s0uB8;!g5AiB9k1A;a30b1892c4726e67kF6m4B05n3BEDo1E25p47C3s2207t2BC1;a1446e36D2i38Fo9EuD4;a6D9i2By0;a2053c459e10F4h3CE1i4D64o205Fp29BFs46FAt3FE1u4646;k0t11;e22D1;!i31o969s0;t8F6;o225C;a3566s107;!d0eDr7s0;!e4370i6s0;i14s5;g1Ak2E90;!d2F8e1F4Fg4139l158s0;o74y230;e4956;cB1A;b5Cc5AAf1A6BlBt271F;eEi73y64;uE9;a4De42FBi6;l5Cm460En1q123r1BF9s193At4A52;!c329Fd3D03s0;!d28l3E91n47s0;e33Fo2217;!c250j9Bn3E80r40F0s0t1;!e15iADm2Es0y0;c8p8;!c9E7s0;eA3i1DA;b4ADF;!e24l7y0;e1i160;a6Fe4DBAi65;!e15i21l6E4s0;i2Bl25By0;a104Cu1C;a24AAe31EC;!b1D1d0i31r1s0t15Bw3B1x0;!e6B;!n1s440F;l0t14E;z2CA;!e23f37i6l7y0;a1eB8Ai507Fo36;e0p0;e1Bn7A1s11;!s1D1;!m411Fp5Cs0;a20i419;!e15i3D7s0y0;dBn20;o4F1A;a2662e65Ai1F41o127;!e4i317o404s0u5;l31A5n5C2p115;a2AF8e1E4Ah43A0i502Cn369o4057u434Fy1B2B;!d70g56l0n4CE1p4165r318s0vAAC;a50ACd1k1l1n2E35pA3;c0n11B;c0nB;a130Fb2CF8c32D1d2BCDe12f1k273Bl1A4Dm24F8n1917oAEEpF02r2495s255At118Bv1Aw5A;!a51iCs0;!e2C5AiBCs0y0;!e0i0s0;!e12i6l48s0;aA6;e5n3o9;a315CeF78i9C0lC24o2E1Dr2FEE;e98i228o2D03;i6E9;g53;o9u14;i3495y0;!e7s0;lE6n161p32BFsEt60u172;r191s1F;i267;eC67h11A2i66n89p5038y0;!a20e15i3ED5o417s0;l2D33r113;!a4B73e472Ai50D3k5Dl22p118Fs0u1Dy0;f453F;c13Ck1B2Cr144t47;oEp28r3s9C;!d0t0;h33Bt9C4;a10n2o10;!e117B;a22F5b17F2c4F83d19D9e472Cf49C8g1E1Cj76k2Cl2DD9m473En1233o31F5p2597r1458s50A5t2F97u12E2v295Fz2D5D;n28t47;!aCe0s0;!eDAm2Eu49;d0sA77;e7i3y0;eA76i6k0lF5o14s8;g1292;e15iADy0;!d0m2Er2Fs0t1;e208o21;l28mB5r458t47;u6C0;e35E;a3A5Ap16DC;s6A6;!e8g0s0;eA04i2By0;m1As0;b3Ce34iE37y0;!a10e798hEDi1E8s0;!a3C09e5093i23Dl2151o164Ap58;n1t7;r58E;c93l3o9;a349Ao13C0u1203;!o260p3551s62C;p40DB;!r29DAs0;l675;g223;!g223;!a4Be4i21l22s0u49y0;a8i30;e48B8i38B5;!n4EE1;!a1e153i87El28F4s0wB35y0;!a110s0;!eAi6l3982mB83p22CDr3F0B;i4n687y17B;o45rEB;rADCsBt4A;e6Eo81r8F4u4C6;e4D66i2By0;n39t39;r1D73;a1969i27EAo35;i4EA4;a3D42c2Bu14;!e8F0i6p238r35s0;d46C1g152Bs2E18t318;!a10b45E3d4281e3EE3g39E9h89i240Dk307Fl294Cn3910o3Cp28r32A9s40FEt429Dw390y64;t236;o92A;a0t7;!a252g1Ei9D9o36s0;u2F3;c3ADD;c2783g20Am63p4A86;!d0s49Ct2D;a9e761;!l11Ar7s0;!d19Af4544g3CAAn414Br6E1s0u1v35A;a1AF;e90n2t234;!cB2eDiE2Fr62s0u16A7;g682k38;d22CAg4866m113Dn66Fr41AFsDE4t28;e608;a4e3094i1B5o4305y0;e23i6o2E07;e6Ei2C58o7Fr40BD;t4050;n12Cs107;n35EDr2C;x11D;!a4De15iB92s0;a7Fe82i1E14o36u5;rE2;eAi4C09o1;a30g48u19;b1F4g4An39Ap9FAs223t1BC8v35B;a29D0eAF9i547o1043u8F;!a236Es0;a1388b3C17c1CE0d3B0Ae2F43f2102gCACh2BCEi27A2j4636k1614l341Am1622nE57o31D3p377Fq20E2r150Es35A6t4534u429Bv1536w1E61x36B2y498Ez23A8;h19A;n16r0s8w8D;!a122Fb21Ae1BA9i21m2Eo468s0w588;a647;a2D4Db2A90c2ABEd38e35Dg3485l16E3m17F4n39ABp328Es369Dt25EA;i5129o2B5D;!t1F6;a3A8e1;!a20e4i44E3s0;a1De3111;e235;!e235;a5e365Bi3BB5m6D0oDD2r46D7s0t1C52u0;!e24C4i38Fl2DA1o202As0t47uD4;!a42F7c48AFd3D5Be1EC0fC3g1F74i2CA8m338Fn1701o1916s3A23t3ABBz38;!c404Cg47A7l4941m3C85o260s49D4;a1d298Ee3048g97l2DBFo4950p1FFs4D13;l106;x4C;a563e1;!e4As0;m1oD;a4DeAg0i23D;a12e4DB0;o4AE;eAC2iA8Cr32F6y0;!d0n4854r1s0;d0n1r2Fs8;!i3FD3o5s0u5;a12iEy20;a517d811eBg4Ch1FFBiF92l32Bm2Dr1585;!l5FtB;!a32lBo43A3s0;t117A;!g4Al319s2Ct1x0;d0n16r1s8;t2D1D;a15Eh0i2By0;u24B1;!e4iDFo12s0;a14e2BD0i9C9o42F;e1iAA2;eD9l6A;!e32AAf37i21l22s157;a4Be67n2;o4r2A;a1C3DeEiACo3D89r6FB;pB84;p4F8A;c368;eAi9s71A;l0tBD;l19u36;e2FB1i6;!d0i10n13C6s0;!a2BABb406Dc409Dd4D11e104f44B7h2F52i21lE85m162oD5p39B3r1AC6s26F5v25Ew276By9A;!b39Dc50E1d17C3e1g31CFi34BCk2DAEm987n3B7Ao46r2BF4u34v1A96y2802;d5Bi73n809rE3y0;!i333lD1;e382i43lBy0;a32FeFF;d1040eAi1B74l21AEm374Bn2AF7r3A94t4185;a328i247oE7s42E1;a1e1953i6u1D;a235;!a1A12e4iB9o673s0u304;f16ADg2A6i36B4l4157m1421n2E04o361Fp1627r4969t10F1u2DCCw3C6B;u36F;h4A38;!e50BDg475k5Dl69Eo10t422Cy0;b1CgBh1tB;a1D23uA0;b7Bn5DD;!l48s0;!e2BEDl1s0;a4e19F8;a571e4378i1D95l342uB8y0;!i88o36s0;!a7Fe51Bi2A8lBo1s0y0;e292A;s3u36;a605;eCFi18Dy0;mA1r1315t1E51y38;n494;n1BA1;t35A;e23A3;p264Ft3F6;a1i73y349E;a3D;a30d48n1BF1r64Cs3E1B;e177i241E;a51r9u59;!a30e24i6C1;a1FC0e9;h39;l618;tB82;d1r1;e95o92;!e21Ci86lF4s0y0;!e4f37i86l19s0y0;l452;c8Bs117tD2;!e15h3E0i6l2Cs9AC;xC;n1C7;!d7E0r35s0;e3393;s0u14;a28eDEBi3784l7FFo75Ar2A73;h39DA;i43B;c7t35B5;!e15i48F0l62s0;eEi27y0;e24n2w238;aDAAo139;a2A5e2092;!a4Db101e15f1C5i1E1s0y0;!d0fC3l22r1s0;!a47B3e3D4i32D8l45A9s0u1B6D;d1s99;!a3D82e5i1C8Ao3EE2s0;gBnA34;p4BD9;!e4i2CDDs0;!a763e5141f37h325i3E73l2Co34E6r3CDFs0u359y41CE;d0rB12;!e15i21s1C9w130;!e1Bi3Bn22;r338s3C2D;a5AF;n52t14E;h526;i660;a328e562w3C8;a65e4EDDi54;a0i31;u377;!h135Bl7Cs0;l37A8;c0e0;!c0e0;!c1D0d0h156i6l47p109s0;b7BgA3nEtA37;!fC3iBCs0y0;a8A6u216A;hD8;!a40i4771oEDCs0u5;!d13Ee50A3h1F6Ci6k76p2B8t2DD6;!l7nD5s0;!a387Fe12EiEC8o0;a0uD;e8A8o26ByC6;a3029e4FA8i2A6Bo3922u121D;c3d0s3;!a3CF7e3075i44D6nBA0s0u22B5;e0i27y0;c36AEd75Df1EC3lA9n3DA3s243t4CA3;!d0n138s0;e1BB0i6u91F;b3D8e0;!t38u202;l4B;n3503;c1Ce12g27s0;e1Ei6;a2D42e25ADg14FAi3AD8l1o122Ct11CDu49FE;iEs1F;!b67Es0;c93s19z19;a2BC;m387;nB17s3FDt3E3D;!a7Fb1D1e4iA6Fl22p45As0y0;c2FEe7Dh4C50k1p1711s19DAtCBD;dDBg102;c345e1Bg97n2s27Et3;b4B5Ed1A0De42f3BF2g3B4Bh14E2iEADj29AEk1D09l485Am29FDn18C6p1DDEr3EEEs10A5t1715v133Dx1217;h3006;i3B8Co57;!b4C2l987;l181E;!k0p4C1q0r450s0yE1;!e12DEi66o3EAs0y0;d0f0l8r0;!e6D;!iB0As0;h27t1A;e703u4E;c2E2BeB3l2DBmBnFs1F;a10o1BCE;!e1Bl3ABs0t7;a31B2bF60d4317e2614g1246i329Bj1795k1CFDl1924m2C6Cn4ECDoA39r2F42s397Bt20BDv33DEy0;a1l148;a0e1o9u14;aFA6eECh4D8Ai21A9k4B15o4719t1F40;!c3B43iCo10s0tBDx0;h13B2;a2AC9l3F43o1AA2p48FDw445C;iABD;u371;!u1C;!bF8d207Ee23g2A1i66n9E5s0t58y0;!e24i6s0t11;t1F87;o3B3B;o10t27;!s274y1;l3o9;c2Cd377tD09;o493;e17t16;!eAi3675l44s0;aEn60p46;!d0o12Dr1s0;i133lBy0;n4598y16;aCi31o46u4E;a15Ce1h2A32i3351p41;!e1Bi3Bl7n22s2A2D;i4n2Do10u5;aCh89t41EF;a2B01e31EEi48F3oF53r5139u3D70w1EF3;a242e1i2749;x301;uB1;a328s1F;e1Bf271;a0e11AE;i28AFo29y58F;a25E3b5Ce1l76r452u1986;a30iACnEpE;a32E6b1C15e1o923;!e192l7s0;!a1DeAi2CEt16;!d0i6l22s0;!e532l7;n18Cr4768;d0iEr1;!e4f344i86o29s0;e1t44D;a30e23i6o3EC;d0e4lC;f7nFt7;!d0l7n57Fr1s3E;!a57d13Ee17i4B6o36DFs0y0;a1143h4978l1E4r48Ey844;s615;hB7A;e4i313y0;d27t38;l471;a1e2265;n19D4rB7t196u5;cEr22F1s1C1t29E;a0i12;g5Bi25;a90e11DCi225Al49B7oD17s0y296A;h17B7;o4C9F;!eAi4069s0y0;gA84;l1r195s5;e12i2By0;d0r1t1y16;e31iAE7;!i41s0y0;!a31e10s0;a7FeAi6m47EDo127s27Dt363A;eAi6E0;e4F4;d0l361Ar1s3E;!b14Fe6A9f37iC9l22o4Es0y0;!eAh1A88i6p2E1Es0;l5CE;i0s1F;l1F2B;l3At19;e400l30F2nDBo21B3;!c3De4n366;a2AEDl42EB;n155s8;!aD37e2886i1D00l2D39o3DF2r1E27t5D2u11E2y64;c3Dx1F;eAh68i6;i1111;e300g3;!e2A10i2B7Do3A14p255t2185u316B;a7u5y0;cE8Fi3DD9r95Ay0;!a24C9e3AB8g13F3i1B41u3D8D;!a3287e15i6l6Cs0u1C;!s3E;e1gAF;s217t2D;!d1l1nB;s4DCt2D;c1s3t3z3;!s217t2D;!c3130t85D;e6Eu4A00;i31o6F;a87e33i190;!a1145c1Ad31C0f7g0n1Ao50D7r3s0t1D35w0;!a3FFe489Di15A8l4047s0w1BCy0;l16m16s35t16;aAFe12;!a37C8b1F27cF52f2FA7i2C46l4A23m23CFn3A78o134DpB55r5015s0t432Fu706y0z46C0;!a3C3AbCEAe2D83h14Ai21l210m4B68nEA7p30FFr2FB0s44Dy0;o42u5;!a1D05;c2177d2A3Fl2FF2m27E5n310p5E4r3Cs3E60t9Bz38;e3CDDg225hAE;aCu4E;a3A6Cb39Dc31C9d44FEe4A56f1CB1g4DD6i20F9k29l2920n7Ar49E1s32DDt4A64u4Ew40B6y3807;r2C9u6E;!t789;!i4A3oCs0;i35u49;c132Bd3e13Fg1i6kBl4393m4422n471Cp2509r4343t20A0;e3B3;i43D0;e3AiAC;sCE;!d0n26D2s0;nE1E;a513Ee140h325o8A5u139;a9d0;!a2FC6b27FCd96CeEBEf28h77i1DEClDBm3220o1417p4BBCs3574u4E;l39n39;m213s1F;o23FE;z203;c0sFEt7z3;e12f41C9;o2340;e2A4;e0i160;i1Cy1C;!g34Fz1D67;g44iDs1Ft45EAuB;o449uE;p4984;o57u34;!b7Be10Dn2s0;!d2Bn1s0;a16Di0u5;n20Br127B;!e4i8Es0y0;!a358c0n3s0;!a1i30B4s0;i18o29;i2146;!a3E88c1177d4F89e1BDEf81Ag32ABi202Dk384n23FBo1FEDs1848t2DF1u23DAv151Dy326z27E8;l4DF1nFt28C6;c0o9t3;!c1AB;!hEDi5C3l512E;!d0s0y16;e0k5At34A0;a0e5i13o26B;a4488e38E8o94;e6Eo10;d215;a15F1e2B9Di3292o35E8u4F2CwAF4y2D77;!p1E;n1o9;aCc0u295;i23EE;c42E0x1F;!a5De1Bh83l7n22s0u1F49;!d0l3E07r1s0y0;a32FeC7oBAyC;t62;o442A;a50E5e3785lA7o3780r3125uE;!d0fC3s0;aCi4oDu4E;a1A8C;!nA91r4E2Ct88D;t98E;!a0c10CBd0i6l22r27Bs0t4B8y0;l0r78s3t3;!l0r7s0t3;e12r205;a43EeE;a1A93e391Eh3Ci3E82l2196o1961u24BCy27C0;!s0w15D9;!s0v222;cB2i1ED5;!b2D79e209l4E46r2CA1s0w169;a79Ae6Er3CD6;e402i5C6y0;e1A9E;!e482s0;!a244e4B52g4D8Bh9ADi363Bk5DlBr269s0y4ACC;l1t102;i1067;e1Bf7l7n2t719;b1c64A;iD4;!a2664e1180i1A14s0u4C55;e40E;d3C8;!n3o29;c14B7;c4CA7iE;e59n4B;c1942n2;a6En394Ft1;g97r19s8t505;!l22n8AFs0;aCi110;b6C;a0o2A08u3B3;c3F3i1;a10EBe40i2D72;!e15DiBCs0w393y0;a3E0A;a36oDC;e23i86y0;!d0f37n8r83s157;w1A;!a670e23h17EBiCFFl6B5p4C6Es0tC7D;!aD5i610s0;c246k18l1A22;!b49D2c1F36d3B8eCC6g3A35l1AAEn2245p5086r13CDs3091t1072x11D;tC7x8;a1De400g2CiBl44o56;!a52b21Ai52Dn22o851s0t2A76u33A7w3A3;d2AD7l4115rA82v2E49;a3B91c3230e1g2A6k30BDnFo137Bp1A3Ar1CE1s4A89t2018u212Aw4830;bDDgA3l42CBm2A2Cn5004s23CDtFB3;!e4i6r41s0;a2EAe1t1;!a498Fc2724h468ClA73m400Dr47A3s78At175BwED;e23i21m63;e4C5Ei6;l1Ay0;!e5kB;eCg3;o2B58;a48D8b3827c2E52d3B98e4E4Df3D26g29A0h13F4i4BD5j2E64k3D24l2950m34DCn4E1Co2D11p11B0q1069r3A0Cs2218t501Bu178Dv17A5w3191y26F2z50E4;!a2B4Ce26r7s0;d0r394;b368Fc3B52d1A9f884g394AiFkBm1A42n284Ep11F4rBs4540t4913u275v23F1w39A3y2B5Bz24A1;i280Cy0;e4i6l44;!i143Fs0;!e1DzAE;a6EDhACC;e5057;!e49F3i10;!r1s0t1;!a4Be4i91l6Cs0y0;z423B;!g9Bm1EEn3Co1385rB11s0u632;h359E;r33B0t87;!e5i18;b1r4E00s775;a3270g3;!n271s2773;!cB0d4EF4n2o10p126tC95;!hE3i69m2Et27;n9A5;!iBoA6s0;e24n2s35;!e12l11Ar7s0;!a39Ae17FAi63Am2Es0y0;n2Do10;k47l1;i16y1BA8;!e15f37i21s0;!d0i6r2C2s2E15z1BF;g11m3DFn13A;d8D;a29DBiA23l2C0o3759rAF3u128B;!e1i10o10s0;a3AF5eAi1FAo29;c9Cp2336s2E8t1;b6BEe3254;e1F1Ao3F9D;l1n2;k2119l47n9F0p12Bt290D;l4B7;n53Ep976r1987t19FE;i3671;g97s1E;!d0o4EEr28s0w112y9A;s3EE7t40;a28CAb39E2e3143i3F41n26BC;a28E6b5Ac484d29FBe1AB5fBFg4918k3mCF7n2Cp126q1384s175t0u4C30v3y5F6z481B;iACo40;n45B;!c219dB33e4i38Fl15E4n39D8p28r265Cs52t45F4;!e984f37i6m2E;!e3Dl6Cs0;!c22Dr222s0;o11Fr1A2u14;p196;nB5;!a452Db164De321Ei25D1l3D69o2734r76s0u46B9;lA8n383C;a27FFe2BF2o3EB8u1;a655;e12h10C;s425w0;!e3E46fC3i9D2s0y0;i1A06l23E;!a4Be15i6m2Es0w80;l49D;!e24l22s0y0;iADB;m57t1;b61FmA5;r31DC;w4C9D;p3Cs4C3;k0n0;e10n4FExE;aC80b468Ac5D0d3164e11A9f1871i37C3k369Fl1C56m48A2o27F2p14As18D0t1u3198v2EFBy261E;c215p2D78rDF9;!a1BD5c14DBd24A9e22F7fAEAg4DA6i10k289Fl22o640s5111;c3968dE9Ef2C0k874l2003s219t4448;r2BD;!aA93e9i43A5o4D91;!a147c13Bi386Cl8m3389o2F48p2CrB74s4C41u4405v38wE6;lE1B;!e0s0t10A;a2E71b3BAc3CAe3AA5i3121oA6s4333t1E30u48F;!e4i624s0;l3EA1;!e14Di43l7m2Es0w342y0;g40EE;!r1s0y0;iCC8;n1sE;!aCiC8o29y6D;r5FA;!a411e3C56i295Dl7o1s0;!e4h131i91s0y0;g137;eB3E;c14Bf7n2;!d0i6l1m7EEn3C88p14Ar28s0t3ECC;a1B5De3B39i4358o1F43t333Cy427;iA5u50;o1u6A5;e1i13o11F;c3BA;b1Ac43B0g4757l3CF3n28BEr3581s544t3E2B;m5A3s5E;a435Ce3BD6i1390l28ADo1B9Cr1508u2B84y145F;!b2449cD3g349h1n238EpB81s0t1A6x58;a12iEu54y20;d0r1s8t0;d0r0s8t1;s56;e1F04i132o31DE;c9Ct47;!e5i73y0;a8t1y1;a3EB5cBu14;!e15i6oD5s0y0;m8EAr106t162C;!aCk11Ar7s0;e4i6lF4;i164F;e4E9r399s84t43E6;a2100;c2Cf24An2o1F9t120;h3781t23AA;i1FCB;!e1Bi50l3ABt7;e3D2Ai6;e32B7i6;b4460;aD8Fu5;!e10Er3A2s0;u1C78;!a1d36DBe1681fB5g38i2BE2lAB4o253Ds0;aB03g4311j4FC5l1D4r1214s3Ft356F;!d0l76m2Er1s0;e5i4o46;mA3A;l3F61o74y10F;d19s1A6F;aCn490F;c32d0r16;!a51e67i6o19D;l1C7sC1C;!a250s767;e42i11C;aEp19;a10h61;c1A6;a3E66b3Cc4832d1C66e1ADEi2577m2F2Bn1998o4CB5p10CAr163Ds1A0u47D0w131;a180o9u14;!e4f19s0tB72;s391t49;i6t16;t199;e256;!e256;n1C1t7E;a48B9b210Dc323Ed2A29eF65f1B1Bg2521i319EkA26l4356m35EFnEF6o4DF2p491Ar11FEs335Ft409Au3C0Ev11E9w2B7Ax34CC;n1r28B1;s4A62t3F50;a59o49;c3097e29FFg246Ak23E0n120;aDm4D;d158Bh1iF15n44B2r35B6s30FD;a8m164x0;!e10Bi6l7n22s0;a40i31F8;!aA4;a34D5;n4r7;e0i133y0;!e7i8Ey0;e7i8Ey0;oC6y7B1;r16C;i60;h1DBz256E;c45C1dC5Ff21D7gC57i22DCk1l5071n37E3q30Dr2B79s170t116BzD16;i774l1A;!e1w130;c1Ar1;d0s65;a593i3ADo12D;x2BD;!m2Ew7C;n19Bt14B;!e4t0;bCB;!e1Bi290l7;c9Cd74Dn58t0;c46k2B6o10;a3Be166i3EF3;a399De10E5l1301o92uA3D;aA29;p2C;!e15i2E0Fs0y0;f55A;l1Dm22A5s448E;a267;!a1DeCDi10F2u5;a1E2Fe1955i4926;e18i2060;!a508eAi66y0;a1CE6d18e514i21k28o46u452C;!e510m2E;!e15f37i6s0t160D;d91Ct220F;a1Di1;a0e1o2EDu34;!e5i6n3o12;a1Dh49A3;!e43E1i27s0y0;!a92b1F3c9Ae3294i6C6l22m213;r113;b3C6d4B60f1CEg3A37m1En338p3E6Bs5Bv2169;t1197;e1i35o40;!e1o1;n2s5B;!a47De4i4005o3ECr29A5s0u4E76;n7CDo29;g1i319Fo46y0;l236;!a0e1i11C;u140;!a211b67Ec9Bd0l3B58m2Er3DCAsF0w34C5;!d0r58s0y0;l0n4213r25s19;!e1238i21s0;b1Ag145w2Fy3C;!a4597e1o1C;c22De5n510Aw396E;a402Ee12;a1684t88;d1B0gE4;l4763o3A7Fv2CwE6;i661;b1Ai4BF0lEEm4501s3u4588w0yAC6;o4F8Cr39Fu29AB;!l0x0;l50EFs0;!e34Bi6s0w6C4;a3E1D;a1iC8;n39E3s2At28A;!e24i6zAE;a7Ei3F;a861e3D;!a374d3978n3s11B;b231Ce4542i6o3808;iBA1o12;!c560h1A55l4D89n3E15o3577p659s4977t29A6;c4037g3B0l420Co3723p4CF9t4F07u1B9E;e3F53o202F;a84Fe9;!e15i6o1AAs0y0;e26i5CBy0;e9AA;e16B0y0;!s0w0;lF46n18r76s1F;a1B30e3DCEi4671o1AB8u1389;!e153i6s931;!e27;!e8Ci21s0w1BC;e245En2;!a128Fe10BiCCn22o1452s0y0;a4Bd1Ae1AAr3C38;a281Ee90u19DD;!e5D4i6;n3DEDr1;c0sE;a9u34;a42i36;i159;eB66;r45C8;!s1t16;u589;e31i14D;e1i5FAm214DnEp55z4AA;h4592;k14A1;m43F7s4BD4t1503;a1E53r18u34;b44EEc1CD4d22D6e18FEf683g2109h1387i4A45j4521k3570lCF4m27AAn272Aq3810r4586s1C4Ft4E98u1E54v2DA5w3B87xAEy45F9z387B;a1Do29;a328e1i4AF2;d0eAr9t0uEw9;!a30h1;!a1D9Ae2F08i313Bo46s0uB8;t7Eu85;n2s3;e0i11Cu15C;a252e4;b173d3C19h1i9l4DDEn1DEFr223Cs304FtF26z483A;a4949e18D9i34B9o476Au2B2E;!c32d0m62p135r28s0;k1Al48F5;p809;!b11B3c560r1A;!d8Ag14Bi239n1r0s0t2D;e37Ai21;!n52o9;n3o9;!e224i23Cl7p1A6s0y0;!e457r109s0;!e67gD5i6;!e15i21r22s0;a1157e19EBi3C7AoB36;lBo4;!e6Ei2Bs1Fy0;!b3547fB5m397s0;g97rB;s4D8D;!n6Cs0;!e26i9oDs0;n7y1;!a441Fe187i6o10s0;h1F98;a4B50d3D08o4D12s0;!i10Fl7;d523;c0d0g5Bl1D3n1;j0;!e0r3ED4;e4876;c19Fn4403t14E;a341Ce3EABi18Co92u693;!aCe4F4i28Es0;!n0s466t1;dAAk28;c30A2e11D9;!e4i6l7Cs0;f7n2s11;!h1282s4E6t3239;!m55n483s29;!e1p2090y0;d0n5AAs0;a34e4i1735o591y64;g175x498;!e187i1FAl66Ds0;!a8EBeA79i6l51Ao4BC4s0wA7;s4E38;!b29g30E1r1s0;!fF5n2;c32o34;!e15i6l11As0;e1h2D0;lB4r26Bt1;!e2FD2i6o159s0;d3284g26AAk56l4r3B0s1530t200;!e20Fi6n0s0;a407Ce1E29i228Fo3DDAu5C3;t145;!e15i1A5Ds0;!e4iF9o12r4B17s0;d1nAF1s1F;i10n1FCr306As20;c0d1e5s3z3;r2DCBs1977t401A;a30A7e317Fi1D7Do4834u3624y11B;!g342DlA8r118s0;!e15f37i4BB4l7s1Fy0;!dE3i1E8;!p138Ds0;p1s5;i0u4E;e0i65;d0e1r1t16Fu36;rE0E;n2o9u14;!a1DCl490Er489Au1296;!b3FDmABo759p2F28s0;h19D;r17FB;a2658e41C4i4365;aCn2s1DEz3;a59e17i6y0;u335;n41D5tB;l3F16s0;a4De3F1i190y0;h2C3E;e1EC5i34l2DDFn28o488Ep1t2780;a4083b31BDc2FF8d440De3BA5gF82i137En136o1A95p250r133Et1700u5;!c44EBd39FEg4FF9i2B2lF05m26AFp360Er17BBs0t1905;iACo12;e1l1BD8n269;a9n78s1F;!e5029g7Ah3732l56o10r1135s0;a24Ee640l4E2F;e973;a130e17i60Ao43C5;l1FBo12A;i74E;e1iB9;!t62u15Ey47;a2BE5b4625c3FFBd403Ce9E6g44C1lCF2m4D60n2016o10p434Br4F15s4154tF87v47EC;!eFEBi6s0;c0n2CAB;o10u2C8;b1Cl85n4200r1443s215;i1A4o1u5;n13CFp1r2Fs9Ct4755;c4621;d0r1s5Ew0;e5nB;!a12e104Fi6n4A65s0;!i1t1;a0i20o46;c2AnB;a111Ae17;e305Ar32B3;i2EEDy64;sF6;a0d3E96o9;!aCoD;aCoD;a1ED;e67lE1nFo29t1A;e0l0t3;a4849;!e4lDAFs0t4B2;e48A3o57;!e12Eo239s0;h1AFD;e1i31;!e5i31;m1B4r22C2;!a1i0s0u5;!h9DlEB;h14;a8o2Ax0;e185;a338E;!d357s0;n2s3t7z3;!r11DDs0u12;c31B6n293B;!e4s0tB6;h2B8D;eAi8A3y0;o384C;eAi6kBA6t28;aE83;!d1CiA5s0;iCn155;eAi66y0;m0t2F;a2E11e12EiCDo2BAr4CF3;!s1uD;eEo92;l1t1E17;b4B5Cd2720f223Ag2A6i49k3D61m49E2n397Fp38EFr448Cs1C32t5Ax1F;k17Cn2742o8t430u172;b8BcEFr36B8sC1;a452E;d0l1r2Fs0t2F;a20b2EC4oE7s0v62;aCc0e5s155z3;!e1C3y0;!r1Es0;eAi86y0;d0pEr9F6;n0r3;n3r0;bA1i4y1;e493g97r8FF;o165E;!e4i86s0;!l7n22s0;a46Ei3CDEm22C;c7l1r7t6F2;u4F70;e12i43y0;!d0r99Ds0t88v38;g3C9E;eDn2t0;rEs1EA;g28k28;!c4CFFe1B83l7o2417y1DC4;!h4DA3p1404s380F;aCe0i0t39;aCt0;c2Ag0k3lC;a1497e1D6E;!i4FD7s0;n3852;e696i6;a20D5e14Ci1F37l43ABy0;a259b42B7c4FAAk1617n3969o4438rBs1EEDt3B07u78Fw371E;!e23i6o6Eu149C;r2Fs8;!m0t3D4F;e3AA9i172;o2A60;b304Ag167r3788;d320l28n4427s2CzB;!aCd4390e41Ah2DC2i1D89oD5s0w3CAy0;!c12Dl5BFs0;n2r353;c2Aw1E;!g649w40A;m3E5D;e50o8A;!l45n46EAs0;a4D4Cb1C3Ac616d43CEe4561f3FCCg2996i1843l122Dm2926n3BC9pF14r379Es33A8t3C49v0y11EEz9D8;d1s11;a1774b46Ec28A9e208Di258Ak2B95l35EEm68Cn2C4Do3346p1E68r144Es1F8t48C2u172Bw1D80;oE2;!e33s0y0;a78EeAi6o69u6F;m25D3n404D;a2A48o1590;a19C1e285Di1E1Bo4D22u16FE;!a8D8s0;e3CD1i3Fo29;l5D3m0r4498;!b396e40i8El112s949y0;e0t7;a32AiC7lF58s0u1FA1;!e10i2429p5A5s0;e5i2C0B;t975;t5CE;s3DEt7;l14Bo32u36;d1t4B7;a214fBFt1342;a4CCBe1i0o1;u2A41;!a4Be15i6s0t8D;!e402i6s0;i3C9o16;f1r1;i29A;e4B0E;!a1Db2DF4d0m411Eo29s747;!eDl7n1s0;!a10e1s0u49;l438;e114u49;a276Fe4877i1FD6r72F;nC8s11u14;!c3887n3448;a0x0;!b4345e2F2i23Cl220s0w1BC;a264b4CC9d40D2k44l373mF01n4350o1002pE43u2936v3w99By0;a20o46;i36o54;a188b18EDd7Fe37EFf1E3g48B0k1EA1l161Em2823n4572o422Ap3DFCr3A0Fs46C4t2AC1u319Cv17Cw1DFE;c2Bl1Cn2x0;!a26ADc3C61e4CECh3509i4C27n1212o3B26p2209t2C09uEB3w503F;o155;h35E;a1514i172m1;!a30e0h38s0tAB;!e17i17B5r58s141;m1679n33FFo1AA;!s0t78;s0t78;l53r3;h2A24o1;rA3;i3786y0;i3u4CEEy0;f1CC7n161s1BD4v5D;d41t18;a31Ao9;cEFh440Bk4667s4252;!e4i3s0y0;pE0;cEe1;eEoE;t5C2;e1EDEi6o396D;i34r48s37C;a10o29;eCi17DCo12u49;!o45E;i25o29;d0l3Cn26F;a1Di38Do10;eAg1E2i86y0;e1h9D1;h35o3C08;!a1De36D3i329Cs0y0;!s0w55E;o36s3u5;!a50s0;aCe281oD;a56Eb43F8c3082d2E4Ef1E37g2138i4B2Ak2Cl20DEm1C17n1EEBp473Cr40F6t18BFz47D9;a2C93e1BC3i66u5Cy0;a4424hC0C;n82Cu47C;g543n106;!e21Ci1AABl7s0y0;n278;!a4BB1e2CE3h89Ci3E16n22o23C3s128Cu32A1y1F70;e98o134;!aE13e15i6s0;i233l3u29FE;a68A;!a4Be20Fi21s0;g23ADt1;m183n177;!e1Bl7s0y0;e262i21;a0o14D;e14Ci4041l170y0;bB4Bc20DFd468Be1g3A9Ch0i3A4Fm48C4n36B5r1F7Bs4126t1AFAu907w3D6y1z16FA;a2C17d2E4De1B4Bg466Bh0i166Cu4BE6;n1F6;eBEi344;r2579;d3E3CeAg1CFi435jCDk1y0;dE2;!e256y0;!a1E9Ae845i21o117y3540;a6FA;b4EACn8D7;!a2EE0e23i3E22o1s0;!i13o33Es0;dBe403t1;l1r55F;!a3707b2BB6c3263d492Ee396Af30A0g4D0Bh3493j1524k4320l34E3m2EECn311Ao1A37p31FCq504Ar32B2s3DC8t1789u3300w4260y848;a4C4e1o36;l1FA7m63tBD;!a3A6eDC9i21r1272;o214F;y3368;!a3FD0e5;a1BC6d0m4043r50CCw0;i3Bl7;cDFDi1CEk5Bm2Cn2346p347r527s147u172xAE;!l455Bn0r28;!g7Bs0;m1An4CE2;t4ED0;!e10Bi6l7m2Es0;a2682e5hBDo4C93uEE;o67B;l3B8;a0c15Fs2BF;eAi18;!d0l7r1s3Et16;e3870;!b101e4i6l22s0;!m2837u264y0;a1e1k3AC8l46F5;c1i5Cp2CB3v38;!e41AhAEi6k4718l76s3A3AtE77;i1DzD6;d8E2n62;y35D;g55n83s25F6;!f37l256Bn3BC5s0t4208;d945g3E38rDB9t2E8B;!g7Ai1Cm63o12r106s0;eD0l1;!iB9n46EFs0;f28BDt1;r46A0;r412C;!iB21m1As2FE9t2Du5;!a14E0e561i1C2Eo18As0y2026;e79l52n2;m754;a12C9u0;tDB4;n572;m0o12p1C;a48B1eE2Ei1F4Co1A94u6y2FB5;!l9A0;a10oB9;n124;eAiF9o40r35;a634s0;l3D55n2;a42F9;r47CD;a208FbBc3F94e113Ff1519g4E12i3F69m36F3nAF7s112FvBw0y4C85;r59C;r8Ds3u1C3;eAi23Do3234r550;d19e108s0;r514A;!e71Di2D20r6D6;f4F85g336l23FCm2DE7n340Fs3464t38v44;i1DBC;a10AC;!e235i86l7n22s2F4;a52Bg0i3F;c45D8mFC;f31Bn2;!e456h19A0i6s46B1;n38r25D4;!i28Es0;!e1191o45Es0uB7;a1e0nF;uDE;a2681;e1B8F;c0n2s14t3;eEh16;b372A;e2CFC;g5Bi4nBrCA;!m3516;g1Ek1El1CEn147r3765s2C91tFBy1E;o1AA;!e4i3DCl7n22s0y0;m0r1A;r1E26;!bBDAc3C29l3C31n4D95oD3p126s1FtF8;l1n4B2Ds58t1;b11Dn118;!a4F3l44DCm63Cz2427;a12c3348d1B9e1g366Di2F5Bl3E31m40A8o4A82rCE1t2EB6u4C29w1665x0y1160;e4i73Dl3A0;r301;c1CAdBt2E8;d102Cs234;!aCi13;!eCFiBCl22s0y0;r1DD8;n88E;h7C;!d0r4B5Ds0;e15i43o54y0;e82i6;r28t88;r2043s0;!c318Ad3E2FgBACi3Ck178Cs4FCE;l3Cm28D9o1B9;g61k4C;i9o67B;a12i94u5;!d0n8r0s0;a4E9C;!e5h112Bs367A;i4E57y0;d0lB4;!e0k1s0;e239n1471;d0e21E8l1n32Ds0t1;!b3E44l7Cs0;tA9E;!e24i66w1BCy0;t2D1;!d2157i6jA7k0m4731p343Dr39E4s0;!k7As0y4E78;h4AC;e5Bi76o125;e92r2F8B;l1D0D;d1eE;d0o29r7;d293n2;pFD;r16vB4;l8A;!e12f37i43l6Cs0y0;d0nEt1;c3e79n7Es11;a2507eC6o4695;a78Ee98;rDD;n4t1;i12w32;!a4AC9eAF5i1F7Fs0y64;e0g1Al58;e2DAC;j1Am4BE;s2B;!s11B;!s2B;s11B;a8D8;!a2349e1BDCi43Dl7m26B0n22o1p28r3CFEs952u3FE6y0;y76;i42C5;!d0l7r409s0v3D;!e667i3Bs0;!d0lA0p6A1s0;e1Bn25F5;e1Eo81;e2DC6;n62t4D63;a20t13D;!e455i8Em363pB0s0y0;a187D;n0t11;i273o897;e23i6s0;!e23i6s0;!e64Ei6s0;!c0e24;f499t2F;s19tEF;f144F;b524;u6AA;c3eAg0;i72o4BC7;a0e0n7;!e15Di6l6B4s0;m7n8;n2o9vB;g62s2E7t145;n55rB;d1n16;a4De24f37;a2B65;l3093r4D3;h461D;l2Cu489;eAi6t39;!c87Dd70g35p5051r60s0x35;!d0t2F;!dFDg1C58s0;n2906s112C;g71C;m4CDs84;e126h87;a1C21e2281i4C94l4B4Dm1100nFEAo2979t4AFAu34F5w1A;!aBEs0;b3BA3d1f1603g2E70i307l1FA6m4E09n4894p2160r3011t2591u3A63v114Aw4DBCz56;h3k28;i440u14;oE1;o80F;e31B4iAD;u18C;n7A1;l3D23r723;eAoF7;a30D2b49e3CD3i287Dm7ABo2A9Du706y0;!e10EiBl496n8CDs0t4Ay0;a356EiAF2;!e15f37i6l7s0;b1FB8dFDe47C8i4C39m3465nFDs103D;!fC3l1Es0;uFF;s2051;!aB9Ee8F5u34;c4Ag4Al28n651r1;y69;!i1ADBm3626s0t3136;!e1g39Es0tA57;l1754;n2D16p228D;i736;h472B;g46;a17e39B;e209r8E8;e5g422Bl405An2;iB65y0;i109Cp209Ex4A6;a2366e15B1h162Ai1013o24CBs1BE7u489Ey348A;a3FF1e32D6u10A6y3A18;i3F5F;i4C0;a4Be67o3595t60;c223d2BAAt0;aD7o29A3;h1Fs7D5;tB71;!a49A2d2746e1621iF35l363Dm158n22o10w19DE;u2A2;!e153f37i6s0;cEx68;e23i6lB;kA3;r0tAE5;b49B;l4F36m0;lFF9;lCn2;t407A;r2D3;!c31C6kAA3;cB8Fx0;i7Do4CE9u34;c9ABd120B;e1u1;e1Bn22;e3293;e153iCC;n3ADF;!a299s0;!e4322h952i43Do29s0;e4i486lF4oC5s0y0;k385B;e1E5i6;a1021e5EAlA5o239yC6;!c2306h1E5At277D;e766o12;d19F;e4D5F;!b396e2849i21l18B0s0y0;i77Bo12B;h587;!a715i2296o3D3s0w2C5;s1C8;e30D3i6;s27;!aCd0r58s0tC8y0;d3Ar1s0t380;b61F;o10s0;a9eC;aEn25;l1p707;n3o8t1;!c511n1s0;cEB;!b2E5Dm63n9A5s4A66t1;!c9CoE49r25Fs0;iEC4;a174Fe1518i4D1E;!m1139s0;a7F1h0;n2t29;!e15i21l22s0;d44n2D8Fp26Es22E;r131y4F76;!e4h16i6s0;g298t2F;a1B9Ab2D65e1g1A8Di2DD0k47l371Co194Dt41C;!a472b88As0u944;!d0f1E3l22r1s0;b407;e3E10oFCy20;iC1Eo46pB7u5;i83Ey0;!e4i21k5Dl37F9o2C3s141y0;i2D0E;!cB86kDBlA73r28s0t1E7;!g1En1Es0;e82i35;o32u54;s1B10;!a23BCd286Fe3235i16EEl87Co1E9r4B22s0u706;!a165c243e4iEF2l2E0oDt4077u4Ew1A;s3w1;i2C65s89z89;f4EABv2B;!e14Ci23Cs0y0;!a36BFc409d3070e1E5g1FF6i2FD5j2C8Ck4580l2D56n160Eq30Ds1ED8t1D69x6D3y8Bz33B;n1r60t60;l850s0;l4D5m0s0;s19t7z19;!b4B7Bl7n22;c0f4E51l7E;l16t0;c0dD2n3s14;a75l1u14;e8Ci35Ay0;iFC;m198s19;d0r1t16Fy0;a873i2118;!e38Di16Ds0;e7B2i73o1y64;d194n1r16t1;!a4AB3e12BFi333o944s0uB8y1A7;!e15iA6Fl365s0y0;rB1;e351o1;l95;a37E9l19o667uE2;e3D2i2F60;r3985t1;!eECs0;l35B;l3A9r966;t7C9;!b1EEAe4h314i6l22BDn49F8p479As53FwAC5;!e6A;e84i2By0;!a11e5;c168Ce950h12C4i6k1BDDt18FD;a28De9Bh1E81i3DFBo3AC9r1577u27DEy7C;a4F6Dc11d3e259g3B47l3A3Fn1D29o1AC5p1r3FC1s34F7t1A66u1D5v5Bw1xAE;eE7E;a1e0i1E16k28;o14A9;e2F2i486y0;e1EoD7;e4ABFi158D;e9i31;n4B8;a140lE3;d4EDCf220Ak252Cl46ECm1310n215Fr47A1t475DzF3;d0n142Br1s8;d3i14Dn4p1r4y1;a1552;a60E;d119;!a3147b4EE5d4ECBeAg510Bi1B84l31C3m376n27A8o465Ep220Br511Cs1994t1F9Bw1C06;r44CF;g997;gDC;!n8r0s0t3;!b2B68l76s0;d56e483i209n2AFD;eDf7n2t3;!a3DCDb3C5Dc1F94d2D82e25A2fB5i4287l4617n981o2CB4p2308r2ABBs4362tEBu1245w3AC4;t4E2E;p39;a343C;e12u32;!a20i3Ds0;l16A;e12f27;i77y0;r1y1;a3F0Ab1ACc4B58d5039e46A2g3A17i4EA2l1F93m19C6n32A5o628p4BD6r4B32s2C49t4421u3052v3w294Bz13BB;!e2E34i2A8y0;!s0t1D3;a137oAF;e4CF7;d3CD8g3Cn76t11EC;!aAF0i12o1EDFu12;!a143e4i3739m63r38D6s0u6EE;a445;!l0r0s0t3;aF1e33F9i2BD5t3B41u4953;i3BoA6;e1m7EAo4Ey936;a201A;e106Bi190y0;!a4Db62f17Al22r1s0;r2A4C;c462g1A;!c41B1d115DgD6k1lBn176s5E9t481;o8u8y0;i4m3r4;!g297p6A1;a344Ac264Ee398Ch2D68iE19k3271l1206m3401n3o2CF4q469Fr3B2Et19A8u3816y252B;!a107Fe502Fi3C41uB0y0;e0h0m0;!a265Ad1631e2637g4C5Fi26E3n2F8q4377s0t4B72w9A;gA5;g167m2D2Dn31F2q123s42Eu2CB;!e0l0r7t1C7B;!eB8Ai6rC8s0;!l0n0s0;!g19r0t19;e0o3B54;!s0v27;e0o9;e1476;rA1t56A;a212Cd421e1h16C5k42D6t369B;a2C7Ee413Fi2F65o2C32y140;d0r39s8;p34FB;r1FFs1A;a1i350Cy361;a985i2Bo388y0;!i39C8s0;a4De23i1B3;e1Bn2p1EsEt2BD;n4149;!eF7l7t7;d28k28;m1F1p19F;r6B4;!e15g11i21n0s0;p9F0s9C;a703cB0e67l35FBn885;lA8s1F;e0i60A;n1DC;!s0w28;t19B;d16eAi6;r25vBy1;d1C6t0;a117e1498u4FD9;!a31A0e431Cg8C1h221i36D4l3DAAn2C51o3BCr3086s0y3FC9;i1B1;a16B;!i13l2Ds0;!k16r1Es0;d50A;!e1Do29s0u4E;r2AC;cEp1;d38g44k47;m3n70;i4688;l1t1;a3F3Be1F52i1FBCo1AF1u21E2;cD1g3FDn8;rBEC;a4Bl3;!a4BF8e19FFi41AAm89p7BDsABA;aCd2825;o10s16CtA12;fEn14B;o3Bu3By1;d2BA0e0t8D0;d1p540;l1AD1;!l1n5B8t3;l1rF;a54e72i51;a80Ce27Ci6;a17E4e1872iCCo31FFy0;!aCbB0d29A9e3E3BiA0Fs0y64;!n7As0t1A;e9i13;m331s0;r276;i38Cm1Ao29y0;oE4Ar46C3u3402;c3d28Ff18Al59Am3DFp4Ev75F;!e4i4CEnD75s0;h2318;!a4F7Ad2B8BeED1i21l18Er857;!a4693b2C5c4700e187fC3g3902h314i1C27l2C26o4904pB0r657s0uB8y0;h35F5;!e1s0t28;o1156;aCd3e1s0;n2E1Bt1;n259C;!i10;!c302e1s0t4F3C;aCn3u14;a20y1C;!l176n22r1s1AE;g0i20;a1173o46;!o41Bs0;g19s19;!a4Be15f37i6s0t0;eE9D;a266Bb11B2c3FD8d1B31e3EBDfE7Bg118Dh5i1A2Cj1758k28E9l1915m30AAn2BB8o3F8Ap1C2Aq4055r3290s26EFt410Eu10D0v46B0w4127x45A2y206C;!e880i6p4C;a0g10s773t7z48;i127;a25oDA;l1r16;!a3F13b34DAe37Ai19A7m45EEo2A4p2ABr158s0u4E;n9C1;i4s55;i882o40;!a250bABc2E0eA36i20l3277s0uA86;i4o20D2r777uBDFy19;!i2EB;!l442Cn22s0;i77u5;aFo8A;n76u1;!a25C3e432Ci6o92s0;e1u55;k16l0t1;!d0e673l2FBm2Es0;!b26DDs0;!i63Ds0y0;d0l0tB6;a1i18y0;t1C4;!e23hE1i6p745;!c2Cd87eC0i17Fl7n22o71p1F76s0;g55x0;b1712cD3g705l9FBm8Bp1r3057v171x301;!i94Ay0;!a4CF8eE73s0tF3C;c21B;a198Fe89i1C;!e67iBCl2Cy0;i94D;!a34e111Ci21l7Cs0;a12E7c518e30i4480k4119o4470q3095u71F;d1Al1At4E30;n16r16;!e1C3i6n3u24B3;d4Bs0;l35FE;b1Ad1E05f25D0g2A6l3EE6m1A05n3B33p12C3r229Bs2Ct2992zF10;aD5Ae4;g1i1C7;n321;a20iD0u6D;o21AD;c3d3;a0g0;!n2D34r1B0s0tBCB;a236i18;eEAn11Et3;!a0o10s0u34;!g25B;b3F2cEA5dB73f4DE6g4EECp2A5Dr2AEAt2056v11AD;!i4AD6s0;i5t3D;!d38r58s0;oEy2900;t5F6;!c3Cs14EF;a343Fc24Fd492i3F81l450Es1BBy47;rA;m44;h93;!e1Bn2;eB3n20B;!e0l0r2F31s0t847;n3D0;e104i6D7y0;s17DA;c524i25;!a1C1b7fB4i9oB22s2E1t41v27;e1t3B51;!b7Ae1BAAi4F0l3EF8s0;a20eAi465o36;c18n0s19z73;a21EFe4071o3015u693;d0e5nFt3378;a1BE;a913;!a290Ae5h2F7o2C81;!s83C;l450r245tB6;aEw25D;s83C;nBu5;eBA3;!e18A7o4A9Cs0t47u485z329;tC2;aCo0;e5BEo264;n8t6F2;t50Au15E;a4782iE61o56y148E;m4DDn2Dr16A4t677;!i94As0tB5y0;e12l2C;!o35s0;p1t1;n17DDp28;sA20;e8D2;!e81Dn2700o29s938;eAFC;!r28s0;!c1d0r1s0;!e36i2269l7s0;d2A80l84n2812o3C2Fr132s13Eu93Ew1ExAE;!e67i48E0pE1y0;!a4Be4iDFm2Es0;c11r16;a1A1Db56cBd40A3e49C6f74Fg13E0h3180i326Dj8E2kE87n20B7s2830t45B7u4ExDBy0z15E0;o167;e24i6;rBs1F;a4E8Ce39CDi4F7Fo29u5Cy552;c4696;r83sB;i25B6;e2FF0u190E;c954t16F;a31e31i3539o12;p1r1D;e4248;s12AEt2Dz48;a4EcF2r5DA;e8BA;!d16eB18n1Es0;!a14o14;b3D8;i23Fk17C;mBn1Fr18;!aE80e2CC7i3099l44o14E5r36CDs0;a4DAAe3A69i2BB3o2C67r1516u40FC;!d20De159s0;e1i1k18;c3328d473g44k1n3F7Eo5009s56t262B;e30i3;!fF5iDCr9BC;!k46;c2EE;d0l6A;nEt234;r25v3y1;d0e0y0;s424Ft2D;e12Ef2Dr3CC2wBy1;eDl7n30A;i31oFC;!o1D;a3BC4b21DDc341Bd213Ce426Cf2F22g2E5Ch2817j469Ck3B96l44BDm47DAo9p3063r3E8As3249t1CA7w4BBA;!e15i43o1Fs0y0;e33m0t0;x78;!b1E2fBFgBs0t427D;c3d1s3;eAi419;eA04h89Do130;a1132;f0n2o9v3;a1e1Bn2;!s0t22BE;iCn3o2Ap1;a1439c3FE7d21F3eBB9g4D32h1i102Fk43EFl2258m3A44n39F0o4E63p420FrBD7s38BDt32C8u4829v166Aw4D03x2E39z48B7;c0d3059fF5lD1t3;r245;a3Be126;d87i15B;a4223e3511o42F;!e2AE2i22Bo2A5Eu18A2y304;a1BDe1;a628;l6Ar36v19;o69;!e4i6k229oE7s0u34;e1f7s14t7;d3kBr40t3D04;!a1Db12F2e9i5002k5Dl7m4AB1n22o1847p474Cs0;!e4i6Ds0;n3ADBr3C50w0;a316Ee1F1Bi19D6o1u1187;!i2C1l7s0;!e4i6s44D;!i2713l44s0;!o6B;e4502h1678i45C0o145A;r145E;!e4932i204l170m2315n22s157y0;!a10f1n83s0u14;!dB5Ei0l38o0s0;k2AB9;e24sB2;h1Fi31;d50Cl307n90Fr328Fs1t800z3F4;a501eA81o16BB;a6Di6;a250Fo3A0E;g6A;!aCg0s0;!s255;eA2i18;e15i2F3Ay0;a360e720i14Do423Fu295;i2E12o38BC;c1Ce12k4CnF;e17Eo431BsB30;p3058;!e101Ds0;g66Ci8E9m28t4EFFy0;u21BC;a23EeB9i18A6;n507Et1CDx0;!a100g7D7l1D81n22o1B6Cr5EEs0;c3Ce12nFo1;k1Es3F9;e4m0;!e5l3E1;e8g0;m0n2;s22E;l2D3o5059r1218u93E;l388;i1853;a21C2e305Do3F67;!a20eD0i2EEFoE7s0;a60d1i22Bm27;!a4De2A3BiBCl112r1D54y0;i4E08o4472;g3k0;a241CeB75uA1F;i3Fn19;!p3Cs0;!i4Bo1;c1E6e1Bl7n2;fF5s16B;!a8e192oDs0;l2F4Cp1C23v3A85;c4Ct3;a8DFtBD;f747;!e0s49C;e104i6;a4BFi13o9;!d0i6m2Er1s0w439;pAA;r1AC;!r3C;e50m2D38;a40n8;o953;!a12e1Bl7n22;c58l386m1t2808;!a1C39b2F98e4264i3B6Al274Fo2D67s1A0u1C86w463;!a488Bb748c1D0d3179e1DD2gBh424i4l734m2En22o49D1r4766s0w406Ez3BF;i13l0;!a291Ae1i3171l160Fm7Ap4309s0;c490Ad31B5g17Dk3532m1C97n49F7r3F71s1EA6t4DB4u214Av384;a3A3Db1C89d2337f2257k3m237Cn221o42A7s4A81t37B8;a20BBb89e11BFf683h109j4FEBl412Fm1AA5n1CF9o13FBr3D17s4431t4A19u1A8w2CC3z389;i6C;d39s3A1At1;l4r14;!a52eD3iEs0;e0i250l1;b1c24Fl3F4Fm9DCt19E4u1A24;tByC4;a307b1f8iEkA3mB17n2AC0t38uE;nD8;b3CCBc42D1g4Al2BACn4CB6r4s2087t1C50vB95x0;i3B68u139;a3E;!n4A44;e187Ai10;b3F79c2186d3C43e191Cg11EDl3E90m461Cn314Ar183Fs4C0Ft3014zE16;!e46Di4823;v7A2;e10DnFs11;eB3nFs11;r5A7;a4F3Bi1F9;!k0lBp28B0sC3Ct20A3;a42AEd1De13BAf1E3h1D66i6k4AB7l38DAmB7n3594o4552r2675s0;!a51eEA;!c316e4i6s0;!d0l22r1s0w9A;i2CDBy0;!b27Ad1F3Be4f27Ai6n401Fs0;r25y16;!i1DAp397s0;!b3D8l0mA3n1D2s0t1B6;r1t0;!a2EBEeAi296s0y64;a1D07o2D0;i10o50;a32g1sB6tEFu418v5B;c2347i2024n43BEr2828s257;a18C9e25B9i165Ao31B3u3948w18By4A8D;l29Fs0;!a3B15i3C4Ao1AD3r400B;r4B08u6E;b76d1eF29i4BA0l158p1Ar3C63w9E8;!aCg1i467Fo4B1;aCe1i247o1;e32F;!e5l25nA1s0;iD74l3795t28;e2392;!a4283e48EDi14C3l2FA4o3719rA7s0u48F9;e3Dm0t70;!i0n8;!e23g2Ci3C5Fk822l7Cn7As36BBt38y0;!s0t1FD;t456B;r402D;e3EC;i172o6;!e5i4B6o3Cy0;l41F0;g46n18;!a558e15g1i21o29s0;y1EA5;h3D7Em186At1B7D;e6BDi21;!eDoDs0;!eB66i6s0;rD38u4BC;!e12Ef37l2Co0s0;h4411l8ACp39B8s1DA5;c2Cr4775;c2D98i4E25l513Dm1008nC02s3DDCt2E1Fx171;!e38i13s0;d55s55;!e0l1DFDm7DF;!eB7hFBl7o29s0u202;e1Bi6;e10Di6;e4081;a20e1Bo3DCCu5;cEd70f823g2E17n3p4F0Er60;aB9Dc6B9d47EAe1D84i4FDEj376ClFDFo4D5Cs3DC3t25FAv4DEF;!d25B0l7Cr58s141;a49E9e1;!b29c30EDd60Dg50DAh393l8EFm3129n4075p505As157t3DCF;e1i7Du5;l1ED6;!eE5s0;!a10c1F96h28k29EDs0t140Du14A8;!o1C2s0;!d8Ae1B2i86l7s0;!e15i97Cs0;t212B;t6BA;a7Fc18h3k28;e1oCB;e1o29;e5o29;r419;t4F72;a0n3CCu14;!eAi6s0t2630;!d0f37l22m2En47r39DDs0;i5B;i20uB;!d0n5AAs0t1;!a4DeCFiADm74Ao12Dr237s931w2C0y0;n2t5A;!g0k611nABs65Et474;h1Fi8FsB;eAiDFo12r1A2;!d0r1s0t16;hBt1A;aCcB2e1E5i6tBAFu127Ew240;b1Ae1B4;!a51e6DDi86s0;!dA59e23F2i42E4l158s0;t4E6D;!d0g89Di3Fl1FBDs0;!a75i4E71s0u14;d6D3k1868;f1F4tAA6;a30d11At8D;rFy1;m63r188;sD2;k4CnFt14E;a104Be4B96i3178l1A15o2E2Er42A1u195B;e24DDi6;!g388As0;h1l0;e21A3;!a2CEBeAiADo46s0y0;a495F;a359e125o24A6u2CD;!a359Dl22m1690o1101p4C23s0;o4DB;!e208i6s0;!e0n0s0;c93l1B1;aDo29u14;n2F1A;!h14A;!e40i8Em2Es141y0;a1Dl216o827u71y0;e1B53i21u202;a52Bi6F;c3CCAd2FBFfAD8l387Cn34E4r1C14sBEt8BFv2C;!d0n0r16s0;n25Au12;a57o57;eB0Bh4AA3i574oA5B;a10e2F4i5044o122B;!a20e24i43y0;!d0m2Er1s0y0;!e15i6o708s0;!a1761c3202dBA2eF2Df1k3CA3l4AC0m1555n4DECq9EBr2E9Es4556t4851v1326w1495z0;!e1091i86y0;i1o28B7;b408;o9Au3B7;!a3791c126Cd1C2DhEDn999s141;a252lB;s438D;aACu69;!e14E4r2DDy0;!d0l7r41;!eE74i6k7F6s0y0;a22AD;e4FBC;!e15i6lBo28s0;a306Ce322Ci3134oA08u1F67;gB00;!r5Es0;a18Fe5;d1B26f1g478Cn39B0r1808w210;e10El7n22;l76n1E92t1Eu4CCy85;r2Ds2C8tB6;c61e5;aA63r26C;a321;!d27g16;!cE;!b1EeAi6k16r1Es0;oAE2u3DBE;r3C8E;i2Bo1D4Dy0;cEF4g97n37DD;bAB8e12i63ClFC8nBE9r6CEt2915;oCu0;r8D7;iCDrA53;e1l2Co772;e171Bl6D1m63;i3992;!e32B4i1l26D1m7D1s0t1;b2ClA3Bo84u59;a190Be1i2564mBo720u12;!aDAe15Ai6l7;p113;!e4f1E3g19DFi1BAk274l22mC8Bn2Fs919y43D2;!aE97e1FACh38A1i314Co1B58r1531u1C2;e2241;!e456fC3h10Ci66l83Ds0y0;a1eFFB;h2DD;c32z17C;s4A7E;!d0l1D8n0r3154s0t3C7B;e12h1A5r2D;a12kA80o12;r186Bs1F;s1Ft10A;c48fCAs48;b1CBDe3FAf47E8l2803n23D1p2EB8s1F18v166FzC66;k2590;e12r3D56;o334;d0r78;d2Cm95Cp5As554v286;e352i3B;i3D66;!l6E8r3s0t20;t1D87;a20i9o74;i5068oDAC;eBi364t3677;a12e23i2CE;!a930n4E4;c393d437g4094r16C3s1B73w47z31C7;e34A1;n20r16;b1CtB4;a10c1e1Bl7;c0t5E;o878;eB3l7n2s11;e1i2BB;b7Be3D5lBo1t3E08;!e4t11;!e26iADs0;u423E;!a3A8Cb101e1FB2iBCl207Dm280s0y0;a4D67e1EE6i3569l3CE2o1ACAr316Dt310Du3824yD1F;i10EEo12ArF6y0;!f37i16CCl22s0u3D;nFsEt511F;c898;nF2Cr491t2D;d0l39;!p29sFC;!a44Ab4BD7e12i21l509Co468p4EEAs2A37t5F0w4088;dBr9;h3E6i8BC;rE9sB6;a52i9o36u5;l21BDm27A7;c1D5e15Ag3BAAn129Cs3565tEAE;eD1i347Du10E6;a3D33o21;lE4;!a75i1u14;gA8i10nCC1r2513;a13A7e1D58l29C1n1831pAA1s1D9Ct2F87w15E3;e964o46;!iA52s0y1F91;!b18CBl74Cs0;c9Cr3;e345iE01o2290p255u478D;!a1BBBe1m4D9u1424;e0f4B02t3B9;!e0l1r25tB6;f2Dn3x3A;!i2Bl2Co1CBs0u0y0;l445n179;l204BrB;d1Ee4;m1n1u5;a6EsE;e1AC4g16A8s11t0w40A;x55;eD3i1FA3l3761p2Cs262A;r20C3;a691e4i66l44y0;d1r15Bs2584t2511;b2C5h5150k33BEo1s3F76t2394w439;!b3DD1c557d0fC3gA87h899i6l198Cp68Es3CEFw5B9;!a30e27Ci6o12s0;!e40s0;!bF8e67f37i21;cC2e1Bn2;!e201s0;b3ADc31Ci84m3AFn30E9p1FFr3;!i6l0;o53D;!l38s0;dBiE4k265n1DC7r10B8sC7t60;!a2523e40B8i6l22o3EEr184s0;!b56Ah1r195s0;u17;a40i4EoD3;b3F2c6DAd275Bg21B7i4CCAm2A94n19E7p4020s182t12CFx7;e57i1146;a472e973;eAi6nF6;r44F0t175;g385Dn35CDtC87;!e1CAFi38B1o1836s0;c1Ce23n2s11;s698;lBs3;!eAi39DEo4EAs0;c32t84D;d0n16r0s8;d2Cn1964p257s8;!g5B;g5B;a189Bi1276r1A;!a0e2634;!i3Bs274;g297h350l1815;b1CAc24D;aFD7e1450i221Bo2256;a328e3Fo36;m3FF7;s8DBu5;!b269;!fC3g2650s0w2131;!a40D9d47i483Fl12A9o397Cs0t147F;a57oDD;e187i6;aDCB;e12i26FD;!eA7Ai6y0;!a1De5i27m2Ey0;e24s11;!a3406e1Bi565l744n22r62s0y0;l1tB;a71e25;!e67f37i6;aCe5i13;a8CCe1CA0i2BuBvF5y0;i18Al6As2CA;a1e1i3F;s95F;l3526;l6Cn1;a4507d1A30e4993iBCl2F0Ep2D25y0;e0i18;!e0i18;h0k38;!a137e7EDi66s0wBFy0;!a7Fc44i25rE1s0;e264r35E9;n4E69p135;a0e26i6;!i160r1E;a3C6Ce154h116iBt2B4B;!g19r1Es0;d0e12r598t39;gBi180u6D;l1E9Dm0;aFe72i72o134;!a5Cl929s0;i8B;!aEe1CF1i6l688n22s0;t144;!t144;!e15i189Ao29s0wEDy0;a2407c2211d2A6Ef9AAg16EBk434n3E36p35A5v75F;!e4i1FAl1Es0;r4714;n119;!n0s0t2D;!e4iBCs0y0;aAD4;!a0l7s0u14;!c4D80i6r47s0t9C7;!e15i3AAs0;a302Bi49A9y0;!e325Ei66y0z2B;n3C93;!d0p61r1s0;c13Bo0s4740u22E;v9B0;!a14s0t0;d41tEF;s418F;c3AEg3AErF38;s4Cz4C;!a137iA49s0uB3Cy0;aBAi94D;!c2D7i5;!e4i6s251;e5145i11Cy0;g231l118t60;r106;h5A9;!aE65b101e4BB0f4D30i21l323n0s52;e3391u32D9;cA5e1Bf1n2v3;a1CB0;a20e5;f3F54t27B5;d19Ae2657i4v1E;o10vB;i5A8p9BtF8;a11e4i6;hC39i1DAs1997tB71;e2BC;!a4De15iBCl24Bs0y0;d3E50n709s3BEzA6D;a1e35CFi25BDo12r62;eDn2s19z19;!eC0f37i86l7s0t1;h27D;!e12i6n0s0;a27EDb5081e47E2i5082m3FF5o38AFt360uBA;e315An367Bo2DFpF5rB7;a678i1AF;!cB2h4DDBs0tAB;a371;!b1C0De1Bi3Bl7n22pB;!a5e4s0y0;aD7i72;n65r19t19;f3F6k4A25l47m28n2FEBr47t0;!e15i6l19s1C9;g1o1382;!a1i3881s0y0;g1CFk976t38;i21oD7;a517;b1AnD12r5E;n8r1t3;e36AhCBi3Bl3A0;!nFs938;nFs27E;b20Dm35nE;a10e455i25A9o3214y1A;!a47ADe4i1E1n22s0y0;a1CBCi9s3t39;l278s5E;!d0s1t1;i9u5;f108i10l3An1D2s20;!i13l781m128s0;!n22w130;!a4De15f37i21l6E4s25C1;h1Fi4D;!e0l0r2Fs0t3;!cB7l62n1650s14;eAi138Bo4FC2rEB;a18Ff2D;!gB;!i2Bo29r7s0y0;i3623y0;a414Fi346o4C6;c2AE3;c2BADdFBe2E3Cg37AFn117Fq27D8;a49m79B;aBF8e448i209sAA;!a7Fe4i6s1584;l203;t19v9E9;l32Cs0;!e5i663o46s0;a3976b86Dc20BEd3126f108g4406i1D8DkBm4215nC70o1DAAp30FqC2s1EDBt4AA8u427Av23D2w4F23y48A4z3;r34C;!fBFn3s0;!i4915s0y0;a105i4532o2065;d47t0;g3773;c2F01k4189;!a72cA5i6;i31o642;a2A3o31;l1r3D;!r57Bs0;r418C;e42u49;d1k5Dn11E0sC7t922;!a644e1CD9iDDAo1s0;c2Ax0;!i597s0y0;t1AF8;!l100Ar36sA7F;r1287;e405i190y0;e33CAn4461;b4669c109Fd0f1FDEg153Ci2707kBm343En207Cp272EsD3t1CDu1C04v3w3D62y1582z89;e4C76t22EB;a1i24D1r1sDE;!c4128d28gFDn7Ao1DD9s0t5D8;s23D5t2Du5;!e15h10Ci66s0y0;!hEBm2E;s2ADu5;c8g739kBr425;a12h482Ak28;a322e1fCAm5Bo29;!eCFf37i91s0t0y0;!b4D94e12s1A0w13A2;aCt380;e5nFsE;!aCe17s0;!a4143b17Dd206Ee514f2E66h3EDi1104k1l170Em2A3Cn136p143Cr3B1As30A4t4599w40Ay0;e1u54;b15E6e390Cg746k3m3AD7n3pA5Dt60v2C;!b134e4i6s0;!b645cF23e15i1E1l220m2Es2C6A;a563e1o46;a25dDCt1594xC1;!m329s0;!b4529dEA3e1CEBf6D5iA00k47l495Es2E1zDD;b842c434d1EBEe40CEf42F8g1EF7kBl2EDBm4A97n2CE8oEp3822s174Et46CEv76z42A3;r522;p271;a20e57;c42Dh1l3C70q2199;t4835;l3105;!c13Cs0;!a4Be10Bi6l7s0;e0yC;eCy0;eA41i5DFy0;e1Dg1E;e42m210p35F7s0;m85;a54o57;p3592sA92;a0c0d0;c3Dr34u59;!e4h16i6s0y16;a5125e3D6Ci41A7o48E2r7B4u1B5Fy35A7;c32mB;m1An2848pBEsC1t2D;!h3C62i1s0t0;m645;eB7B;!e15f37iC9s0y0;!a75i233o0s0u14y0;!a2D23e15fC3h5Fi3692l22s0w130y0;a3A24e1F69i6n3oEr2E5A;eC0i86;!e3BF6i21oFr3C7Cs141;e4i27F;g0t11;s65;a88i26DCo1182y8EE;e3051m6FCnFo32B9p1770u277F;c0e1s8;c0e5s8;e33i1BC4o1E8Du71F;rE3;e139i4FE4o12r22u3935;e4i18DFo10y64;!d4Fi4m3;n2s19z19;k0t28;e23i6o54;iE76y0;a100eB28l2AE5oC6r515;e8D2t0;t1FC3;!a4Bi13m4D9s0;e31y1C;!t2AA0;a166B;i2F6E;t1B0;!e769i3ED9o9A7s0y64;d16g2553;!b47A2eA79i548l76s0u4E;g3Dr0s8;a937e4i21;n1A2;e26i4C03y0;s528t3C66v19;e211h213oB8;!e4i1F9As0y0;a4w0;!b422e4i6pA5s0;a423;c0n372o9v3;eDi6D;a1786e1017h5Fi1A7uB8;a2036e35F1i1F21o4DD3u1F78yC7C;rBs511;g17Dh137C;!s2F76;aD7Ce1E40h7oC5;!a0c1e1s0;sC1t3BAF;a2EAeAi6;h2C;!hAE;oB36;!e4FDAf37i21l22s0;t46FD;c22B1g3Cn2;a37E7m1;n53o9;l3E62n46B;e92F;!d0s0u12;eAi6t16;a1n3t3;!e24i6t16;a5DDi18Cu693;e40i21CF;h583;i511Ao642;d0z1E;!e23i2FC;b2706;!o4C6As0;!a4Dd0l24Bn22r1s3E;e95Bi38CAy0;a1CCbFDe1i4176;r380;a32CBe35C8i287Eo3D0Au4E81y3DBA;l3C55n1F6E;!a1B3Eb27Be15h5Ai4078l7Cm2Es3FA8w34FFy44B;!e3F1Di20A5s0u1;h2A8Fk47;nB9B;d3FA6e37Ei25A4l50A1m1CF6o4A53p3CEs1A0t1y0;l6D1y0;n994r45;d0k0;e5E5i43y0;i27o42uD0;d0e10r9DDt16;u240C;s903;d0l503En1rA10;s8CC;c0n2t7;!i6F;b169Ad1g2451n4D71p2FACr0t36E;l331;rB8s36;!c954l7Cp101s0t3001;i277;!eEAn3s3;b7t0;c257t0;bCBl3C;u1957;n149s11;!aCi61k1Es0;e17i20;h35D2;e39Bi20;c15Fn2;e18i4;l267F;k5134;h2334;a99Ce0iAC;u32EE;t3B69;n8t0;!b5De15iC9l22m2Es0y0;a4B4Be2F5l4D5D;!eAi6l1E;x1A4;eD1i3EED;aCi47Do417u4E;e5Bo35;c2Ak3n807s11t3;c3BE5;f454Ai4A4m7C5s45vC45;d0e330g0i11D3k47y0;e2498l3DC4n179;m1n1r2CF1;!aA4e14Di235Co71s0;i48AAt203;l47BAr393Es29;!a15F4c69De426Dh391Ci480Ak13E1mA5Ao2122q20C7s26EAt1B3B;!c185f24Ai0o3C4Cs4150u5;y422F;e143n76;o24F6r2Ds8CA;k4Ar9t8B;!n222s0;k8B;gBl3Ar3AtB6;!l158n28o1AAr9DCs0;!aA4e153i66l44s0y0;c7l1t3;e10Dl7nF;a105CeD94f24BAg19E6i14DCl357Ao4733r30E7tC54;s7y0;o2EE;!b1993c11A3d163Ai6m2En25r1FABs0t1FF8z41;c22EDe5g62;p1EwA9;i16l117y28;o56B;g3790;a2C4;!a2184g1C4Em183En21FFo33C8p179Fs2687t297u15Cz38A5;!b2415e3D64i412r9DAs0u1C3C;d0t70;e639;!e40;!e12f37i8Es0y0;hE9Fr1EE0;b1CBi3;a1C0h6CyC4;n56;lCt11;n2t58;n816;!i27Fs0;!e4p7s0y0;a59e166i65o49;!e1DB1i21l21Dn23Bo260;i57Do3429;g49l1C;t9B7;!d13Es0;!c9Cs0;cEFn1pAAB;!d0e9f37r1s0;e1934r181A;!d1D6Fe1743g4898i808s0u506;a1EFd0l6Cr199;!d0r0s0y0;b1Cg369;!pDDr364s0;n39CFrBFBt28;!i49C1l7s0;l3At1DA9;d1l24D;l28n5D2r2Fv459;aE51eE6;aCBiA5;o12AuB5D;n4A21;a2790o1;n38A;a416l2C;!i204l196Dm27As3BEEt5C5wA7y0;!e4i4BB6s0y0;!a4DDAg2ED4s0;b4AACc11A8d10A3e10A0g4B26h1E00i1302l1E4Fm40E1n247Do449Cp802r3236s4640t3A8Fu25C6v296Dw21CCx3F55y4F0Dz4146;r130;!c32e5o701;a519r14DD;k289Cl22E0n21EAp869r2771s4938t33Cv32Bz100C;i7Do10;a2C20i8;i352B;i83En1y64;i233u5;!b1D1c1E4d3Al365p109r1s0;l3u5;a4De23i21;f2Dl3;!d8Ar7s0;a30Ce508E;!a10d0r1s0;!f3288i3Bt3349x62E;!aCe5i49FAs0;e4DFA;aEC;e3C11;c4Cs5Et2D;a2C13eA0;e2A55y0;c4F0Fm95C;a2A0Ee4F33i12A4o48CDu488A;g2F6s1AE;!a4Db3DBc9Be382g167i21lE1m2Er237s3073;a32d0e25;!e4f37iC9l22s0y0;d3n2;a83;a3317i3420o12u3E8;o642;e1o34;c3E97e110l4697;e50DhB;k1AAz83;a28eAh17Ei38FpD6u201C;!a31b39De2F9Bh10Ci3917o28Dp8D4s3175u4Ey0;n4Bv55;s1CE2z3;!m0t70;a4D38;!n430Ds0;!e4i21o38CBs0;d0n16Ar16t0;e7DD;e13A6i86y0;w2413;t2E1;!t41;!e21Ci23Cl7s0;!e769i3B20lBr76s0;!m1AA8sB77w240;!c41s0;k4F;n2B4A;a179Bc2F69e24CEi200Eo10t1A76uC44;b1Cg19;l4o46D0r161u1DB6;h76;!eAi21l1DB;i1Ey0;h1n1;a6FE;a1e5CFi6;e1724i23Co57;a2C75c29CDe2A4Bg4FD5j13C1k11Fl1D36o3EBFr159Ft123Au15Cx285F;!e4i18s0;!e4i13r7s0;!d0mA5n421r1s0t0;e351;e8F;c59Fr60x35;aE8rC2;h427Ei0o666u4E;cBt7;c7tB;!a2AAe2AE4iB7s0;g1i2AAB;g2E1;!g1943i0s0u1F9;p6A;!cD6g44k5Ds0t14A;!b3D9z116;!b1D7e1Bl7n22o1;q90Br5AFs22E;d16k16p16;!c37B2e4i21n22s0;l4D0E;lA85o29v3;o510C;!a10eC0i6l24Bn22s0w2C0;a828p20D;u8B1;o4EE;a395eC0i22C6o1u14A7y4E7F;oB14;aCg5k28lBn6CEr1E57s259;aCD1eF9Ei3F25;y1B4F;g97mBn2;m575sC1;l445;l87t1;!b210d34Ae1782i548l498p280Bs3450;d40CBe3452f3B9FiEB8l258Dm1o402FpBy280A;e4i296y64;s2AFF;i5o6Ft95;t4E21;a20e3A;!i138As0;!e42DAi21s0w169;m29F;y9DE;a1e24f7o3681;e1i9;d8Bl62;k53m0;a25o14;t5EC;!fBFn2s0;!a1De15i21s0;!g1D8Cs0;d0n1r1t16;l342;e1h4325zAE;i47CCl44y6CB;n13;!e4f27Ai6s0;a10o31;d298F;!r992t23E4;a1313c17BEh1Fl304CmF55oD01s4570t15EA;u25y25D;tA4E;e2BF;i207l227;c58g61An376DrD03tF49y1A;!a4Be12i6s0;j53;a4Be1;!c6Af61s0t1;a319Ab40FBc4CDBd3525e4991f2CEAg255Dl4975m2691n3993o4A2Bp47B4sCEEt1D9Fv1DFCyCDz1A;!a4DE3e4h4931i36n22s0t0y0;e6Eh1;p369Ez6C8;c93f7qC2;a99Ce510lBu1C;t40BA;a1B5e92;yA0;d1El3Fs0;y2759;aCe4C6Fi13u4E;f106;l4979n1;!d0l3Fr40F7s0;aCeAiD4Co46u1Cy0;e0h2CF;h453Dt4B3;e2810iBAl3811o371Fr25FDu2445y52;!e4i6s0u5;e12i6l19;aCo10;s57;c2Ad89g3B7m24F1n2903t908;b1CsE8C;a44BB;u125;e1i335Eo29r306Ft3C;n21Do1;!m0n0s0;s1A4;!eB6Fi6l7Cs0;r5AD;eAi13oD;sEt7;t908;g1t19;!fF5;!l7n16r0s4D68;g3E81i69lA8t1CA;!a1394d229e177g711i30FBlF6o3F8Es23A5z350;eB0B;cEn1r4426;a238De452Bi29E0o429Cy64;!aD4eAi6s0;hEi35;r266;d0r1s4F6B;!a1bBdA7e27EEf53Ch35DBi21o4935p314s3Ew390;a1DiACo12u49;a4Dc491d286;d3p3;i18y18;e4E0Eo3DE8p56;e12i10;!c2559e0tB6;b7Bl1;!a1DE2e2832i11E7o434Es0;a5110e4F9Fi4C3Fo33AAr23FDu47F9;!e4i30E6l803r19s0y0;e1i5p43FBsC8t3B3E;e23n2;a10e18Ch213iD8C;i476D;!a10o10s0;oEt1;!e14Ci17Fs1269;a1EFu36;!a4Cf37s0;h3185o2F23r44C0y361;h0k658t194;o4E43;r8A;e1683g18C0i484A;b4D2k4C24;a1b120F;d3r8;!a3173c3457e29B3h2441i12DAl38B4m3302n2B69o370Cp10C8t2205u1F6Fw1DF0;!e48E6i86l7s0;l47t0;a75p0u34;a10l4AE;a469D;a12hAEi0s120;e30g3Ct354;!a1EFCe10FCi4923oEEs0u5C;e5Bi5F9y0;i12mE9;!m70t102;!e4i6m2Es0y0;a4741e1583i2F85o6DBy64;a1s3;w34A6;!a322o1s0t7;h19C0;uEC;mB81tC15;aA4i4AFy64;v2Cz4901;r4t3;a558e4293i6;n2993;o723s11Bu5;!g2EA1l7n22s0;n2s8B5;bB0l3B6u1CC6;a3E4Fb31ACc1EA8d1897f3A0BgCBFh4BE5i42FDk49CDl3186m2216n1DB7o44F8pAD6r433Cs478At2767u197Ev10A2w2F2Dx3C8By22CFz3C;bAFBp16;a40FAc1C4Ce4191g2DD2l4CACm718n41FBo26DErD89s15F6t200v89;!dA7e4i21s0t49F9;a4D7Ce3687i4FEFu1C2;f96B;gBl0n8r25tBD;a303Ae94B;!a283r1s0;aCs1F;!c48e1i0s0t3Au5;s1BBt38CFu5;l6E8;a9B8;!d0g87Cr1DDs0y9A;lA8n1o10p29s19C3t260Du5w1;!a274k3s0;i2A8B;e6EB;o42u410;eE4i787m501Cn4B9Fp2AC4;a299c5045eAfBFl2Cm2Cn4410r1D26tD6;e3E13;!a1AFe1A3Ei4337o12s0u3;!a75i18s0u14;f161n32;t142u10;dA1nFt2329;!e5o36;e5o36;!i54p422;r2CF6;!aCe872i13FCo1B76t0u5;cD1p33E5;f17B;a37B3d129e2938i494Ck55Al38B0o1B62t1195y210C;oAE4;o1E43;a4C68b5131c1C20d1437e1CA8f213g248Ei2C06lF9Fn1B75o1494p49E6r347At4DE5u1317w5E;r8s3;sC1tD2;r4v18;!e4i3s0;e352Ai6y0;!d0i6l57Es157;i482w0y1;c461e71Di0r58;c1ABe5;a20l1;!a10e64Ei6s0;nBs1Ez1E;!f4AD5i12s0;c0o9sFEt7z3;!b7Bs0t391;!aEB0e1Bi2E84l7n22;a0s34C;e1851i1BD7;e5l19nF;bBpA1;!aD7t0;e1653iB;d0r308E;a22EEc4388e407Eg3009k1906t28u3196;!d0l1n0s0t1CC;a12Bd151n778u991;l2B;l11B;!d8Ae36i345Dl816s0t7;a43BAd186e1p85t48AC;!a4De1814f37i177Eo591s0y333B;tA1F;!a50A8e20Ff37i151Cl22o49B3s0;g1o1;e2B77i6;e3E;!e15i6n0s0;d3C7l34m110Er1858;!d38eCFi21s0t2E59;a15Ce41Ai6;!e4hB0Ei6s0;r4E3Cv17C;!eDCh9Fk46t95;!d0r1s0wA7;c3o3BBs0v3;!a3FFn0r1s0;!d4F2g97s0;c49r286t1648;f566;p19s3A8;m91DsC1t2D;d14Bg97v3D;n2E4F;l261;i2BA8;!b237;a6DF;r16A;p1834;!n27s0;!e4o29s0;e4804i343y0;!d9Bg38s0;!f3D75r4BC3s0v351C;a180i132oE7;h41C;!d50C0i3Bs0;n16A;d3CBl1660r62;!e4i192Cl170n22s0;e1D8Fr24B9;n106;gE89w56D;m38;a299d37FEe0i5087m3B42n24DCo261Fr4525sE03;e1i3B;c13Bn25t1D9;!e15h1i6s0;!e4i21l18CCs3AFA;!c2E13s829t5BDz2C57;c3C12n2;n74B;!a3D20e2B09g3B89h2F7i2FB9l3AA7r237s0u147Aw169;c1C55h144B;!e4i190s0y0;aCe5iC;!e39Bg1s0;sA92;e5n11E;r1EAA;t1E2;e2483iB00;!b30DFd509EfE2l22m2Ep4BCFr1sD4Dt6C4w47C1;o164;d124C;!i28Do33D;a20i0o29u5;e17i8F;aCe26o9;cEn65v19;r25y1;a3AFe1F31i3E7o1F19;!d8AeAF6i856s0;d16i22Bt0;d3Ar598s5;nBr16u12;c0e10DnFs11;u18B;gE0Co1;a7Ei31;a217A;!b31DcC3Ad52e4g1A9i6k1l1m178Bp181r25E9sD78t16z296E;!e15i41BAs0y0;sC1t102;o4u5;!a2FDBc27A5h2F0iABEo1s0;!a29BDi186Fo5s0;d0e4;e26CFo3AF1y5C;!eC0fE2i6l7Cs0;aDEt47;i4oD;!a4Dd1E65e4F69g2Ci21o1s0y0;lA6An188u2AA5;aBE4h4E39o1176;a40hB;!c9Bd60Di4A2l83nF34s4C3Cu5;r2Av3;l4536;n4CF2;!a90eAF5i4334s0u36CC;e20FEi2557o3A6B;!d1s0t197;a10C7e4039hFE3i39F8l3899o2522r2491u1746y2FC5;a373i207l16F1n1704r2476sA55t1CD;b4CB3c46F9d27C6e24AFf3715g33A9h30EFi2820k4742l39F2m259En1284p33DDqB1r2046s44FBt3A7Au42EFv2299wF2Ax3E49y481Fz28C;!e1Bi3Bl7s0t7;!a12e4945uB8;aF03e6E;a3628u2E6BwD8;a52n2;aA4iB9l687;!aCe33i1o1;!a4Db181e15i6m2Es0;a1F51eF62i3BD7o152Fp709u2382y42DC;eDAuA0;!c58r446Cs0t4425;e5Bo1;!e15i6o242s0;!e3s0v18;!a4Be20C9i1BAn0s0;c6BF;a9s155t7z3;b1Cc59Fd17C6gBl1391n3B7p56Fr451t102xAB9;e1iACo46;!m1As1AD8t102;!a97Fe470i4E11o29A1p1CEDt1D3Dy0;!a4De23i495;e0i0u5;!l46s0;!e19h613i3Bl7Cs308w1BCy0;iEE;l1F4As0;g97l55n188t1;a19E8c3DEEe1AE7i3F8Fm76n3796o42FEr37D9t2F2Au10D2v12AD;i172o56;e5D9i1DF;e1oE7;l38;!eE8Di2C1Al220s0y0;e5i33D6;l7oF2;o140;uEE;h15D6;e37Ei1D88kCBu14;!e10m4E91z49CB;b22BCd2Bl8r3A51s241t0;o23FuE;!e15i91o1s0y0;c2Bn2D89s11t29C6;c3n48;e4652i86;a422;l2Dn4C5Ax1A5y1;a1DF;bB0c3B02d37BBf1DA7g1BCBh28i4A2lBFEm3609n3D0Cp4D54r131s1A1Ez374C;e27Ci6;!e8FDi6;u635;!e5t2D;a3C84e3248h3855i1AA1l1E0Co36EEr4444t1483u1CF3y2124;e6Er4C44;!c4296l41Cm3C91nE3p446t3FB2w637;eAh3l3;d5D7e5g338Di470Bo1s42C7t191Av181;!n3r38C4;a57e42;iA47;!r7s0y0;e366i48BCoA9F;!l7n22r4219s20D3;a416z8C6;!e15i509s0;c353Dn2q2DE1;eDr4D40;!eDA9h3C8i21s0;!b5B3d0n17D8s53F;t1636;c9Cl118s458Ft28;e175;l4B4Ez210;i43FoD9;e4i6l1BF;h3C1F;!e23i6m3512sD9Ft26C6u4D;e0i233;e43Ci6l2C;!a69e23i43o31D4s0y0;d210Fe23i21;!a2A63l30Bo175r120s0uFBC;!a3833e743iC29s0t5C5u27F8y0;d0r40;k1AzFA;n266;!a7EeAs0;d0rE0s0;p131;!i4n1s0;n1s5t1;!e15i21lBs0t0;a2107e2405i4753o9EAu1C0;a377Ei2E9o436Bs0y2005;sF3zF3;g1Cn1E;k1Et1E;f345A;!c7gBl0r7t205;!a4FC8b27Bc2A3Ae2933f5B9h194Fi32B6l737o2580p148DsFCBt35F9;a729;c7C1;!a729;e5n476;i2Br7y0;c1EnF;l194A;b5106;oAAF;!oAAF;a4De44DBi21s0;!e104i1B3s0;t40CF;a311Ei3DF5o11F;e1h4B23t23CE;!e59;!e4iCCl44s0y0;n2x0;g7A0n1x1F;a56F;e23i50F3t38y0;c2Al870s4F2D;!e1iBlDF2s0;a4937d338eEDFlD3Fp2F4Fr3EBw9;s4A0;!c23Al0t5BC;!t265E;c4579g8B2n1882r451u3ACBx11D;a1e11y18;p3A5F;eB3f20El7nFs11;rF09t331;e3CF6i50y0;lBy131;i216B;kAA;gA5o1Cp16;!e4i6l3s0;!eDl7yC;a32ACe2D07i327Co4C2Bv22C;!c1E6d0l7n39r0s3Ey1;e650l8;n476C;d6F6;i59D;!a15D0c200Cd1FB6eAg1i13k1A9l76n28D8r34Fs0t48CCwA7;!a244Cc324e3022h2F19i2B0Fm29o37FrBtE5Fu34C6;a20iA7Fl291Co338Bu5;e3CDAi5027l3y0;!mFBp12Bs0;i701;!a1B4g3BF4l2E0o2CFDs0w2F0;uA88;b2F;!d2Dg167n0t3193;r3854;c7d142t0;b9D4c6A8d2739fBFn3p30CFs384D;o6CD;l3E6;!aEd0l1m2Er3445s4C05t31E;e1DE1;a1t3;eBi3Bu52C;d3D9h1;a4367b970c1E36d7Fe25FBg4BDDj39A7lF1Bn353Cp2DDCs2781t10B4v350z286E;c282iE14l3A;g3ACt0;t2612;!b19BBc37CCd9A6e15f1489gAD7h728i343l4523m2En28p3920s3E9Dt11C4w1E6Cy0;k5An2;l82F;e425;i9FEl44;t1zB;!a24C2e19F6i1A71l3FABp237BrC68s383Ft38u32D0y2BFB;a4067i39B6u100B;!a858e15i86s0y0;!dABg2Cs0;!b5040c9BfB5h10Ci186l502Bm62n22p101s0t217Du3079w2493;d0n5Fr1;!r7Es0;!a4C2Ee4h10Ci23Do2533s0w253;h1FCC;e3FAf37;n1p8;h9F2l62;!h1r58s0;!w2C0C;aB91b1Cf503D;!o58F;c227s84;a4AEA;a4F7Bi3D37o1324u4DD0y44D4;a28D1b3C98e4FADi3D6ElFDm3B1En20E9o31DFp3B95rFDs0;i3A8;!m61y0;a125o2DFAu2C4;!e2323s0;a12h47;i13D5o46;a2F3;a4F7Ce2D6El4EBBm3n437Er2141s4F30t48A5u4B27y1;!d8Al10A8s0;e1Bn2p1EsE;!eB49i6s0;!l1r7As0;e1Bl7v3;i9k1E;!e4i43l7s0y0;r2DE;!a14F1c2246h3F5Bk7As0u4247;!eAi21;g69Bl4A67n211Ft2E8;m4272r10E2;cEFnBr1;!a1e1Bi31l7n22;d0i10r1t1y1;i9m28r8t1CDu172;a21e12B;c62d1B87g843n47BFp645s516t3F2Dw28y28;r40F4;!e4l7oDs0;eD91iE4o120;e8B;f56;e0i6;a2BCAi13o29;d48iEr48;b48D5fDA0m4637n3F19p1F4t115Bz2C;o6Fs0t2D;a270o1u4E49;e4858i3F;c3Di160rE0;k1CF;e304B;s368B;b3B17e1F9h121m2F99p4958;eAiAD3;!c40D1f1E3l7m1EEn22s0t4B2E;e17i32y32;l4D24t1F6;o92rEB;c32l433;!fEl2A7Bn1F00r34B2s3u274Dw11E3;iBBu5y0;e17j5A;o1B9u4E7;!e37Ai44B3t6ADuD1;eAi11Cy0;!e15i5ABs0y0;e30vB;a1c0s2BF;e1o12;l1s5t1;!e845;c5Cd87e5fF5o29t3D68;!m4DDr26C8t3CCF;a2656e1B2;!e4i6l668o127s0;e14AC;a4531e16BDi13B6o3FAF;e1Bn2t3C;k35;e4F7iADo10;t2345;aEeA41i21;!d0l4Cs0;!e50s8;b7CFl84m2Cp87rE00;c4B36h44D;a2188eEi31B8y0;e7E7;h1921;s4Ct2D;aD48e17FEi38AAl142Eo39A5rD8u9B8;!a4357e4E1Bi3C54o1620s0u453y0;l4F64;a57i5F5u6;r1564;r1D6;k2879;!e4i43l19s0y0;!d3746g14Aj14A;b5E6d44g2Cs554;b1341c4171fBm89n1E86p28AAt1v15DCwA7;a3390s5w0;!b1AE6e2E37f378i3D27m1309s0y0;!e0t2DBD;a4Di2064;cB2e1n4469s236Dt2Cv4DA;a799e23i2CE;i4166o3E4yD57;eAi31;a1De24n500t5A;a3D79iB9;e1EE4i35E2y0;e475;cEn4FE;l3BA1t841;y2;!a7Fb67Ee15f14Fi4D93l1C25m2D8o3CFAp3A2r3A28s4A34w9Ay0;e4i498Du32;!e510i5t679;g404A;lB9A;!e12Fi2663;e937l2Cr176;!g0i307l6EFn1D5rEt2F05w1;l120;i8Fo358F;c2Bd35Es1F;e12Fi4315y0;!c1427d2414e19AFg254Ci66k4DBFn4BD2o1s2354t241Ay0zB;!l1D1A;a1090i3889u5;c3C0;!d2057i1k2434s0t5124;mBn70;!e24i3D7o0y0;!oFz2B;k1n2s20;n6A6;!r378Fs0;!a0e1g354i13s0u5;a10e4iADy0;!i10l1Es0;!c2BC7d1506rCD4s49C;o39C6;d0rA1;!d0l1r1s0y0;!i9l7;d0r9B6;!a51e15i6s1F;!k27s0;a4Ci3E35u6;e6Er19;c417CnA2Do10;!e4g5Bi6n1p115s0;t2Dx55;a46D2e209i3BD5o13E;r515u3846;!i13s0y34;!b5Ce3BCEi4EF5l7m730n22o4DACp648s0wB0;cCECgBn1544t4027;nB4u36;aFB1e2688i57o19EDr215BuE;a38CEb379Bc1EA2d1C7Ee40DDg1647i2757j283Dk3285l14FFm346An4F93o11C7p400Er27ACs2F32t114Bw44C4y3EE1z46E0;!a40h27i13s0;c13Bi431En4p38r77FsFC7y17B;i5D6r50;r1B1;a17l430Cr130;k0t3A;i2367;!a858eAi6s0;c3d1g3t11;n58;d0l4776s5;h1ACC;!i4E0l7;e359Ao6BC;hC7;h1C9;f89j0;lB63n29C;!a4Dd0l3459n47r2091s0w2C0;i38Co29y0;s57B;m3BE0;a10r1D0;c2Bx0;!e2D5i2FCs0;a4De4i6;c0t7;r148;!e463Bi6wB;cF3;f7o9t7;e1274i22BuB69;n291Dt145;l39n16;aCn3t7;e15DiC9l2Cy0;d0n39r1s8;l1r21B;c7t276;!e262iC1Fs0y0;c19e50m39;l25u69;u353E;i3F87y0;!a1DcB13i9o10s0t1813;!l0r7s0;t5FC;h84;y898;e17i21o3A3C;n1s1F;b16e380Bi6D7s22EAt16y0;e15i5CBy0;d4B1Fr2226t7F3u9A3v379;eB3l7nFt1;n118r120sC7tB;r126;x56;!a4FE1d11F0e2F91g1i6B9j2FA8l4253n58p2955s2EB1t268Bu1056v4AE6;u9F4;t40D4;!e1i0s0;!e3o6Bs0;e6Er1B14;r65t4452;!a32d1f1k3A4l3BDFm1707n59Bs1E98z5B;a383;a6n11B;n321Dv2Cw0;k1At2D;!e4f37s0;a151;g0o1;e6Er4723;aBAe1;o52;!s0w9;a529;a141De4A77i1F7Do2E30u3643y5D2;e4i6o18A;a15C6i36;o1Ds83;!b26D7g28CEi360Dk4F6Am22n28p8Bs4784tD6;i13t2D;i63Dy0;r0s8v48;!d0l0r0s0;a12c8e2AAs2054;!e8i4s0;aCe1iAC3y8F;!e4i4F57l44s0;!a4F27b1DCCe4629gD8i2799mE0Dp1s0uEy0;a50u1C;i4n25s4C3w1A3y1;eAi665y0;!e24iC9y0;eAiC9y0;i556;!i556;r19y16;a20i0u5;!a1De4iDFs0u49;!a0e1BiBl43C4n22r1Es0y0;b543d3nE;eB48i6o218;a9EFo5C7;e1Bn2t3;i2FF4m1n0;!f37n22s2CAF;c13Bn2Cr15D2;i9AF;eEi0l44o0;b8;!a1c9ABd3730i96kABAn1762oB39s0;a4Ce1261i1BCAoEy0;l724;!l7n0;r18B;e8i2By0;aCDFe2D8EiCFEl20AEo1FBEr46F3u8DCy0;!r8B6s0;c22AFg2B47;!e288i4D44o3EC;!g2668s326t30B;!e1g0i0o0s0;t1FD;!b8AEs0;i8DEl0;!d184e412Ei40EFp34Er4BC1s0;d0h0r2EA6sE;eCAEo4500u445A;u4DF7;!s0t5B5y1;a1122g0o36;n1t294D;e2411i202;c124BdD2nE3Dp24DEs1Fx2AD2;i61o29;!gBr25s0;!d0l7n22s0;i2075o30y0;n1r117Dt0;nB64;e48F1;c13Ee26CBj4EFBn58o10t288F;!g20C4l2ABs157;i2Bo42y0;dBv9B;!e0l0n8t3;e1o29A;e4751;e39B;a0e0i410F;!b271Ae104f47B7g25Ei1644l58Cp3A2s0t1E7w416By0;!d0r10s0;eBo3116t1;a6CDe3Bu3B;e49DFi8Ey0;d61e67;a486Do4AFB;!d0i6mDBn28s0;s0t16F;l15E2m23C2;e12i8Ey0;!e12i8Ey0;a0g19C;a25n1C7;a8Fe9B;d43DFe12s19;!e15i1063l7m1432o1759r1C5s0w9A;e1DiC30y0;a370Ae4B1Ei1DFo2A9Fu4218y0;iBCAo4EBF;a65Bi0u5;!a52m1EoE7p6Cs0;dD6eAi6;n2s11t7;!e5h1F;!a2B97d3232e22A4f17DEi40F2m36F5n2901o3B6Es0t1454uBA7v4B53y64;n113;e3812;bB7Ec355o375;e1F0lE1;a233i247uB5Bx1F;a203Ee282Ch2F6AiE1Do103Fr1455u44AEw627;l1A4r1t38B;g1m1;s619;!l56;e1BfBFm2F6n4C2Cs1C69;!a13ABe4B33m3F75p29s0;lB68;dBm2Ds2AA1;o159;a1Dd48i4F26nEp16E8r4A1Ft31E;!aCe17g0s0;m4B3A;!a0e1ECf428i3BlBs0;aCe3ECAh29B8i4D7Ao487;a1c0dB;o29r48;!e224iBl7s3E5;e8t3;!h3D1A;c19n19;o260;bFD;!e256i132;cEFk16;!i35s0t7;!a4Be187s0;!e0i35o40;e12hACCk2B6;!n7;a1e30;l70nA1s3Du5;n3077s669;a0i414o9C3uE;a45Ds0;c996fE47g2F50m4985n1D13r485s1BB2t320Av1332;i3309y0;h4194;aE27l3924r382Fu4E;d455Cf3A38i424Ak1F8l6AEn16E6o1FF5r3AA2s197tFFDu2CB1;!mCAs0;mCAs0;i13y6D;h580;m0t7E;!m4DB2s444Ct60wA7;f824i1k82Ep1BBEs0t4905;a75i88u14;c227l0;r5Au1;l16D4;lCn443;oE3A;e402i6y0;e0i16EAo6D;eCs0;c32r7w8D;c2Ay0;a1fBFl370D;a4737oA6;a4CE4y5C;fE1;!aE8o29;aE8o29;l63m2AD;d185;m25Fn1;a4EBAe61i1E;a1927;!a8CEd98e4E41l7m1Ap1As33D;hA19;!o10s4780z19;!b1Cd3Ci1Ds0;!e3AC7i428Cs0y37C5;t4C61;e35i2A7Fy0;p4319;kC76;!aE08e3D4i5Co1FA5s0uC27;d0e1r2Ft20;!a3Cr754s0;!b367d7Ce4CEDi66l365m2Es3E01y0;a289Bi351Eo35;a1u1D;a230;!a309Bl76s0;!l0s0t18;eDl3;eF7l3;a24Et7;e1Bn4;e37BE;l38AnFo1AA;e5l3;e1l3;a10h18C3m76s3E87t494A;!a660cD3g26BDi69s0w390x9DA;a1Dc423e24k38l120m63s3B2AtCE9;!a4535g3604h172Ai4A24lAB4o3B01s0;c13E9pFEFx1F;d0e10r1s0;eDk3n2;e4i4335y0;!s0t1B1C;rA15;n3EA7;dB4D;f8E7z3F4;e8Cn2;e67o579;e12l48;dFBl47;!l3573s0;a88h4D6Di1A10k46FEl3936o503Cr2259u4957;h5At27;i152l44y0;!a1DAb112e3BEBfBFi1BDFo18E2s0tABy1F45;c3Ce1Bl7n2506;!d0r1s868w253y2093;!nAs807x0;e1B23r5EE;d0n20Cr154;c15E5;!a77Cr3Cs0uD3;a782c0s261A;!dABlF2o3Cp8Bs0;!a12DBb3Ae4g422h6Ci95Dj6Cl195m2En3Ds0t342;l6A2;d0l1r373A;gBl1rBu8Cv3C;!b4E80d0f27Ag3l7n22r0s2270;t4B01;b1D5Ac3951d3BFBe1gB0Fi28C5k2Cl50F0m2D88n2DBCp376Bs219t4A11v1115w1y47;o127;e5s282t3z19;!o2;!eC0iADl7o1s0;k518;d16e470i3ED0k47n78p216E;i46DBo74;o460C;g1m438B;!a88i146Ao2A5Bs0u50B;cB73r3DF7;e3B36i3648;t2CE7;aEC0;u2CB;!u2CB;e53;!cB2h2Cs0t54F;e1iBA1;!i8El2Cs0y0;aCe1g0;a1B8;!e1iB9nF6s0z1077;!e3207l514Fo35E7p2B34s217t4E0Cw255y0;r3CC5;!i331l222s0;!c171s0;!e5n7s0;!eA83s0;!e5l19;b648e1884m2FEp238Au4E;!e15i86s0y0;a7Fe1F44i190y0;!dDABg1C0El22m1D4s0wBF;!aA35d0e5FBf87l22pB76s4AEByB;!a1FFDi77s0;b12DdA7eB3l7n146s3DE;d0s57;eEAl7n2t7;e33oDt1;!a7Fp162r1s0;gC2n2s35;!a2642b42C0c3A20dBCCg17A4l146FnDFBo3E0Ep1185qC2s356Cw34F;a283l2DE;d194r0;!d0lA7m63n8o1s0;a46D4h26A7i2By0;u117;!o34;b5Cd0l2AFn28s39F3;c93s10B2;r10u2B1;d1C7;!a3C6Fe4i6s0u1D37;c438;a4Bd1f7;s1BBu5;a4509d270Fe3F18mD3En4029o3477p2CB9s46AAt4DF4uA00v1FEEw28F8;aAFlC;n2t56D;n337t10A;d4E4n2;a96e356i6Fo47B;t544;eEi471A;!a3E6Et0;i5AF;m1r25;a1Dc2DD1d87n136FtB;r60t2D;g3E61l192m145Bn93p1r1C22sA33v1347;!e4i6s460;!e455i44F9l22sF0;!f28s0t102;e3F0Di1DF7;n16A2;!d0s0t48D;e3Fq34AC;a61Br40F9;a20e41D;f3B19t1;d0n6C;a7e10;e5FF;d1k0;!h16Co6F;!t19;!c20B0fE7ChAD1l210n0p47r442Bs3775t38FEv2B;tE50;e1E4oDDu2FF;!t5A3;f108l1A;!c1D34d143Eg43CBi4003n348s256Dt3D71;a4De24g62n1r62t48A6;b39;e30k16;!a1C6De4476oD4s0;!aA4e4i21p17CAs0y0;!i8;d3C1l3As2D;u16;!e506Ch2Ci8Fs0;i90y507D;d437iE6m35A1p2496t2DzBBB;m3vB4;!a44Ae12f37i66l22s0y0;a36e1i479Do125A;r2F7E;!b3EB9d3283i6l5D7r1s0t4A0Dz2C;l62r2B3;aA54e4DA0;!a4E94eCFi21s0;cBD5e1;tFBE;c3617h129k28o487s5D;t993;gA3;a0g1i13u14;i353B;d0r1t64By1;d3An191t137;!a3DD5e2320i345Fm17En3F29o1D01y48C0;a1D48e4D17rDECu40BF;d0n577r1s0z2C;e33i8;a409Fe387i6o52A;i4BC9;a4Ce1;a2C2Ce34Bi4184u14;pECr9;!a419Ad226e15i21l49Bn0s0;r39u12;r760;n2o414r36B7s385;eE15yC6;e17o98;!b4EBe3DEBgD3Bh2F7i2Bl24DAm2Er184s0y477D;a2AEo8;y96;!d0s274;lCB;i31yC4;g5Bi4m1A;c170t0;a8Ce36C8i2B1l1Dn8p8;e23i32D4;i1465;!d0r5104s95B;c1CA;!d0r2C48s0;!e5l31Fr151;a140hFE9;a4D35b327Fc320Fd1412e395Ff1B4Cg22AEh12i2A1Bk1BBDm3842n231Fo4E62p4F41r443Cs13E4t4793u1C40v4CEBw47FAx3038y1z3DB3;n46s473A;i20m0t1;z12C;aAFsE;h1rD8;tD81;l1ABD;!a71s0;e51Bi1E1y0;!e12i1FA;!h3EBAtF8;t3BB9;!i9l1n0s0;n3Ar1;n1r3A;!lC36m17Ao1AAs337Ft3995y9A;e0i13o46;e4t1E;!a4Be2F2iADo12r7s0y0;r195y30E;l4BDC;oCs0;!oCs0;e12i3Bl19;!e6Do1F9;u12B9;!eC0i472El7n22s0wA7y4B74;r7s0;!eC0i24F3l7s0;!h4F5DsDBt1A1y2CC5;!d0l22s3584;!m175s0;a1oC6rAA;a4Do29t2317;d0r0s8t2F;!aEE8e4064h3BF5i52Dk5Dl22o106Dp36CEr35s0;n481As3FB4u39AD;t3y1;a8e9y0;e166i8;e12iAC8;nAFp8;l453s4555;aCn2s155u14z3;!e3i1s0;a12uAF;i3C4;a9sFEz3;tACB;d41e1Bl7n2;b43AEc198Bg48CBi11DEk3BF0m2406n37E8p3546r170s2517t239Au4EC6v37E1w4668x48B5y47;eAhB37i6;c6A1e1CE;a4De1C6CiCBAl3245o4CB1r325AuCAF;!e224iBl7o0;e153i1689y0;!b1ABe15i6s0y0;!e3395i254p836s0;e34o4BA5;m2082o6E1s0;n2708;mE5;m9;b37D4c339d1775i373l3C9Fm40E6n118r4F98s302t2FCBw2A39;aCeAoD;dE12;!e5i1j97B;!a7Fc158e4f570hA3i5CBl112m2Es0y0;a10e3BA2;e12u2F3;c31Ci38C1l5030n129Fp261r4E17s2B2At1CD;n16r7;!o59s0;!e0n25r78t545;s1DEt4Fz3;c19Ft18;i4o20B;n3CE3;a59e721o54;hEn3A;l5En19s1EAu59;l3D0Er495D;c11dB5g15B6nBC7r40FDs2FFDt42B2u1v2B;e8t1;p340;a4AoAF;i108;iE41o417u5;i2264l44u573y1870;e2DmCA;!aB2Ee4i6s0;h9Fo54uE;a54i8Eo6y0;!l19uA0;k1876l58m1016n451Dq16C0r2862s193D;t22F6;!e6A5h1jBp2BF0;!s0tC8;nE0By0;eBl2C;!e15Di6l1BFs0;fD6u0;!a137e4i17FFs0;o32E3;l1A3;dBtB6;e1o100;!e4f37i6l22s0y0;!eCh33F5m31Ft2E74;a31o31;!e100o149D;d1l1D;!c44EAeD0Dh2544i2310kBr29B6s0t3956;e1o4CFCrAA;o9F7;!a12;a10o3EAu10;h2BE;!b1ChBm2E61s0;a157AeF6Bi2C66o21A1y2BC8;!a52e23i66l22m7AoE7s0u1y0;e1BA4i1827;a244;d0r0s1C1;d0e10r218;l4A1n0;c0s2Cu14z44;e201iDEEo1;r135;e0o6F;n9C6t1;a2EFe12o1AD;r3E5Fv62x128;a1cB2l276C;n1E87;lB38o87D;h4D3D;dBn0;e1o1Ct1;!e15i1B3s0;a4A7De4F47h3B0i45A6o28C1r1D17u35B7y16DA;a2BCdB5o6Er3Du9A3v7Aw9;a30i1866;a325Be104i3F2Fl170y0;a3C1Cb1C71c4369d326Ae31CEf2BC3g1D0Ah1144k3844l4FEEm243EnD45o35ACp19C8r351Bs2E28t4B5Au43C1v4482w8Bx222z2F3C;hEEDn3;nErEt96B;a23F0bFDc40A9d118e181BfD9Cg86Ci2C07k5073l3B13m1C68n17D6p4413r11B7tDFEv2FE6;n3987;!e1i18s0;a3E9e3FBy17E;eC0i6;z9A;!e2C5BiCCs0y0;!e24i285s0;k47F4o3152u373B;a4A72d3Ae1Bn2u14;!e2AEF;!eCFi21s0;!d0rE0s0y1;f45E9;!o1p3DC9s1C9u1;!s0w16;i2010;a375;a3AFe5036iBAo4A33;a30eAiCCy0;a71e1Do5FB;n1F6t1;!l5Ay0;a30d0r0s8;n3s106;r475F;e5B6iB20;e67n2s11;!i38A3s0;i164;a46EDe85Ff392Dr157B;!f183p49Bs0tACD;a2FCE;i47A;g3642;m4DE;c156;e1i47EEo57y64;!e4i285s0;a2AA9e852uB6B;!a73Ag3Ci132o1s0;a69e12A;r27F9;e4A;!i4AFs0y64;a0h3E2DiFDDu12A;m7Ct47;k8A1;c0dBn3s2C8Az2C;eCFi6y0;l1p4C8u14F5;!cB13e23g47F0iBCn24As0y611;a46AFe15ClB;d16t942;!b1Cj6Cm1Es0;l4C42s13Ct36C6;!e1s0t21A6;eEs11;b5BAgBl4FD2m3589p2B72tBzA16;a125l1C7s0;!e87Ff37iDFs0y0;l29Fn1;!eA5Di4EB6o83FwEDy0;l136;!a782e1DfB5i30AFm1B1Eo362Cs50C5;eAm164;e5iC8;c38DDi1Ck2BF9n27C1oD9Bp44D8q1950s2AF2t1F14u3225;!aA27c3684e21A2h28A4k13AFl2FAq123r2600s0;!aB7Be4061i6s0;e17B6o12BA;e1n289;a25BCcBl2AA8n2o29s12DC;!a92e193Ei69l46p4CtEB;a115C;!e0h4EC3i0s0;!aCe13Ai13s0;iF8;o135E;o537;e2E67h3FEo4A69;n3004;!a1EFe1r1s0;d0o10;g545;!g19;!aCe12s0;c626h4B77k0t38AD;!n118s0;!n1ACr42Ds0;!i233o349Cs0u5;l28n507s87;e114iB4o40;r4106s3uF45;!a33Fs0t1uE;a22F3;!a30e4i6s0;d2Ci2934n40B1p270Es22E;t4CF1;!aCe44E5i4E1Do1;e30i4oDu168;a321e61i2Bo46y0;a9m3w1;a1s11;t2Cy0;!e15i2AAFo2E6Ds0u6FAw9A;g0i45B0;a136Ce196Ag22E7h3D60i3265o2139t11u1B1Dy2F36;c45D4g42CFi3C0Ak130At2AD;a9c0s8;e32CCi72o134u2;!e4122s0;e16F;f682t1E;!pB;!e82i23Do12r22s0;d41A1;d26Ci3B72;r8FE;a26DAb13BDgFi49m47CAn4C1o3EB4p1r3366s356At2B0Eu221v44w1BF4x308Az5F0;a117;a4E;c4CBCd232Ei2055n1554r10FBs4408u511B;a130Eh3B9Ai0k4EC8o3023u4B16;e15i34Dy0;oE7r19B;!a1898c11C0d3B3Ae1f2536g3C35i56k1A9l67Fn1652o10s0t391Dw130z210;e15i6o19D;a1D83b2E3De383Di4457lFDo4FC6u3D81y4BA8;a17d0o10r245t16y1;!e41BFi6pDD5s0;e1Do1;l4522n377Dt4379;!c2Cd1eE;!d0r5F4s0w80y1;h167A;o28r2356u111B;!a37FBe4i586s0;p7r1s5;!e15iDFo12s0;!r8As0;u15CF;f31Bi5D6k44r33B6s1Ft1DE9;o53u360C;g3r14;i13Au7;a3660c2E97d4A1Ce4EF8f3480i4F8Dk26A4l2CB6m4749o175Cp4AE9qA07t2112u40CDv2283x1Fy255Ez4E58;e90t2756v28C4;c1sFEt3z3;d0m1;g28CC;eAoA2;a2AAe6Bo2227;!c1E6e4iBj6Al7s0y0;u94;p7C9;!p4E;dBs0;!e405i6s0t28;u6AF;s302t34EAy28;!g4E5Ci6s4B4A;!a29D1b4A42c500Cd334Be458Df28E1g18E9h4FF1i21j1DBFl47A6m288Bn42ACp1883r1A2Es3F9Ft1852v4790w28C9;o427;d28s5B5t4645;!o10tAA;!b1F3c1E4e82i6l22s0;e23B9;i26A;n2297rB98;e27CiDFo12;g316Fn28s2Cz2C;e1i88o29;!a4EAAe4i6s0;r3900;g38D4;n32F3;eAi6s3At39;i16F;a59y0;l2DA2nDB;n30FC;c13Bn3081t340;e84i12A2l44o630;lA8n58;c84l4E14r4A6A;s1AB;!a48DCcF6De1Df53Ch471Fo31r219Fs0t32F7u7F0;!b3FCDd0f27D5h424m2Ep21Ar1s0;!l24Bs0;fFCC;a4626o51;a4Ai56;i4F8E;a20oE;iE6r3;g3847l2C14;!a4De12i47DCs0y64;b49ADp5056;!w27;lF7A;c0e67l6A;e1r0;u5C4;a1eEi2By0;d1E2gBr156t1FD;a2D6e1;aDEc5EB;!e0l1r7s0t3;!b4CBeAC2i3415l7n22s0uB7;aFE5c84i228l1B61m4Dn161r399t29EA;t467z38;!e26iADs0y0;e4478i61k4A73s56t0u49;aAFDs0;aE9e1Dl19u1AFF;!g4339;!h1Ei18m2Ey0;c801u8E5;f302F;a20i5DCo29;h1BD2;a20oB32;!e15i6l19s0;!iB4n39D9r1Es0;k44FAo5C;g2CoE6;o576;!e4i6l0s0;!e32Ai8Eo9Es0y0;i33F;n3B67s4508t2A3Ex2D8B;c11r1D;e5CC;!a4Be15h2D8i190o3FC2s0y0;!e0fC3h9Bl83Dm2Ep2E2s0w121;c393d437l83n70t186;c0e1Bn22B2;e3C7F;a3012;!e5k4C;a20i1879oE7u5;s2556;a0t0;!eC0i85CoD5s0y0;a1eAE8lCt1wA9;a1b49B8d4FA9g349Dk2330l4566m3FF4n0r2390sA33t4F08z5C;e79l7n2t0;!d0n35C2r469Bs0t370By1;o7AC;i6FuC5;!e4i18Dl22s0y0;!a105i3Bs0;a8uC;e514i33A0o5D5u2FF;e5w20E;!a18ABc3E29d1B03e3964f3C48g2F17hC5Ci25AAj1039k2137l48Em48EAn1393o31BAp31DBr1504s1F57t187Eu3DDFv2189;a20e1D;r4s5;e3C79i6o3F48z2A53;a7Ei0u5;h1i4619t2221;a32B8e4462iAD0o3EA2u10CF;!i3l20Eo49t381;a36o2CA5p1Ay6C3;!e153i43s0y0;!i35o12s0;l1D8n2469;p362;!l126tA7;r36t0;iFAB;a792i14u14;h20ADk4AC3pFBt822;!l4m2B3n1Er9w9A;t618;d4D37g4AF3m3E40t1120;e5EC;d47t35FA;m36Dt4A;e1y6D9;!d0fC3l2FAn1F1r2A64s0;!d2EF9e23iA52m4391s53By0;!a1h1As0;!k1l61nBo1DrD8s0;!d5Be33i21;i276A;!a4De3F7Di1259s0y0;a77C;d0s0t27u6AF;o10u59;z17E;r1A08;!a1h38l2963n22s919t206D;i96E;o3F90;n8s8;i25El623;!d0n16s0;a56Ee1D78g29i19C5l4226o391Fs2Cu33E9v26D3;u25FF;e1gABCn120uE;a7Fe257Bi21y0;h1725i742;!lC8s0;a0c0n30A;rE4;n62E;!c17D1e3127i21l22m1D0o3667s78t3918uDE8;!e5i61;!d0n65r1s0;dBr7CA;e5f48A8;b9Ap85;l62oE;f3lC;o2230;kB7nB;c0g18;i13y1;e2ACDi168o334;h1n1201;d0s8;a0e45Di4E;a20i73y0;!i1DoEs0;c21E5g1CC8i4B91n595p1BE8q826;r25CuE;!a6CEe2765f4E4Ci126Dl1D94o4ADDr1451s0t0u41E6;!aDs0t163;l4182;r5BC;r494;y2B5;a70o46;lA5;l776u31F0;!d0l1;e8F0i6;mFCr2852s219t1796w2280;!eCFi66s0wEDy0;e1u34;n1257;l47y0;a1357e6BiCCo2A5u3By0;!y18;j1As4CDE;a12r1;!c7iBE5s0;lA91;c1D1kE55m4A49;e15iBCl2Cy0;a13e5s8;h4C0B;c19d0r1;!l1960s0;a40E;a48D3e0i2BB;eAi6n6C;g5Bm5098t46F0;d0l1D8n1r1;l8BmFC6p6A0r5079s151A;n0y0;a1C48e3109i140o22E9r623u28A1;a520eAiFC2t27B6;d469E;l1n8r7t10A;a120Ae18Ci34u42F1;!d3552e24n1468s4BF9;k1CBl4BF6r38E;cD9;mB7n10D9o45uBA;f16l18E5n2019s1661t1A01v306Dw459;a1CCg0;n4C31;a414Eb4624e117C;o17;!e2E7Ai0l7o0s0;!a3FFEc487Dd1817e4CC4g2985hA7iD7Fk3A2En2B6o1AC1s35AEt128Dy0;a159AeB;s19t1A09;i27l56Ar7;b374F;c93n52;gA90n28FDr1511;!cB2s0t4583w240;!k0l2F2Fm28n1rDBt1772;r4F49;a53o19Dp9A8;a4Be3AD5o718u18E4;!d0e6Em63n118rFDBs0;a479Fe3CEBi159CkDDEr3u253B;h25A;r1F;!d0lB1;!e4i3AAs0;i1Dn25t4590;e28FBo54;g19l1r245;c2A30fCD2g2984i32EBn34DFp30Fq123s1E89t256Fu1BA0y4E96z1A;a7Fe2A14;o9FC;bCBs1F;!l12FFn0;a2FCDb1E9Bc1162d37D2e2726f3B1Cg1727h2654i3E92k38CDl21A5m23A9n1846o2316p165Dr2CDEsCB0t33C1u3AFBv3DAEw4B64x2A59y3E52z4665;!a20e1B2g0i6s0y0;!a725e2D5i974s0;i65t48;h1Fu2965;a429Ae15i21y0;nD2;!n4FB;!aCe1i13s0;d0n1r1t16y0;mA3;aCo29u3D;a174e67f37l22;!e0s0t1w1;!a7Fc9CeAi5080k111Dn4591s0t5;!y31;lCs11;s14t3;!l144r28s0;n707;o10uABD;c13ChF5;a3467e57o9Dr9F;!c35A2gBk0nBs0tBx0z35;u37C;a20o46u5;m61n4A63r8s13B;!a7Fe4i6l22sF0w390y0;a16D2;n36r1D42s9C;a34e34;!e24i2B27;e1m47DEp28;!r23CAs217t1050v1A;i2By552;i10D6u5;p2520;!e2F2i6s0;!e7EDi6s0;aCe1tDCuA0;a4CC5e4906h1EF5i1698l4872n2153o3374r3933s9Bu1CB2v3755w2150y3CE8;t2159;!e1i7D;d1Cg1;e15i27lF4y0;lE6;!e1z37A0;e12l44;l385F;!e23i6s0t197;t3654;!a4Dd0r1s0;a6Di647;!e15i43l19s0y0;!e15i6o29s0y0;!e3DA0i6y0;a32C6c73Cd575e3AD6i1C6FmD1Bn43F9q826rBs4446tE3E;!e15i6oD5s0;a0n52s14;k39t0;a2524r42B;c128e1Bl5C8n19AA;n1E76z241D;a4Be15i6l19;a45B9e3B5i60;f9C7r8D;a0e0i0;c1n2t3u14;n9BC;a13c1AD2;a84c1BE3n8AArD0E;d0i6s0;a1F7CmCDo27D9s918u1Aw1Az476E;l2FB;!e48E7i86l7m2E;a1C85o29D2;e4o6B;a31C4e17iA09o1y0;aCe5h259i1AB1k2769uF0F;h5F;i6A;m45F0;e15DiC9o1F5y0;a34iBy0;t1w10;!a1Dc18e1hB6Ek1C53s0;!i4A27t3629y0;d3t19C;d1l4p79E;d2FBBe24;e4s11;r14y0;!e638fB5l496n22;g2Cs2Cv3;c8C3l27B4m83p2D4Ar42F2s15Bw1B4;!a77De4i66lBs0y0;a30n85;n2rE6;!dB1Fn82Ar901s0;e23i17F;e3B2B;r278;!r119s0;a379Fe0t129;r4ABA;!c7h3Ck46BBo1s0t280;!a65s0;a65e1E;e5E;e5A;f84r2FD;c0dBn1s14t14Eu14;!e15i21o1CAs0uBA;!a20e17i130Cs0y0;!a375e2A4i1431o1F60s0;c31Cd3CBk585mF96n14CBs147t0v741;!o20;!b0cE1d4090k458l339Dm3A40n1Ar125Ds0;t17F8;n249B;!d1EgF4s0;!a2FBeB99i38Fo326s0;!e82i66l44s0y0;n16o9;l401E;!e104i43l48s0y0;a1t38;!d8Ae10Bi86s0;r584;a15D1b1c2025d945e45g16B9i2BE6k44l493Am4395n20EFo50C1p2E44r384Bs5t4104u1A61v183Aw2602;n2629r21DA;d3n1A5;i1962;n0sC7;!e4i8k4Cs0;c19iEy1E;!e15i5C0s0y0;a2A7Ee2610iC32oCC5r1C5;!n0s0t32D3;!a2704d17E7e3FB8i44E4lFFCo4A35s0t49BCu10DEz1A;!e10Bf37i6l7o29s0;t7y0;h2A58;a10h386Fo10;eAi6t5A6;d4A01s142;a859c364Dh4B12k3C9Co4341t46B3;eECi6;c30DAe2B9g2A6i86m146Bo10t1D64;c11d0;!e1h1154i3Ds0t11CBu75E;p12Bt1B6;a4DeC8Ai3AEFy0;i38D;aAB5y0;!a173Ce3EE5g76i1A26oA9As0u5;eEEh1AE1;!a4CE6cB2e5h2EE8i3EA6r3F49s0t3563uE69;a336Cd18Ei0l306Bt28u295;a3142e17;s3Cu5;a13CBi4B94l2804o3BA6r226;!a10d417Et4FB;s50A6z19;e144A;a75i5140u14;s50EE;a30e30;aCb1902c17CFd2D45e3DF3f10ADg45A0h2038i1488j1FkE6Bl4D23m4B93nC22o1p2DCEr1CB8s1B59t3A16u4C90v4EB3w500Ax474EyF7Cz32FD;eAi2233k1Ap417Du66B;a1BC7;rC78;!aECDe4i6l44o1699s0u49;!f37l22s0t16BC;l19Et3F6;a3B4Ee1376i915w19E;!b3DDi6n22;h19Fi7DlC65s58;c1ArB;e0g3C9;a59i94;e23h114i66uDy0;e23i21p4ECE;a1FB3eBA8i3F10;!e27FDi6m2Es0;aA84h3BAl6A2r297;d27tB;m9A8p37E6;!a4D36c3476d1e208g44i46BFk10DFl14C9m1F6n4A85oB62pF7Fq7CCr144s0t40C9y0;d39s3t5F;dF2;!e2D08i172o48Bu2A0;!p11;e385i9;l2E8Dp47F1r236F;g0t16;!g1i1As0;e15Al7nF;!a0d131i1859o9s0u14z1A;b9FD;rE9;cCC3lBn1t1D3;t173u1D;!d0f1E3i6l2809s0;!b363d0r145s0t1y0;!o12s0;!a0i0o0s0;!dA7;e0m1Ao3DCB;d0e0k0n0;!e4i163s0;g3B62v3867;!e5A2;h49CC;a2A4Ae48EFi21D4l19F3m4CD;o8r9;b11FDc2A6Dd4270g63h4A17qABFr20DDt13Eu168;a1229e2C9Ei3304o2B6Ep0y3384;l0t83;d0n294o29r5F;i5A7;e0i31;g3l266r7;a0e30;i1C5o4ABEy0;t4607;t3A26;!b198Dd1A8FfE29g2A6AhDDk3904l3350n79Dp3966r33CDs11F2t2459w47A5;!a2E22b7dD1i9n22o3BFEs58tA30u3708w31F;i0lA8n332s0t44C;!b4459d197Bm43C7p250s4997;!a1129d1A4Be1EB3i6o10s0;n1s9C;!a35B2d3890e0g4FF8i4809l2962m4C91n22;c40C0;t1u32;x3E;r4DDF;a12e0iBA8t29u302D;!s27E1;!a1A07b42CcB2Fg4375l1669m354Fn3564p28F1s1FD3t1CF4;cEd0;iA4oDD;!a174d0l1r1s0;pEv1EA;a556e9;d1p1t16;i58Bo284Au39D6;!cDDd0m1279n15Br1sA46y4BF;i6n6FB;e4EDFi30F6y0;aE8e14Bg0iB31o9E;!b1F3d0l7n39r0s3E;!b380Cc1D0r5Es0;!e15iBCl87s0y0;o201F;a1F1Fe0o35DF;!a6Be3;!a77Fb112e4i21lF80s0tDBwDB1;!f4C7l112p5A4s789;a1EBu46C;a75i13o9;nFt2CvB;d109;s125;l151;!e1298i21l112m162s0w9A;!e4i6l28s1F;!a57e1C91i66s0y0;e288iF9;i37B;!i1At0;a1127eF68i28B3o4D3Eu173A;a0e239Cs3BD4u34x68;t64C;aDeDr7s0;t582;l29o2D9;!i4F4s0;e4C5Di3AEBoF4D;a670i1F39;u2182;!e15i6j238lF4nA1pA5s0u57;!fC3p7As217t102;i4D5E;c0s11;!c11s0;a48BeEi142;!hFA8o2CCEs0;d0l47s0;a1D8By0;aBAy0;t215;l2BEm5D3;a9c0n2t7;!e4i1DE7r35s0;i1At10F;a2128c87e2CF5i21p1A9r492s3D9Cu2BF8;l4C4A;c4132h1B3Ck1152tBD;c13Bd151t2D59;a466De35F2i2187u14;e373Cl2C;e50D5;!eFE0i66y0;a1422d4Bt19x1F;a2D24b1D71c25D9d345e85Ff18E1g480Bi58Bl3B9m50F5n80Bp2447rD54t1983v362A;a1eEm76w1D7;a72lE3;!lEEn2s0;!e15i34Ds3C42y0;c0d0e0;b7Bg3;l32BCo4CDArCuE;u3FF3;d0e60;!eAECiCCl2Co404Br22s0yF0;g410D;t1Av1A;sFA;e3y0;!a873i5AEo1D2Cs0;l7r78t19A;!a365Cd129e326Bg3874i6j56kF6n2F49o12s496AuEzA1;aCe1i33E2u48D4;!a70Fe4B46i8Eo9A9s0u3E17y0;h21Et3588;e15i43lB85;!b88Ac560s1A0;e2D14i6;o3DF;!a1A25e15i24EBo4ED8s0;iF9A;a0e17oE;!e1Bi3Fl7n22;!e40i3Bo1s0;e16ABi4229l2Bo2EE1r446A;u4F5AwAF;!aD2Ac13Ce6ABi3B5s0t2569u14;a1e3Ei0;a264Be389Fi3960o18BBu32A2y1F46;g71Cm4C77nEp4A79s354Ct1891;a1g1A9;!a40i13o29s0;!e1nF;e356Dh5D;o85;h695;e1Bt7;a960c154e45ACg21F8n2Cq123s9Ct0v31A2;s5Eu5;a36A4e49B1i4AC1o19B8;a4563e18A5i473Dl2CFEo335Dr1ACFu2916y735;!dCAp35;u261;r3D52;a246Cg6E3i3EC2o3D0s841y64;e3610;e3264y244;u69F;m375Ct4AB;i2Bl35FFy0;e5i5t1;r50s1F;c93qC2;m113p1s9Ct1;a358D;!a48EEeC0i6l216n22s0uB;!h121o9Er1A80;e14Ci6o1;e0i4955mD24;a183Dc50Be3957i9E0l4B37nE75tA0Dw99Bx2FA1;!g514Bh424k449Fn5072s451B;eDi13y0;a30iC50o10;!e4i95Es0;o17E8u5;!l7n22;eAAo94;!e4i86l5F8s0y0;!e0l1;e0l1;e1l18;i21B1o3E1Cr22uD49;a94e12;i489;e36C;!bFBl3B1m1BA7p113s0;e5f27lA0;mBn0;aB18u69;aD4h1;!t112;e235l7n2841;!a4FCAe3C10i4CF5l4614o49r45DCy0;k1CFl0n28r2224;d345;n50FB;e0u5;e0u1;b1014;c84gBt3;d19s8v19;!a40eB49h1A5i12C2s0;b1CD2e1p3AF9tBDB;d35i25;r1AB;u433E;c230Ae34A8i1492lCE4m4180o4EA3p4F59t16F5v139E;!a4840bB0c461eF7f38h2145i4B07l471Bm4DD2o4E7r4323s0t1578u4951;e16A3;s1FtBv3;r9CD;aCt3D;a1799f7nFo29;l40E4n5142p1FFs13CvBw3653;a1De3832m1;!a4914e212Fo2F4Bs0u6;bF8A;r392;d0n8uD;l3805;!e3E74f1i254k1EB4l2A21m4CE7n3003p274AsD59t5AC;!tA51;e4715i285;m38nB;!s0t2552;n2s14t0;s8t3v3;!e15i17Fs0;a40e18D1i31;!a7;x54E;e6EiB;c1n3;!a4485e4f1E3i6l22o5D5p16Cs0;!h10C;e3352i6u49;!e3A4ChDD7i4CC6m2C8Fs2D31t3000y0;a2793b1D4Fc3A2Dd2927e3986f47B9g4E67j3B24k3C21l1C70m508Fn42E2o2930p3A1Er3160sD65t27E0v3A45y427Fz2AA7;!e4i1B3o0s0;!a4F02c2B10e8Fo4519s0t5C;a132r37B;a9CF;e12Ei41CDo10;b2990i387l439Fp27B1q4A6Fs0w637;b0s0;!b0s0;eC13i1570;e1o10r1s5;eBg62n5E;f3AB;e17uD0;a2D6i2By0;c22D;!e5s3;!b40D3dA5h34l6E7n1s0;n2s4D6;o2603;b1AC;!a1l2Cs0;e20Fi665y0;c309Ag35Fp4D74r23B5v4777w89;g44m30D5n110r1E5Es15BvD71;nErAC;!a5As0u1;!e4B6Ah3B10i35CEl1275mE1o154Bs38t4A5Bz1A;l1AEB;r4C12t16F;l7Ct1;!a1b387Ec4477d4059e1B69f44C9g3804h1A58j955k44l401Dm4C89n13C4o25C9p13F1r3D07s22F8t4153u4946v2DF7wD30x2CA7;n0s1DEz3;!i42A;!iE;i42A;!g27p471r28s17AD;m2E1t70;r25s11;zA3;i1Do1A;!i290o10s0;!a2001e10BiDA3l7n22s0t11y0;eAi6l16;e24nFo10s1F;a30E;a2CFBe3A4AnFs1373t46AD;i11B;i1F;t1u5C;!d58s0;!e23i21s0;aDEe2032i4Eo5E;iACF;!l238;d26Cm6F7n1s7D2tD2;!e24gA3i6F8n0s0;a373Dc62e49B2i41F9k2B6o46;rE6;e178i1BEBy0;a299n2r1;m70n2D;!k1Es0;!a44C7e455i26B5o1A9Fs0y0;p4F5;!p4F5;!kE0m2Es0;h1968;d0n0r8Ds0;!a9e37C0i17Fl7n22s0t11;s4ECA;h273;!a15C8e23i21o10;k3t52;r4FE7;r138F;m4D25;u28w28;e1f108n2;h3B99kA97;!a3A87c132Ce2CC4f41B4g925h3201i2570l2C79o94r3A54s0t4FDCu18D6w390y0z30D1;c1Ed1Ez1E;!k7;l0r25;!l9C2m55s0t1;i4o46;d0r4347;t3F47;!e12i8Es0y0;c8i9F8;!e0r3As0;!e12s0y0;!e24i7D8lB;b27B0mE9s1;!t1x867;lE6r2FD;!e0n9E4s0t19;iFF;a232Fb3273c6F1e4C62gAA8h10F3i14D9l2C53o1FBFt3BB4y2813;!a444Bc14BCg2F92i256Ak100El1BD1m46ABn2C7AoD2Cs11Bt3FAAu3C1Dw2A86;g5Bs4FF5t2D;!d1F4l1675n2701pD6s47A8z3F3C;!e23i21pD98s0y0;!l19m1n19r1s0;!a3AE7e1A63i6l63s0;g4F;a51e51Bi6lBy0;cB2d405Bf136m2B8n38AEt2AB5v2C;r4DF;!c1CoE7s0;lEFFr25;l1B1;u14A3;u1A45;r2Fs0;!a12l3FE2o25;a4De6CDr1DA0s1B7t3Dz9A;e73E;i4r46t16u20;!d658e41Di6o12s0;n4467s0;!aCc119d0i9n428o331Fr1s0t119;a1f499;f7s65u12;a42Ae5105u3;g843s42CCu5;bCDDc26F0d47B2e3AE5f26CAgFAFh3AABi4DE0j4BEk3A2Bl131Em5018n5095p2D52rD80s1FE3tDDBu1933v2372wFF8x1D98yF8EzF24;!e153i21l4EA6s0;a118Cc1FEAh129r102Dt308B;h39Ek26F1o2A4E;e482B;b106r7AEs3D00;eAi38Fo33Eu5;e1l505C;d2684h14ABl136z4169;l32r25s11t60;c163e5o9s155z3;i98D;aD3De15DiC98;c52t1;i0n29Cs0;!b2A1e12m82Dp3C57s0;l44o71;!b4BC6l22n27A0s503A;a136De4CFo1;s54E;!b4A05e23i6s0;!c4Fe1B2i6s0t3A;n4210;e17AAi3325;i39C0y0;a178oB;a51e1;e3766o6ECrF2;i8Fy0;e50D;b7Bd3AfCA;!b1395f363Fh10Cl50F4mABs0;!d80i6s0;r1401;!e5i11Bl121o3215u1;!e42o40s0w14F;e1355;!b3D9e15i21l4816r2F7As460uBwA7;u59y3D;e1B5;d42E9g309Dl69Bn332t197A;bA1d19r1A;o14w0;a0e9;a9e0;i1C45y0;c11iE;a4F55m33An1EC4s147t200;d404;a26B;!aA5Ec892o4C0;!d8Ae87Fi2EBk4Cl1Er7s0t40;l0r0t3;!d2583e4i6s0;s19t3z19;c10C3x1F;b881;o14u8;c95e12n2o10s11;!e13AoCs0;r38DE;!e4f4C1i6s0t303C;!f37l7;e15i21l2C;h1686;d2E38m4B4r3329x0;e264o4F53r13E;!a7eAi21s0;o5B;e4l8;a44BEe501EiA23oAC;e1n11Es11;!e4h344i6l5F8s0;a25l11B5;a1865e10;g1s1Ft457z1F;!c33Cs0t173E;!f37n84r1sF0;fCAnF;!e42B9i6s0;!a1512e5m4D2B;a1c11e1i2E5;aCe24;!aCe24;k1F8y0;!aDA6b101e10Bi86n22s0y0;b1Cl2432nEt505;r144;r8F1;k511Dl1A;d0n2E8;r7D9;m18r0;i2FDCy0;a6F4;a20i905;i222E;r2380;a88eAi6;d1t3;i2134s113C;e596n2;!lDC6s0;d0r1s5F1;c27CEd119e24fF5n3o29;e7A6i66y0;!a7De1g61n123Do46t5E;e1Bg145n2t1FD;i45B6;m10n36r1;e4F6i6t13D;!r8F1s0;o1A6;o2764;c1F7Ed4FCDe1g378Di126Ek2B8q49AFr2940t2EFDw33F4y0;l18E0;a4E02;t84E;!c77eEh3E85i2C21;e30iAC;n45D5;a4CA;n4B5;d491Cl292s0t2332;!d0n0r1AE8;!a1E88e2C23oD93;d0t22F;eAi2966;!n2s437DtBz19;!lCF0;!g3k12E1;b4E4Ac1D6Ad1131eA2Eg4ED2i4A68kBl24E2m4B3Cn366Fp4C52r42EAs205Ct41CBu1DABv3399wFF0yD13z3710;a25E8r158;!e293Ci6;!e17i290l1Er7s0;!aCe44F5k5Ds1E84t1CE7;s21D;e1i2E5o2A83;p46;e208i6y0;b1Ag62m87r8;g1m27n4A5;!e4i1551s0;u12E;a1208eC0i3998o9A7y0;!a1Di13s0;i36o81;o1024;nA6Ar24D;r4A50;a1b1721d0e477Ei21l2B15s36F6t4630u154E;e1088i2475;!eF81;t132A;g145;h30AE;e1137h1415i44Fk136o4A1Bt1B7;u6EE;c18A8e4999hF3k37D7oA8B;r5Fs8;!a3A6dB5e15g62i6m2Es0;e127;a4AA6o3727u4EF9;r2C9u12;a42CAeB09h3FCr2A8D;!a4De12i6o12Ds0;a15B3;y13D;cEFvA1;c3C0kD6;!a7Fb45C7e26f14Fg240h31E3i2F0Al6A3m631n2B5p4B0Br2BAEs27B3w46E5y0;d28k791l28p2C2t3E0z1425;hEB;e17i3FC7u5;a3AEh0;!t70;!eAi12D1l7s0;c4BEBd3AE4g97k0l443Bs4EA8t16D6;d26EEn2s0;z13B9;!l112;p16t7;s8t7E;e3E24iBCy0;eA0Et9B2;p651;!l7oD;n2904;c0sFEz3;!a1s0u2C;c3D1;a30e104i6l1C8;u4FBB;!aCe26oDs0;i73o1A3By0;a1C8Fu600;d0l1EnE;!e15i2EF2s0;!d0n1209s0;t3F65;iEo199;i1Du34;eDn2o9v3;a349Bh1A7Fi3EC5o1F0F;b1Cn26Ft10A;h1F89;e6Al7;e1r1D4;a188B;c93nFt34A3;z4F95;!a4DdA7e153i21m1EEn2140o25DBs2B96;g97nB;!e4i2E6r7s0;!a48Ce4i66Es0y0;l0y0;d2Cm21Br2C;f2B8;a36F7e17;s4354;g354lC6A;k8Bt3080;h1C;!e4h28i6l87s0;!a90d0hEDr1s0;!s0u79A;u22FD;!r12s0;d0n8D;d6DCf4B3Bl14B0tDBCv25B;!e12fB5oE4s0;sAAC;c32r25;!a4Be114i27s0;a0c44r1193t50D9;i127l2B25r2D3t17C7v3;a1336o6D;r1926s8;!aCd0s0;e50i50;n5092t203;!n14A4s4D5B;o2B56;l5F8;a1DC2e71;o2A34r1AE5;aF7eDn2o9;c256Cd3167e1FE6f4CD9g1F92i3161j1DBk4330lE5Bm140Bn25DCo3E0Cp387Dr12BCs44FCt2174xAEz197D;mC4Dn1625;!f183n22p983sB51;i13r7;g297n1;lCE0mF2;hB4lA5;m102;d0m3r1s0;c1215nF;eFBFi2FDoD;!d0i18s0;!d0s0t1x0;b56d79Eg3336l280n85r14AsBt20A;!b4856c2353e13AEi86l7n22s3C00t83F;e0l2393o0r18F3;b1Cd89l1t2E7;d27g10sE;dB7Dk1l2871m4EF1n323p446r4A95t5021;n359;!a1De1Di2B86o1F83s0y64;e1Bf7nF;!a4B56c32C9l50F6m2EB3n8r2307sCA6t2Du3A6Fw0;m91D;g35Fl2DF8m0;l28F;e24t60;!b1D7c4789d3Ce4g5F7i8El497p5Ds0y0;!e262i21s0;e23i495;!a3B70e27CDi1FDBo5BAy0;e2626;h2C70;!e24i6y0;a9e9i31;p502;c0nB89s19z19;l8m7n3B7s33DB;a3BF8eC7i42C6;g1z3;t1473;e63Ei41D7o1rB64y0;!a7Fh4C9;l0m2Cy82D;!b1Cs0tBD;!e4i6m63s0;eAi6n0rE3;kB7E;e239;a49EEb3DAFc344Cd3A7De2A7Df1268g41B6i2EADj3AB4l1588m1E47n1528p4601r4259s30B3t157Eu3D91v310w1CFEx1B38y290F;c3C1Eg1Ei3505n205Bp38r1Et3EFv1Ey17B;a0c0n1;eCi9;e61i4A3;a20e12r91F;!g38s0;d87fBFt48D2;!a2172;c2An2A;n362;n5C9;!i3Dn3Ds0;!a72e12i6s0;cEFr3;t3E0;hAEt681;e50o8u1C;i18Al48;h21D3lE1o1733rB15;a188Ai102Bo26E9u5;a532i3F;b44tC7;a1e5o9;c25Fo127q98A;e1CE4i7AFoC5;o29s1AEu34;a2D0Bc4A48d436Ce3863f2FD7g3828h1C2BiD35j1639kA89l3EDBm499An2831o3EF0p1BFCq172Fr2B40s3331t454Eu497Av2225w14FEz3D1D;n3868;!l236Cs6CAtBD;!a9EDe456i6r58s0;!h43B9s0u2D9;aA4eB48i1BA;a1E7De2BB9y8F8;!a19D1b332Be27D0i3D8BlD85m2Eo2D43r37F0s0;eAi4CC1mF2;!e15Ch1i29ACs0t11F1;h213;f16DE;mCAx4C;iC4l80o114;!a252d0o29s0;h55t2D;a46EBx5E;m45n4;!l7En8t3;i37C;r941s1F;!d3BECl3C89n2321o1E9s0u21Fv46;a1e1AF9i18E7o4D31s0u4AC4;cF56;aDlC;!aCe1o1533s0;!a4De15i1E1s0;a0c0o29u14;!a1De1E5f255i6s0t32C1z1F;a4863e5l2E4nF;aB8b89d4EFEg167lBm4AA7p200s1B6;c1lAA;i85;d50Cg45F7j1Al4994m1042n75Dr1580s200A;!l0m164;!c7AAp8BB;h275E;s6A;!a40c93n2s0;e6;n0o9;!d0s0t39;c14D1f24Al441n2sE;a927oE;!i11C;b402Co1;c7C1t47;aA4e15i6;a47C9d1FCEi12E8l19D7o4881s1FE1tA4Bu85Aw3D6;d7k4Cw1;i1BF7u160C;!a2918b1041c322Bd46CAe38EDfE78g1592h3BBCi222Bj453Cl4FE9m4E9Bo269Dp2BB0s449Et4FB4u1031v27ECwA7z3B83;!h78y0;m505;!e447h1i312l2A7p1A6s0y0;d0l39n16r1B08;a0iB;!d1368r451s0;i4818;e2747;i1BADu2F9;o1D04wCD;d16C8e418AgB8k1l2155m2AFn2628o1AEAr52s17FCzB;h5;d4C;a12e12;!e24i2D4;!b1D1cDDdB40h183i3C6Er10C;!f183g56s157tEC7;lFBB;a11D6b5B0c302Ad352Ce15F9f32E9h713iB1k4E20l797m4A8Cn12ECp3354s44C8t1v46BEw32B5y1;b7Ce42i2Bp1C6y0;a4Et4604;!i10Fl1Es0;!c61;d5ADo29;d0s11;c61;e1149k2DEEl1Dn92CpFF4r1CFBtB;t36F;h4167;a399Be3D7Fi31F7r2A04;lA5r1;c5s0;a81;s116t31D9;a9c35;c2BsE;e30n24BF;a119Dc4297e15FBf3C8g4DD4i21B5l239Do2240u1C87;h70;c1DCkE2Cn9EE;!a117e8Fo46u14;a4C81e3AF2i2AAo1E0;a0g217B;cF33p5E8;a86Fe15Di2A8l2Cu168y0;e1Bf7n2o29;n2s27E;a20ECe98i21FEo69u37C9;!d0l7r1s0;rFF;eD4;m5F;d19A;d1C8;r3DF1;!n1AFs0;a3612c7B3o10t5C;!h1i9B9kFDs0;e166o71;a14BDe1E6Fi263AoC89;!e67iC9m2Ey0;!e30EEi2FCCr1AEs0;l25A3r192A;l0r55;!l0r55;k832;!n353s0;cEmD2;!v7;gBt28A;s46B4u4E28;a8Fe1F0o21F;y17E;!d47e10fED7l4944m2Ep101s2C50wA9D;!e1262i21m162s0w9A;u1C24;i722;e5i3ABC;a54i72o4C8C;!d3s0t3;d0s3t0;e3DBFi9CA;a0iBB;e40D0i4E;!aDi1507s0;aBAi27ABo2F9y939;h161;k1AnB;i12t1;n3AC1;b1CAe5o28E0;e235nF;!n4A5o10s0;!aC3Fc5143d1D97e301Ch3979i3C4Fm44A9n3o2798p213Aq3A9As3AD2t4911;!nB;cBF0s91A;t1Aw1A;!d4F31;!aCi435Eo1174s0;l28n1r2752s35t1;!a54e42h1E;i4ED;!d0i6l273s0;aBAi57;!a3D85c4EBEe656l384m1EEs0t297Cy37F5;c6A8d0fA7Bl1113n1861s1881t3474;c0n2sE;k1As3A8;a75s2BFu34;e31i31;!d0r2F;d0r64B;a51u59x68;l36D6r1;!d0l1m2Es0;s19t19;e2430i66l14Br89y0;!a15CCd3341e2574iADk5DlF72o2DAs308;a3F15c46e2CA4i29C9o3031s129t248Cu71Fy0;i4r0;b4DF;sA1;l63Cs8B;dF5r118sE8Aw38;l13;e25oA99;!e1EhA5;c3d18t0z18;aCe2DEAi1A52o54B;l1D3;e186o10z120;a1DEDe283t3041;!e67i43m2Ey0;a243Fe2274i1E1Do92u541;!e15i6s0t0;p1r0;!aF67b2BE7e41D2i43EkA3r38BFs0;e383t1;a1018c31Cd0e33CEiE4n8p3210sE;tC35;b1D91c4107d3FB7e4479f375Bg50DDiDE2j1Ak4FB2l11CCm1294n3AB2p35BEr4FCCs1A1Ct1352y1z9D8;o71B;cE7Dz50A9;d1n52;r173;!a1F75e104i1E1o35E4s235Aw253y0;r1F0As435Bt1uEz199C;l8FF;!bB0fF5l7n22r0s8;n391B;eAi1EC8l3FA3t1D9;a3AE2e2A70h15C2i586z1F;!e3306m2778s0z7DB;e5n2u57;!i1Am2E;!hEDl24B;l32Es0;n18B4;eAi6m0;!d3F14e17s0;a593o4E8B;i3EF5l340;g1188;e2C3i4517o4E;n26AE;h1Et1E;t481;!e0n0t19;a9rCE3;!a4De37Ai3310u39A;a1g0o36;!o6Bs0;h199Ai1DlC8m1D40n4703;i2Bo2C3y0;c2452g11;a3ACCe1F0i12B2;!aA21c1E12e13Fi508Bn2683o4316t2133u485;e7F4i32;a1D5eEC9l1138n65Dr57;!a2A5t27;e46B7;a20oE7;t77A;!a4Dd0l176n57Fr1s0wFA1;!a18Fd0fB5h23Bl4BD0m1C2oA0r58s0t36ECwED;!e5g1s0;!e63Bs0;iF13y0;c33F8m1s2BD7;a7Fe4i2479y0;cD1s2B7;g0i0o0;!e9i9s0;!b4A5Cc18BEg298mB0r21Bs0vFB;!a40d2540g223i1E80n2893oA0s0tB3Du304;o6Fu328C;o3C95;s48F2t2C2;aE8eAi1B3;!p76Es0;l63u3882w1Ax0;h3B1;!a2E83e4ECi3D76o3458s0u4E;f37l26E8;i18A3;a15Ee11BAi1C6Ao9t0y0;!a7Ei3ACAs0;dBi1;!i160s0;e186;a4EEEo9Dr29BA;a321e61;o180C;a2B1De4952i375o1uB8;r1083;e2AE8fB5;!d0l477Br2BA9s141y0;p135uB8;!a9s38;s35t2D6;e1s0t1x68;!eC0i6l7B7s0;c0o10;!a7Fe1B2iADl22s0y0;gFC;m2DA;l8B;!i27l19s0y0;!a3DA7e757l8Bo12Bp14CCs0u1AF;a1A62o4DA4;d329Ah2F7l3C67n300Fq6F0rBBFvCD;i270;i25u5;e1922;!e27Ci6l47E5o10s0uB8;o1F9;tC46;!b5De15iA8Cl7Cs0y0;!cBe0r7s0t3;e1Bs4D6;e0h3A;n2t0vD8;a3E02b2E81c10D8d17A7e255Bf11Bg4BE9i15C5l1A75m3AC0n18ACo21F2p4B54r27EFsE0Ft2960y177;k53nF;r139Du12E;!s0u3;dA71n83;e1g4FA7l1D57rE82y963;y2A2;!d0r1s0t3;oCFA;e1i13u14;!d3F6g3CnABs0;!o3C5E;e676f80Dl4D62t6B8;!e0l0s0t3;a3DB5;r36F4;t1364;r43AC;lA0r54A;t4AAF;o2964;a72o42rE3;c2Ae45F2l3422nC59rE4s3579u352F;!a4Dd0l7Cr1s0;e17i38Cy0;c2Am6CAp502;b1BFEe1i3E69l20Do53D;!f9As0;c9Cd4160l28r28;h1l1;n45D9;!b1Ae5s0;a20B2o399u19;a6Fo35s2D;cA5As0;r25t0;nF4;oB1v3;!a7Fe15i21s0uB8;k1l3C;e103i3D;!d0l181r1s0;aEcEi10FnEr40C7v27;i27E7;n5E;b17Dc2545l2C6Dm4878r4E1t8FBu41F3;t4FB;l118o45;rBs36;n0r1C28;lAB0;b4497f5E0i1CEp1FE4r9A4wF6C;!e1u26A;d3Af2Dl292;!d0e0;!e26r7s0t1y0;s3t228z3;e20B5i33DCl926n507AoCBBv3;eB7i29Do29;b7Bn4A9;v4537;!aAFAb512e13Fm2AADn3717p1FFs3ADt3ADu2B1v3w1FEB;i21n8;!e10BiADl2A7s0;hC;!k5Du3189;c1d1;d4FAg1n47r963tA40;h18FC;c1CgB;!h1l0n65s0t0;!e262i73Dr77s0;t1u49;h1A6s4DCtD2;!aCD3h28B6s0u2C;c2Bn83;a1C09e2ECFh1C07i15BAl10C6o174Br36C5u1D70y29D4;g123sB1CzB1C;a11i4E5A;e489;c4FA4;cD96;a3Be6DDh93;!e3D44iB;a4970eAi6;!l6As0;c182t0;aCd2BlA0s1Ft2A9;a20i10o29;c1429i35k45BCt2Dz7;!a8e26s0;a4B81e1C36o607u63;i46;a2730c21D0i0o28sB2uB5Bx1F;!b37F2s0;b1s4B1D;eC97i6y0;g29B5;c616s5;eEE;g1E2l0;b1c4E4Fo408As3EFt1D3;a233c1;!p314s0;a3068l3A9n161o1FFr1E0t3E7;!i6l22;i2BCCl959r10C9;n4B7;a10u23F;!a12c557eA22h3EDi66l38n34As78Aw1D4y0;d0r28;n2589t35D9;n2419;c1356d0f454n3o1C;d430Fl220Dt2B1Fz17D;a65e17;!a2EC6e3D0Df37h50CDi415El11CAo4380p3A01r43FDs3DB9u3D98;r22;!a10gABs0;!l7n22r0s902y1;i33B5;g127l159n63rB97s84;!a3272d18ADe432Ei3F64l1FD1o33ACt3506y3829;e33i6o1F;i3BCl31B;!f37i6;!bF8e4A5AgB0hB0Ei21l365m2Es4A7Cw2B07;o4C0;e23i313y0;!a4De4f37i66o0s0y0;e69;!b106mE9p179Ez1A;h3685;a1De15i6;eECy0;e1F0o9E;t4A31;!s52t37D;a33F2e439Ai20F0k8Br2FB8y0;a8e799;l28t0;d0l34rCEs0vA1;a42i59o1F65;!i13o1s0;c196n429Fr2635sE;e0i4BA7;!i56s0;!dEE3eAF6i856s0;s1Ft5E8;!d1BA2i6k14E7l2CF9m1n2E6Ap3BE3r0s3Et2D47v4884;!d3B4Cg323n22Cs0t28;!hEC1i54k5Dl126;a3F8e98oD5;a215Db108Dd30E0e15C1g3AE1i6kBl2324m2035nF1o36C3pD8Dr1BE5s1D1Dt24F;l7t2D;a4Be4i6l19;l55x0;d3w9;!i5t27;!l7n1Es0t1C;a25C5u3B3;!i13u3;!b4EBk141Fr1s40D7;!d0l497n0r47s3B63t1F50wBF;!e1CB3i86l2Cs0y0;d0l57Er144;a2C3Be402B;!a4Be187i6s0;a4i16D;e23i21k67A;!mABs0;i228o1;h3D5D;aCi3D;k1Er29B;n21AB;a36FCc161e6Er63;d0t13D;iC31;!e3E1Fi6z3032;!eEAi50C6w888;s4Et1;r209F;l3558n145r31EAu5133;!d1fB4Ci4AD9k1C83m1908n1p4973s47F7t33B7;oA6rAA;hF2i440k1C;c38g20Am63n118rFD8s36t34AF;a1d106e0;!aCe33l3s0y0;i417A;c251;d0r16s8;n692r1t18;!bE3e4i43s0y0;a1EDe208;d19E;!a4De103i6n0s0;bD4r87s54E;e3984i96o2709r173u5;!e1i6s0;i679;s3DE;e1D3Eg45C2i2B33;n2o1;l1t3FA4;g14m0;!d0l22r47s0;!e15i435s44ABy0;b42Cg2573i4lA8m4711p4D57s34BFt2F5C;!e762;g8F;c9Ci108B;c4B8Fg6E9i3C65m1237s4EB5t10F8;a3DC5s259;a467Ae31EFi3E12l7Co46t566y0;s1DE0z48;r16u12;a28C;e17t1;f1m28v1BF;!l7n1BEAr0s3E;d38e1gBA6t38E;e82u14;m46DAn284s297F;!l453Bs0;aBD0e1399i4CADo457Er3AE9u672;dAA6gB;eA6oA6;i1604oD;pA14;l4530;v89E;y75;l2CBC;h36A2;n1r379t1CDxAE;e4n1Et4A;p28r4147s223t2E99;b1FF0;!a1671e2D81i2605l1D4p439Cr460Ds1A0u1;!a4Dd1e15i21s157t23A;a40m72Bo29;!a36;!g464h1s0;mC8nE;cAB7f108n2t5E;!eD3i7Dl22o2F13s0wA7;!a15Ce15Cf37i35Cl7;b1Cg38;l3An8t677;bA2Be3C0Fi18BlE58o3D57;c8B;n832;p141A;h5C;h63;!a4A16c23D9d4E07e15i624j181o37CDs0;e1A44;u148;l2FFn28FAr3DEF;!e1i1B3o10s0;!e15i5C6s0;c0e5s282z19;a51Do14;p1662;k2AC;!e784l7n22;i1Ds0;!rA6Es0;!a4As0;o57s177At22D2;e1k129;!a45FAe4103i1325l5DEo49A0p2F8r10C5s3170t215Au1086y1BEF;!a27B8cBd4D7Be510Eg15ECj9Bk3D14sC73t5Cu38C9;!a24FCd34Ae4451h131Bi2438l28D3o3541r33EBs0u5y0;b5Ci1855k50A0m1A;a0l2C;r3253;l34Az87;t1344;a4611e28A2i1764o3E4E;c3E4Cg3825n28p87s86Ct1AE0v3CD2;i5C;b19oE;n22B9;n2Av3;!e15i6l2Cr3F86s0;g0k1;!a4DAEeAg7ADi6m2Es1A0;!a5121g2E2m1763o12s0;aB50;o22DB;!i1034l18Es479By1BC1;cBe1;i4C3Bu3148;e54D;n719;r12C;e0k1lBr24EDt50DC;!e67i6y0;!s0t40;g17A8i56t278B;e4E5i6y0;l286t3AE6;e5n2s3;!l7r3;e1r5A;n0t5E;h2B;h11B;!h1F;e6Ei41FD;lA5o10rAA;aCiDFo3EC;e30D4k176;u47C6;i1FEy0;l232rB;dF5iCl4F73r118s4D61u59w4E42;e104i6l2C;!a105e23i1A1B;fD6;e12h0rB;t0w80;!a20F3b4F6CdB3BeFCEi2ADDlBr26CDs53Fy64;aE8n2D;!a177eF0Ci4E74l2Co428Er3D83s0u2015;!a4DeC9Ai21l2B00sA0Cu4732;!iBBs0;a3E6Db2B17c3CAFd4D2e2275f2AF9g1D2Eh13F5i2375jCE8kF28l3150mCC7o32FBp2FD0q494Er23ACs28FFt474Bu251Bv24ACy848;!b3A3e1Bi12DDl7m1EEn22sF0;!aCBe382f1539i21l3C5AmFFAr28Fs41F1wA66;c53h3;a22C0e126;!e2F2i21s0;!b47E0l188r47C7;a1821b66Ac128fBFg20AnFo4D0;c9B3d1g1n2u84;r409;!i4B6s0y4E73;a1C60b4Dc41E0d4D05e21FAg1ECBl307m1BD9n1475o196Bs1818t5D0v23F6z97E;!d0g397Er7s0y1;!b181e4i6sF0;!e15i6m2Es0w80;!d0l6Cn2171s0;eAi3417y0;!e24i6v2DA7y0;!l18Ep999s0;c32s1F;aAD9f155Fm1Ao5E7p3F8Br3B7D;i7ACl1BF;c546n11Bs7C4z19;n44ED;!a3748e1105i3098o12s0u4DC5;a22AAb272Cc322Fd2929e33B1fCE7g13F9h270Ai2F3Dj3090k44CCl34CFm4F4Cn1C84o11A5pF1Er442Es20F5t3049u4745v5Dw3A39xC7y4D90z310B;e126oD33;c48x2AC8;!b42D3eAi21l22p287Fs0;gFDEnF;i568y0;!a322i31k1o1s0;c2Bf7;i3AFE;a2766;d3AFCe4Eg389lD1o346;l8DC;a2Di1E07o1Fy64;a250e1AA4g44i117En1DB;!a214s0;h9F9;i4n3s3;a1591e1h4673i4164l3EB2o191Br10AFtFA0u3C14;a57o95;z1CCD;t4574;e49D3n61D;l5F9o1123r297t3D1;e1g6Au20;!e15i6l7s0u49;a1e1i2776y0;dBm3E55s117;aC3Bo469Ar2744u412;rF43;d740f33E3p1C2s386;!e12r7;a2B98e2B9h3B5Bi34B0kE4Do1t2D70y0;a3A8;a18Fe12s1F;!c9Cd47i6s3CBFt47;a4E9o25E6u496C;eC6;a23C4;!f37n3E1s0;r1t10A;!e4i5C6s0y0;!e4i2A8s0y0;l3576;u964;!e4i6s0v18;!i152r7s0y0;e2F5r23EuE;!l55;!g48;e18Bs0;!s0t12C;i54o3D90;e2B9iC9y0;p28s564;!a137e1h0i2CCAo274s0t29B1u4E;r492F;uAD5;!d0e0r0;!t176;n1o10p39w1;cEFe1l1nF;a1DcA34e23i6p1Cr3D;!i54o6F;aCe33g0;!e4i25BBs0y0;!e4i6o10s0;!b1Cn154s0;s107t7;d85t28;!r7s0t53;h25BEl87r43C3;i1Dt0;l4BA3;m18A9;!c9Cs0t4F1;!a1BEe361DiB34s0u44AD;aADDi27lEBo576;n0t4C;v12C;iB1D;!d14CAo9Es0;e18Ci3423;e595oC49;dAADp9D;!a44An0r1s0;!i61s0;aD52e483Ci30BCr3E6s218Du700;e1E3Co9E;!e15h19Ai6s0;!b4BBe6ErFA5s1A0u55C;e3C71i2E43l62r1D3u12B;!eAi6p4F1s0w169y0;!a1FC8d2842i3Bs0;i3BoE1r58t4F8u2236vDE;o1E3A;g19n16E;e6DEi6l19;h488i1FFu4E;!nC8;nC8;!fE2h10Cl6CpABs893w130;!a0e26s0;e0i4;a2604;!a1618eBh4D0Ai4C1Ak2Fl2693m3499n1D6p1r1s1C1Bt19CCy0;i157C;!c11gBl0s0t3;!l3694n4Br2Cs0;d1f38g26A1l5nB7rD04s259t507C;rF66;a72E;l5Ft39B1;e757t1D6u2AA3;!e15i2044o56s0y0;iBBo8F;t1B6;a1i31n3t3;a2254e43F5i317r22;!d0fB5r1DDs0;!p43As0;d3Ar1t39;d41s3u5;l881;r1411t1;a2A50e17iD0u50;!e0n4EAs0t19;eAiF9u49;c4CA9s14;nBt2D;!e1Bi152l7n22y0;o3221r6FF;!a20i245D;!d6Ag3h1s0;j4BEn1;kCB;i31o1;!a40i0s0u5;c1256d4D6Ee35B0g4908m3FDAn243Dp321Ar21FDs1CFCt3A9E;e3794;d14DFi63;d1CAEg3B0s133At37CA;a416e1z26E0;a2F56l29C2n3CA6p31D7r31;i2889;c1Cn3s0;d1e3Fj4Cl3797n200Br4274t8F6;g230Fk2FDDt2C2;a12e18A;c1f7n2s3t7z3;e4FDn4B04p6EAq2319r977s702;!d0l22n1C2r181s0;!e14Ci6s0y0;a6EF;e23i86;l244AsB;n249;a449eC6l2824o175Er184;!a1DeCFi6s0;eAi6m39;!r418;!n1EF8s0;c1FDCg1C9Fq1B8A;e1r39;a2672e8A8r42B;g58i3A75k1EA4u451;eA2F;!e4i6s0t128;e8CBl22;!a36e4h1AiBCm2Eo36r367s1C9wBFy0;d2B2F;a1i1D93l3;a1DF8e615;cBe67;a9e5u14;c0n0s3z3;l1E13;!n6CFs0t2Dx3D50;!n2s1D9;!d0gAB2m1D92r1s0wA7;!a9i9;lDBp2327;e24t1;r2956;l335n1At3C;e4iB92l44y64;!a10e15h8Bi66l22s0y0;a27DFe1C3i3B;!e4i3F36o1B91r32E5s0;h271jDB;h1F9EtFB;!d1Ae42s0;d4Bf2Dn2;a1B05;a1E94e4A4Ci33E8r28F7t1EECu262D;cEd3n4B;!e8B8i6s0;!e23i21o1Cs0;d4AE8fB1gFE2l1m2F9n1AB0p135r380Ay28;pBsBDt379;d0l2DBx1F;l185n184Cs154A;e10EnF;!e15h156iBCs0y0;!l2DEs0;!d38eD2Di1E1l7n22s0t20CCy0;!e4i35o57;a94e30B8o52Ar4752;i1DAp5Bu2C88;aFF7e17o37D0u14;o2BF;g5Bs0;!eAiC9lA5Cm730n22s78y0;!b1r229s0t28;h614;oEE;!a4865d3CBBe3613g3BE4i255Ck10EAo3F51s5090t2097u62Fy0;!a15DEe12Fi4237o4EAs0;c19t19A;t14A;!a2F1Bc1F03k2A98s0;a1520e23B1i4CC0o3571;m148;c2D7p1470t1553;!iBBs0y0;r4AA;i286Dl10BFo7C7r26Cu2A31;nD2p3C1;!a12d1A9i2D3Bo29C5s0u2502w2E01;g7F2nE;!aDCe4i3CDs0y0;!a2404b1166c3F01d4133e406Cf4972gEBFh16Ci4181j21Ak28l506Bm2B8En4728o1E50p4099r1B67s49A1t1A23u3297v1CD8y408F;!e187i2CEo10s0y0;r48BE;!a4Ce5i11Cs0;b1E2B;a691e15i66l44r1CABy0;!b63e3860f5Dh3EDi6k4A8Fl1630m2EpE1s1D5Fw225yC60;a10o10u34;!b2B61e15i21kB0m61r237s0;o77B;b1t0;a168Ee2C4Ch18B2k3B9o1s1973t1E8E;s5w10;e4D28;a4490e1DCoD4t41C;a3B93b842eECl403Dm2547s4F9E;eA93;!a20b7g3223o1106s0u5E2;aCi18;e10DnFt29;l1ABn2E27;a5De9z222C;l31E0n24A4r798t136z2C;a1D9e15i6u57;!eA9i2195o3FFCr1A2s0u250B;b2D;a3C6;e4DFBu3B9Dy0;c3A66d33C3f21E4g2D48n4900o4CCDr4934s3F85t200;b1Ci78Fn3C97r29C;a3534i0u8B4;lA8sC1t2D;a20e5i3D;k1El0;a646eE06i2EBoE;a45CBc1C0Ae1D5f154g1i370Em4142n4E1p265r2EE5u244vFECw28;b9A2u12B;a3B3F;e1h1Ai20k129o8FCt3D8A;!a1Db367c12De43B2h112i33BAl811p2E6Fs2AEBt629w1975;p5B;!gABh156s0;n55u60;a59eA1oB;i5011y64;t2738;!e5o2F9;t3D38;c1s3z3;d0n3s11;e37Ei66;e3562i2AD8l6FBo5019r39D2u4E3Ay0;c19FBd3087l4024t28Av459;i13o242;a9t4F;e275;a1AB2eAA;a0n2u14;iB4n458E;a946;a13E8d4AE0f3CD4n3o4DC6sC2Ct3Dz2C;e22C4i1E5Co30C0rA1y0;!l1534s0;!d0r1s1Fy1;!d0i6l7r0s3E;a3482e23A2i40F1o1119s0u3D94;h279C;r85D;e30E;gBl1n1r2FD;!oF2s0;e207;!e207;l0n37AAr1;n18EB;o2Ap18u31C2;a5De1D59h1C5i6o1F1;!a1C3Fe7F4i37A2o3508r33B4;!e4DCEs0;!c11;a13e5t7;e3EE;!s64;e9D9;d44rE4s1709;c3C7nF;l3An8;!a1e0i1A4s0y0;u256;e2B1Ci378;nB4;r39t3A;g280;r78s1C1;a174e67o29r56sD00;!a94;c197t8DB;a51De90;n1C1;i2Bp7y0;i29Do6B2;e4i6l19y0;!l19;e4i6lB;s216C;s1074;!s5C7t1;!a10g7As0u22A7;a4C2b3017i10m2201q9BBsC9Du1E85;!eCl3;b112e2C1Do49;e3B5As1Ft4086;e5C1i4802o2C90;e4i296y2622;i866o54y0;e189i21l7;!d1r1s0y0;d0r1s0y0;o1047;a0h1C1Dr3908;n277;l3CA;!e24i6u3D;s941;a28C7i106u2588;u3B86;!a4Dd8Ae4gAB2i3DF0l112s53By0;e15Di17Fl170;u3194;u1312;aE4rF6;!d0n3D9Fr1s0;!s17E5;h7DF;a1e4D34f14F6m1Au110;cF3d0r1;l1A9Co1419u1285;o361;d0s8t11;!b2D8e262iADm2Er28Fs0t1E7;f3F;e40ABk3t3ADv3;!bB88e1Bi6l7n981;!e4f37i312s0y0;o0s0;o43FE;b7BoE4sEt48CE;l1m1t940;!a1l7;a1De79;!aCo29s0;e0i663;!e4D1Bh10Cl4D8Fn22;c32r0uD;c31Cg231i147k1EnC90r1F02tF2E;!h126l23B;h5D;!e2F2iCCs0y0;!gA87i21pB3A;!nE36s0;a1EBe30;a571c13Ce1g19Ei47Ak47t1;c2CB0e1g17D9k2Cl3FE4p4FA5r1822s2FABtBw3B50z484;l5Ft356;!s0t357;c93nF;f1C6kFA7r285Bs29AAt12B6v2B;c64Ai88r695;a1De32Ai4D7;a351Ae35B1i745l1ACDo38B2r16A0u327D;i3B73;d0r1t1y1;g2Cn1r1s4D0F;e5F9oEA9rE1;!a218n2s12B3;!a412Be3967iC9l44o1E78rAB0s0y0;a4AC2e11BBi49BBl80Bo4243r35EB;!a4De15h1i21s0;!a9b27BcF8d0gA7l20D9r17Bs0y1;!f4CFDg925p4326s0w463y0;r1u1A8;dBe5;!a51e12i6o0s0;n3s0;!n0s52;o4E3E;!d13EhEDl7Cr7s141;m39r80;i34oB41r550uCD;a2D01e14CFi3BD2;t13Du59;!a261De4089o3Cs0v7A;a9e9i65;a2454e3FACh8Bi42F5o1B99uC20y4781;!e1i5;m87n1D38;!e60Ff37i312s0y0;!i420s0y69C;!e4h4D08i6s0;a1118e109o4031u814y185B;g9l39;sEt1;e1l1;d3B4DeA42t6E6;r131;l48n85;!cB2e15i6s0;!i160o29s0;c2An2;e4C84;c414Ce3E70l1944n17F1o0r5AtB;!c2Ao1s0u1;!a2C2Ee14D5gDBiB;!e153iF9s0;!e15ABiB5ClBsA1t294Ay0;!f21B9i73s0y1D51;!c454Dd23E9e3A1Ch47FCl11B4o2BAr3BFs4603w3412;!a1F5Ae2149i317l176m1C2r89s0u48F;i736l19y0;e5nFo10s19v3z19;!s308tDB;e0g1;!e60FiCCs0y0;e383i142u15C;!aB91c1DCd1C77e4342g2115i3EFAn0r58s0y0;lEBoF;!e13FfC3i4F9Cs0w253;iB96;s245;r14D;!aCc156d89Fe4BFh156l0r1s0;!a2EC5e4A3Ck1C35n364;z6D8;!a3724e4h210i254o958s0;!a2C64c538e2B9f28i2C19l365p49F6r43As0t11C1v2By0;m907;iCD;c9DBh1C30i403Bo10t2E0u13E3;aEw39;e10B1fEkBl59Am1B09nBC2v3614;e38F0rB7;a4E86;b3DBe6E;a42EDeB1Do464E;nE32;!e4FD3l16s0t18;aCe1i2977q6F0t2A52y0;!a4Be15i6D7l6Cs0;a1728l1BBs1Fu14;c506Fg7F2l27DCm0n268;c0n3s14;!r4A3Bs0;!e24f41BCm4A03s0;e1ABAnF;n2t2F;a249e15i6;!m2Eo34;c7AAi5o1BEt1545;l66Cr340;e50Dk28;l3E1;c76AiC6j184m58p41D8;r37B;n8A;!e4i3DCs0y0;eD4h368k58s4F8t124;l462;!e24E4iBl3;a178o12;l33A3n4D52rF3As330A;k0l0;e33i5;e33i1;!e1BEi3F7B;!c171i31k9AEs0t186;c29n9E4;a3BBAe43CiC9o71y0;!d8Ae1B2i2EBl7s0;!d0n223Fr1s432x0;a4824b456Ad2FFFe38D5f185Ag4484i2250l3938m1525nC06o4620p4BF4r4ED1s1E8Ft2084u1952v4BB3w1695;a1Dh3Du3D;h545k39;a11ACi1A;g92Dn25s1E;i1231m3CA4r3E14t5C;o4D0;a876e23h555i12D0u34;!a34DBm3Ct1;l3F;l1tB79;!a462Dc243e47ACfB5h4E16i2428l38m2Eo3EAs1985t4E90w4D47;u1AB;!n0r8Ds0;a4E2Be3F57i6;aCeAy0;!a42A4e5t0;sAE;a2AAe1469;s2C;!s241;eDl7n2v3;e1Bn48CFt3CB5;a2D19c4A32e67g2C42m3B84n470Ao93Bs32A0;l4uCwA9;a17EC;iC4oEB;!i4EDl7o12;r3D6D;e1fB;!i3864k254Eo94s0t2F75;e228;e49D6;a3e0;!d0r1s0t0;!d0r1s0t5;!e1Di4A51t158u34;e2A4Di1311;f436;p599t3102;i1D82;p48A;l39t39;!a7FeAh0i6o1E9s4D78t0;g3m1y0;!e4f69Ai66m5Bo1E63s251t16Cy0;d4B5Fk53l27CAm854n486Cr266Ft1y1A;e23i6oF1;e23D0;eAi3D;!a33F6e2126i35DEo3F9Er350s460uD4y552;b7BlA85nFs107;aEiDE1;!a54hA5;n13A4s5Et102;a1Dr4706;dBn4By16;i161F;!k369s0;o29s1F;n3A5r1t38;r540;eAi1194;a19D;!g1A;!a1eAi6s0;!s0w3549;!k1En1Es0;e911h54Al4291u5C;e9iBo71;!c28As0w113;!e4ECi35E0s0y0;a36De17;!a3231e153i21n22s0;n98B;a12n1B0;i242;e6Ei177;e14Ci6l2C;!a4C13e68BiDFs0;!s0v19;r1A5;a44F4r1147u1;!a3B76;e1581o30F9;a359;a4d0nCD;u9A;e3CF0i4609;!e4i1380k4F74o4DBEs0y0;c16B6n2o10s107v3;eDr0sEt1;k3140;l0n18C4;nFp16;a100eC6;e1CEEi57Cr1E7y0;lBu59;a3D09e455Di4368o211;e0lB7;iBA;a1g38n24C8s11t38;!h23Bl2Ct28;e36;!a5FEe4i43l6Co10s0;b10F5c1D5f267EgB0Fi3927k3C46p492Dr3E0Fs36A9t461AzF12;u36v48;!f38n2s0;a3A4Db169Fc9E1e3D29i31FDm3942o3C30p231Bs0u2EACy605;f47D8;r28CD;!e15i6l3s0;!e5u57;n8E8;d0r598t1;o5010;f7n2o9;!i1A2Fp35A8s1B0t1;c0d1n0;e1h27;d1Eu30;sB37t1;a3FBA;!a4747e48FFo1A5As0u484F;h3D5Fo5C;e24FAi16E4k163l4D01m78B;c0fCAn19t3u14;a35C;!e6DEfE2i85Cl2A7s0t11y0;f31BtBv3;!nB6;v3731;nB6;l1734s3t89E;n0u2B1;o5B1;e42iB;!t113;eC38;!o14s2DD;eAi3C2;f1DD;a9e9o49;s6AD;!d13DEm2Es0;o184F;gC2i25p1q3D72;a137o5061;g44l17E;!d0r4DFs0;!e10;e1DF;n1C6;i41y0;!a3FFe15i21r22sF0;!eAi27Fs0;a96Ai2EA4o337B;!d0e9l7s1;h469;n3BE9t4AB;g1E58;o1971r95uF;a4F1Cr12BB;e2127;c4852r28;e17i9BF;o86A;!bBn237Do263p15BEr4158s0w9;c93e1Bl7nF;a46e26E5iEo41D;!a60o108s0v1EA;g0n29B;a2794d241l3A9n188r107Dt4BC2;dE4Bn4w80;o37B5;a42B8r95uB;d0s5Et70;i8Fo3C;!a1e4l7s0;!o30s0;a2BE9;!a4Be15i43p4Cs0y0;a74o31y20;d2Cn4256;e1Bn289;l3n2o9v3;g10;pCEF;o30C2;a4792tBu34;i16Dy0;i13Bs2D;!m2Et381;a18Bl1FB;!f1C5g3C20h121s0;!a956e4i497Cs0y64;e3DC0r3D;!d0i21s0;t6C9;l2A0;i451E;r5E3;uED5;a5066l4;t2912;a2807o23DE;!e4i21l22s0y0;h6B9;a40eAi415Do8C;m55n8r7D5;i2FEFn151t2D1y0;g1k1;!e5i2E3En4ED3s41E;c367F;e5n3;c2BDnB;e55;a463Fb50C7c1408d11BEe232Bg179Di3B22k1EF1l3494m3591n3262o2D96p3D7Bq2A67r301Ds2C62t3B30u4F80v4893w3D45y2DB4zB6D;d2Fk65Cl2DA0m0n2049p176Er507v4102;!a4046e4A71fECi2CADl1o4BEDp2834s0t27FAu2403v44;a2CDo6C8;e32C0;i4o3BCt0;!a2F6Cb5013e2D4CfB5g37A1h2C15i5151l191Fm2Ep461Fr222s2FC2;n20Ct2743;u3DF;l2023r1B36;d1DE4;i50Fo2F81;s11t3;!b176e42B6i11Cs0;a42i65;!d1805p278As0;!r1s732;h4810l76;a451F;!e390Fy0;d3i4927k265n2D7Dr2D8Cs64At1E;e24FFi32AEo36B3t0;a2234e46D3i547o2D0Du4381;i42EC;m18r1B9t0;h9A9;l1n93o10;!n1D2r7s0;!e24i9F5;lDD;r2Fy1;i883;a4049b9Bc3454d7EEe1AA9g28BAi3CB0k85n4434o4E68s43B6tB1Bu2F96y234D;w524;!e1Bl19En3D46s0;a42e10uB;c1Cl1n372sE;lB4r10;!a4Be29E4o36s0;r643;a4Bd39;!e8Ci3Bs0y0;i6p2C;i8y1;!b3DDd42A2g62hE3o31rB62t4A8w4D55;h47AB;d429n118;!n8r0t3;!k82En2AF3s0;eB9i3931;!i27;!b39Dc250d3BE6e31A8f2DB8g20EAi8E1k470En2A0Ds0;!c84d44k2Cl7B8rD1Cu1FFy28;m62v535;e51Fo305u168;c41l0;!o672;e3Di3F21o3EAC;o7B1;s2E4;t56y56;!a4Ce187i31m2Es0w80y0;t2111;!a3FFc13Cn22;!a20i13;!a0s0u3BCF;!e15i43s0u49y0;!d0i1FAs0;n1s0;c2Cl2EDFn13Br497Es178t3ADy28;!e4iADl19s0;mF57;a43CFe1i60A;a3E4Ac2C08d204Ae49D7iA68k4B9El1081r1s182t3FCAyA68;d1r17B4s8;!a10b181e3527i21l36E4n2C8Bs241;!aC92d17A2e3B0Cf2CD5gA1i18DBlE86o1D30p2C37s3767u35DDv222F;!e2B14i1BAr4058s0;c2Be1n1x0;f7n2s99;!cDDd4054f39DBg2Ci123Fl6F3p21Ar1As3BB3w3D6;e15An22;e46Fi3C2;e3E00iC37l3E7o45D1rA7;l27F5m3B75;g5A;i3BA8o1234;!gBl2AFBs0;n6AD;!i36F0t21BEu304;n18o1692;!n5A1s2110;d2DFf751i2B39l147p347s3EFt1Ev1Ey17B;!a45BEc219d101Ae3f7BCg32DEi2FB4l13EAo2487s0t4211u40Dy7C;!i2Bt1D6y0;s3F;a76Ce1o1u4E;c3E6d89e267l4321m77n781rD58xAE;e172Ci6;!d0rE2s0;!a283s0;i51o95;!l1An1s0;a48Be2EDo334;a48FCb3F2c1D5d50Ce18E6l2870;oDCA;!b342E;e279Fk7;c130g4E65t4B3;b61Fe5nFp16;e39E7;a1d4C0EeBF9i24D6l20F2o3C1As3A93t1079u4E;gC2n65;!r469s0;iEp1;e3EA4i21;n6CF;!d1CFp47s0;mE9n48;!b1F3e984i6;!e871i6s0;a283Be38B3i3055o157Du251Ey31B1;a1B93e3587i3C4Do50AAr4A18;i684;!i684;r4642;a2EAs3432;l171C;!e43Ci4284oE4s0;a80Ed44e90l0s34B4t4E8v19B9;o222A;!l1n20Cs0t1A;!d0l1r218s0;bB0l4F2Bn3B31rA98;a3E42e31F1i4F9Bo12y0;f1g2DC9s8t200vB;d1e5;m1D2D;aCi3F;e33i6;l57E;!i81El41BDs3F05t8FAy1;a1iBB;e743i234El1BFo71y0;n0s2BFt7;b168r19C4s8;cB2k47l4267n1972p447Bs3437vB;c2DtB;f273l56;!a3BC6b1B2FcDDo419Ds27B9t389w50FE;eDo9;a0h61Ai4AD4o71B;r1s2F4t1807;h19;!i6w2F0;cD1n2376tC83;a996c3655f9CEm4A09n44B8o3FF6p2943qF95rBs48F6t2C24u18ECw1E66z4373;!d0r2481s0t16;!e4i18DlBm2EsF0y0;aCi4DB;e92o29s19;e5l7t7;k0m1t1;n1280r62x128;n1AC;e2488;!a46B2e1BC9i4D21o1s0u4E;!e33t1;e33t1;!d0e1i6;!e346Cs0;t3E;a93D;cBd19t19;!eAi1B3m31CA;h0i178FoFC;o136A;lB38;e32Ai1CB7o3BC2u5;!aCi206s0;h1i31;n1r12ABs1B0;h225;!b2620dEDAg60Cl330BnBr60Cs2416t29D3;e21F1i3Bo1;!a3C05h1As0;c44f108n1BFFt3B2;e3834i6s1F22;r3BC7u2947;n0u5;!m2En1s0;e24n2s430;sC1t4825;n16r0s70C;!e153f37i312s0y0;!a4Db36FEc42B1eAE1fC3h0i6l22p5Dr1F9Ds29C8t4EE6;eB09l271;aCd27;!b21BBd72Fn3A0Ao26B3s0;g5Bl70n2Ds2058;h2C34p23A1;!a4De47CEi2A45l2A26m63o12sF0;n3y0;d19n3D1Ep1C;i72oA6;e9BFo578;m0n124;!a289Eb2932c2617e48DEfB5g12Dh504Ci56k5Dl18Em4D3n4797s2D1Ft1AB7w463;a4Be30DBi6m8Dr1896t39;!rA9s0t1;h195A;b16c4Ct39;m40C1;w89;g654;b147c63e25nE6Dw0x116;!a1d0mBs0;g1zFF;e10lA0nBt1;!a4Be166g1i22DnBs0y0;!a3Be4i22ACl7Co0s141y0;gD8z198;!dBl76n3A13r1s0x128;i596o3C;l143nD0;m142;!d1082m2510;l8AFt268;!e4i6lBs52;l1BCCo23Er20B1;c43F3gA18nA45r9B1sF5Et57A;!e26i3s0;r0u1C3;!a1F73b41B8e2AB6iE9An484o2478s0u19D8;!?0e230s0;h47D5k1940;n2F20r301;n19p1;n2030;i22Bl4A92;!d3Dm2Er7s0;e4m1;c1B1;e64Co260;a20Ae14Ci1E5Dl2Cr14Ay0;!e15h10CiC9s0y0;e5BCo1A6;e73Ei252EnD8;a3313h245Fi1EA7t2078y4489;a382E;c4CBAk56t5E;!i4A3s0;m276D;n1t4473;!c32e24i6s0;c8i4;!d0l1n0r1s0;!a4De15iC9s0y0;a3EFCc154Cd241e3D53g788h56l3044m3nECr3t4261vBC8w3CA0;h9F2l6A2o25;c456Ek25EFu71;n3p1Es11;g39;fF5r38As0t2D;i2D13u5;a4De262i21o4D7u52C;r3F23;n6EA;e25ACi21y0;e1Dn3291;r492;c2435;!i7D;oFF;i1F8E;!eE4iB34s0;aB50h580l150Ao15C7r5B2;d12A1;!e4i66s0w1BCy0;e23iF9o12;c25AEh4EFCi911k1740lA8Eo2BA7tA12u3538;c34E1k28;b1Cn65;!e12Ei6s0z70A;lD02r0;r1816;r17As1D7Ft2D;!i3953k1l2C5m3387sA1t3315w1A1;e0i13oC;e2289i21;u304;!l7y6D;a3471d2C7e173FfC4Fg4565i32E0jB11k1m44ECo2244p4D86r1E6Bu34v3BCB;a11BCi6;!a958c13EdB3BeAf5FDh3E65i6o1E9r64Fs0t1F97u26E7;k2942r47F5t5094;a358;c3Dl7r4E6C;e85Bi66y0;e5s2BF;k465BpD4Ar136;a40h0i10F;a539o7;c55n115p55;a3BmA1p16;o1FFr4AAE;!c5C5e3640h50C2i41ACp2F0Ft2CBEu3E5Cw3E6Fy0;f904s1ED2;i30E;lC8m0;!e1Dt38EA;c302g36BE;a20eB;a29E5p1u1;!a1A7d764e42s0y9A;!e31ADi2F58l55o59Fr7s0;a75i13u14;gF8;d2De5s2B7;!i13l7s0;e5f7n46AEo10t7;n2282s221;d4363;e4AA1uA6B;!d77;dB1A;i2CB;!d0n507s0;i56o10;eA3;!e26s0t0;c27CCd2CC1eEB4g42AFi9t25F4y35;aCB7h580i4Do483Br1BCu2C;r4FF0;aA4Fb1F55c41EEd28DBe46E4f1F59g1445hD77k70Bl1073mF04n24D3o111Fp3BF9r3E20s4F44t3742v13E6x9ACz184;a3821e19B6j1BE1n3F08;!iCB5k1FAEo92s0u9EE;d38g44k5t40B2;l4A46;!a4CD8d2671i336Bo9Er15A3s8y4371;!e1n22;iA71o58F;b1D7e1Bf28Fn146s107t3C;!e26s0u14;s615v38;cEs8;eBnE3;!l24Dr345s1BD6;lED;l6BFr12CDt0;c2Ad3;e25y0;e1i48E1;c11De5;i132n7E;n19D;eF36i2FBCo2BAy1258;nC3Do1AA;n4Br36t48;!c215Ef1g2655k0l28n32Br1s31C5t58z32D7;b917;!i2C43j53l1n121Fs0u90;!e3D2iDFs0;!g3C0Cl7s0;!e12i21lE1s0;e12FAo20CE;a10e1oB;e0oDu14;!g3i9r0s0;e8f6Ci10;aA48i11C2o3188r550u710;!l1B43o260s0;n135Ar1t4170;c401;!e510i1A99s0y0;h129r2B22s5C4;l4EBCsEt3E57;a35C5b21Be231Df0g41D3i3545k1m329Dn323o2ECDr3010s304Eu3843v5By1615;!aAC9e4s0;a4AEDb12CAc2F1Cd1D32e4CF4g209Aj1F88k44l28DEm195Cn2D74p44E8r2969s4C57t3CCEv4E19y1AzFF;d0x0;d0s0w1;i49oDA;l3F98;cA28n1A7;e24n2o10s11;eAi6m63;!i257s0;e1Bf24Al7s2A1Ct58;e5n2t7;e6FCi359;n391A;o2FBu2FB;kDB;d2Cr44s1B6v3EFE;!a20b3F2e37EEf3B49g89i10AAk379Am2860nDC5oF37r7BCs4811t235Fv11Dx3133;c243d247Bg3E89k1A04s0t30D8;a30e23i6t47;!a3762d136e5035fAEAg323h4AE1i4AF9oEF3s1EBBt164Cu1y131;e4i86l2Cy0;u46;!a8b7fB4i9oB22s0t41;!e20Fi23EDo26BBs0y0;!d0r1s0t137D;!l2Cs0uB;b1Cg29E8n39A6r5DtB;c26E;d110n2859;e17i5F5;l1nC1Br45B;t3837;a125e109o3F3uD6;i2BD3;!sF0;sF0;f24An2E3oBDCt3;!d1r0s0;!s0t18z1E;s2B5;l46A6s0;l5ErB;a12i8C5;g1Es19;r859;!p1Es0tB4;!s0t150;e22Ai6lBo35;t2B5E;!a425oA4r3EB;n2tB;n2t2B;kF7D;!i2BB;!a42B4c3377e4EB1fC3h4735iEC5l221Dm2Eo40AEs2623t1757;d2B5h3EB;h613;b5096cB1Eg46F6p4C18tABC;a34C;!r216Ds0;!a151b181eB3Ei41C8n22oB27y552;w4C9;l48FA;k386D;b1Cr155t433F;a0i51C;c3f7nFsE;i20AC;a2ED;a4De23i1BAuB8;c0m19B;nA94;n3A;d62;!c1A48e5;!c606e93Ah19Fi69t102A;a3814;!d0l39r1s0;a2EB0c24A5e16C6f1n4CA5o29;e4C88;!a2625e154i96Es0;p3848;!c4AA5f8l3E2m3C0BnB8Es4C34t5046x11D;iAC8;!r1s0t119;!bABk1l1AoE9s1F;a296CbBe4BD8i4D9Bl40CoD10r1D0Cu273A;!a0oDE;u23C6;cBd474n1FE9sC7t47;d1B0tD2u2AD0;!a7Fe5CCi8Es0y0;a5001e2C03i487F;e3D3;!d0l1C6s0;!a2DF5e4B7Dg2492i39B9lBF4m3D87nDD1oEpDBsF0u4ABC;!d1El7s0;gB8Fx1F;iEn25x1F;!e1D;e3A1;!e307Ei1A64l44o36E0s0y0;b1Cc5Cd1B7gB;!aCe26iCCs0y0;l1491m1nFr1C82u4FD;bF6r118wE4;i620o678y620;z38B;g3s3t1;cElB4r25u263;s8F2;r2D71;aDAo3D40;u88v56C;bB88c42DBd7BFe12f183g24D4l1E79n1E7Er4249s1466t1D3Bz8B3;a2B7;!n2081s0;nD5;!i142;c0e79s99;tA13;d4C2y551;!a3D36e10Bh1DC1i3A64l3n22o41DCs62Eu4Ey0;i28D;!d43B1i2E89l52nFA2r599s385t9Bu90;r3BC;nFtB4;r1913;!f1i156As0;nA19;!g2E65lA8;h318F;!a4e4i6s0;i10n0;e17o3630y0;!e15Di6m2EsF0;!c416Ad38e1g4175i20k28l5Dn2B05s0t28;u139;!k5A;iDl4D9Dn1D3r2D69y13F;l466Et324F;l4Cu5;d90Cl0t90C;a409Ec28E5d3408e1iD90l5049m4FD0n43F0o4A7pE46r2300s3745t3DDDv325D;!e15i21l22s65E;n37;lA7o23E;e12l25An2;!e12Fi4ED;!e25F7i6l581s250Ey9A;e2431i43rBy0;c7g19;e17i3934o30E8;a394CiBy0;!e1012i6m2E;l36t48;!c48n154y16;!c63;c63;!a4DAFc350Ee196FhF00i1563k22Cl178En413Eo4DA9p2BC2t91Eu7C2w3CFF;d3e13F;!n3909s0;a759;!a4A4i41CCm363o43E4s0u245AwA7;!e35s0;d58;i90r161;a12Bd63i3369m4C65n4A9rE4;yA4F;!a646i6;h3F3F;l1B40;g1EB2sBD;v3826;e225D;a1o46;rBx1F;!e5i24FE;!d0k4Cr2Fy0;i3Bo177;f28k5ACm1s3C7E;e142AiB7p47y0;a4423e5o9A4u304;!i3BC3s0y0;r6Ct8D;a1FF4i4o199Er4981u49w1D7;a49DDe4FDDi3242o261uB9y6CB;!a805f8s0t1;!e10Bi6l7sB2B;!eDCs0;e17i4EC9;c93s107;d0uD;e1F7i2C0Fr2358s0uBA9;a1BAh87i4;r5B;eA42i6;a12i31;g196n65;e20Fi6;!a3A89e4C7Af37i439Dl22o339Br2436s0y2F8D;a12r4AE;a1003eE38i1A84y0;d32F2r438At88DwE4;o29s0t7;c492h4D1s1FtBBD;!d0e32Ai5C0kA3sC7Et2BEE;!e2532i4F90l776o3Cr1011s0y0;c23Ad1A;kA3n1DDo2As5;o29t1y16;e1nFs1A8E;i21AFy64;a25CBo10r11CF;!aCe4oDs0;t1v48;i81;c4359;!r24D;a27AEe24n2oEpA5s19u14v95z19;!s0y136E;e41D;!e533iADy0;!a1359cB2eAi6k2F26l22o4010s0t1685w27B;t7E8;!c1D5e1g3A04i117l102m2914n474DrCBCs884t2986u3358w109Az17C;a317Db4F3Fe1Df482Eh2194i0k19E9l5055m4707n114Do50EAp2679r2FADs13F6t2BF5u2815w16B1;!e49BDi6o46s0uA0;g12D7;h804;a5o9y0;h44;i174;s14E;!e4i6pA5s0y0;e42i3B92o71y0;a1A92e2A5Cf8l38F7n3CE4r22A2t13B7w28y450A;!aBEt80;e621h5Fi81Fy0;a1i77;pC4;!e18F1m31Fn15BFtF8;e633;a2F90i13;c5Ce1k5Dn9BAs1F;!a3A1Fs0;bD05c2AdD69g4DCBi30D6l11D4m40EAn3C07pF6Fr37FAs1948t1FEFy136zAEB;b1EeE2m35;!i73o60s0u34y0;lAAE;b83t1DF2;!e1Bt428B;p45;i29F0;m8;d168;!a1Db1Cc1Ce24m0nFs61t38Bz61;rB2A;gBn85;!d0r1s8B7wBF;i837y0;a0cA9Bn3409u14;d2Ci2464m7CFn3B38r2D3u3ECDvFB;e49B9;!a7Fe21B8i1010l112s251y9A;c32r48;n65r1s376A;!a427iBs0;e3E71i1BF6;h20D;l4BE0n40Bs9C;!c461k1B22p37C4r0t144v3926z7;a7Eo8;a673i9;m4CD5n83;i2F3u2F3;a4F5Fb4ADAc3E06d17EAeF8Bf1EC9g49A5h312Di4239j3C72k1228l3517m4494n4EEFo4801p3F35q2E05r384As1AF6t24FBu3034v2C27w33E4y713;l2303;!hD95l148s71Et2D5F;!e2DADg40CCi6o2DDBs0t389;c32p1w16;a1239eB7i2B94o131C;c4As4B3E;c4676;!eC0i3B80s0u34y0;nDDs7F7;a20e288i2D4;l1tAF4;kBp4C86s2113;!b29c9Ae23h10Ci21l16DFm2Er51As0wA7;a57i88o20;eC2;i2AC7y0;!a7Fe456h183iBCl4B25s78y0;u527;!e5i61s0;c2D06nFs11;t115;e748;d0m3;!e15i5DFs0y0;d2DF;d0m2A2n38FAp8t0;a266Ah38i35D4o4769t2A87;l34A5;e5i5C;c13Ct0;d7Cv340;aEc32;c1dBs19z19;n4A5;aCD0e343Ai3593o41Fu1B96;n1A16;!a10e2741i3D7o2C1Fs0y0;d205mB;a42i117o8A;l16v19;e3974i96;a1e262i3F1Fy0;!i88o30B7s0;!a5Ae12El482Cs0;a350Fe27l182C;c401n3E5o10t16w1;i871u23F;!a354Bc1CnBo104Ds107;i4820;cD1t712;e156Cu3E8;h6A;h195;c0gFCl3;!i35Cp8BDs0;a5De4188;!e617f37i6l7s29EF;e4i6o54;c85x1F;a40u34;i487By0;a2A56e1B28i22A8o2285r1D0;h7i287Ao29;!a4F39e35EiB69l7o1DEAu42F;a4Ae4i21;a520l20D1;a3404e23i6t1A;!a75d0i4s0;aBEe760i57;!n439s0;a3330o1E55u13C7;iE6n145r161t0;l44r3B03;k0m1;g2CE1n4DFC;gBr31;!e2B4oDEs0;hCD;i57oE;!g19n34A4r1s0;!l5As0;!k8Dl19s0;!d0l22m2Er1s0t4538;!i1AEDn10CCs0;!l7n1FCr1s0;m34B8;h1Fi69;aEo51;t3BCD;!e4fC3i3FD4m66Bs0u453y0;e1i88;i36sE;n994;b7Bt10A;!d0r1s0t88;n49D9r4302;y3E8F;a1B64eAi2975r3AC3uEE;a0e0g0;r7B2;!e12iBs0y0;!e12i2Bs0y0;a1595e3E8Ei2106v22Cy0;t41C;!d5B5e73Bf14AAi6l22s16B7t38v13D4;!e187g0i6s0y0;c14ADe1hBk44l3303v88F;aA4iE;!eCFi4506s0y64;!l220n22w130;!nFs11;e103n19v19;aCe24n2;h21B;l1Et0;a1354b189Dc22D8d38F8e4967f3498gDCCi18F8k50F2l1B24m2F68n285Co3DB0p366Cr1ABCs22BBt1121u43BFvFAAwA7y22B3;a44A4h5B3l1C54o5016u3A8D;m48t36AB;t23C5;oCt2537;o395Cu5;o3BBvB;!d0f37l32B1m63r1s0;d0y88;d4Bg3C;!a4Be67i43y0;a2A51i247;a2B60e4CFAg43E0i3F20l76m513n2294o2616r45BDu3233;!a1EC6c892i40E8o4CFsEE;!e402i9D2s0t1E7w1BE0y0;l143w1;!i610;a4C4e1;!d1f37i6k28m2Es157t144;a100yC6;e7E;e3A32;r0t2C7C;p135sC1tB;eAt0;i1D5E;e39Bg0;l14AoEpA5;h87;h34E;t8BE;d409;!a4Dd0l6FFr1s0;a2E85c203Fd1523g106Ei19F7k2Cl2BFDm50A2n209Do2EF5p17E6t103Au1705v223w35D0y0;!e0n3r7s0t3;!e36Al7m162n22s0;!a531m33E0s0;h353;a4FCFe395BiEoA6u6yC4;uB95;!e4i21k44Ds0;e5fF5n2zA3;a36e6Eh1A00;!n16s0;c0m0;e778i420y1A39;a20iEECo29;a43E8r27D;c120d4CAEj4BEl2BF3n464Ap242r1C75t4692u448F;y400;a44F3h1k80Dt39CC;n25s173B;a50CFf0k1l48A1n168Ar1As7C3v751;f3v2B;!a71;m2298s1BBu5;a247Af427Bi3CF2n8o1u14;o6By0;eB29i21;a45D0h14A;c406l28BFt91C;aD6r378;p0u5w16A;i133o6y0;f0t0;a4DeAi6;!n76pABs0t6C4;s3A7Cz3;e98r238;c45BAo3D3;u40;a59e17;c2C8;!a4Be10Bi6l7s0w80;!e5s2F1t28;a40u2D9;!e189iDFs0;n4r3y1;n1637;a0h29Fo0;b3107i2DDAm5077o812;nAA7;nA8Fr1;a356o36;d4589e1i84C;m1574;!a1232e291Bh156iDADl4FC3m2Eo36E6r28DFs0u794y0;!c1g739i143l0nFp3E53;e35DAi62Bu4E;n98E;o9F7y361;!a2129c2B8CeB7f3A3h181Ci284Cm2Eo10s951t2A81u1037yE22;o3D;d26Cl3652s3DD8;r5s0;!c2D60d4204f1348i6l2D7n4B38p17ArE2As0v3F0;a2A2e30i160A;a48Co441;g3w80;f46g4A5p4F86;eAo1;!a69e4i6s0y0;!l22s308;a38A9b400Cc13ACd4CC8e3430g1532h441Bi4A02k352El41B2m50D1n13D3p3AB5r1741s488Ct2689u1EF9v2204w1F13x226By170BzC82;!h1i9n376s0;l0t6F2;d1h1;n76;c2D87dFF6e1Bg299Bl7m2F14n1FF9p13A0s11t13D7v1B0D;!a1F5s0;!a250b4BBl22s0;a10AEl1ABo483Dr2FE0;lAA9;!m2Er0s70C;!e2931i4CEl80Ao4E10s0y4E0D;i4Du445;!iB4Fl7s0;!e2433i13r56s0u4Ev886;h403E;!a828b1D1e40A2iC7l1225m2Ep358Es0t7B6;a1207e4CF0i17AFl87o1A83r3D1Cu12B;a57e41DAiEm37D6;e1f38l4E6B;e5u14;!e19E2i4B13u34;a40e448i813o251A;a5120e4DDCo4B85r39EA;!a51De12i472Do1E0s0y0;k1l1r3A29;c3g2Cn1E2Cp8vB5;i82s0;l76r8E0u6A4;!g3A4i86;b1Cc58r24DBs40E5tC08;a40e23i6;!d0z3;!a90c135eAi6o9;aCi18y0;a1n18;a639i0t16u5;!n0s0t11;g2Ci147;t1x0;!s5Et2D;aDo6B;e187;u1BB;a17C1e72i78ClD61o41ADr2CB8u33BF;o1A2;o40u49;e1Bf251Fn2;!s268C;a4E24i7CEn3631o30C4p85;c55d58i117m3F3n118p3F0r15E8tBx42F3;iAA4o40;n2C96;d4456e2DBBg2271i3Bo4238t4A;r27BB;!aCe4i13s0u5;c158d403m0n0;!e0l0r286s0t2D1;!e5s18;aEn3;e8DDi296y1244;e11Ci447;i46CCo1626;aE05i2E9rDF6;c128d24Dn3157;r4DE;s27BF;!a4Db14Fc36Fe1557f37g34Fi2B81p34Es63Bt1E7w439y0;a1413i36;r392u4E;aE2i1798y0;h1EE3;!d8Ai96s141;!a21E3e4008i21s0;i73l7y0;t29B9u4E;!a10e1g3939iDBDl4D7Fo35CBs0w2F0y0;e6EoB8;a5128b471cD7Ad152Ce2123i6k293El3519m4842n3B74o21E7s375Du4CB4;aCn2s11;a3301;l374D;a3782e33C6;!b2F2Ce3FFDf657i4767l929s0y0;r3D0;n33Dt1346;m5C7;e23i21l2Cy0;e36E9;a0l19;r1BE;a312Be3906i13C9o26A6u2566;p211A;a75u34;!aDc7B3e309g63i86k4988l22nABs0t182Fu4481x3F;z2AD;i0o36u1E71;!a1295g4BFDs0z170C;a1AA0e6A9i12CEu71;!e8Cs141;c29A2;l4o2A;!d0r1s0t2D;e1s14;e5s14;!c11s0t27;!e4g1s0;a12l2D5;d3772;a4429e1Di6E2o3089z2135;a356iAC;!l3AnEt8FA;i2D44t7;i38Do2DC;!n35BFs3;a2395bE94c2B13d25A1fE98gCA7h1Di3120k35EAl3F82m4E0Fn40EDo21D5p4FFDr16E7s4B75t2C54x8Ay2B1Az3D9A;iEl1s22E;l273n40Ds2C;!e5h4841s2Bt1EEF;c0d3;a46C5eBE1i3725l3923r133Fw622;!e5i20s35;s19t2D;!a4ECCb396e4i6l112m2Es0w112;p4798;i21o1EB;i60oDA;!n16r0;e5s1DEu14z3;!c4879o4E0Au21B2;u82B;tB9F;d0nAEFr1E;!eB2Di6o0s0;!a7Fb53Ae14Ci66l365s0y0;rB74u59;e72i45o49r87;!bDDe2F66h58iC9lBo1Fs0u4Ey0;!a1e319Bi17C9o3F95r165Cs0u64Dy0;c0n0t3;a322i13EB;o15E;g3i4r8s1C1y1;!i25nD2p4512s217;a12e8p8;!aCe4i13s0y0;o1457uE;u967;e22F;a67De9;a1075eEiFD4y64;!e67iC9y0;!a3C24c158e210Eg226i4474o33D4pA3s78u45y3B6D;c19rEt419C;d185e394EgBh285EiC04k28l28n4F81t26D8;iE2y0;r38B;m0n2rC;!a4Bi34E9s0y0;k3656m1;a54Ci2DCAo1901;a442e12t7;d1En1E;o2E8E;!a4Dd419Fe1366g155Bi2F7Co9C3s0;a11i9;!d0r113s3E;e1u936;g3u17;!d0r3307s0;m150;dD6i207;u1713;eBCDh1i401Cy0;c2E50sD3;e3Fo29t62;!e12i4B6l7Cy0;!e15s0y0;c1BBu12;c54Dl1A0E;i47B;!e4ECi6lF4s0;aD3n835;l1C0B;n3r3;!e192l7oDs0;a233c0;g170;a450Di5076lBo132u335;e1i209;!e1Bi559s1AEy0;l297;!n276r4C40s0;a4DC1eF2;!aCd3083eAi395Aj97Br45A5s8;g4995q2F1vBD;a244c37B1g2CBDn15A2o3F5sD3;!j101p2E2s0;a2e12l19;z834;a291;o117;!l0s0t3;e3A98;nFs197;!e26FEo27C8s0u143;a17e2E0Bo6BC;l31F;aEe3B4oE;a30e4729i14C1u3D;d2A85g5D;e2166;l3425;!d0l5Cr1s0w1FE5;n161s0;d0eAi6u20v48;m2En1;!g229s0;!e1Do10;!e4h1E96i6l875s0;d1En7;i73oDC4r3C3Dy0;dD2nBt1370;n21AA;!b41D6e533f255i264Am2Ev25Ey0;a750;e12Ei152y0;i7Do51Ft70;t4D50;!n1s3E;e3A2Ci1E04m120o21p10BEu37F1y3B56;eFB0;!a1FCAb242Fc3FD6d27C9e153Ef23C8gD19k366Bl4CC2m398En3371p1371rC2Ds32F5t246Fv4179z19C2;s4649;!g7ADs0;!a634hFA;o2FF;l4A78;!fE2i8Es0tBw7F5y0;eC72i1AC2;a4d50Ci16B5k1B9n1A18o94p30Fr4ABBt3045;eAi3F;e15i1FAo1;!t5E6;b49c3CdAAq123r14EBs2BDDw1;t5E6;d58l232;c3B90d97El10FFn45CAs4286;mAB3;a46BCo95u9C0;c9Ct5B;n2485tC8;aCt1A4;l3B06m21Et3CC9;!c197;d1DFA;e1Di36C9oA7Dy0;!d0l22mD2p109r1s0t2Dy0;!a20e4i6o29s0;!s1A;!l5Fr2013t3D0F;a32D2eDE0h48C1i35CAo281Fr1372u33D8y2D9;a411Bb3C6d9CCe3523lCp8tB59;a4Be114;e47B;e67C;!a2DCDh4BB5i4EFDs0t19CD;aDC2e1i361Ey64;m3DE7;aCe1B2iADy0;b55i25mBp22CE;!eDi8Ey0;!a3280n1D44p932s0;a150C;n2v19B;!e15iBCl22s0y0;l3n1;h3A4;!d55s0;a3F99o97D;i117;rADCt40;a4407c156De2EF0g8A2i254Fl42AAn146Co2DAFr3043s50FFt27DBx426A;c1n1s34;c137tD4;!i27nD5s0t78y0;e1t234;!a30e15i6s0;b16i13;h2BEi29D;!aCe369Af1E3i10E0l22s23ABw860y0;c13Cd38g1CFt6E6;!e23i43p11As0y0;a148Bb4520c39EBe1C29h29CAi4BFAk2A5FlD4Fm240o506pF3Fq413Ds14ECt3586u3145w254Dy2F09;t1009;e46A;!e15i21o29r7s0;a2CCl19oEr95y20;m93o34t5B;c37A7dBeB01p4691r3839t1Ax4974;e14Ci43y0;!a21e3276t158;!a4137e30EAi1DAEl40B3o39E6r2957s0u3A22;r715;a65l1n17A6r36;s7C0;g0t0;!h5F0kE18s0t348;!a0eAi9l7s0;i221F;b4E9Dc3D59d3644f3064g74l2FBAm2A84n1EB6p1FE7r457Cs406t2F4;c3DnF;!e4i574lB4r25s0u30v27;c8ECd4E9i5D6n2DFr1742s7t6B6;!a1i9s0u5;e5Fi2BB;r80;!a34BAfB5i1D22p34BDs0u1D03;c8i13u14yC;a10e72Co4E45;!eAf37i6l22s157;!a30s0t1;!l0n0;hFCA;!d6AEs12F5;!e2A69;!aDC3cCFCe277Eh15ADi4F40o2D95p316At335Au23F4;a1b1CBm7D1n119o3659s2FEt219Au14F4xC1;!l404F;g536l3C92r0;!g167s0t44C;a34b4Dc238Fd1e1184hCBi4B40l210m1n4420s3t38A2u1vD1w10xC1y136;g2D9Bk1Ct39;f1l49Do94Ev4F19;!d0f7n8s0;!e20Fi6s4B6D;!a1eDs0;a5112i4F16;!i20r194s0;c0oA78t5E;i3658o3131;!e569s0;aD22;i10Fo46;h1D53;e1s0t1CC;a45e14;c712e1i152y0;b1Cm1s0t4743;e15AnFt2E86;w266;n34EB;c1AlBu5;aCe1BnFo29;nFs14;p39w39;!a3F9Ae4684fC3i1CF8s0t16Cy105E;e5h3lBo9E;d469l53s1F;a4401b31DDcE66d30CEe4015g4F42h1i4786k230Bl20C0m1C13n4539o3F7Cp21A4r22A6s3703t4B90u16F7v4012w204Ex0y1155;!i11Cs0;s324;a2CDe305Eo5097;aE2;e0i290;e310Fi1869t40;a21D1e3875o168;!l7n22t2745;a134Ec616d6F9e13Fg995i60k0n33C4s430Bw0y1;l2278n3F8Cr334;!i8E4;n0r8D;!e67iCCk4C;oB7C;!e71Di4E;!d0nF8s0;a10e15AEi435l216o10y0;!e4E22i6s0y0;a69e23i6;!i90m2En2Cr161s17F6t1CD;!e24i6m2E;e63Ei43y0;e2B9i43y0;d2DBt0;!a2DF2c243e49F0h5B9i224Ao2176r21F6s3E98tA2CuEEBy3141;aCeAi4419o52Fu34y0;t6D6;!a267e15i17Fs0;b1CEcEd7AiF07l863m1En2BCs5E0u3047z1E;i4662;a4c2An2o2Ar4u4;a4CE0e3F5Al2Co772;!i38EBp2B23;p4366tA6C;a69e4;m56;!m56;h30F4o11F;d1396;sAD5;h4B65;l6B7;r36ADt3244y4B34;e3217i6;!d0lFB8r1s0;a46A3b3CFCc25F2d1029e1889f475Ag3A06hF91i30C3k10D3l2B0Bm4E75nEBAo282Ep43D3q246DrCD7s48F8t3747u4FE8v4E4Ew1840x4686yE91z2C;a15B;aE5u14;a9u14;!d39i6s0;t1A31;e23i3632;!nB5Ao4F00t88;e67qC2;p1F6t47;a5Cf1DFFt3319;!b11AFc3DBd76De4f14Fi66l22s0w240y0;b512;a9e5o2144t5E;b105Ac2Ad413f4034g2232z8B3;a51FeC2Fo4447r5EEyC6;a242;l5Av54A;i3Cn18;a2F3e12;e1B44iFF3;f7DC;lA8t1;d1C49f1055;e90i90;!d0l242Dn4A2Ar1s0;i5FA;!e4i43s3E5y0;a1EFnF;!d0r58s0t1;h34;e23i3849;aA4iB8;e852iC9s0y0;dF4sEz6A;e910;a31i31;cBe24k5Dl24BnF;b135CdD4l5Em3D1;eEu20y0;a3BABc1460d3BE7e10f2B4Eg3DFAh41A5k4C48l3676m3D63n3137o228Er44A8s1B3Ft405Eu449Bx12C1z230C;i1297;e0n32Dt3B2y0;r78s8;i77o9E;c8B1e1g1i287Bn2;!d2F8Ee90i2568s0w169y64;c0o5D5s107u34;l9F;!l9F;!s11;s1D9;!s1D9;f44;e23i6o8C;aCiDC1o4EAu5y38A6;nFq90B;!a110d1DBi1F2A;m2007;i12t60;e1i3F27;!aDAi6n0s0;a30e23iF9o8C;!e2D36h488k8DAo83s0u4E;u292;l1Er1E;a1Dc3D51oE;lA8s42Et1AE;l4819n106r25DE;nDD8r2863;!h1r58s0t310E;l48E3;eCB4;n1E0E;b1D4d119m2422n1FCDsB2t11D7;c0d3n52t3;c0d3n3t3;!d47h10Ci152s3787y0;!a1153b37EAe15f39B2i21l2607m2935r237s3AACt16Cw240;o36D7;b4A0EcAF8dF1De17F7m124Dn425Dp4F7Es3EE9tA1E;!n3Ds0;d26C;d28B4;g167lA8;aD4;!a414eA3h177FiE26s0;i3u3EBE;!e12y0;e1g3B0Bi144Dk366EnBC3s3954t58;a3110b58e1B6Fi37D8m4D82n3149o595rFBAt4Av44B;n3s5Et2D;sEu14;!a3764b21Ac9Cd5D7e4186g44E2iC6Dj8Bk28l22n4D88o3D4Cs0;e1i290;a10n20B;!a2DC1c11d4066e25A8f7FDi2C6Fk14C0l24C3o48BFr28ACsB8Bt22F0v87;u202;e242g2Cm2F9r853s1828v3;!e19Ai27l53s0;a4Be24i6;!e17i568r7s0;d437p301s47E7zA16;o267u1D;aF1e4E32;aB76o2F3B;n546s5;l3s18u5;i5m0t1;c11l16r39s48;aE21o4Eu97D;e1i1l3;!e533i66y0;i9l76o29t38;c3r1t3;!h156l22s0t397w1CAD;b8Bc705e1i3067l3w9B;c3469;l14B;a4236e49F5i4764l426o3EA8u27BA;n2t60;!b4B9l220s0w130;!a20e1959i2E6l22m47Eo579s0;h1E20t454F;e10Eg41nF;!c1sE;a501e0o29s24EF;cEd0r1;a3E8;a163;!l771o1Ds0;o28BB;f8F4l1r589;!i1Cl22s0;f4D1;t4892;h2B7;!h4EBs0;a3C4oC6;a5144b45Di1D;!bB4e4i6s0;!aCh16B3i152l22s0u4Ey0;l40E3t147v4FE5;!e22Ai21s0;kE0l39;!e8i8;i6C7t102;hAEtB;u5A;eAoDu5;a0o10;!a0o10;k791;c3AEg3AE;!d5A4e23D3i2BB7s0;e235l7nFrBs11;e2C5Ei3E78lBm2Eo5022;!e67g167i4BE1l22;n44E;c484Bd682k480E;eB87i2A92p3873;!o46s0;a18Fi4B03;a70Fe1i34;e33n1;!eEh9F;!e12i254s241t3455;!a150Dn498oA9At5119;h8D;l1989n1Au472;!pA5s0t3CE;!n22r1;n46D6;i4s37AD;!a12e1365i6s0;aF5Ae28EFi2048o1196u23CCyA75;a5i2Bo40y0;a1DFe1;d0p1;a10e5;!a10e5;m1C4;l905;e1Do35;a0e23i2A8y0;!e224i3Bl7s0w80;f7n0t14E;h35BB;!d0l7r78s3E;!d0l7r0s8;tFF2;!d0s0t1x245;!l53s0;m18u5;o4114;o13;l265;e26i6l2C;t126;y4A98;!aCe143uB8;bBc32;m1A3;i10r156;!e4i2A8s0u14y0;b34D4dC6EeAf11DBg2DFFh3F5i2ED2lE3Cm249En3FB5o5F2p2652r3DE9s3D80t232Au39EEv4B83w3FBEy4C53z4794;aBAi43BDy0;t1730;i36l61;l3B8B;!d7Cf113l17BrB70s0t3CB3v19;t4DC2;b3r151u1CE;i846;!s0tF4y0;k1t1;i44El118r21Bw38;!a326Fd2F53e3845g216i85m119r36C7s0u2885;c77d1z191;i14D;!eEiEs0;iCDl5D;!a39Ce17i3Ds0y0;i48E5;e3A58;d3m1;!d0r2Fs0y0;a1E6A;!l0n3s0;h300A;rCB2;!a962e470Fi36B1l24Bn22o28s0u4Ey0;aBAo177r39F;a1054;!e1B65i1B51s0;!e36i2C1l7;!a8e4i2D4s0;!a472Fe11F7i2567p4C54s1Ft4279;z116;b4Dd1r6DAu2B3z3F4;aA4e4i41BEl44;i264l3206n61Dp105Br35BD;n16Ep35;!g1032m17D3s0;t4562uEz3;!e4i19F1o29s0;a347c4E23d429f8i1CEl1FDFn178r147u40BCw9;e0i3Fo29;d3EB;!a45FCe872i3002s0y0;e1FD7z2C28;!eEf37g0s0;e309i6o17;a0c0n0;!d0i6r1s0y0;e19A2f1260t2D04;i2B2s3u5;eAg16i6;!d8Ai1E8s0;r24C;!d0m1r2Fs0;b112f8Bn316CpB;!b1D1e455f1CD5h1B25i398Am2Eo4140s0y37DE;!e15i66l3A0s0y0;!b4CBd226e15f1B47g39Eh3EC3i3D7j914l6B4n0o46Cp3A2s398By0z4FC;iE6r7CAu59;nFt3;e2A5iAC0o2D7B;!e0l0t19;d185E;b1Cn1ADDt485D;r50;a4AD7e1F32hF8i4EE;s8AwA1;e5n2pEB;m0r3;!b7s0;o408;!e67i509;a556e761;c32e0i211l3799m47A4n300Er1t3156wB4C;l1n128Ep1;i8Fo3Cu0;a165e1;t15FE;e15i43o92y0;n206A;!e4i2FCl6Cs0;!a0e4AB2i21l2Cs0y0;a8EEi1Do4074;e9i2Bl44s0;a40g3CCnF;!a1s0y0;l6An34B;!l16;b7Br25t19;l3Cr1;vB0;a1e1t1CB5;l0n8t3;!e4065h18Ei4E27o9p74Cr115As0t329wB0;!e0r1t3;e23i6t1E8B;i77s4070tC23u351D;a9E3i4AFu45y64;!a15B9e4336h38i16F4s0t2621;b1Cl0n8;!e1939i4011k5Dl7n22s0;c34E5f50C4p2B16r2ECC;a32FeAi66o4116y0;eAi3A7y0;l20Dp1;!nF;lBr120;!nA29s0;g3DnD0r10AB;!g38C5rAAs0;k1B95t20E5;d1Au8F;a54Ce176B;aCi26D0o1;a270i4772o31u8C;!a4129e22E2i4EE0o4943s0uBv7Ay7C;!e1C3i6n3;e24f49EDv3D;f409C;!i50o124s0;a4CA1;nFs107;l7E6uB9;eED3i2By0;i3123l1E;c44gBr2CB;!d0e20EDr1;b1CgD6lA1Bn16B;e5Fi133m1En1Ep1Ey0;r4A13;!t377;h8n1E;c2CB5d1E7Al8D3m6C2p135s3028;tE71;!j101pABs680;e20D4uAD0;a1h1A;!l7n20DBr0s3E;aCl0;c535d1F4k2ACnBD;c94;!e5E5s0;h1l3;!aCi35u4E;!w1E0B;e9CAo5114u3DBC;d48n48r34t0x0;!c13Be1C3i21n3o3AFu4D;a16EDb485Ed4B44eA3f11EBg4BB7i56k4156l147Cm33F3n508Ap2E72r71Et17Dv2B;!eF19iC9o31rDDs0y0;l2ADy1;a277Ce4608i29C4o4828y0;!c4Fs0t1;d35nACE;a141Ee4C1Dh192Ei4ACBl38D7n1163o11F9p432Br3A15s13BCt12E6y282F;i30rEsEu12w27;!e79i6y0;r15C0t19;e2CF0;a40i0u5;e2C73;c0e24s8;e5B6;a30i3Fo29;a277d0r16;!d0i6m2En22r0s3E;a4F91e237Ai3C2Co1587u14;r415t188CvB;h173i4F6E;!a38EEb6BEc4079d22Ce2638g48ECi4670j1DB8k1247l1810m33D1o2BB5pA36q1434r1A20s4B9Bt3C9Dv49ACy4682z4F5C;e4i141Cy0;m38AB;t387;r3t1;!e4i21k28s0;l7F8;!e4iCCs0y0;uB7;l9Ay0;hAFA;a12D8e12i61l2670w66A;e37Ei66y0;a1b648;d48sE;s3z52;!d3138g1F0Bj39El3E5n3F9Cr1487u34C9;g195F;!e24i43lF4y0;i4A7r25C;n25r2C;a1FAF;g1F4;a4DD7c1407dBA2e1i254k5003m4DD5n2AACo2864r19ECs4DEAt1EBA;m1CC2n118;e4C66;d2180;a105e5;!o100;e1kAB1;a88i3A83o203Au346B;c87;eBE6iBCy0;u445;a92e12l48r6C;!a1o46s0;eAhFAi6;c28F2r2A20;a69oB7C;s3C;e2F89;s674;cB2tFBz92B;a57e17o98;s2CDC;l3F34;n28r0s8;e42i2By0;t1D9;!e42i2By0;d0n0r1s8;t3972;!r4B39;c3897d2Cg337As348t480Fx28C;!e12i91r7s0y0;!r29;c1n3r1s3DE;e19o7FBu3751;cD1l0n85;fB1l3n1;e3D01i2EC0;r2645;r21D2;c32g131;!d19Ai1k8F3t0;a2FDFcEi72An25o36sEu5;u57w1BE6;e3557i37F;a3FA0d2E29e1D7Bi3645o3E32s4263y4F7Dz89A;g163;!a3BbA1Cs0;e4BC;a3BeBi1;!a262Cb321e20C6h121i6D2l44o1Fr1403s41F4;d44g231s554v50A;i223E;a4E31;e0i21;e1A90iCCA;!c197g3s0;!b1AB;!a450Fd129g3299i3278o1659s0y0;s801;i132o22C5;!e224i3Bl7s0;c528d1030t4409;a2C8f24Ap3E7;aCi247nEo260E;!p11As0;zBE;!c9Cg2Ck47n89s0;r93C;o1A7E;s2F9D;!l2C2r142Ds0t5C;!e12i4AFl2Co71s0y64;!l3EEn464Dr0s0w169y0;!f1E3s157w121;eAE9i26A3;m4344;l7y0;!l7y0;rF3;l4E04r98C;i45F5;!e31D8l7n22t320;dCB;e17i43y0;a1A11d113e0f28m47t2BECv2C;l3Ar7;n3o36;e15F5h2212i4886lBo1DCBr22;e3A84i6;g41t3;e50uC;a42ABe88iBC9o1rD8zB4;c1Ce12;o10s19B3;!e1005g7Ar2B4Fs0;!i2C1l7;!e493Fi43l2A7s0;c2229mB7x1F;!i12r91Bs0;e3FC3i1823y0;b16e1;!d0n13Ar1s0;i2Bu412Ay0;a1C62d58e4D4Bi4AF5l43B3m362En4DABs31A1t2F41u4Ev21F4y64;o132;!o31;i12u28C;o2A5;!m41s0;c24F0f4318k1400lDD3p3EE0t3449;!r4s0;aD82c4BAEe23BDs466;i3Fl2A79mA3p45Cs1402t712;r2130;!e31i20s0;!d176e12Fi10D5s0y0;!a6i20o1D;!a4Be15i6s0y0;!a3AA3eAi23Ds0;e4uD;i4EFt248;o41B;!e4g0s0;b3E3;!e23i6p1744s60B;b1293cD9Ad2C95f42D9g490Ch47EFi18F0j955m3E7Dn4A61pF84sEB6t154u3F40v2A2Bw5F2y72D;b1448c4A4Ed3FDFf2A71g2A6k1F1Dm4018n3E48p2198r4DE1s3t2596;a4BFFo0u4E;oBC5;a2FC1e1383iC41l26BEo1DB3r11B6u35BA;a278Ee7BEi10EDl3EC9o36EArC52u48AD;!b934;!a1b4CBe638h10Ci204l496n22s0w55Ey0;e1i2Bo177y0;!e490i13s0;b7Bg223n1AF;i26;o1829;v191;eDk3l7;d0s0v3;b1Cr16;!b1F3d0s0;a2C0Ae1D9B;i3Cl1B06;o7E9;c93Ce67;a4A08i3F58;!f24Am1n372s2164tA95;!b101eC0i17Fl7n22p5E3s0wBF;cA1;!l477Cs432;a31AAe4A47i3B4Fu31E5;!eAh16Ci6y0;nAAD;!f183p5Dr1s0;!a10e390Ei6m4A06n2D90o4C22p189Cu1596;c21C3d83m4FB1p4615;a0e2B9i66k16CtDD;!a1EFe1l5Cn13D9s0t1;nC6;d167F;h7i13;e12nFo327;oD44u412;a500De4FE0g3i296k1m3E0y64;n26F8;a7Dt1;a6F9e362Fi4653;a4De6Ei21;c15Fn2sE;c11m1;!a39Ce2D5i3AAo12s0;i25nB;!e12Fr980s0;a346;t51E;a6Eb408Dc278Dd18B8e2881g2D28l1DmF0Dn1B35o492Bq30DsFE4t22AB;c4Fe12t3A;!i18o9Et158;k4628uF42;!e4FFEi204l7o1s3E5y0;n191t48;!g29BhEs0;!e533i43u49y0;!eC0i6s0y0;d0l1D8r113t1;a1o28;l21D;!m2A05r2913;s14t1;!nD5s0;!c0i1;a20e0;!e26i18s0;rD47;a1015b19F9c12CCd3F7Fe3CD5f906g4DCCh1i186Ej3Cl3C96m335Cn2983o28B5pBD8r2EA9s3069tBC4uD6Dv1609w3930x5135y3CA7z504E;s792;l16n1E;!a4Db4CBd226e15i6s949;n4062r132;!e15f37i43s0y0;n142;e3789i6lECEo1AACr22;c450k4699l1Dm2021n12BEp3BB6;!e4i6l4FCs0;!a1e4i6lBs0;s2C39;a1De23i6t8A;c32rB;n0t2D;!a30e4iF9o12s0;k1F6t2D8A;e3A05i6;!b62e12fB5i21s0t0;p76;a481De23i3025l3B8;d3Cn1;i10l2C;e5s107;b453An25;d213;!aCeDs0u912;o4A5F;c36A8d0f14B1g336l1o2884s1E7Ct58x5E;t5A6;i435F;!n155t4F;eCFi2EB;!e4BABi6s0y0;d4Fs0;a215;b0r32;t6CC;i204y0;n5F1s53;i825y0;!e67i21k9B;s269Az6D8;!d7Ag44s0;mA3s7F7;i257;g1611;a274Ce1BB6i31D1o4E5Eu4895;!e5tB06;c21DCg690i15Bl437Bm18Ep221r2D3Ds86Bt4AC6x372C;a20e30;l48t39;b7BnF;a449Ac3FEEd1D7Ce1FC4m265n4E64sBF7tB82u2AB1w16x3928y28;q4774;e4432;!e23f14Fi49DCs0t1752y0;a0c0s3u14z3;t494;o4206;g2Bx0;g1Fx0;i0oFCu5;g129;lCn3s11;!o9y0;l3F3;!e15f37i5101l22r3962s0y0;!a4Db101e4i21s0;nD3p49D0;!a1304e4837i19B4m2Eo71s1C9u9B4y939;s60E;n182ArEs1EA;a2E63b3124c3AA6d2784n4E66o1FADr3DF8s3ECFt2541u1FCFx445D;a23B7i2350u3F9B;o3BB;n2E3s11;h70B;e3657g231nCC4o1FFrE07;a1e25ABi3B65l3947o1r148Fu1A;!a490Bc1EE1d33CBeBgD97i2020k11CEs26C0t47uEE;e23i6p5C;i4m1An1;!a3754e505Fh38FFi1307n76o1E9s3496t3B9Cy0;e11Ci34B;a44F2e56B;l16r1E;l1Er16;e10Ei3By0;c3D02e1i18l39C3n22o2C3sBy0;!e3Di4659s0;e40i27y0;!a3B6Fe2FA2i87Br2CC0s0v2DF9;b4808;!i31s1F;m8B;e10El7;c4AwE0;p75B;a4557e1i1F8Fr1A;!b31Dc26FCf1179g1hA3k2B8l28n3CC8p135r4807s34A2t1ED9v53Ez2C;!a4Be4i6m2Es0;a20BFcF16d4A0Ce378Af2E20g1i4CCCl7m13BFn3770s2C0Dt39DF;a0f2B6t98F;a3Ch4C98i6E2k17Do4F2Et1A3C;a1A7e4i6;e189i285;!l1r1s0t38FC;aCi2By0;a33AFe5A2i20o358u1803;a2202e104i3F73o71u441y0;aDeECi9;!b8F9s0;n7A2;!n83s0u5;a2902h3835o3C64r211Du15A6;eEo10y0;n195;u12A;f1A;r1y0;!h1776s0;a6Eo1;e40i1E8o9E;eAi6t0;!a441Ae72Bi3n0s466;a2Ad0e4;z2754;!e15i1EB5s0;a4AAA;n118w1;dB0q4A6r1E28;!b3199c1Ae1g7Ch1s12D6t65Fu2D3v3AE0;!a16Fp659s0t184D;n8r39;lB25n1F1o3BCr4880;l90D;dBs3u256;cD3;!a6F;r58t3u168;k499m28p28;e2F9Eo117r4C;a21E1e0i3204o4C6u2AA;n76Et0;!e4i6lCEs0w80;h83i13y0;!a34d2BAFn1E19s0;!l2Cr27As0;!e15Ai6l7n22;!r11As0;n62r84u6Ex2BE4;a480;l87r11C5;!e7DDs0;!i7Ds0;a30e2448l147t248w28;!s0tB72y0;!m2En0s0;iADBoC;!c6As0;!a20e31s0;d0s0v19;a1De23i3C2o12;!d0l0s0;d0l0s0;!e104i17Fo2858s251t0;e3841;b89l2774;n1sC1;l2A1A;e1Bn2oE4t3;e4666i7D;e1Bn289s27E;!a1A7e2AF1i66o71s0y0;!b111Ef3800l22m61s1C9;gAAEx1F;i4A54y0;!a92e67f37i21l23D7o0;a49F1i284o3AD3;a35C9b3C18c4705d1EA3e1i67Dk1l41B5m2AD9n364Fo3AA8p1657r1110s3155tC01u1A21;n120r3BB2uD;l4FBAo12A;l49C3n3B8Fo1CCCs3A9Bt16C2;c3Di16B;e305;e18Ci3A48;r679;e4761i6;l2ED8;!e24i3B5Co12u2729;w8B;e5i4F0;i4A4l1n1At3;a12i4C78;i8Br7A5;a3388e1080i4495o455Fu1E22y0;!i2F5D;!a2DD7d2FECe39CEf0i534lB9Cn43B4p1r58s47E6;eEr198;!e4i4A28l7s0;a1E52e2073i1992o1ACEuE67yC1D;c19eACm19nEs191;r36BA;u7D;!a4De4i574oB10s0;d3A30e34f1331g2CF2i1A1l2C41o412pB;aEe15i1B89;n37D3;l14By1C;!eAi6r1Es0v19;a2A75b3106c2D2AdDB0eECFf24C5h4C20i47C4j279Bk40DCl479Em2063n1A36o493Dp22E1q2A68r2B1Bt26A5u3C02v18CFw392Ey12D9;a1d1i2By0;d39FAr1t38E9;a4Ce1358i3257k120o9Es452t113y0;e51EiEEAy0;a1e5CCo735;!a4Dc1E4e4f37i6D2l211Bm631r1C5s4514w293Fy0;a147l3;!b2A1e1l7m192Bn22oE7p1929;!i31A7l7s0;e208i6;!b3260c3E86d3819e4B18i4E5Fl473m23D4n2B1Eo2835p8A7r3Ds1FB0t4E1x1Fz478E;c18eA2l7;!f17Ag69EsF0;!b14Fe4iC9s0y0;g182l20D;e104i43y0;!c341Df37m2C4r0s8;i3Dt7B;!l6Cs0t1A3;k67A;t95Az1A;!a1m56t3;k42;b46Ad2B4;e2627i16B;d1Ei6mE2n1;a4Be15iAD;e1ECi204;n2t11;a490l4;i4m1;r0y0;!gABs0;!c243d0k1p28r1FC1s52t2DBwB35;c4231e784g3798m2E76n35A4p507BrBEEsAF8t15CEv468x1F;a36e12rD2;a3F7eAi5A0o29u34;a1Ci1BE;!i4547s0;a3E9e6E5i6;r652;!d0l1r1y0;h116o48F;d4543;!a36n319r1099s0;n190D;!b121cAE6d25C2e38E2h899i86j21Al3A73m2Er2Cs277Bw4E53;v2D;i2o2;!e2D5o12s0;u45D;!e0r78;a75e33;!aCe33;e0r7;!e15i35E3o12Ds0;c54Ak28m1;!b39Dc629e31A3fC3h3EDi29CCm2Eo1242p3A00r2D18s0u2DC5;!a20i3Fl7;!e24iBCu3AB7y0;a1E67e201o28C;!a6DFe43BCi3EADo1t1u4D6A;d2546n1;a11E4e448Bh1794i169Ey0;o4680;d38e209i3168tByB46zB;a1EC7e2D0Cl4ABo48A9;g5BsC1t2D;a1EDe208i2AF5o42A8u4E;l22F;!l555;c6A6;l418n4ED4r1;e12Fi1AD5;!a7FeAi6s0;a3146e1u34;a51e1nFo10;!eAi27y0;!d432r1A98s332FtE44;!e212i6s0;a3D1b1e1BA6i6lF6nF6p1;a4499;i13o36;eDi13;p173t2C12;!d6B8e0g2D5Ck2284n7Cs22F9;aF44e337Ei1190o46F2u1353y1DCE;a4Co57;!c197s0t8AE;iA3E;e5n2s11t3;b3514;eDn1;b1Cl143n337r1t19;!i4m18s0;k19tEF;n3Ar32;b4843;e1Bl1nF;d2953;o39D0;!fB5l19Es0;!a44Ab3DBe4C11i21s0;l4n4;n6F6t1;o2277;aCt1;iFFo95;aCd28e0n23C9t4B3;a3F0Ci234Co41FE;a233t3u14;c699;r74A;!a2009d2530g129i4D4oECBs0;c12D5d2E5F;e0i14;a49o2A3uC;a2534;m5BvCE;a1c1Ak7DA;c145m29;a1iAE;e1Do38A;!c20D8l57sC7;a2E5c4A4Bd4F5n2o4C51p1D49s3EDCu14x1F;a2BDAc0nBo4B1s3682z3C;i2BoF2u5y0;!o810s0;e1DsA3t7D3z3A80;!e42i2BlBs0y0;b3e24v3;!r4121z87;!aCk7s0;!aA4eC0i86n22s0y0;aE9e180Ai3777l1D74o2061r26Cu2C5F;!eAg5Fi6s0;l1u32;k16m1En0t197;a0c0u14;!e25s0t20;e12h112AiCu49;a9d355n0r3381;aB8i47Ao5BE;l1o29tE0;d0l1D8r28;cF4d27;!b3Cm3Cs0;r4290;i14o6B;!i8E4o35s0;o4A2t518;sEt19A5;c28D0;a1i3F60o2CD4;!bB4Ec2595e15i435l2640r1AF3s3A88w4FAFy0;aCo1;a1oC;l1D0;e177i2A06;!i2C6s0;c1n2s99;h488D;h27lF4;iCw0;eDr1397;eC4Ci3Ft1C;!e0l76s63B;!l138s0t1;c9B3l43D7n6E3r161s3744tAA1uBA;r1DE;!b1F3e15i43l198s0y0;!a7Fe2A01h2702l97Ao41B0r602s0u1B71;e46B8;a28C0e3074i28E2oD5ErEFDu5;l23E2;!b367e15i6l22s0;!c35C4d1484f3A2Fg32Bl4443m6B8n3BE1pB4Ar1s292Fz711;a4F13e262i6o71;c46BAd4F63e43DCg4CA8i4E59s0t1785y64;l1nF;d29B0e23i4F9Dk4C8Bl2C7Dn12Dr2FEt3704y0;o9t47;d58lEEn3E76z3C;!aDEiF1m2Ep5D;aAC9e5s14;!m14B3p21Es0;aCc4CBFdFBe2961f30ABg5127k3637l2C82n4897r2DB5t2BD4v3F4D;cEe10g1E10t1;d1DB;!t19BE;!i3BoAC7;!a51e15i3728o2F9s0y3D2E;e3BF1i13;r2D0AuD;a1e15i21;e15h4EC0i66lBy0;a4De1447i5DFo1y0;!iAEEl38s0;!bB0fB5g35ADl926m2Es0;!d0n33Fs0;!a1A85e47F2g308Cs0uB;b1CfBFl3679n2o10;aCi5;!d0fC3r1C6s0w1BCy1;aDEoE9;f29F8;aEA2e2C76h4EC5i19A3o3BD1u4744;v57B;y3BD;d17B9e0k3664l577m2800n0r4812sEDEt3DB4;d0l1r1s8;a39Bi3ABDo46u441;!n1p9Ds0;e5y34;l4F09m6FrE;a1F63e5i1543o41ED;!a4976e103h28i4BC8l38o3A92s0t4B9Au1;a1444i34D2o3634r539;d1E3D;!a252;e0oD;!e256p4C;t7E1;!e4i6l28nA4Bp47s0y0;!a833e2B2h1F7Al50EoA99s0;l4F68n1;a2CCoC4;lA50;d63g127l117nD1r2E4t44;!i73o1900y0;l76s1F;!a37FFeCFi1B8Do29s0u14;iA43;!a8A6e5D4i1F5Dt0;i6o1C80;m1An1A;!a121Ae4631i26F4o14D2s0;e4288i171D;!n3D0s0y9A;aAFFc58e2748h3B1k29F1o386Eu21A7y90E;!a3A6b181e15i6m2Es0w169;e12f38rB;!aC5e4190fB5i3Bl22s0y0;nBv3;!l39s0t1;!s432;!d0l2Fn284s4F62;lB25oD2Br184;hA53;!g1EhEs0;f444D;b50C9c2E0d2E6El2E2Dn1r1;!e39E5iB;u1D4;o108;!d32El0;aFD5e1B77i204FoE6Fu4A0By33B2;d3C75k1l2167m28p136t1;!e4f37i6s1219y0;!e5E5s0y0;a1DgC2s27E;!o731s0;!aBF5bBe5B1f81Bm13CEo1E9p28B2s0;a39ECi4ADBo4907v22C;b1g1C6k65Cl28p21E;e10i329Ep3D2BtC1u1F12;gD8;!e4s0u5y0;t3D;n2s11t3;!c19EEd0s0t1;c6AEn92E;!h2ACs0tAB;n1s3z3;e18i0u5;!r1Es0v19;!a3039e1753hBBCi3F31o3363r4493s0t4289w45E6;nFu2B1;a17i33E1o3680;!a30b29C0e0m4F1o4F4Ap47s0;i4C7Do46;!d340Cg176;l1y1;n382C;t1C12;!t10A;c1eDl3;a1CE8;!e0t1;i2389;a105n1rBs35t3;l1n28;!b7Bt1B6;d28p362r28;e1Bn2o10;n1CA1t0;i3D3A;r3A5;l1CFAt1C;c173d3CB;!e4i6l58s0uC;c2A35;g38n1343;a1eAi6;a1e109o139t1;r3FEA;c3iC;!a75lB;!r1B0s0;a388Ei2B49;!aB9Ee6Ei3A0Do56s0;c93h344s7;!s0wA7;!a4217e14FDi3392l744n38o3D92s0u49w80yB46;a16Bi3B;i742;!a45c2D22e28EBs0tEC3;m2725;e0h0m0t0;d5Ce168gC53o396B;i2363;f1v19;d95;a50i31o34;c63v62;c0o29u14;!d0i9s0;a4FD6i2EB5;a0c1;c6BAd1B7m3F09;!aBEeAEFh8C2;f108g19rEt19;!e15i6s680y0;eBAoC5;xB;rD79;nD46;!a513Bc1A0Ce2143h18Ei1947o39FFt0u34;o10p3C;f1456t47;uAFE;h222t38;!gBiA7Cl668n47r1CACs0t566;c17Er4F34;u3BDB;!a339e15i3365n202Cs0;a946o29;e2C80i2117;u3606;m0t8A0;!gABs0uA88;e9Bi395uE;e2B4i79Co1984;!g55;g55;!l0r7t3;a934e1iAF2r8Bt1558u304;l0r7t3;!e0l3A9F;!l1Dn24CrACs0t1;t4FC7;e2341;l48E;a124;!e40E0i2891r37A3;i11B1;!hEBo6F;!a75d412Di34F8m115n48C3s217t4F87;r380E;rF8;!e15i6k5Ds0;e250Do1AD;!a2ADBc2359d3122g4BDBi3EA9kB80n15DFs1A0tCF6y0;t290E;aE9iD4;!d34Ae4F3fC3h437Fi2AF0p1E8As4CBBt16Cw1FFA;e177B;g24E8;n8r480;c1eB3n2;sBE;!a273e26h24D2i226El27o3F2Ar58sB77u10;a1s0;n1BF3;t129;aEF1;e12o260C;d537;!a4Be21Ci23Cl7s0t0y0;a88i31;i21o135u4;e2E8Fn2;dF4;!d0e1n0r8Ds0;!i66s0y0;r9w1569;a10c35n6D;l1967;b7Bl948n8t4E8;!eAs0y0;!aCo9s0;!b15A5l112s0;!a15Ee4i6s0;a43A2b5149e1CCAh18C5i363En1F17o5147p81Br3F59u2B6Cy359Bz4CB2;!a13EEe24iC9m62u1D3y0;d1m1o3B;oA11;a3BFA;!b4554d3027h183i6lBB6m2En22r1s294Ft2Fw84Az434;!p2D2s0;c128d392Fl1211n248Bo10;e2F25;a24FD;eAi6t1;i1o9;i9o1;e98iF1;d0g1;e5EF;i20A9;n428;!r1s1Fz1F;a1D5Ce177i12D2lB;!c690t38;e5oFC;n1D2r5A;a1AFCb208Ad2402e212f39FBg142Cl464Bm5118n29B4o1677p0r10DDs3046t3FBBu2F8Fv3238z3F06;a1D12i2B2B;h9D1;m5EnEs35;sAC1t1;eDn2o9;c128n179;e1BnFo9;!d464h112s0;lD2;e1Dr43F6;e23i8ABt5A6;l55n2D9Ar50s50B7t447CzFF;!l0n8r7;e177i4D02;l8EF;c32k1n1;h1B1;!e5k151F;a2215bB0cB2g298i2806l1F4En1AFp699r38E7s324Dt274Ev43FCz272F;a15Ed5BeAi21;h3Ct439E;a1A72;a48C;!a11dABs0;l143r2FF6u40E;y88;e1Di1D;!e46Fi91y0;u2ED;!a4BeC0i86p1F3s0;!c3C0s0t4660;!iE88s0y0;e12g0;a413Bd2E25e2ED6h12EEi3F6Ej33EDl112m3521n4040o30E5p2D53r16F9s3502u13D1v4D20w9Ay357Cz2D12;l216;!c491d0l7m6EBn1329r163s0u4E;l0r2Ft3;eAi3F74;!c7s0t19C;!e65Ai8Es0y0;e7A6i20o29;!r30D7;l64pCEy0;r62u1EBF;l1Am29r4Ct10A;!e0l43F2s0;!e4i43lF4s1Fy0;k4CA0;!e4i6l48s0y0;a41F5e3F5Ci4A3D;i9u14;a42f2F4El27Bt26B6;c3E3;a10CE;!e15i830s0y0;n3820;!e1h78i47E9l76r22s0u1E2Ey44B;l2B8n0s259;e23i6tC03;o1EF;o6E7;l25CFm2F51oAFuE6;e5l486En2o10s68DvB;b1Cf3AB;a3E6Ce2442f1CA9h4F61i47E4l3190n41C1o1DEBr3F91s47D1t2690u2C78y217Ez8C6;m1t70;m70t1;e60;d3g298m4CDzA3;a3F8e4240i4D87o18BCyA8B;p18;!aD92c2E14e35F8g27F3h27i30A9l1o48FBs0t48AEu3EC0;d23E1;!a352e3EEFi6l44s0y0;g4FCn38;a2203e67m1zA3;h1C2o71;r16t1;c19F;v21D;l1D15s5Et2377;!a2F9Fo14;i6nB;!a4Bp1Es0;!d0p34AEs0;a6AC;b1B27;!e15i1A49l24Bo12s0;!i2288o4F66s0u41F2;e0o81E;e1Di31;a10l77;!eA3Ci21l76s0w130y0;!m2Eo6Ft19A;gF0;t25D;f144;e4D83;g7Ah1lDB3s157;!e12Eh10Cm162s0w9A;!e12r7s0;k8Dm39;f2D;a42o1B86;!iBl7s0y0;k295A;!i2Bl7s0y0;fE;!e4i6s0t16;p551;s4F;i6o6;cBi56t38E;n25t1;aBB3i3891;b7Bl3n2o10;!bC0Dc5D0d0g280i6k2Fp0s52z38;e31r1A;c1E;!a646e256i3949y0;b4080o48C6p177C;i1A34y0;!t40;a375Fe2565i547o143Du1D86;c0d1lA0s34BB;e40A4i2DAAo10;n4A6;n540;z78;!nFp1E;!l2B64s0;e347B;!h195r269;u15Ev62w127;n88;!c49g19s0;!a532d0n60s0w16;d572;a0c3D;e912;e33p8;r246;l3Ct1;!e0i20;e0i20;!a4414e4i6s0;!e4i6l19s0y0;e17i8;a40e272i10;!pDBs0;g19p16;!eEAl7n2s0;k0m0t0;!n3Cs0;e30Eo4C0;!m7AsC6C;c4Al143nD0;e30v55x1F;n136;a1E48b3092c4585d3CC0e25D7f34ADgC43h299Fi3C28j1680k45EDl3174m27B2n498Cp3E41qFC4r1576s4C33t3A52uA5Ev1FA0w1AECy2661z34EE;e382iBCy0;a54Ce89i1D;s2D1;m14B;c3151eA61o33CCp8BBt393B;dBe5nB;!g1n38;u90A;t470C;e1g61;f683l1An483s1F;i77o29;h43C8;e381nB0;e1o4F1B;a4D85eC28i4867o3778r2343u4C02y7A;eCB3;!a10i272s0;i31o1C61;!a1062b1841c4BCBd62e2695f4D0Di2E7Dl426m631o168p20A2s0u6EE;c433g1A;a30i1F2y0;a12ED;!c4An2059;!iB20l7;!s0t128;!b11A0i1EABr990s0;aCn3;!d3308e1h3F4El78n22r0s3Ex1F;oEx68;!c219d42A0n2497s0t0;s35AB;s70E;g2A1hE;o2A44s3E3Fu307;eA7Ch3FEB;d17Bt0;y39;a20i7D;c3665r78;!i2697o29E9s0;!i10Fo29;!l128tF8;aDEe4CF;l2D6F;!i597y0;!e4i6l2Cs4E6;n5EC;!e15iC9s0y0;l1m1;n1s447E;uDFC;!a3FF9e4h18BDi6l87o4C87s0y43B;e166iD6B;!a3FB9d136i6A7l229s0t1;!e395Dl7s0;!i91y0;g297lA8m265sEt37D;e5f7;d3334s1F;dBn1A;!c1;i1386t4925;e2D93;!b61Ed58f1909g182h424i20k1l22m25EEn27DAp3324r40Cs2685t38w8A2y20D;d0r25D;a3F83e189i48C5o0;!d0e0s0t0;!e17i96l7r7s0;!rF3Ds0t1F1C;l3m1;d0r5Ft0;b2ClE6o4FD1p2Ct3104u3042y3D;d1l4A1s1Ft2A9;d80;eAs0;a1DcE;a4398c2471d1E2De4E13g2FFBh496Fi4FB7l42A6nEA0r17CCs130Bt1561x3A27;e5g135j219Cr64Fs275Dt1CDu894v6B3;e15i190l2Cy0;eAi45F6y0;k19lACy16;e201i1;n1o9F6;a332Ee201Bi3838u14y64;!a48Bt1D6;!s0y9A;a1o8;!t491B;e2822;!e12h156i63As0y0;!c121e8Co4EADr89s0;h0k0;!a4De15i2998l22s0u5y0;!d4F04f3CF9gBi4B43l2C5m6D0n2301p45Cr1642s4109t226w3F39;!k5DnF6t58w2D8;t326E;!a270e1E5i3071oB41u3CCD;!a3D1Bd0f37l6Cm2En1r1s0;e15i2208lBo0u3By64;a65BeAg1C37i32C4k306o4883u34;!i27o6y0;!a2C31b2561e49ABhEDi1299o666s0;!eAi66s0y0;!s671t2D;o487;a4910e1E7Fi2465l22Cm1562n1AD4o670r1DBBt173u441v1001;a1e15i6l2Cy0;t1779;d0n1A3r16;a31Ae1oE7;l54E;!p2466s0t38;d70g35;a21e1;eE9l221A;a504e9o50;f0n0;a3088;!b181c17Ae24g6BBh7D4i2A8l22m2Ep431rC79y0;!o10p3F0Es0;aEF7b2BEBc40DAd4DB6e1613f3EC4g42DEiD08j9E1k2C25l3813m1ED1n2923p486Aq1r2972s4F2At498Bz33BC;n2r7;!a9DFe3D21i20F6s0u32BA;!r195s0;g63;!g0h613k1103l220n770s0;d3l3p3;b1Ct15B;o12p38;p213;aDAe4i6;eAf313Ei6;k1m85r2022sA27t2482;mFC;n0r58s0t1;r171;!h3;d5AnDDs2792t0w1911;l1CEr4844s0t0;m18n0;aD63b1DCDi355Fm1AD0p35AFs3A36;a32E4b3D06d2937e4EAEh3E05i2E4Bj13B1l24EEn2E93o465Fr19F5s4A0Au3AF4vB60y4100;e1DD4r3A11u901;a7E5oCB;!n21Ds0;t381B;b3980c311Cd2AB7g38F1l348Cm1880n39D4p3726r182Ds2F1Ft2B6Ax56z2E98;g239Eh388D;e4k39;a3s0;a51e15i86;e2287i44A0;a3D86c3BBDd2C29e242EfAE3g287Ci6o4A30r36D9t457A;s3t5B;d406Fn154sEt1;a4E1Fc2E47e8BCn1Ao786t62u52C;!l3256s0t391;l4712s2B92t4AE3;g20F8n3F11;oFC;!e15f37i6s0t27y0;a9e98u10;c2676f780sE;a174e3E03u3D;!d5B;k1Et16;n2t3B0E;oFu31;i4FA0n3D32uC5;!e16B8i6;i89B;!e4l30C8o1s0;!e4iBCl76o29s0y0;e467;m114;aF70c59Ed13F0eC12f335Bg218Cj5AlEE4n2E19o1416p2797r4BAFt1C1Fu1288v126Aw4265yF3;b1CgBr2FD;i12Bn0t2C;l4E1E;e678;!a4093c2C3Dd447De3084f4098g2E26h0i4496kCB9l22n1E39o2368s284Ft129u1747;!a3C9Be4C5g44i6F8k29BBl7CoF2r3733s48B4t137;!a1BF5e24iB;d3Ag5Bn1sE;!b7;!d17Dg2Cs0;!c2BB2e1h0k4B21;!c58s0t11D;eAi3DCy0;!d0p5s0;a42e4DE7i124oE6Cu1C90;!f37l22rA5s3590t2C18;b1Co246r1;!nF88s8;l3FFA;e512Bf58Dg338lE6n4F58p1Er2Cs5085t3EDFv2C;t50E9;a4E8Ec0;b1s1C8t16;d19gBr25tA1;d30F0;a4084eC5Ei299Do1334u2152y64;b3De1Bk4Cl7n2;o2E79;a9t1;!a4Be15i91s0y0;c2D62lEmF8Dr7;e1i28E;a124e17o51;b7BpE;e4i3Dl1Em1E;a54i51r1D6;w124;e1Bg97nF;!b58e4fB80i6k3975m28n2E32p2F0Br82As2AFAtE4Cv2B;a361i63o15Er4F29u50D4;a3EE;i3CDBy0;l9Br84t0;t3F3A;!e224l7s0;i55Fo517;a165i5BBo29;!o3Cs0;e29E;!d38l28s0;d81C;e330i1E1;n2s107;n1C1t1;!e1982i2267s0;c8r39tB;e149Fo23Eu17F9;!t474;d63pCEs4618t3B6v25FE;!r158;e110gBl500;!e4f29F5i6s0;a0o4882;!d0e13Fs0;c0f2D;!e15i6s0t1E;e17oA11;!a4A07e2C1Ci2C10s0u4014;e1923i43y0;r57F;n3Et3;!n8t3;c26El62;!d0e1oDr1s0t1;l2Cn89rE6tE90;a3C26e1i333u4E;r572;e447;!a726i8Es4F8t2103y0;e8i21;!i3FF8l9C8m39D7p305Fr3905s3EtBvBzB6;!e73FfC3i8C7r40Cw2F0y0;dB70e0n0;eAiDFu12;i3713oCyC;p36;k1n1;i4C16;bB;i1t7;!a3259e6A9i2A33o45E4r3721s0u14C5;k76;cBd2F29e18B1i3397l475Em2ABFo508Cp2FC3t1C6;a1e1g1o46;eDr3u1;g167r2077;a1lFDo3DD4;b1Cx5E;!a1028b317Ce15B2iC9l4889n195DpB0s14E3t1E7y0;!a96Ae4E77i1958l76s0y1EC;eB29i6;e31i4lE0o2C63;!a7FeCFi1252s1C9;!eDn22r40D6;e0i1Do10;a0iB9;i653;rD0B;a3B12d28e592i20DCt2AC;e46FBl37BD;a2C45;!aD3s0;e5122;c2At1;a38CC;!n282rE9;i1AEF;!a19B0e1A9Di31E2l346Do35B9r3AB1s0u4D72;!a20b1BAFc1338d2647fF5g40Ak5Dm4D09nFo10p2D8s3EF4u34v189E;aDEe3CADi31B7u2C;l106n2968;h3ACD;!a2EFb3599c229Dg3611k2C9l4B0Am2AFn4384p1109r1D60s2178tDE7v45A1;!a40e67i6s0;r3D0t184E;r3E7A;i2B2l12C;!b396c33FEj101lC8Fp394Ds2C9Ft0wBF;!hE1;a32Ei3Do0;!a7Fc128e15i21s0;b1Cp1;!a242e1A51m2Eo2A96r550s36CAtF83u1w169;!a30e23i6u49;!a3705b58Ac2504d8C1eDC7f17Ai3B2Dl184m2094o8C4p1B70r47FBs4A9Dt2408u5Dw2EA8y3332;a1172c1FDDfBFn40B;a20e3EF6y0;a45C9b2190d185f4EBk975m3D13oA78p2CD9;e5gC19l2AF4m626nBs159Dt3AD0;a1Di1D;!b3FDEc225f34CBhEDi1E8k5Dl220s41E;o4FDu92w1;!e4i6s0uE;!i270o1s0;o4D99;o93F;aED8e1092i343y0;aCi160m0o29;!c4163h4CCEs0t464;e82uDC;b7D6d17Bg1A77l4303n193Cr410Bs3C0Dt4CA6;a9i0u5;a1CD3i247;!b181d0g6BBl4FFAo1335r1s2253wA9Dy0;a834;!k1r1s3Et11;e143;eAE8;a3C03o6;!c58d84Ce0t4827;d0r1FF2;e5s0;e1s0;gE3;d9Bm1A;a1De45A7i3Du50y50;y2B4;i32EC;a2CCDo25CE;!e178n11As0;!a5cBe159s0;!a3FF0l4634o29s0t9B;i27o9Ey0;!e103h26B2i6s0t4ABD;a4A9Bb1F71e0l4400m134Fp123Br2086t475Bu1;e45AoEE;e402iC9y0;!n20Cr1DAs0;i147;i4m18s3u5;d9B5g49lFD3m738n3A57t33Cv13E7;!h2A0i172o413Ct2028;r43E3;c1n0;c0n1;!iBs0t1;u3C4;r0s8t7;!r0s8t7;i127l119;hBD4t2D;i25E;c32r3w16;!a174p1sF0t1w169y9A;a49C7i2Bo1811y0;a4D04i978u5;o3B57;a692;a1De23i317;m148sC1t2D;e8i1361o36;e1EAC;c11eA;aCe79n2;a3C45e17DBo21B4;a20e1o284;eD87;iAFlCr3;!d4B95m20B4n25F0p1084s0t2D;a1De15i6o12;!s1Ft1;g41lB;g245;eAi23D;l3C5Cn3r1E1Fs3EFt4821x2BFA;!b240d494Dg89s0w390;!d0s0x1F;eA63i73k3D84y64;!e15DiADs0y0;!a258iBs0;a44D9e4E7Ch16CDi26A9jC81o386Ar2098s39A2u149Bv3CA8wC7Ay48A7z4B66;b2A1FeD53i25k3B1Fo10C1qAB6r3EF7sF6;e34r48t3973;!e4h33DFiC9l22s0y0;a19D0;s14u1F7;a41C5i29ECo1D;oA96yFC3;c8g0;e2FAAi21;c58l3701t115F;!l1057m1n18r1F2Fs868;!b718c1CA6d4C15e1g3282i1ABFk3241l22m17ACn1CDCsEE6t20D0u3F5v165Bw3139x58y320z2A8C;i31oE7;e33C0i149AnBCE;a450Ce23i6;a3605eD6Ei3D10l24DFo1E24r22C1u3DD2;e1Bn218B;a373F;!e12n4458r29A4s217tD9Du48D;!d0r5s0;hF2;d19nEt391;g269;!g269;i4374;n4s11;!i2719s0;e2FB7;c65Fk8B;!l0s0t2D;e5h427Ci1D2B;gD9i22Bn1A;dBm22C7nBo8F;!a5tB9C;c2512e87AfF5gE1n1FA2v2B45x0;a0d21Bu14;aE53t1F6B;e45E0i22BFo3BDAu454B;i174t1F6;e12l1r1t19;a1e1o41C0;oAFt3;c5Cm11D;!cAC7;!s0t45C3;s0t16;!a4A12b61Ed3447e2814i6l2E0s0t11;!e4i27y0;e82i27y0;!e39D1l3o41s0;!e1m162s8;e4E84iCClBy0;a4DD8u45F;!c268Es0;t2Dx301;a0e74h1i11CoE7u295;e14i13;i5065;k1o0;c0k0;!c9Cd1CFk5s0z4D5A;a49F4e4201h323Ci6lC2Aq3108s2426t3A;z131;a7e0;b19g7;!e23i6o127;c35F6k0;s0v3;!a1e3FE0i2EF6oE68r16Cs0uD4y64;!g2FA6j454oEs7A9;!e594s0y0;u291;i7Do29;aC09;a8u11E1;!a4Db101e6DDi21l47n0s0;!b9Be4A76i18A4m1C5o9D7s53Eu2FF;c32k1l1;l28r1CFt19E;g132n0;!e0g19l0s0t66D;a442i10Fy0;a1e49AEi116EoF2;p230;l3n2o731;a4BDAc25F3d253Ce4174g175l28EEu36w1;b55;c87BnB7sEE0t57A;y12;c3AF3eAi6l4FE3n1Ar62s12B5v4124;!i1BAj10C0s0u1;u4F;c1E2;!a1s0t2F8uD32;!i27s0y0;d0nFp27;k3BB7;a4111n13A;l45B;!a21C0d21B6e1CDBg606i4C9Cn3DFEs3BEAt4A6Ez18;a4De4D3Bi343y0;tCD;aCe37Ai21;!e880i43y0;a4p1;!a4924c56e49C0hDF3i4916k5DEl67Fm2Eo1F8BpAC4sCF8t3CA1;!c24Fd8Ai96l1s4000;gBl0;e62A;o4F0A;n49E;n530p2D27r415s319xC1;a4890;!d0f37r1s0t0y1;!e5n3t0;y4622;n458;l0s1AEz6D8;c44l42Dm1;uED4;a1De23i2CE;c2An3;c4E29g4Ar31BC;n1o2A;w36F;cBg1;gBn1s178t60;e1o7FC;!a1o88s0;c484C;!c303Fe38E4h2AC5p2AEEs1522t350B;z4A7F;hA3;e1Dl2Cu20;!a11A4e1481i3AB9o10s0y0;rB4E;c182t3A;d0n1r7s0;eAi4DA1u2A66y64;e19i19;!l22nABs0t47;!c16F8e4i6s0;o39;!b101e4i21l37DCo6Es1DD3w3CAyBzDB;c32i4r48y1;a0c2Bo3C15;s4AC8;oEy36D;a58BeAi37BAt5A;c73A;tDA4;a3585e410Ai2384o3CB8u1FB4;dF0Ae34D6;d3E51e4632f8g2FD1h1An28F3oBADp2E06u4w52;a4De2455i44B5oDrB;!e924f37i1DDBm2Ey0;!e5z688;!h2FB6lBs0;k3s3;gE4l36nE8E;a3651i495Bo2838;n4E0B;!a4D8;m3F1Bo41Ft45EC;i2Bl48y0;n1pD5;u3072;p8D;!r1C8;r1C8;!iBCo46DFs0y0;!a4739d3869e1gC2i3B34n1F95o1DA4s3326t19EFu1D0Fy64;!c33D9e2191i19B7o2386t12E9;l1A6;l434D;e2F67s0;!a4Dd0r1s274;!a4F12e1BB7hCDEi3B27p214Ct2052u17B3y0;e4i86;!a18Fe3Di20s0;!n31s0;l29F;c257n1r284t2C;a16AEb1d0e318CmB5n198As134CtB47w2A18;o100yC4;!d16e4i6s0;a140l101o21Fr225;m1En355Dr38C0;i2Bo162y1;xF8;l0nACE;u6C;!o8;o18F;a180e5s282z19;aDd3oE;a110b2E23c35B4dEAFe290Bf3EECg2F38i269Fk4Al162Dm1DF9n2378p1F2Dr3250sC33t358B;h3FEq4CA4t0;a424Be1319o1E9yC;k19C;k19s379;aF1e9E6r453EuC5;!i3Fo29;y56;g0m434n267Br3C8F;n2525;l1n66F;g5Bs2C59;a18;m3E75;!a413b28ECd2BBEe1462fB5g3608i3A42l1FD2m1EEn258Bo5033p330Dr2002s0t21CDu4D75v4141;l45;y3718;m8BpD6r12F4;e0i27;a2C2Bu4E;!a3F7e15i2E6o9s0;c0e1Bn2s11;a165e399Ci20o3CED;r246BuE6;!d119l1n295C;g19n20CrE;o1s3DF;eEi31oC4;!b1ABm2Es0;o2F1E;!l3252o1r37Bs0;h2CA2n4B6Br4C1E;eAg97l84;p7A;e15i586;a1eEi935;e18i18;a2AcEl1D;!p61;c14A5g626l348En1B2ArE2Dt1B7A;d0f37;!e6CCi449Dl2Cs0;o275A;a289De1F85h4B1Ai3C74l38F9o3DE3r4EA5u230D;e17l1A;!e4iF9o8Cs0;i2740o1;wFD;e7i1DA;n4EFA;i1o3C;d70sEt2D;e23i21k1l19Ey0;a30Ci4;!a69d0k4387n1r1D6s0w1D4y1;lA0n2t3A49;d4FAr1;h1849;o1B0F;a15EcBe24g62s1F;a165i492Al1A;m1D5Dp115;a9u9;!e1o379D;oA2;!n63s20B3;m1An1C99;!t103B;!d0s0t15B;l45CDv6B0;!e5Bh5Fi2Bs0v3Cy0;dBl1CnFo10;!b32A6i4125lB6o3F38sA5F;!d0s0w4641y0;u2A;n161;m3C1;k5F4;a1F81e17F3h116o3216u17;aE8i111;!e4i6o28Cs0;!e37C2i1C51o8Fr467Es0;!o1535u12A;r3407;e6Ei4A26l44r33A5y69C;!e26C3i32C5l7n22s0t467B;!a41ABc3BFFe3633i15EBk0l43CDoB9pB3As0tE6EuD9Ev159E;gAD7m4F5En19A4r2539u12;!e4i25A6lF4s0y0;l1t3F;c8n2;gE0k1C;cCEn119pBq32A7sBDt3;!g4674l7n22s0;o488F;c324e2B3Ci71o7E2u2CF7;!d0l3461m1FF3s0;e4i60ElB6;!a120De1i13s0u64D;!e1Bf37i3Bl7;m4FA6;a117e1i7A4oE92u3B3;a4D3;!c19e0i10n3p4Cr55s0z749;!c0e1Bn3;e40i855y0;t4679;d0r1t20;s99z3;d38k144t38;!b31De73Fi343p171Aw34FEy0;mB7;g3Cn4;a260;!bBs0;k48sE;!k28r46C8s170Ft2FB2;d5D;!i661s0;e3AE3s1A0;e1hAFB;g20E0;i641;oCF5;z83;!a3EAAb3A8Bc368Dd243Be24E3fD40g1B21h40FFiEE7j7EFl281Bm3F2Bn11D5o1910p2CD0qAE3r1C34s191Et4964v3CB1w3018x4E6y2ACz4C36;a4Ce12A3i18B7;a1A;i4FBEo4E3y0;r151;a3A8Ee9;d0e4t0;d27n39;aA4e23i6;aEhE;!i41l53s0;v363w40A;!e22B8i21k5DlE1m2197n1r734s46CFt4A;!e3F68;!rF0B;e4i6oC6;l717p3B9Er1A9B;t233B;a137e23i6;!e10Ep1Es0;bEA8c2E60d4E8De155Cg3FCFh4EBDi131Dj407Bk2F35l14B9m4D2En1717o4AC5p428Fr101Cs3D99t43A6u1410vC7Bw415Fx14E6y2B48z2326;b173Dd121g20AlF32n3323r2FE2sC7v225;i4y1;a455Ae4756i21;m115u4E;!d3Ar25As0;cEFs11;c3Ce1Bl7m19nFt1C;d0e13Fy28;o310;a43C6e40Ei1777o46;!b1D7d0e34l25m1s0wED;aC42l3B16n1D3Fo3EA5s1F;b4BDF;d7t11;!g4EA7s0;a9E3e8i1688;!m3359p4092s0wA7;e1t18;h11;!eC0f14Fi21l7n22sA0CtE64;e49A8;b1ECDf108g34E2kC07l269Em413An196Ep1610r3113t26F7z18CD;nE56s27E;!e15iF9o12s0;o4F18;e5i23A4k1;!a4De3F30i6;i211Ek5Dl827pBr48DAs3DAD;!e5BEr27D;a3C3Be1F61i4052o4CFBu2928;c36Cd4235g2F6lA8n37Dr16C7s13FAw1;e15iADl170;!a34u34;!l1s0t88w1;o9F8;c28A8f4C6Cg2710h184l2ACAm3357n22s1AEv990;iCCo6y0;d21Bk1l125Fn163Cs0t1DBE;!m2Eo54s0;!aAFf44F6m2A2s0t1CD;aCE2e2387i4F3Ao3EE4y0;iB90;i14AF;!i110;!e43D8l44;!nE;n18r1;aFy0;!c47E1h4960i3275p28ABt5F7;!a328Bc3d1150e4BD3g3919i7Dl22n1CA4o1ABEs42F0t27B;e4EE;n2594;a3688i160o29;a127c13BiC;!e4i0l442Du22Ey171;!d0r1s0t20;lA8m1;fBFo1F9v35BC;aCi4FAB;o487E;e1Bl7n22s13Ct554;c21DBm3CBD;cEx1E;d4Bi22By3D;c1Cf7n62Do10;aF3l1C;!aCi485Bs0;!aCi1C88;a4C2Db10C4d85e342Cg0i0n2F6Dy28;a25A5e3B71i6o1E6Eu315;!e4l7n1s0;m3E0p113;!r7t19;e1i568;!b6DCe22AiBCl7Cs0y0;c8A4m503Bs3F62;l38C2;a51e51;d793eAl20E7m58Dn1C7Ar7At1CE;e2768h36BDi4E87k24E6o2D8Dt21D6y0;l2FDAn0r11A6;e3714i86;g3B0i4t1;l1An3C52r30B;!lBs1C9;e24t1B1;a51o1C;f2E9B;c9Cd338;!gA3l5012p5C2s21A8x2083;e5n2u5;eAh1Ei6;o57DuE;!c17Ad0s53B;a1CB4e3D78i4233o3607y0;e6Eh241o42C9;nEp16r36;!e1Bi3Fl7s0;h1Fs1B7;f1nF;!l1Eo576s0;r61;n19C;!e490s0;f7n2s3z3;!d0n39r1s0;aD31e52o4BE3;aDe9n8;!e67nF;a75i247u14;a1E90eACi4F8Bu1134;tEB;!tEB;t20y16;!c11t7;h3757;o4145s2C;n16o10;a283t4F9;r84;!r7Cs0;!k28l3466p3FB1s0;aCe23i6y0;e721;i1AtFB;e4i11Co36;!l3E93;f17E0iD07o29;aD9b29f1493u34v19F;a2FF9b4A88c2999d4DFe3AADg3D1Fi25C4m8Bn425Eo3769s4E50t2EAAu283Ev1A;d0e1y1;d3Dk53lA8m48EBr4BFCsC1uC0Fw0;u64D;c0nDC8sA20;d1n27;!h68t341;k3sEv3;a180r1;i1EFDy2C02;iC40;a4e4;c3A19e5k4C9m38n3B09oEs1F;nFt0;c9Cd4A2Dk21C7m28s84t244E;!e5z3169;i4CB8;cC8;a1o230;a49DAe168;!d0hEDn22r1s70C;c32w16;b2EEBc3BACi36k1l120m3n512Fp2B38r1D41;!s2CA;m3Cz1974;a4Ai34;e12i21;a16F;c158d39BDg440Cl168Dn2F0Ds5148t36A3z89;a177e8F;n2CB;!l7r0s8t16E;iA49y0;a1n3;c1f7nBo1D;!g1k1E;!b34Ep119s0;!b1Cn70s0;!eC0i6s0;cBl120r4694;aDi0oE7u5;!e0m2456r2A0;!d93i6k2Fl1p501As14C6;c197t1;oDF4;e23i4CE;e56B;bDCd0x1F;!b61Ee869gE9Bh2C92l8ACm3760pA3s3BE8t389w1DEE;!eDl7n2s0;c128m23EBn3ACo1F9s3FBu5v9AE;k3F9m10;i1FE0;!aCe4l7s0;a393Fi1078;n5EF;e15i7EBy0;a9s3z3;!d206Fs0;a395i2E5;!f1Cn1s0u34;e6EFi2951o1DF4y0;l1r18;!s0tFED;!cEd1ACi8s0;e24n2s11;d0l0r1s0;d241mB;g0k0;e1i10;e5i1DF;h1E4u21EE;e0n2o46;c1538m42D0n2o1F9;c36C;a42i135D;!a4Be1F25f37i2B3Fl6Cs0y0;b171c2Ad1A8Be1f2Cg1B4Ai13C5kBm3247n2089p116Fs5t3D4Eu477Av40EBw4DE4y47;eAi91l19y0;e116Di8Ey0;gCB;a52o29;c2B53m6F7;t205;!aDE;a54o6B;a4ADE;u2BA6;i108Ey0;u2C8;o1r28;i77o9;!aF1e143i41C7k1o1;i6FDy0;l64n144p4796r2CC9t113;!s0v7;e98o10;!i0l11As0u5;e12Er22;!a4A0c35AAd24CFfDEg4FD8h4C7k587l43BBm45D3p47F6r1E7s331Ct4D1Cx128;a423o92;!l7s1;!i3Bs0y0;aCiB7;m609;!d0m2EsF0t1;s34t14E;i22BA;t78;e4C2;d0n16A;i2E62;a3Be3ED8i43EEo433B;c0d1s0;!c0d1s0;a6DeC;e5i5t2D;!a14D7d0e4B00f41B3iB90l2339n6Co1856p33Cs326t0;e5mA3nB;eCl1;!e4C14;c32sEz17C;!n92Cs0;g3s5B;aB9e17o6;!n1s1DDD;y4B;r1t5B;e283p3990t1;!d0l5Fs0;!i31m4032r1E15s767;!a174b87d36Ee12i17Fs308w9A;e67Ci6z17D;e1nFp1E;c35n2o10v3;a12e1;!a12e5;u459C;i1966;!b770s4DA7;!a4Be4iADs0;c21E0g167s0;!cB2d4903e7f39EDk1FAAl337Dn1pEF0r1DE6s1844t2FF5v4655;d0r7t1y16;e10E7;!d2A61g4BCAk5Dm8Bo9Es0;!e15i1D7As0y0;s4038;b47B0g28F5i4A6Ck320Cl1459n3999r3F77sBw6F3;l1nE;eAi6l4528t203B;cBC1iDt1F48;e0o29;a0e5u14;!e4i44E0s0y0;m0r17B;a9l1F0Dn353r1Ds4Ct4C8;l271;a150;r3A08;c393lA8;a0c0n2p4As3t3u14;o99;a35CCe3E58i2E33o2A16u1970y36BC;a25e10r43E9;!b44CAd56fB5g3706l76s0;e1q123;r546;!e0l1nEt3;a22E3e4559h3994i49AAo1AF4r1B6Eu1E09y2409;tFFz78;r7t1E;r78tB6;i65n2;!aA4e8B8i6s0;l438r3702;g1r148;!a2E88c4AF0e4678h3B9Bi4A04l2A6Cm622o34ECp35C0t2856u34w1731;!l3A03s0;n1t30B5;c4EEDm56n179t0v3;!a4Be15i6s0w80;i663;b102;!a140b101e3F1i21s0;!lF2n2ED9s2357;!o1E6;!a80Ee272Di336Do2E7Cs0u4Ey64;h35D6;a6AA;mF8n3372;c2AdB;tAB1;!e5i6n3t0;!a8BEc3528e6ABi1697nDDo431Ds893t32E2z3;!e4i1B3s25E2t13D;h171;o186y88;h68s68;!c243d38e0g2A9Ai709j18n738o1065sF6t4051;!e26s0t1;!d31A6e1632g711i1F8Cs1978u1;!s0u4Ey1;d1AsD3t46AC;k1r1;!a38DBe1s0t4DA;r83s2D66;iB3FuAB3;k7DApB4As7;pBt83;!d0l22r28s0;b1Ad28k28;n138;!d0s0u6AF;o2847;e2374oA5;dBt1;a10d9En2EA7s0;!d8Ae2F84l7s0;n24CC;h2A95;!p4765s0t0;f3D15;e6ECl325o177;a1D20i25l170o2E51u2D9;a14F0e2B55i4AFCoAA7r5Au1B97;!h1s141;!e1C3i6;nFu32;c15Fs503z19;aD9c15Fn2;a3A72d4B5i13o33E;!a4076c1FDe1BhB63k621l182o404;!a1bB60eCDAg3736i4C59l8Bm2Eo768s53Ft17BFuE2w2E42;a4D2Db113Ec2B7Bd1B5Ch312ClEFCo2C55r1B6As4F25tCD6u4EC1z523;a339;i1C5D;!e42iBs0y0;l1B7;a18F6e3537;i51uF;d28DA;cEm115r138;!a1DD6e4i3F37o1E9s0;a17o92;h2673;a38ECi3A31;m7sBD;l1As1F;h397Ak1BE4o0;a895e19E1;!e4hEDi2A09l22n22s38F5;i4E3Dy96;i5n46;c49Fh2DAk320tB;nFt7v3;hBk47tBD;l1n0;l0n1;l3C5n39A;t4788;tC;!e4i6l22s0;!a3279e10i365Fs0;k28n47;o375;n3C9;r7D0;aDu5;a1D6Be47D3h16D1i4033u15B;i36n5A;l368C;c1gBl3FC;!l1BBn1250t29;!h3A8;aFBDr378;!iA17nA30s0y0;fF5m63t2D1;oBEu1D;n1E75oE4v4245;r44;!a7Fc4AEEe4F50h3CF4iDB7l5107o0p3A2r225s0u49FCy0;!a4Dd0l24Br1s2F86t5EB;i206t56;!e24i6pA5;a94e1Di52E;!a96Cd601e512Di301Fl2C7o1628r12C7s0uBA9;e647;!eE04f37i375l4DFDo1p12C0sD36t41C6;!a3559o92s0;!o32s0;d3AnF;e1B49;!i2Bo29s0y0;a4B67s1F;!d4AFDi6r1s0;cBt2F39;aA2e154;!lF6m4D06p17Bs0;!d80o31w80;e9h1F;s5Et35;e1Bn20Bs11;aECCe149i1F5Bo33F1;t278;!e104i6l6Cs0;e2F0C;k4307;eAi8A3o29y0;!a0e5;a0e1;r966;oDr7;!oDr7;a2A40e4875iEo52Ar3EE8;aB67e2418;h8Bk47;!r163s0;a227B;e6Bo2A5u50;u2;g7r30EC;e4B7Ei3C;i1Dw10;e1i3E43oCu5y0;s38C7;f39E8;aA7E;!e4i6r439s0;h2F21;a30m0;a29CBc44D1d0e2CFAi43DBk2293l153Bn1C2Fo4Er4564tB04w2C2;d1Ct7;l2E4;a475e1D19;g38B7o10;a2C68;!a4De15i21l22o704s0y0;a1076o39E;e5n16C4s11;!e23h5AiCClBo1s0y0;iFD2;!eAi21s0y0;r106tC75;i31p36t4E8y47;a42i6;lA8s0t2D;!cD1e0r2B6s0t1FD;!i13o9s0u3y0;c32n8D;o11FuE;e4791oD;!e15i8Es0y0;!f37l22o40E7s0;rA65;!e4i6l3DF6r58s0;g298s50B4v27;a1De24;e15i11D2l44y64;u2C9B;m2352n14BBt2563;aA8Ab3488c26B4d43AFe88Cg356Bh4C47i3258j50B6k293Al3F84m3Cn2EE2o1D5r3E8Ds4661t3D74u219Dv16A1wE11y29F3;i315;!dABi497Bn1F1r1D75s0u5074;!l1As0;!e22Ai21sA46;!m29As0;aD9n2;c243e1DB0h129i444Ao3981r733t322Ay0zFD6;a22A0hA3i4A99m269o42p41A9s217t1783;m2B3u59;d0r16t1;v271;aDi6C3o29;!r58s0;!rAA5s0;!e170Al7n22s0;lB53n5;e32C;e1Bn62Dt3;!e23i534pA1Cs0;i3lBy0;!d0e1D6Cf15FCl22r1s5026t102Ew121x0;a59e95i59Co89B;o131A;!e1r7s0;!e33i23Dp2B3D;cEt1x5A9;e154i1;!aCe3BCCs0;!e1t707w1;o100y34;!n4193;a1e6El44;e1BnFv27;!a16Ee4EF3h332Cs0;t2AD;a175o54;c19g19n44F7t19;a413i21;!s0t88;a59o98;r28F;r25A;!t47;!gBl0s0;b89i4p4C6t322Eu275x1767y28;hAA;e288i22E8;e23Fo95;a42h477;!rE0s0;d1CsB;z17C;b1CgBt1;a4De189i6;d1877n2Ap567;a50D2;!a3484l44s0;c1Ah3FAEk320;!e104i86l48s0;p171;a100e239;!e5s0t3C;t4026;a52i3F;o242u105;!a1DeBB1i374Eo12As0u4E;!b14Fe1fC3h27i2A1Es4E85t1374w860;dBn65u1;!b14FeCFi830s0y0;h95o358;s23BB;i25y0;i18t1C;a54o607;!a283l150r35s1;!a726e15i21m8CFsF0u7D;!d0o29r4Cs0t1;a3A33;t3AE;e1Bl18C2n146;e32BEi4524;kFD0;a3D95e3CA5i4727l32Bo4BDEr1F05uE7F;!d0f1r1s0v48;!e30B0i20D7s0;h116t3879;o1r2AB;!a2351s0;!oEs0tB;c7s19t2E10;!eC0i86l7s0;a962e2971i1221o43F1u2162y64;!a1De4i15EDn38o127s0y0;a644e2873i8C7y0z17D;a4BCE;t120;d0n85;!a3C5Be12i2905j5B2mB0o2C4s0v130y64;i13o52F;!e1f780n1s0;g97l16n4r1E;e1Di13;c0lA0n2s11t5089u14;n188r62s538;tFE8;a16;l39FD;l3n2;c15Fe5nFs282z19;a268;a3481e2618i4971l19BFo4BADu1485y37A5;t1v3;e4F3Di3By0;!a1e15i3AAs0;!e4iADs0t0y0;!e37BCi204n22s1A0y0;e14Ci86l216o127;m4B8Et186;c19f4F2s7vB97;o327r203;s2A07;h4361;d1Ce0;aDe1i13u5;!e26iB1s0;m35A0;a1A6i16DuA0;!e126;!e10m129s0u4D6B;!m87n4864;c463Ch3414k4959r107At348;u263;a241Be4487i1027l4BF1o4382r2C9Du4D59y396C;!d0i6k15B4l136nA21o42p4B20r2CCBs4912t32CFv2EDAw48C9;e30o74;o6Fp61;rB15;!a2BF1b1142eA9i3EF2m7Ao4FB3s0;!e12i254p23F9s22D4;f0v2B;d8Al16;sE3;a252e1oE7u335;t150u5;e12r1CC5;d3An4F37;!i1p19E;a454;e592i86;!a0cBFAd1F5Cg3B32i4F4Fk4C0DnB8Do3668r7F6s0t4C4Dy49EF;e1g53;a1BA3b6AmBn94Co10p1Er35E;!m19FsBDt5D8y4019;g783rFD;e4fBFg231n0t63;iC5B;eF7i9;e878;!a3E54d14E9h27Bl28r1s1600t2B12;!b7l30E4;e0i8El5054m1o14t0w6Ay0;a18Fd61i3661o29;m32Es29z140A;!a22D7b43C9c544i29Al58Co3894sA26w1857;e33i6r12B;!aB03b4C83c56d1529e4f1433i21l1801m2944n4B2Bp12F1r18Es0t23F8w2874;!a505Dc4C8e1i247t47;e1C5Fn83u62C;!e17Bi6s15A1;!a395c2C7e24i6m2EnFs0wA7;e4716i6;!d0l4F24r47s308w169;!i19A9s0tAB;!sAD1t22A1;!e15i2FCs0;c3BFe2421k2508;!c31E9eAf31ABg97i6j1DBlBBAn2750p28r1B32s463At28CF;!h23Bi228t1;n1B19r4A40;i28E7;!a15Ee1213i6o10r3CA2s0;!a34e2D5i6s0;a1087c4397e31CCh25F9i464Cn1At3880u2CBBw14Ay4A9A;!n3s3z3;n3s3z3;f0p0;i4n4y1;!aD9e664i1D9Do3DE4;c11f1t60;!s0t270C;n53u5;!a4DFFb14Fc3444d269Ce1C5AfF22g4986h728i3915k1058n38D8o2909p45Cs0t1264xCEy0;l4B6E;!a1812b27Ad280e4FB9fB5i6m2EpE1sAA5;!e1537h4AFFi34F6l2C5s0t298BwCDyD15;l1n1Ep35r7v19;!d0g2Ch1l22n8s0t0u159;c7s7t1;e30oC6;e4i6o0y0;a70De35;!s0u41B;y3;y52;i4CA2;l3674;e0h109Dt3375;e103k28;h311i1D;l2F1m2F9n2CB;b9DD;!b21Dl1n2BDs0;i3446;i1EAEo0;!d0p1Er1t1;a164lED0u340E;e1Bn1;!a1751c4E9Ed3D49e0g3Cl46EnBr1s2F79t2C99;a43F;!a2A43e2FAEi2ADFo56s0u29y0;i13y2D;c199Fd3g23AEl4AA0mF94n4E4Bp2CD6r43A7s4E6Ft39CAv26D5;a1E38;c84i4E55l3A6Dn27ADr41DDs121Cv46wE4;aA4l216;eAi1E1y0;b3A5m38o85A;g12EBm484p4BE4w0x11Dy5;m3rB;u16D5;a1CB9;e1r15D3t22B6;n1w8D;iBo71;!a247e3E9m7As0;tFD;e4i1BA;t185D;zA59;!e15g48i6s0;a4383i4DCDo3896;eEi2By0;!eB3i27l7y0;!aCs0t4AB;h29iC;n4BtB;n3932;s57vB;h3At85;p27sE;i275;a346e37CFh1A5i3672o4963r10FAy5E7;!c1E2e2A13l1BF0s39BCt348F;c0e1u14;e42i4E;d47e1C41i3DA8l16Cy891;a174e23i6n28;d6B7;m277A;h3C;!a100i2Bs0y0;n2o9s14v3;d24De703;!a71Be4i6kB33l1n19D3p280s0;!e15f37i91o1r422s0w80y0;e480Ct3B2;f3DC1t1E42;hC85;!a1DfBFn24A7p200t1EvBE;l1Ao124;a0n1o9;!e924i6;e212i6;eAiAD;e2147hAE;o12E3;g3n287;n1r1t3C8;!i965;!a84e23i4A22l24D9o1s0uB9y0;a1iD9;a3F2Ck1o4DBt0u1D;s4428;o11Ft1;!c9Ck28s0t11;!a20Ae26FFh2D8i66s0y0;l90A;l1A5E;!aBF2c1CF5e18A0h41DEi31k1F3Dn1D68o1423q30DrDDCs0t3EF1u1D;!aD28e1i73s0v44E9y64;t0x0;!d0n7Fs0;l3o2F;w685;i3618;i3619;!e447i6s0;a175b1EA9c2Be5l273n2821o35E1t22F;e5CFi6;!e9y0;f7nFs18A;a0n1DBtFBu14;!a4Dd0i3Bl24Bn22r1DDs4CAF;!e15i41B9o5Ds0;!l1s0t1;!a69c6Ae15iD6Fm2Es0y0;uD3;aD0iD0u36;!e4i6s0t1;e17u34;e2EA0g4B92s84z44;h27p6A;n3Ar0s8yB;f0v40EC;e85Bi6;a1e33o1;i5E7o29A;e8i4;eC6rAA;!i53;r6D6;a1Ce4C6Bi5m1t2D;gBw80;a558e2A72i2FDo6E;c11h7;l325;!i8Es0y0;a15Ee22Ai6l44;m98;i12A8;i61o35;n49CF;n6E3r1BB9s3D8Ft1;r2C7;e317AiBCy0;c463Dd30DEl1023r4E52t3CE7;!b4998c22C9e48D6h1l175An3D9DoF6r43D5s1CDFtE70;u2EC7;!c324k4262;!b1Ce0g3n59Cr394s0t27D2;dBl35;g231oE6r3uE6;sB7AtFB;!i1l1255s0;n6Co1;a51h4B0D;a21l4606;e34C2;e273;!a2649o327s0;eBA3iD4;!d0s52;l4372;cC2eCBn62D;aCe5n2s8;c32h1i30F8n4899s23E6y56D;o2C8;!e1i2C1l357s0;n2s68D;!d0r2Fs0t0;r5FF;e7E4;l3BF7;!d0e13Fl7n22r0s3E;a36A6e31F4g654l9D6;!c8iCr7s3Et3;i33C7o8F;!o10v3;a20e67s11t4A;!e6E;d0t40;a1B9o1;a51nF;s61z61;!p19;p19;a960e23i6;e26i3CDy0;c4A37l46C7r2228;!a2678o2381s0;!l75E;aCeDg0i0u5;a508;d6AeB3n2;!e1Bl7n22y0;cEi10m19;a1D85;!e1Bl7n22sC7;!rD8s0;i3Fk16l16t39;uB06;n2t14E;e2B9i66k3536y0;aEe8Ch10A9i27E4u7E7y0;e2AE;!d0rEs0;!e1Bg6Ai1D47l4EA9m1n22o1s0t222;!a20e3695i4E06o125s0;e1Dg1C9Cn2D3s44A6t379;i152yF0;r70t27;d3n3;d0l1r2F;!r34s0;r32F9s232C;n2ACp1AC;a25e4B10h4D53k1A65o2DABt12EA;!s0u49;a20i0o36u5;!i69k9Fl9Fm2E;aCm1rB;nC7;!h8C2k4C;g3Dn1C01y0;i31o49;cE1n2s11;t498;d3AnFt77;i8D1;!e0g415Ck1CFl7n2312s0;i6FD;a252k3;s28A;aDh0t838;d1549o19Du1;!d0s0y28;!eEh9Fm2E;d2Bl55s1F;!a20;!l40DEs24Du5;a9i13o9;e2156i6;!s0t1314;!d79Bn3BC0s0t85v19;l55x1F;!a1e5t4D2;e1377o74;!h10m2Es0t1885;!i226Cn0o46s0;!c2F7e2FE1i3E83j47C2l392Co468p26A8s394u1920;aCe1i18;!e26i21m61s0wA7;!b4B9s0;d7t1;!aCi20;b0p28;a29DFeFC0i1D2Fo2D1Bu2528;k3CD7n1;s11tBD;!a1Dy0;e3FAnF;!e4i6s68;!d47l33B3m1EEn3621s1CF7t55AyDD;c316rB;f31Bu18E8v3;eD4Bo0;oD9;!a4B82i16DoC6;i12C5;tEFy1E;e4440i4A14;!d0f37r1s0v4C;a639e42u34;!o159p80As0t0;e1Bn2t380;l4E34;!b12Dd146De15fC71i254l2C35m2C1En0rA98s20A1tFFz3B9;e2E31;!l182s0;!b3DDt1BA5vB30;!m2Et9B;g589;!i285r269;!hC7k47s0;lA8mA1pAAB;eA2v3;m3t3;i1FC;s8v18;a0c0tBu14;w47;a0mA14o9qA72t45F8;a2C89l26A0;a1i61;!d0nEo1s0;a395i50u15C;s0t1D9;s3uA0E;!a4Bd0s0;!i4EDl7;a495Ci1DlB;l188r39A;e1Bn179s11;a20e3Ai2BB;a4De178Ai21rBu1AF;a25D6i21EDo42C4u264;!d0e0s0;e1l19Ep1;l1D43;c321n3;m9E7;h3BAl16E9o227;eAi5;e24i5;!e43FFoE17;eEu34;a1ECCeAB5i3D5Al2Co421D;i774;!e3i0s0;!d1F3e261p9Ds217t2D;a0e3Au14;c7l1r7t3;!a1b3861e4177i24B6m377Cs2F6Fz7DB;!a1797b501Fd4D73e2924i4887l47BCm1E4En4E9Fo3112p1DAFr45E1sF3BtFFy0;e4C5i2D4;n2Dp55t3D;c32w39;cB2g0k144;!aCe4f81Ai21s0;o292;e437AoA4r83;h3355o10;!a228s0;!o1;!d0l1151s0;!b39A9c1E4e405g4466i18Dm2En0r237s0y0;a10e49BAiB;!a7Fb3DBe15h890i1E1m2Es326;i1n50B8u88F;!n4B9Dr474s11B;e1A0Fo788;!r35s0;n66F;!b2242d0l4B63m16F0n23DDr0s3E;!c7s0t5B8;!i6s5E;a12u23F;i6o9D;!e4i207Bs0;e456i2369l2Cy0;!f570s0;a13e12o505EuD4;a3E72;!a1A0Ai73o28s0y64;e1B9i853o3F12y25F1;!a8EBe244Di40C3l27r7s0;!d18D2g4Ar28s0t47;i28A0;!e24i534;eDCi35o40;s32D5;e50AB;!a1BD3c17E9d2EDEe33EAf4004gCDBh2F7iB19k267Dm2En1E11pE1s3383t46A4w2C0y0;!a3BeE4iBo71s0;eEAAi6;b1Cc2C;nFo10;g0i0oE7u5;i882;a29BCn2p502r386s103Cv128;!r2B6s0;e15Di190o12y0;n3C37;h1499;!e1BnFs0;h3Di4;o14r3C3;!a5132e4AD3i1278o354ApBC0r13FEs0u41C2y2446;!e26o41s0;e2BB1iF1;e10Ei96l7s1AFEt4A;!d0n26Fr1s0;n0s11;!e4f37i27nD5s0y0;tCBE;h1E62o139r225;f38n193s9BE;aD0i65;r29C;b3DE0c4C17d2958f1g4353kEC6l3FD5m36A1n1D90r378Bs3065t4B24x4549;!aD0d0fCEr36s0;hA3o10;e1Bn193s107;!d8Ae4iDE6l2A7s0;!e4i5047s0;a1F01i529;a7e3D;e1z2A1;t457;e17i21y0;a23E8d154e15BiA2El4FE2o3533s1E06u3729v499E;m6F7s5E;!i25s0;l3o10p1Ev3;o2CE2;i12n1;a2CDe17i172;l4063r429;!i221k502Dn74Br1159s11t60v3y1;!g2BDF;gDCl0;h1406;!a1204e1006h5DBi21s0;a263Ee54o8A;b5CgBm2Ds1C31t4402;a1F4Bb3F2c2F45d189Fe420Dg2608h218i25B1l4681m37D1n4346o2D50p2E3Ar1222s196Ct800u1178v3B6Cw26EBx5020y362z2AA2;a10i61;!b229s0;d3r1;d52r1;o2B93;!a1De23i6u49;t1C7;eEi0;!a12Ae20FhB0i2CEs0;v44;l35E;o3462r518;p0y16;e2EDCiD9;l232u5;p14B;c39C2o1qC2;!e5m2E;!a3AA4c2F30e24i6l22s4D10y0;t28E;l19nE;e4CiAF;e1i81D;!a10h255i1l3A0s0;u6A;l109E;a3F7e1i279u14;aCe256i3D;n3858;a1C0;cEn1t16A;rB9;!b2D8e15i63Al7Cs0w1BCy0;!a230h1n2s0;e15i190l44o71y0;f102;d0r1t2D15;e32Ah649;!s41E;!s141;a2ACCg4573;a4D3Ae4685i2CC8o4209u385Cy0;e5o46;!e5o46;!a38F6d19D5e1g4042k1m2En38D3o3D41s0t1;!a15E9e23i21l2CoBDDr4E95s0;n2r35;!b1p28r9E5s0;a51e15i6;i191;!a4De8F5h1Fi548sB6Et0;o30y31;!a2E78fC3g3699k400l1o2494r33E7s0v30C6;i4324o46u5;c3ACE;s34;!a19FAe5Di0oE7s0u5;c2472g463Ek4036l3793r0;!e0h9Fi35Ay0;d44E1;aD0r4A;!a39Ce24i6;i25Eo1EB;l1n87;i3A1;c4DF6d1Am1Ar58t5C4x1F;f18EAt47;m1988;!c1n289o5Cs0;!l1n0r1s0w80;!e4B11g245Cs0y0;l26B7n1AAD;o9t44Cu5;!a485Fb2DF3e436Ai20l76m303BoE7p129s1A0u31C8z364;!b4F35d158eAi18Do435Ds0u108y0;a328e6E5i4228y0;!e1i13l7s0;!a7Fd1e15i6C6m1s0t0;n2A7;i651;i11Co446;!e4i6s1F;a4C1Ci3FFFr2DE6u3DC6;!b39Fe9i8Es0y0;aCi10F;s3424t0;i65u5;aCi1C;!a52b6DCd0f28Fl7n22r0s4F01t40B0w130;!f37i34E8l22s0y0;i9n8;eA76i6;a18FA;a360u8FC;eEg1Eo8u9;c4730e5;n1r28;a3E9e3274i42D4o7u4376;a270i28C3o92Fu28A5;h1928;!i27t8Dy0;i25x4C;s247F;a1i4l0nB;d0nEr39;d3A41pB56tB9F;e2A4i71nAF3;l16t27;!d0i6m2Er1s0;a125e1;!c0n0s14;e4709;o12D;!bD6e159;e201o28C;a25d1ACm377v130w9A;!i8En2C72s0y0;a331De437Cl358Co479Cr1A56u2108;a20c6BFd0e1i0o292t1u5;g1F8p36r10DAt10A;!c249Fs124E;h1714iAC;l408;!e24iE24m2Ey0;aBAe4l22;!e67f27A9iDCDm2EoDu49;c1Cn2;e5nFs11;!d0m4C08s0;b7Bn2;!n22r1s8;e3C83i6o12;n1A1;r2911;!a2857d22E5e300Di4D27n3B78o1B20r4B8As1837t209BzB6A;n2FBE;e808;i4A3k53;e8Ck5C;!a3865n12DoE4p3B44s0t88;!l1s0t88;a2FEAeAi21oF31;pCE;e72iE;!d29AFe0l7t2550;!cD5s0;!a737e1C3f183p983s3B37t3380;a1n3Cs1F;a10r5D;h129o6FCp1B1;r57;!eEi279l7s0t7;l16F;b20B8d37DFg465Ci2D2Fj15A0k31D2l1F79m4B79n2718p4857r131Fs4105t26E4v3554;g2371t55;!d27i31o1s0u34;!eBi825s0y0;e12hEi5A8m1EEu41EC;e29A;a374i4B57y0;l58s56u2B83;!b3D2Fc4Ae0;c128d33B9s0;o6DB;o44EF;t2AB3;c23BAd847g4308h210i212Ek3B8Al27D7m3B61n1CE3p2076q2959r380Ds487Ct1227u46FCv1059w9A;o108wE0;c0tD2;e6Bs3;lD8;!e284Dy0;!e6Ah3295k5D;!d3;a3C81;b512d28B8f2A03g746l141BnDD6r31E7s3C0t295Ez5123;i9o40;b1Cn4r3B53;eA6l19r19t1;a2CAAe4437h32C3iBCkBAAoErA96tEB2y844;!s0w31F;!d70s0;!a500Ee1B46g1D96i2946l4EE7m162o1F30p84Bs0u7C2w5B7;z5B0;h116p47s4331t70;kCBr2FBD;d0l2C01r1s4E;m3B94;a53eAi6;e1i38;c0n0s0;!a4Ee3473r42Bs0;rB6;uB5;!d0l43A8n0r1s3E;a0eAoD;e10n13A;!b14Fe108CfB5i1FE8m2Es0y0;a3683l1n3580rBEs42EtDD4;eAh0t1;a1c13Ce207;e267;n1409r2C9t1A;m3D25;a1Dk4595l2599;i1Dm19t2592;d1B4D;e307B;aC86e21F9;i967;hDBB;a19EAe48D1i510FjAC5l2994o42B5rEB9u1E59y49E3;e4g1E;b1eA;!i344F;o28B;eAg1;!e15f37i86l198s0;r777;a376Fo69F;e209h168i13o3F8Dt38;e12o3431;!a9b3914cC4Ae514h1AC0i6l2474n22s0t2892w3A3;a2364p47;!c1BBe4i6r246Es0t0;hE42;l2A4F;i5n65;!d0n3C59s0;!e5z73;a8D9e104i3EFB;fB1nFv3;i2461u34;a768;aA0;!d1C8Ee621g716i1E8s0;a4CDDc12F0d1E45e3FA7f1098g32F1h2888i2BF6j18EEk202El4D42m4258nF63p49BEq3A96r378Es10E3t2A47u3CEEv2B0Cw2D80x2D92y21FBz1051;!e2887i6s0;i1s1F;!c2F94g41l1s32;!a4BEEb14Fc1607e1330h2DD5i4654l7n22o4399r35D5s394t3D4AuA86z38;a416Cb0i38l8Bs44t3806;!l7s0y0;l3t25B5;d3An1r1s0;e2805;i4F4;c1Ce1Bf7l7nFs0;!b27Ds0;e4F3h16CF;e1FC9h1i4FC0y0;a7E5;d0n8AAr4B1B;e1EAD;!a0b176Dc1AEe15f2974h1BF2i66l407Fm162p2BC5r39Fs416Et27A6wA66y0;e24n1E21;t7B6;d19eEs5t1;a1F5e10DfBF;!e79i43lCEo10;i31r25;iAFo74;!d0l6Cr1s0t1;e1Bg97l7;i8t13D;d89l1Am33FAn83r3;l4D5r77u5;rBB5;r139A;a1FCy6F;e4E5i91y0;!a60o108v1EA;!c11e0l0r7s0t3;a249e4i24ADo299Ey0;a176A;aBAe4iBCo1D4Cy0;o350;!c121o58E;eDl1A3Dr3;e3BAE;d1A9e1E0Fg716;nEsBt19;a4Ae4A;a1Db2CmE31n4B78p48BBr48B2t2B44v2C;e704;!aBC6e27Cf4C7h1B1i2BDElD6CmF30o2925p2AB4s39F5;!e15f37iC9l2E0Dm63s0y0;eA7Em4939;a530h46A9l4BF7o1E93t13E;d27i2EA;!l1A28;!a174d0l22m63r1s0;!e15Dh1iC9k5Ds0y0;r28s4E;!n8s0y28;i3EFFo12;eDB6o46r342;!a3;a3;n1r2F;a3817b1893e14BFi4E70o1809p2782;aFE6;!a16e24i6o16s0u6D9w16;m63n85;h2Bt1E;!s0t7A;n1202;!b1e4s0y0;d1A81w229E;!a956eEi56s0;!i21l7n22s0;!e1Bi364Al7n22t11DFw2D8;n443s3;e3A09iB5Cy0;a7B5d49o338Cs1AB9t1107;d19r48;a3971;a30t2E7;a30e106;!d0e9l22r1s0;b0d1;a1Di9FF;!b4B99e3B1Di2535s0;a0c11eD3n3u324CzF5;a28E8c36FBe15BDh4643iBEBj1EF2m60Co3616r4C9As466Fu4AB9w2919y184Bz3F24;!a20e10Bi10B6l7s0y0;e1B78;o226F;m95;e1n16r0;e1i3165oB;!c2CD8r3663s3C73tA6Dx116;i35o486F;e17i206o1;e90i787;p1Ct11;!g397s0;!l1340;!t1A3F;i2BrD8y0;!e15i43r35s0y0;!e46DiADy0;e7DEr585;!a0e5i40E9oF7s0;k1rD1;!m2Et6A;a214i20o4602u29BE;!a928e5t0;o37FC;!fC3l37B9m372Dp24ABs0wA7y9A;k2Bx0;!a165s0;a13b635;h4023;c7t4FEC;c0n2s99;l5Ar5A;!a12s0;!e1C3;e1C3;lF4o3A1;i163j18;a0c44d11Dg28k176F;!a26E6e18F5h2344i4623o1567r1703tD6;bCDp123E;b5E9l1DB2t1B6;dBs36;e82i514E;!a20g48i3Fo29s545;!b1F3e4i313p61s0y0;h1At1;nEzFF;d1AC;!a4Bi152s0y0;e1By0;e10Ey0;!a3952b2220c459Ad31F3e257Df3A6Ag2F73i40BEk2EFAlF6mC4En3251o1CE5q123r2C71s50B3t29FCw2F0y4D4A;l2276s0;!n2s0;s3C40t14F3;s55tB;f37E2l44;e5BAiBo92;eAh1289i6;aFC5i2952u2AA;!d0n551r1s0y0;dB7Dm54Fp47;a36E3e12B4h1CF0i3AE8jCBl1164n1904o303Er3A3Eu1AC8w36DDy43D1;e617i86y0;!d426Be5i2ED1k47o1BEs0;eAi6n2CBFp0;e1fF5;!i22F4l7;!m87nEt15B;!d3Af37p5r1s0;r3s0;!r3s0;t362;e17i117;aCe31i9BDo45AEyC;c37B4h288An89;n2480;!e15Di6s0;e32h5E4i40F5k4FDF;c128e1Bg145;c13Cd36CF;h1Ft39;i3By0;h3FEs7C;e1i3FuA0;x245;d0e10r16;!s0t2B0;!e21Ci476Bl7s0y0;!d0k3Cr1s0;!e4i43pCEs0y0;i2Bl2Cy0;cEFe15Ar311F;dA4E;o27F1;m40C5;sD1u5;e6Ao42F;o12u1DBA;e145o17uB0;e0hFB;a1EDe4;!a861b1D1e4i2C56o124s0;aE4;!a2262e1F8h45F3i69k4ClE3t18C7;iE6n5052y0;k3CE;hBi542;!e0g0s0;l1n27;!d1n1s0;a3D67e1F29iCoE7;f1n2r25Cs1EB7t4D33;!iB65s0y0;i2775o211y64;a1o331B;a1l48A;b29n6C;nFuE;r3E25;!eAs0t3;e1BnFs16Fu14;!d1El22o1s0;l587r1946;a87e8E6h25Fi900l34EFtD21u3E8;e0t20u12;b388r173;!l3318p3CEAs0t3916;!e12i21n76s2BA5;!i273m63s0t2D63;!e4i21o10s0;!e5s1F;!m1Ep1Es0;n18B;l6D1r245;!a4E61e2613i281Co1C9Ds0u2949v22Cy7C;a20c30DC;g6BEl76o0;n1AF;r19C;a10e2982g2BA3i127Dl1479nBo1p295Br242At4936w46E6;g1v3;tB1E;a896;!l6Cs0y1;a3FBFe1EBCf1i1B4n197Cz2777;a20c0nF;!e24i6s1DB9;d535l10BC;p2AB;i36y16;!aA4e1i56o4C0Cu3E6w121;a1210o18B;a88e53Do50;d4FFFe5f172Dg395El5F2m2170nDDDp38BBr45A3s444Et23F5vFEEz4FC4;c430AsC7;e15B5;a1l18;i1u1;!m1s0w253;r2FE;d5Ck8C8lA8mA4Cn2238p1s2C;n238;!e2EBChCC2i3638o4C0At1509u2CD;!g3FDs0;e1n5136;eDi20A8;i98;!b3DDhE3o31p2B85r51AtBB0wD4E;s84t60u172;!e79iC9y0;a1De23iDFn3E1;a0e0s0t1;!a32F8b1FBe3B3Di4E47k49FFl4596r5FCs0t1804v28y0;e2B4;c3e5f7;!p114;a4491e46F8i4FC1o145Cu2BC;a52Bi3Fo29;b62i84sB;a50DEb2763i48D7;a21E9;n16v61;e3615i21t16u5;f7n366s0;!e2373h38i17Fl505Bs1C9t37B0y0;d293nF;n1B82o29;a72i4526l9F;eECi2Bk0y625;n120;!d0h20Ep454r2C97s0;l4uA6;o20C8;a16DBe496Ei224Eo1490y7C;fEwA9;i2D02r20C5;oDA1;!a12g222s0;!a4Be10Bi3AEDs0y0;!a211b4C1Bc1749d42B3f3FC5g3513h2667i22Bk2939l47F8mF1An2CFFp20E6r3C2Bs4463tF90v27wF4By9A;!iEs0t1601;m1C4t1;i42A9u202;!d2De0h1;!p25Cs385Et5C;!a2311e17f38i389Do1CAs0u36;e1F0o21FuE;g336n221s2E7B;e4A93i21lA8E;o1Dt95;!r60;eAl1;!eC0i21l7n22s0t0y0;!i2040k3B7Bs0t2BA2u9F4;a4c2At0;n123;g12DFm2758;e5n20B;n2827;r16sC1;a4FA3e506i4053oE2Br4AE5u424Cy64;b2988c2F4Dd2E91e31F9f4162g237Eh12D3i2677k49B6l1F0Em4C2Fn1BABp1AAFr5075s2636t33C9u20CDv1025wDA2y11A1z3F72;n3FD9;!d0l7n0r1s0;a190Fi1C5CoB52t840;g4ECFj50D0k47n4254x68;a689e27A4i22DD;eAi41;eDn20B;eAi2E1;a10e6E;d1A6E;b2EFc2A49fBFn1s5BFt5E;n2C6B;n3F3E;a79C;!n22p219Bs1A0;e4i296y0;hD5F;a4E40;o3A59;e3Ai3Fu34;!l361Cr102u42AD;i5y1;a4CD3;!eC0iB7Fl7s0;!e0r7t19;t8C3;d1An1;r1C2;i2A82;!c3g3k1;!b48DDd406Be4g9DEh7A7i6k3943m4D56n149r1C6s4082t101Bz2E75;n2070;!b95e14Di3CDl3s0y0;!e1h1E2Am1p1D5Bs389t1B42;a21c3FCEe4AABh14EAi3FA2k377Al2292m56o1q3A3Br199s3686t4C92;!a110e139h121s0;a4785i43D;b7Bl0t19;r2B28;a531;!n350Ds0;gBi1D;e10n1DE3r4BA2sExE;!g1EE5k28nB5sA0B;e24f7nF;!b1Cd349e0r1w269;!e24i21s7A;g4Ak21Em54Fn7A3s1BFtD8A;!e7i3Bs0;!b14FiBl22p162s0;n52t3;!n3t3;i2542u5;i50s1F;!aB2Ee43Ci6s0;!bB78e10s0;e5i13s0;a41BBe249Ai4F92o19B2;!hEBy0;!a403e4i6n38r58s0;d9B0;c15Fs107;lE2r2D2;nBs7D2;l1BBt5D8;!e21h16C;b1Cc444Fi664nB9B;tCB1;r2E08;tF18;e34C3;i15B;!e1i18l7s0;e17i1D1E;c1At1691;e30i2A93o12;l411r3;aE62m21Et10DB;!e4i4D46s0yF2F;eCE;e12ErB7;a294e1n60;l4017rB;nF2r1BC2s1A43;!e0l0tB6;a1f2DnF;a1EDe1;t0v3;n3s14t1375;!o4471s0;a1D62e17C0h34F9i2B91lDAEm4FF4o3872r1F8Dt2DC0w3E59y2DC4;d318t846;l3ADC;i6FE;!e82i8ABs0;!c415Bd0e2571g236i98Dk582o2CE0;l3t1;a442i0o52Fu5;e18Co5D;!d20Ee8FDiCCm2Ey0;e43Bi271C;!e15i6l238s0;e5hAEi5s4FA;a4F94eBEDh20BAi21CBo3117u3DDByCE5;!d0i6n268r78s0t2D;!e10Ds0;!e1Bs0;!a132Fd22E6e2861i4A36l158n34ABo4C80rBs0t3361u38C8;d4E;a0o9r1A;a1F5c210Bf21EBr3347;e2C3i4D1D;f0t1;l36;mCAr18;h649;a5070e2DE2hBD3i2B5Fo25E7r334Cw627;e12r1A;!b1Ee82i86l7r5B;o3CB7;k17Cr2A;n3AB;a36eBiBo2917;a895o46;i1Ds1999t4295;p5Ay28;n546;a213Db2042c298d1668e2D73f11BDi456Ck1Al1918m1n3BA7p8r1F62s4980t27D1y1;r14y16;!e4l11As0;e0i77;d0e25i22B;eE63;bB4Bl863o4D58p30Fr3C8Ct57Au14B4zAEB;e20g1o1996y34;!n56r1CBEs4E26;eAiF9o12;g231i32DAl1CEu338;l7Cm2997s38E6;e48A;!aB87e4F79i6m1EEs0;eDl7n20B;c6B1e0h1Fk4D19;l0n1D2;!a6b24B2i1954l5DEo259Bs0uD5Cy0;a0e0i13;g28DCl1r2AAA;!oC;a446;!e5r1s0;e5Au41D0;l2CD3r83;!d452Ag39B7i21k329n7As0t28;eB9i6;!e4i6s0u49;aCbD5y1;a408Ce4E3Bi254;i12D;e4468h3C33l1F1;r584t1;a235De655h0o2761;a21C6iF64l1n5ACo2D2B;d793g614n522t28;n65r3;r1D39;r19t1;!a4De3BD0i6r47FFs2C86;e318B;!e37Ai66l1FBu240Ay0;e15i6lB;b4656r4E7D;aD8Eh1B80kBEAl4920oE60;!a30EBc3809d1B29eC8Df6Ci34B5l85mC99n3B4Ao258Fr12EFt355C;d214Bs1633t2A9;n4s379;a1lB;eEAf7l7;e1378;a15A7e2F4AiE5Ao201Eu3666y49FD;a1ADAd2011r1;!a650e1s0;!eF7;!a8i13s0;i73oFy0;a927;!e4m1s0y0;b1Cm0nFo10vB;i99A;i6B6;d2B0r4;c3d41;!e4i4A41l2FAs0w7F5y0;a1h2AA6;n0r2F;s197;a1FD0e4i6;e0hB;e42i2Bu6y0;!e37Fg2E2l36EBmC58r27Bs0u8B;e327Al604;aC1Ac4A8Be4E5Dh3B64i3CC4o2ECAp12FBs1A19tEE9u18BA;e1l144;!i204l176m2En22s0t4A8w2D09y1CA3;o1D14;b12B7c296Be24f4433g415Al50BFm3DA1n2ED3p1060rDDFs406t2855v216;a8s5;!i56uB8;e6FA;a214e61;!d0f37m2Er1s0;d0f1r0s0v81C;!i1pBD9s2896t252FuEE;a20i16Dl52y1D;e12i5o1y0;c0s99t7;n456D;a6Di753;a11e31D5;d63p12D;c22Dd0n3x1F;c27;e968;m88;c1B2E;!aCi279s0;d28sBD;!eC0i6l9E9s0;a3D2Ce43B7iBAo2991;b7B8c2Ch1i4m7t2Cu188y28;f2370;nBs0;h14B5lB;!a218b3885eD64h4C70i17Fl7n22s4C43u35Bw5B7;!e82s0;e4s0;yB9;k5Dl0t3;a2116o42;!e4l7n0s0y0;!iB9s0;e2071g4BCCi3B;n334Er3463t28v8F2;cE3e67t16;!e4i47AEs0y0;!e4i47AFs0y0;c1Cd1g35nBr60;n1A6;n4FE;o4r34C;aD7e12i3Do69;o9Et184Au4E;g3x0;f7n0t3;e3Ai96u69;t444;t163;o4r8;r3Ds3;a36CB;l19n49E;!a2458e1BF8f14Fh99As0y21F;a4675d37DAi43A9l3o914;n25A7r32FEx5A9y2B36;i5024y64;!aA03eEi0l1Eo36s0u5;l44oE;w25D;n34F;eA3i910;!e50s14C8;!s0t2C;!e4i1B3l325s0;aBEr19u49;!c4Cr16s0;a0h33FCi110o9;a4Ai1E23n226;a3Be67iCCy0;e17o36;a3B0Fo0;a1De23i127Ao8C;m3C6A;i45o6B;!a4De15i21m2Es0;e3F;e26l7;!g33CFs0;i1430;!a41Fe4B3Fi6rBs0;!b5BDcD1s0;n332;l0r8FE;kCDC;r184;u1B4;c0s4C3;!a4AA4s0t1A73;i4l0;!eBAh23BlA5o10p1BC;!b1D1i5Cl22s0u485C;g41r7t3;a10i21y3D2D;s0z0;e1r0t1;r1D79;o14p3;a32oF1;a8c2A;o2F12;a14FC;aD5o100;cD1l3At3C;b7Bn32D;s1CA5;!eAi43s0;a6Ee6E;t4B3;c5Cg231r1D0Es44t44u60;eFy0;eAiF9o8Cu49;r669;c302h85;a1B9FeC25i4587k4D2Ao466Cr2BEA;!a2779b17De25CCi2AE0o445Bs0y0;iAFD;!a3B82lF6;!aEo4CBDs0;!b38d45A4e7f394Bg3698i8El3FDBn2EFFp419Er2ABs1CCB;h4689;l50BA;c93f1n2s0;!aEe4lBs0y0;a250o2468;r4s11;aBF1b47e1;o4762;!c158d0lA95n22r0s3B46t205y0;r59B;o5D;cB2eB7i1BFAy0;b1Ct1A;!e2B7Fm8Bs0u117;e1Bl7n40B;!e6Es0;d0l3ED1s84;!d0s0t102;d0e1l1r1;aDe1i10FoD;yFC;aDe3o3929u25BFw8B;!m29Bp4942s0;a21Fe2B4o8DFy4450;r6B5;!a1B9e3344iBCl2Cm14As1710y0;d0r8Ds0;a496Be8E6i34F3o1B79u2A54;k2795;h3B55;c243d1426m47n1r28C8s259;!e2FD9h4922i15CDo1E9t13B3y0;a2A3;!a180oCs0;a372Ee118Ei2237lCA2o23DBr4216u2BD9w26CCy3F70;b195;!a4310e15iADs0y0;l17C8n40B7s32DC;h1F82;b66C;!a2470e2B74i4E83y0;t36D1;a1b961d36A5eEg33Bl3101p7t15BC;o1820;c4Ft5F;dD2i4m1Au5;!d0nA3Fr1s0;a119Bc3E3eAE9o851;i10Fy0;d0r1s1C1;n39C5o3BEs13C;b1Ce3D5n233Do1;e499D;aA4e704;f0p1;h1C5l23AFn488;aCc0f7o9sFEz3;a3F96e3763i4687oE4y0;!a347Ce22Ai21s0;!aADEfC3g1B9Dh3EDs0u1C3B;r145t1A87;!c1k1s0t1;a51dBi3320l49CAm3ABFr39AAu22FFv3;e15i43o0y0;e36Dh116k5Ds441Ct1A9;n52t7E;!eAiDFu49;eAiDFu49;a50A4e4E7o4F78;n1r35;!a12e15i6l22s0y0;!e4i66l22n1s0y0;!b11B8l7n22s0;l1t0;e162Bi4FFy0;k3CnCED;!e0l55s0tBD;!e1l1C7s0;a1A7Ae10B9o3C4Eu1FFC;a4F54d1g2D97m1B4n2D84p298As11t1EDC;g4725m2BFFn2424p30Fs41AEt21BAz26B1;w505;a1A33e1AC3iA6o8E9u395;eC0i6l48;n3D1;!a20i3Fo29;f755o8EDt28;l1Dt1;!e15iDFl7o12s0;c1Ce1Al5FnEt1E;!eC0i86l7s0y0;f36F2iFFn119t28;eFCl19o335;e2BC6i6o417y0;a1ED4c0d3s14u14;b0g0;a1E35d39A4i4FF3k2136l3E5B;b53A;s3u14z3;d0r1t930;n4803r65;aAA3e383i4E93o1D8E;e24lCn30A;aE5o9;a9o9;o628;!dFBeAs0;a315o1E0;eEDBi6;e5fF5nF;eD3h7i20;a59o31;s128t3961;e1C3o1AA;d1Am63t28A;i2EEEy0;n286;!k0s0;i440o46;!a3BD3e47FDi6l112s0;!aCe1o29s0;!e5i21n3;!aA64e15i6l4195s0t5F;e78C;c11t60;e9l2Cu45;u1E1A;!e4n0s0;e37E5iE5El38r2880;d1kAD8mDBr478Ft43EC;d2FFEs2954z2C;!e15i21l22s0y271E;c50A;a1EDe1i0o0u5;h1C44k4717o1t2DC3u5;e233Ao1114;i7BoC6;c2AECoCs1B37t2E82y227;a88e3C3Ci1C8C;i19FCo0;i2BoDy0;e8i0o1;!s0zFF;a3578e1674h623i118Ao3411u2E4Cz3E2;!pA5;r55tB;i5AE;t23B8;!e1F84i27Fl7n22o2B02s0;l1A4;yB1F;s2C8;!e4i6lB68n0s0;e317Bh3C;!e26i6o1s0;j0m3;!c257r11Ds0x4A6;a427;e1Bl7n2oEs7A0t7;e0i8Ey0;a2DeBy1D;n47r39D3t37Du12;a1D76;!b8F9t0;n3033;d19l1;!e15i6lB5Fs0;!d47fB5i3Bs0t1;e36o42F;e8Bu2E7E;!b181e12m2Es0t38;n0s0t5E;!d186s0;!h1s0t397;!t5F;k0l16;a3C80e5i142tA9E;t10Aw9;a2EDrFFEsBD;!r1E56s0t3;e50EC;g1n1;i8E1;i5A8;l92E;bD8;t430;a1Dd0e8g97;r7y16;!a5FEe15i6s0;dBE;a90i27CF;h3228;!a1e1B13h5Di1864l1BFo159Br184s0u10y0;i900n188;cBf1lEB5vB;a42e6Ao3311;!b169De15Di6n22s0;!d0i6k0s0;n1Ar640s4C;aD3eE;b83;lF47;a3C90;r4CF6;l2B5;i3501y0;o3115;aD0i4A57u69;!a1e159l48C8m4327o1CFFpAD6r1C8Bs421F;a42C2e8i172o1328;e4o8;!e4i6o28s0;a4EE4;n60p89;a60t3F;k2791;!i2067o817;n6E1;!d3B25l3C1Bn20A4r1EB1;!a4BeCFf37i6s0y0;!e15Di66l2047s0y0;!e2D05i32pD99s0;h307D;e17E2i21pA3;!e4i6r1As0u10;!a291Ee15ACi3C2l22o25EBp162s0;f904p1A4Cr1B0s20v2D;c1BFD;!e15i6l7s0;a4F56bF3i3FF2;d0r0t16yB;!l7r1s8;g1k1t4A;e87AfF5s0t4C7E;!a4Be262i43s0y0;d0r315B;!e4h156i1DE8s0y0;d0r218;!e4f37i9C9l22s0t3159;aCA5;a44CEe531l4F60u14;l48n2t3D;c19d16e50;!d0l7r7s0;!d0l7r0s0;l35A;!e15i21s0w169;!n83s0;n3t1;a1EBe23i21;d0eAi6;l454;h1E4;!e6EiBy0;e6EiBy0;!d0l1r1s0w80;h19Fy43B;a3F7u34;i3E4o2CC2;h9F3;e891k2F04oF2;a15Ee3D5t2514v3F0;a49A6e3364i375Ao36y64;!d0n4r1s0;!c45Ad0fC3l497r3212s0t125w7FE;!i1AC9s0y0;!d0n242r1s0tD11;c3e762;e5l7nFs11;n110;!k0o0s0;!e4i6s1C9;l4B8B;o8r3uC;!a1251e27Ci43ADo3EArBEs0u43Ey0;e3F92o1ADC;dBi25s0;rB31;!d3Ar1s0t20;r992t28Ay0z940;m52t7E;a1De30i77;t3013;f147lB98r26E1v7C;!a3ED2e41E8l7m7D7n22s0;a499Fe4F03;m1A7Bt2D;s56Fu23F;a1e1EB0f0i2CDF;e1i111;b3C6f8E7l3D47;b36DAc2DDDd2CA6eD4l1D5r1s34Ex46D8;c193Bp10F6;!l13D6s0t4095;m5DB;!a90eC0i6l7n22s0y0;l20E3;a2008e4909h297i3B85o12Ar2EBDu2908y5C;!e4iCCl6A3s0u4Ey0;d313Dt30A6;!a3A62e67i4101l22m2Eo2F70y7C;sD1;a30e15i6;!s5;a6i6u6;e4v5B;!i565o29s0;!e224h0i3Bl7s0;e57l1Dp8;e12h1;!i2EFs0;!a4E54b448Ac1E4e15f17Ag240h480i18Dl4C72m3BFDn2B5rCC0s4202w2D6Cy0;f4352o49t1u0;e1h2C;e9i13y0;c4417;!a12d8Ae4hEDi26C7o57s0y64;!a30e4i2D4n11Bs0;a151m2Cr194C;!d0e9r1s0;l418o1;d1263;nD0o29s3;e15iAD;a4612i4CE8oD42;e5oE4;a30e23iCCy0;c45C5l491Fs1573;a28D5g62;e0n2s11;t27u49;yFD;oB07;d2Cs2D1t17FD;!e4i2644m2Es0w80y0;!d3t3;d3t3;o29t7;u13A5;d0g48;!eDr7s0;e150i3B;!d0o9r1s0;!b1D1d0i9m389Co29r1DAs0;c97;e17o287;d8Ai1E8;!d8Ai1E8;!d0r145s0;eAi6s3A;eAk1;lBr298C;m27n1;!m0s0;cB2;tD4;!c4021dA3k28s4A15;a1DC9e43D9i26F3;a21C8;a49uE;!c4E15h1Fk32EDo1189q30Ds44A5t3367u10;oAFF;h3C2A;a69e0;a43Ee324B;!e4i6kDDs0;a9EFe302Ei19o2843y7C;!n0r0;!l0t40;!c243h253Es0t4246;a44B9e12F8i6o2B70p270Bu37A6y0;c19s603;!d20Ei3Bo1y0;a57i57;l612t16;a1B9f27F6t136;a25u275;!h23B;i90rEs885;s4CD0;a257FeDF5i3486o10A4uF54y1FF1;r8F;!a10E9;b1D4g8Bi1s11E6t3F00u0v2CA0;eB99i6o48B6s83;i2519;m1C19;aA4i36;a24A0e4F67i3416o1CBy7C;h3E;!h3E;i1345o248Fy0;!s0t4BC0;i2851;!a1EFd0l35Bm63s0;d80w80;e10En2t0;e1Bn2t0;!aDe20Fi18EFo29s0u1D;e6Eh92Br62;!d1FFEe0h29CFi2DA8l7n22;!l0r55t3;!a2CEFe1800i2ADAo2948p2987r1D0s3EDDtA69;d151;!k5DtF8;e3A1u1D;p4AsC1x7;a506f874i1DD5o50D6;!iF5Cl1Eo969s0;a200Do36;!i21s0;a596;i10nE;gBs0y34;a1BCFe1Dr1u12;a72e1Eo45D2;o2A4;e4EpD6;a24E5b2E03c3C44d156Fe2A0Ff4799g2C98k3D3FlEA6mE72n3C3Ep181Dr106Cs2AFCt323Dv38w1D4x4348z40B5;!a399Ee22Ai66l22sF73y0;e3438i2EF8;c19m25D;n0r4B84;f89;!m7As0;d1e12r7;e5t150;!e5s0y0;d0e1r1y1;bAB8;k0n4546;a4D84c2DDEeE4Fh1DF3i328Ao1DC5sEt1y513C;!e14Dl7s0;l58r168F;a8F8;a5F1i1A;cEFnFr25;t5116;!i43y0;z1DA8;a4965o50;!c1C92h5137i52Dk58m74Fo41Fs1124t4A8A;e15Af37l7nFs11;e1Bk3;e40o6D;!d0l16Ar1s0;aB14;r344;!n292B;s7C4z19;a1085b4639c4178d3553e2105f1BEEg3F1Ek1748l2C11m36B6n4117o1EFBp16ACqBFDr457Bs47DBt3475u4EA0v1277x3370z2ECE;e309i6;!e3060i6;a634;t30F3;e6C5f7s0;u2D94;!a558e3Fn3410r3EB6sBE7v3;e154i4C73v58;!o46s0y0;e67;i44E;e23;a7F1e27Ci3AA;d0t200;d0n525;!e3EDEo1s0;oE02;o49C4;!a0eAi6t47;!a4112eFi26EDo54s0;c2Af11C;!d41DBi1183;a1De275iD7Do1A27;e109o9D;d0r16y16;l1t8D;o72u2A2;n1tB;c690rBAEs3F78;a20c3Du14;c3d1t1;!b112d0fBFl58Cr2876s33Dy1;!e4i9s0;!d0r390As0y0;!c3e0l3F80m25Fs0t4FA;e12C;n1D3o29;c345d286l2C40n3711s0;e4917i35B8y0;!c11m138n0;a520r26BF;!e263Bi6l7s0y0;e1i333;!e224l7;!h2E0AtFB;a1Di45CCy107B;!e26i43s0y0;m2D1A;!eBDEs0;a59i2B6By0;e1Bl7n193t84;s14DE;u20v48;a19DeAi6;a15FA;i4Eu8;b7Bn86Et19;lEEr1;!bC18f3696g4412l1A69m2FC7sA69w4C7F;c52;!l7s0t1E;k1El1E;n2o3BB;d25C7f1l450Bn110t22FC;e12i7Dr304D;r3A4;!e4i4C1Fs0;c32n0t4A;c4D26f1963k30D9l2279n1308r2BD2s854tAC4;a1E46e85i4E3Fl1A6o46u5;a20u5;eEFAi3166y0;!eAi6s0u7D0;f1t2C16;t2E73;!a7Fe4F38i6n0s0;l4F97;c30C5;!e67f4DD9i429El22o1E9pE1t2549u6E9y0;b1BB8d3F28e32g2A6k2Co2B20rEA1tDA8u1FB9w4E7B;!e281oDs0;!a2444e2D46h982iC3El3BDDo35FCp16r332As1Ft4E60u1108;d0n540r1x0;!a876bD50d4702eAE1gE52i2B75n25A0s0y0;!e36F8g42E6h121i18Dn145s0y0;e67Ci6o10;lB4p7u30;a20d0s0;a8m3o2A;e1t1E;c0k1l138Cn83s175;n4BC5;iE45;!i152o168s0y0;i8l3;b1Ee4l16s19;a1m6C0r1F3C;i13u295;e3333;f3C77gDE3l28n3CBCr0s16FCt3774;d1g35n3r60;c3C7;h68o68;a55;cBs364C;!t4690;a1F5i3Fl45E2;!r138s0;a4An1DB;h55;n1E4Cr2F61;!s0t4A;!i73t602y64;iBoC5;a35Co10;n3Ft7;n2E80s107;c2A99e1517i3211l407Dm4Cn1BB1s3ABEt3AAAu46D9v18;c1s3t7z3;a299r191;a0i13u14;a2660i25F8o21CA;l1r43Bt3;a2175e2CE5i452Fo456F;o12p4118;a2529bF79c4030eD20g252Ai9B9m3B40n381Cp2183r319Ds7F3t4921z3F1C;!l5Fs0;gBi15D7o4B6F;!c428Dd785l1n61Dr3362s231Au2029xAB9z83;h28;d0e5g97m3AFn483Ep347;l32Es3;!a7Fd1e4i66s0y0;!a2BAe1B34i3560p3871r17F0s0;c182t5F;!a88g1Aj9BsDF8u34;p1C93;e1r7;!e5r7;!e1Bi3Bl7n22o88pCBs388F;d0rB2A;a247Ce21CEi10E4o36D8u1020y20CA;!e1i96;m1p1Cr7;a32d0;e1t88;e57p8t0;e1Do2DB7;rB43;!b1Cd1C0Fl1C18m4D9n25t43DD;c0e79;!a75c247Ee1i52Ds1B8Bt12AA;h3A1Bt11AA;k1l1;f38l87;a479i25;n2012;s4Fu5;i25s3;e12i1634;!a3BBBb16FBe3DF9i3803l76m1Eo4E01p330CsF1Fu5;e90l3;oEs44Et1291;l3AA0tB;eAi6o1B5;b2D3Cc73Cr4B35t1;m7E;!a1EF6c9Be23h3893i6k76q123s2A97t4B19;!f37s0y0;!b1726g167s0t56v6B3w5D1;t2B6F;!s0t5A3;rA28;!e87i490DoF2s0;e23i254;!d473BnABsA13t3E33;r6F5tC7;g71Ck65Ct23A;!a2EABd306e608i17EFk1n4C4Co38F3s1C9t3639u5Cy0;e1306i6;g48t3A;a4BeC;e42i73y0;a2A9Eh2213o1;d0r2Ft719;l1F77;!d0s0t20;oDEr431;!eCFi21l22s0;!e9i8Es0wEDy0;!a1DFs0;!e4i6l22s157;c9CzCD;a20e1i597y0;a4C9Eb1EE9eF7Ei254k2F59n1629s19C9t3A7Ev1B94;uCy0;l98B;!y95;a72u3B;!eDi65r7s0;a51l31B;a10e239Bi6;a5F3h1321r3515;g5C;c2DE8i18Bn37A4p4227s117t4DB8wCx1A9;a2DD8eAi6o22DAu4E;!p1FE2s0;!e12Fi3F;!e521i8Ey0;n1s3u5;!z394;l0r2F;f305Bl28n2Dp2EE7r4F9At1097;l3Ar7t10A;s77;c6CBs107;!u34;u573;!r29Cs0;l390Bn3;e163Fm18oB8;a0t1;a1t0;a174e1E5i6;c19e30lBnFtB4;o12Bs2C;!a88d9A0f33D7i13m3F3s0;e1i96l7;eBiE;a88eA8Dg83i13o4A84yB2C;!e209g43Am2Eo10p156r106s141;!e4i63Ds0y0;b142Fc2400l307p1s57t3689u221w2DA3;!i34;aCe17g1;!f2120l55Bn1D08r35DCs7A8;a15BBb1420c288Ed25E0e25ECg251Di44CBl2BE8m1F10n4B9Co362Dr3BF3s4AA9t1C7Fu509Dv2DE0wF11y4B5z439B;e1i59Do29;!c7e0t3;e37Ei5ABy0;!b357s0;bBn1A2;!c0d293e5s0;b3944c4C58d4EE2f39AEiDBFl2C8DmC9Cn264Dp44Fr1E18s31Ct988u1v2385w161A;!cB2h1F;d1i2By0;!a307Ae4i4817l35D7p45Cs0y0;n2E46r4D8;!e4iCCo2104s0y69C;!cFB5g1FDn1CC3r2266s0;i2Bl44y0;l7nF;c3DsE;c1D5g995k3A02lFA4o107ErE59t445Fu232DwE;!a226AeE8Bi1925o8Fs0;g48n4B;n72E;d0n1r0s8t1;d0n1r1s3Et1;!c93s0;!c7s0t353A;!e500Fi2CEs0u125;o3F;!a13B8e3E9Ai94Eo9D7r602s0;c26Ed0i12n1004r63t2E8;!nEs0;nEs0;nFr662s11;o9r1;a5FEe1;c46D1e1g50CBr386t44u14;a147;i4D3C;i38s1496;!a8FsA07w22F;a1eAh1A9Ai6s1DB4tCC9;l151s4B2;a563;r1v62;d1k2976p28t4A;e72Co94;e71;a373lF2x4663;eB7;e1i133y0;e15i534;!e4iADl418Dm61o3C5s0w325;iB8r22CCu4BCz2DD;a0i96o5CD;a34B1b164Ec3D77d1C02e31A9f2268g1i31AFk5l4E7EmC16n1477p2066r4CDCs41FFt29F9v89w233Fx1Fy1CA2;u376;a449e9;n32D;h526oE4;!r417Fs0;e124i1035oA67u5;c0d1n3t5E;a17ED;!e8i1s0;cD1l0;eBi34E0o0;!w91E;cB2e23i6o10u12;n286Bs9C;c15Fe5s773z48;f4C3D;!d0f37n8o10r7s0;h84n28;a49B5e4E89r2680;!e2D9Fh1BC0i4173o493Bs0;!eC0i6l2A7r2980s0;a442i11C;!e3478s0u1C;e1Bg8BnFo9;i18Bo74;o53A;i194Es0;!e46Fi6;c1C5Ee1n2t3D;l30B;a165i1F35;!eA61s0;l1Em1E;e12l1n2;a1560e26C2s4CEFt22B7;n29Fs8;!c24Fn58;l15EF;!p2728s680;a125e1638i46DCo1D6Dr1780;a246;!d7Ae0i333oF1s0;e457D;n16r0s8y1;a1BDAd0e676i37E4l42EE;a4D96i43B8o10FDy0;r2045;c302;d16l1F3Ar2C3Ct1E;aBAe4D8C;i1045;a1e212i636l5Bo10;t97F;!f183;a3243b11A7c1566d39AFe159f4A8Eg4A59h1i252Dj446Ek45B3l3163m18F7n3E9EoF89p4EDEr1A4Es11ABtCD8u3CB4v164Bw1FD9x0y1C4z436D;!a104Ee3950l76n126o1;d0s7;r462;!e10Ei7B9s0;!e4l3s0y0;k2Cl1305;e447i866y0;!l88Br39;d3E3E;nBs3u5;e41Ai21v58;d3B6i188m0s1B6x22Fy0z3C;!e4i6s0v886;!e3D2i6;c771nFo1s13Ct241F;e9iBl25By0;u1E4B;c2Cd491Ds0;s203t0;b145l97Ap113;!a1EFl1s0;l2554;!e0f37i60;a0f7t7;r3F;l63s1F;!eEl19s0y0;!e2168h156i21l44s0;s551;s1EAtB;s7t3;i3114y0;!e104i21s0;b93F;a1B5i57;e4iAC;!g1r0s0;!c199n70r3z4AA;e4504o12t1300z89;k7C;eC8;!a24C0b2F5Ec6D0e0f8g1323m3FA5n4FB5p31CBr3B59s0u3AAEv5Dw438Cx4BF3;e15i313y0;c13Ce23i29DEn1F6p2641s3;!h9Fi3;dBh1;s44F;o1DF;a1D21d0;e62Fi7B5;b1Ct3;a2F44b2C74c2B11d4475e16F2f2037g4CABk15A4l4F0Bm4B31n2826o2132p4B76q4EF0r1CAAs1E60t2379v3DB1x1949z1A1;a3342;!e4i27Fs0y0;a132i26A2;eAi3AC5l1ED3;m5Ar7;!a605o1;a475r2C;i2486;r156E;g380tB4;eAn2o10;!eEi1F34s0y0;!g3Ck16r1Es0;!a16e24i6s0w266;t2C36;a1C0i2DFCoACu1C0;b3BEFc385Ad3D11eE28f26B9i446Bl29D8m2F93n3266p3977r119Cs17BAt5034v1A13z0;o31Bu125;e15ElB;!a158Fb3A25cE1e1501i23B3m177DoE7p4453s0uB6By0;!e15i6l44o9Es0u34BE;d4198;!e4i6s0t35;!d421h1FBnF6p44s326t0w130;n5r16y1;i1ClFBo2EF7r1At267Cu12F6;!a4FF2c219d3B45e3E94i24BEj4A80n4072s0t4C01uAE0z4445;c11n2s699;a4Ae1AC7o30r15D5s0u1;n8r1B0t2D1;!a1CBBe84i1A7o71u4A0;l1m3B7Ev44;a30i2By0;!d0n22FAr1s0;i7CE;a1DA3e3D2i6o12;i20y0;!hEBC;i23E3;l3983;e53Di65DoAC;!a9l7s0;a16e40i44D5y0;!n0r16s0;e334A;b7Bl5FtB;!n1AB4rCDs0t85u60;!e88Ci54;i2B31;!a30e3D2i6;c36FFw44E;a3FA1e37E0i31l24D8oCF9r2F11u2D5A;gBl3Au41B;aBEe50;n671;c0eB3l7;c4568d34B6e2760fD62g49FBl4AE4m2772n2420p4701rDA5s17A0t4394v1ECAz5099;!b1d0s0;e1D4A;l2Cr89;!a1EFd0f37s0t16;u4DC7;e12Er27D;a4BECl4m4AEsE;!b3Cd0m2En16Fr1s0t1;nCAs18A;e37C1;x4996;!oB0s0;e3F02i6y0;l49B;l1D3A;!aF3i1Dl16;e493l360Br3xAE;!e12i3Bs0;d0m18r1;!lBp3DFDs0w130;f507;i3Fl30Bo29s0;e1l7;a1B7;a1e12Fi3F;d3l4F;l1D8r0s0;!d0fB5h10Cl22r1s53By9A;c339;e5117f342Ai4l44o3240;c3CF8;i3Bl433;!e10l170;y50;!eAi6o1s0;aEi206;!g5Fs0;i371;q61A;a1832l32EFo227;!c3DFF;!e39C9;!e4i86s0y0;!z3;mBt15B;l1541;!a1eAr7s0;j4ADkBn6Cs3CDC;a328e45EBi17B0;e1nFqC2;i4A4n24Cp1;i9u9;!d25;o7AF;u412;a1867b1930i4A83o25AF;kBl2538n2A0Br25s0t88;a442e1Di29Do29;gBt3;i172s3A79;!d0iD4lEEnCB8o1rEB1s217t2Du1;p19B;r0t19;e4CE3hAEi6;o3203r2A8Eu491;!j101l1FBp8D4s0;e6Dy0;d4759l2DCFp113r3360t1B85u1BEv205A;a1i57;!l1Dn3s0;i1Ds50BC;!e3103g3958h314i21s3F42w463;!w130;i7Ds516;d19pEs5;!e15h16i6s0;!e40iBo1p156s0y0;o88;i7B0;a180c0s19u14z19;!a10e56g4EB9hE1Fl2FAs0w3ADA;!a75t9D0;!i6p18C1s2F4;c128l63s1F;!e1Bi8Es1AEy0;s18A;h2313;c3EB0d3Ag4Ak28n0r4869t172E;a9e9o20;d14Bg97t1z19;a4Ae15i21;a2D6i21;b1Ct13D2;m5DA;bDBl3B2Co4B80;c1026e4464i3A65o365At4AC7uCD5;b4212d413e2261f271Dm3945n2E0Ct357B;g468D;!l22;!a4Db208El112m2Er27D3s0;a14A0e4E97oE9u26A;t1066;!c11e23h27iBCs0t4A2Cy0;b1Cn1;p6Cs271;b7Bn2p2B;eAi6t2E36;d6As0;!d6As0;a57i88o20u6;!f7FDl4FB6o10s1DC8t2079;e330i2C47y0;r377;a15CeD4r56;a4E72b4B0Fc3DE2e4338f50AFi4AB8l3335m1C4o2A2Fs38t19B1v3E6Ay1A1;l1A0Bt47;n1t5B8;!e159n298Ds4E92t5B;!c89e23E5i47E3l7s0;n438E;!e4i6o3A53s0;d4241;!e14Ci34Ds0y0;eB3f7l7;e1Bf7l7;n2s430z3;!i140s0tEB;!e15i6o29s0;t35A9;e4871i6;!e4i6nD5s0t4A;n83sC1t2D;!t4C38;d2B06n332p346vFD9;!a0eDl7;a3722;c32o124w9;!u1C98;b38A8n328Dp65FrBF6s3BA9t37Du4BC;a105c0e1i0p1271s15Bt21FCu4EzFD;c2BE;!e2712i27DDo1s0;!n1860r121Bs0;a389Bb161Dc28D2d1951e2CD2f50CEg4B59h1706i4848j180Fk2260l28CBm12E5nC84o29E6p2396q2E1Ar5041s29F6t411Au4135v44DEw311Dx42C8y4870z1FC7;!a1AA6o36;!d8As0;g3Dn2o12;e2C9i36D0o36u14;!c9Ae1547f255i17Fl50E3n22oDDs0;!a4F3Eb2F5Ac3489d1D50eE5Df23FAg1737h3440i6j2248k320El3ECBmD3Cn167Cp33D3r2C1Bs4E79t33E6u12Bv1B33w3F5Ey240;e1Bm3;a4CC7i25o2C5Cr1875uA3Dy52;n28r151;a1De42o1;l1658n3E30r2633tF25;i100;s5E0;a3678e91Ah4A75iD84l2014o2B4DrEEFuBA7y23A6;p9A1;!s0t3CE6;aCe5o6B2;!l2EBB;l3A9r84;k315D;!e4i6s0t58;d1i31;l7Eo10v3;i46C;g167pD3t44Cz3EB;e5t3;!aCe4i1FAo29s0;!f183i2B4n22r2C9s466y840;b3s8;aD0p3F0;!e4CFg815s0;d0n8r1;!e1l2Co698y0;a20l3;e12r229C;g3Dl0n4y0;a8w1;a3FE5i45B4l20D6u3E68;c264Cg184k185n222q766s1486t47;!a7Ee489Fi5008o12uEE;g0t1E;o3314;a1049;!m29;!e4i43l11Ao9Es0;l8A0;c316d1;!e4B28r1117s0;d16Ag4AtEF;m23DC;!b30FAe1Bh3ADEi3Bl7n478s0;!e15Ei4B29r58;u637;!bE20c2CECe15i18Dl32AFn22sF0y0;!b1Cg635n4B0tA37;!l0r4t3;!e104f37i91s0y0;!a49E5e4i14DAl22o44B1s0u29D6w25F;aCA8o2B4;!d0r1s2D7Ct993;a4A6Be13Fn8w0;!o4783s0;l1D0B;!b106Ac2E0e4f42F4i21l1CEAm3F52r110Fs13A3w3636;hAEt28;!i69t27;b1527c3FECd346Ef49BFg4839i2D21k2Cl4D0Cm2249nC26p4BACrD25s3D35t2E40u275v2Cw28y3322;tCA;!aA4e67i21y0;!a977;k1s2A0t1E82;d7A7;a1n38A;l70m0;e314E;a3DEA;!a24CDe15fC3i21s0;a2D4E;c3C7h1Fs1656;e1i1Do513A;a765eEACh2490i476Fl3D4Br49B4u2A7A;a531b2A1iBo373E;!i21o110Bp1CC1s3D7C;aA2fB0t382A;nE1;e26i0o1;g7C5;o8y0;!d0m367n0r1DDs0;!d0i6n48Es0;!a39Cd0i1649s0;aDCh68F;!a16BeAiC9l7m8En22o255y0;nC21;a1m63oB9u34;mBB4pA15;n218At1;r567;!i3FC6o3877t345E;s3Dt3D;iE6n0;d0eBi37B7o2222t38;dCEt19;n1rEt29C7;!e13FFi6m2Eo1;r25At11EA;a1i0k0u4E;n25r2EE;a322e1;!b1AAe1h4613s0t2E2u202;c123s1980t3A74;c2EEk1;!d0f37r1s0t4F9u34;!b11F3e7F8i513Fl126Fo3337s0;d3De4;iC96o12y0;jB;a69o86A;a403e235i559y0;d37F3e1r7;l323Ar57;!o6FuCE;!a238BcB42d30C9e1AEEf3FE9i4ACFkDBl4D70s0tB6Dv1AB3;!a549e4i2E6l22o377Bs0;w9A;b12Dc19Fd215CmB86o247t29CE;a4AA2b4B70c2A78dBf38D1g152Ai2BBAl368Am1579n4838p46FFq123r3779s1B07t3CBEx3F66y6C2;a270u34;a20u34;e42s0;e9i6l3;o423;!d0nEs0;a191Di347o3853;g97n25;c2CnE;!eBE2iCCs0y0;lCnA94;l12C;!e153iB9Dl22r101s0;a5De894r418B;t7E0;c4Ag4AnE;e47CFk0m185nDCFr5006s83u1007v3;a2D0Fc37A9e65n2oCs4C79;!i6s4EAFw169;!cF2e0r1A4;!a3DF4e15i119FsF0;cA47;!dCEs0;e1i13o1;a819l1E6u2F3;!r2651s0;cBo10s68;e1Di722;a0sFEu14z3;s1CECu36;!i2163s0;b1ACn917;e2D1Co1766r4207u42D5y52;o29u34;r93;c29o84r1E3FuBA;t213;e6E7;!e1Bi16CAl7n22;a429i12;a1E69b9Be260Bg8Bi16B2m5FDn1o2Fr61Cs8u3520z5A;o3913;c41d4A3Fe1E5f1E3g18i3A7l227At28y0;e76Ci8;oC7;a105e1Bl7n146s107;!aCe41Ds0;!aF06;i22B;!i22B;g35s0;n8t2FE;r26C9;o75A;o4DEB;l22E4sB;c1000fBFs2BF;a4B8Co2A2E;mD6;aEE1c2252e1C5BfBFo43C0s511x0;g1wA9;a2A1D;i321Cl1A70;a1F5n38A7s3209;i6A5o7E2u54;p2F8Au2A3D;n11EF;!o2BA;i160o29t41;!s0u1F09;c3A81dCBf45B2g2639m363oB9pE4Er392s4199t1198v3888xAE;!e15i6l48s0;!e6Ei8En23B0s0y0;aCs3t7z3;i10D4o1200;e1E5i3EA0m38p2875s56;d1l3946n1r415;!a9s0v62;!e357Di50o29s0;a4704e4D4Di4CD7o1216;!e4f37l22s0;a244Bo50;!a5E1e41CAi6o6BCs0;!e79i18y0;!aF3e4;e691;!i3Bl7n22r0s8t58;!l7n22o29r0s8;l4068;b7Be1;l2F;!e957i18Dl44sF0y0;l850m1s29E7t2E7;e8i13oA9u14;l17CBt1;!a7Fe15i6l7s0;!e24i6m47Eo62p4C;!eA3Ci6o12s0;!b1ABd2582f37l1m2Es1616tEB;e5B6i3B;!r0s8t1;e1Di11C;!e15i6s0u1D;!e4FFCi23Cl3BD9n22o1s0;aDEe351o1;!eB02i6y0;a3A95e1AAh5FCi1DACo1E9Eu33A4;e2006i6E0;!g755s0;e13Fi21;eAn8;e30nA1;sBA0;!e10Bi21s0;aD5;!aD5;!e617i21s0;!i3662;!gA2Ch9CEm1EEo1s0u3903w3D6;a17D0b3690e3E11i3054mA80n23B4o38DCp3749u2FFy0;a506Ac41E1e3A34f69Ag4E88i101FkB16l2DE3m19CBo2154r41E7s8FByB01;!r1FC;!e15m2Es0;!l144r1s0;h312A;d8Af16;a29En37B;!o29y0;o29y0;!e4i6y0;!a46Eb354Ed9E8e4Ej9Bm659p2BE3s0;h400A;s1B1;d0n1AF;r42E7s44;l227F;r15B8;!r56s0;!i31o46s0;o6B1;l1r31FE;e1n4805;i18u3y0;!a48E8c681f15E7k5Dl17CDo7Dp5Ct4AEF;!a59;r8s8w1;!d0m63n0r1s0;e1738o2D40;a88i4F0;a264b7BcD1d2DA6l1m7D3r3F46;l1F72;e67n3;!d0f37g1Am63s0;e2EDo6DB;h2FA9i43E5;!e15i21l44s0;r28t11;a9FFe5s282t1z19;h8B0o817;!e42D2g3E8Ci4C75n10BAs0uB;!a143c219e0h306Eo27E9s78t4277z7;!a4DF9e15Di21r7s0;a26F9e16Fr1A;!a1e1i13s0;i25CD;d6Ai0;!d658;!a4503e15i39F1o36rCDs0uC4B;!e12i1FAs0;a51e17y0;a291c24Fe21D9i6l2305n47r365Es3CEt0;!e4i6s0t0;e1B01h3Co1;l1n4t3;oA2F;c23Ai10;!d0l1s0t1y0;o4D43;e47FEi1A;!e263;e696;!m18s0u5;!aD1Ab2477e27C5f4E44iC9Es0u1351;r271B;!a7F;!g3l1s0;!d8Ai96;!b24D5e24g99Fh3561iA0Fk3085m2Es112Et20FFy28F0;!a1DBDi9CFl22oFAEp1894s3BDE;!e3FAi6l7n22y0;a2E56e18A1y0;a202Bb1EDAeB05p3218;c94lC;e3641;i127y47;!n15Bs0;!l2DEs0t1;!a4De4i6l22s251;r3ED3;t391;l0t2BD;a7Fe3EEBiCDoA44;a4257i13o29;rA08;c1d21Br2CB2;b1Cl1BBmA6C;d205l2Do4u36;n25t11;eCo4E3;aDt1;e7ECl0;n18t3;b1AeEn7;t3EEA;!b126c4B3De283Ff1C0Ch5007l2A91n22p27E6s3CBAt1266;g127n47;n1E33;!a1A5Fb4275e20B6i1253m1414p3197s0w49E0;eA6g97t1;a11Fi4155oD4y0;c2FE5l8r278Cs84;i1663;a399e17i3830;i4130l25By0;!e405i2101l44o3DA5s0y0;!h1F99uABB;!c2B89d2C2e495Ai0k5l2C5m2En40C8s0t1;!e4i6l6Cm2Es13DB;!e9iBs0;o33E;f6D5;r25sEx1F;i8m0;!e82i6s0;!aB67n1A67s0t88;o6FE;a2E68e1205i2F00o10FE;s48t7z48;!fEDhEDi86;c3C0f1g4An34EDp301Es44t19E;!e15i91l48s0y0;d0n25r1;!e4203h114El44p7As0;a2A62b1E44c2727d2214e17f2624g34CDi416DkBl40C2m508Dn2DA9o3C60pD1Dq3DBDr3007s42E8t2E77u4FA2v4576w3162x1Fy40AFz3568;h1BBA;a9e470i21n0t4BB2;d0n5r1;t234y47;!a273CcD5e4F7i23Cl7s0y0;!e29DCs0;eDl7n2o1;!e11Ff37l22s0;e1Bl7n11E;e30i34BoD;aCk7;m0n0;a28AEeE96h99Fi4B89o1CAr1E6;!eCFi34Dl19CFs78y0;!b101e15h28i2A8s0t58y0;r2E24;a18Fe950i462Fo29u2E1Cy0;d0r2AB0;h1y0;a65i59u10;i277u5;e4i1B68y0;n1o10u60;!a20i5DCo29s0;a59e95;l3m3;e1n0;l0s14;e371Ai66y0;a225E;e4B14;o653;r2FD;a10oE;e17i94l148;r55F;a47De12i21l3o425C;!r53s0;i9t2B;!a16FFc1474d47Ef446DlD72m4648n33B8o13F2p2C69qECAr988s2631t370Fv317E;h9C2;a1A68e21Fl225o15F0;c2EEl23B2;eDt1;r21Et11;a0e374;aDi31;!a88g7Ah3504i34Bs0;!iD9n2Bs0yD9;e291;i39F6l3y0;c0n2s503z19;bD6t1E;m19Fn119s5E;t3E84;!e18r119s0u2E9;c2818;!a1e4i27Fs0;!c5EBi3FADo78D;a1C03eDDi10CDo31u30A1y0;b2BBFc38D2d36EFe15DAfF69g4C8Dh4D45i1670j3776k2B2Cl273Em4885n186Dp2DEFr2F27s4F8Ft31E6u2B26v3E95w3442x56y462Ez15EE;u22E;d276;u12B;c1Ag286m9B;h87s2C;d1n84;a519eAC6;a110e2BE1i6;i2B9F;a32h38uD4;oEC;!i8D1s0u5;a50o65;c83l1A;i111o12;dBn87;l1An8;m3DE1;e4i6u36C;s2E1;r5FtB;t4F28;!h618s0wEDy0;b3C6e0g0l5058;n2s619;a4Dc9Cm28;!s35;f153AlBoBE;a75u295;!i51Cs0;c93n2sEt5E;i1Dl6AnAF1;!a25o5CDs0;n40;!e15Di6o1s0u14;!eB58l7n22;a36E1c8EAe4F05i3A07s3518t497D;a0n0;d0r262F;aCoC;c1k1r8;d1E2s0;!a972s0;c0t205;t348u1B4;h1732s1E41;!b1D25c2E53d0fB5g226i21jA7l7n45EFr0s902t2A19w17B1y1;e5s2Cz2C;e6Ai4E2o69y0;b34El0r3892;!a2Ad89Fe2AhEDm2Ep300Br50EDs0t35ECx1F;a15CB;aCn2v3;a1303c324eF5Di26ACl2839m133Co3C39r5063t3E3Au17A9w1Ay1B81;m6C8tC7;n347F;!h1C6i3856s0t38;a2EF;rE1;i4lA8r171;d223g50E8n344p46s84;i40;c1D31gBlF3s30CD;aCe15i6o12;r4013u1ECy1;g1o953;m144n47;g48r16;!a2FD3b2699e1f3FCm1F2En4D9Ao1C81p1095s355B;n69;!i3Bl7s0;n1D2t19;a8c606e4161h4001i1B3Dl1044m3A9Do23C1p4028t3C94u3CEC;eAhAEi6;n0r2As5;zDB;!e490s0y0;e45o45;n4E36;e12r19;l2C7;!e0t95;i1F2o81y0;!d186e4i6s0;c32t60;!i5s0;!tE2;l5D3;!h9Fo6FtEB;a9BD;m0s8A;a59e17i65;aA8An20FB;a43Ee1r36AC;!b1CBc1A86d3EB7f136k2B8l136n1s30C7v2C;!l3D31s0;!a45C6b1270cDDe13ECi40BBm3F26oE7p4ACEr135s2751u1A4A;e3135iCCy0;!aCe15i21l87s0y0;!e25i6s0;e1BsE;!a4D9Ce5i155Ay0;dB4s5E;a2666e23i6oA39;!a1De3CF5n22s157;i4016o38A;g3Cm2CACr303;h4F;!n0p46s8B9t2EFC;h7Ct4961;!n289;!i13s0yC;a305Ci88m5DAo54Cr5As2B7t17By3524;!a4ACDe3479h43DEi4D49l2E16o45FBr199Ds0;g9s44A7;!a18Fd0s0u5;!s0u9A;!a1B4e65Af37h10Ci2DD4l22o29D5s0y0;!e4iF9o12s0;n0r1yB;d194g138;!a50EBb273DcD5d2665f381Dg41l3E7Cm2En0pCFDr3E19s3182tE3u36wCE;v19D;s82F;eAiF9o8C;bD6Ac4091f228Cg10D1h3C69k3267l2D5m40D8nEA4o38E0p4FCBr50DBs180Et28A7u2898w3A1D;m387y5;!m3s0;m3s0;i561;!i6r55;a20Ae4633i6o12A;r1651;a59oC5;i1392o1;a2BC9e17i31o2FF7;c1e5l443Es14;k27n0sE;e1t62;!b4087f37h183lDBEr1s40DFt4A8;a415;n1t2D;h3Am0;d0m0r1;a1071;i7By20;c0i25;i111y0;a51i1C59o1F47;a1c128m85t44C;gBn25;n16o1B9;a3BoE9;r3AB;!eC0hA3i86l3E9Cn22s0;h56;p205;l115;!i8E3m38oDD0p695s0u17AE;!e79i2;!a4De15i190s0wA7;o2Ay1;eC61i3A7o2A28y4D1;!a3078h460Bi3A90s0y28FE;!a25DAeA;!bBg97n259pBr2BA1s0t46B5;a4294e9o54B;!a47D6e2EE3h1i152s0y0;n1286;e877l473mB52s44C5z3E56;!aCi5064s0;t248;!tB6;a27FBe36D5i6oCBu360;eAh526i6;a3823e2BFEi16B4o343Bu38D0y40E2;n162s3DB2;l2E4o12;a19AB;b1Cd70r415;i9n2B;!e4i6l19o9Es0;!m4EDAs0;a411;!eAi6s0t21DF;u1C8;!e0g555s0;!b435AeF7B;eAt236;!a0e192i6F8o1s0;!a75s0;aCs0;!a155De12gABh1B6Bn4A3Er4C1s0u1F5E;k0l362;c1r2Ct426;e315E;!s48t0;!d23EFe1f37i1E99l7n22s157y0;aB9i1Dl2A0m2C4r313Fs84u26ABy0;eBu44E6;b158EsC7;!s1C9;!b42Cc4722e1D65g207Fi2B2k4El4E8Fm4B0Cn2C4Ep15F8s2BDBt1052z2AB;!a214iB9s0;c19d1E;a75o9u14;!a12d9Bo12s0;h56o10;!a495eAi6tF8u5;iB9o1E9;k3x0;!e4i6l36Em1s0;a86Fc49Fe189iC9k567u4831y0;b970c1571d38FDe1643f108l4A1Em1n3FB0p26BAr1A89s2A15tF4Fv384x3E39z3EFD;c0n2s0;d4550e1i5091l33AEo3E4;u1521;!a20FDd0f1BCm2En1r1sF0y0;a175b4A0FcE33d5Ae1fCCBg2B67hBABi2484j18AEk1995l3567m1D1Bn4F51o21D8p2F72r4C5Bs4D18t4C8Eu2EFv2AE9w28y1729z3E0D;eB3l7n3434;c2Ar1;!a303d3959e212i468El1C4Dr3E2s0y3CC6;e1iF40;d785;d877;s9BE;l1B0n2E96;e32CD;d0g1i31nFD;i656u5;!i13oA9s0;eAi2BE0o46;j18n53;!a1542b1D7g1D3i1F20l7Cm25Fs0u1C2;n469;n54D;m2F6n0s3;c2DF6k33Bp33A;f249Dt5A;l225Fn27;e4806h37F7i6C1k3327o1DC0t1845y0;a14D0b1FD4c2526f1m2C3Fn5023o3DE6r120s21Dv2Cy2CCC;!e4i6r1s0;t7B4;!eC0i2ABCs0y0;n21D;e1t93;t535;!d0g80l6Cr1s0t16;c7s7t2D;c1s14;l24Dn8t2E7;!b85e4i6s0y0;g3D;i4n3sC1t2D;!k11l78n8CDs0y0;!a1136eBBEi25DDu5E2y64;a14c2D26r161t1;!d3Ai6r1s0;!e1r19s0;!a0i5AEp3FC;!c2Am23A0n294s132ExE;!oDs0;!g1o29s0;a1e17i9Ey0;!d0i6lDB2m4CAAr2D7Es0;e1Bn3v27;i16;!c32r0;e1B1;a530eA81n320D;l62n337s8;a12o3B48s3u12B;g3n1;aB8;a1606e4E05h49EB;i4234;o5A5t2516;!a28D7e208Bi3E37n22o715s0t11u1F26y0;c22DlBs199;!a10d384e1D11nDBs2CE9t129w9C4;r5FtB6;e1E5i974;a4Be4i312y0;a3F2EeDA7o2EDu45F;!e594i3l7s0;!a19BCe30i279s0u295;a928;aACi805oB10r4D8Eu128;a4A91e288i6k1DDFl1DB5w622;a65i6D;!r2EAF;k16s4C;w25F;o1ADrEB;!m4D9s0;eA9h1Fi21t4D4E;!gBi206;aA4l27Dm58Dn1C5o2192p1Er12Bu12B;e17o8A;c4C96m33An4s84;!bFDh4845;!e1C95i2C85s0y0;!a12C6c348Dd47D4e2243i66o4205s0t4515y75;n39r1s8;i30o5EAyC4;l2890n1;c0n366;c0e5s14;a56Ee1DFBi484Do49A4;n2t3237;b173d1C5l62m63r29DDt173;a17C2bE1c1DF6e2AC2i16CEk1781l32CEm1Ao4C82p1Au13FDw66A;e309i6o35u49y0;o4BB9u14;h1654;c0dBn179;r353;i3Bo74;!e4i6s157;!iD9;!a10l44u10;d1u32DB;!p4ED5s0;c3Cn272o175;!e4f28i6s0;l4r36y1;!g265i2Bo28r13Es0y0;!s0tD6;!r3Cs0;!c34C8d14BEf3507gAB6kB1BlA8Fm28n44D0pBEFr432As4DC0t38E3v37AE;!c36F1dBn277s0;e2C8;l35n35;b7Bd349g19n8t1A;!n3439s0;!a4Dd0r2Fs0wA25y0;s99t3;!s0t5CE;a2D3c13Bo1E1Ep347r577s8v741;c15Fe67;eAo29;a2722;!a34B3e48C7i120Ek5Dl1D56m15F3o1B5Bt2EE9u4Ev40A5;n656;b1Cl3n2o10t7v3;i38o80F;e15Af7l7n2t7;i6o2D0;i446Fn100Do1593;!a12b3DDc4F0Cd2B5g25D2h2F6Bl69Bm36A0n1FF7p1B17q2F1r192Fs2286t2114w6A;e1o10t1874;!c1s0u117;c1B00i2085n26D4r2E9Dv1Ay69D;e13FgBm37B6s38A4;a1CCo1;g2Cn3;!i27l6Cs0y0;!d3Al668s157;d145;e41Ai6t0;h3FB3s1F;a42h263Fi36;!e15i21l76s0t226;e1i3A86s1F;n28p28s9C;a1l18E3n32;eAi91y0;!eAi91y0;!e1iB9l2EC9s0v1AF2;a2816;a6ACo46;r7DC;b28EAe2D7Ai2D29o41F;o34sFA;e470i21;t3AC;a519f2AE1n171Fo46uC88;b1m1r1;r7s5;!b372Bc2910d4CB9e42BCf157Fg434Ai4269kD4l12A6mFE1n1DD0o4048p3491r28FCs2333t4D6Cu1B04w4C3Ey3D97z234B;!s52t0;a21eA3;s0t3;l1B9;!l87s0t33D0;!eCl7n22;e41EBi19DCu4E;eAo10;!a47De103i6s0;d38t47;r3s9E;!b181e1B2iA32m2EsF0w1D6;!pB5Es60Bw1BC;d1Am0;r1046;h1CC4;!a1DeA7Ai4928;a261b471De32A8i44E7m22D0oA7D;c15Ff24AnFsE;!b1FB5c4AD2e15f8D5g5F7h183i1E31l803mD26o820p45Ar1E7s106Fw169yF0;!r119;a297Ee201i4349o71;!e17i13EFr7s0;i8FoF;e23h68i43y0;i28E3;!a3D34i4F0o46s0;s262E;l29A8m897;m447Fs3EFtB6z3F4;e90i277u1170;dED9m2F6;a13C3e2ADCi8Eo71y0;e1D61o19E5;!e1i2619o1y56;e23iAD;l266;s80;a2348;iAE7o54y0;!a3883b31De4i6lBo1D55s0;!i4r0s0u5;o45DA;e1Bg3Cl7nF;e4iBCy0;a3B0D;t4E8;o71r225;f7nE;n150;!a174e4i3C2s0;d1n25r18BtBA5;t1w1;!l1Es0t12C;e152Ei37C;s18D7t4CD1;n0t3D;eAn2;k3EC1;n4FF6;g1BB3;h717;!c557d13Ee4fB5hEDi6k3646l1089p1E6Ds141wED;!i8Ey0;i3226;uE6;r13Bs2Ct31B0;a1i3B;r36D;!b2F5Fc1165e638h11C3i559lA5Cn22s141t205Ew55Ey0;!kF3;m1FFt3;!y1;h4002t18FF;!m357s0;a36t1;!a4De3F1h28i2AC3n1DBs0;!a9EAe1339h4724l1FD5o69Ds0u331E;!a1DA6d31C1o436Fs24E7;!b5113c10A7e2EA3g1B60i4AF1m28F6n2D37p1038s2D00t2263u228Ay2AFz1B5A;h77A;c32dB;a8t1;!t1D2A;!s0t83;b1c19d19;!d3i4s0u5;!e15i21l2Cs0;!a4De23hAEi21o4672t1u49;l2D86;!i31s0y26B;o1Fu34;bD4cBd5Dg5AmA31s1FtE3Bv38y1z261B;a404eAr19s1FtB;n3227;o5E;eB7h3FE;n47AAr1B18;s50Fw1DC;!eAg4902i6m2Es203C;!a88b2C33c6F1d849e42DDf3345g2F64h314i3l220m1768s2D75t2FD4v50Ew2F0y0;s2Cz2C;!k18;m3E09s1888t186;l1DADr3941;!e442F;i65o1E0;gF93iEl492Cm2AFEn1B15o3A46p2EA5s3030u4896v434w2B66;r539;!e1p280D;o18E;m1r8;i34vB;i4oDE;e0t1FD;!eAi6s0y0;r11C8;wA7;g184;!n35D1s0t0;!c1BB5d23F3g1Al403Fm4758n2AB2q123r28s3EtA40;c2733i600l1C6n28r21DE;!h1EE7k0l76p28s1265t13DC;d849y1;!e14Di43m61s0y0;t1A6A;f4BAAt76B;c3AB3;d0l143r1;!e15i17Fk5Dl7CrAAs0;eAi2A6Fo3D8Cs18;l4r9;a12eEi207o3E4;a3C13iF0Eo36Du2F1D;!a15BeAi6k329o1s0;e1E02i14CEo38AC;cEd49g2Bn7r282s5;e4i2By0;b42Cl8D3m333An1842p28F9t50F8;y4F71;i359CoB61;!aA4d27eC0i6l7n22s0;e5A7hB;a1i25lBr26B;i13y28B;!s385t3;a2Al650n13A;l1y0;g7E;o4Eu52C;f336A;!c17Ef19FsC7t1A;i2F77y0;g131m173tB;!s274;c3m1;!e31;p504F;nFv48;e14B;!e1f7i96s0;!b1F4eCm3E67p2B3As0;r2B3;r3u5;a31o20y60;s3036t2Dz48;c376;!bEBBf1k5Dm39EFp43DAs0;g2D7F;e1Bf7l7n2t1;a5Ce0o150;!n1Ap1r22B0s0;!l1E;a7Fh968;!e34E7i6m49CEo1133r3AD4s0t166Ey3D;d7m1E;!h10CiA43l7n22o230s0;e1E64i6;a3BiF;d0l0r2F;a154Fe1945o4BE2;b7Bt13D;i4C10;!c7e0l3An154t10A;!kABs0;!l7uC5;!d0l1r1;i3Dk6C;c1F9Fx1F;s44t28;!s116t28;d0n199;l1C6;h334F;e0o388C;n2D3;r6F6;!a7Fe4i66s0y0;!aCi13o1s0;!a1EDe4i30B2s0;r1A2;b5;a283t20;h36BuB07;i943;!d47A9l176r1s0t2443;a0o29;e3A5Ei73oB27y64;aCe2499;e454Cy100;l2Ar9s7y1;!a4Db2AD5d0l147Er138s2E7Fy1;k16n0;n0s14;p0w0;s2At3;r261;!e1r0s8uD;!e262i6s0;r5C9v7;a50i3Bu1D;k3r8;e52;!e1Bf2Dn193;n2s99v3;aCl3m0r3;!b2335e263iA05oEs0;cDEs89tFB7;e4i6o1;a1A35d34A7l48F4n33C5q6F0r6D3s266Dv2247y1E;a34B7;!e27h95Fs0;!i31o10;e6Df1i13y0;!c9Ck144r28s0;a1DD7;c4C56;nEr39;f7n3;a0e5s155u14z3;o3468;aA4e24;e0s0;d1p3C;h385;aEc3B14dB4Dg3340m34FDq19E3r3183s0u30;d6F5rBs9Ct9D6;s44vB;a30i5C;!g62l63n1s0;n1A78p1A1t1A1;!cB2d481f3907g2473h1j364k4BE7lF39n376p28r43EDt320;c9Cs2C;u19B;a30ACi1912t7u34;!a3F17e90FfB26g4CDFh3A6EmB42n22oA55s0w34F;!r15AAs0;!a160s0;h21B0;!a44Ab9Be15i624m16Cn4F5o71s0;i18m0;e33oDr7;q129A;cB7i2D49;d740nFsE;n0s155z3;l1D8tBDvFD;!b4C;c84n2o1t1B6;!aDE5b4AB6e3750f43CAi661m22Co3C99p325Fs0tB0;a48BAr3;l88BnAB7;tA9B;!a39E1e27A1h1AF7i965k9Fl9Fm2Eo3056p49DEtEE5w27BC;!n25s0;!b48ABc1D0d76De4f14Fi3DCk28l497m2Es3647y0;a1EDDb100FcD34d2397e1BBCf1826g1236h1F2Ci3886jFA9k2B9Bl3119m22ECn3DC2oD29p15FDr3670sFFFt138Eu1068v3A2Aw48DBx1140y1;a1i2E5;i34l1o666p8C8s56t340Bv5D;!d8A;a54oD76;bCA0m50D8s1F;!a30F5e4h1C33i21kAD2o0s0t3A56u17EE;eEAl7n1D77;!d0n16rB12s0;!u28D;r143As11;c5Ce1Bl7n146;e27E2i6;cD3x55;u36C;!e5i50s0;r18tB;!a3FD2d42D8eB24i50A7l7ABo408r3B97s0u2E4A;l3An0;a3FBi76Fo74;!aB45e2BEFiBCl44s0u3E7Ey0;a5126;!iEo0;c4FD4n1;b1Cd41g3;a3483;!a8D9b2C3Ae15f37g6BBi21l76m62r237s4AB4t4A8;l77D;!a9DFe1E5h1DA2i2C8El42A5n22s3859t1722u42Dw364;!d0i6m4221r1235s0t1;a40n3;a9eF8Ci166;!e0r1FA8;!b1C4Bs0;a174e1i0u5;!i3ACs0;m1p4ED7;!e15i43o12s0y0;n40CAo4A2Es2F4t4A;t37F;c2Bn118x0;e1FC2o17uB9;e23i6o12;e4l7y0;aA48e2732i6t102;oEy0;gBn2EC;!e4i2EBs0;b20D;!e5l1o36s0;a3F89d0i2B1l3CCrA18s702t1556yCD9;uCE;d1nF;!d0e10n486Bs0;!e15i1B3r4Cs0;e292D;!a1350e23C0iCA4o1482s0;t3158;!n6CsE;e1E5i3D6Bk5C;!b3BAf824nD3s0w5D1;e4i21l1BF;l3Ar74;c9Ce1Al47;e7i2B;!o2068s0;h35C6;i4r1;i10B5;!m3B0s0;e4k1E;eA70;h369;y3AF;g298n13B4t428;o309F;!a3A6e104f8D5i6m2En12Do12DrAAs30FE;g97k3t0;e1i3;i23B6y0;gBnFr34;a2F7Di3802;l27oA6;a1Db3D9lB85o3343;!e0iF85m162o159s0w9Ay0;a1Db3269c4D97eAg3B66i40A7m4332p1s24E0y0;!g1480h3535i12s0u9B;!r7s1682;!n11D;a1e2C94h541;n5FF;iCB;i25n8D;!e4i21s0w130;!e4i13s0y0;e448h106i1Dr515;o5u1zCB;g1s5;!h3700i519o16CBp815r47BDs0;!d0r1s157y0;eF1Cl44s45F1v390D;t6B7;o527;!l4FFBs0;d2B;o1D1Fr39Fu3B;e15i21o71;e17o6;!dB0De1f17As0;!d0l20C1n17DFr0s3Et38;a4151eAi368E;g3E3m1;!gB78s0;!a4DBi61k27s0;g19i12n4r282t3y16;!a3CB6e2272i21o3A82s0u2F37y1A1;u419B;!e15i66Es0y0;fC10;l4A1;!a4605e1Bi13F8l7s0u710;nB5t7;n7A3;e2EF4;fF5n39A1;d1r36;!i4D4s0;a1i77Eu77E;!e1BB4i6s0;l90Dn0;e23i6u37B;f37;!e4fCEi6s0t271;!t997;!m87s0;t380;a42e9D5i2Bl265y0;!d0e1l1D3s0;!a1d6As0;o3246;!cB2s0u1;e33s0;pB1;a7Di73l1t28y0;!k248o29s0;!a409Be5o29s0;l4BDo418;e30t16;a1694eA44o1405rB6Au4861;i61u5;!b1Ci4l1w0y1;l41rD8;eAi1FA;c1AD6e1l1q123r279Ds17E;s2A9;!a16A6c1C94e270Dh34D3i2F07k23EAl122Ao3398r445Es0t3289u112Dy90E;o8r3;a20eAi20CB;!n29F;n29F;t675;!k28n16F6r1A17t8BF;a0c99Dd286e5f4FACi31m18n372;a70e1;a501e3840o10;t18F9;rFC;!d38n10DCs0;eEi26Bl6C;t4035;t2Fv3;sB2y0;a1i1y0;i29Ao72;!h5Al1DBp24CAsAEt4D2u3925;d3C9;a44DAb293Dc4DA2d2819e1467f2787g42FCh1i420Bl1B57m1854n32A3p48B3rEFEs1F68tE09zF08;a4De4738i317;dD67e261l1635m4FEDo10;d2072l83n3BB1s0tFCF;t2737;r151E;!s0w80;a55Be179Al2D6Aw0;c196kCA;lE3u3B;aA03;e1i0o0;d0r4C37;k3l2As2Ax0;a633c121e1l3A9nFt27F0;m53n7E8;eC56i6;c1l1;cEl1Dr3851t3w19;!a10o267s0;a3D5d17ABg127l2Cn16AAs26Et1;!e12i3669o562p7Ar3C78s0t107C;!a10b21Ae9g40AChEDn12Ds29F4tB83w4AF7;!a4Dc68Ed4A70i21k1CFl113m167Dn0p4E2Dr478s7A9t3379;!e5Ai0sBu4E;a2Dc11;dC48;a2B7Ed4EE8e3118g4BCDi3A61l1A54m1243n2039p4989r2D17t43E7vA3w25E1y0;e1ECr1B0;e243A;r0u12;a1DoE7;!b31F6m7As0;rA50;u57y1CB6;a1o10;a165d0l1o29r16t426E;a829d58e4Ag31D0j5As0t36C4zCB;f16n3BD;c355;!c355;c11m16;t1DB;n11Es11;d1g1E;a174rB0;n4p1;e4i6uD4;iA67;!e255Fi2391;e3FB;c2EB4n538p44Fr4C04s34D7u9FC;a40i20o207A;aD2Ee125Ci1B9BlE25o41A8r3FDDt20DAuEy3C27;!m2Et0;!a7Fe3BCAi6o32s0w1BC;u6F;e261C;i25r8Dt77;a2601r1t1;!c7l7s0;!d3Al22r1s0;!e4i21m2Es0t226w9Ay9A;!t138;e405i354Dl581;!h1l4FDn1A1Ar1672s1FBA;l41E2;aCE6;e1CC9;a7BB;!r7s0t41;d5Bi4D1Fu5y0;e4i6s0y0;!e22AfB5i3DCk5Ds0y0;e17C;m4F11;n1D02;d0r56t88;gBl4D8;l310n1;c197s27Dz176;l4873s1A6C;e675;a4Bc0e24t758;b5Cc4ADg14EDi207l367En1C43p45CEs32A4t1C4Ax0;d1D;m3A4;a12e3C47h50B1i6k4BBBo1A2Ay1A7;!a2D99b961c219e2181i2E2FlC0Bm2FA5o674s0t47B1;!i73y64;e4l4F;e3C86h29FAi13;a12b326CmA4Cp43D6;e4BFBi2899l2Co2FC0y64;p5s0;s84vA3;r31;b4C3Ac35E6d24Df30F1g41m1Ap2D30s9FBv27x0;a13u5;a1bFDc489Ce4779h19A1i1318k458q123s4D7Dt42E3u240E;a10lD2;!e0l3As0t19;a7Fe49s24F4vA6B;!aD5Bc4EDBd22DEeAf367Dg8C4i1546k33ECl67Fm2En465Ao1903s3062t5109u3C58w588;b44AFc14A6d2F24f3620g3FD7h28i421Cj1B45kCADl2A7Cm4C4Bn38BAo2E6Cp18B3r3A99s15B7t234Au1F06v384Ew4A6DxAEyDF0z27AF;w3D9;!d7Ar16E2s0;aA2e1u14;e4C5i34D0s35;h3F6Cl2388;!eC0i6l7n22s251;b7Be1C3fCAnBt1;!e1n2s0;!e5n2s0;t971;a124e1Dp1;c48n16;i2555y0;cEFd1061g4Ai5n6F9p398Dr4044s24A3t1AA3v2437;l30Br268;h7B;aD60l16F3;!a2551i13o29s0;e23gBi6o40r3C;i373n147r3C3x1E;!a4EF6e23f37i6l22s0;!k2398s0;n3sFEt7z3;e12o81;g1Al8E0n11D1r2D6;c1s155z3;a2A3oDA;s1At7;p63;e4454i6k18u0;g4196i0lA8s0;a71e1914i3A68l236Bo425Br46F1y361;gAF;i156B;l310Cn3C36;s3ABA;d0e9r195t16;a31E1;r370;l466A;a275;c1Ce5;l3AtB6;e1Bl7n2s36;c1Ee50m1Es35z1E;r0s0x78;a1167i27y0;!z259D;e543o10;o218u2CB;r17CE;!b7Bf120n1p794s0;d3BDt864;k3mB6;!o3AF8p582s1A0;!a110b2FA0c471EdFDe41C3f5B0g32Bi383Al4187p2FAFr2AFs4582t329u689v2F80;!e4i6o3Cs0;!e274B;iDn443uC;b1CD7e30DD;f16s8t16;!e4i998l66Ds0;m45C4;!a6DFi3F;a1D24i4516m2711;!e0n0s0t2D;eDs3z3;a100eC6lA5oC6rAAyC6;l685;d0l1n39r432;!a4DF0e3D3Ei4713l24B5o12B0r30E3s0t19Au332D;!eAECi1C10o5005r22;a18Ae1n60pA5s199z0;!a0e4i29EBs0t3884;!b230Ee254Ai21l1BFnF6s0;!d0m2Er1s0y16;g4D6Fn3r7;!eD1o10s0u34;g48i132t1;n0o10;eAi95D;!a451CcB2d410Ce1C64f183i4136n45AFo46C2p2302r75Cs24BDt206Bu21E6z56;e1n1;c18CEg153Fn1p19CEr3A97s34D8t47z1A9;a125e4DB3i48Fu6AA;i1550;u2E3F;!a1e1r7s0;i1773;a2872d299Ae124Fi3C06l1F54u273F;a0c5Cf3396;a180o5;aC3eDi457Fo1E0;m2C;a1CE9e0o31FBu14;a10o3AF7;e4i5;e1i4;!a90c4AeCFi21s308y4085;e4850;eC6n44BCoB28;a59e17i3831y4BF;a0e4u14;d0n39r3As8;lF9Bp58;n1r0s8t2F;dA3;a4E5Bl68Fn33ABu6B0;!c2A0l7F9n4B2CrE95t4FEAvB0;n4364;e3D93;y34;c32i25;a4569e482Fi16FDo203Dt9BA;e109o1E0;c32l1;yCB;!a1d509Fe18C8i5C0n1979pDBs11Bt131;!d3Ai20r58s0;aAD9l25Co1BEr2B37;b1CgBx1F;m1D3n3B5r1283;aAD4d0;!e64B;cBeAs68D;y10F;a8FeC0EiA4o42;l58t5A;e4i3024o591y0;a50iE6m265;e10En2DFE;!a39CBbBFFe4CEAf68Fi39BEl76o122Ep42CDs4A96u4826;iCl4o2Ar3;!e12i3CDs0y0;a1B48e2AA4h34C0i3EBBo27BEr1655u24B0w627y7C;e569;i5EA;s5w0;!a283Ae541i4C4Fl806oE7s0y0;!b31De24g2D10h4EC7i4FFs41Et4C25y0;i20oFC;i25l2B08n1p257A;!e3F6Fi3A4Bs0;e24nF;oC4r87;!s68;c19e5n11E;!s73;!r109Bs0;e70B;eEi6o6y0;a3Cb2A89f30CBg3D5Ch109l12A5m302Cn44DDp4DF3r1667s4C45tD39v44z457;e27D6i21;d0n138r1;a20E4n65t1;lE3s1E;o90;a3e1o46;t9B4;!a4DDDb21Ac2B42e2D55i3386l119Ap3B05s0t50C8w3F1A;!d0eDs0;n8s1C1;a448eAi3AA;a1l19;!a18B5d17Df53Ci3C25l1720s0u2643;!e23i6t1;a3e1i4600o260;i4r0s4097u5;eDi6Dy0;lA1;a692i21;a54e25o95;!a3020b4266c25Cd4A74e187Ff0g5AiE5CkDEAm1D10n4007o39F4p2231r134As493Et3AF6u18DDv3472y2D61;a9c0s3z3;e18iE;rCD;e30lBu1C;a4DeAiAD3o12tCAB;g3Cn2;d3Ar2F;!aB8Ee18D8i4416l174Ao34s0t1;u2B5;n524;e204Ci61Bo4B88;!b46A8c243Cd9A6f1EFEg19ADl4FF7m47C5n28p1A57q174Cr2193s4BE8t1C6Bw2E2C;e1723i4FFy0;s245t2D;!b467Dc1BEd200Ff4C06g268Ak4C9l1956m31E4n4560p1B8Es381At1DCv1886z4B45;l18o4;cBt17F5;a3D22e3219i3857o2A5ArDu1E91y2AE6;!o11E5;a1i4ED6k46E1o1;!i3Bl2Cs0y0;l175F;aE8l1EoE7y0;l16t1E;s7t2D;i6o92;i4B51y128A;!e0l0r2F;u1053;!d0r1s0u991y0;l84;!h0o10s0t1D9;!eA83i435m19Fp8Bs0;a408Ee43EAi3016o421EuFC9;aCc0;a75c0;p16v191;e15i21y0;s16B;o3A12u168;n29E;!i38B6o44D2s0;!l7t0u12;l70A;!aBEh0i6s0;lBo46;i373m2Cn3B7sC1;d38e1lBt320;!e41EAi6y0;a37CBs148;c31BF;a108b922cA2Be1E5g0i42FAk1E03l18En2B88r23A7s705t2DFD;c0d3f7u14;i2C05;!aC8Ce5D4i3FEDt5E4u49;b1D4o33E;!a52BeC0i2FCl7s33Du34w80;!p4750s0;i4E7;f37o29;e30g1Cu20;k4Cn2s11t49E;a3F7n2u34;eAEDi664;a319;n2716r1Ay1;g14B;d8Ae12Fh248t0;a1C5eB9h18AF;z56;!cD1m30CCs0t196;e0o31;!b101c2587d39EeCFi309CkF6o159p220s140Ft1E7;b7Be1lBn2o78Dt1F6Av3;m83r3A43u12;a1b9Ae16D7;n4DE;a1112bDE9o4A2;i35Bo56t38;!a1784e5s0;d12C;!d0r1DDs0;a1EC;!a4F21c3AFDd20BCe676g2338i23E7j387k0n4F4Es2B0Dt1CD0;d341F;s5Bz17C;e1Do186;a1B7Ce336i38;t28A;h523;e7FC;!a12d2735s0;!a410oF;r564;e49Ai6;a4E7Ae6Ei2Bo497Fy0;bF8m89p323;!a786d0l496n2DB9r0s3E;e110;e2C2Fh280k66Bm29o3E27t4954u46B6;eAm1t1;s339F;l1An1;e330i1CBFy0;m8BnB59o1F5Fr39C7u59v5B;a1702;n8D;!b38E5s0;e1E9Ci6;!a1e9l7Cp28FtF8w80;o1A03u90;i4B8Do1CDE;!a3FBi2DB6s0;!t3FC;a1De49Ai6t1;e0i11Co29;o1B4;a7Fe23i9F5;y3650;e34x1F;!aDi13s0;!e46Fi43y0;i18m1t1y0;!o29s0t20;n25r1tB;b3818e14E1i6l44C2t259F;!eDi3l7;d3CEg2Ck47l36Ep1BE9r1s406;o220C;s478B;f3E7;!b1CBh121tF8;!l724m1EC1n2s0xB;!a388b4BBeAi2B30lBo4045s0u3FBC;e12i190lBoBy0;eBlB;p47s3FE;e1825n0o9E;m2Do10;e24E9;a1453f216Ft0;d9En8;i3BE;!a3172b2C61e4EE9i30A3m5067p1096s0;t41FC;!e1BnFs0t1;l57;!s1t1;cCDl4r14;l342B;b1C4;i2Bl19y0;a100eC6i30Ey30E;!d34FCe12FmFADn28p1DCr400Fs0;!a9e31E8i3A5Co1s0z2CA;!g320Bh1i2DC8s0;nD9tF3E;a1e4ADCi4E9Ao46;b1f108;e4553h583;s68z1B52;a59i2C6y0;i2B8Fo2BC;c19rE;f1D63s0;!aD18e12i420o71s0y0;hEn3CC;s5A;d2ABk2E69lFDr2A27;c8r14;r4754;cCBi2B2Dt681y0;!e5i6;aDeAoE7;o264;a725;a4658e8FiBy1833;e1BnA2DsE;i399Ay0;i7CBo480;a1AFeAi6;a10i62Bo46;eCF1;!d4D1e0i375El3F6An3CD9r198Es0;e1m63s11;i29Do230;s1Ft1D;a8DE;h477iF;!e1B8t20AF;n191;c2Ae1Bl7n2;!e26l7s0y0;!l1n25s0;!g19s5DBt16;e696s5;!i3693s0u4E;a59o1B5;!a2A65cA45hC94i56t1FC6u88;!a45CFe31o2503r652s0;g1iBB;e6E5i6;t42;a14e0t1y0;p27A;a13CAb2E9Ac46A7d2125e48D0f3B23g4B30l4F84m282An3673o4B42p1862r3E64s1612t23D6v3911x5078z185F;b1Cc32i4r60tB6y1E;!f69Ah23Bm2E;l2BD;bCEjB7;l3A0;!a4Dc17Ae10Bi21l7n22s0w169;!e224i11Cl7u49;c16F;bCDc76Al71Em2FCFp113;h4134;n8z3;vB8;a4AECeAi421Ao3F03y64;!d8Ah1C4s0;e3D5;!aCr7s0;!l38E1q7CCs0;!n18r53s0;!d8Am2Er0s0;!z2B;z11B;c59Ei32l357Er4527s219tA1E;zB;n89oE;d87n39As1Ft18;k3nF;e1BnFtB;l124;a414DeB7i1696o3BBu4E;l4EE3;a59o71;e1B12;e1Bk3l7nF;l63r63;!b1Cc58i9l10BDs0w1y1A;n25r65;!b1ABc1E6e4F7fE2i86l7B7oD5s0tEB;i2Bo1E9y0;g0i1;!e24i6o284;!a80Ce3F1fB5i389Eo258s0;a14F7e275i274;l1C9En1;b3D8e185l0nB5Ar91Bt2D1;!c4647l3A21o45w6A;yDBzDB;k17Cl32;lD1;l5t7;a60d0l1Dr4593;g16;aAF0;iE6;!r0s8x29;c32e65;a1599b3E23c321Bd3C04e2C52fCA3gDEDh47C0iFDCj1E2k1ADFl2D58m2C84n2F18o18FBp2161q3441rDFAs3D54t2A12u4108v4787w11C9x61Cy1472z2D91;eAi6l4FCu3E8;a4E6EiD4;d4B7;!a561e4518h184i3627k3FDl27C4;a1CCe36FAi5DCo1;cCE;c1o9;a31e2B78i296o46y0;!a508e24i6y0;n2s11t60;a1708bDD9c103Ed3D16e1D45f4389g4439h1878i140Cj1693k2868l40C6m3AD1n2717o2840p3B29q4DEDr4541s393Dt43FAu17BDv1935w3F97x3A7By225Bz188E;"

---@type integer
DawgStart = 20819
DawgLoaded = false

---comverts a table or builtin to a string
---@param val nil | boolean | string | integer | table<`K`, `V`> | function
---@return string
function ToStr(val)
    if type(val) == "table" then
        -- start off assuming that the value is an array. 
        -- if that assumption is violated, it's a general table 
        ---@type `K`[]
        local keys = {}

        ---@type `V`[]
        local values = {}
        
        ---@type integer
        local nPairs = 0
        local maxKey = 0
        local minKey = 1
        local isArray = true

        for k, v in pairs(val) do 
            table.insert(keys, ToStr(k))
            table.insert(values, ToStr(v))
            nPairs = nPairs + 1
            if isArray and type(k) == 'number' and math.type(k) == 'integer' then 
                maxKey = math.max(maxKey, k)
                minKey = math.min(minKey, k)
            else 
                isArray = false 
            end
        end

        if isArray and maxKey - minKey + 1 ~= nPairs then
            isArray = false
        end

        ---@type string[]
        local str = {}

        if isArray then
            str = {'['}
            table.insert(str, table.concat(values, ', '))
            table.insert(str, ']')
        else 
            str = {'{'}
            local fields = {}
            for i = 1, nPairs do 
                table.insert(fields, table.concat {keys[i], '=', values[i]})
            end
            table.insert(str, table.concat(fields, ','))
            table.insert(str, '}')
        end

        return table.concat(str)
    else
        return tostring(val)
    end
end

---randomly re-order this array in place
---@param array any[]
function Shuffle(array)
    -- reverse fisher-yates shuffle
    for i = 1, #array - 1, 1 do
        -- random value to select
        local j = math.random(i, #array)
        array[i], array[j] = array[j], array[i]
    end
end

---@type integer
SOUND_STATE_ADDR = 0x13FFC
SOUND_STATE_TRACK_ADDR = SOUND_STATE_ADDR
SOUND_STATE_FRAME_ADDR = SOUND_STATE_ADDR + 1
SOUND_STATE_ROW_ADDR = SOUND_STATE_ADDR + 2

---@class SongFrag
---@field trackNo integer
---@field bankNo nil|integer
---@field frameStart integer
---@field frameEnd integer
---@field rowStart integer
---@field rowEnd integer
---@field tempo nil|integer
---@field speed nil|integer
SongFrag = {}

function SongFrag.new(
    bank, track,
    frameStart, rowStart, frameEnd, rowEnd,
    tempo, speed
)
    local frag = {
        bankNo = bank,
        trackNo = track,
        frameStart = frameStart,
        frameEnd = frameEnd,
        rowStart = rowStart,
        rowEnd = rowEnd,
        tempo = tempo,
        speed = speed,
    }

    return setmetatable(frag, {__index = SongFrag})
end

---@class Song
---@field frags SongFrag[]
Song = {}

---@param frags SongFrag[]
---@return Song
function Song.new(frags)
    local song = {
        frags = frags,
    }

    return setmetatable(song, {__index = Song})
end

---@type Song[]
Songs = {}

Songs[1] = Song.new {
    SongFrag.new(1, 0, 0, 0, 7, 63),
    SongFrag.new(1, 0, 0, 0, 3, 63),
    -- SongFrag.new(1, 0, 3, 0, 3, 35)
}

Songs[2] = Song.new {
    SongFrag.new(1, 1, 0, 0, 15, 31),
    SongFrag.new(1, 1, 0, 0, 6, 31),
}

Songs[3] = Song.new {
    SongFrag.new(2, 0, 0, 0, 1, 63),
    SongFrag.new(2, 0, 2, 0, 3, 63),
    SongFrag.new(2, 0, 2, 0, 3, 63),
    SongFrag.new(2, 0, 4, 0, 4, 63),
    SongFrag.new(2, 0, 5, 0, 13, 63),
    SongFrag.new(2, 0, 14, 0, 15, 63),
    SongFrag.new(2, 0, 14, 0, 15, 63),
    SongFrag.new(2, 0, 2, 0, 3, 63),
    SongFrag.new(2, 0, 4, 0, 4, 63),
}

Songs[4] = Song.new {
    SongFrag.new(2, 1, 0, 0, 3, 63),
    SongFrag.new(2, 1, 3, 0, 5, 63),
    SongFrag.new(2, 1, 5, 0, 15, 63),
}

Songs[5] = Song.new {
    SongFrag.new(3, 0, 0, 0, 2, 63),
    SongFrag.new(3, 0, 2, 0, 3, 63),
    SongFrag.new(3, 0, 3, 0, 4, 63),
    SongFrag.new(3, 0, 4, 63, 5, 63),
    SongFrag.new(3, 0, 5, 0, 7, 63),
    SongFrag.new(3, 0, 6, 0, 6, 63),
    SongFrag.new(3, 0, 8, 0, 12, 63),
    SongFrag.new(3, 0, 12, 0, 14, 63),
    SongFrag.new(3, 0, 2, 0, 5, 63),
    SongFrag.new(3, 0, 5, 0, 7, 63),
    SongFrag.new(3, 0, 6, 0, 6, 63),
    SongFrag.new(3, 0, 8, 0, 12, 63),
    SongFrag.new(3, 0, 12, 0, 13, 63),
    SongFrag.new(3, 0, 13, 0, 15, 31),
}

---@alias SongLoc {
--- track: integer,
--- frame: integer,
--- row: integer,
---}

---@class SongState
---@field curSong Song
---@field curFrag integer
---@field lastLoc nil|SongLoc
SongState = {}

---@param song Song
function SongState.new(song)
    local state = {
        curSong = song,
        curFrag = 0,
        lastLoc = nil,
    }

    setmetatable(state, {__index = SongState})

    return state
end

---@return boolean
function SongState:finished()
    return self.curFrag > #self.curSong.frags
end

---@return boolean
function SongState:playing()
    return not self:finished() and not self.curFrag == 0
end

function SongState:play()
    self:nextFragment()
end

function SongState:rewind()
    self.curFrag = 0
end

function SongState:tick()
    -- peek memory and update the current frag
    ---@type SongLoc
    local loc = {
        track = peek(SOUND_STATE_TRACK_ADDR),
        frame = peek(SOUND_STATE_FRAME_ADDR),
        row = peek(SOUND_STATE_ROW_ADDR),
    }

    self.lastLoc = loc

    -- this happens when no song is playing
    if loc.track == 255 then
        self:nextFragment()
        return
    end

    if self.curFrag > #self.curSong.frags then
        music(-1)
        return
    end

    local frag = self.curSong.frags[self.curFrag]

    assert(loc.track == frag.trackNo,
        "frames from different tracks unsupported. loc.track: " ..
        ToStr(loc.track) .. ", frag.trackNo: " .. ToStr(frag.trackNo))

    if loc.frame > frag.frameEnd or
       loc.frame == frag.frameEnd and loc.row > frag.rowEnd
    then
        self:nextFragment()
    end
end

---@type integer
BANK_SFX = 8

---@type integer
BANK_MUSIC = 16

---start playing the next fragment.
---calls "music" to modify the currently playing bgm
---calls "sync" to switch banks
---(so make sure something else doesn't sync that frame)
function SongState:nextFragment()
    self.curFrag = self.curFrag + 1

    if self:finished() then return end

    local frag = self.curSong.frags[self.curFrag]
    sync(BANK_MUSIC, frag.bankNo, false)
    music(frag.trackNo, frag.frameStart, frag.rowStart,
        false, false, frag.tempo or -1, frag.speed or -1)
    --for testing
    -- music(frag.trackNo, frag.frameStart, frag.rowStart, false, false, -1, 3)
end

BTN_SIMPLE_W = TILE_W_px
BTN_SIMPLE_H = TILE_H_px
BTN_UP_COLOR = PALETTE.BLACK
BTN_HOVER_COLOR = PALETTE.BLUE
BTN_DOWN_COLOR = PALETTE.LT_GRAY
BTN_SPR_MUSIC_ON = 354
BTN_SPR_MUSIC_OFF = 370
BTN_SPR_SFX_ON = 355
BTN_SPR_SFX_OFF = 371
BTN_SPR_NEXT_BGM = 356
BTN_SPR_NO_IDEA = 372
BTN_SPR_LEAVE = 357

--- the amount to extend the highlight left and right
BTN_HORIZ_PADDING_PX = 1
--- the amount to extend the highlight up and down
BTN_VERT_PADDING_PX = 2

---@alias ButtonStatus 'up'|'hover'|'down'
---@alias ButtonAction nil|'downed'|'hovered'|'clicked'
---@class Button
---@field node Node
---@field draw fun(self: Button)
---@field name string
---@field down boolean
---@field hover boolean
---@field hint string
Button = {}

---@param node Node
---@param name string
---@param hint string
---@return Button
function Button.new(node, name, hint)
    local button = {
        node = node,
        name = name,
        down = false,
        hover = false,
        hint = hint,
    }
    return setmetatable(button, {__index=Button})
end

---@param buttons Button[]
---@param mousex number
---@param mousey number
---@return Button|nil
function Button.whichOver(buttons, mousex, mousey)
    for _, button in ipairs(buttons) do
        if button.node:isPointInside(mousex, mousey) then
            return button
        end
    end

    return nil
end

---loop over buttons and return which one was clicked if any
---@param buttons Button[]
---@param mousex number
---@param mousey number
---@param mousedown boolean
---@returns Button|nil
function Button.updateButtonsAndDetectClick(buttons, mousex, mousey, mousedown)
    --- @type Button|nil
    local which = nil
    for _, button in ipairs(buttons) do
        local result = button:update(mousex, mousey, mousedown)
        if result == 'clicked' then
            which = button
        end
    end

    return which
end

---Removes the hover state from the list of buttons
---@param buttons Button[]
function Button.clearHovers(buttons)
    for _, button in ipairs(buttons) do
        button.hover = false
    end
end

---@return ButtonStatus
function Button:status()
    if self.down then return 'down' end
    if self.hover then return 'hover' end
    return 'up'
end

---@param mousex number
---@param mousey number
---@param mouseDown boolean
---@return ButtonAction
function Button:update(mousex, mousey, mouseDown)
    local mouseInside = self.node:isPointInside(mousex, mousey)

    if not mouseInside then
        self.hover = false
        return nil
    end

    self.hover = true

    -- if button is up, the mouse is inside, and then the mouse goes down
    if not self.down and mouseDown then
        self.down = true
        return 'downed'
    end
    -- if button is up, the mouse is inside, and not down, and the button was
    -- already clicked previously
    if self.down and not mouseDown then
        self.down = false
        return 'clicked'
    end

    if not self.down and not mouseDown then
        return 'hovered'
    end

    return nil
end

---returns x, y, w, h
---returns number, number, number, number
function Button:posAndDims()
    local n = self.node
    local x, y = n:pos()
    local w, h = n.wpx, n.hpx
    assert(w and h, "button node missing dimensions")
    return x, y, w, h
end

function Button:drawBack()
    local status = self:status()
    local x, y, w, h = self:posAndDims()
    x = x - BTN_HORIZ_PADDING_PX
    w = w + 2 * BTN_HORIZ_PADDING_PX
    y = y - BTN_VERT_PADDING_PX
    h = h + 2 * BTN_VERT_PADDING_PX

    if status == 'up' then
        -- rect(x, y, w, h, BTN_UP_COLOR)
    elseif status == 'hover' then
        rect(x, y, w, h, BTN_HOVER_COLOR)
    elseif status == 'down' then
        rect(x, y, w, h, BTN_DOWN_COLOR)
    end
end

---@class SpriteToggleButton : Button
---@field toggleState integer
---@field toggleSprites integer[]
---@field chroma integer
SpriteToggleButton = {}
setmetatable(SpriteToggleButton, {__index = Button})

---@param node Node
---@param name string
---@param hint string
---@param toggleSprites integer[]
---@param chroma integer
---@return SpriteToggleButton
function SpriteToggleButton.new(node, name, hint, toggleSprites, chroma)
    local button = Button.new(node, name, hint)
    setmetatable(button, {__index = SpriteToggleButton})
    local button = button --[[@as SpriteToggleButton]]
    button.toggleState = 1
    button.toggleSprites = toggleSprites
    button.chroma = chroma

    return button
end

function SpriteToggleButton:draw()
    self:drawBack()
    local spriteId = self.toggleSprites[self.toggleState]
    local x, y, _, _ = self:posAndDims()
    spr(spriteId, x, y, self.chroma)
end


---@class TextButton : Button
---@field text string
---@field textColor integer
TextButton = {}
setmetatable(TextButton, {__index = Button})

TEXT_BUTTON_H_PX = 6

---@param node Node
---@param name string
---@param hint string
---@param text string
---@param textColor integer
function TextButton.new(node, name, text, hint, textColor)
    local button = Button.new(node, name, hint) --[[@as TextButton]]
    button.text = text
    button.textColor = textColor

    return setmetatable(button, {__index = TextButton})
end

function TextButton:draw()
    self:drawBack()
    local x, y = self.node:pos()
    print(self.text, x, y, self.textColor)
end


---@return TileElem
function DrawElement()
    local r = math.random()
    if r < CHANCE_TO_DRAW_CHARGED then return 'charged' end
    return 'normal'
end


-- TODO: refactor name to SpawnLetter. Normally draw means render in my
-- codebase, but here it means to draw it (from a random distribution)
---Generate a letter according to the table of frequencies. Shuffles the
---array of frequencies to mitigate the error
---@param pVowels number proportion of vowels
---@return string, TileElem
function DrawLetter(pVowels)
    local vowelChance = (pVowels ~= 0) and (IDEAL_VOWEL_PROP / pVowels) or 1
    local isVowel = math.random() <= vowelChance
    local whereFrom = isVowel and VowelDraw or ConsonantDraw

    Shuffle(whereFrom)

    local sum = 0
    local r = math.random()
    local letter
    for _, l_f in ipairs(whereFrom) do
        local freq
        letter, freq = l_f[1], l_f[2]
        sum = sum + freq
        if r <= sum then break end
    end

    local letter = letter or LetterDraw[#LetterDraw][1]
    local elem = DrawElement()

    --- exclamation points are never charged
    if letter == '!' and elem == 'charged' then
        elem = 'normal'
    end

    return letter, elem
end

---center a rectangle inside another. returns the top-left x,y coords of the
---inner rectangle (distinction between inner and outer doesn't really matter)
---@param outerW number
---@param outerH number
---@param outerX number
---@param outerY number
---@param innerW number
---@param innerH number
---@returns [number, number]
function CenterRect(outerW, outerH, outerX, outerY, innerW, innerH)
    local dWidth = outerW - innerW
    local dHeight = outerH - innerH
    return (outerX + dWidth) / 2, (outerY + dHeight) / 2
end

---Text to render whose height was determined by a pre-render pass
---@class Text
---@field text string
---@field width integer
Text = {}
Text.__index = Text

---Create a new known-width text object. Performs one offscreen render to learn
---the width of the text. Doesn't actually render visibly, only stores width.
---@param str string # the actual text to store
---@param fixedMode 'fixed' | 'variable' | nil
---@return Text
function Text.new(str, fixedMode)
    local fixed = fixedMode == 'fixed'
    local w = print(str, 0, -8, 0, fixed)

    return setmetatable({
        text = str,
        width = w,
        fixed = fixed
    }, Text)
end

---@alias Xy {x: number, y: number}
---@alias Cr {col: integer, row: integer}

---create a new column/row reference
---@param col integer
---@param row integer
---@return Cr
function Cr(col, row)
    return {col = col, row = row}
end

---@class MouseState
---@field x number
---@field y number
---@field dx number
---@field dy number
---@field left boolean
---@field middle boolean
---@field right boolean
---@field leftTrans 'down' | 'up' | nil # change in left button since last poll
---@field midTrans 'down' | 'up' | nil # change in middle button since last poll
---@field rightTrans 'down' | 'up' | nil # change in right button since poll
---@field whereLeftDown Xy | nil # where was the mouse clicked? stays for 'up'.
MouseState = {}
MouseState.__index = MouseState

function MouseState.new()
    local state = {
        x = 0,
        y = 0,
        dx = 0,
        dy = 0,
        left = false,
        middle = false,
        right = false,
        whereLeftDown = nil,
    }

    return setmetatable(state, MouseState)
end

function MouseState:poll()
    local x, y, l, m, r = mouse()

    self.dx = x - self.x
    self.dy = y - self.y

    if l and not self.left then
        self.leftTrans = 'down'
        self.whereLeftDown = {x = x, y = y}
    elseif not l and self.left then
        self.leftTrans = 'up'
    else
        self.leftTrans = nil
        self.whereLeftDown = nil
    end

    if r and not self.right then
        self.rightTrans = 'down'
    elseif not r and self.right then
        self.rightTrans = 'up'
    else
        self.rightTrans = nil
    end

    self.x, self.y = x, y
    self.left, self.middle, self.right = l, m, r
end


---@class Dfa
---@field states DfaState[]
local Dfa = {}
Dfa.__index = Dfa

---@param states DfaState[]
---@return Dfa
function Dfa.new(states)
    return setmetatable(
        {
            states = states,
        },
        Dfa
    )
end

---@class DfaState
---@field tx table<string, integer>
---@field final boolean
Dfa.State = {}
Dfa.State.__index = Dfa.State


---@param final boolean?
---@param txs table<string, integer>
---@return DfaState
function Dfa.State.new(final, txs)
    return setmetatable(
        {
            tx = txs,
            final = final or false
        },
        Dfa.State
    )
end

--- Grammar that describes the serialized format for the DAWG
--- dawg ::= (state `;`)+
--- state ::= `!`? transition* 
--- transition ::= <letter> HEX_DIGIT+ 

---convert a hex digit to its integer value
---@param str string
---@param i integer
---@return integer | nil
function UpperHexDigitVal(str, i)
    local zero = string.byte('0')
    local nine = string.byte('9')
    local upa = string.byte('A')
    local upf = string.byte('F')
    local code = string.byte(str, i, i)

    if code >= zero and code <= nine then
        return code - zero
    elseif code >= upa and code <= upf then
        return code - upa + 10
    else
        return nil
    end
end

---read a transition and destination state pair from the serial stream
---@param str string
---@param i integer
---@return string, integer, integer # the new i value
function Dfa.parseTransition(str, i)
    local letter = str:sub(i, i)
    i = i + 1

    local dest = 0
    while true do
        local digit = UpperHexDigitVal(str, i)
        if digit == nil then 
            break
        end

        dest = dest * 16
        dest = dest + digit
        i = i + 1
    end

    return letter, dest, i
end

---read an optional final marker plus list of transitions
---@param str string
---@param i integer
---@return DfaState, integer # array of transitions and new i
function Dfa.parseState(str, i)
    local final = str:sub(i, i) == '!'

    if final then
        i = i + 1
    end

    ---@type table<string, integer>
    local tx = {}
    while str:sub(i, i) ~= ';' do
        local letter, dest
        letter, dest, i = Dfa.parseTransition(str, i)
        -- add 1 to conform to Lua's 1-based indexing
        tx[letter] = dest + 1
    end

    return Dfa.State.new(final, tx), i
end

---deserialize the DAWG and return the DFA
---@param str string
---@param maxLen integer
---@return Dfa
function Dfa.parseDawg(str, maxLen)
    local i = 1
    local states = {}
    local untilYield = LOAD_STATES_PER_YIELD

    -- first yield so that the first time the function is resumed
    -- it doesn't do anything (useful to start the coroutine)
    coroutine.yield()

    while i < maxLen do
        local state
        state, i = Dfa.parseState(str, i)
        assert(str:sub(i, i) == ';')
        i = i + 1

        table.insert(states, state)

        untilYield = untilYield - 1
        if untilYield <= 0 then
            coroutine.yield()
            untilYield = LOAD_STATES_PER_YIELD
        end
    end

    return Dfa.new(states)
end

---start a coroutine that parses some number of states whenever it is resumed.
---@param str string # the serialized DAWG
---@return thread
function Dfa.startParsingDawg(str)
    local t = coroutine.create(Dfa.parseDawg)
    coroutine.resume(t, Dawg, #Dawg)
    return t
end


---returns the result state from following the given string
---@param self Dfa
---@param str string
---@param i number
---@return DfaState | nil
function Dfa:matchPrefix(str, i)
    local current = DawgStart
    local len = #str

    while i <= len do
        local state = self.states[current]
        if not state then
            return nil
        end

        -- START TODO: stop this from crashing if DFA is unloaded
        current = state.tx[str:sub(i, i)]

        if not current then
            return nil
        end

        i = i + 1
    end

    return self.states[current]
end

InitStates = {}
-- Initial run of states that spell out 'test', so that the game can be
-- tested without loading the word bank (which is slow).
-- make a single node at DawgStart that recognizes every individual character.
InitStatesTx = {}
for i = 0,25 do
    local ascii = string.char(string.byte('a') + i)
    InitStatesTx[ascii] = Dfa.State.new(true, {})
end

InitStates[DawgStart] = Dfa.State.new(false, InitStatesTx)


---Global word dfa. Never unloaded once loaded.
---@type Dfa
local wordDfa = Dfa.new(InitStates); -- replaced by loading state

---For basic scene management
---@class Node
---@field id string
---@field parent Node | nil
---@field xoffpx number
---@field yoffpx number
---@field wpx number | nil
---@field hpx number | nil
---@field children table<string, Node>
Node = {}
Node.__index = Node


---comment
---@param parent Node | nil
---@param id string
---@param xoffpx number
---@param yoffpx number
---@param wpx number | nil
---@param hpx number | nil
---@return Node
function Node.new(parent, id, xoffpx, yoffpx, wpx, hpx)
    local node = {
        parent = parent,
        id = id,
        xoffpx = xoffpx,
        yoffpx = yoffpx,
        wpx = wpx,
        hpx = hpx,
        children = {}
    }

    return setmetatable(node, Node)
end

---create a child node with given coordinates and dimensions and 
---insert it
---@param id string
---@param xoffpx number
---@param yoffpx number
---@param wpx number|nil
---@param hpx number|nil
---@return Node
function Node:addChild(id, xoffpx, yoffpx, wpx, hpx)
    local child = Node.new(self, id, xoffpx, yoffpx, wpx, hpx)
    self.children[child] = true
    return child
end


---same as Node:addChild but interprets that child's offset as being from
---the top right corner. Requires that the parent have a width.
---@param id string
---@param xoffFromRightpx number
---@param yoffpx number
---@param wpx number|nil
---@param hpx number|nil
---@return Node
function Node:addChildFromTopRight(id, xoffFromRightpx, yoffpx, wpx, hpx)
    assert(self.wpx, "added child to a node with no width's left boundary")
    local xoff = self.xoffpx + self.wpx - xoffFromRightpx
    return self:addChild(id, xoff, yoffpx, wpx, hpx)
end

---returns the node's absolute position (recursively adding its offset to its
---parents absolute positions)
---@return number, number
function Node:pos()
    if not self.parent then
        return self.xoffpx, self.yoffpx
    end

    local px, py = self.parent:pos()
    return px + self.xoffpx, py + self.yoffpx
end

--- Align a value from the node's right.
--- Return's relative x value.
function Node:xRight(amount)
    local r = self.xoffpx + (self.hpx or 0)
    return r - amount
end

---compute the vector between the node's absolute position and the given point.
---returns the vector <node.x, node.y> - <x, y> 
---@param x number
---@param y number
---@return number, number
function Node:offsetOf(x, y)
    local px, py = self:pos()
    return x - px, y - py
end

---determine if the given x y screen coordinates are inside the node
---@param x number
---@param y number
function Node:isPointInside(x, y)
    local nx, ny = self:pos()

    return
        x >= nx and
        y >= ny and
        x < nx + self.wpx and
        y < ny + self.hpx
end


---Interface used by the application. Gets ticked every frame with information
---abount important app events. Can also draw itself.
---@class IAppState
---@field tick fun(self, MouseState): IAppState | nil -- returns new state
---@field draw fun(self): nil
---@field enter (fun(self): nil)|nil
---@field leave (fun(self): nil)|nil
---@field nSyncDelayTicks integer|nil
---@field delayTick (fun(self): nil)|nil
IAppState = {}

---@class StLoading : IAppState
---@field dawgThread thread
---@field loadingText { text: Text, xPx: number, yPx: number }
---@field loadingPercent { text: Text, xPx: number, yPx: number }
---@field nYields integer
---@field finishedLoading boolean
---@field licenseWidth number
StLoading = {}
StLoading.__index = StLoading
local UK_ADVANCED_CRYPTICS_LICENSE = {
    "This video game uses a modified version of the UK",
    "Advanced Cryptics Dictionary which has this license:",
    "",
    "UK Advanced Cryptics Dictionary Licensing Information:",
    "Copyright (C) J Ross Beresford 1993-1999. All Rights Reserved.",
    "The following restriction is placed on the use of this",
    "publication: if the Advanced UK Cryptics Dictionary is used",
    "in a software package or redistributed in any form, the",
    "copyright notice must be prominently displayed and the text",
    "of this document must be included verbatim.",
    "",
    "There are no other restrictions: I Would like to see the list",
    "distributed as widely as possible."
}
local SFX_LOADING_COMPLETE = 53

function StLoading.new()
    local licenseWidth = 0
    for i=1, #UK_ADVANCED_CRYPTICS_LICENSE do
        licenseWidth = math.max(licenseWidth,
            print(UK_ADVANCED_CRYPTICS_LICENSE[i], SCREEN_W_px, SCREEN_H_px,
        0, false, 1, true))
    end

    local loadingText = { text = Text.new("Unpacking words...") }
    local loadingPercent = { text = Text.new("99%", 'fixed') }

    loadingText.xPx, _ =
        CenterRect(
            SCREEN_W_px,
            SCREEN_H_px,
            0, 0,
            loadingText.text.width + loadingPercent.text.width + TILE_W_px,
            TILE_H_px
        )

    loadingText.yPx = SCREEN_H_px - TILE_H_px * 3

    loadingPercent.xPx = loadingText.xPx + loadingText.text.width + TILE_W_px
    loadingPercent.yPx = loadingText.yPx

    local state = setmetatable({
        dawgThread = Dfa.startParsingDawg(Dawg),
        ticksElapsed = 0,

        loadingText = loadingText,
        loadingPercent = loadingPercent,

        nYields = 0,
        finishedLoading = false,
        licenseWidth = licenseWidth
    }, StLoading)

    return state
end

---@param mouse MouseState
---@return StIntro|nil
function StLoading:tick(mouse)
    if self.finishedLoading then

        if mouse.leftTrans == 'down' then
            return StIntro.new()
        end

        return
    end

    local results = table.pack(coroutine.resume(self.dawgThread))

    if coroutine.status(self.dawgThread) == "dead" then
        -- an error occurred
        if results[1] == false then
            error('error occurred when loading words: ' .. results[2])
        end

        wordDfa = results[2] -- loaded the DFA
        DawgLoaded = true

        self.finishedLoading = true
        sfx(SFX_LOADING_COMPLETE, 'C-7', 60, SFX_CHANNEL, SfxVol)
        --return StIntro.new()
    else
        self.nYields = self.nYields + 1
    end

    return nil
end



function StLoading:draw()
    for i=1, #UK_ADVANCED_CRYPTICS_LICENSE do
        local x = (SCREEN_W_px - self.licenseWidth) / 2
        print(UK_ADVANCED_CRYPTICS_LICENSE[i], x, TILE_H_px * (i - 1),
            PALETTE.WHITE, false, 1, true)
    end
    

    local x, y = self.loadingText.xPx, self.loadingText.yPx
    local color = PALETTE.WHITE
    print(self.loadingText.text.text, x, y, color)

    -- actual percentage
    local loaded =
        math.ceil(100 * self.nYields / EXPECTED_N_YIELDS_TO_LOAD)
    local percentStr = string.format("%2.0f%%", loaded)
    x, y = self.loadingPercent.xPx, self.loadingPercent.yPx
    print(percentStr, x, y, PALETTE.WHITE, true)

    -- hacky: just needed some kind of periodic timer
    if self.finishedLoading and ColorCyclePhase % 64 < 32 then
        local msg = 'Click or tap to continue...'
        --- this ended up being easier than using the node centering functions
        local msgW = print(msg, SCREEN_W_px, SCREEN_H_px)
        print(msg, (SCREEN_W_px - msgW) / 2, self.loadingPercent.yPx + TILE_H_px, PALETTE.WHITE)
    end
end
--------------------------------------------------------------------------------

---@class StIntro : IAppState
---@field tick fun(self, MouseState): IAppState | nil -- returns new state
---@field draw fun(self): nil
StIntro = {}
StIntro.__index = StIntro

SPR_FRONT_FAR_HEAD = 9
SPR_FRONT_FAR_HEAD_TW = 7
SPR_FRONT_FAR_HEAD_TH = 4
SPR_FRONT_FAR_BODY_HEAD_OFF_X = 8
SPR_FRONT_FAR_BODY_HEAD_OFF_Y = 28
SPR_FRONT_FAR_BODY = 74
SPR_FRONT_FAR_BODY_TW = 4
SPR_FRONT_FAR_BODY_TH = 2
SPR_FRONT_FAR_BODY_HAND_RIGHT = 88
SPR_FRONT_FAR_BODY_HAND_LEFT = 95
SPR_FRONT_FAR_BODY_HAND_OFF_X = 8
SPR_FRONT_FAR_BODY_HAND_OFF_Y = 8

SPR_SMALL_TILE_NORMAL = 366
SPR_SMALL_TILE_CHARGED = 367
SPR_SMALL_TILE_FROZEN = 382

SPR_FRONT_CLOSE_HEAD_STRAINED_ID = 136
SPR_FRONT_CLOSE_HEAD_STRAINED_TW = 8
SPR_FRONT_CLOSE_HEAD_STRAINED_TH = 4
SPR_FRONT_CLOSE_HEAD_CHEERFUL_ID = 128
SPR_FRONT_CLOSE_HEAD_CHEERFUL_TW = 8
SPR_FRONT_CLOSE_HEAD_CHEERFUL_TH = 4
SPR_FRONT_CLOSE_HAND_RIGHT_ID = 2
SPR_FRONT_CLOSE_HAND_RIGHT_TW = 2
SPR_FRONT_CLOSE_HAND_RIGHT_TH = 2
SPR_FRONT_CLOSE_HAND_LEFT_ID = 4
SPR_FRONT_CLOSE_HAND_LEFT_TW = 2
SPR_FRONT_CLOSE_HAND_LEFT_TH = 2
SPR_FRONT_CLOSE_HAND_THUMBS_UP_ID = 224
SPR_FRONT_CLOSE_HAND_THUMBS_UP_TW = 2
SPR_FRONT_CLOSE_HAND_THUMBS_UP_TH = 2
SPR_FRONT_CLOSE_HAND_BECKON_ID = 226
SPR_FRONT_CLOSE_HAND_BECKON_TW = 2
SPR_FRONT_CLOSE_HAND_BECKON_TH = 2

SPR_BACK_FAR_HEAD_ID = 32
SPR_BACK_FAR_HEAD_TW = 4
SPR_BACK_FAR_HEAD_TH = 3
SPR_BACK_FAR_BODY_ID = 80
SPR_BACK_FAR_BODY_TW = 3
SPR_BACK_FAR_BODY_TH = 3
SPR_BACK_FAR_HAND_LEFT_ID = 100
SPR_BACK_FAR_HAND_RIGHT_ID = 116


---@class IntroScene
---@field tickLen integer
---@field t integer
---@field draw fun(self: IntroScene): nil
---@field tick fun(self: IntroScene): nil
---@field finished fun(self: IntroScene): boolean
IntroScene = {}
IntroScene.__index = {}

---@param tickLen integer
---@return nil
function IntroScene.new(tickLen)
    local state = {
        t = 0,
        tickLen = tickLen
    }

    return setmetatable(state, IntroScene)
end

function IntroScene:finished()
    return self.t > self.tickLen
end

---@type string[]
MagispellsChars = {'m', 'a', 'g', 'i', 's', 'p', 'e', 'l', 'l', 's', '!'}
---@type TileElem[]
MagispellsElems = {
    'charged',  --m
    'normal',   --a
    'normal',   --g
    'normal',   --i
    'charged',  --s
    'normal',   --p
    'normal',   --e
    'normal',   --l
    'normal',   --l
    'normal',   --s
    'frozen'    --!
}

---@type IntroScene[]
IntroScenes = {
    -- far, front, hands out
    -- close, tiles moving up
    -- far, back, title in arc, last tile coming down (crash)
    -- close, smiling, thumbs up
}

INTRO_SCENE1_TIME = 1.44 * 60
INTRO_FAR_FLOAT_END_OFF_Y = -10
INTRO_FAR_FLOAT_HEAD_START_Y = 40
INTRO_FAR_FLOAT_HEAD_OFF_PER_TIC = INTRO_FAR_FLOAT_END_OFF_Y / INTRO_SCENE1_TIME
INTRO_SCENE1_TILE_SPEED = 1 -- pixels per tick
INTRO_SCENE1_N_TILES = 11
INTRO_SCENE1_TILE_MAX_SPEED = 4
INTRO_SCENE1_TILE_MIN_SPEED = 1
INTRO_SCENE1_TILE_MAX_OFF = 100
INTRO_SCENE1_TILE_MIN_OFF = 0

---@class Scene_FarFrontHandsOut : IntroScene
---@field head Node
---@field body Node
---@field rhand Node
---@field lhand Node
---@field tilePoses Node[]
---@field tileVelos integer[]
Scene_FarFrontHandsOut = {}
setmetatable(Scene_FarFrontHandsOut, {__index = IntroScene})

function Scene_FarFrontHandsOut.new()
    local state = IntroScene.new(INTRO_SCENE1_TIME) --[[@as Scene_FarFrontHandsOut]]
    state.head = Node.new(
        nil, "head",
        122, 40,
        SPR_FRONT_FAR_HEAD_TW * TILE_W_px,
        SPR_FRONT_FAR_HEAD_TH * TILE_H_px
    )
    state.body = Node.new(
        state.head, "body",
        SPR_FRONT_FAR_BODY_HEAD_OFF_X,
        SPR_FRONT_FAR_BODY_HEAD_OFF_Y,
        SPR_FRONT_FAR_BODY_TW * TILE_W_px,
        SPR_FRONT_FAR_BODY_TH * TILE_H_px
    )
    state.rhand = Node.new(
        state.body, "rhand",
        -SPR_FRONT_FAR_BODY_HAND_OFF_X,
        SPR_FRONT_FAR_BODY_HAND_OFF_Y,
        1, 1
    )
    state.lhand = Node.new(
        state.body, "lhand",
        state.body.wpx,
        SPR_FRONT_FAR_BODY_HAND_OFF_Y,
        1, 1
    )
    state.tilePoses = {}
    state.tileVelos = {}

    local old_seed = math.random(0, 0xFFFFFFFF)

    math.randomseed(44)

    -- scatter tiles around.
    for i=1, INTRO_SCENE1_N_TILES do
        local x = math.random(0, SCREEN_W_px - TILE_W_px)
        local y = math.random(INTRO_SCENE1_TILE_MIN_OFF, INTRO_SCENE1_TILE_MAX_OFF)
            + SCREEN_H_px
        local v = -math.random() *
            (INTRO_SCENE1_TILE_MAX_SPEED - INTRO_SCENE1_TILE_MIN_SPEED) -
            INTRO_SCENE1_TILE_MIN_SPEED

        table.insert(state.tilePoses, Node.new(nil, '', x, y))
        table.insert(state.tileVelos, v)
    end

    math.randomseed(old_seed)

    return setmetatable(state, {__index = Scene_FarFrontHandsOut})
end

function Scene_FarFrontHandsOut:tick()
    self.head.yoffpx = self.head.yoffpx + INTRO_FAR_FLOAT_HEAD_OFF_PER_TIC

    for i, _ in ipairs(self.tilePoses) do
        local node = self.tilePoses[i]
        local velo = self.tileVelos[i]
        node.yoffpx = node.yoffpx + velo
    end
    self.t = self.t + 1
end

function Scene_FarFrontHandsOut:draw()
    local headX, headY = self.head:pos()
    local bodyX, bodyY = self.body:pos()
    local rhandX, rhandY = self.rhand:pos()
    local lhandX, lhandY = self.lhand:pos()

    spr(SPR_FRONT_FAR_HEAD, headX, headY, PALETTE.BLACK, 1, 0, 0,
        SPR_FRONT_FAR_HEAD_TW, SPR_FRONT_FAR_HEAD_TH)
    spr(SPR_FRONT_FAR_BODY, bodyX, bodyY, PALETTE.BLACK, 1, 0, 0,
        SPR_FRONT_FAR_BODY_TW, SPR_FRONT_FAR_BODY_TH)
    spr(SPR_FRONT_FAR_BODY_HAND_RIGHT, rhandX, rhandY, PALETTE.BLACK,
        1, 0, 0, 1, 1)
    spr(SPR_FRONT_FAR_BODY_HAND_LEFT, lhandX, lhandY, PALETTE.BLACK,
        1, 0, 0, 1, 1)

    for i, tile in ipairs(self.tilePoses) do
        local tx, ty = tile:pos()
        local spriteId = SPR_SMALL_TILE_NORMAL
        if i == 1 or i == 5 then
            spriteId = SPR_SMALL_TILE_CHARGED
        elseif i == 11 then
            spriteId = SPR_SMALL_TILE_FROZEN
        end

        spr(spriteId, tx, ty, PALETTE.BLACK, 1, 1, 0, 1, 1)
    end
end

---@class Scene_NearFront : IntroScene
---@field body Node
---@field rhand Node
---@field lhand Node
---@field tilePoses Node[]
---@field tileVelos integer[]
Scene_NearFront = {}
setmetatable(Scene_NearFront, {__index = IntroScene})

INTRO_SCENE2_TIME = 60 * 1.3
INTRO_NEAR_FRONT_END_OFF_Y  = 20
INTRO_NEAR_FRONT_HEAD_START_Y = 40
INTRO_NEAR_FRONT_HEAD_START_X = 100
INTRO_NEAR_FRONT_HEAD_OFF_PER_TIC = INTRO_NEAR_FRONT_END_OFF_Y / INTRO_SCENE2_TIME
INTRO_NEAR_FRONT_HAND_OFF_PER_TIC = INTRO_NEAR_FRONT_HEAD_OFF_PER_TIC / 2
INTRO_NEAR_FRONT_SPR_BODY_ID = 136
INTRO_NEAR_FRONT_SPR_BODY_TW = 8
INTRO_NEAR_FRONT_SPR_BODY_TH = 8

INTRO_NEAR_FRONT_SPR_LHAND_ID = 2
INTRO_NEAR_FRONT_SPR_LHAND_OFF_X = -16
INTRO_NEAR_FRONT_SPR_RHAND_ID = 4
INTRO_NEAR_FRONT_SPR_RHAND_OFF_X = 0
INTRO_NEAR_FRONT_SPR_HANDS_OFF_Y_START = 40

INTRO_NEAR_FRONT_N_TILES = 11
INTRO_NEAR_FRONT_TILES_BEFORE_WISPELL = 5

function Scene_NearFront.new()
    local state = IntroScene.new(INTRO_SCENE2_TIME) --[[ @as Scene_NearFront ]]
    state.body = Node.new(
        nil, 'body',
        INTRO_NEAR_FRONT_HEAD_START_X, 
        INTRO_NEAR_FRONT_HEAD_START_Y,
        8 * TILE_W_px, 8 * TILE_H_px
    )
    state.lhand = Node.new(
        state.body, 'lhand',
        INTRO_NEAR_FRONT_SPR_LHAND_OFF_X,
        INTRO_NEAR_FRONT_SPR_HANDS_OFF_Y_START, 16, 16
    )
    state.rhand = Node.new(
        state.body, 'rhand',
        INTRO_NEAR_FRONT_SPR_RHAND_OFF_X + state.body.wpx,
        INTRO_NEAR_FRONT_SPR_HANDS_OFF_Y_START, 16, 16
    )
    state.tilePoses = {}
    state.tileVelos = {}

    state.tilePoses[1] = Node.new(nil, 'm-tile', 25, SCREEN_H_px + 5)
    state.tileVelos[1] = -2

    state.tilePoses[2] = Node.new(nil, 'a-tile', 80, SCREEN_H_px)
    state.tileVelos[2] = -2.5

    state.tilePoses[3] = Node.new(nil, 'g-tile', 110, SCREEN_H_px + 30)
    state.tileVelos[3] = -2.5

    state.tilePoses[4] = Node.new(nil, 'i-tile', 140, SCREEN_H_px + 10)
    state.tileVelos[4] = -2.0

    state.tilePoses[5] = Node.new(nil, 's-tile', 165, SCREEN_H_px + 75)
    state.tileVelos[5] = -2.5

    state.tilePoses[6] = Node.new(nil, 'p-tile', 195, SCREEN_H_px - 30)
    state.tileVelos[6] = -2

    state.tilePoses[7] = Node.new(nil, 'e-tile', 55, SCREEN_H_px - 40)
    state.tileVelos[7] = -1.25

    state.tilePoses[8] = Node.new(nil, 'l-tile', 25, SCREEN_H_px - 50)
    state.tileVelos[8] = -1.25

    state.tilePoses[9] = Node.new(nil, 'l-tile2', 75, SCREEN_H_px - 25)
    state.tileVelos[9] = -1.5

    state.tilePoses[10] = Node.new(nil, 's-tile', 222, SCREEN_H_px - 60)
    state.tileVelos[10] = -1

    state.tilePoses[11] = Node.new(nil, '!-tile', 165, SCREEN_H_px - 35)
    state.tileVelos[11] = -1.25

    return setmetatable(state, {__index = Scene_NearFront})
end

function Scene_NearFront:tick()
    self.body.yoffpx = self.body.yoffpx - INTRO_NEAR_FRONT_HEAD_OFF_PER_TIC
    self.lhand.yoffpx = self.lhand.yoffpx - INTRO_NEAR_FRONT_HAND_OFF_PER_TIC
    self.rhand.yoffpx = self.rhand.yoffpx - INTRO_NEAR_FRONT_HAND_OFF_PER_TIC

    for i, _ in ipairs(self.tilePoses) do
        self.tilePoses[i].yoffpx = self.tilePoses[i].yoffpx + self.tileVelos[i]
    end

    self.t = self.t + 1
end

function Scene_NearFront:draw()
    local x, y = self.body:pos()

    -- tiles behind wispell
    for i=INTRO_NEAR_FRONT_TILES_BEFORE_WISPELL, #MagispellsChars do
        local node = self.tilePoses[i]
        local tx, ty = node:pos()
        local scale = 1
        RenderLetter(MagispellsChars[i], MagispellsElems[i], tx, ty, nil, scale)
    end

    spr(INTRO_NEAR_FRONT_SPR_BODY_ID, x, y, PALETTE.BLACK, 1, 0, 0,
        INTRO_NEAR_FRONT_SPR_BODY_TW, INTRO_NEAR_FRONT_SPR_BODY_TH)
    local lx, ly = self.lhand:pos()
    spr(INTRO_NEAR_FRONT_SPR_LHAND_ID, lx, ly, PALETTE.BLACK, 1, 0, 0, 2, 2)
    local rx, ry = self.rhand:pos()
    spr(INTRO_NEAR_FRONT_SPR_RHAND_ID, rx, ry, PALETTE.BLACK, 1, 0, 0, 2, 2)

    -- tiles in front
    for i=1, (INTRO_NEAR_FRONT_TILES_BEFORE_WISPELL - 1) do
        local node = self.tilePoses[i]
        local tx, ty = node:pos()
        local scale = 1
        RenderLetter(MagispellsChars[i], MagispellsElems[i], tx, ty, nil, scale)
    end
end

TITLE_SIDE_MARGIN = 32
TITLE_TOP_MARGIN = 10
TITLE_MAX_HEIGHT = 50

TitleNode = Node.new(nil, 'title',  TITLE_SIDE_MARGIN, TITLE_TOP_MARGIN)
TITLE_N_LETTERS = 11

TITLE_LETTER_BASE_GAP =
    (SCREEN_W_px - TITLE_N_LETTERS * LETTER_TILE_W_px - TITLE_SIDE_MARGIN * 2) /
    TITLE_N_LETTERS
TITLE_LETTER_BASE_XOFF = LETTER_TILE_W_px + TITLE_LETTER_BASE_GAP
-- TitleYSlope1 = -3

-- we want the letters to form a nice arc. how much of an arc?
TITLE_ARC_RADS = TAU / 4
TITLE_HALF_ARC = TITLE_ARC_RADS / 2
TITLE_HALF_N_LETTERS = TITLE_N_LETTERS / 2

TITLE_MAX_YOFF_FACTOR = 1 / (1 - math.cos(TITLE_HALF_ARC))
---@param whichNo integer
function TitleLetterOffY(whichNo)
    local phase = (whichNo - 1 - TITLE_HALF_N_LETTERS + .5) / (TITLE_N_LETTERS - 1)
    return TITLE_MAX_HEIGHT * (1 -
        math.cos(phase * TITLE_HALF_ARC)) * TITLE_MAX_YOFF_FACTOR + LETTER_TILE_H_px
end

---@type Node[]
TitleLetterNodes = {}

_TitleNodeNames = {'m', 'a', 'g', 'i', 's1', 'p', 'e', 'l1', 'l2', 's2', '!'}

for i = 1, TITLE_N_LETTERS do
    local offY = TitleLetterOffY(i)
    local node = Node.new(
        TitleNode,
        _TitleNodeNames[i],
        (i - 1) * TITLE_LETTER_BASE_XOFF,
        offY
    )
    table.insert(TitleLetterNodes, node)
end

---@alias PalEntry Rgb

---@class Scene_FarBack : IntroScene
---@field body Node
---@field head Node
---@field rhand Node
---@field lhand Node
---@field bangNode Node
---@field tilePoses Node[]
---@field tileVelos integer[]
---@field tileLetters string[]
---@field tileElems TileElem[]
---@field handDownTicks integer
---@field bumpNode Node
---@field savedPalette PalEntry[]
---@field palFadeStep PalEntry[] # how much to fade each entry per tick
Scene_FarBack = {}
setmetatable(Scene_FarBack, {__index = IntroScene})

INTRO_SCENE3_TIME = 5 * 60

INTRO_SCENE3_FINAL_HAND_OFF = 8
INTRO_SCENE3_HAND_OFF_TIME = 2 * 60
INTRO_SCENE3_HAND_OFF_PER_TICK =
    INTRO_SCENE3_FINAL_HAND_OFF / INTRO_SCENE3_HAND_OFF_TIME
INTRO_SCENE3_BANG_NODE_FINAL_YOFF = TitleLetterOffY(TITLE_N_LETTERS)
INTRO_SCENE3_BANG_NODE_START_YOFF = -LETTER_TILE_H_px
INTRO_SCENE3_BANG_NODE_OFF_PER_TICK =
    (INTRO_SCENE3_BANG_NODE_FINAL_YOFF - INTRO_SCENE3_BANG_NODE_START_YOFF) /
    INTRO_SCENE3_HAND_OFF_TIME
INTRO_SCENE3_BUMP_OFFY = -2
INTRO_SCENE3_BUMP_UP_TICKS = 6
INTRO_SCENE3_BUMP_SFX = 20
INTRO_SCENE3_FADE_OUT_START = 3 * 60
INTRO_SCENE3_FADE_OUT_TICKS = 1 * 60
INTRO_SCENE3_FADE_OUT_CHUNKS = 6
INTRO_SCENE3_FADE_OUT_AMOUNT = 1 / INTRO_SCENE3_FADE_OUT_CHUNKS
INTRO_SCENE3_FADE_OUT_TICKS_PER_CHUNK =
    INTRO_SCENE3_FADE_OUT_TICKS /
    INTRO_SCENE3_FADE_OUT_CHUNKS
INTRO_SCENE3_FADE_OUT_MOD = math.floor(INTRO_SCENE3_FADE_OUT_TICKS_PER_CHUNK)

function Scene_FarBack.new()
    local state = IntroScene.new(INTRO_SCENE3_TIME) --[[@as Scene_FarBack]]
    -- you know, it might be easier if I hardcode some of these constants

    -- used to bump everything when the last letter hits its spot
    state.bumpNode = Node.new(nil, 'bump', 0, 0)
    -- temporarily parent the title to the bump so all the letters bump up
    TitleNode.parent = state.bumpNode
    

    state.body = Node.new(
        nil, 'body', 45, 100,
        SPR_BACK_FAR_BODY_TW * TILE_W_px,
        SPR_BACK_FAR_BODY_TH * TILE_H_px
    )
    state.head = Node.new(
        state.body, 'head', 0, -SPR_BACK_FAR_HEAD_TH * TILE_H_px + 4,
        SPR_BACK_FAR_HEAD_TW * TILE_W_px,
        SPR_BACK_FAR_HEAD_TH * TILE_H_px
    )
    state.rhand = Node.new(
        state.body, 'rhand',
        SPR_BACK_FAR_BODY_TW * TILE_W_px + 2,
        2, 8, 8
    )
    state.lhand = Node.new(state.body, 'lhand', 0, -3, 8, 8)
    state.bangNode = Node.new(
        TitleNode, '!',
        TitleLetterNodes[TITLE_N_LETTERS].xoffpx,
        INTRO_SCENE3_BANG_NODE_START_YOFF
    )
    state.savedPalette = {}
    state.palFadeStep = {}

    -- save the palette so that we can fade out
    for i=0, 15 do
        --- @type PalEntry
        local saved = {}
        local entry = PALETTE_ADDR + i * 3
        saved.r = peek(entry)
        saved.g = peek(entry + 1)
        saved.b = peek(entry + 2)
        table.insert(state.savedPalette, saved)

        local step = {}
        step.r = saved.r / INTRO_SCENE3_FADE_OUT_TICKS
        step.g = saved.g / INTRO_SCENE3_FADE_OUT_TICKS
        step.b = saved.b / INTRO_SCENE3_FADE_OUT_TICKS
        table.insert(state.palFadeStep, step)
    end

    state.handDownTicks = 0

    return setmetatable(state, {__index = Scene_FarBack})
end



---@param palStart PalEntry[]
---@param amount number
---@return nil
function FadeOutBy(palStart, amount)
    for palIndex=0, 15 do
        local orig = palStart[palIndex + 1]
        local amntR = orig.r * amount
        local amntG = orig.g * amount
        local amntB = orig.b * amount
        local color = {
            r = orig.r - amntR,
            g = orig.g - amntG,
            b = orig.b - amntB
        }
        PokePalColor(palIndex, color)
    end
end


---@param palEnd PalEntry[]
---@param amount number
---@return nil
function FadeInBy(palEnd, amount)
    for palIndex=0, 15 do
        local dest = palEnd[palIndex + 1]
        local amntR = dest.r * amount
        local amntG = dest.g * amount
        local amntB = dest.b * amount
        PokePalColor(palIndex, {r = amntR, g = amntG, b = amntB})
    end
end


function Scene_FarBack:tick()
    self.t = self.t + 1

    if self.handDownTicks < INTRO_SCENE3_HAND_OFF_TIME then
        self.handDownTicks = self.handDownTicks + 1
        self.lhand.yoffpx = self.lhand.yoffpx + INTRO_SCENE3_HAND_OFF_PER_TICK
        self.rhand.yoffpx = self.rhand.yoffpx + INTRO_SCENE3_HAND_OFF_PER_TICK
        self.bangNode.yoffpx = self.bangNode.yoffpx + INTRO_SCENE3_BANG_NODE_OFF_PER_TICK
        return
    end

    local timeAfterBump = self.handDownTicks - INTRO_SCENE3_HAND_OFF_TIME

    if timeAfterBump == 0 then
        self.bumpNode.yoffpx = INTRO_SCENE3_BUMP_OFFY
        sfx(INTRO_SCENE3_BUMP_SFX, 'C-3', 120, SFX_CHANNEL, 15)
    elseif timeAfterBump == INTRO_SCENE3_BUMP_UP_TICKS then
        self.bumpNode.yoffpx = 0
    end

    local timeAfterFade = self.t - INTRO_SCENE3_FADE_OUT_START
    local timesFaded = timeAfterFade / INTRO_SCENE3_FADE_OUT_TICKS_PER_CHUNK

    if  timeAfterFade >= 0 and
        (   (timeAfterFade < INTRO_SCENE3_FADE_OUT_TICKS and
            timeAfterFade % INTRO_SCENE3_FADE_OUT_MOD == 0) or
            (timeAfterFade == INTRO_SCENE3_FADE_OUT_TICKS)
        )
    then
        FadeOutBy(self.savedPalette, INTRO_SCENE3_FADE_OUT_AMOUNT * timesFaded)
    end

    self.handDownTicks = self.handDownTicks + 1
end

function Scene_FarBack:draw()
    local rhx, rhy = self.rhand:pos()
    spr(SPR_BACK_FAR_HAND_RIGHT_ID, rhx, rhy, PALETTE.BLACK, 1, 0, 0, 1, 1)
    local lhx, lhy = self.lhand:pos()
    spr(SPR_BACK_FAR_HAND_LEFT_ID, lhx, lhy, PALETTE.BLACK, 1, 0, 0, 1, 1)
    local bx, by = self.body:pos()
    spr(SPR_BACK_FAR_BODY_ID, bx, by, PALETTE.BLACK, 1, 0, 0,
        SPR_BACK_FAR_BODY_TW, SPR_BACK_FAR_BODY_TH)
    local hx, hy = self.head:pos()
    spr(SPR_BACK_FAR_HEAD_ID, hx, hy, PALETTE.BLACK, 1, 0, 0,
        SPR_BACK_FAR_HEAD_TW, SPR_BACK_FAR_HEAD_TH)

    for i = 1, TITLE_N_LETTERS - 1 do
        local node = TitleLetterNodes[i]
        local lx, ly = node:pos()
        RenderLetter(MagispellsChars[i], MagispellsElems[i], lx, ly)
    end

    local bangx, bangy = self.bangNode:pos()
    RenderLetter('!', 'frozen', bangx, bangy)
end


---@class StIntro : IAppState
---@field scenes IntroScene
---@field curScene integer
StIntro = {}
StIntro.__index = StIntro

function StIntro.new()
    local state = {
        scenes = {},
        curScene = 1 -- 1,
    }

    state.scenes[1] = Scene_FarFrontHandsOut.new()
    state.scenes[2] = Scene_NearFront.new()
    state.scenes[3] = Scene_FarBack.new()

    return setmetatable(state, StIntro)
end

function StIntro:draw()
    self.scenes[self.curScene]:draw()
end

function StIntro:enter()
    sync(1, 1) -- switch tiles to bank 1
    if MusicEnabled then music(0, 0, 0, false) end
end

function StIntro:leave()
    music()
end

INTRO_FADE_OUT_SCENE = 3


-- cyan cycling definitions for the intro and main menu where wispell's 
-- ectoplasm changes color (TODO: consider adding this to the main game, too)
---@type Rgb
CYAN_LO = {
    r = 0x22,
    g = 0x55,
    b = 0x77
}
---@type Rgb
CYAN_HI = {
    r = 0x8f,
    g = 0xfF,
    b = 0xFf
}
function CycleCyan()
    -- cycle cyan color 
    local newColor = CycleCurColor(CYAN_LO, CYAN_HI, ColorCyclePhase)
    PokePalColor(PALETTE.CYAN, newColor)

    ColorCyclePhase = (ColorCyclePhase + 1) % 1024
end

---@param mouse MouseState
---@return StMainMenu|nil
function StIntro:tick(mouse)
    local mouseClicked = mouse.leftTrans == 'down'
    local cur = self.scenes[self.curScene]

    cur:tick()

    if cur:finished() then
        self.curScene = self.curScene + 1
    end

    -- convenience local, used in two places conditionally
    local fadeOutScene = self.scenes[#self.scenes] --[[@as Scene_FarBack]]
    if  self.curScene < INTRO_FADE_OUT_SCENE or
        fadeOutScene.t < INTRO_SCENE3_FADE_OUT_START
    then
        CycleCyan()
    end

    if self.curScene > #self.scenes or mouseClicked then
        -- TRANSITION TO MAIN MENU
        return StMainMenu.new()
    end
end

-- basic storyboard:
-- wispell, small is hovering, hands waving, core glowing, minor key intro plays
-- particles come up from the bottom of the screen
-- Zoom in on larger sprite, now background is glowing,
-- in the foreground letter sprites are drawn coming up
-- Zoom back out, facing behind Wispell, as sprites come down in shape of title
-- Wispell smiles and faces the camera, giving the thumbs up. 
-- mixolydian title music starts playing
-- I like it! It ended up looking pretty good.


---@alias SubMenuTransition SubMenu | nil | number | string # the number is for the new game start level, the string is for other app states

---@class SubMenu
---@field buttons Button[]
---@field tick fun(self: SubMenu, mouse: MouseState): SubMenuTransition
---@field hoverButton Button|nil # for hints
SubMenu = {}


---@return SubMenu
function SubMenu.new()
    return setmetatable({buttons = {}}, SubMenu)
end

---@param mouse MouseState
---@return Button|nil
function SubMenu:updateButtonsAndDetectClick(mouse)
    return Button.updateButtonsAndDetectClick(
        self.buttons, mouse.x, mouse.y, mouse.leftTrans == 'down')
end

function SubMenu:drawButtons()
    for _, button in ipairs(self.buttons) do
        button:draw()
    end
end

function SubMenu:tick(mouse)
    -- abstract
end

function SubMenu:draw()
    -- abstract 
end

--- The main menu's sub-menu 
---@class Sub_Title : SubMenu
---@field finalPalette PalEntry[]
---@field nTitleLetters Node
---@field nButtons Node
---@field btnWidth number
---@field nWispellHead Node
---@field nWispellBody Node
---@field nWispellLHand Node
---@field nWispellLHandSaved Node
---@field nWispellRHand Node
---@field hoverCycle integer
---@field btnStartGame TextButton
---@field btnHighScores TextButton
---@field btnEnding TextButton
---@field btnMusic SpriteToggleButton
---@field btnSfx SpriteToggleButton
---@field nCopyright Node
Sub_Title = {}
setmetatable(Sub_Title, {__index = SubMenu})

MENU_TITLE_OFFY = -20
MENU_SPR_THUMBS_UP = 224
MENU_SPR_HAND_WAVE = 226
MENU_SPR_HAND_TW = 2
MENU_SPR_HAND_TH = 2
MENU_SPR_HEAD = 128
MENU_SPR_HEAD_TW = 8
MENU_SPR_HEAD_TH = 6
MENU_SPR_BODY_OFFX = 8
MENU_SPR_BODY_OFFY = -4
MENU_SPR_BODY = 217
MENU_SPR_BODY_TW = 6
MENU_SPR_BODY_TH = 3
MENU_SPR_LHAND_OFFX = MENU_SPR_BODY_TW * TILE_W_px + 8
MENU_SPR_LHAND_OFFY = -16
MENU_SPR_RHAND_OFFX = -TILE_W_px
MENU_SPR_RHAND_OFFY = TILE_H_px
MENU_WISPELL_HOVER_AMP = 4
--- seconds
MENU_WISPELL_HOVER_PERIOD = 4
MENU_WISPELL_HOVER_PERIOD_TICS = math.floor(MENU_WISPELL_HOVER_PERIOD * 60)
--- phase per tick
MENU_WISPELL_HOVER_FREQ = 1 / MENU_WISPELL_HOVER_PERIOD_TICS

MENU_BTN_START_NAME = 'new game'
MENU_BTN_START_TEXT = 'New Game!'
MENU_BTN_START_HINT = 'Start a new game!'

MENU_BTN_HS_NAME = 'high scores'
MENU_BTN_HS_TEXT = 'High Scores'
MENU_BTN_HS_HINT = 'Look at your high scores!'

MENU_BTN_ENDING_NAME = 'view ending'
MENU_BTN_ENDING_TEXT = 'View Ending!'
MENU_BTN_ENDING_HINT = 'See the ending again!'

MENU_BTN_SFX_NAME = 'toggle sfx'
MENU_BTN_SFX_HINT = 'Toggle sound effects'

MENU_BTN_MUSIC_NAME = 'toggle music'
MENU_BTN_MUSIC_HINT = 'Toggle music'

MENU_GESTURE_OFF_X = -4
MENU_GESTURE_OFF_Y = 4
MENU_SFX_CHOOSE = 48

MENU_COPYRIGHT = '(c) Grant Williams, 2026. AGPL 3.0+.'
MENU_COPYRIGHT_OFFY = 40

MENU_TOGGLE_SFX_OFFX = SCREEN_W_px - BTN_SIMPLE_W
MENU_TOGGLE_SFX_OFFY = SCREEN_H_px - BTN_SIMPLE_H
MENU_TOGGLE_MUSIC_OFFX = MENU_TOGGLE_SFX_OFFX - BTN_SIMPLE_W
MENU_TOGGLE_MUSIC_OFFY = MENU_TOGGLE_SFX_OFFY

function DrawTitleLetters()
    for i, node in ipairs(TitleLetterNodes) do
        local lx, ly = node:pos()
        RenderLetter(MagispellsChars[i], MagispellsElems[i], lx, ly)
    end
end

---@return Sub_Title
function Sub_Title.new()
    local state = SubMenu.new() --[[@as Sub_Title]]

    local wispellHead = Node.new(
        nil, 'wispell head',
        0, SCREEN_H_px - (MENU_SPR_HEAD_TH + MENU_SPR_BODY_TH) * TILE_H_px,
        MENU_SPR_HEAD_TW * TILE_W_px,
        MENU_SPR_HEAD_TH * TILE_H_px
    )
    local wispellBody = Node.new(
        wispellHead, 'wispell body',
        MENU_SPR_BODY_OFFX, MENU_SPR_BODY_OFFY + MENU_SPR_HEAD_TH * TILE_H_px,
        MENU_SPR_BODY_TW * TILE_W_px,
        MENU_SPR_BODY_TH * TILE_H_px
    )
    local wispellLHand = Node.new(
        wispellBody, 'wispell lhand',
        MENU_SPR_LHAND_OFFX, MENU_SPR_LHAND_OFFY,
        MENU_SPR_HAND_TW, MENU_SPR_HAND_TH
    )
    local wispellRHand = Node.new(
        wispellBody, 'wispell rhand',
        MENU_SPR_RHAND_OFFX, MENU_SPR_RHAND_OFFY,
        MENU_SPR_HAND_TW, MENU_SPR_HAND_TH
    )

    local copyrightWidth = print(MENU_COPYRIGHT, SCREEN_W_px, 0, 0, false, 1, true)
    local copyright = Node.new(
        nil, 'copyright',
        (SCREEN_W_px - copyrightWidth) / 2,
        MENU_COPYRIGHT_OFFY,
        copyrightWidth, TEXT_BUTTON_H_PX
    )

    for var, val in pairs({
        nTitleLetters = Node.new(nil, 'title letters', 0, MENU_TITLE_OFFY),
        nWispellHead = wispellHead,
        nWispellBody = wispellBody,
        nWispellLHand = wispellLHand,
        nWispellRHand = wispellRHand,
        nWispellLHandSaved = wispellLHand,
        hoverCycle = 0,
        nCopyright = copyright
    }) do
        state[var] = val
    end

    -- print button off screen to get the rendered width
    local startBtnW = print(MENU_BTN_START_TEXT, SCREEN_W_px, SCREEN_H_px)
    local hsBtnW = print(MENU_BTN_HS_TEXT, SCREEN_W_px, SCREEN_H_px)
    local endingBtnW = print(MENU_BTN_ENDING_TEXT, SCREEN_W_px, SCREEN_H_px)

    state.nButtons = Node.new(
        nil, 'buttons',
        SCREEN_W_px / 2,
        SCREEN_H_px / 2
    )
    local nStartButton = Node.new(
        state.nButtons, 'start game btn node',
        -startBtnW / 2,
        0, startBtnW, TEXT_BUTTON_H_PX
    )
    local nHsButton = Node.new(
        state.nButtons, 'highscore btn node',
        -hsBtnW / 2,
        TEXT_BUTTON_H_PX + BTN_VERT_PADDING_PX * 2,
        hsBtnW, TEXT_BUTTON_H_PX
    )
    local nEndingButton = Node.new(
        state.nButtons, 'view ending btn node',
        -endingBtnW / 2,
        (TEXT_BUTTON_H_PX + BTN_VERT_PADDING_PX * 2) * 2,
        endingBtnW, TEXT_BUTTON_H_PX
    )
    local nMusicButton = Node.new(
        nil, 'music toggle btn node',
        MENU_TOGGLE_MUSIC_OFFX,
        MENU_TOGGLE_MUSIC_OFFY,
        BTN_SIMPLE_W, BTN_SIMPLE_H
    )
    local nSfxButton = Node.new(
        nil, 'sfx toggle btn node',
        MENU_TOGGLE_SFX_OFFX,
        MENU_TOGGLE_SFX_OFFY,
        BTN_SIMPLE_W, BTN_SIMPLE_H
    )

    state.btnStartGame = TextButton.new(
        nStartButton,
        MENU_BTN_START_NAME,
        MENU_BTN_START_TEXT,
        MENU_BTN_START_HINT,
        PALETTE.YELLOW
    )
    state.btnHighScores = TextButton.new(
        nHsButton,
        MENU_BTN_HS_NAME,
        MENU_BTN_HS_TEXT,
        MENU_BTN_HS_HINT,
        PALETTE.YELLOW
    )
    state.btnEnding = TextButton.new(
        nEndingButton,
        MENU_BTN_ENDING_NAME,
        MENU_BTN_ENDING_TEXT,
        MENU_BTN_ENDING_HINT,
        PALETTE.YELLOW
    )

    state.btnSfx = SpriteToggleButton.new(
        nSfxButton,
        MENU_BTN_SFX_NAME,
        MENU_BTN_SFX_HINT,
        {BTN_SPR_SFX_ON, BTN_SPR_SFX_OFF},
        PALETTE.BLACK
    )
    state.btnMusic = SpriteToggleButton.new(
        nMusicButton,
        MENU_BTN_MUSIC_NAME,
        MENU_BTN_MUSIC_HINT,
        {BTN_SPR_MUSIC_ON, BTN_SPR_MUSIC_OFF},
        PALETTE.BLACK
    )


    table.insert(state.buttons, state.btnStartGame)
    table.insert(state.buttons, state.btnHighScores)

    if pmem(MAX_LVL_REACHED_PMEM_ADDR) > MAX_LEVEL then
        table.insert(state.buttons, state.btnEnding)
    end

    table.insert(state.buttons, state.btnSfx)
    table.insert(state.buttons, state.btnMusic)

    TitleNode.parent = state.nTitleLetters

    return setmetatable(state, {__index = Sub_Title})
end

function Sub_Title:tick(mouse)
    self.hoverCycle = (self.hoverCycle + 1) % MENU_WISPELL_HOVER_PERIOD_TICS

    local button = self:updateButtonsAndDetectClick(mouse)

    if button then
        sfx(MENU_SFX_CHOOSE, 'C-5', 60, SFX_CHANNEL, SfxVol)
        if button.name == MENU_BTN_START_NAME then
            return Sub_NewGame.new()
        elseif button.name == MENU_BTN_HS_NAME then
            return Sub_Highscores.new()
        elseif button.name == MENU_BTN_ENDING_NAME then
            return 'ending'
        elseif button.name == MENU_BTN_MUSIC_NAME then
            ToggleMusic()
            if MusicEnabled then
                music(1)
            end
        elseif button.name == MENU_BTN_SFX_NAME then
            ToggleSfx()
        end
    end

    local pointing = false
    self.hoverButton = nil
    for _, maybeHoverButton in ipairs(self.buttons) do
        if maybeHoverButton.hover then
            if maybeHoverButton.node.parent == self.nButtons then
                self:pointAt(maybeHoverButton.node)
            end
            pointing = true
            self.hoverButton = maybeHoverButton
        end
    end

    self.btnMusic.toggleState = MusicEnabled and 1 or 2
    self.btnSfx.toggleState = SfxVol == 0 and 2 or 1

    if not pointing then self:stopPointing() end
end

---Make Wispell gesture to a node with his hand
---@param n Node
function Sub_Title:pointAt(n)
    self.nWispellLHand =
        Node.new(
            n, 'temp gesture node',
            -MENU_SPR_HAND_TW * TILE_W_px + MENU_GESTURE_OFF_X,
            MENU_GESTURE_OFF_Y
        )
end

function Sub_Title:stopPointing()
    self.nWispellLHand = self.nWispellLHandSaved
end

function Sub_Title:draw()
    local hoverPhase = self.hoverCycle / MENU_WISPELL_HOVER_PERIOD_TICS
    local hoverOff = MENU_WISPELL_HOVER_AMP * math.sin(TAU * hoverPhase)

    local hx, hy = self.nWispellHead:pos()
    spr(MENU_SPR_HEAD, hx, hy + hoverOff, PALETTE.BLACK, 1, 0, 0,
        MENU_SPR_HEAD_TW, MENU_SPR_HEAD_TH)
    local bx, by = self.nWispellBody:pos()
    spr(MENU_SPR_BODY, bx, by + hoverOff, PALETTE.BLACK,
        1, 0, 0, MENU_SPR_BODY_TW, MENU_SPR_BODY_TH)
    local lhx, lhy = self.nWispellLHand:pos()
    spr(MENU_SPR_HAND_WAVE, lhx, lhy + hoverOff, PALETTE.BLACK,
        1, 0, 0, MENU_SPR_HAND_TW, MENU_SPR_HAND_TH)
    local rhx, rhy = self.nWispellRHand:pos()
    spr(MENU_SPR_THUMBS_UP, rhx, rhy + hoverOff, PALETTE.BLACK,
        1, 1, 0, MENU_SPR_HAND_TW, MENU_SPR_HAND_TH)
    DrawTitleLetters()

    self:drawButtons()

    local cx, cy = self.nCopyright:pos()
    print(MENU_COPYRIGHT, cx, cy, PALETTE.LT_GRAY, false, 1, true)
end

---@class Sub_NewGame : SubMenu
---@field nButtonRoot Node
Sub_NewGame = {}
setmetatable(Sub_NewGame, {__index = SubMenu})

MENU_NEW_N_BUTTONS = 5
MENU_NEW_BUTTONS_OFFX = -10

MENU_NEW_LVL1_NAME = 'level1'
MENU_NEW_LVL1_TEXT = 'Level 1'
MENU_NEW_LVL4_NAME = 'level4'
MENU_NEW_LVL4_TEXT = 'Level 4'
MENU_NEW_LVL8_NAME = 'level8'
MENU_NEW_LVL8_TEXT = 'Level 8'
MENU_NEW_LVL12_NAME = 'level12'
MENU_NEW_LVL12_TEXT = 'level 12'
MENU_NEW_EXTENDED_NAME = 'extendedPlay'
MENU_NEW_EXTENDED_TEXT = 'Extended Play'
MENU_BACK_NAME = 'back'
MENU_BACK_TEXT = 'Back to Menu'

MENU_NEW_LVL1_HINT = 'Start from Level 1!'
MENU_NEW_LVL4_HINT = 'Start from Level 4!'
MENU_NEW_LVL8_HINT = 'Start from Level 8!'
MENU_NEW_LVL12_HINT = 'Start from Level 12!'
MENU_NEW_EXTENDED_HINT = 'Keep playing after the end!'
MENU_NEW_NOT_UNLOCKED_HINT = 'Must reach this level to start from here!'

function Sub_NewGame.new()
    local submenu = SubMenu.new() --[[@as Sub_NewGame]]

    --[[ buttons:
        Level 1
        Level 4
        Level 8
        Level 12
        Extended Play
        [vertical space]
        Back

        show 4 through 12 if they have been unlocked
        show extended play if the player has beaten level 15
    --]]

    local totalButtonHeight =
        MENU_NEW_N_BUTTONS * TEXT_BUTTON_H_PX +
        (MENU_NEW_N_BUTTONS - 1) * BTN_VERT_PADDING_PX

    local level1Width = print(MENU_NEW_LVL1_TEXT, SCREEN_W_px, 0)
    local level12Width = print(MENU_NEW_LVL12_TEXT, SCREEN_W_px, 0)
    local extendedWidth = print(MENU_NEW_EXTENDED_TEXT, SCREEN_W_px, 0)
    local backWidth = print(MENU_BACK_TEXT, SCREEN_W_px, 0)

    -- center the buttons 
    submenu.nButtonRoot = Node.new(
        nil, 'button root',
        (SCREEN_W_px - level1Width) / 2 + MENU_NEW_BUTTONS_OFFX,
        (SCREEN_H_px - totalButtonHeight) / 2,
        level1Width, totalButtonHeight
    )

    local BUTTON_YOFF = TEXT_BUTTON_H_PX + BTN_VERT_PADDING_PX

    local nLevel1 = Node.new(
        submenu.nButtonRoot, 'level 1 btn node',
        0, 0,
        level1Width, TEXT_BUTTON_H_PX
    )
    local nLevel4 = Node.new(
        nLevel1, 'level 4 btn node',
        0, BUTTON_YOFF,
        level1Width, TEXT_BUTTON_H_PX
    )
    local nLevel8 = Node.new(
        nLevel4, 'level 8 btn node',
        0, BUTTON_YOFF,
        level1Width, TEXT_BUTTON_H_PX
    )
    local nLevel12 = Node.new(
        nLevel8, 'level 12 btn node',
        0, BUTTON_YOFF,
        level12Width, TEXT_BUTTON_H_PX
    )
    local nExtended = Node.new(
        nLevel12, 'extended play btn node',
        0, BUTTON_YOFF,
        extendedWidth, TEXT_BUTTON_H_PX
    )
    local nBack = Node.new(
        nExtended, 'back btn node',
        0, BUTTON_YOFF * 2,
        backWidth, TEXT_BUTTON_H_PX
    )

    local level1 = TextButton.new(
        nLevel1,
        MENU_NEW_LVL1_NAME,
        MENU_NEW_LVL1_TEXT,
        MENU_NEW_LVL1_HINT,
        PALETTE.WHITE
    )
    local level4 = TextButton.new(
        nLevel4,
        MENU_NEW_LVL4_NAME,
        MENU_NEW_LVL4_TEXT,
        MENU_NEW_LVL4_HINT,
        PALETTE.WHITE
    )
    local level8 = TextButton.new(
        nLevel8,
        MENU_NEW_LVL8_NAME,
        MENU_NEW_LVL8_TEXT,
        MENU_NEW_LVL8_HINT,
        PALETTE.WHITE
    )
    local level12 = TextButton.new(
        nLevel12,
        MENU_NEW_LVL12_NAME,
        MENU_NEW_LVL12_TEXT,
        MENU_NEW_LVL12_HINT,
        PALETTE.WHITE
    )
    local extendedPlay = TextButton.new(
        nExtended,
        MENU_NEW_EXTENDED_NAME,
        MENU_NEW_EXTENDED_TEXT,
        MENU_NEW_EXTENDED_HINT,
        PALETTE.WHITE
    )
    local back = TextButton.new(
        nBack,
        MENU_BACK_NAME,
        MENU_BACK_TEXT,
        "Return to previous menu",
        PALETTE.WHITE
    )

    table.insert(submenu.buttons, level1)
    table.insert(submenu.buttons, level4)
    table.insert(submenu.buttons, level8)
    table.insert(submenu.buttons, level12)
    table.insert(submenu.buttons, extendedPlay)
    table.insert(submenu.buttons, back)

    return setmetatable(submenu, {__index = Sub_NewGame})
end

---maps new game buttons to which level they start on
---@type table<string, integer>
ButtonLevels = {
    [MENU_NEW_LVL1_NAME] = 1,
    [MENU_NEW_LVL4_NAME] = 4,
    [MENU_NEW_LVL8_NAME] = 8,
    [MENU_NEW_LVL12_NAME] = 12,
    [MENU_NEW_EXTENDED_NAME] = 16,
}

---maps new game buttons to their hints (so we can swap them out
---with the hint that says the level must be unlocked)
---@type table<string, string>
ButtonLevelHints = {
    [MENU_NEW_LVL1_NAME] = MENU_NEW_LVL1_HINT,
    [MENU_NEW_LVL4_NAME] = MENU_NEW_LVL4_HINT,
    [MENU_NEW_LVL8_NAME] = MENU_NEW_LVL8_HINT,
    [MENU_NEW_LVL12_NAME] = MENU_NEW_LVL12_HINT,
    [MENU_NEW_EXTENDED_NAME] = MENU_NEW_EXTENDED_HINT,
}

---@param mouse MouseState
---@return integer | SubMenuTransition
function Sub_NewGame:tick(mouse)
    if mouse.rightTrans == 'up' then
        return Sub_Title.new()
    end

    -- update buttons based on which levels have been reached
    for _, button in ipairs(self.buttons) do

        local level = ButtonLevels[button.name]
        local btn = (button --[[@as TextButton]])
        if level and pmem(MAX_LVL_REACHED_PMEM_ADDR) < level and level > 1 then
            btn.textColor = PALETTE.DK_GRAY
            btn.hint = MENU_NEW_NOT_UNLOCKED_HINT
        else
            btn.textColor = PALETTE.WHITE
            btn.hint = ButtonLevelHints[level] or btn.hint
        end
    end

    local clicked = self:updateButtonsAndDetectClick(mouse)

    if clicked then
        if clicked.name == MENU_BACK_NAME then
            return Sub_Title.new()
        end

        local level = ButtonLevels[clicked.name]

        if not level or (pmem(MAX_LVL_REACHED_PMEM_ADDR) < level and level > 1) then
            sfx(SFX.cant, 'C-4', 120, SFX_CHANNEL, SfxVol)
        else
            return level
        end
    end

    self.hoverButton = nil
    for _, button in ipairs(self.buttons) do
        if button.hover then
            self.hoverButton = button
        end
    end
end

function Sub_NewGame:draw()
    DrawTitleLetters()

    for _, button in ipairs(self.buttons) do
        button:drawBack()
        button:draw()
    end
end

---@class Sub_HighScores : SubMenu
---@field scores Highscore[]
---@field nRank Node
---@field nScore Node
---@field nLevel Node
---@field nTime Node
---@field nBestWord Node
---@field nBestWordWorth Node
Sub_Highscores = {}
setmetatable(Sub_Highscores, {__index = SubMenu})

MENU_HS_BACK_OFFY = 120
MENU_HS_BACK_NAME = MENU_BACK_NAME
MENU_HS_BACK_TEXT = 'Back'
MENU_HS_BACK_HINT = 'Back to main menu!'

MENU_HS_CLEAR_OFFY = 0
MENU_HS_CLEAR_NAME = 'clear'
MENU_HS_CLEAR_TEXT = 'Clear Saved Data'
MENU_HS_CLEAR_HINT = 'Delete all high scores and level clear data. Irreversable!'

MENU_HS_RANK_W = 24
MENU_HS_PAD = -12
MENU_HS_SCORE_W = 58
MENU_HS_LEVEL_W = 30
MENU_HS_TIME_W = 40
MENU_HS_BESTWORD_W = 60
MENU_HS_BESTWORD_SCORE_W = 40
MENU_HS_TOTAL_W = MENU_HS_RANK_W + MENU_HS_SCORE_W + MENU_HS_LEVEL_W + MENU_HS_TIME_W
MENU_HS_ROW_H = 8
MENU_HS_TOTAL_H = (N_HIGH_SCORES + 1) * MENU_HS_ROW_H
MENU_HS_TABLE_NODE = Node.new(
    nil, 'n hs table',
    0, 20,
    MENU_HS_TOTAL_W,
    MENU_HS_TOTAL_H
)

function Sub_Highscores.new()
    local nRank = Node.new(
        MENU_HS_TABLE_NODE, 'n rank',
        0, 0,
        MENU_HS_RANK_W,
        MENU_HS_TOTAL_H
    )
    local nScore = Node.new(
        nRank, 'n score',
        MENU_HS_RANK_W, 0,
        MENU_HS_SCORE_W,
        MENU_HS_TOTAL_H
    )
    local nLevel = Node.new(
        nScore, 'n level',
        MENU_HS_SCORE_W, 0,
        MENU_HS_LEVEL_W,
        MENU_HS_TOTAL_H
    )
    local nTime = Node.new(
        nLevel, 'n time',
        MENU_HS_LEVEL_W, 0,
        MENU_HS_TIME_W,
        MENU_HS_TOTAL_H
    )
    local nBestWord = Node.new(
        nTime, 'n best',
        MENU_HS_TIME_W, 0,
        MENU_HS_BESTWORD_W,
        MENU_HS_TOTAL_H
    )
    local nBestWordWorth = Node.new(
        nBestWord, 'n best worth',
        MENU_HS_BESTWORD_W, 0,
        MENU_HS_BESTWORD_SCORE_W,
        MENU_HS_TOTAL_H
    )


    -- it really would have been better if I had made this part of the 
    -- button class in retrospect, rather than computing the width manually.
    local backW = print(MENU_HS_BACK_TEXT, SCREEN_W_px)
    local clearW = print(MENU_HS_CLEAR_TEXT, SCREEN_W_px)

    local nBack = Node.new(
        nil, 'n back',
        (SCREEN_W_px - backW) / 2,
        MENU_HS_BACK_OFFY,
        backW, TEXT_BUTTON_H_PX
    )
    local nClear = Node.new(
        nil, 'n clear',
        (SCREEN_W_px - clearW) / 2,
        MENU_HS_CLEAR_OFFY,
        clearW, TEXT_BUTTON_H_PX
    )

    local back = TextButton.new(
        nBack,
        MENU_HS_BACK_NAME,
        MENU_HS_BACK_TEXT,
        MENU_HS_BACK_HINT,
        PALETTE.WHITE
    )
    local clear = TextButton.new(
        nClear,
        MENU_HS_CLEAR_NAME,
        MENU_HS_CLEAR_TEXT,
        MENU_HS_BACK_HINT,
        PALETTE.WHITE
    )

    local state = SubMenu.new() --[[@as Sub_HighScores]]
    state.buttons = {back, clear}
    state.scores = LoadHighScores()
    state.nRank = nRank
    state.nScore = nScore
    state.nLevel = nLevel
    state.nTime = nTime
    state.nBestWord = nBestWord
    state.nBestWordWorth = nBestWordWorth

    -- remove zero scores
    while #state.scores > 0 and state.scores[#state.scores].points == 0 do
        table.remove(state.scores)
    end

    return setmetatable(state, {__index = Sub_Highscores})
end

function Sub_Highscores:draw()
    for _, button in ipairs(self.buttons) do
        button:draw()
    end

    local headerColor = ((#self.scores == 0) and PALETTE.DK_GRAY) or PALETTE.YELLOW

    -- score header
    local rankx, ranky = self.nRank:pos()
    local rw = print('#', SCREEN_H_px, SCREEN_W_px)
    print('#', rankx + MENU_HS_RANK_W - rw + MENU_HS_PAD, ranky, headerColor)
    local scorex, scorey = self.nScore:pos()
    local scorew = print('Score', SCREEN_W_px, SCREEN_H_px)
    print('Score', scorex + MENU_HS_SCORE_W - scorew + MENU_HS_PAD, scorey, headerColor)
    local levelx, levely = self.nLevel:pos()
    local levelw = print('Lvl', SCREEN_W_px, SCREEN_H_px)
    print('Lvl', levelx + MENU_HS_LEVEL_W - levelw + MENU_HS_PAD, levely, headerColor)
    local timex, timey = self.nTime:pos()
    local timew = print('Time', SCREEN_W_px, SCREEN_H_px)
    print('Time', timex + MENU_HS_TIME_W - timew + MENU_HS_PAD, timey, headerColor)
    local bstwrdx, bstwrdy = self.nBestWord:pos()
    local bstwrdw = print('Best Word', SCREEN_W_px, SCREEN_H_px)
    print('Best Word', bstwrdx + MENU_HS_BESTWORD_W - bstwrdw + MENU_HS_PAD, bstwrdy, headerColor)
    local worthx, worthy = self.nBestWordWorth:pos()
    local worthw = print('Worth', SCREEN_W_px, SCREEN_H_px)
    print('Pts.', worthx + MENU_HS_BESTWORD_SCORE_W - worthw + MENU_HS_PAD, worthy, headerColor)

    if #self.scores == 0 then
        local msg = 'No high scores set!'
        local w = print(msg, SCREEN_W_px, SCREEN_H_px)
        print(msg, (SCREEN_W_px - w) / 2, (SCREEN_H_px - 6) / 2, PALETTE.WHITE)
        return
    end

    for i=1, #self.scores do
        local score = self.scores[i]
        if not score then goto continue end
        local color = PALETTE.WHITE

        local rx, ry = self.nRank:pos()
        local y = ry + i * MENU_HS_ROW_H
        local rw = print(tostring(i), SCREEN_W_px, SCREEN_H_px)
        print(tostring(i), rx + MENU_HS_RANK_W - rw + MENU_HS_PAD, y, color)

        local sx, _ = self.nScore:pos()
        local scorestr = tostring(score.points)
        if score.points > 999999999 then scorestr = 'High!' end
        local sw = print(scorestr, SCREEN_W_px, SCREEN_H_px)
        print(scorestr, sx + MENU_HS_SCORE_W + MENU_HS_PAD - sw, y, color)

        local lx, _ = self.nLevel:pos()
        local lw = print(tostring(score.level), SCREEN_W_px, SCREEN_H_px)
        print(tostring(score.level), lx + MENU_HS_LEVEL_W + MENU_HS_PAD - lw, y, color)

        local hours, mins, secs, _ticks = HoursMinsSecs(score.nTicks)
        local time

        if hours >= 10 then
            time = 'Long!'
        else
            local format = '%02d:%02d'
            local args = {mins, secs}
            if hours > 0 then
                format = '%d:' .. format
                table.insert(args, 1, hours)
            end
            time = string.format(format, table.unpack(args))
        end

        local tx, _ = self.nTime:pos()
        local tw = print(time, SCREEN_W_px, SCREEN_H_px)
        print(time, tx + MENU_HS_TIME_W + MENU_HS_PAD - tw, y, color)

        local bx, _ = self.nBestWord:pos()
        -- local bw = print(score.bestWord, SCREEN_W_px, SCREEN_H_px)
        print(score.bestWord, bx, y, color)

        local wx, _ = self.nBestWordWorth:pos()
        local wordScore
        if score.bestWordScore >= 0xFFFF then
            wordScore = "Max!"
        else
            wordScore = tostring(score.bestWordScore)
        end
        local ww = print(wordScore, SCREEN_W_px, SCREEN_H_px)
        print(wordScore, wx + MENU_HS_BESTWORD_SCORE_W
            + MENU_HS_PAD - ww, y, color)

        ::continue::
    end
end

---@param mouse MouseState
function Sub_Highscores:tick(mouse)
    if mouse.rightTrans == 'up' then
        return Sub_Title.new()
    end

    local clicked = self:updateButtonsAndDetectClick(mouse)

    if clicked then
        if clicked.name == MENU_HS_BACK_NAME then
            return Sub_Title.new()
        elseif clicked.name == MENU_HS_CLEAR_NAME then
            return Sub_ClearScores.new()
        end
    end
end


---@class Sub_ClearScores : SubMenu
---@field confirmed boolean
---@field lines string[]
---@field widths integer[]
---@field btnClear TextButton
---@field btnConfirm TextButton
Sub_ClearScores = {}
setmetatable(Sub_ClearScores, {__index = SubMenu})

MENU_CLEAR_REALLY_TEXT_OFFY = 40
MENU_CLEAR_WHAT_TEXT_OFFY = 48
MENU_CLEAR_IRREVERSABLE_TEXT_OFFY = 56
MENU_CLEAR_TEXT_OFFS = {
    MENU_CLEAR_REALLY_TEXT_OFFY,
    MENU_CLEAR_WHAT_TEXT_OFFY,
    MENU_CLEAR_IRREVERSABLE_TEXT_OFFY
}

MENU_CLEAR_CLEAR_BTN_OFFY = 72
MENU_CLEAR_CLEAR_BTN_NAME = 'clear'
MENU_CLEAR_CLEAR_BTN_TEXT = 'Clear'
MENU_CLEAR_CLEAR_BTN_HINT = 'Confirm that you want to clear all data'

MENU_CLEAR_CANCEL_BTN_NAME = 'cancel'
MENU_CLEAR_CANCEL_BTN_TEXT = 'Cancel'
MENU_CLEAR_CANCEL_BTN_HINT = 'Go back without clearing'

MENU_CLEAR_CONFIRM_BTN_NAME = 'confirm'
MENU_CLEAR_CONFIRM_BTN_TEXT = 'Confirm'
MENU_CLEAR_CONFIRM_BTN_HINT = 'No turning back once you clear!'
MENU_CLEAR_CONFIRM_GAPY = 5 * (TEXT_BUTTON_H_PX + BTN_VERT_PADDING_PX)

-- it would be better factoring to share code with the "really abandon"
-- code for the in game state.

function Sub_ClearScores.new()
    local lines = {
        'Do you really want to clear all saved data:',
        'high scores, unlocked songs and stages.',
        'This action is irreversable!'
    }

    local widths = {}
    for i, line in ipairs(lines) do
        widths[i] = print(line, SCREEN_W_px)
    end

    local clearW = print(MENU_CLEAR_CLEAR_BTN_TEXT, SCREEN_W_px)
    local cancelW = print(MENU_CLEAR_CANCEL_BTN_TEXT, SCREEN_W_px)
    local confirmW = print(MENU_CLEAR_CONFIRM_BTN_TEXT, SCREEN_W_px)

    local nButtons = Node.new(
        nil, 'nd buttons',
        SCREEN_W_px / 2,
        MENU_CLEAR_CLEAR_BTN_OFFY,
        0, 0
    )

    local nClear = Node.new(
        nButtons, 'nd clear',
        -clearW / 2,
        0,
        clearW, TEXT_BUTTON_H_PX
    )

    local nCancel = Node.new(
        nButtons, 'nd cancel',
        -cancelW / 2,
        TEXT_BUTTON_H_PX + BTN_VERT_PADDING_PX,
        cancelW, TEXT_BUTTON_H_PX
    )

    local nConfirm = Node.new(
        nButtons, 'nd confirm',
        -confirmW / 2,
        MENU_CLEAR_CONFIRM_GAPY,
        confirmW, TEXT_BUTTON_H_PX
    )

    local btnClear = TextButton.new(
        nClear,
        MENU_CLEAR_CLEAR_BTN_NAME,
        MENU_CLEAR_CLEAR_BTN_TEXT,
        MENU_CLEAR_CLEAR_BTN_HINT,
        PALETTE.WHITE
    )

    local btnCancel = TextButton.new(
        nCancel,
        MENU_CLEAR_CANCEL_BTN_NAME,
        MENU_CLEAR_CANCEL_BTN_TEXT,
        MENU_CLEAR_CANCEL_BTN_HINT,
        PALETTE.WHITE
    )

    local btnConfirm = TextButton.new(
        nConfirm,
        MENU_CLEAR_CONFIRM_BTN_NAME,
        MENU_CLEAR_CONFIRM_BTN_TEXT,
        MENU_CLEAR_CONFIRM_BTN_HINT,
        PALETTE.DK_GRAY
    )

    local buttons = {
        btnClear,
        btnCancel,
        btnConfirm
    }

    local state = SubMenu.new() --[[@as Sub_ClearScores]]

    state.confirmed = false
    state.lines = lines
    state.widths = widths
    state.buttons = buttons
    state.btnClear = btnClear
    state.btnConfirm = btnConfirm


    return setmetatable(state, {__index = Sub_ClearScores})
end

function Sub_ClearScores:draw()
    for i, line in ipairs(self.lines) do
        local offX = (SCREEN_W_px - self.widths[i]) / 2
        print(line, offX, MENU_CLEAR_TEXT_OFFS[i], PALETTE.WHITE)
    end

    for _, button in ipairs(self.buttons) do
        button:draw()
    end
end

function Sub_ClearScores:tick(mouse)
    local clicked = self:updateButtonsAndDetectClick(mouse)

    if clicked then
        if clicked.name == MENU_CLEAR_CLEAR_BTN_NAME then
            self.confirmed = true
            self.btnClear.textColor = PALETTE.RED
            self.btnConfirm.textColor = PALETTE.WHITE
        elseif clicked.name == MENU_CLEAR_CANCEL_BTN_NAME then
            self.confirmed = false
            return Sub_Highscores.new()
        elseif clicked.name == MENU_CLEAR_CONFIRM_BTN_NAME then
            sfx(SFX.clearData, 'C-5', 85, SFX_CHANNEL, SfxVol)
            ClearData()
            return Sub_Highscores.new()
        end
    end
end

---@class StMainMenu : IAppState
---@field subTitle Sub_Title
---@field curSub SubMenu
---@field fadeInTicks integer
StMainMenu = {}

MENU_FADE_TICKS = .5 * 60
MENU_FADE_CHUNKS = 6
MENU_FADE_CHUNK_BRIGHTNESS_AMNT = 1 / MENU_FADE_CHUNKS
MENU_FADE_TICKS_PER_CHUNK = MENU_FADE_TICKS / MENU_FADE_CHUNKS

MENU_HINT_BTM_OFFY = -8

---@return StMainMenu
function StMainMenu.new()
    local subTitle = Sub_Title.new()

    local state = {
        subTitle = subTitle,
        curSub = subTitle,
        nSyncDelayTicks = 2,
        fadeInTicks = 0,
    }

    return setmetatable(state, {__index = StMainMenu})
end

function StMainMenu:enter()
    sync(16, 0)
    if MusicEnabled then music(1) end
end

function StMainMenu:delayTick()
    if self.nSyncDelayTicks == 1 then
        sync(1, 1) -- switch tiles to bank 1
    end
end

function StMainMenu:leave()
    -- if the user is super fast, they could otherwise get into a game before
    -- the palette has finished cycling. this forces it to finish.
    FadeInBy(DefaultPalette, 1)
    music()
end

---@param mouse MouseState
function StMainMenu:tick(mouse)
    local cheat = CheatKeyPressed()
    if cheat == 'unlock_stages' then
        sfx(SFX.levelUp, 'C-5', 120, SFX_CHANNEL, SfxVol)
        local reached = pmem(MAX_LVL_REACHED_PMEM_ADDR)
        if reached < MAX_LEVEL + 1 then
            pmem(MAX_LVL_REACHED_PMEM_ADDR, MAX_LEVEL + 1)
        end
    end

    if self.fadeInTicks < MENU_FADE_TICKS then
        self.fadeInTicks = self.fadeInTicks + 1
        local brightLevel =
            math.floor(self.fadeInTicks / MENU_FADE_TICKS_PER_CHUNK) *
            MENU_FADE_CHUNK_BRIGHTNESS_AMNT
        FadeInBy(DefaultPalette, brightLevel)
    elseif self.fadeInTicks == MENU_FADE_CHUNKS then
        self.fadeInTicks = self.fadeInTicks + 1
    else
        CycleCyan()
    end

    local tx = self.curSub:tick(mouse)

    if type(tx) == "number" then
        return StInGame.new(tx)
    elseif type(tx) == "string" then
        if tx == "ending" then
            return StEnding.new()
        end
    elseif tx then
        self.curSub = tx
    end
end

function StMainMenu:draw()
    self.curSub:draw()

    local hover = self.curSub.hoverButton
    if hover then
        local w = print(hover.hint, SCREEN_W_px, SCREEN_H_px)

        print(
            hover.hint,
            (SCREEN_W_px - w) / 2 ,
            SCREEN_H_px + MENU_HINT_BTM_OFFY,
            PALETTE.WHITE
        )
    end
end


--------------------------- in game constants ----------------------------------
FIELD_TILES_W = 8
FIELD_TILES_H = 8

---the number of y offset pixels for each column
FIELD_TILES_Y_OFF_px = {8, 0, 8, 0, 8, 0, 8, 0}
FIELD_TILES_PER_COL = {7, 8, 7, 8, 7, 8, 7, 8}
FIELD_COL_HEIGHTS = {
    FIELD_TILES_PER_COL[1] * LETTER_TILE_H_px,
    FIELD_TILES_PER_COL[2] * LETTER_TILE_H_px,
    FIELD_TILES_PER_COL[3] * LETTER_TILE_H_px,
    FIELD_TILES_PER_COL[4] * LETTER_TILE_H_px,
    FIELD_TILES_PER_COL[5] * LETTER_TILE_H_px,
    FIELD_TILES_PER_COL[6] * LETTER_TILE_H_px,
    FIELD_TILES_PER_COL[7] * LETTER_TILE_H_px,
    FIELD_TILES_PER_COL[8] * LETTER_TILE_H_px,
}
assert(#FIELD_TILES_Y_OFF_px == FIELD_TILES_W)

FIELD_W_px = LETTER_TILE_W_px * FIELD_TILES_W
FIELD_H_px = LETTER_TILE_H_px * (FIELD_TILES_H + 1) --+ 1 for column offsets
FIELD_RIGHT_BUFFER_px = 0
FIELD_TOP_OFF_px = 4

WISPELL_OFF_X_px = 0
WISPELL_OFF_Y_px = 0

LETTER_FALL_SPEED_ROWS_PER_TICK = 0.2

CONNECTING_ARROW_N_SPRITE = 365
CONNECTING_ARROW_NW_SPRITE = 366
CONNECTING_ARROW_NE_SPRITE = 367
CONNECTING_ARROW_S_SPRITE = 381
CONNECTING_ARROW_SE_SPRITE = 382
CONNECTING_ARROW_SW_SPRITE = 383

CONNECTING_ARROW_N_OFF_X = 4
CONNECTING_ARROW_N_OFF_Y = -3
CONNECTING_ARROW_NW_OFF_X = -2
CONNECTING_ARROW_NW_OFF_Y = -1
CONNECTING_ARROW_NE_OFF_X = LETTER_TILE_W_px - 3
CONNECTING_ARROW_NE_OFF_Y = CONNECTING_ARROW_NW_OFF_Y
CONNECTING_ARROW_S_OFF_X = CONNECTING_ARROW_N_OFF_X
CONNECTING_ARROW_S_OFF_Y = -2 + LETTER_TILE_H_px
CONNECTING_ARROW_SE_OFF_X = CONNECTING_ARROW_NE_OFF_X - 1
CONNECTING_ARROW_SE_OFF_Y = -5 + LETTER_TILE_H_px
CONNECTING_ARROW_SW_OFF_X = CONNECTING_ARROW_NW_OFF_X
CONNECTING_ARROW_SW_OFF_Y = CONNECTING_ARROW_SE_OFF_Y
-- todo, tune SW

---@alias ConnectingArrowDir 'n'|'ne'|'nw'|'se'|'s'|'sw'

---@type table<ConnectingArrowDir, integer>
DIR_TO_SPRITE = {
    n = CONNECTING_ARROW_N_SPRITE,
    ne = CONNECTING_ARROW_NE_SPRITE,
    nw = CONNECTING_ARROW_NW_SPRITE,
    se = CONNECTING_ARROW_SE_SPRITE,
    s = CONNECTING_ARROW_S_SPRITE,
    sw = CONNECTING_ARROW_SW_SPRITE,
}

DIR_TO_OFFX = {
    n = CONNECTING_ARROW_N_OFF_X,
    ne = CONNECTING_ARROW_NE_OFF_X,
    nw = CONNECTING_ARROW_NW_OFF_X,
    se = CONNECTING_ARROW_SE_OFF_X,
    s = CONNECTING_ARROW_S_OFF_X,
    sw = CONNECTING_ARROW_SW_OFF_X,
}

DIR_TO_OFFY = {
    n = CONNECTING_ARROW_N_OFF_Y,
    ne = CONNECTING_ARROW_NE_OFF_Y,
    nw = CONNECTING_ARROW_NW_OFF_Y,
    se = CONNECTING_ARROW_SE_OFF_Y,
    s = CONNECTING_ARROW_S_OFF_Y,
    sw = CONNECTING_ARROW_SW_OFF_Y,
}

---@alias ConnectingArrowInfo {cr: Cr, dir: ConnectingArrowDir} 

---@type integer
SHORT_COLUMN_LEN = 7

---compute the direction connecting two tiles, from a to b
---@param a Cr # source Cr
---@param b Cr # dest Cr
---@return ConnectingArrowDir
function DirectionBetween(a, b)
    -- convert and copy integers to numbers
    local arow, brow = a.row * 1.0, b.row * 1.0 

    -- for shortcolumns, offset the rows by 0.5 to normalize for their
    -- actual offsets on screen
    if FIELD_TILES_PER_COL[a.col] == SHORT_COLUMN_LEN then
        arow = arow + .5
    end

    if FIELD_TILES_PER_COL[b.col] == SHORT_COLUMN_LEN then
        brow = brow + .5
    end

    return
        (a.col == b.col) and (arow < brow and 'n' or 's') or
        (a.col < b.col) and (arow < brow and 'ne' or 'se') or
        (arow < brow) and 'nw' or 'sw'
end

assert(DirectionBetween({col = 1, row = 1}, {col = 2, row = 1}) == 'se')
assert(DirectionBetween({col = 2, row = 1}, {col = 1, row = 1}) == 'nw')
assert(DirectionBetween({col = 1, row = 2}, {col = 2, row = 3}) == 'ne')
assert(DirectionBetween({col = 2, row = 3}, {col = 1, row = 2}) == 'sw')
assert(DirectionBetween({col = 1, row = 1}, {col = 1, row = 2}) == 'n')
assert(DirectionBetween({col = 1, row = 2}, {col = 1, row = 1}) == 's')


---a tile in the grid, stores the letter and also the (possibly fractional) column
---for when the tile is smoothly falling down.
---@alias TileElem 'normal' | 'frozen' | 'firey' | 'charged'
---@class GridTile
---@field letter string
---@field rowOff number
---@field elem TileElem
GridTile = {}

---@param letter string
---@param rowOff number
---@param elem TileElem
function GridTile.new(letter, rowOff, elem)
    assert(#letter == 1, "tried to make a tile with more than 1 letter: " .. ToStr(letter))
    return {letter = letter, rowOff = rowOff, elem = elem}
end

---responsible for storing the letter tiles, getting the tile under a point,
---and drawing the letters
---@class LetterGrid
---@field node Node
---@field cols GridTile[][]
---@field nVowels integer
---@field nTiles integer
---@field bestWord BestWordInfo|nil
---@field allBestWords table<integer, table<integer, BestWordInfo|nil>>
LetterGrid = {}
LetterGrid.__index = LetterGrid

---create a new letter grid, whose top left is at the given node
---@param node Node
---@return LetterGrid
function LetterGrid.new(node)
    local grid = {}
    for i = 1, FIELD_TILES_W do
        table.insert(grid, {})
    end

    local val = {
        cols = grid,
        node = node,
        nVowels = 0,
        nTiles = 0,
        bestWord = nil,
        allBestWords = {}
    }

    return setmetatable(val, LetterGrid)
end

---add a tile to the top of the given column
---@param letter string # letter of tile. chars after first are ignored.
---@param col integer
---@param element TileElem
function LetterGrid:addTileToCol(letter, col, element)
    assert(col > 0 and col <= FIELD_TILES_W, "column out of bounds")
    --letter = letter:sub(1, 1)
    local column = self.cols[col]
    local row = #column + 1

    table.insert(column, GridTile.new(letter, row, element))
end

---@param letter string
---@param elem TileElem
---@param px number
---@param py number
---@param mode 'highlighted' | 'selected' | nil
---@param scale number | nil
function RenderLetter(letter, elem, px, py, mode, scale)
    local sprite = LETTER_SPRITES[letter]
    scale = scale or 1

    spr(TILE_ELEMENTS[elem], px, py, nil, scale, 0, 0, 2, 2)
    if mode =='highlighted' then
        spr(TILE_HILITE, px, py, nil, scale, 0, 0, 2, 2)
    elseif mode == 'selected' then
        spr(TILE_SELECTED, px, py, nil, scale, 0, 0, 2, 2)
    end

    spr(sprite, px, py, LETTER_CHROMAKEY, scale, 0, 0, 2, 2)
end

---draw a given letter to a given place
---@param col integer
---@param row integer
---@param px number
---@param py number
---@param mode 'highlighted' | 'selected' | nil
function LetterGrid:drawLetter(col, row, px, py, mode)
    assert(col > 0 and col <= FIELD_TILES_W, "column out of bounds")
    local tile = self.cols[col][row]
    if not tile then return end
    local letter = tile.letter
    local offy = (tile.rowOff or 0) * LETTER_TILE_H_px
    py = py - offy

    local elem = tile.elem
    RenderLetter(letter, elem, px, py, mode, 1)
end

---draw an entire column
---@param col integer
---@param tlPx number # the top left x coordinate to draw the column at
---@param tlPy number
---@param highlightRow integer | nil
---@param strand Strand
function LetterGrid:drawColumn(col, colHeight, tlPx, tlPy, highlightRow, strand)
    assert(col > 0 and col <= FIELD_TILES_W, "column out of bounds")
    local y = tlPy + colHeight - LETTER_TILE_H_px
    for i = 1, FIELD_COL_HEIGHTS[col] do
        local tileHighlighted = i == highlightRow
        local mode = nil
        if strand:tileSelected(col, i) then
            mode = 'selected'
        elseif tileHighlighted then
            mode = 'highlighted'
        end

        self:drawLetter(col, i, tlPx, y, mode)
        y = y - LETTER_TILE_H_px
    end
end


---Return the column and row the point is over
---@param mouseOffx number
---@param mouseOffy number
---@return Cr | nil # highlight {col, row} or nil
function LetterGrid:pointOverTile(mouseOffx, mouseOffy)
    if  mouseOffx < 0 or mouseOffx > FIELD_W_px or
        mouseOffy < 0 or mouseOffy > FIELD_H_px
    then
        return nil
    end

    local col = math.floor(mouseOffx / LETTER_TILE_W_px) + 1
    if col < 1 or col > FIELD_TILES_W then return nil end

    mouseOffy = mouseOffy - FIELD_TILES_Y_OFF_px[col]

    if mouseOffy < 0 then return nil end

    local row = 1 + math.floor(
        FIELD_TILES_PER_COL[col] - mouseOffy / LETTER_TILE_H_px)

    if row > FIELD_TILES_PER_COL[col] then return nil end

    return {col = col, row = row}
end

---@param crs Cr[]
function LetterGrid:drawBetweenArrows(crs)
    for i=2, #crs do
        local prev = crs[i - 1]
        local cur = crs[i]
        local dir = DirectionBetween(prev, cur)
        local spriteId = DIR_TO_SPRITE[dir]
        local rowOff =
            FIELD_TILES_PER_COL[prev.col] == SHORT_COLUMN_LEN
            and -0.5 or 0
        local row = prev.row + rowOff
        local offPy =
            FIELD_COL_HEIGHTS[prev.col] - row * LETTER_TILE_H_px +
            DIR_TO_OFFY[dir]
        local offPx = (prev.col - 1) * LETTER_TILE_W_px + DIR_TO_OFFX[dir]
        local baseX, baseY = self.node:pos()
        local x = baseX + offPx
        local y = baseY + offPy
        spr(spriteId, x, y, 12)

    end
end

OVR_TRANS_ADDR = 0x3FF8

---@param highlight Cr | nil # tile to highlight for mouseover
---@param strand Strand
function LetterGrid:draw(highlight, strand)
    vbank(1)
    -- update palette in vbank 1

    for _, palIndex in ipairs(CYCLE_COLORS) do
        local lo = CYCLE_LOW_COLOR[palIndex]
        local hi = CYCLE_HIGH_COLOR[palIndex]
        local cur = CycleCurColor(lo, hi, ColorCyclePhase)

        local indAddr = PALETTE_ADDR + 3 * palIndex

        -- poke r, then g, then b
        poke(indAddr, cur.r)
        poke(indAddr + 1, cur.g)
        poke(indAddr + 2, cur.b)
    end


    local x, y = self.node:pos()
    for col=1, FIELD_TILES_W do
        local colHeight = FIELD_COL_HEIGHTS[col]

        local highlightRow = nil

        -- if there is a highlight and its this column
        if highlight and highlight.col == col then
            highlightRow = highlight.row
        end

        self:drawColumn(col, colHeight,
            x + (col - 1 ) * LETTER_TILE_H_px,
            y + FIELD_TILES_Y_OFF_px[col],
            highlightRow, strand
        )
    end

    self:drawBetweenArrows(strand.tiles)
    
    vbank(0)
end

---whether the given col and row refer to an actual tile
---@param col integer
---@param row integer
---@return boolean
function LetterGrid:inBounds(col, row)
    return
        col >= 1 and col <= FIELD_TILES_W and
        row >= 1 and row <= FIELD_TILES_PER_COL[col]
end

---return the list of neighboring tiles
---@param col integer
---@param row integer
---@return Cr[]
function LetterGrid:neighbors(col, row)
    local colHeight = FIELD_TILES_PER_COL[col]
    assert(colHeight == 7 or colHeight == 8, "this code assumes different col heights")

    local neigh = {}
    local push = table.insert

    -- all tiles, regardless of column, neighbor their above and below tiles
    if self:inBounds(col, row - 1) then push(neigh, Cr(col, row - 1)) end
    if self:inBounds(col, row + 1) then push(neigh, Cr(col, row + 1)) end

    local potential = {}

    -- a short column borders its own row in the next long column as well
    -- as the next row up
    if colHeight == 7 then
        potential = {
            Cr(col + 1, row),
            Cr(col + 1, row + 1),
            Cr(col - 1, row),
            Cr(col - 1, row + 1)
        }

    else
    -- a tall column borders its own row and the previous row in adjacent
    -- short columns
        potential = {
            Cr(col + 1, row - 1),
            Cr(col + 1, row),
            Cr(col - 1, row - 1),
            Cr(col - 1, row)
        }
    end

    for _, pneigh in ipairs(potential) do
        if self:inBounds(pneigh.col, pneigh.row) then
            push(neigh, pneigh)
        end
    end

    return neigh
end


---determine the highest scoring word that could be generated at the col row.
---returns the string, its elements, the list of Crs, and the score
--- @alias BestWordInfo {
---     word: string,
---     elems: TileElem[],
---     crs: Cr[],
---     score: integer,
--- }
---@param col integer
---@param row integer
---@return BestWordInfo|nil
function LetterGrid:bestWordStartingAt(col, row)
    if not DawgLoaded then
        return {
            word = 'test', 
            {'normal', 'normal', 'normal', 'normal'},
            crs = {{col = 1, row = 1}, {col = 2, row = 1}, {col = 3, row = 1}, {col = 4, row = 1}},
            score = 100
        }
    end

    local tile = self.cols[col][row]

    if not tile then return nil end

    local start = wordDfa:matchPrefix(tile.letter, 1)
    if not start then return nil end

    ---@alias SearchState [DfaState, string, TileElem[], Cr[], Cr]

    ---@type SearchState
    local startState = {
        start,          -- the DfaNode we're on
        tile.letter,    -- letters explored.
        {tile.elem},    -- list of elements. used to compute the score.
        {},             -- list of tiles. used by the caller.
        Cr(col, row),   -- next tile to search
    }

    local bestScore = 0
    ---@type SearchState | nil
    local bestState = nil

    ---@type SearchState[]
    local frontier = {startState}
    while #frontier > 0 do
        ---@type SearchState
        local toSearch = table.remove(frontier)
        local node, wordSoFar, elems, crs, searchCr =
            table.unpack(toSearch)

        -- check if tile has already been visited
        -- for _, cr in ipairs(crs) do
        --    if cr.row == searchCr.row and cr.col == searchCr.col then
        --        goto continue
        --    end
        -- end

        if node.final then
            local currentScore = WordScore(wordSoFar, elems)

            if currentScore > bestScore then
                bestState = toSearch
                bestScore = currentScore
            end
        end


        -- only add search letters if the resulting word will be small enough.
        if #crs >= MAX_WORD_LEN - 1 then
            goto continue
        end

        for _, neigh in ipairs(self:neighbors(searchCr.col, searchCr.row)) do
            for _, cr in ipairs(crs) do
                if neigh.col == cr.col and neigh.row == cr.row then
                    goto ignore_neighbor
                end
            end

            local neighTile = self.cols[neigh.col][neigh.row]

            if not neighTile then goto ignore_neighbor end

            local neighDfaNodeId = node.tx[neighTile.letter]

            if not neighDfaNodeId then goto ignore_neighbor end

            local neighDfaNode = wordDfa.states[neighDfaNodeId]
            local neighElems = {}
            local neighCrs = {}
            for i = 1, #elems do
                neighElems[i] = elems[i]
                neighCrs[i] = crs[i]
            end
            table.insert(neighElems, neighTile.elem)
            table.insert(neighCrs, searchCr)

            ---@type SearchState
            local neighState = {
                neighDfaNode,
                wordSoFar .. neighTile.letter,
                neighElems,
                neighCrs,
                neigh
            }

            table.insert(frontier, neighState)

            ::ignore_neighbor::
        end

        ::continue::
    end

    if not bestState then return nil end

    local _, word, elems, crs, lastCr = table.unpack(bestState)
    table.insert(crs, lastCr)

    return {
        word = word,
        elems = elems,
        crs = crs,
        score = WordScore(word, elems)
    }
end


---determine all the words that could be generated starting at col row
---@param col integer
---@param row integer
---@param words table<string, string>
function LetterGrid:allWordsAt(col, row, words)
    local letter = self.cols[col][row].letter
    ---@type table<string, boolean>
    local visited = {}

    local start = wordDfa:matchPrefix(letter, 1)
    if not start then return end

    ---@type [DfaState, string, integer, integer][]
    local frontier = {{start, letter, col, row}}
    ---@type string[]

    while #frontier > 0 do
        ---@type [DfaState, string, integer, integer]
        local next = table.remove(frontier)
        local node, wordSoFar, c, r = table.unpack(next)

        if visited[wordSoFar] then goto continue end
        visited[wordSoFar] = true

        if node.final then
            table.insert(words, wordSoFar)
        end

        if #wordSoFar == MAX_WORD_LEN then 
            goto continue
        end

        for _, neigh in ipairs(self:neighbors(c, r)) do
            local ntile = self.cols[neigh.col][neigh.row]
            local nletter = ntile.letter
            local nnodeId = node.tx[nletter]
            if not nnodeId then goto next_neighbor end
            
            local nnode = wordDfa.states[nnodeId]
            local newWord = wordSoFar .. nletter
            if visited[newWord] then goto next_neighbor end

            table.insert(frontier, {nnode, newWord, neigh.col, neigh.row})

            ::next_neighbor::
        end

        ::continue::
    end
end

---return an array of all the charged tiles in the grid
---@return Cr[]
function LetterGrid:chargedTiles()
    local result = {}
    for col=1, FIELD_TILES_W do
        for row=1, FIELD_TILES_PER_COL[col] do
            local tile = self.cols[col][row]
            if not tile then goto continue end
            if tile.elem == 'charged' then
                table.insert(result, Cr(col, row))
            end
            ::continue::
        end
    end

    return result
end

---return the Cr of a random charged tile or nil if there aren't any
---@return Cr|nil
function LetterGrid:selectRandomChargedTile()
    local charged = self:chargedTiles()
    if #charged == 0 then return nil end
    local i = math.random(#charged)
    return charged[i]
end

---@return GridTile | nil, Cr
function LetterGrid:selectRandomTile()
    local col = math.random(1, FIELD_TILES_W)
    local row = math.random(1, FIELD_TILES_PER_COL[col])
    local tile = self.cols[col][row]
    return tile, Cr(col, row)
end

---turn the given array of tiles frozen
---@param crs Cr[]
---@return nil
function LetterGrid:freeze(crs)
    for _, cr in ipairs(crs) do
        self.cols[cr.col][cr.row].elem = 'frozen'
    end
end


---the amount of extra displacement to give to a tile based on how many it is 
---being spawned over. used to stagger the falling speed.
SPAWN_EXTRA_ROW_DISP_PER_HEIGHT_TILES = 1

---maximum amount of a random row offset to spawning tiles 
SPAWN_RANDOM_ROW_OFFSET_MAG = 0.5

---@return nil
function LetterGrid:updateBestWords()
    self.allBestWords = self:bestWordsFromEachTile()
    self.bestWord = BestWordAvail(self.allBestWords)
end

---@alias SpawnTilesResult nil|'respawned'
---@return SpawnTilesResult
function LetterGrid:spawnTiles()
    local result = nil

    while true do
        for col=1, FIELD_TILES_W do
            local height = FIELD_TILES_PER_COL[col]
            local tilesBelow = 0
            for row=1, height do
                if not self.cols[col][row] then
                    local letter, elem = DrawLetter(self.nVowels / (self.nTiles or 1))
                    if VOWEL[letter] then self.nVowels = self.nVowels + 1 end
                    self.nTiles = self.nTiles + 1
                    local rowOff = FIELD_TILES_H +
                        SPAWN_EXTRA_ROW_DISP_PER_HEIGHT_TILES * tilesBelow +
                        math.random() * SPAWN_RANDOM_ROW_OFFSET_MAG
                    self.cols[col][row] = GridTile.new(letter, rowOff, elem)
                    tilesBelow = tilesBelow + 1
                end
            end
        end

        self:updateBestWords()

        if self.bestWord then
            break
        end

        self:clearAllTiles()
        result = 'respawned'
    end

    return result
end

function LetterGrid:clearAllTiles()
    for col=1, FIELD_TILES_W do
        for row=1, FIELD_TILES_PER_COL[col] do
            self.cols[col][row] = nil
        end
    end
end

---replace a tile with nil and update statistics 
---@param col integer
---@param row integer
function LetterGrid:deleteTile(col, row)
    local tile = self.cols[col][row]
    if not tile then return end
    if VOWEL[tile.letter] then self.nVowels = self.nVowels - 1 end
    self.nTiles = self.nTiles - 1
    self.cols[col][row] = nil
end



---A list of selected tiles
---@class Strand
---@field tiles Cr[]
---@field selected table<integer, table<integer, integer>> selected tiles mapped to index
Strand = {}
Strand.__index = Strand

function Strand.new() 
    local selected = {}
    for i = 1, FIELD_TILES_W do
        table.insert(selected, {})
    end

    local strand = {
        tiles = {},
        selected = selected
    }

    return setmetatable(strand, Strand)
end


---unselect tiles until reaching col row
---@param col integer
---@param row integer
function Strand:trimTo(col, row)
    assert(self:tileSelected(col, row))
    
    while #self.tiles > 0 do
        local last = self.tiles[#self.tiles]
        if last.col == col and last.row == row then break end
        self.selected[last.col][last.row] = nil
        table.remove(self.tiles)
    end
end

---add a tile to the strand
---@param col integer
---@param row integer
function Strand:add(col, row)
    table.insert(self.tiles, Cr(col, row))
    self.selected[col][row] = #self.tiles
end

---@return integer
function Strand:length()
    return #self.tiles
end

---determine whether a tile has been selected
---@param col integer
---@param row integer
---@return boolean
function Strand:tileSelected(col, row)
    return not not self.selected[col][row]
end


function Strand:clear()
    for _, tile in ipairs(self.tiles) do
        self.selected[tile.col][tile.row] = nil
    end
    self.tiles = {}
end

---return a string containing the letters that make up the strand and the 
---elements of each letter
---@param grid LetterGrid
---@return string, string[]
function Strand:asStringAndElements(grid)
    local chars = {}
    local elems = {}
    for _, cr in ipairs(self.tiles) do
        local tile = grid.cols[cr.col][cr.row]
        assert (tile.letter, 'invalid letter stored in strand')
        table.insert(chars, tile.letter)
        table.insert(elems, tile.elem)
    end

    return table.concat(chars, ''), elems
end

---@return Cr | nil
function Strand:lastTile()
    return self.tiles[#self.tiles]
end

---compute what the score needs to be for the level
---@param lvl integer
function ScoreToReachLevel(lvl)
    assert(lvl > 0)

    return lvl * 500
end


WISPELL_PROFILE_TILES_W = 8
WISPELL_PROFILE_TILES_H = 8
WISPELL_EXPRESSION_TILES_W = 4
WISPELL_EXPRESSION_TILES_H = 4
WISPELL_EXPRESSION_OFF_X = 16
WISPELL_EXPRESSION_OFF_Y = 16
WISPELL_BOOK_W = 4
WISPELL_BOOK_H = 4
WISPELL_BOOK_OFF_X = 24
WISPELL_BOOK_OFF_Y = 10
WISPELL_RHAND_OFF_X = -5 -- relative to book
WISPELL_RHAND_OFF_Y = 18
WISPELL_RHAND_W = 2
WISPELL_RHAND_H = 2
WISPELL_LHAND_OFF_X = 27 -- relative to book
WISPELL_LHAND_OFF_Y = 6
WISPELL_LHAND_W = 1
WISPELL_LHAND_H = 2
WEXP_OX = WISPELL_EXPRESSION_OFF_X
WEXP_OY = WISPELL_EXPRESSION_OFF_Y
WEXP_W = WISPELL_EXPRESSION_TILES_W
WEXP_H = WISPELL_EXPRESSION_TILES_H
WISPELL_SPR_BOOK = 200
---how long until wispell pulls out his book
WISPELL_BORED_TIME = 10 * 60 -- debug: make longer in future
---how long does the book take to reach its final position
WISPELL_BOOK_DEPLOY_TIME = 2 * 60
---how long does a fully deployed book take to be removed from screen
WISPELL_BOOK_DISMISS_TIME = 0.5 * 60
---distance down from wispell's node to book when finished deploying 
WISPELL_BOOK_DEPLOY_OFF = 30
---distance down screen to book when fully away
WISPELL_BOOK_AWAY_OFF =
    WISPELL_PROFILE_TILES_H * TILE_H_px - WISPELL_OFF_Y_px

WISPELL_SALUTE_OFF_FINAL_X = 16
WISPELL_SALUTE_OFF_FINAL_Y = 22
WISPELL_SALUTE_OFF_INITIAL_X = 16
WISPELL_SALUTE_OFF_INITIAL_Y = 64
WISPELL_SALUTE_OFF_CUFF_X = -4
WISPELL_SALUTE_OFF_CUFF_Y = 10
WISPELL_SALUTE_W = 2
WISPELL_SALUTE_H = 2
WISPELL_SALUTE_CUFF_W = 1
WISPELL_SALUTE_CUFF_H = 1

---how long does it take to bring hand into salute
WISPELL_SALUTE_TIME = 0.5 * 60

---how long does it take to put hand back
WISPELL_SALUTE_DISMISS_TIME = 2 * 60

WISPELL_BOOK_MOVE_PER_TICK_BORING =
    WISPELL_BOOK_DEPLOY_OFF / WISPELL_BOOK_DEPLOY_TIME
WISPELL_BOOK_MOVE_PER_TICK_UNBORING =
    WISPELL_BOOK_AWAY_OFF / WISPELL_BOOK_DISMISS_TIME

---An image attached to Wispell's image
---@class WispellImage
---@field spriteNo integer
---@field offX number # Where to draw this relative to parent
---@field offY number # Where to draw this relative to parent
---@field tileW integer # number of tiles wide
---@field tileH integer # number of tiles high
---@field colorKey integer
WispellImage = {}

---@param spriteNo integer
---@param offX number
---@param offY number
---@param tileW integer
---@param tileH integer
---@param colorKey integer|nil
---@returns WispellImage
function WispellImage.new(spriteNo, offX, offY, tileW, tileH, colorKey)
    return {
        spriteNo = spriteNo,
        offX = offX,
        offY = offY,
        tileW = tileW,
        tileH = tileH,
        colorKey = colorKey or 0
    }
end

---@alias AnimName 'idle'|'blink'|'huh'|'argh'|'okay'|'great'|'bored'|'half_blink'

---@alias WispellFrameDesc {
--- image: WispellImage,
--- howLong: number|nil, -- # in ticks, nil means forever
---}
---
---@alias WispellAnim {
--- name: AnimName,
--- frames: WispellFrameDesc[],
---}

---@alias WispellBoredomStateId 'interested'|'boring'|'bored'|'unboring'
---@class WispellBoredomState
---@field state WispellBoredomStateId
---@field ticks integer

---@class Wispell
---@field profile WispellImage
---@field expressionAnimState WispellAnimState
---@field node Node
---@field boredomState WispellBoredomState
---@field saluteAmount integer
---@field saluteDir integer|nil
Wispell = {
    boredomState = {
        state = 'interested',
        ticks = 0,
    },
    profiles = {
        neutral = WispellImage.new(
            128, 0, 0,
            WISPELL_PROFILE_TILES_W,
            WISPELL_PROFILE_TILES_H),
    },
    expressions = {
        neutral = WispellImage.new(68, WEXP_OX, WEXP_OY, WEXP_W, WEXP_H),
        blink1 = WispellImage.new(8, WEXP_OX, WEXP_OY, WEXP_W, WEXP_H),
        blink2 = WispellImage.new(12, WEXP_OX, WEXP_OY, WEXP_W, WEXP_H),
        huh = WispellImage.new(4, WEXP_OX, WEXP_OY, WEXP_W, WEXP_H),
        huh2 = WispellImage.new(76, WEXP_OX, WEXP_OY, WEXP_W, WEXP_H),
        wow = WispellImage.new(72, WEXP_OX, WEXP_OY, WEXP_W, WEXP_H),
    },
    accessories = {
        book = WispellImage.new(
            200,
            WISPELL_BOOK_OFF_X,
            WISPELL_BOOK_AWAY_OFF,
            WISPELL_BOOK_W,
            WISPELL_BOOK_H),
    },
    parts = {
        lhand = WispellImage.new(
            140,
            WISPELL_LHAND_OFF_X,
            WISPELL_LHAND_OFF_Y,
            WISPELL_LHAND_W,
            WISPELL_LHAND_H),
        rhand = WispellImage.new(
            137,
            WISPELL_RHAND_OFF_X,
            WISPELL_RHAND_OFF_Y,
            WISPELL_RHAND_W,
            WISPELL_RHAND_H
        ),
        salute = WispellImage.new(
            142,
            WISPELL_SALUTE_OFF_FINAL_X,
            WISPELL_SALUTE_OFF_FINAL_Y,
            WISPELL_SALUTE_W,
            WISPELL_SALUTE_H,
            PALETTE.SKY
        ),
        saluteCuff = WispellImage.new(
            174,
            WISPELL_SALUTE_OFF_CUFF_X,
            WISPELL_SALUTE_OFF_CUFF_Y,
            WISPELL_SALUTE_CUFF_W,
            WISPELL_SALUTE_CUFF_H,
            PALETTE.SKY
        )
    },
}

---@type table<string, WispellAnim>
WispellAnims = {
    idle = {
        name = 'idle',
        frames = {
            {image = Wispell.expressions.neutral, howLong=nil}
        }
    },
    blink = {
        name = 'blink',
        frames = {
            {image = Wispell.expressions.blink1, howLong=5},
            {image = Wispell.expressions.blink2, howLong=10},
            {image = Wispell.expressions.blink1, howLong=5},
        }
    },
    half_blink = {
        name = 'half_blink',
        frames = {
            {image = Wispell.expressions.blink2, howLong=30},
        }
    },
    huh = {
        name = 'huh',
        frames = {
            {image = Wispell.expressions.huh, howLong=60},
        }
    },
    argh = {
        name = 'argh',
        frames = {
            {image = Wispell.expressions.huh2, howLong=60}
        }
    },
    okay = {
        name = 'okay',
        frames = {
            {image = Wispell.expressions.blink1, howLong=60}
        }
    },
    great = {
        name = 'great',
        frames = {
            {image = Wispell.expressions.wow, howLong=60}
        }
    },
    bored = {
        name = 'bored',
        frames = {
            {image = Wispell.expressions.blink1, howLong=nil}
        }
    }
}

--- average number of ticks between blinks
WISPELL_BLINK_MTTH = 8 * 60


---@class WispellAnimState
---@field anim WispellAnim
---@field currentFrame integer
---@field currentTicksLeft integer|nil
WispellAnimState = {}

function WispellAnimState.new()
    local state = {
        anim = WispellAnims.idle,
        currentFrame = 1,
        currentTicksLeft = WispellAnims.idle.frames[1].howLong,
        saluteAmount = 0,
        saluteDir = nil
    }

    return setmetatable(state, {__index = WispellAnimState});
end

---@param anim WispellAnim
function WispellAnimState:switch(anim)
    self.anim = anim
    self.currentFrame = 1
    self.currentTicksLeft = anim.frames[1].howLong
end

---@return integer
function WispellAnimState:nFrames()
    return #self.anim.frames
end

---@return boolean
function WispellAnimState:finished()
    return type(self.currentTicksLeft) == 'nil' or
        self.currentFrame > self:nFrames()
end

function WispellAnimState:advance()
    if self:finished() then
        return
    end

    self.currentFrame = self.currentFrame + 1

    if self:finished() then
        self.currentTicksLeft = nil
        return
    end

    self.currentTicksLeft = self.anim.frames[self.currentFrame].howLong
end

---@return nil
function WispellAnimState:tick()
    if self:finished() then return end

    if self.currentTicksLeft <= 0 then
        -- in case we zero out frames for debugging purposes, 
        -- handle it correctly to skip ahead and not display a 0 length frame
        while not self:finished() and self.currentTicksLeft <= 0 do
            self:advance()
        end
    else
        self.currentTicksLeft = self.currentTicksLeft - 1
    end
end


---comment
---@param x number
---@param y number
function WispellAnimState:draw(x, y)
    local frame =
        self.anim.frames[self.currentFrame] or
        self.anim.frames[1]
    local image = frame.image

    spr(image.spriteNo, x + image.offX, y + image.offY,
        image.colorKey, 1, 0, 0, image.tileW, image.tileH)
end


---@param node Node
---@return Wispell
function Wispell.new(node)
    local wispell = {
        profile =  Wispell.profiles.neutral,
        -- expression = Wispell.expressions.neutral,
        expressionAnimState = WispellAnimState.new(),
        node = node,
    }

    setmetatable(wispell, {__index = Wispell})

    return wispell
end

function Wispell:draw()
    local x, y = self.node:pos()
    spr(self.profile.spriteNo,
        x + self.profile.offX,
        y + self.profile.offY, 0, 1, 0, 0,
        self.profile.tileW, self.profile.tileH)
    self.expressionAnimState:draw(x, y);
    local bkX, bkY = self.accessories.book.offX, self.accessories.book.offY
    spr(self.accessories.book.spriteNo,
        bkX, bkY, PALETTE.BLACK, 1, 0, 0,
        WISPELL_BOOK_W, WISPELL_BOOK_H)
    -- draw hands
    local lh, rh = self.parts.lhand, self.parts.rhand
    spr(rh.spriteNo, bkX + rh.offX, bkY + rh.offY,
        PALETTE.BLACK, 1, 0, 0, rh.tileW, rh.tileH)
    spr(lh.spriteNo, bkX + lh.offX, bkY + lh.offY,
        PALETTE.BLACK, 1, 0, 0, lh.tileW, lh.tileH)

    -- draw salute if he's doing that
    if self:saluting() then
        local s = self.parts.salute
        spr(s.spriteNo, s.offX, s.offY, s.colorKey, 1, 0, 0, s.tileW, s.tileH)
        local c = self.parts.saluteCuff
        spr(c.spriteNo, s.offX + c.offX, s.offY + c.offY,
            c.colorKey, 1, 0, 0, c.tileW, c.tileH)
    end

    rect(
        x, y + self.profile.tileH * TILE_H_px,
        self.profile.tileW * TILE_W_px,
        200, PALETTE.BLACK
    )
    -- cut off the book and hands. no stencil buffer...


end

function Wispell:presentArms()
    self.saluteAmount = 0
    self.saluteDir = 1
    self.boredomState.state = 'interested'
    self.boredomState.ticks = 0
end

function Wispell:orderArms()
    self.saluteDir = -1
end

---@return boolean
function Wispell:saluting()
    return self.saluteDir ~= nil
end

function Wispell:tick()
    if self.saluteDir == -1 then
        local maxSaluteOff = WISPELL_SALUTE_OFF_FINAL_Y
        local saluteDismissOff = WISPELL_SALUTE_OFF_INITIAL_Y
        local offYperTic = (saluteDismissOff - maxSaluteOff) /
            WISPELL_SALUTE_DISMISS_TIME
        self.saluteAmount = math.max(self.saluteAmount - 1, 0)
        self.parts.salute.offY = offYperTic * self.saluteAmount + maxSaluteOff

        if self.saluteAmount == 0 then
            self.saluteDir = nil
        end
    elseif self.saluteDir == 1 then
        local maxSaluteOff = WISPELL_SALUTE_OFF_FINAL_Y
        local saluteDismissOff = WISPELL_SALUTE_OFF_INITIAL_Y
        local offYperTic = (maxSaluteOff - saluteDismissOff) /
            WISPELL_SALUTE_TIME
        self.saluteAmount = math.min(WISPELL_SALUTE_TIME, self.saluteAmount + 1)
        self.parts.salute.offY = offYperTic * self.saluteAmount + saluteDismissOff
    end

    self.expressionAnimState:tick()

    -- roll to see if we blink
    if self.expressionAnimState.anim.name == 'idle' then
        local blink = math.random() < 1.0 / WISPELL_BLINK_MTTH
        if blink then
            self.expressionAnimState:switch(WispellAnims.blink)
        end
    end

    if self.boredomState.state == 'bored' then
        local blink = math.random() < 1.0 / WISPELL_BLINK_MTTH
        if blink then
            self.expressionAnimState:switch(WispellAnims.half_blink)
        end
    end

    if self.expressionAnimState.anim.name == 'half_blink' and
        self.expressionAnimState:finished() and
        (self.boredomState.state == 'boring' or
        self.boredomState.state == 'bored')
    then
        self.expressionAnimState:switch(WispellAnims.bored)
    end

    if  self.boredomState.state ~= 'boring' and
        self.boredomState.state ~= 'bored' and
        self.expressionAnimState:finished()
    then
        self.expressionAnimState:switch(WispellAnims.idle)
    end

    -- tick book
    if self.boredomState.state == 'boring' then
        self.accessories.book.offY =
            self.accessories.book.offY -
            WISPELL_BOOK_MOVE_PER_TICK_BORING
    elseif self.boredomState.state == 'unboring' then
        self.accessories.book.offY =
            self.accessories.book.offY +
            WISPELL_BOOK_MOVE_PER_TICK_UNBORING
    elseif self.boredomState.state == 'interested' then
        self.accessories.book.offy = WISPELL_BOOK_AWAY_OFF
    end

    if not self:saluting() then
        self:tickBoredom()
    end
end

---@param newState WispellBoredomStateId
function Wispell:changeBoredom(newState)
    self.boredomState.state = newState
    self.boredomState.ticks = 0
end

---@return nil
function Wispell:tickBoredom()
    self.boredomState.ticks = self.boredomState.ticks + 1

    if  self.boredomState.state == 'interested' and 
        self.boredomState.ticks >= WISPELL_BORED_TIME
    then
        self:changeBoredom('boring')
        self.expressionAnimState:switch(WispellAnims.bored)
        return
    end

    if  self.boredomState.state == 'boring' and
        self.boredomState.ticks >= WISPELL_BOOK_DEPLOY_TIME
    then
        self:changeBoredom('bored')
        return
    end

    if  self.boredomState.state == 'unboring' and
        self.boredomState.ticks >= WISPELL_BOOK_DISMISS_TIME
    then
        self:changeBoredom('interested')
        self.accessories.book.offY = WISPELL_BOOK_AWAY_OFF
        return
    end
end

---@return nil
function Wispell:restoreInterest()
    if self.boredomState.state == 'interested' then
        self.boredomState.ticks = 0
        return
    end

    if self.boredomState.state == 'unboring' then
        return
    end

    self.boredomState.state = 'unboring'
    self.boredomState.ticks = 0
end

---@alias DrawFun fun(x, y): nil


PTL_BASE_TILE_CHROMA = PALETTE.BLACK
PTL_LETTER_TILE_CHROMA = PALETTE.WHITE

---@class ParticleState
---@field x number # x position in pixels
---@field y number # y position in pixels
---@field dx number # x velocity in pixels/tic
---@field dy number # y velocity in pixels/tic
---@field baseTile integer # sprite of base tile
---@field letterTile integer # sprite of letter tile to draw on top
ParticleState = {}

---@param x number # x position in pixels
---@param y number # y position in pixels
---@param dx number # x velocity in pixels per tic
---@param dy number # y velocity in pixels per tic
---@param baseTile integer
---@param letterTile integer
function ParticleState.new(x, y, dx, dy, baseTile, letterTile)
    local state = {
        x = x,
        y = y,
        dx = dx,
        dy = dy,
        baseTile = baseTile,
        letterTile = letterTile,
    }

    return setmetatable(state, {__index = ParticleState});
end

function ParticleState:update()
    self.x = self.x + self.dx
    self.y = self.y + self.dy
    self.dy = self.dy + PTL_GRAVITY
end

function ParticleState:alive()
    return self.y < SCREEN_H_px
end

PTL_GRAVITY = .15 -- in pixels/tic^2
-- TODO INIT DY VARIANCE
PTL_DX_INIT = .3  -- in pixels/tic, initial x speed
PTL_DY_INIT = .3  -- in pixels/tic, initial y speed
PTL_SPRITE_ROW_OFF = 16 -- how many tiles to add to get the sprite below

---@class LetterParticleEmitter
---@field particles ParticleState[]
LetterParticleEmitter = {}

function LetterParticleEmitter.new()
    local emitter = {
        particles = {}
    }

    return setmetatable(emitter, {__index = LetterParticleEmitter})
end

---add a letter's 4 particles to the alive set, with top left x,y pixel location
---given. 
---@param letter string
---@param element TileElem
---@param x number
---@param y number
function LetterParticleEmitter:spawnLetter(letter, element, x, y)
    local ltr_nw = LETTER_SPRITES[letter]
    local ltr_ne = ltr_nw + 1
    local ltr_sw = ltr_nw + PTL_SPRITE_ROW_OFF
    local ltr_se = ltr_sw + 1

    local base_nw = TILE_ELEMENTS[element]
    local base_ne = base_nw + 1
    local base_sw = base_nw + PTL_SPRITE_ROW_OFF
    local base_se = base_sw + 1


    local part_nw =
        ParticleState.new(x, y, -PTL_DX_INIT, -PTL_DY_INIT, base_nw, ltr_nw)
    local part_ne =
        ParticleState.new(x + TILE_W_px, y,
            PTL_DX_INIT, -PTL_DY_INIT, base_ne, ltr_ne)
    local part_sw =
        ParticleState.new(x, y + TILE_H_px,
            -PTL_DX_INIT, PTL_DY_INIT, base_sw, ltr_sw)
    local part_se =
        ParticleState.new(x + TILE_W_px, y + TILE_H_px,
            PTL_DX_INIT, PTL_DY_INIT, base_se, ltr_se)

    table.insert(self.particles, part_nw)
    table.insert(self.particles, part_ne)
    table.insert(self.particles, part_sw)
    table.insert(self.particles, part_se)
end

function LetterParticleEmitter:draw()
    for _, part in ipairs(self.particles) do
        spr(part.baseTile, part.x, part.y, PTL_BASE_TILE_CHROMA)
        spr(part.letterTile, part.x, part.y, PTL_LETTER_TILE_CHROMA)
    end
end

function LetterParticleEmitter:tick()
    local alive = {}
    for _, part in ipairs(self.particles) do
        part:update()

        if not part.alive then
            goto continue
        end
        table.insert(alive, part)
        ::continue::
    end
    self.particles = alive
end

---@class DelayAction
---@field ticsLeft integer
---@field action ActionFun
---@alias ActionFun fun(self: StInGame)
DelayAction = {}

---@param ticsLeft integer
---@param action ActionFun
function DelayAction.new(ticsLeft, action)
    return {
        ticsLeft = ticsLeft,
        action = action
    }
end



---@class StInGame : IAppState
---@field ndScreen Node
---@field ndField Node
---@field ndStatus Node
---@field ndWispell Node
---@field ndBook Node
---@field buttons Button[]
---@field btnMusic SpriteToggleButton
---@field btnSfx SpriteToggleButton
---@field wispell Wispell
---@field grid LetterGrid
---@field highlight Cr | nil
---@field strand Strand
---@field dfaState DfaState
---@field score integer
---@field level integer
---@field nextLevelTarget integer
---@field levelStartScore integer
---@field subState StInGame_SubState 
---@field ticks integer
---@field nLevelWordsSubmitted integer
---@field levelBestWord string
---@field levelBestWordScore integer
---@field gameBestWord string
---@field gameBestWordScore integer
---@field statusMsg nil|StatusMessage|string
---@field statusTicksLeft integer
---@field nChances integer
---@field currentPar number
---@field letterPartEmitter LetterParticleEmitter
---@field delayActions DelayAction[]
---@field ticksSinceLastPlay integer
---@field bookDeployTicks number
---@field postGameOver boolean
---@field hoverButton Button|nil
---@field levelStart integer
StInGame = {}
StInGame.__index = StInGame

IN_GAME_BTN_MUSIC_OFF = {x = 0, y = 0}

BTN_MUSIC_NAME = 'btn music'
BTN_MUSIC_HINT = 'Music on/off'
BTN_TOGGLE_STATE_ON = 1
BTN_TOGGLE_STATE_OFF = 2

IN_GAME_BTN_SFX_OFF = {x = 0, y = 8}
BTN_SFX_NAME = 'btn sfx'
BTN_SFX_HINT = 'SFX on/off'

IN_GAME_BTN_NEXTBGM_OFF = {x = 8, y = 0}
BTN_NEXTBGM_NAME = 'btn nextbgm'
BTN_NEXTBGM_HINT = 'Next Song'

IN_GAME_BTN_NOIDEA_OFF = {x = 56, y = 56}
BTN_NOIDEA_NAME = 'btn noidea'
BTN_NOIDEA_HINT = "I'm stumped!"

IN_GAME_BTN_LEAVE_OFF = {x = 0, y = 56}
BTN_LEAVE_NAME = 'btn leave'
BTN_LEAVE_HINT = 'Abandon game!'

BONUS_SCORE_PER_CHANCE = 1000
IN_GAME_NEW_LEVEL_SPAWN_DELAY = 60

---comment
---@param lvlStart integer|nil
---@return StInGame
function StInGame.new(lvlStart)
    lvlStart = lvlStart or 1
    local ndScreen = Node.new(nil, 'screen', 0, 0, SCREEN_W_px, SCREEN_H_px)
    local ndField = ndScreen:addChildFromTopRight(
        'field top left',
        FIELD_W_px + FIELD_RIGHT_BUFFER_px,
        FIELD_TOP_OFF_px,
        FIELD_W_px, FIELD_H_px
    )
    local ndStatus = ndScreen:addChild(
        'status area',
        0, 60, 96, 104
    )
    local ndWispell = ndScreen:addChild(
        'wispell',
        WISPELL_OFF_X_px,
        WISPELL_OFF_Y_px,
        WISPELL_PROFILE_TILES_W * TILE_W_px,
        WISPELL_PROFILE_TILES_H * TILE_H_px
    )
    local ndBook = ndWispell:addChild(
        'book node',
        WISPELL_BOOK_OFF_X,
        SCREEN_H_px - ndWispell.hpx + WISPELL_BOOK_H * TILE_H_px,
        WISPELL_BOOK_W * TILE_W_px,
        WISPELL_BOOK_H * TILE_H_px
    )
    local ndBtnMusic = ndScreen:addChild(
        'nd btn music',
        IN_GAME_BTN_MUSIC_OFF.x,
        IN_GAME_BTN_MUSIC_OFF.y,
        BTN_SIMPLE_W,
        BTN_SIMPLE_H
    )
    local ndBtnSfx = ndScreen:addChild(
        'nd btn sfx',
        IN_GAME_BTN_SFX_OFF.x,
        IN_GAME_BTN_SFX_OFF.y,
        BTN_SIMPLE_W,
        BTN_SIMPLE_H
    )
    local ndBtnNextBgm = ndScreen:addChild(
        'nd btn nextbgm',
        IN_GAME_BTN_NEXTBGM_OFF.x,
        IN_GAME_BTN_NEXTBGM_OFF.y,
        BTN_SIMPLE_W,
        BTN_SIMPLE_H
    )
    local ndBtnNoIdea = ndScreen:addChild(
        'nd btn noidea',
        IN_GAME_BTN_NOIDEA_OFF.x,
        IN_GAME_BTN_NOIDEA_OFF.y,
        BTN_SIMPLE_W,
        BTN_SIMPLE_H
    )
    local ndBtnLeave = ndScreen:addChild(
        'nd btn leave',
        IN_GAME_BTN_LEAVE_OFF.x,
        IN_GAME_BTN_LEAVE_OFF.y,
        BTN_SIMPLE_W,
        BTN_SIMPLE_H
    )

    local btnMusic =
        SpriteToggleButton.new(
            ndBtnMusic,
            BTN_MUSIC_NAME, BTN_MUSIC_HINT,
            {BTN_SPR_MUSIC_ON, BTN_SPR_MUSIC_OFF},
            PALETTE.BLACK
        )
    local btnSfx = 
        SpriteToggleButton.new(
            ndBtnSfx,
            BTN_SFX_NAME, BTN_SFX_HINT,
            {BTN_SPR_SFX_ON, BTN_SPR_SFX_OFF},
            PALETTE.BLACK
        )
    -- it's not actually a toggle button, but it has a sprite...
    local btnNextBgm =
        SpriteToggleButton.new(
            ndBtnNextBgm,
            BTN_NEXTBGM_NAME, BTN_NEXTBGM_HINT,
            {BTN_SPR_NEXT_BGM},
            PALETTE.BLACK
        )
    local btnNoIdea =
        SpriteToggleButton.new(
            ndBtnNoIdea,
            BTN_NOIDEA_NAME, BTN_NOIDEA_HINT,
            {BTN_SPR_NO_IDEA},
            PALETTE.BLACK
        )
    local btnLeave =
        SpriteToggleButton.new(
            ndBtnLeave,
            BTN_LEAVE_NAME, BTN_LEAVE_HINT,
            {BTN_SPR_LEAVE},
            PALETTE.BLACK
        )

    local buttons = {
        btnMusic,
        btnSfx,
        btnNextBgm,
        btnNoIdea,
        btnLeave,
    }

    local state = {
        ndScreen = ndScreen,
        ndField = ndField,
        ndStatus = ndStatus,
        ndWispell = ndWispell,
        ndBook = ndBook,
        buttons = buttons,
        btnMusic = btnMusic,
        btnSfx = btnSfx,
        letterPartEmitter = LetterParticleEmitter.new(),
        postGameOver = false,
        nSyncDelayTicks = 2, -- for switching music
        hoverButton = nil,
    }

    setmetatable(state, StInGame)

    state:newGame(lvlStart)

    return state
end

function StInGame:enter()
    local song = StartingSongNo(self.level)
    SetSongIdx(song)
end

function StInGame:delayTick()
    if self.nSyncDelayTicks == 2 then
        vbank(0)
        sync(1 | 2, 0)
    elseif self.nSyncDelayTicks == 1 then
        vbank(1)
        sync(1 | 2, 0)
        vbank(0)
    elseif self.nSyncDelayTicks == 0 then
        music()
    end
end

---determine which song to play based on which level we're starting with
---@param levelStart integer
function StartingSongNo(levelStart)
    local songBank0 = math.floor(levelStart / 4)
    local wrapped = songBank0 % #PlayList
    return wrapped + 1
end

---@param levelStart integer
function StInGame:newGame(levelStart)
    self.grid = LetterGrid.new(self.ndField)
    self.strand = Strand.new()
    self.highlight = nil
    self.dfaState = wordDfa.states[DawgStart]
    self.score = 0
    self.level = levelStart
    self.nextLevelTarget = ScoreToReachLevel(levelStart + 1)
    self.ticks = 0
    self.nLevelWordsSubmitted = 0
    self.levelBestWord = ""
    self.levelBestWordScore = 0
    self.gameBestWord = ""
    self.gameBestWordScore = 0
    self.delayTicks = 0
    self.nChances = N_STARTING_CHANCES
    self.statusMsg = nil
    self.statusTicksLeft = 0
    self.wispell = Wispell.new(self.ndWispell)
    self.currentPar = 0
    self.levelStartScore = 0
    self.delayActions = {}
    self.ticksSinceLastPlay = 0
    self.bookDeployTicks = 0
    self.postGameOver = false
    self.hoverButton = nil
    self.startLevel = levelStart
    self.delayTicks = 1

    self.wispell:restoreInterest()

    --for col=1, 8 do
    --    for row=1, FIELD_TILES_PER_COL[col] do
    --        self.grid.cols[col][row] = GridTile.new('a', 0, 'normal')
    --    end
    -- end

--    self.grid.cols[1][1] = GridTile.new('b', 0, 'normal')
--    self.grid.cols[2][1] = GridTile.new('t', 0, 'normal')
    self:spawnTiles()

    self:delayAction(
        IN_GAME_NEW_LEVEL_SPAWN_DELAY,
        function (_) end -- no op, just don't accept mouse events for a sec
    )
end

---@return SpawnTilesResult
function StInGame:spawnTiles()
    local result = self.grid:spawnTiles()

    self.currentPar =
        math.ceil(ParValuePercentage(self.level) * self.grid.bestWord.score)

    return result
end

---
---@param mouse MouseState
function StInGame:handleClick(mouse)
    local gridOffX, gridOffY = self.ndField:offsetOf(mouse.x, mouse.y)
    self.highlight = self.grid:pointOverTile(gridOffX, gridOffY)

    if mouse.leftTrans ~= 'up' then
        return
    end

    self.ticksSinceLastPlay = 0
    self.wispell:restoreInterest()

    if self.subState and self.subState.id == 'level up' then
        self.subState = nil
        self:reFall()

        -- play a sound?
        return
    end

    if self.subState and self.subState.id == 'game over' then
        self.subState = nil
        self.wispell:orderArms()
        self.postGameOver = true
        return
    end

    if self.subState and self.subState.id == 'abandon' then
        local ss = self.subState --[[@as StInGame_Abandon]]
        if ss.finished then
            if ss.reallyLeave then
                self:gameOver()
            else
                self.subState = nil
            end
        end
        return
    end


    local highlightedTile =
        self.highlight and
        self.grid.cols[self.highlight.col][self.highlight.row]

    if not highlightedTile then
        self.strand:clear()
        sfx(SFX.tileDeselect, 'C-5', 120, SFX_CHANNEL, SfxVol)
        self.dfaNode = wordDfa.states[DawgStart]
        return
    end

    local col = self.highlight.col
    local row = self.highlight.row
    -- only add if last tile is a neighbor of highlight or the list
    -- of selected tiles is empty
    local lastTile = self.strand:lastTile()

    if self.strand:length() == 0 then
        self.strand:add(col, row)
        sfx(SFX.tileSelect, 'C-5', 120, SFX_CHANNEL, SfxVol)
        return
    end

    local word, elems = self.strand:asStringAndElements(self.grid)
    local exclamation = word:sub(#word, #word) == '!'
    if exclamation then word = word:sub(1, #word - 1) end

    -- if the tile was previously selected, trim to it
    if self.strand:tileSelected(col, row) then
        -- if there is only one tile selected and we just clicked it
        if self.strand:length() == 1 then
            self.strand:clear()
            sfx(SFX.tileDeselect, 'C-5', 120, SFX_CHANNEL, SfxVol)
            -- clear.wav
            return
        end

        -- we clicked the last tile of a long enough strand: submit.
        local dfaNode = wordDfa:matchPrefix(word, 1)

        local tileSubmitted =
            lastTile and
            ((dfaNode and dfaNode.final) or DebugMode)  and
            self.highlight.col == lastTile.col and
            self.highlight.row == lastTile.row and
            (self.strand:length() >= MIN_WORD_LEN or DebugMode)

        if tileSubmitted then
            self:submitWord()
            return
        end

        -- otherwise, trim
        self.strand:trimTo(col, row)
        sfx(SFX.tileDeselect, 'C-5', 120, SFX_CHANNEL, SfxVol)
        -- trim.wav
        return
    end

    assert(lastTile)

    local isNeighbor = false

    local neighbors = self.grid:neighbors(col, row)
    for _, neigh in ipairs(neighbors) do
        if neigh.row == lastTile.row and neigh.col == lastTile.col then
            -- we can add it, so skip the next return
            isNeighbor = true
        end
    end

    if not isNeighbor then
        self:setStatus(MustNeighborLastLetter())
        sfx(SFX.cant, 'C-3', 120, SFX_CHANNEL, SfxVol)
        return
    end

    if exclamation then
        -- exclamation point must end the word
        self:setStatus(BangMustBeAtEnd())
        sfx(SFX.cant, 'C-4', 120, SFX_CHANNEL, SfxVol)
        return
    end

    local next_letter_is_exclamation = self.grid.cols[col][row].letter == '!'

    if (next_letter_is_exclamation and self.strand:length() > MAX_WORD_LEN) or
        (not next_letter_is_exclamation and self.strand:length() >= MAX_WORD_LEN)
    then
        self:setStatus(WordTooLong())
        sfx(SFX.cant, 'C-3', 120, SFX_CHANNEL, SfxVol)
        return
    end

    -- add.wav
    sfx(SFX.tileSelect, 'C-5', 120, SFX_CHANNEL, SfxVol)
    self.strand:add(col, row)
end


--- returns a table that maps a column and row to a best word, its elements,
--- its Cr path, and its score.

---@return table<integer, table<integer, BestWordInfo|nil>>
function LetterGrid:bestWordsFromEachTile()
    local result = {}

    -- compute all the best words makeable from every tile
    for col=1, FIELD_TILES_W do
        result[col] = {}

        for row=1, FIELD_TILES_PER_COL[col] do
            result[col][row] = self:bestWordStartingAt(col, row)
        end
    end

    return result
end

---Given the best words from each tile, return the best word possible if it
---exists.
---@param tileResults table<integer, table<integer, BestWordInfo|nil>>
---@return BestWordInfo | nil
function BestWordAvail(tileResults)
    ---@type BestWordInfo|nil
    local best = nil

    for col=1, FIELD_TILES_W do
        for row=1, FIELD_TILES_PER_COL[col] do
            local result = tileResults[col][row]
            if not best or result and result.score > best.score then
                best = result
            end
        end
    end

    return best
end

---Given the best words from each tile, selects a random one for comparison
---@param tileResults table<integer, table<integer, BestWordInfo|nil>>
---@return BestWordInfo | nil
function RandomComparisonWord(tileResults)
    local randomCol = math.random(1, FIELD_TILES_W)
    local randomRow = math.random(1, FIELD_TILES_PER_COL[randomCol])
    return tileResults[randomCol][randomRow]
end

N_STARTING_CHANCES = 3
MAX_LEVEL = 15
PAR_PROP_MAX = 0.5
PAR_PROP_LVL1 = 0.1
PAR_PROP_STEP_PER_LVL = (PAR_PROP_MAX - PAR_PROP_LVL1) / MAX_LEVEL

--- what percent of the points for the highest word is needed for no
--- freezing tiles? depends on the level.
--- @param level integer
--- @return number
function ParValuePercentage(level)
    if level >= MAX_LEVEL then
        return PAR_PROP_MAX
    end

    return PAR_PROP_LVL1 + (level - 1) * PAR_PROP_STEP_PER_LVL
end



---@param superlative string
function StInGame:freezeBestWord(superlative)
    -- freeze tiles
    self.grid:freeze(self.grid.bestWord.crs)
    self:setStatus(XWasBetter(self.grid.bestWord.word, superlative))
    sfx(SFX.badWord, 'C-6', 120, SFX_CHANNEL, SfxVol)

    -- two "huh" animations
    local huhs = {WispellAnims.huh, WispellAnims.argh}
    local whichHuh = math.random(1, 2)
    self.wispell.expressionAnimState:switch(huhs[whichHuh])

    -- deduct a chance
    self.nChances = self.nChances - 1
end

function StInGame:gameOver()
    self.wispell:presentArms()
    local hs = Highscore.new(
        self.score, self.level, self.ticks,
        self.gameBestWord, self.gameBestWordScore
    )
    local rank = SaveHighScoreIfHighEnough(hs)

    self.subState = StInGame_GameOver.new(60,
        self.gameBestWord, self.gameBestWordScore,
        self.score, self.ticks, self.level, rank
    )
    sfx(SFX.gameOver, 'C-5', 60, SFX_CHANNEL, SfxVol)
end

function StInGame:submitWord()
    local letters, elems = self.strand:asStringAndElements(self.grid)
    local score = WordScore(letters, elems)
    self.statusMsg = nil

    self.nLevelWordsSubmitted = self.nLevelWordsSubmitted + 1
    if score > self.levelBestWordScore then
        self.levelBestWordScore = score
        self.levelBestWord = letters

        if score > self.gameBestWordScore then
            self.gameBestWordScore = score
            self.gameBestWord = letters
        end
    end

    local comparisonScore = self.currentPar

    if score < comparisonScore then
        self:freezeBestWord("better")
    elseif score >= self.grid.bestWord.score then
        self:setStatus(BestWord())
        self.nChances = self.nChances + 1
        sfx(SFX.bestWord, 'E-6', 120, SFX_CHANNEL, SfxVol)
        self.wispell.expressionAnimState:switch(WispellAnims.great)
    else
        self:setStatus(GoodWord())
        sfx(SFX.goodWord, 'C-5', 120, SFX_CHANNEL, SfxVol)
        self.wispell.expressionAnimState:switch(WispellAnims.okay)
    end

    local function clearSubmittedWord()
        for _, cr in ipairs(self.strand.tiles) do
            local tile = self.grid.cols[cr.col][cr.row]
            local px, py = self.ndField:pos()
            px = px + (cr.col - 1) * LETTER_TILE_W_px
            local height = FIELD_COL_HEIGHTS[cr.col]
            py = py + height - cr.row * LETTER_TILE_H_px
            self.letterPartEmitter:spawnLetter(tile.letter, tile.elem, px, py)
        end

        for _, cr in ipairs(self.strand.tiles) do
            self.grid:deleteTile(cr.col, cr.row)
        end

        self.score = self.score + score

        self.strand:clear()
        self.nextLevelTarget = self.nextLevelTarget - score

        if self.nextLevelTarget <= 0 then
            self:levelUp()
        elseif self.nChances <= 0 then
            self:gameOver()
        else
            sfx(SFX.blockBreak, 'C-4', 60, SFX_CHANNEL, SfxVol)
        end

        self:startFalling()
        local spawnResult = self:spawnTiles();

        if spawnResult == 'respawned' then
            self:setStatus(RespawnedTiles())
        end
    end

    self:delayAction(SUBMIT_DELAY_TICKS, clearSubmittedWord)

    self.delayTicks = SUBMIT_DELAY_TICKS
end

function StInGame:delayAction(tics, action)
    table.insert(self.delayActions, DelayAction.new(tics, action))
end

function StInGame:tickDelayActions()
    --    local keep = {}
    -- this might generate a lot of garbage.
    -- keep an eye on memory usage.
    -- in fact, it does generate a lot of garbage, but the GC seems to 
    -- have it under control. 
    -- It bugs me though, so go ahead and do this in place
    -- (in retrospect, there are tons of sources of garbage and the GC keeps
    -- up just fine, not sure why this particular one bothered me.)
    local i = 1
    while i <= #self.delayActions do
        local action = self.delayActions[i]
        if action.ticsLeft == 0 then
            action.action(self)

            -- delete and shift down. there will not be many of these.
            table.remove(self.delayActions, i)
        else
            action.ticsLeft = action.ticsLeft - 1
            i = i + 1
        end
    end
end

function StInGame:levelUp()
    self.level = self.level + 1
    UpdateMaxLevelReachedIfHigher(self.level)
    local newSong = UnlockNextSongIfAble(self.level)
    if newSong then
        SetNextSong()
    end

    self.nextLevelTarget = ScoreToReachLevel(self.level + 1)
    local wordScoreGained = self.score - self.levelStartScore
    local chanceScoreGained = self.nChances * BONUS_SCORE_PER_CHANCE
    self.subState = StInGame_LevelUp.new {
            newLevel = self.level,
            wordScoreGained = wordScoreGained,
            chanceScoreGained = chanceScoreGained,
            totalScoreGained = wordScoreGained + chanceScoreGained,
            newScoreTarget = ScoreToReachLevel(self.level + 1),
            ticksTaken = self.ticks,
            wordsSubmitted = self.nLevelWordsSubmitted,
            bestWord = self.levelBestWord,
            bestWordScore = self.levelBestWordScore,
            chancesLeft = self.nChances,
            newSongUnlocked = newSong
    }
    sfx(SFX.levelUp, 'C-5', 60, SFX_CHANNEL, SfxVol)
    self:setStatus(HeyLevelUp())

    self.nLevelWordsSubmitted = 0
    self.levelBestWord = ""
    self.levelBestWordScore = 0
    self.nChances = math.max(self.nChances, N_STARTING_CHANCES)
    self.score = self.score + chanceScoreGained
    self.levelStartScore = self.score
    self.delayActions = {}

    self.grid:clearAllTiles()
    self:spawnTiles()

    self:delayAction(
        IN_GAME_NEW_LEVEL_SPAWN_DELAY,
        function (_) end -- no op, just don't accept mouse events for a sec
    )
end

---make it so that every gap has everything above it fall down
function StInGame:startFalling()
    for col=1, FIELD_TILES_W do
        for row=1, FIELD_COL_HEIGHTS[col] do
            -- every tile above, have its row offset set to + 1, so that
            -- we know it's at least 1 row too high. it will be ticked down
            -- every frame.
            if not self.grid.cols[col][row] then
                for above=row+1, FIELD_COL_HEIGHTS[col] do
                    if self.grid.cols[col][above] then
                        self.grid.cols[col][above].rowOff = above - row
                        self.grid.cols[col][row] = self.grid.cols[col][above]
                        self.grid.cols[col][above] = nil
                        break
                    end
                end
            end
        end
    end
end

---make the same tiles fall back down again. useful when leaving a substate.
function StInGame:reFall()
    for col=1, FIELD_TILES_W do
        for row=1, FIELD_COL_HEIGHTS[col] do
            if self.grid.cols[col][row] then
                self.grid.cols[col][row].rowOff = FIELD_TILES_H + row
            end
        end
    end
end

---make falling tiles fall down until they hit rowOff == 0
function StInGame:fallTick()
    for col=1, FIELD_TILES_W do
        for row=1, FIELD_COL_HEIGHTS[col] do
            local tile = self.grid.cols[col][row]
            if not tile then goto continue end

            local amount = LETTER_FALL_SPEED_ROWS_PER_TICK
            tile.rowOff = math.max((tile.rowOff or 0) - amount, 0)
 
            ::continue::
        end
    end
end

---get the tile the mouse cursor is over and report the best word there
---@param mouseX number
---@param mouseY number
---@return nil
function StInGame:bestWordHint(mouseX, mouseY)
    local mouseOffX, mouseOffY = self.grid.node:offsetOf(mouseX, mouseY)

    local cr = self.grid:pointOverTile(mouseOffX, mouseOffY)

    if not cr then
        local best = self.grid.bestWord
        if not best then
            self.statusMsg = CheatBestWord("no words!", 0, 0);
            return
        end

        local bwCr = self.grid.bestWord.crs[1]
        self.statusMsg = CheatBestWord(best.word, bwCr.col, bwCr.row)
        return
    end

    local best = self.grid.allBestWords[cr.col][cr.row]
    if not best then
        self.statusMsg = CheatBestWord("no word", cr.col, cr.row);
    else
        self.statusMsg = CheatBestWord(best.word, cr.col, cr.row);
    end
end

function StInGame:memProfile()
    self.statusMsg = CheatMemProfile()
end

---
---@param mouse MouseState
function StInGame:tick(mouse)
    if self.postGameOver then
        if self.level > MAX_LEVEL and self.startLevel < MAX_LEVEL then
            return StEnding.new()
        end

        return StMainMenu.new()
    end

    if MusicEnabled then
        CurrentSongState:tick()

        if CurrentSongState:finished() then
            SetNextSong()
        end
    end

    local cheat = CheatKeyPressed()
    if cheat == 'level_up' then
        self:levelUp()
    elseif cheat == 'cycle_best_word' then
        self:bestWordHint(mouse.x, mouse.y)
    elseif cheat == 'mem_profile' then
        self:memProfile()
    end

    if not self.subState then
        self.ticks = self.ticks + 1
        self.ticksSinceLastPlay = self.ticksSinceLastPlay + 1
        self.delayTicks = math.max(self.delayTicks - 1, 0)
    elseif self.subState.id == 'abandon' then
        (self.subState --[[@as StInGame_Abandon]]):tick(mouse)
    end

    self:tickDelayActions()
    if #self.delayActions == 0 then
        self:handleClick(mouse)
    else
    end

    if self.statusTicksLeft == 1 then
        self.statusMsg = nil
    end
    self.statusTicksLeft = math.max(self.statusTicksLeft - 1, 0)

    self:fallTick()
    self.letterPartEmitter:tick()
    self.wispell:tick()

    local clicked = Button.updateButtonsAndDetectClick(
        self.buttons, mouse.x, mouse.y, mouse.left)

    -- if the status message is caused by hovering over a button, clear it.
    -- (it's only a string if it's a temporary hover status, otherwise it will
    -- be a function)
    if type(self.statusMsg) == 'string' then
        self.statusMsg = nil
    end

    for _, button in ipairs(self.buttons) do
        if button.hover and type(self.statusMsg) ~= "function" then
            -- only change the status message if there isn't a higher 
            -- priority one (a function)
            self.statusMsg = button.hint
        end
    end


    if clicked then
        if clicked.name == BTN_MUSIC_NAME then
            ToggleMusic()
        elseif clicked.name == BTN_SFX_NAME then
            ToggleSfx()
        elseif clicked.name == BTN_NEXTBGM_NAME then
            if not MusicEnabled then
                MusicOn()
            else
                SetNextSong()
            end
        elseif clicked.name == BTN_NOIDEA_NAME and self.delayTicks == 0 then
            if not self.grid.bestWord then
                self:setStatus(NoGoodWords())
                return
            end

            self:freezeBestWord("best")
            self.grid:updateBestWords()
            self.delayTicks = 60

            if self.nChances <= 0 then
                self:delayAction(60, function() self:gameOver() end)
            end
        elseif clicked.name == BTN_LEAVE_NAME then
            self.subState = StInGame_Abandon.new()
        end
    end

    self.btnMusic.toggleState = MusicEnabled and 1 or 2
    self.btnSfx.toggleState = (SfxVol == 0) and 2 or 1
end


---@class StInGame_Abandon
---@field id 'abandon'
---@field reallyLeave boolean
---@field finished boolean
---@field btnLeave TextButton
---@field btnCancel TextButton
---@field btnConfirm TextButton
---@field buttons TextButton[]
StInGame_Abandon = {}


ST_ABANDON_TEXT = 'Really abandon game?'
ST_ABANDON_TEXT_AT = { x = 100, y = 40}
ST_ABANDON_BUTTON_AT = { x = 120, y = 60 }

ST_ABANDON_BTN_NAME = 'bt_abandon'
ST_ABANDON_BTN_TEXT = 'Abandon!'
ST_ABANDON_BTN_HINT = 'Go back to the menu!'
ST_ABANDON_BTN_CANCEL_NAME = 'abandon_cancel'
ST_ABANDON_BTN_CANCEL_TEXT = 'Cancel!'
ST_ABANDON_BTN_CANCEL_HINT = 'Nevermind!'
ST_ABANDON_BTN_CONFIRM_NAME = 'abandon_confirm'
ST_ABANDON_BTN_CONFIRM_TEXT = 'Confirm!'
ST_ABANDON_BTN_CONFIRM_HINT = 'No turning back!'

ST_ABANDON_BTN_CONFIRM_YOFF = TEXT_BUTTON_H_PX * 5

---@return StInGame_Abandon
function StInGame_Abandon.new()
    local nBtnLeave = Node.new(
        nil, 'nd leave',
        ST_ABANDON_BUTTON_AT.x,
        ST_ABANDON_BUTTON_AT.y,
        print(ST_ABANDON_BTN_TEXT, SCREEN_W_px),
        TEXT_BUTTON_H_PX
    )
    local nBtnCancel = Node.new(
        nBtnLeave, 'nd cancel',
        0,
        8,
        print(ST_ABANDON_BTN_CANCEL_TEXT, SCREEN_W_px),
        TEXT_BUTTON_H_PX
    )
    local nBtnConfirm = Node.new(
        nBtnCancel, 'nd confirm',
        0,
        ST_ABANDON_BTN_CONFIRM_YOFF,
        print(ST_ABANDON_BTN_CONFIRM_TEXT, SCREEN_W_px),
        TEXT_BUTTON_H_PX
    )

    local btnLeave = TextButton.new(
        nBtnLeave,
        ST_ABANDON_BTN_NAME,
        ST_ABANDON_BTN_TEXT,
        ST_ABANDON_BTN_HINT,
        PALETTE.WHITE
    )
    local btnCancel = TextButton.new(
        nBtnCancel,
        ST_ABANDON_BTN_CANCEL_NAME,
        ST_ABANDON_BTN_CANCEL_TEXT,
        ST_ABANDON_BTN_CANCEL_HINT,
        PALETTE.WHITE
    )
    local btnConfirm = TextButton.new(
        nBtnConfirm,
        ST_ABANDON_BTN_CONFIRM_NAME,
        ST_ABANDON_BTN_CONFIRM_TEXT,
        ST_ABANDON_BTN_CONFIRM_HINT,
        PALETTE.DK_GRAY
    )

    local state = {
        id = 'abandon',
        reallyLeave = false,
        confirmed = false,
        btnLeave = btnLeave,
        btnCancel = btnCancel,
        btnConfirm = btnConfirm,
        buttons = {btnLeave, btnCancel, btnConfirm}
    }

    return setmetatable(state, {__index = StInGame_Abandon})
end

function StInGame_Abandon:draw()
    print(ST_ABANDON_TEXT, ST_ABANDON_TEXT_AT.x, ST_ABANDON_TEXT_AT.y, PALETTE.WHITE)

    if self.reallyLeave then
        self.btnLeave.textColor = PALETTE.RED
        self.btnCancel.textColor = PALETTE.LT_GRAY
        self.btnConfirm.textColor = PALETTE.WHITE

        self.btnConfirm:draw()
    else
        self.btnConfirm.textColor = PALETTE.WHITE
        self.btnCancel.textColor = PALETTE.WHITE
    end

    self.btnLeave:draw()
    self.btnCancel:draw()
end

---@param mouse MouseState
function StInGame_Abandon:tick(mouse)
    local clicked = Button.updateButtonsAndDetectClick(
        self.buttons, mouse.x, mouse.y, mouse.left)

    if not clicked then return end

    if clicked.name == ST_ABANDON_BTN_NAME then
        self.reallyLeave = true
        return
    end

    if clicked.name == ST_ABANDON_BTN_CANCEL_NAME then
        self.reallyLeave = false
        self.finished = true
        return
    end

    if clicked.name == ST_ABANDON_BTN_CONFIRM_NAME then
        self.finished = true
        return
    end
end


---@class StInGame_LevelUp
---@field id 'level up'
---@field delayTicks integer
---@field newLevel integer
---@field wordScoreGained number
---@field chanceScoreGained number
---@field totalScoreGained number
---@field newScoreTarget integer
---@field ticksTaken integer
---@field wordsSubmitted integer
---@field bestWord string
---@field bestWordScore integer
---@field chancesLeft integer
---@field newSongUnlocked boolean
StInGame_LevelUp = {}


---@alias StInGame_SubState nil|StInGame_LevelUp|StInGame_GameOver|StInGame_Abandon

---@param table {
--- scoreGained:integer, newScoreTarget:integer,
--- ticksTaken:integer, newLevel:integer, wordsSubmitted:integer,
--- bestWord:string, bestWordScore:integer, newSongUnlocked: boolean,
--- [any]:any,
---}
---@return any
function StInGame_LevelUp.new(table)
    table.id = 'level up'
    table.delayTicks = 30
    return setmetatable(table, {__index = StInGame_LevelUp})
end

---Return hours, minutes, seconds, and remainder ticks from given ticks
---@param ticks integer
---@return integer, integer, integer, integer
function HoursMinsSecs(ticks)
    local secsTaken = math.floor(ticks / 60)
    local ticksRem = ticks % 60
    local minsTaken = math.floor(secsTaken / 60)
    local secsRem = secsTaken % 60
    local hoursTaken = math.floor(minsTaken / 60)
    local minsRem = minsTaken % 60

    return hoursTaken, minsRem, secsRem, ticksRem
end

---@param node Node
function StInGame_LevelUp:draw(node)
    local x, y = node:pos()
    -- local secsTaken = math.floor(self.ticksTaken / 60)
    -- local ticksRem = self.ticksTaken % 60
    -- local minsTaken = math.floor(secsTaken / 60)
    -- local secsRem = secsTaken % 60
    local hours, mins, secs, ticks = HoursMinsSecs(self.ticksTaken)


    print("Welcome to level " .. ToStr(self.newLevel) .. "!", x, y, PALETTE.WHITE)
    print("Word Score: " .. ToStr(self.wordScoreGained), x + 8, y + 8, PALETTE.BLUE)
    print("Chance Score: " .. ToStr(self.chancesLeft) .. " * 1000", x + 8, y + 16, PALETTE.BLUE)
    print("Score gained: " .. ToStr(self.totalScoreGained), x + 8, y + 24, PALETTE.WHITE)
    print("New target: " .. ToStr(self.newScoreTarget), x + 8, y + 32, PALETTE.WHITE)
    print("Words made: " .. ToStr(self.wordsSubmitted), x + 8, y + 40, PALETTE.RED)
    print("Best word: " .. self.bestWord, x + 8, y + 48, PALETTE.LIME)
    print("Was worth: " .. ToStr(self.bestWordScore), x + 8, y + 56, PALETTE.LIME)
    
    if hours < 1 then
        local formatStr = "%02d:%02d,%02d"
        local time = string.format(formatStr, mins, secs, ticks)
        print("Time: " .. time, x + 8, y + 72, PALETTE.WHITE)
    else
        print("Time: > 1 hour", x + 8, y + 72, PALETTE.WHITE)
    end

    if self.newSongUnlocked then
        print("New BGM unlocked!", x, y + 90, PALETTE.GREEN)
    end

    print("Click/tap anywhere", x, y + 104, PALETTE.WHITE)
    print("to continue!", x, y + 112, PALETTE.WHITE)
end

---@class StInGame_GameOver
---@field id 'game over'
---@field delayTicks integer
---@field gameBestWord string
---@field gameBestWordScore integer
---@field totalScore integer
---@field ticksTaken integer
---@field levelAchieved integer
---@field hsRank integer|nil
StInGame_GameOver = {}

---@param delay integer
---@param bestWord string
---@param bestScore integer
---@param score integer
---@param ticks integer
---@param level integer
---@param hsRank integer|nil
---@return StInGame_GameOver
function StInGame_GameOver.new(delay, bestWord, bestScore, score, ticks, level, hsRank)
    local state = {
        id = 'game over',
        delayTicks = delay,
        gameBestWord = bestWord,
        gameBestWordScore = bestScore,
        totalScore = score,
        ticksTaken = ticks,
        levelAchieved = level,
        hsRank = hsRank,
    }

    return setmetatable(state, {__index = StInGame_GameOver})
end

---@param node Node
function StInGame_GameOver:draw(node)
    local x, y = node:pos()
    local c = PALETTE.WHITE
    print("Game over on level " .. ToStr(self.levelAchieved), x, y, c)

    print("Final score: " .. ToStr(self.totalScore), x + 8, y + 16, c)
    print("Best word: " .. ToStr(self.gameBestWord), x + 8, y + 32, c)
    print("Worth: " .. ToStr(self.gameBestWordScore), x + 8, y + 40, c)
    
    local hours, mins, secs, ticks = HoursMinsSecs(self.ticksTaken)

    if hours > 9 then
        print("Time: >= 10 hours", x + 8, y + 56, c)
    else
        local time = string.format("%d:%02d:%02d,%02d", hours, mins, secs, ticks)
        print("Time: " .. time, x + 8, y + 56, c)
    end

    if self.hsRank then
        local msg = string.format("#%d High Score!", self.hsRank)
        print(msg, x + 8, y + 72, PALETTE.GREEN)
    end
end

CHEAT_ENABLE_CODE = 'nthgthdgdcrtdtrk' -- it's been 3 decades and I still remember this cheat
CHEAT_ENABLE_SFX = 52

CheatProgress = 1

--- Checks to see if the next key of the cheat was pressed. If not, resets the
--- progress back to zero
function CheckForCheatProgressAndEnableCheats()
    if CheatMode or not keyp() then return end

    local p = CheatProgress
    local expecting = CHEAT_ENABLE_CODE:byte(p, p) - ('a'):byte(1, 1) + 1
    if keyp(expecting) then
        CheatProgress = CheatProgress + 1
        if CheatProgress > #CHEAT_ENABLE_CODE then
            sfx(CHEAT_ENABLE_SFX, 'C-7', 60, SFX_CHANNEL, SfxVol)
            CheatMode = true
        end
    else
        CheatProgress = 1
    end
end

CHEAT_KEYMAP = {}
CHEAT_KEYMAP[13] = 'mem_profile' -- M
CHEAT_KEYMAP[12] = 'level_up' -- L
CHEAT_KEYMAP[2] = 'cycle_best_word' -- B
CHEAT_KEYMAP[21] = 'unlock_stages' -- U

---@alias Cheat 'level_up'|'cycle_best_word'|'mem_profile'|'unlock_stages'
---@return Cheat|nil
function CheatKeyPressed()
    if not CheatMode then
        return
    end

    for key, message in pairs(CHEAT_KEYMAP) do
        if keyp(key) then
            return message
        end
    end
end

--- a function that draws a status message to the specified location when called
---@alias StatusMessage fun(x: integer, y: integer): nil

STATUS_MSG_TICKS = 3 * 60

---set the current status message and time
---@param msg StatusMessage
function StInGame:setStatus(msg)
    self.statusMsg = msg
    self.statusTicksLeft = STATUS_MSG_TICKS
end

---create a StatusMessage that tells us there was a better word to have played.
---@param word string
---@param superlative string
function XWasBetter(word, superlative)
    return function(x, y)
        local w = print(word, x, y, PALETTE.BLUE)
        print(" was " .. superlative .. '!', x + w, y, PALETTE.WHITE)
    end
end


function CheatMemProfile()
    return function(x, y)
        local usedMem = collectgarbage("count")
        print(string.format("Mem used: %.0fkb", usedMem), x, y, PALETTE.GREEN);
    end
end

---@param word string
---@param c integer
---@param r integer
function CheatBestWord(word, c, r)
    return function(x, y)
        local w = print("Best: ", x, y, PALETTE.YELLOW)
        w = w + print(word, x + w, y, PALETTE.YELLOW)
        print(string.format('@%d,%d', c, r), x + w, y, PALETTE.YELLOW)
    end
end

function GoodWord()
    return function(x, y)
        print("Good word!", x, y, PALETTE.WHITE)
    end
end

function BestWord()
    return function(x, y)
        print("Best word!", x, y, PALETTE.YELLOW)
    end
end

-- could only happen on an incredibly sparse board where 
-- the user mashes the no idea button a bunch of times.
-- there may be no words with score > 0, forcing the user 
-- to play a 0 score one.
function NoGoodWords()
    return function(x, y)
        print("No good words!", x, y, PALETTE.RED)
    end
end

function RespawnedTiles()
    return function(x, y)
        print("No words! Respawned!", x, y, PALETTE.WHITE)
    end
end

function BangMustBeAtEnd()
    return function(x, y)
        print("! must be last!", x, y, PALETTE.YELLOW);
    end
end

function MustNeighborLastLetter()
    return function(x, y)
        print("Not a neighbor!", x, y, PALETTE.YELLOW)
    end
end

function WordTooLong()
    return function(x, y)
        print("Word too long!", x, y, PALETTE.YELLOW)
    end
end

function HeyLevelUp()
    return function(x, y)
        print("Level Up!", x, y, PALETTE.GREEN)
    end
end

---draw the status bar to the left
---@param node Node
---@param letters string
---@param isWord boolean
---@param wordScore integer | nil
---@param mana integer
---@param level integer
---@param next integer
---@param maxWords integer
---@param par number
---@param message nil|StatusMessage|string
function DrawStatus(
    node, letters, isWord,
    isCharged, wordScore, mana, level, next,
    maxWords, par,
    message
)
    local x, y = node:pos()
    local score = ToStr(wordScore)
    if letters:sub(-1) == '!' and score ~= nil then score = score .. '!' end

    local color =
        (isWord and isCharged) and PALETTE.LIME or
        (isWord and not isCharged) and PALETTE.WHITE or
        (not isWord and isCharged) and PALETTE.GREEN or
        PALETTE.LT_GRAY

    --if #letters > 0 then 
    --    print("[CANCEL]", x, y, PALETTE.GREEN)
    --end

    print(letters, x, y + 8, color)
    print(score, x, y + 16, color)

    local lvlText = 'Lvl: ' .. ToStr(level)
    if level <= MAX_LEVEL then lvlText = lvlText .. '/' .. ToStr(MAX_LEVEL) end
    print(lvlText, x, y + 24, PALETTE.WHITE)
    print("Score: " .. ToStr(mana), x, y + 32, PALETTE.WHITE)
    print("Next: " .. ToStr(next), x, y + 40, PALETTE.WHITE)
    print("Chances: " .. ToStr(maxWords), x, y + 48, PALETTE.WHITE)
    print("Par: " .. ToStr(par), x, y + 56, PALETTE.WHITE)

    if type(message) == 'function' then
        message(x, y + 64)
    elseif type(message) == 'string' then
        print(message, x, y + 64, PALETTE.WHITE)
    end
end

---
---@param letters string
---@param elements string[]
---@return integer
function WordScore(letters, elements)
    local score = 0
    for i=1, #letters do
        local letterScore = LETTER_SCORE[letters:sub(i, i)]
        if elements[i] == 'charged' then
            letterScore = letterScore * CHARGE_SCORE_MULT
        elseif elements[i] == 'frozen' then
            letterScore = 0
        end
        score = score + letterScore
    end

    return score * #letters * WORD_SCORE_MULT
end

---@return nil
function StInGame:drawButtons()
    for _, button in ipairs(self.buttons) do
        button:draw()
    end
end

function StInGame:draw()
    cls(0)

    local currentWord, currentElems = self.strand:asStringAndElements(self.grid)
    local exclamation = currentWord:sub(-1) == '!'
    local lookupWord =
        exclamation and currentWord:sub(1, -2) or currentWord
    local dfaNode = wordDfa:matchPrefix(lookupWord, 1)
    local isAWord = dfaNode and dfaNode.final or false

    local isCharged = false
    for i=1, 8 do
        isCharged = isCharged or (currentElems[i] == 'charged')
    end

    self.wispell:draw()
    self:drawButtons()

    DrawStatus(
        self.ndStatus,
        currentWord,
        isAWord,
        isCharged,
        WordScore(currentWord, currentElems),
        self.score,
        self.level,
        self.nextLevelTarget,
        self.nChances,
        self.currentPar,
        self.statusMsg
    )

    if self.subState then
        self.subState:draw(self.grid.node)
        return
    end

    self.grid:draw(self.highlight, self.strand)

    vbank(1)
    self.letterPartEmitter:draw()
    vbank(0)
end


---@class FireworkState
---@field x number
---@field y number
---@field dx number 
---@field dy number
---@field detoTime integer
---@field kind 'launching'|'exploding'
---@field palIndex integer
FireworkState = {}

--- Used when spawning identical flares upon detonation
---@return FireworkState
function FireworkState:cloneWithSpeed(dx, dy)
    return {
        x = self.x,
        y = self.y,
        dx = dx,
        dy = dy,
        detoTime = END_FIREWORK_FLARE_TIME,
        kind = self.kind,
        palIndex = self.palIndex
    }
end

END_SPR_FIREWORK_LAUNCH = 26
END_SPR_EXPLOSION_START = 27
END_SPR_EXPLOSION_N_FRAMES = 5
END_MAX_FIREWORKS = 4
END_CONGRATULATIONS_TIME = 60 * 3.6

END_SFX_FIREWORK_LAUNCH = 60
END_SFX_FIREWORK_DETO = 61

END_SONG_FANFARE = 3
END_SONG_HAPPY = 4
END_TEXT = {
    "Congratulations!",
    "You are a word wizard!",
    "Wispell finally gets to relax..."
}
END_TEXT_TOP_OFFY = 48
END_TEXT_LINE_VSPACE = 12

-- firework mean time to happen
END_FIREWORK_MTTH = 60 * 2
END_FIREWORK_CHANCE = 1 / END_FIREWORK_MTTH
END_FIREWORK_FLARE_TIME = 30
END_FIREWORK_FLARE_TIME_PER_FRAME = END_FIREWORK_FLARE_TIME / END_SPR_EXPLOSION_N_FRAMES
END_FIREWORK_FLARE_SPEED = 0.5

-- rectangular area that fireworks can target
END_FIREWORK_TARGET_TL = {x = SCREEN_W_px / 4, y = 8}
END_FIREWORK_TARGET_DIM = {x = SCREEN_W_px / 2, y = SCREEN_H_px / 4}
END_FIREWORK_SOURCE_TL = {x = SCREEN_W_px / 4, y = 3 * SCREEN_H_px / 2}
END_FIREWORK_SOURCE_DIM = {x = SCREEN_W_px / 2, y = 0}

-- pixels per second
END_FIREWORK_SPEED = 100
-- pixels per tick
END_FIREWORK_SPEED_PT = END_FIREWORK_SPEED / 60

END_SPR_WISPELL_ID = 202
END_WISPELL_BOOK_OFF_TX = 1
END_WISPELL_BOOK_OFF_TY = 1
END_WISPELL_TW = 5
END_WISPELL_TH = 4
END_WISPELL_TX = 20
END_WISPELL_TY = 13
END_SPR_TOWEL_ID = 224
END_SPR_TOWEL_TW = 6
END_SPR_TOWEL_TH = 2
END_SPR_TOWEL_OFFX = -8
END_SPR_TOWEL_OFFY = 16
END_SPR_BOOK_ANIM_ID = 176
END_SPR_BOOK_TW = 2
END_SPR_BOOK_TH = 2

--- how long between the start of Wispell turning the page on his book
END_PAGE_INTERVAL = 60 * 4
END_PAGE_N_FRAMES = 3
END_PAGE_TIME = 40
END_PAGE_FRAME_TIME = END_PAGE_TIME / END_PAGE_N_FRAMES

-- the firework only uses a particular color in the sprite data.
END_FIREWORK_BASE_PALETTE = PALETTE.ORANGE
-- the base color can be swapped with any of these
END_FIREWORK_PALETTE_SWAPS = {
    PALETTE.YELLOW,
    PALETTE.ORANGE,
    PALETTE.LIME,
    PALETTE.GREEN,
    PALETTE.RED
}

END_FIREWORK_GUARANTEE_TIME = 60 * 4

END_THANKYOU_OFFY = 4
END_THANKYOU_TEXT = "Thank you for playing!"
END_THANKYOU_W = print(END_THANKYOU_TEXT, SCREEN_W_px, SCREEN_H_px)
END_THANKYOU_OFFX = (SCREEN_W_px - END_THANKYOU_W) / 2

---@class StEnding : IAppState
---@field fireworkStates FireworkState[]
---@field nFireworks integer # not the same as the number of states, which include fragments
---@field ticksSinceLastFirework integer
---@field anyDetonating boolean
---@field congratsTicks integer
---@field textLineWidths integer[]
---@field pageTimer integer
StEnding = {}
setmetatable(StEnding, {__index = IAppState})

---@return StEnding
function StEnding.new()
    local state = {
        fireworkStates = {},
        nFireworks = 0,
        ticksSinceLastFirework = 0,
        anyDetonating = false,
        congratsTicks = END_CONGRATULATIONS_TIME,
        textLineWidths = {},
        pageTimer = 60
    }

    setmetatable(state, {__index = StEnding})

    state.nSyncDelayTicks = 2

    for _, line in ipairs(END_TEXT) do
        table.insert(state.textLineWidths, print(line, SCREEN_W_px, SCREEN_H_px))
    end

    return state
end

function StEnding:delayTick()
    if self.nSyncDelayTicks == 2 then
        sync(16 | 8, 0) -- change music and sfx
    elseif self.nSyncDelayTicks == 1 then
        sync(32 | 4 | 1, 2) -- change palette, map, tiles
    end
end

function StEnding:enter()
    if MusicEnabled then music(END_SONG_FANFARE) end
end

function StEnding:leave()
    vbank(0)
    sync(32, 0) -- restore palette to default
end

function StEnding:fire()
    self.ticksSinceLastFirework = 0
    self.nFireworks = self.nFireworks + 1

    local destX = END_FIREWORK_TARGET_TL.x + math.random() * END_FIREWORK_TARGET_DIM.x
    local destY = END_FIREWORK_TARGET_TL.y + math.random() * END_FIREWORK_TARGET_DIM.y

    local sourceX = END_FIREWORK_SOURCE_TL.x + math.random() * END_FIREWORK_SOURCE_DIM.x
    local sourceY = END_FIREWORK_SOURCE_TL.y + math.random() * END_FIREWORK_SOURCE_DIM.y

    local vecX = destX - sourceX
    local vecY = destY - sourceY
    local dist = math.sqrt(vecX * vecX + vecY * vecY)
    local tics = math.floor(0.5 + dist / END_FIREWORK_SPEED_PT)
    local dx = vecX / tics
    local dy = vecY / tics
    local palSwapIndex = math.random(1, #END_FIREWORK_PALETTE_SWAPS)
    local palSwap = END_FIREWORK_PALETTE_SWAPS[palSwapIndex]

    ---@type FireworkState
    local firework = {
        detoTime = tics,
        dx = dx,
        dy = dy,
        x = sourceX,
        y = sourceY,
        kind = 'launching',
        palIndex = palSwap
    }

    setmetatable(firework, {__index = FireworkState})

    sfx(END_SFX_FIREWORK_LAUNCH, 'C-7', tics, SFX_CHANNEL, SfxVol)

    table.insert(self.fireworkStates, firework)
end

function StEnding:drawStars()
    map(2 * SCREEN_W_tiles, 0, SCREEN_W_tiles, SCREEN_H_tiles)
end

function StEnding:drawTrees()
    map(SCREEN_W_tiles, 0, SCREEN_W_tiles, SCREEN_H_tiles, 0, 0, PALETTE.BLACK)
end

function StEnding:drawWispell()
    local wispellX = END_WISPELL_TX * TILE_W_px
    local wispellY = END_WISPELL_TY * TILE_H_px

    spr(
        END_SPR_TOWEL_ID,
        wispellX + END_SPR_TOWEL_OFFX,
        wispellY + END_SPR_TOWEL_OFFY,
        PALETTE.BLACK,
        1, 0, 0,
        END_SPR_TOWEL_TW,
        END_SPR_TOWEL_TH
    )

    spr(
        END_SPR_WISPELL_ID,
        wispellX,
        wispellY,
        PALETTE.BLACK,
        1, 0, 0,
        END_WISPELL_TW,
        END_WISPELL_TH
    )

    if self.pageTimer < END_PAGE_TIME then
        local whichPage = math.floor(self.pageTimer / END_PAGE_FRAME_TIME)
        local pageSpr = whichPage * END_SPR_BOOK_TW + END_SPR_BOOK_ANIM_ID
        spr(
            pageSpr,
            wispellX + END_WISPELL_BOOK_OFF_TX * TILE_W_px,
            wispellY + END_WISPELL_BOOK_OFF_TY * TILE_H_px,
            PALETTE.BLACK
        )
    end
end

function StEnding:drawHill()
    map(0, 0, SCREEN_W_tiles, SCREEN_H_tiles, 0, 0, PALETTE.BLACK)
end

function StEnding:draw()    
    vbank(self.anyDetonating and 1 or 0) -- use brighter palette if detonating

    if self.congratsTicks > 0 then
        for i, line in ipairs(END_TEXT) do
            local y = END_TEXT_TOP_OFFY + (i - 1) * END_TEXT_LINE_VSPACE
            local x = (SCREEN_W_px - self.textLineWidths[i]) / 2
            print(line, x, y, PALETTE.WHITE)
        end

        return
    end

    self:drawStars()
    self:drawTrees()

    for _, firework in ipairs(self.fireworkStates) do
        local sprite
        if firework.kind == 'launching' then
            sprite = END_SPR_FIREWORK_LAUNCH
        else
            sprite = END_SPR_EXPLOSION_START
            local detoLeft = END_FIREWORK_FLARE_TIME - firework.detoTime
            local frame = math.floor(
                    detoLeft / END_FIREWORK_FLARE_TIME *
                    END_SPR_EXPLOSION_N_FRAMES
                )
            sprite = sprite + frame
        end

        -- poke the palette swap
        local PALETTE_SWAP_ADDR = 0x3FF0 * 2 + END_FIREWORK_BASE_PALETTE
        poke4(PALETTE_SWAP_ADDR, firework.palIndex)

        spr(sprite, firework.x, firework.y, PALETTE.BLACK)

        poke4(PALETTE_SWAP_ADDR, END_FIREWORK_BASE_PALETTE)
    end

    self:drawHill()
    self:drawWispell()

    print(END_THANKYOU_TEXT, END_THANKYOU_OFFX, END_THANKYOU_OFFY, PALETTE.WHITE)
end

---@param mouse MouseState
---@returns AppState|nil
function StEnding:tick(mouse)
    if self.congratsTicks > 0 then
        self.congratsTicks = math.max(0, self.congratsTicks - 1)

        -- falling edge: change music
        if self.congratsTicks == 0 or mouse.leftTrans == 'down' then
            self.congratsTicks = 0 -- if left down, skip congrats
            if MusicEnabled then music(END_SONG_HAPPY) end
        end

        return
    end

    if mouse.leftTrans == 'down' then
        return StMainMenu.new()
    end

    if self.nFireworks < END_MAX_FIREWORKS and 
        math.random() < END_FIREWORK_CHANCE or
        self.ticksSinceLastFirework >= END_FIREWORK_GUARANTEE_TIME then
        self:fire()
    end

    -- seems like bad memory management but lua's GC seems good enough that
    -- this has worked fine so far (copy over live ones every frame to let
    -- GC eat the dead ones--saves having to delete from beginning/mid of list,
    -- but the best solution would be a pool/arena)
    local liveFireworks = {}
    self.anyDetonating = false
    for _, firework in ipairs(self.fireworkStates) do
        firework.detoTime = firework.detoTime - 1

        if firework.detoTime <= 0 and firework.kind == 'exploding' then
            goto continue
        end

        if firework.detoTime <= 0 then
            self.nFireworks = self.nFireworks - 1
            firework.kind = 'exploding'
            local sx = END_FIREWORK_FLARE_SPEED / math.sqrt(2)
            local sh = END_FIREWORK_FLARE_SPEED
            firework.dx = sx
            firework.dy = sx
            firework.detoTime = END_FIREWORK_FLARE_TIME

            table.insert(liveFireworks, firework:cloneWithSpeed(sx, -sx))
            table.insert(liveFireworks, firework:cloneWithSpeed(-sx, sx))
            table.insert(liveFireworks, firework:cloneWithSpeed(-sx, -sx))
            table.insert(liveFireworks, firework)
            table.insert(liveFireworks, firework:cloneWithSpeed(0, sh))
            table.insert(liveFireworks, firework:cloneWithSpeed(0, -sh))
            table.insert(liveFireworks, firework:cloneWithSpeed(sh, 0))
            table.insert(liveFireworks, firework:cloneWithSpeed(-sh, 0))
            self.anyDetonating = true

            sfx(END_SFX_FIREWORK_DETO, 'c-5', 60, SFX_CHANNEL, SfxVol)

            goto continue
        end

        table.insert(liveFireworks, firework)
        self.anyDetonating = self.anyDetonating or firework.kind == 'exploding'

        firework.x = firework.x + firework.dx
        firework.y = firework.y + firework.dy

        ::continue::
    end

    self.fireworkStates = liveFireworks

    if #liveFireworks == 0 then
        self.ticksSinceLastFirework = self.ticksSinceLastFirework + 1
    end

    if self.congratsTicks == 0 then
        self.congratsTicks = -1
        self:fire()
    end

    self.pageTimer = (self.pageTimer + 1) % END_PAGE_INTERVAL
end

MAX_LVL_REACHED_PMEM_ADDR = HIGH_SCORE_PMEM_ADDR + HIGH_SCORE_STRIDE * N_HIGH_SCORES

function LoadUnlockedSongs()
    local maxLevel = pmem(MAX_LVL_REACHED_PMEM_ADDR)
    while UnlockNextSongIfAble(maxLevel) do
        -- nothing else
    end
end

function UpdateMaxLevelReachedIfHigher(curLevel)
    local old = pmem(MAX_LVL_REACHED_PMEM_ADDR)
    local new = math.max(old, curLevel)
    pmem(MAX_LVL_REACHED_PMEM_ADDR, new)
end

function ClearMaxLevelReached()
    pmem(MAX_LVL_REACHED_PMEM_ADDR, 1)
end

---@param curLevel integer
---@return boolean # whether any songs were unlocked
function UnlockNextSongIfAble(curLevel)
    if #SongUnlockLevels == 0 then
        return false
    end

    local top = SongUnlockLevels[#SongUnlockLevels]
    if top > curLevel then return false end

    table.remove(SongUnlockLevels)
    table.insert(PlayList, table.remove(UnlockableSongs))
    return true
end



function ClearData()
    ClearHighScores()
    ClearMaxLevelReached()

    -- hardcoded: game is feature complete
    SongUnlockLevels = {16, 12, 8, 4}
    UnlockableSongs = {5, 4, 3, 2}
    -- TODO: if you add more songs, need to change in two places
end

---@type IAppState
local appState = nil

---@type MouseState
Mouse = nil

-- playlists were originally going to be a bit more involved. this vestigal
-- system is a little more complex than needed.

SongIdx = 1
-- PlayList = {1, 2, 3, 4, 5}
N_SONGS = #Songs
PlayList = { 1 }
SongUnlockLevels = {16, 12, 8, 4}
UnlockableSongs = {5, 4, 3, 2}
CurrentSongState = SongState.new(Songs[PlayList[SongIdx]])

MusicEnabled = true

SFX_VOL_ORIG = 15
SfxVol = SFX_VOL_ORIG
MuseVol = 1

MUSIC_ENABLED_PMEM_ADDR = MAX_LVL_REACHED_PMEM_ADDR + 1
SFX_ENABLED_PMEM_ADDR = MUSIC_ENABLED_PMEM_ADDR + 1
PMEM_ON = 2
PMEM_OFF = 1
-- 0 is the default PMEM value, so we need to distinguish it

function MusicOff()
    MusicEnabled = false
    music()
    pmem(MUSIC_ENABLED_PMEM_ADDR, PMEM_OFF)
end

function MusicOn()
    MusicEnabled = true
    pmem(MUSIC_ENABLED_PMEM_ADDR, PMEM_ON)
end

function ToggleMusic()
    if MusicEnabled then
        MusicOff()
    else
        MusicOn()
    end
end

function SfxOff()
    SfxVol = 0
    pmem(SFX_ENABLED_PMEM_ADDR, PMEM_OFF)
end

function SfxOn()
    SfxVol = 15
    pmem(SFX_ENABLED_PMEM_ADDR, PMEM_ON)
end

function ToggleSfx()
    if SfxVol == 0 then
        SfxOn()
    else
        SfxOff()
    end
end


function LoadMusicAndSoundState()
    local pmemMusic = pmem(MUSIC_ENABLED_PMEM_ADDR)
    local pmemSfx = pmem(SFX_ENABLED_PMEM_ADDR)

    MusicEnabled = pmemMusic == PMEM_ON or pmemMusic == 0
    SfxVol = (pmemSfx == PMEM_ON or pmemSfx == 0) and SFX_VOL_ORIG or 0

    -- not really required, but I want it to be clear when the default value
    -- was overwritten.
    pmem(MUSIC_ENABLED_PMEM_ADDR, MusicEnabled and PMEM_ON or PMEM_OFF)
    pmem(SFX_ENABLED_PMEM_ADDR, (SfxVol == 0) and PMEM_OFF or PMEM_ON)
end

---@param number integer
function SetSongIdx(number)
    music()
    SongIdx = number
    local chosen = Songs[PlayList[SongIdx]]
    CurrentSongState = SongState.new(chosen)
    -- CurrentSongState:play()
end

function SetRandomSong()
    local iplaylist = math.random(1, #PlayList)
    SetSongIdx(iplaylist)
end
-- DONE: why is it playing a random song instead of index 1 on boot?
-- Because songState:play() calls songState:nextFragment(), which 
-- calls sync. 
-- sync can only be called once per TIC, so after the first sync, I'm
-- guessing the others were dropped. the result was that the correct song state
-- was loaded but the fragment data was playing out of the wrong bank.

function SetNextSong()
    local next = SongIdx + 1
    if next > #PlayList then
        next = 1
    end
    SetSongIdx(next)
end

-- addresses of the 4 volume nybbles
-- stride is 18 bytes
VOLUME_BASE_ADDR4 = 0xFF9C * 2 + 3
VOLUME_STRIDE_ADDR4 = 18 * 2

-- change the last nybble of frequency for some weird pitch shifting
FREQ_SPOOKY_ADDR4 = VOLUME_BASE_ADDR4 - 1

---Don't actually use this function: it overwrites the envelopes
---@param vol integer
function SetVolume(vol)
    for channel=0, 3 do
        -- have to check if there is volume, if not, the wave will be all zeros,
        -- which the virtual sound chip interprets as noise which we will
        -- end up amplifying by mistake.
        local adr = VOLUME_BASE_ADDR4 + channel * VOLUME_STRIDE_ADDR4
        local currentVol = peek4(adr)
        if currentVol > 0 then
            poke4(adr, math.ceil((vol/15) * currentVol))
        end
    end
end

function AppStateTransition(newState)
    if appState and appState.leave then appState:leave() end
    appState = newState
    if appState.enter and not
        (appState.nSyncDelayTicks and appState.nSyncDelayTicks > 0)
    then appState:enter() end
end

function BOOT()
    LoadMusicAndSoundState()
    LoadUnlockedSongs()
    cls(0)
    sync(2, 1, false)
    appState = StLoading.new()
    -- appState = StIntro.new()
    -- AppStateTransition(StMainMenu.new())
    -- appState = StEnding.new()
    Mouse = MouseState.new()
end

function TIC()
    Mouse:poll()
    local tx = appState:tick(Mouse)

    CheckForCheatProgressAndEnableCheats()

    if tx then
        AppStateTransition(tx)
    end

    cls(PALETTE.BLACK)
    vbank(1)
    cls(PALETTE.BLACK)
    vbank(0)

    -- sync delay is for when entering a new state, if it requires waiting some
    -- frames to sync data into the proper banks (you can only call sync once
    -- per frame)
    if appState.nSyncDelayTicks and appState.nSyncDelayTicks > 0 then
        if appState.delayTick then appState:delayTick() end
        appState.nSyncDelayTicks = appState.nSyncDelayTicks - 1
        return
    elseif appState.nSyncDelayTicks and appState.nSyncDelayTicks == 0 then
        appState:enter()
        appState.nSyncDelayTicks = nil
    end


    appState:draw()

    ColorCyclePhase = (ColorCyclePhase + 1) % CYCLE_COLOR_TICS
end




-- <TILES>
-- 005:00000000000000000000000000000000000000000000000000000088000088aa
-- 006:00000000000000000000000000000000000000000088888888aaaaaaaa99aaaa
-- 007:00000000000000000000000000000000000000000000000088000000aa800000
-- 009:00000000000000000000000000000000000000000000000000000088000088aa
-- 010:00000000000000000000000000000000000000000088888888aaaaaaaaaaaaaa
-- 011:00000000000000000000000000000000000000000000000088000000aa800000
-- 013:00000000000000000000000000000000000000000000000000000088000088aa
-- 014:00000000000000000000000000000000000000000088888888aaaaaaaaaaaaaa
-- 015:00000000000000000000000000000000000000000000000088000000aa800000
-- 020:0000000000000000000000080000008a000008a900008aa90008aaaa008aaaaa
-- 021:0088aaaa88aaaaaaaaaaaaaaaa99aaaa99aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- 022:aaaa99aaaaaaaaaaaaaccaaaaaaccccaaaacccccaaacccccaaacc66caaac66f6
-- 023:aa800000aaa80000aaa80000aaa80000aaa80000caa80000caa80000caa80000
-- 024:0000000000000000000000080000008a000008a900008aa90008aaaa008aaaaa
-- 025:0088aaaa88aaaaaaaaaaaaaaaa99aaaa99aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- 026:aaaa99aaaa99aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa9aaaaa99caaa996f6
-- 027:aa800000aaa80000aaa80000aaa800009aa80000caa80000caa80000caa80000
-- 028:0000000000000000000000080000008a000008a900008aa90008aaaa008aaaaa
-- 029:0088aaaa88aaaaaaaaaaaaaaaa99aaaa99aaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- 030:aaaa99aaaa99aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- 031:aa800000aaa80000aaa80000aaa80000aaa80000aaa80000aaa80000aaa80000
-- 032:0000000000000000000000000000000000000000000000c000000cc000000cc0
-- 033:0000000000000000000000000000000000c0000000cc000000ccc00000ccc000
-- 036:08aaaaaa8aaaaaaa8aaaaaa98aaaaaac8aaaaaac8aaaaaaa08aaaaaa08aaaaaa
-- 037:aaaaaaaaaaaaaa9aaaaa996a99996f6accc6ff6accc6666aaccccccaaaaaaaaa
-- 038:aaac66f6aaac66f6aaacc66caaa9accaaaaa9aaaaaaa9aaaaa99aaaaaaaaaaaa
-- 039:caa80000caa80000aaa80000aaa80000aa800000aa800000aa800000a8000000
-- 040:08aaaaaa8aaaaaaa8aaaaaa98aaaaaac8aaaaaac8aaaaaaa08aaaaaa08aaaaaa
-- 041:aaaaaa9aaaaa996aaa996f6a99c6ff6accc6ff6accc6666aaccccccaaaaaaaaa
-- 042:aaac66f6aaac66f6aaacc66caaa9accaaaaa9aaaaaaa9aaaaa99aaaaaaaaaaaa
-- 043:caa80000caa80000aaa80000aaa80000aa800000aa800000aa800000a8000000
-- 044:08aaaaaa8aaaaaaa8aaaaaaa8aaaaaaa8aaaaaa98aaaaaaa08aaaaaa08aaaaaa
-- 045:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa9aaaaaaaa999999aaaaaaaaa
-- 046:aaaaaaaaaaaaaaaaaaaaaaa9aaa9a99aaaaa9aaaaaaa9aaaaa99aaaaaaaaaaaa
-- 047:aaa800009aa80000aaa80000aaa80000aa800000aa800000aa800000a8000000
-- 048:0000ccc0000cccc0000cccc00000ccc000000000000000000000000b00000000
-- 049:00ccc00000cc000000c00000000000000000000000b00000bb00000000000000
-- 052:008aaaaa008aaaaa0008aaaa00008aaa0000088a000000080000000000000000
-- 053:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa8aaaaaaa0888888800000000
-- 054:aaaaaaaaaaaa9aaaaa99aaa8a9aaaa80aaaa8800aa8800008800000000000000
-- 055:a000000080000000000000000000000000000000000000000000000000000000
-- 056:008aaaaa008aaaaa0008aaaa00008aaa0000088a000000080000000000000000
-- 057:aaaaaaaaaaaaaaaaaaaaaa9aaaaaaaa9aaaaaaaa8aaaaaaa0888888800000000
-- 058:aaaaaaaaaaa9aaaaaa9aaaa899aaaa80aaaa8800aa8800008800000000000000
-- 059:a000000080000000000000000000000000000000000000000000000000000000
-- 060:008aaaaa008aaaaa0008aaaa00008aaa0000088a000000080000000000000000
-- 061:aaaaaaaaaaaaaaaaaaaaaa9aaaaaaaa9aaaaaaaa8aaaaaaa0888888800000000
-- 062:aaaaaaaaaaa9aaaaaa9aaaa899aaaa80aaaa8800aa8800008800000000000000
-- 063:a000000080000000000000000000000000000000000000000000000000000000
-- 064:0000000000000099000009110000911100009111000911910009191100091912
-- 065:0000000090000000199000001119000014429900424421902421111921111999
-- 066:0000000000000000000000000000000000000000000009999999900000000000
-- 067:0000000000000000000000000000000000000000999900000000900000000900
-- 069:00000000000000000000000000000000000000000000000000000088000088aa
-- 070:00000000000000000000000000000000000000000088888888aaaaaaaaaaaaaa
-- 071:00000000000000000000000000000000000000000000000088000000aa800000
-- 073:00000000000000000000000000000000000000000000000000000088000088aa
-- 074:00000000000000000000000000000000000000000088888888a9aaaaaaaa9aaa
-- 075:00000000000000000000000000000000000000000000000088000000aa800000
-- 077:00000000000000000000000000000000000000000000000000000088000088aa
-- 078:00000000000000000000000000000000000000000088888888aaaaaaaaaaaaaa
-- 079:00000000000000000000000000000000000000000000000088000000aa800000
-- 080:0009192200091921000099110000091900000990000009000000900000090000
-- 081:11199000199000009000000000000000000000090000099a00009aaa0009aaaa
-- 082:000000000000000000000000099999009aaaaa90aaaaaaa9aaaaaaaaaaaaaaaa
-- 083:0000009000000090000000900000009000000900000090009099000099000000
-- 084:0000000000000000000000080000008a000008a900008aa90008aaaa008aaaaa
-- 085:0088aaaa88aaaaaaaaaaaaaaaa99aaaa99aaaaaaaaaaaaaaaacccccaacccccca
-- 086:aaaa99aaaa99aaaaaaaaaaaaaaaaaccaaaacccccaaacccccaaacc66caaac66f6
-- 087:aa800000aaa80000aaa80000aaa80000aaa80000caa80000caa80000caa80000
-- 088:0000000000000000000000080000008a000008aa00008aaa0008aaaa008aaaaa
-- 089:0088aaaa88a9aaaaaa9aaaaaa9aaaccaaaaacccaaaaccccaaacccccaacccccca
-- 090:aaaaa9aaaaaccaaaaaacccaaaaaccccaaaacccccaaacccccaaacc66caaac66f6
-- 091:aa800000aaa80000aaa80000aaa80000aaa80000caa80000caa80000caa80000
-- 092:0000000000000000000000080000008a0000089900008aaa0008aaaa008aaaaa
-- 093:0088aaaa88aaaaaaaaaaaaaaaaaaaaaaaaaaaaa99999aa9aaaaa99aaaaaaaaaa
-- 094:aaaaa9aaaa9aa9aaaaaa9aaaaaa9aaaaaaaaacccaaaaccccaaacc66caaac66f6
-- 095:aa800000aaa80000aaa80000aaa80000aaa80000caa80000caa80000caa80000
-- 096:0009000000900000009000000900000009000000900000009000000090000000
-- 097:009aaaaa09aaaaaa09aaaaaa09aaaaaa09aaaaaa009aaaaa0099aaaa99009aaa
-- 098:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa9aaaaaa90aaaaa909
-- 099:9000000090000000900000009000000090000000000000000990000090090000
-- 100:08aaaaaa8aaaaaac8aaaaaac8aaaaaac8aaaaaac8aaaaaaa08aaaaaa08aaaaaa
-- 101:cccccccacccc666accc66f6accc6ff6accc6ff6accc6666aaccccccaaaaaaaaa
-- 102:aaac66f6aaac66f6aaacc66caaa9accaaaaa9aaaaaaa9aaaaa99aaaaaaaaaaaa
-- 103:caa80000caa80000aaa80000aaa80000aa800000aa800000aa800000a8000000
-- 104:08aaaaaa8aaaaaac8aaaaaac8aaaaaac8aaaaaac8aaaaaaa08aaaaaa08aaaaaa
-- 105:cccccccacccc666accc66f6accc6ff6accc6ff6accc6666aaccccccaaaaaaaaa
-- 106:aaac66f6aaac66f6aaacc66caaa9accaaaaa9aaaaaaa9aaaaa99aaaaaaaaaaaa
-- 107:caa80000caa80000aaa80000aaa80000aa800000aa800000aa800000a8000000
-- 108:08aaaaaa8aaaaaaa8aaaaaa98aaaaaac8aaaaaac8aaaaaaa08aaaaaa08aaaaaa
-- 109:aaaaaaaaaaaaaa9aaaaa996a99996f6accc6ff6accc6666aaccccccaaaaaaaaa
-- 110:aaac66f6aaac66f6aaacc66caaa9accaaaaa9aaaaaaa9aaaaa99aaaaaaaaaaaa
-- 111:caa80000caa80000aaa80000aaa80000aa800000aa800000aa800000a8000000
-- 112:9000009990009900099900000000000000000099000009000000900000000900
-- 113:0000099900000900000990900990000990000000090000000090000000090000
-- 114:9999900900000090000000909000990009990000000000000000000000000000
-- 115:0000900000009000000090000000900000009000000090000000900000009000
-- 116:008aaaaa008aaaaa0008aaaa00008aaa0000088a000000080000000000000000
-- 117:aaaaaaaaaaaaaaaaaaaaaa9aaaaaaaa9aaaaaaaa8aaaaaaa0888888800000000
-- 118:aaaaaaaaaaa9aaaaaa9aaaa899aaaa80aaaa8800aa8800008800000000000000
-- 119:a000000080000000000000000000000000000000000000000000000000000000
-- 120:008aaaaa008aaaaa0008aaaa00008aaa0000088a000000080000000000000000
-- 121:aaaaaaaaaaaaaaaaaaaaaa88aaaaaaa8aaaaaaaa8aaaaaaa0888888800000000
-- 122:aa88aaaa8888aaaa888aaaa888aaaa80aaaa8800aa8800008800000000000000
-- 123:a000000080000000000000000000000000000000000000000000000000000000
-- 124:008aaaaa008aaaaa0008aaaa00008aaa0000088a000000080000000000000000
-- 125:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa8aaaaaaa0888888800000000
-- 126:aaaaaaaaaaaacaaaaaccaaa8cccaaa80aaaa8800aa8800008800000000000000
-- 127:a000000080000000000000000000000000000000000000000000000000000000
-- 129:0000000000000000000000000000000000000000000000000000000000000009
-- 130:0000000000000000000009990000911100991111091111119111111191111111
-- 131:0000000000000000800000001800000011880000111888001111118011111188
-- 137:00ccc0000cc00c00cc0ccc00c0cccc00c0ccccccc0ccccccc0cc0cccc0ccc0cc
-- 138:00000000000000000000000000000000ccccccccccccccccccccccccccc00000
-- 140:0000cccc000cc000000ccccc000ccccc000ccccc0000cccc0000cccc000ccccc
-- 141:00000000c000000000000000c0000000c0000000c0000000c0000000c0000000
-- 142:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaacaccaaccccccacccccc0
-- 143:aaaaaaaaaaaaaaaaaaaaaaaaaaaccacaccc00ccac00cc00c0cc000cccc00ccc0
-- 145:0000009900000091000009910000091100000911000091110000911100009111
-- 146:1111111111111111111111141111111311111121111112221111222211122222
-- 147:1144222844334222331144224114324234222440134443312333300100000111
-- 148:8000000088000000280000002080000001880009111809901111900011999000
-- 149:0000000000000000000008880099900099000000000000000000000000000000
-- 150:0000000008888800800000880000000000000000000000000000000000000000
-- 151:0000000000000000000000008000000008000000080000000800000008000000
-- 153:c0ccccccc0c0cccc0ccc0ccc00cccccc000ccccc0000cccc0000000000000000
-- 154:ccccccccccccccccccc00000ccccccccccc00cc0cccccc000000000000000000
-- 156:00cccc0c0cccc0cccccc0cccccc0ccc0cc0ccc0cc0ccc0cc0ccc0cc0000ccc00
-- 157:c0000000c0000000c0000000c0000000c0000000000000000000000000000000
-- 158:cccccccccccccccccccccccccccccccccccccccccccccc00cc00000c0ccccccc
-- 159:c0ccc00c0ccc00caccc0ccaacc0ccaaa00ccaaaa0ccaaaaaccaaaaaaaaaaaaaa
-- 161:0000911100009111000911110009111100091111009111110091111109111111
-- 162:1022222010222201102220111022011110201111100111191011199010199000
-- 163:11111111111111991111990011990000990000000000000000000088000088aa
-- 164:99000000000000000000000000000000000000000088888888aaaaaaaaaaaaaa
-- 165:00000000000000000000000000000000000000000000000088000000aa800000
-- 166:0000000000000000000000000000000000000008000000800000080000008000
-- 167:0800000008000000080000008000000000000000000000000000000000000000
-- 174:acccaaaac00caaaacc00aaaaac000aaaacc00caaaac00caaaaacccaaaaaaaaaa
-- 177:0911111909111990999990090000099000009000000900000090000099000000
-- 178:9990000090000000000000080000008a000008aa00008aaa0008aaaa008aaaaa
-- 179:0088aaaa88aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- 180:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- 181:aa800000aaa80000aaa80008aaa80080aaa88800aaa80000aaa80000aaa80000
-- 182:0088000008000000800000000000000000000000000000000000000000000000
-- 192:0000000900000090000009000000900000090000009000000900000009000000
-- 194:08aaaaaa8aaaaaaa8aaaaaaa8aaaaaaa8aaaaaaa8aaaaaaa08aaaaaa08aaaaaa
-- 195:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- 196:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
-- 197:aaa80000aaa80000aaa80000aaa80000aa800000aa800000aa800000a8000000
-- 202:0000000000000000000000000000000000000000000000000000000400000444
-- 203:0000000000000000000000000044000004444400444443304444333044433330
-- 208:9000000080000000800000000800000008000000008800000000888800000000
-- 209:0000000000000000000000000000000800008880888800008000000000000000
-- 210:008aaaaa008aaaaa0088aaaa88008aaa0000088a000000080000000000000000
-- 211:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa8aaaaaaa0888888876600000
-- 212:aaaaaaaaaaaaaaaaaaaaaaa8aaaaaa89aaaa8800aa8800008800000000000000
-- 213:a800000080000000099550009666655506666666006666690066669806666988
-- 214:0000000000000000000000005000000050000000900000009000000090000000
-- 216:0000000000000000000000000000000000000000000000000044444404444444
-- 217:0000000000000000000000000000000000444400444444444444444444444443
-- 218:0000444400044444004444440444444304444433464223336223233362332333
-- 219:4433333043333330333333303333333033333330333333303333333033333330
-- 225:0000000000000000000000000000000000000000000000070000000700000076
-- 226:0000077700777666076666667666666676666666666666666666666666666666
-- 227:6600000066000000660000006660000066666666666666696666699865599888
-- 228:0000000600000066000006990006998866998888998888888888888888848888
-- 229:6669988869988888988888888888848888844888844848898888488988884889
-- 230:9000000090000000900000009000000090000000000000000000000000000000
-- 232:2444444323333333233333332333333302333333023333330233333302333333
-- 233:3333333333333333333333333333333333333333333333333333333333333333
-- 234:6233233362332333623323336233233362333233632332336323323363233233
-- 235:3333333033333330333333303333333033333330333333203333320033332000
-- 241:0000076600007666000766660000755500000000000000000000000000000000
-- 242:6666665566665577555577709977770700977070009707070009707000090707
-- 243:5779888877798884707988880709888870799888070798887077998807077988
-- 244:8448888844888844844888848848888488448884888488848884488488884884
-- 245:4888488948848890488488904884889048848890488488904484889074848890
-- 248:0233333300233333002333330023333300233333000233330002333300022222
-- 249:3333333333333333333333333333333333333333333333333333333322222222
-- 250:6323323363233233632332336323332363323322333233203332220022200000
-- 251:3332000033200000320000002000000000000000000000000000000000000000
-- </TILES>

-- <TILES1>
-- 002:00000ffc0000fccc00ffccccccccccfcfcccccfcfccfccfffccfccfcfccfffcf
-- 003:ccf00000fcccf000ccccf0cccfccfdcccfccfdccffffccc0fccccc00ccccc000
-- 004:0000000000000000000000000000ffff0000ccccc00fcccccccfcccccccdffcc
-- 005:0000000000000000000000000ffff000dccccf00dccccff0dcdccfc0dcdcfccc
-- 011:0000000000000000000000000000000000000000000099990009111100091114
-- 012:0000000000000000000000000000000000000000999990001111180044111188
-- 018:fffcccfcccccfccc0ccccccc00cccccc00000000000000000000000000000000
-- 019:ccccc000ccc00000cc000000c000000000000000000000000000000000000000
-- 020:fcccddff0fccccdd00fccccc000ffccc00000fff000000000000000000000000
-- 021:ffffdcccddddcccfccccccf0cccccf00fffff000000000000000000000000000
-- 027:0091114300911242092222340222222302221111021111119111111191111111
-- 028:3341111114422111443222213322222111111221111111111111111111111118
-- 029:8000000080000000800000008000000018000000118000008888000000000000
-- 033:0000000000000000000000990000091100009111000911110009111100911111
-- 034:0000000000000000990000001190000011190000111190001111900011112900
-- 041:0000000900999990090000009000000008000000008888800000000800000000
-- 042:9999999900000000000000000000000000000000000000008888888800000000
-- 043:9999999900088888088aaaaa8aa9aaaa8aac999a8aaccc6a8aaac60a8aaaa60a
-- 044:8888888888888000aaaaa880aaaaa9a8aa999ca8aa6ccca8aa06caa8aa06aaa8
-- 045:8888888800000000000000000000000000000000000000008888888800000000
-- 046:8000000008888000000008800000000800000880088880008000000000000000
-- 048:0000000000000999088881118111111181111118811111810881181100088111
-- 049:0911111198111111811111118111111111111118118111821111881111181111
-- 050:1112290011222900822229008222199922211811221118811111188111111811
-- 051:0000000000000000000000009900000011999000111119901111111811111118
-- 059:08aaaaaa08aa999a008aaaa90008aaaa00008888000000000000000000000000
-- 060:aaaaaa80aaaaaa809aaaa800aaaa800088880000000000000000000000000000
-- 064:0081111800088888000000000000000000000000000000000000000000000000
-- 065:8888111180888881000999980000999900000999000000000000000000000000
-- 066:1188811111111118888888889999000099900000000000000000000000000000
-- 067:1111118088888800000000000000000000000000000000000000000000000000
-- 074:0000000000000000000000000000000000000007000006660006688800688888
-- 075:000000000000000000000000000000007777777767777bbb86667777b9866666
-- 076:0000000000000000000000000000000077777777bbb77776777766686666889b
-- 077:0000000000000000000000000000000070000000660000008860000088860000
-- 080:0000000000000000000000000000666600067777000987770009888800098888
-- 081:0000000000000000000000006666000077776666777bbbb788777bbb88888777
-- 082:0000000000000000000000000000000060000000766666007777776677777776
-- 088:000000000000000000ccccd00ccfcfcd0cfcfccd0ccccdc0000ccdc00000cdc0
-- 090:0009888800009888000009880000009900000000000000000000000000000000
-- 091:b9884448bb9884888b9888489bb9884809b98884009989990009900000090000
-- 092:8444889b884889bb484889b848489b8984889890999899000009900000009000
-- 093:8888600088890000889000009900000000000000000000000000000000000000
-- 095:000ccc0000ccccc00ccfcfccccfcdcccccccdccccdccdcc000ccdc0000ccd000
-- 096:0009888800008888000088880000088800000088000000880000008800000088
-- 097:88888888888888888888888888888888888bbb8888ffff888ffffff88ffffff8
-- 098:8888888988888889888888908888889088888800888880008888800088880000
-- 100:0000cdc00c0cdcdcccddcdccccccdcdccccccdc00ddccc00dccd00000ddd0000
-- 112:0000008800000088000000800000000000000000000000000000000000000000
-- 113:fffffff8f0fffff8000000f80000000800000008000000000000000000000000
-- 114:8880000088000000880000008000000000000000000000000000000000000000
-- 116:0000cdc0000cdcdc00cdcdcc0cccdcd0cccccdc00ddcccccdccdccd00ddd0000
-- 130:0000000000000000000000000000000000000000000000000000000900000091
-- 131:0000000000000000000000000000000000999998991111111111111111111111
-- 132:0000000000000000000000000000000088888880111111181111111111111111
-- 133:0000000000000000000000000000000000000000800000001800000018000000
-- 138:0000000000000000000000090000009100000911000009110000091100009111
-- 139:0099999899111111111111111111111111111111111111441112243322222422
-- 140:8888888011111118111111111111111111111111444111113334221124442222
-- 141:0000000080000000180000001800000011800000118000001188000011180000
-- 146:0000091100000911000009110000911100009122000022220000222200022222
-- 147:1111111111111144111224332222242222222420222224222222234422200033
-- 148:1111111144411111333422112444222243342222222422224443222233300222
-- 149:1180000011800000118800001118000022188000222118002222108022228108
-- 154:0000912200002222000022220002222200022222000222000002001100091111
-- 155:2222242022222422222223442220003300011100111111111111111111111111
-- 156:4334222222242222444322223330022200011000111111111111111111111111
-- 157:2218800022211800222210802222810822228010002281011102888811108000
-- 158:0000000000000000000000000000000080000000080000008880000000000000
-- 160:0000000000000000000000000000000000000000000000000000009900099900
-- 161:0000000000000000000000000000000000000000000009999999900000000000
-- 162:0002222200022200000200110009111100091111999999990000000000000000
-- 163:0001110011111111111111111111111111111111999999990000000000000000
-- 164:0001100011111111111111111111111111111111999999990000000000000000
-- 165:2222801000228101110288881110800011118000999999990000000000000000
-- 166:8000000008000000888000000000000000000000999900000000999900000000
-- 167:0000000000000000000000000000000000000000000000009900000000999000
-- 168:0000000000000000000000990009990009900000900000000880000000088800
-- 169:0000000000000999999990000000000000000000000000000000000000000000
-- 170:000911119999999900000000000000000000088800888aaa008aaa99008aaacc
-- 171:1111111199999999000000000000000088888888aaaaaaaaaaaaaaaa99aaaaaa
-- 172:1111111199999999000000000000000088888888aaaaaaaaaaaaaaaaaaaaaaa9
-- 173:1111800099999999000000000000000088800000aaa88800aaaaa80099aaa800
-- 174:0000000099990000000099990000000000000000000000000000000000000000
-- 175:0000000000000000990000000099900000000990000000090000088000888000
-- 176:0990000090000000099000000009990000000099000000000000000000000000
-- 177:0000000000000000000000000000000099999000000009990000000000000000
-- 178:0000088800888aaa008aaaaa008aaaaa008aaaa9998aaa9a008aaaaa008aaaaa
-- 179:88888888aaaaaaaaaaaaaaaa9999aaaaaaaa9aaaaaaaa9aaaaaaa9aaaaaaa9aa
-- 180:88888888aaaaaaaaaaaaaaaaaaaa999aaaa9aaa9aa9aaaaaaa9aaaaaaaaaaaaa
-- 181:88800000aaa88800aaaaa800aaaaa800aaaaa8009aaaa8999aaaa800aaaaa800
-- 182:0000000000000000000000000000000000009999999900000000000000000000
-- 183:0000099000000009000009900099900099000000000000000000000000000000
-- 184:0000008800000000000000000000000000000000000000000000000000000000
-- 185:8888800000000888000000000000000000000000000000000000000000000000
-- 186:008aaacc888aaacc008aaacc008aaaac008aaaaa008aaaaa0008aaaa0008aaaa
-- 187:cc9999aaccccccaaccc66caacc6666aacc6006aaaa6006aaaaaaaaaaaaaaaaaa
-- 188:aa99999caaccccccaac66cccaa6666ccaa6006cca99006caaa9aaaaaa9aaaaaa
-- 189:ccaaa800ccaaa888caaaa800caaaa800aaaaa800aaaaa800aaaa8000aaaa8000
-- 190:0000888888880000000000000000000000000000000000000000000000000000
-- 191:8800000000000000000000000000000000000000000000000000000000000000
-- 194:008aaaaa008aaaaa0008aaaa0008aaaa0008aaaa00008aaa000008aa0000008a
-- 195:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaacccaaaaaaccaaaaaaac
-- 196:a99aaaaaaa9aaaaaa9aaaaaaaaaaaaaaaaccccaaccccccaacccccaaaccccaaaa
-- 197:aaaaa800aaaaa800aaaa8000aaaa8000aaaa8000aaa80000aa800000a8000000
-- 202:0008aaa900008aaa000008aa0000008a00000008000000000000000000000000
-- 203:aaaaaaaa9999aaaaaaaa9aaaaaaaa9aa8aaaaaaa0888aaaa0000888800000000
-- 204:aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa8aaaa88808888000000000000
-- 205:aaaa8000aaa80000aa800000a800000080000000000000000000000000000000
-- 210:0000000800000000000000000000000000000000000000000000000000000000
-- 211:8aaaaaaa0888aaaa000088880000000000000000000000000000000000000000
-- 212:aaaaaaa8aaaa8880888800000000000000000000000000000000000000000000
-- 213:8000000000000000000000000000000000000000000000000000000000000000
-- 217:0000000000000000000000000000000600000668000668880660808800900888
-- 218:00000000000000660666667766777777b6666677b9888866b9888888b9888888
-- 219:00000000666666667777bbbb7bbbbbbb7777bbbb666666668888888844444888
-- 220:0000000066666666bbbbb777bbbbbbbbbbbbb777666666668888888888844444
-- 221:0000000066600000777666667777766677766966666899bb88889b8888899b88
-- 222:00000000000000006000000066600000b8866000888086008800090008009000
-- 224:0000c000000ccc0000cccc0000cccc0000cccdcd00ccdcdc00cdccdc00cccdcd
-- 225:000000000000000000000000ddddd000cccccd00ccccccd0ccccccd0dddddd00
-- 226:00000000000000000000000c000cc0cc00cccdcc0ccccdcdccccdccccccdcccc
-- 227:00cc0000cccdc000ccdccd00cdccdcc0dccdccd0ccdccdc0cdccdcc0cccdccc0
-- 233:0009000800009000000009000000009000000090000000090000000000000000
-- 234:8b98888888b98888088b98888088b9880008b998008088989999999800000099
-- 235:8848888888488888888488888884888888884888888848888888848488888484
-- 236:8888848888888488888848888888488848848888488488888484888884488888
-- 237:8899b888889b8808889b8880889b808088988800889999998990000089000000
-- 238:8009000000900000090000009000000090000000000000000000000000000000
-- 240:00ccdccc00ccdccc00cccdcd00cccdcc000cccdc0000cccd00000ccc00000000
-- 241:ccccccd0ccccccd0dddddd00ccccccd0ccccccd0dddddd00cccc000000000000
-- 242:cccccccccccccccccccccccc0ccccccc0cccccccceeccccc0ceeeecc00cccee0
-- 243:ccdccc00ccccc000cccc0000ccc00000cc000000c00000000000000000000000
-- 250:0000000900000009000000090000000000000000000000000000000000000000
-- 251:8888884888888848988888889888888898889999989990009990000090000000
-- 252:8848888888488888888888888888888899999988000009980000009900000000
-- 253:8900000089000000990000009000000090000000900000009000000090000000
-- </TILES1>

-- <TILES2>
-- 001:00000c00000000000000000000000000000000000000000000000000c000000c
-- 002:000000000000000c000000000004000000000000000000000000000000000000
-- 003:000000000000000000c000000000000000000000000000000000900000000000
-- 004:0000000000000000000000000000000000000c00000000000000000000000000
-- 005:0000000000000000000009000000000000000000000000000000000000000000
-- 006:000000000000000000000000000000000000000000000000000000c000000000
-- 007:00000000000000000000000d0000000d000000d8000000d800000d9900000d88
-- 008:0000000000000000d0000000d00000008d0000008d00000088d0000088d00000
-- 017:0000000000000000000000000000000000000000000000000000000000c00000
-- 018:000000000000000c00000000000000000000000090000000000000000000000c
-- 019:000000000000000000000000000000000000000000000000000000c000000000
-- 020:000000000000040000000000000000000000000000000000000000c000000000
-- 021:000000000000000000c000000000000000000000000000000000000000000000
-- 022:000000000000000000000000000000000000000000000000000c000000000000
-- 023:0000d8880000d888000d8899000d888800d8888800d899880d8888880d888888
-- 024:899d0000888d00008888d0008888d00089988d0088888d00888888d0888888d0
-- 026:0c000000ccc000000c0000000000000000000000000000000000000000000000
-- 027:3003300300033000003333003333333333333333003333000003300030033003
-- 028:3003300300333300033333303330033333300333033333300033330030033003
-- 029:3003300300333300030000303300003333000033030000300033330030033003
-- 030:0003300000300300030000303000000330000003030000300030030000033000
-- 031:0003300000000000000000003000000330000003000000000000000000033000
-- 032:0000000000770000070770770770777707077707777777777777770707707077
-- 033:0777000070707007770707077770707777770770777070777777077777777070
-- 034:7000000077070000770770000770700070707700777077017770777077077770
-- 035:0000000000000007000000711001000710011000101000770100007701001177
-- 036:0000000000000077700000771000070101007170010017177770177077701017
-- 037:0000000000007000000777001017700011100000117707701077777070117700
-- 038:0000000000000000000700000077000000777000077177000017700000170000
-- 039:0dfffffe0dffffe40dfffe440dfffe440dfffe440deefe440dfffeee0dfeffff
-- 040:efffffd04efeffd044efffd044efffd044efefd044efffd0eeefffd0ffffefd0
-- 041:0000000000000000000000000000000000000400000000000000000000000000
-- 042:0000000000000000000000000000c00000000000000000000000000000000000
-- 043:000000000000000000000000000c000000000000000000000000000000000000
-- 044:0000000000000000000000000000000000000000000000000000000000c00000
-- 045:0000000000000000000000000000000000000000000c00000000000000000000
-- 046:0000000000000000000040000000000000000000000000000000000000000000
-- 048:0077177700001700000077700007777700007770000017000000100000001000
-- 049:7177777071770777010077770100777700107717001007170010001000100010
-- 050:1077777110777770707770707077707070770770177777001071700010010000
-- 051:0101007711100770010077770111770701000071010000011100070111007771
-- 052:0770107777771707007717010771007777010077700770010001000100010001
-- 053:7110000071000000117000071170000011000000110000771107007111770001
-- 054:0100000071000000700770001017700011000000100000001000000010000000
-- 055:0dfeffef0de4efff0de44eff0de44efe0de44eff0de44eff0dfeefff0dffffef
-- 056:feffefd0fffe4ed0ffe44ed0efe44ed0ffe44ed0ffe44ed0fffeefd0feffffd0
-- 057:000000000000000000c000000000000000000000000000090000000000000000
-- 058:0000000000000000000000000000000000000000000000000000000c00000000
-- 059:0000000000000000000000000004000000000000000000000000000000000000
-- 060:0000000000000000000000000000000000c00000000000000000000000000000
-- 062:0000000000000000000000000000000000000000009000c00000000000000000
-- 064:0000000000000000000007770000777700777777007777770077777700077777
-- 065:0000000000000000000077707007777777077777770077707700010070077700
-- 066:0000000000000000077000000717000100710001000770010007700100071701
-- 067:0000000707700007117770001770777000007771007700070777001701700071
-- 068:7700000077700007100000071070007707770077701007771100077777700777
-- 069:0000000000000000077000007777770077777777777777777777777777777777
-- 071:0dffffff0dffffef0dfeffff0dffffff0dfffefe0dffffff0dfeffef0dffffff
-- 072:ffffffd0feffffd0feffefd0ffffffd0ffefffd0ffffffd0feffefd0ffffffd0
-- 080:0770077007770170777770107707701077001017010710100177771000000000
-- 081:1077770717770177017001777700770077007700070001000100010000000000
-- 082:0000177107000101070001077770710171700101010701010107010100000000
-- 083:1000010100007100000711010000711000100100001001000010010000000000
-- 084:7700777710077717000001771000010010001000100010001000100000000000
-- 085:7777770077701000710710007177700701777077110010011000100100000000
-- 086:7000000017700000777000001770000010000000700000000000000000000000
-- 087:0deffffe0dffeeff0dfffffe0dfeffe40dfffe440deffe440dfffe4400feeee4
-- 088:effffed0ffeeffd0efffffd04effefd044efffd044effed044efffd04eeeef77
-- 098:0000000000000000000000000000000000000000000000000000000000000077
-- 099:0000000000000000000000000000000000000777007777f7777f7f7ff7f7f7f7
-- 100:0000000000000000000077777777f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 101:00000000777777777f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 102:77777777f7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 103:7f7f7ff1f7f7f7f17f7f7f11f7f7ff117f7ff111f7ff11117f7ff111f7f7ff11
-- 104:1f7f7f7f1ff7f7f71f7f7f7f1ff7f7f7ff7f7f7ff7f7f7f7ff7f7f7f11fff7f7
-- 105:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 106:00000000f7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 107:00000000000000007f7f0000f7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 108:000000000000000000000000000000007f700000f7f7f7007f7f7f7ff7f7f7f7
-- 109:0000000000000000000000000000000000000000000000000000000077000000
-- 114:0000007f000000f70000007f000000f70000007f000000f70000007f000000f7
-- 115:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 116:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 117:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 118:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 119:7f7f7ff1f7f7ff117f7f1111f7f111117f111111ff1111117f111111ff111111
-- 120:111f7f7f11f7f7f71fff7f7ffff7f7f7ff7f7f7ff7f7f7f7ff7f7f7f1ff7f7f7
-- 121:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 122:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 123:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 124:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 125:7f000000f70000007f000000f70000007f000000f70000007f000000f7000000
-- 133:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 134:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 135:7ff11111f7f111117f7f1111f7ff11117fff1111ff111111f111111111111111
-- 136:11ff7f7f11f7f7f7111f7f7f111ff7f71111ffff1111111f1111111111111111
-- 137:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7ff7f7f7ff7f7f7f7
-- 138:7777777777777777777777777777777777777777777777777f7f7f7ff7f7f7f7
-- 139:7777777777777777777777777777777777777777777777777f7f7f7ff7f7f7f7
-- 140:7f7f7000f7f070007f070000f070070007070000700000000707000000000000
-- 149:00000000000000000000000000000000000000000000000f0000000f0000000f
-- 150:7f7f7ffff7f7ff117f7ff111ff7f11117f111111111111111111111111111111
-- 151:1111111111111111111111111111111111111111111111111111111111111111
-- 152:1111111111111111111111111111111111111111111111111111111111111111
-- 153:ff7f7f7f11f7f7f7111f7f7f111ff7f71111ff7f1111f7f71111ff7f1111f7f7
-- 154:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f71f7f7f7f17f7f7f7117f7f7f1111f7f7
-- 155:7f7f7f7f11f7f7f7111f7f7f1117f7f711117f7f111117f71111117f11111111
-- 176:00000000000000000000000c000000cc000000ce00000ccc0000cccc0000cc02
-- 177:0ccc0000ccccc000ccccc000ecccc000cceec000eccc0000ccc00000c2200000
-- 178:0000000000000ccc0000000c000000cc000000ce00000ccc0000cccc0000cc02
-- 179:00000000ccc00000ccccc000ecccc000cceec000eccc0000ccc00000c2200000
-- 180:00000000000000000000000c0000cccc000ccccc00000ccc0000cccc0000cc02
-- 181:0000000000000000ccccc000ccccc000ccccc000cccc0000ccc00000c2200000
-- 184:7f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f77f7f7f7ff7f7f7f7
-- 192:0000cdd00000dccd00000dd00000000000000000000000000000000000000000
-- 193:2200000000000000000000000000000000000000000000000000000000000000
-- 194:0000cdd00000dccd00000dd00000000000000000000000000000000000000000
-- 195:2200000000000000000000000000000000000000000000000000000000000000
-- 196:0000cdd00000dccd00000dd00000000000000000000000000000000000000000
-- 197:2200000000000000000000000000000000000000000000000000000000000000
-- 198:7878787887878788787878888787888878788888878878887878888888888888
-- 199:7878787888888888888888887888788888888888888888888888888887888888
-- 200:8787878788888878888887878888888888888887878888888888888788888888
-- 204:0000000000000000000000000000001100000112000011220000122200001222
-- 205:0000000000000000000000011110011222211222221222222112222212122221
-- 206:0000000000000000100000002110000022100000221000002210000012100000
-- 209:00000000000000000000000000000000000eeeee0ee0000000eee00000e00ee0
-- 210:00000000000000000000000000000000eeeeeee00000000e0000000000000000
-- 211:0000000e000000ef000000ef00000eee00000effe000efff0ee0eeee000effff
-- 212:eeeeeeeeffffffffffffffffeeeeeeeeffffffffffffffffeeeeeeeeffffffff
-- 213:eeeeee00ffffe000ffffe000eeee0000fffe0000ffe00000eee00000fe000000
-- 214:7888888888788878788888888888888878888888888788787888888887888888
-- 215:8888888888878878888888888788888888887888888888888788887888888888
-- 216:8888878788888888888888878878888888888887888888888888888788888888
-- 218:00000000000000000000000000000000000eeeee0eefffff00eeefff00e00eef
-- 219:00000000000000000000000c000000cce77772cef7999cccf779ccccff77ccf2
-- 220:00001222cccc1222ccecc122ecccc122cceec112eccc7711ccc77771c227ffff
-- 221:121222121221111221222122221112222222222222222221122222111111111f
-- 222:121000002110000011100000101000001000000010000000eee00000ffe00000
-- 224:0000000000000000000000000000066600000006000000000000000000000000
-- 225:0000000000000000000000006666666668888888066888880006688800000668
-- 226:0000000000000000000000006666666688888886888888888888888888888888
-- 227:0000000000000000000000000000000066000000866600008886660088888666
-- 230:7878878887878888787878888787878878787878878787877878787887878787
-- 231:8887888888888888788887888888888878787878878787877878787887878787
-- 232:8887888788888888888888878888887887878787787878788787878778787878
-- 234:000ee00e00000ee000000e0e00000e0000000e0000000e000000000000000000
-- 235:efffcddf0eefdccde00eeddf0ee00eef000ee00e00000eee0000000e00000000
-- 236:227efffff7eeeeee77effffffeffffffeeeeeeeeeeeeeeeeee000000e0000000
-- 237:ffffffffeeeeeeeefffffffffffffffeeeeeeeeeeeeeee000eee000000e00000
-- 238:fe000000e0000000e00000000000000000000000000000000000000000000000
-- 241:0000000600000000000000000000000000000000000000000000000000000000
-- 242:6888888806688888000668880000066800000006000000000000000000000000
-- 243:8888888688888888888888888888888868888888066666660000000000000000
-- 244:6600000086660000888666008888866688888886666666660000000000000000
-- 245:0000000000000000000000006000000066600000666600000000000000000000
-- 252:e0000000e0000000e00000000000000000000000000000000000000000000000
-- 253:00e0000000e0000000e000000000000000000000000000000000000000000000
-- </TILES2>

-- <SPRITES>
-- 014:0222222222222222222222222222222222222222222222222222222222222222
-- 015:2222220022222220222222232222222322222223222222232222222322222223
-- 030:2222222222222222222222222222222222222222222222220222222203333333
-- 031:2222222322222223222222232222222322222223222222232222223333333330
-- 046:0444443044444443444444434444444344444443444444433444443303333330
-- 096:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 097:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 098:0000000000aaaaa000a000a000a000a000a000a00aa00aa00aa00aa000000000
-- 099:0000000000000a00000a00a00aaa00a00aaa00a0000a00a000000a0000000000
-- 100:0000000000a0a00000a0aa0000a0aaa000a0aaa000a0aa0000a0a00000000000
-- 101:0aaaaaa00a0000a00a0000a00a0000a00a0220a00a2222a00a0220a000022000
-- 109:ccc22ccccc2222ccc222222cc000000ccccccccccccccccccccccccccccccccc
-- 110:22222ccc22220ccc2220cccc220ccccc20cccccc0ccccccccccccccccccccccc
-- 111:22222ccc02222cccc0222ccccc022cccccc02ccccccc0ccccccccccccccccccc
-- 112:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 113:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 114:2000000202aaaa20002002a000a020a000a200a00a2002a002a00a2020000002
-- 115:2000000202000a20002a02a00aaa20a00aa200a0002a02a002000a2020000002
-- 116:0000000000a0aa0000a000a000a00a0000a0a0000000000000a0a00000000000
-- 125:c222222cc022220ccc0220ccccc00ccccccccccccccccccccccccccccccccccc
-- 126:cccc2cccccc22ccccc222cccc2222ccc22222ccc00000ccccccccccccccccccc
-- 127:2ccccccc22cccccc222ccccc2222cccc22222ccc00000ccccccccccccccccccc
-- 128:ccccccccccccccc1cccccc11cccccc11ccccc111ccccc11ccccc111ccccc11cc
-- 129:cccccccccccccccc1ccccccc1ccccccc11cccccc11cccccc111cccccc11ccccc
-- 130:cccccccccc111111cc111111cc111ccccc11cccccc11cccccc11cc11cc11cc11
-- 131:cccccccc11cccccc111cccccc111cccccc11cccccc11cccc111ccccc1111cccc
-- 132:ccccccccccccc111cccc1111ccc111ccccc11cccccc11cccccc11cccccc11ccc
-- 133:cccccccc1111cccc11111cccccc11ccccccc1ccccccccccccccccccccccccccc
-- 134:ccccccccccc11111ccc11111ccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 135:cccccccc111ccccc1111cccccc111cccccc11cccccc11cccccc11cccccc11ccc
-- 136:ccccccccccc11111ccc11111ccc11cccccc11cccccc11cccccc11111ccc11111
-- 137:cccccccc11111ccc11111ccccccc1ccccccccccccccccccc11cccccc11cccccc
-- 138:ccccccccccc11111ccc11111ccc11cccccc11cccccc11cccccc11111ccc11111
-- 139:cccccccc11111ccc11111ccccccc1ccccccccccccccccccc11cccccc11cccccc
-- 140:cccccccccccc1111ccc11111ccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 141:cccccccc11111ccc11111ccccccc1cccccccccccccccccccccccccccc1111ccc
-- 142:cccccccccc11cccccc11cccccc11cccccc11cccccc11cccccc111111cc111111
-- 143:ccccccccccc11cccccc11cccccc11cccccc11cccccc11ccc11111ccc11111ccc
-- 144:ccc11111ccc11111cc111ccccc111ccccc11cccccc11cccccccccccccccccccc
-- 145:1111cccc1111cccccc111ccccc111cccccc11cccccc11ccccccccccccccccccc
-- 146:cc11cccccc11cccccc11cccccc111ccccc111111cc111111cccccccccccccccc
-- 147:cc111cccccc11cccccc11cccccc11ccc11111ccc1111cccccccccccccccccccc
-- 148:ccc11cccccc11cccccc11cccccc111cccccc1111ccccc111cccccccccccccccc
-- 149:cccccccccccccccccccc1cccccc11ccc11111ccc1111cccccccccccccccccccc
-- 150:ccc11cccccc11cccccc11cccccc11cccccc11111ccc11111cccccccccccccccc
-- 151:ccc11cccccc11cccccc11ccccc111ccc1111cccc111ccccccccccccccccccccc
-- 152:ccc11cccccc11cccccc11cccccc11cccccc11111ccc11111cccccccccccccccc
-- 153:cccccccccccccccccccccccccccc1ccc11111ccc11111ccccccccccccccccccc
-- 154:ccc11cccccc11cccccc11cccccc11cccccc11cccccc11ccccccccccccccccccc
-- 155:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 156:ccc11cccccc11cccccc11cccccc11cccccc11111cccc1111cccccccccccccccc
-- 157:c1111cccccc11cccccc11cccccc11ccc11111ccc1111cccccccccccccccccccc
-- 158:cc11cccccc11cccccc11cccccc11cccccc11cccccc11cccccccccccccccccccc
-- 159:ccc11cccccc11cccccc11cccccc11cccccc11cccccc11ccccccccccccccccccc
-- 160:cccccccccc111111cc111111cccccc11cccccc11cccccc11cccccc11cccccc11
-- 161:cccccccc11111ccc11111ccc1ccccccc1ccccccc1ccccccc1ccccccc1ccccccc
-- 162:ccccccccccc11111ccc11111cccccccccccccccccccccccccccccccccccccccc
-- 163:cccccccc11111ccc11111ccccc11cccccc11cccccc11cccccc11cccccc11cccc
-- 164:ccccccccc111cccccc11cccccc11cccccc11ccc1cc11cc11cc11c111cc11111c
-- 165:ccccccccc111ccccc111cccc111ccccc11cccccc1ccccccccccccccccccccccc
-- 166:ccccccccc111cccccc11cccccc11cccccc11cccccc11cccccc11cccccc11cccc
-- 167:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 168:cccccccccccc1cccccc111cccc111111cc111111cc11cc11cc11ccc1cc11ccc1
-- 169:cccccccccc1cccccc111cccc11111ccc11111ccc1cc11cccccc11cccccc11ccc
-- 170:cccccccccc11cccccc111ccccc1111cccc11111ccc11c111cc11cc11cc11ccc1
-- 171:ccccccccccc11cccccc11cccccc11cccccc11cccccc11ccc1cc11ccc11c11ccc
-- 172:cccccccccccc1111ccc11111cc111ccccc11cccccc11cccccc11cccccc11cccc
-- 173:cccccccc111ccccc1111cccccc111cccccc11cccccc11cccccc11cccccc11ccc
-- 174:cccccccccc111111cc111111ccc11cccccc11cccccc11cccccc11cccccc11111
-- 175:cccccccc111ccccc1111cccccc11cccccc11cccccc11cccccc11cccc1111cccc
-- 176:cccccc11cccccc11cccccc11cccccc11cc111111cc111111cccccccccccccccc
-- 177:1ccccccc1ccccccc1ccccccc1ccccccc11111ccc11111ccccccccccccccccccc
-- 178:ccc11111ccc11111cccc11cccccc11cccccc11cccccc1111ccccc111cccccccc
-- 179:cc11cccccc11cccccc11cccccc11cccccc11cccc1111cccc111ccccccccccccc
-- 180:cc111111cc11cc11cc11ccc1cc11cccccc11ccccc111cccccccccccccccccccc
-- 181:cccccccc1ccccccc11cccccc111cccccc111ccccc111cccccccccccccccccccc
-- 182:cc11cccccc11cccccc11cccccc11cccccc111111c1111111cccccccccccccccc
-- 183:ccccccccccccccccccccccccccc1cccc1111cccc1111cccccccccccccccccccc
-- 184:cc11cccccc11cccccc11cccccc11cccccc11cccccc11cccccccccccccccccccc
-- 185:ccc11cccccc11cccccc11cccccc11cccccc11cccccc11ccccccccccccccccccc
-- 186:cc11cccccc11cccccc11cccccc11cccccc11cccccc11cccccccccccccccccccc
-- 187:11111cccc1111ccccc111cccccc11cccccc11cccccc11ccccccccccccccccccc
-- 188:cc11cccccc11cccccc11cccccc111cccccc11111cccc1111cccccccccccccccc
-- 189:ccc11cccccc11cccccc11ccccc111ccc1111cccc111ccccccccccccccccccccc
-- 190:ccc11111ccc11cccccc11cccccc11ccccc1111cccc1111cccccccccccccccccc
-- 191:111ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 192:cccccccccccc1111ccc11111cc111ccccc11cccccc11cccccc11cccccc11cccc
-- 193:cccccccc111ccccc1111cccccc111cccccc11cccccc11cccccc11cccccc11ccc
-- 194:ccccccccccc11111ccc11111cccc11cccccc11cccccc11cccccc11cccccc1111
-- 195:cccccccc1111cccc11111cccccc11cccccc11cccccc11ccccc111ccc1111cccc
-- 196:ccccccccccccc111cccc1111ccc111ccccc11cccccc11cccccc11111cccc1111
-- 197:cccccccc1111cccc1111cccccccccccccccccccccccccccc111ccccc1111cccc
-- 198:cccccccccc111111cc111111cccccc11cccccc11cccccc11cccccc11cccccc11
-- 199:cccccccc11111ccc11111ccc1ccccccc1ccccccc1ccccccc1ccccccc1ccccccc
-- 200:cccccccccccccccccc1111ccccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 201:cccccccccccccccccc1111ccccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 202:cccccccccccccccccc1111ccccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 203:cccccccccccccccccc1111ccccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 204:cccccccccccccccccccccccccc11cccccc11cccccc11cccccc11cccccc11cccc
-- 205:ccccccccccccccccccccccccccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 206:cccccccccccccccccc11cccccc111cccccc111cccccc111cccccc111cccccc11
-- 207:ccccccccccccccccccc11ccccc111cccc111cccc111ccccc11cccccc1ccccccc
-- 208:cc11cccccc11cccccc11cccccc111cccccc11111cccc1111cccccccccccccccc
-- 209:ccc11ccc11c11ccc11111cccc111cccc11111ccc11c11ccccccccccccccccccc
-- 210:cccc1111cccc11cccccc11cccccc11cccccc11ccccc1111ccccccccccccccccc
-- 211:1111cccccc111cccccc11cccccc11cccccc11ccccc1111cccccccccccccccccc
-- 212:ccccccccccccccccccccccccccccccccccc11111ccc11111cccccccccccccccc
-- 213:cc111cccccc11cccccc11cccccc11ccc11111ccc1111cccccccccccccccccccc
-- 214:cccccc11cccccc11cccccc11cccccc11cccccc11cccccc11cccccccccccccccc
-- 215:1ccccccc1ccccccc1ccccccc1ccccccc1ccccccc1ccccccccccccccccccccccc
-- 216:ccc11cccccc11cccccc11cccccc111cccccc1111ccccc111cccccccccccccccc
-- 217:ccc11cccccc11cccccc11ccccc111ccc1111cccc111ccccccccccccccccccccc
-- 218:ccc11cccccc111cccccc111cccccc111cccccc11ccccccc1cccccccccccccccc
-- 219:ccc11ccccc111cccc111cccc111ccccc11cccccc1ccccccccccccccccccccccc
-- 220:cc11ccc1cc11ccc1cc11cc11cc11cc11cc111c11ccc1111ccccc111ccccccccc
-- 221:ccc11cccccc11ccc1cc11ccc1cc11ccc1c111ccc1111ccccc11ccccccccccccc
-- 222:cccccc11ccccc111cccc111cccc111cccc111ccccc11cccccc11cccccccccccc
-- 223:1ccccccc11cccccc111cccccc111cccccc111cccccc11cccccc11ccccccccccc
-- 224:cccccccccccccccccc1111ccccc11cccccc11cccccc11cccccc111cccccc1111
-- 225:cccccccccccccccccc1111ccccc11cccccc11cccccc11ccccc111ccc1111cccc
-- 226:cccccccccccccccccc111111cc111111cc11cccccc1cccccccccccccccccccc1
-- 227:cccccccccccccccc11111ccc11111ccccc111cccc111cccc111ccccc11cccccc
-- 228:ccccccccccccccc1cccccc11ccccc111ccccc111cccccc11cccccc11cccccc11
-- 229:cccccccc1ccccccc11cccccc111ccccc111ccccc11cccccc11cccccc11cccccc
-- 230:0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 231:cccccc00ccccccc0ccccccc0ccccccc0ccccccc0ccccccc0ccccccc0ccccccc0
-- 232:00c0c0c00c0c0c0cc0c0c0c00c0c0c0cc0c0c0c00c0c0c0cc0c0c0c00c0c0c0c
-- 233:c0c0c0000c0c0c00c0c0c0c00c0c0c00c0c0c0c00c0c0c00c0c0c0c00c0c0c00
-- 234:0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
-- 235:bbbbbb00bbbbbbb0bbbbbbbabbbbbbbabbbbbbbabbbbbbbabbbbbbbabbbbbbba
-- 236:0555555555555555555555555555555555555555555555555555555555555555
-- 237:5555550055555550555555565555555655555556555555565555555655555556
-- 238:0444444444444444444444444444444444444444444444444444444444444444
-- 239:4444440044444440444444434444444344444443444444434444444344444443
-- 240:ccccc111ccccccc1ccccccc1ccccccc1ccccccc1cccccc11cccccccccccccccc
-- 241:111ccccc1ccccccc1ccccccc1ccccccc1ccccccc11cccccccccccccccccccccc
-- 242:cccccc11ccccc111cccc111cccc111cccc111ccccc111111cc111111cccccccc
-- 243:1ccccccccccccccccccccccccccc1cccccc11ccc11111ccc11111ccccccccccc
-- 244:ccccccc1ccccccc1ccccccc1ccccccccccccccc1cccccc11ccccccc1cccccccc
-- 245:1ccccccc1ccccccc1ccccccccccccccc1ccccccc11cccccc1ccccccccccccccc
-- 246:cccccccccccccccccccccccccccccccccccccccccccccccc0ccccccc00000000
-- 247:ccccccc0ccccccc0ccccccc0ccccccc0ccccccc0ccccccc0cccccc0000000000
-- 248:c0c0c0c00c0c0c0cc0c0c0c00c0c0c0cc0c0c0c00c0c0c0c00c0c0c000000000
-- 249:c0c0c0c00c0c0c00c0c0c0c00c0c0c00c0c0c0c00c0c0c00c0c0c00000000000
-- 250:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb0bbbbbbb0aaaaaaa
-- 251:bbbbbbbabbbbbbbabbbbbbbabbbbbbbabbbbbbbabbbbbbbabbbbbbaaaaaaaaa0
-- 252:5555555555555555555555555555555555555555555555550555555506666666
-- 253:5555555655555556555555565555555655555556555555565555556666666660
-- 254:4444444444444444444444444444444444444444444444440444444403333333
-- 255:4444444344444443444444434444444344444443444444434444443333333330
-- </SPRITES>

-- <SPRITES1>
-- 098:0000000000aaaaa000a000a000a000a000a000a00aa00aa00aa00aa000000000
-- 099:0000000000000a00000a00a00aaa00a00aaa00a0000a00a000000a0000000000
-- 100:0000000000a0a00000a0aa0000a0aaa000a0aaa000a0aa0000a0a00000000000
-- 101:0aaaaaa00a0000a00a0000a00a0000a00a0220a00a2222a00a0220a000022000
-- 110:0444443044444443444444434444444344444443444444433444443303333330
-- 111:0555556055555556555555565555555655555556555555566555556606666660
-- 114:2000000202aaaa20002002a000a020a000a200a00a2002a002a00a2020000002
-- 115:2000000202000a20002a02a00aaa20a00aa200a0002a02a002000a2020000002
-- 116:0000000000a0aa0000a000a000a00a0000a0a0000000000000a0a00000000000
-- 126:0bbbbba0bbbbbbbabbbbbbbabbbbbbbabbbbbbbabbbbbbbaabbbbbaa0aaaaaa0
-- 128:ccccccccccccccc1cccccc11cccccc11ccccc111ccccc11ccccc111ccccc11cc
-- 129:cccccccccccccccc1ccccccc1ccccccc11cccccc11cccccc111cccccc11ccccc
-- 130:cccccccccc111111cc111111cc111ccccc11cccccc11cccccc11cc11cc11cc11
-- 131:cccccccc11cccccc111cccccc111cccccc11cccccc11cccc111ccccc1111cccc
-- 132:ccccccccccccc111cccc1111ccc111ccccc11cccccc11cccccc11cccccc11ccc
-- 133:cccccccc1111cccc11111cccccc11ccccccc1ccccccccccccccccccccccccccc
-- 134:ccccccccccc11111ccc11111ccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 135:cccccccc111ccccc1111cccccc111cccccc11cccccc11cccccc11cccccc11ccc
-- 136:ccccccccccc11111ccc11111ccc11cccccc11cccccc11cccccc11111ccc11111
-- 137:cccccccc11111ccc11111ccccccc1ccccccccccccccccccc11cccccc11cccccc
-- 138:ccccccccccc11111ccc11111ccc11cccccc11cccccc11cccccc11111ccc11111
-- 139:cccccccc11111ccc11111ccccccc1ccccccccccccccccccc11cccccc11cccccc
-- 140:cccccccccccc1111ccc11111ccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 141:cccccccc11111ccc11111ccccccc1cccccccccccccccccccccccccccc1111ccc
-- 142:cccccccccc11cccccc11cccccc11cccccc11cccccc11cccccc111111cc111111
-- 143:ccccccccccc11cccccc11cccccc11cccccc11cccccc11ccc11111ccc11111ccc
-- 144:ccc11111ccc11111cc111ccccc111ccccc11cccccc11cccccccccccccccccccc
-- 145:1111cccc1111cccccc111ccccc111cccccc11cccccc11ccccccccccccccccccc
-- 146:cc11cccccc11cccccc11cccccc111ccccc111111cc111111cccccccccccccccc
-- 147:cc111cccccc11cccccc11cccccc11ccc11111ccc1111cccccccccccccccccccc
-- 148:ccc11cccccc11cccccc11cccccc111cccccc1111ccccc111cccccccccccccccc
-- 149:cccccccccccccccccccc1cccccc11ccc11111ccc1111cccccccccccccccccccc
-- 150:ccc11cccccc11cccccc11cccccc11cccccc11111ccc11111cccccccccccccccc
-- 151:ccc11cccccc11cccccc11ccccc111ccc1111cccc111ccccccccccccccccccccc
-- 152:ccc11cccccc11cccccc11cccccc11cccccc11111ccc11111cccccccccccccccc
-- 153:cccccccccccccccccccccccccccc1ccc11111ccc11111ccccccccccccccccccc
-- 154:ccc11cccccc11cccccc11cccccc11cccccc11cccccc11ccccccccccccccccccc
-- 155:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 156:ccc11cccccc11cccccc11cccccc11cccccc11111cccc1111cccccccccccccccc
-- 157:c1111cccccc11cccccc11cccccc11ccc11111ccc1111cccccccccccccccccccc
-- 158:cc11cccccc11cccccc11cccccc11cccccc11cccccc11cccccccccccccccccccc
-- 159:ccc11cccccc11cccccc11cccccc11cccccc11cccccc11ccccccccccccccccccc
-- 160:cccccccccc111111cc111111cccccc11cccccc11cccccc11cccccc11cccccc11
-- 161:cccccccc11111ccc11111ccc1ccccccc1ccccccc1ccccccc1ccccccc1ccccccc
-- 162:ccccccccccc11111ccc11111cccccccccccccccccccccccccccccccccccccccc
-- 163:cccccccc11111ccc11111ccccc11cccccc11cccccc11cccccc11cccccc11cccc
-- 164:ccccccccc111cccccc11cccccc11cccccc11ccc1cc11cc11cc11c111cc11111c
-- 165:ccccccccc111ccccc111cccc111ccccc11cccccc1ccccccccccccccccccccccc
-- 166:ccccccccc111cccccc11cccccc11cccccc11cccccc11cccccc11cccccc11cccc
-- 167:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 168:cccccccccccc1cccccc111cccc111111cc111111cc11cc11cc11ccc1cc11ccc1
-- 169:cccccccccc1cccccc111cccc11111ccc11111ccc1cc11cccccc11cccccc11ccc
-- 170:cccccccccc11cccccc111ccccc1111cccc11111ccc11c111cc11cc11cc11ccc1
-- 171:ccccccccccc11cccccc11cccccc11cccccc11cccccc11ccc1cc11ccc11c11ccc
-- 172:cccccccccccc1111ccc11111cc111ccccc11cccccc11cccccc11cccccc11cccc
-- 173:cccccccc111ccccc1111cccccc111cccccc11cccccc11cccccc11cccccc11ccc
-- 174:cccccccccc111111cc111111ccc11cccccc11cccccc11cccccc11cccccc11111
-- 175:cccccccc111ccccc1111cccccc11cccccc11cccccc11cccccc11cccc1111cccc
-- 176:cccccc11cccccc11cccccc11cccccc11cc111111cc111111cccccccccccccccc
-- 177:1ccccccc1ccccccc1ccccccc1ccccccc11111ccc11111ccccccccccccccccccc
-- 178:ccc11111ccc11111cccc11cccccc11cccccc11cccccc1111ccccc111cccccccc
-- 179:cc11cccccc11cccccc11cccccc11cccccc11cccc1111cccc111ccccccccccccc
-- 180:cc111111cc11cc11cc11ccc1cc11cccccc11ccccc111cccccccccccccccccccc
-- 181:cccccccc1ccccccc11cccccc111cccccc111ccccc111cccccccccccccccccccc
-- 182:cc11cccccc11cccccc11cccccc11cccccc111111c1111111cccccccccccccccc
-- 183:ccccccccccccccccccccccccccc1cccc1111cccc1111cccccccccccccccccccc
-- 184:cc11cccccc11cccccc11cccccc11cccccc11cccccc11cccccccccccccccccccc
-- 185:ccc11cccccc11cccccc11cccccc11cccccc11cccccc11ccccccccccccccccccc
-- 186:cc11cccccc11cccccc11cccccc11cccccc11cccccc11cccccccccccccccccccc
-- 187:11111cccc1111ccccc111cccccc11cccccc11cccccc11ccccccccccccccccccc
-- 188:cc11cccccc11cccccc11cccccc111cccccc11111cccc1111cccccccccccccccc
-- 189:ccc11cccccc11cccccc11ccccc111ccc1111cccc111ccccccccccccccccccccc
-- 190:ccc11111ccc11cccccc11cccccc11ccccc1111cccc1111cccccccccccccccccc
-- 191:111ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 192:cccccccccccc1111ccc11111cc111ccccc11cccccc11cccccc11cccccc11cccc
-- 193:cccccccc111ccccc1111cccccc111cccccc11cccccc11cccccc11cccccc11ccc
-- 194:ccccccccccc11111ccc11111cccc11cccccc11cccccc11cccccc11cccccc1111
-- 195:cccccccc1111cccc11111cccccc11cccccc11cccccc11ccccc111ccc1111cccc
-- 196:ccccccccccccc111cccc1111ccc111ccccc11cccccc11cccccc11111cccc1111
-- 197:cccccccc1111cccc1111cccccccccccccccccccccccccccc111ccccc1111cccc
-- 198:cccccccccc111111cc111111cccccc11cccccc11cccccc11cccccc11cccccc11
-- 199:cccccccc11111ccc11111ccc1ccccccc1ccccccc1ccccccc1ccccccc1ccccccc
-- 200:cccccccccccccccccc1111ccccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 201:cccccccccccccccccc1111ccccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 202:cccccccccccccccccc1111ccccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 203:cccccccccccccccccc1111ccccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 204:cccccccccccccccccccccccccc11cccccc11cccccc11cccccc11cccccc11cccc
-- 205:ccccccccccccccccccccccccccc11cccccc11cccccc11cccccc11cccccc11ccc
-- 206:cccccccccccccccccc11cccccc111cccccc111cccccc111cccccc111cccccc11
-- 207:ccccccccccccccccccc11ccccc111cccc111cccc111ccccc11cccccc1ccccccc
-- 208:cc11cccccc11cccccc11cccccc111cccccc11111cccc1111cccccccccccccccc
-- 209:ccc11ccc11c11ccc11111cccc111cccc11111ccc11c11ccccccccccccccccccc
-- 210:cccc1111cccc11cccccc11cccccc11cccccc11ccccc1111ccccccccccccccccc
-- 211:1111cccccc111cccccc11cccccc11cccccc11ccccc1111cccccccccccccccccc
-- 212:ccccccccccccccccccccccccccccccccccc11111ccc11111cccccccccccccccc
-- 213:cc111cccccc11cccccc11cccccc11ccc11111ccc1111cccccccccccccccccccc
-- 214:cccccc11cccccc11cccccc11cccccc11cccccc11cccccc11cccccccccccccccc
-- 215:1ccccccc1ccccccc1ccccccc1ccccccc1ccccccc1ccccccccccccccccccccccc
-- 216:ccc11cccccc11cccccc11cccccc111cccccc1111ccccc111cccccccccccccccc
-- 217:ccc11cccccc11cccccc11ccccc111ccc1111cccc111ccccccccccccccccccccc
-- 218:ccc11cccccc111cccccc111cccccc111cccccc11ccccccc1cccccccccccccccc
-- 219:ccc11ccccc111cccc111cccc111ccccc11cccccc1ccccccccccccccccccccccc
-- 220:cc11ccc1cc11ccc1cc11cc11cc11cc11cc111c11ccc1111ccccc111ccccccccc
-- 221:ccc11cccccc11ccc1cc11ccc1cc11ccc1c111ccc1111ccccc11ccccccccccccc
-- 222:cccccc11ccccc111cccc111cccc111cccc111ccccc11cccccc11cccccccccccc
-- 223:1ccccccc11cccccc111cccccc111cccccc111cccccc11cccccc11ccccccccccc
-- 224:cccccccccccccccccc1111ccccc11cccccc11cccccc11cccccc111cccccc1111
-- 225:cccccccccccccccccc1111ccccc11cccccc11cccccc11ccccc111ccc1111cccc
-- 226:cccccccccccccccccc111111cc111111cc11cccccc1cccccccccccccccccccc1
-- 227:cccccccccccccccc11111ccc11111ccccc111cccc111cccc111ccccc11cccccc
-- 228:ccccccccccccccc1cccccc11ccccc111ccccc111cccccc11cccccc11cccccc11
-- 229:cccccccc1ccccccc11cccccc111ccccc111ccccc11cccccc11cccccc11cccccc
-- 230:0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 231:cccccc00ccccccc0ccccccc0ccccccc0ccccccc0ccccccc0ccccccc0ccccccc0
-- 232:00c0c0c00c0c0c0cc0c0c0c00c0c0c0cc0c0c0c00c0c0c0cc0c0c0c00c0c0c0c
-- 233:c0c0c0000c0c0c00c0c0c0c00c0c0c00c0c0c0c00c0c0c00c0c0c0c00c0c0c00
-- 234:0bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb
-- 235:bbbbbb00bbbbbbb0bbbbbbbabbbbbbbabbbbbbbabbbbbbbabbbbbbbabbbbbbba
-- 236:0555555555555555555555555555555555555555555555555555555555555555
-- 237:5555550055555550555555565555555655555556555555565555555655555556
-- 238:0444444444444444444444444444444444444444444444444444444444444444
-- 239:4444440044444440444444434444444344444443444444434444444344444443
-- 240:ccccc111ccccccc1ccccccc1ccccccc1ccccccc1cccccc11cccccccccccccccc
-- 241:111ccccc1ccccccc1ccccccc1ccccccc1ccccccc11cccccccccccccccccccccc
-- 242:cccccc11ccccc111cccc111cccc111cccc111ccccc111111cc111111cccccccc
-- 243:1ccccccccccccccccccccccccccc1cccccc11ccc11111ccc11111ccccccccccc
-- 244:ccccccc1ccccccc1ccccccc1ccccccccccccccc1cccccc11ccccccc1cccccccc
-- 245:1ccccccc1ccccccc1ccccccccccccccc1ccccccc11cccccc1ccccccccccccccc
-- 246:cccccccccccccccccccccccccccccccccccccccccccccccc0ccccccc00000000
-- 247:ccccccc0ccccccc0ccccccc0ccccccc0ccccccc0ccccccc0cccccc0000000000
-- 248:c0c0c0c00c0c0c0cc0c0c0c00c0c0c0cc0c0c0c00c0c0c0c00c0c0c000000000
-- 249:c0c0c0c00c0c0c00c0c0c0c00c0c0c00c0c0c0c00c0c0c00c0c0c00000000000
-- 250:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb0bbbbbbb0aaaaaaa
-- 251:bbbbbbbabbbbbbbabbbbbbbabbbbbbbabbbbbbbabbbbbbbabbbbbbaaaaaaaaa0
-- 252:5555555555555555555555555555555555555555555555550555555506666666
-- 253:5555555655555556555555565555555655555556555555565555556666666660
-- 254:4444444444444444444444444444444444444444444444440444444403333333
-- 255:4444444344444443444444434444444344444443444444434444443333333330
-- </SPRITES1>

-- <MAP2>
-- 000:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060000000601020304050600000102030405060304050603040a200c2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 001:00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000021000000920000110000c25161000011210041516131005161314100b3c3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 002:0000000000000000000000000070800000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002030000000a3400060000000000000b2c2d2e22000405031410061c3d300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100
-- 003:00000000000000000000000000718100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c21192a2b200d200930050600000b300d3e3003100516100e292a200c2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 004:00000000000000000000000000728200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000030000060a300c30000004100610000200040000060a20000d2e39300b3c3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000100
-- 005:0000000000000000000000000074830000000000000000000000000000000000000000000000000000000000000000000000000000000000000000003100006100005000e2000000d2000092a2b20000e200b3c3005000b2c200000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 006:000000000000000000000000007384000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a200c2d2e2415161e3a3b3c3d3000000a3b300d3004100000000a3a2b2c2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 007:000000000000000000000000007483000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a3b3c3d3005161f24050005060000000c20000400060a3b3c30000a3b3c3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 008:000000000000000000000000007384000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000a20000d20060400060004151610000b3c34131410000000000b300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 009:000000000000000000000000007585000000000000000000000000000000000000000000000000000212223242520414000000000000000000000000a2b2c2d2e20061415161000000000000000000000000b3c30000a20000d2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 010:00000000000000000036465666768696a6b6c60000000000000000000000000000000024344454420313233343530515243444540000000000000000a300c3d3e3000000000000000000000000000000000000000093a3b300d3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 011:000000000036465666a7a7a7a77787a7a7a7a796a6b6c600000000000000021222324225354555435363000000000000253545550414243400000000c3d3e300000000000000000000000000000000000000000000000000e3b3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 012:2636465666a7a7a7a7a7a7a7a7788897a7a7a7a7a7a7a796a6b6c6d60000031323334353630000000000000000000000000000000000000044543444000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 013:a7a7a7a7a7a7a7a7a7a7a7a76979898897a7a7a7a7a7a7a7a79696a6b6c6000000000000000000000000000000000000000000000001010145553545000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 014:a7a7a7a7a7a7a7a7a7a7a76979797979b997a7a7a7a7a7a7a7a7a7a7a7a7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 015:a7a7a7a7a7a7a7a7a7a769797979797979b9a7a7a7a7a7a7a7a7a7a7a7a7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 016:a7a7a7a7a7a7a7a7a7697979797979797989b9a7a7a7a7a7a7a7a7a7a7a7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- </MAP2>

-- <WAVES>
-- 000:00000000ffffffff00000000ffffffff
-- 001:0123456789abcdeffedcba9876543210
-- 002:0123456789abcdef0123456789abcdef
-- 004:00000fffffffffff00000fffffffffff
-- </WAVES>

-- <WAVES1>
-- 000:00000000ffffffff00000000ffffffff
-- 001:0123456789abcdeffedcba9876543210
-- 002:0123456789abcdef0123456789abcdef
-- 004:00000fffffffffff00000fffffffffff
-- 012:0a0507b0904ee905af40a0b630ca06b0
-- 013:06303f779506b40899e570068c048300
-- 014:bea99ed8becb8dc69714205620452543
-- </WAVES1>

-- <WAVES2>
-- 000:00000000ffffffff00000000ffffffff
-- 001:0123456789abcdeffedcba9876543210
-- 002:0123456789abcdef0123456789abcdef
-- 004:00000fffffffffff00000fffffffffff
-- 005:be2f5117aaa1b8c4c13dfdd4cb190400
-- </WAVES2>

-- <WAVES3>
-- 000:00000000ffffffff00000000ffffffff
-- 001:0123456789abcdeffedcba9876543210
-- 002:0123456789abcdef0123456789abcdef
-- 004:00000fffffffffff00000fffffffffff
-- 005:be2f5117aaa1b8c4c13dfdd4cb190400
-- </WAVES3>

-- <SFX>
-- 000:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000205000000000
-- 001:10001000200030003000400050006000600070007000800090009000a000b000b000c000d000d000e000e000e000f000f000f000f000f000f000f000400000000000
-- 002:0003100120003000400060007000700090009000b000b000c000d000d000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000300000000000
-- 003:0000300050008000a000c000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000410000000000
-- 004:040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400400000000000
-- 005:040014002400240044005400640074007400840084009400a400a400b400b400c400c400c400d400d400e400e400e400e400f400f400f400f400f400402000000000
-- 006:0403140124003400440064007400740094009400b400b400c400d400d400e400f400f400f400f400f400f400f400f400f400f400f400f400f400f400300000000000
-- 007:0400340054008400a400c400e400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400410000000000
-- 008:c000b00090008000800080008000700070007000700070007000700070006000700080008000800080009000a000a000a000b000b000b000c000c000400000000000
-- 012:c400b40094008400840084008400740074007400740074007400740074006400740084008400840084009400a400a400a400b400b400b400c400c400400000000000
-- 016:010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100300000000000
-- 017:11001100210031003100410051006100610071007100810091009100a100b100b100c100d100d100e100e100e100f100f100f100f100f100f100f100200000000000
-- 018:0103110121003100410061007100710091009100b100b100c100d100d100e100f100f100f100f100f100f100f100f100f100f100f100f100f100f100300000000000
-- 019:0000300050008000a000c000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000417000000000
-- 020:01c001b011a01180117011602140213021303120411051106100810081009100a100a100b100b100c100c100d100d100e100e100f100f100f100f100210000000000
-- 024:13002300330043005300630073008300a300b300d300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300300000000000
-- 025:130013002300330043004300530063007300830083009300a300b300d300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300310000000000
-- 026:230063007300b300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300700000000000
-- 027:205060307010b000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000100000000000
-- 028:13102300330043005300630073008300a300b300d300e30053009300b310d300e300f300f300f300f300f300f300f300f300f300f300f300f300f300300000000000
-- 029:133013202310331043104300530063007300830083009300a300b300c300c300d300e300e300e300e300e300e300e300e300e300d300d300d300d300710000000000
-- 030:030003000300030003000300130013001300230023003300430053006300730083009300a300b300b300c300d300d300d300d300e300e300f300f300300000000000
-- 031:12001200220032003200420052006200620072007200820092009200a200b200b200c200d200d200e200e200e200f200f200f200f200f200f200f200370000000000
-- 048:0007201730374047605770578057a057b057c057d057e057f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000410000000000
-- 049:0008201830384048605870588058a058b058c058d058e058f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000490000000000
-- 050:800080008000800080008000704070407040604060405040404040404070307030702070207020702070107010c010c010c010c020c020c040c050c0300000000000
-- 051:00c000c000c000c000c000c00090009000900090009010901060106010602060206030604030503060306030803090309030a030a030b030b030b030300000000000
-- 052:1024104120522052205330253006400650065014604260607060805c802b900ba00ba00bb01bb04cc06dc070d081e073e054e025f015f015f025f043600000000000
-- 053:11001100110011102110212031404170519061a061c071c081c091c0a1c0a1c0b1c0b1c0c1c0c1c0d1c0d1c0d1c0d1c0d1c0e1c0e1c0e1c0e1c0f1c0600000000000
-- 054:1010102010601090208020a030c040e050f060006010702080309050a070a080b090b0b0c0f0c0f0d0d0d010d030d060d070e080e0a0e0c0e0e0f0f0500000000000
-- 055:01e021d331c541b641b651a76196619681859173a172a160b17fc16dc15cd14ce14ce13cf13bf12bf12bf11af11af11bf10df100f102f105f106f107310000000000
-- 056:03100340030003b0033003c0032013d0130023f0232033e0431053e0530063b0730083c08320839093809310931093609300a340b330c320d300f300300000000000
-- 057:00f010f020a020a0305030504000400040d050d050805080503060306000600060a060a060606060501050105000500060f070f080f090f0a0f0b0a0460000000000
-- 060:0300230f330f430f530e630d630c730a83088310831f931f931fa31ea31ea31fb31eb31cb31ac320c320c32fc32ed32ed32dd328d33fe33ee33cf33a6f0000000000
-- 061:0300130d331c531b631a732a432a532963298349933a834a535b635b735c936ca36ec37f93809390a392a3a3b3b4b3c5c3d5d3d5e3e4e3f3e3e0f3ee400000000000
-- </SFX>

-- <SFX1>
-- 000:020002000200020002000200020002000200020002000200020002000200020002000200020002000200020002000200020002000200020002000200403000000000
-- 001:10001000200030003000400050006000600070007000800090009000a000b000b000c000d000d000e000e000e000f000f000f000f000f000f000f000400000000000
-- 002:0003100120003000400060007000700090009000b000b000c000d000d000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000300000000000
-- 003:0000300050008000a000c000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000410000000000
-- 004:040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400400000000000
-- 005:040014002400240044005400640074007400840084009400a400a400b400b400c400c400c400d400d400e400e400e400e400f400f400f400f400f400400000000000
-- 006:0403140124003400440064007400740094009400b400b400c400d400d400e400f400f400f400f400f400f400f400f400f400f400f400f400f400f400300000000000
-- 007:0400340054008400a400c400e400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400410000000000
-- 008:c000b00090008000800080008000700070007000700070007000700070006000700080008000800080009000a000a000a000b000b000b000c000c000400000000000
-- 012:c400b40094008400840084008400740074007400740074007400740074006400740084008400840084009400a400a400a400b400b400b400c400c400400000000000
-- 016:010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100300000000000
-- 017:11001100210031003100410051006100610071007100810091009100a100b100b100c100d100d100e100e100e100f100f100f100f100f100f100f100200000000000
-- 018:0103110121003100410061007100710091009100b100b100c100d100d100e100f100f100f100f100f100f100f100f100f100f100f100f100f100f100300000000000
-- 019:0000300050008000a000c000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000210000000000
-- 020:01c001b011a01180117011602140213021303120411051106100810081009100a100a100b100b100c100c100d100d100e100e100f100f100f100f100210000000000
-- 024:13002300330043005300630073008300a300b300d300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300300000000000
-- 025:130013002300330043004300530063007300830083009300a300b300d300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300310000000000
-- 026:230063007300b300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300700000000000
-- 027:205060307010b000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000100000000000
-- 028:0c000d000c000d000c000d000c000d000c000d000c000d000c000d000c000d000c000d000c000d000c000d000c000d000c000d000c000d000c000d0020000e000000
-- 029:0e000e001e001e001e001e002e002e001e002e003e003e004e005e005e007e006e008e009e00ae00ae00be00ce00ce00de00de00ee00ee00ee00ee00200000000000
-- 030:030003000300030003000300130013001300230023003300430053006300730083009300a300b300b300c300d300d300d300d300e300e300f300f300300000000000
-- 031:12001200220032003200420052006200620072007200820092009200a200b200b200c200d200d200e200e200e200f200f200f200f200f200f200f200370000000000
-- </SFX1>

-- <SFX2>
-- 000:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000401000000000
-- 001:10001000200030003000400050006000600070007000800090009000a000b000b000c000d000d000e000e000e000f000f000f000f000f000f000f000400000000000
-- 002:0003100120003000400060007000700090009000b000b000c000d000d000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000300000000000
-- 003:0000300050008000a000c000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000410000000000
-- 004:040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400200000000000
-- 005:040014002400240044005400640074007400840084009400a400a400b400b400c400c400c400d400d400e400e400e400e400f400f400f400f400f400200000000000
-- 006:0403140124003400440064007400740094009400b400b400c400d400d400e400f400f400f400f400f400f400f400f400f400f400f400f400f400f400300000000000
-- 007:0400340054008400a400c400e400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400410000000000
-- 008:c000b00090008000800080008000700070007000700070007000700070006000700080008000800080009000a000a000a000b000b000b000c000c000400000000000
-- 012:c400b40094008400840084008400740074007400740074007400740074006400740084008400840084009400a400a400a400b400b400b400c400c400109000000000
-- 016:010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100300000000000
-- 017:11001100210031003100410051006100610071007100810091009100a100b100b100c100d100d100e100e100e100f100f100f100f100f100f100f100200000000000
-- 018:0203120122003200420062007200720092009200b200b200c200d200d200e200f200f200f200f200f200f200f200f200f200f200f200f200f200f200400000000000
-- 019:0000300050008000a000c000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000210000000000
-- 020:01c001b011a01180117011602140213021303120411051106100810081009100a100a100b100b100c100c100d100d100e100e100f100f100f100f100210000000000
-- 024:13002300330043005300630073008300a300b300d300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300300000000000
-- 025:130013002300330043004300530063007300830083009300a300b300d300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300710000000000
-- 026:230063007300b300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300700000000000
-- 027:205060307010b000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000100000000000
-- 028:13102300330043005300630073008300a300b300d300e30053009300b310d300e300f300f300f300f300f300f300f300f300f300f300f300f300f300300000000000
-- 029:133013202310331043104300530063007300830083009300a300b300c300c300d300e300e300e300e300e300e300e300e300e300d300d300d300d300710000000000
-- 030:030003000300030003000300130013001300230023003300430053006300730083009300a300b300b300c300d300d300d300d300e300e300f300f300300000000000
-- 031:12001200220032003200420052006200620072007200820092009200a200b200b200c200d200d200e200e200e200f200f200f200f200f200f200f200370000000000
-- </SFX2>

-- <SFX3>
-- 000:00000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000020a000000000
-- 001:10001000200030003000400050006000600070007000800090009000a000b000b000c000d000d000e000e000e000f000f000f000f000f000f000f000400000000000
-- 002:0003100120003000400060007000700090009000b000b000c000d000d000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000300000000000
-- 003:0000300050008000a000c000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000410000000000
-- 004:040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400040004000400200000000000
-- 005:040014002400240044005400640074007400840084009400a400a400b400b400c400c400c400d400d400e400e400e400e400f400f400f400f400f400200000000000
-- 006:0403140124003400440064007400740094009400b400b400c400d400d400e400f400f400f400f400f400f400f400f400f400f400f400f400f400f400300000000000
-- 007:0400340054008400a400c400e400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400f400410000000000
-- 008:c000b00090008000800080008000700070007000700070007000700070006000700080008000800080009000a000a000a000b000b000b000c000c000400000000000
-- 012:c400b40094008400840084008400740074007400740074007400740074006400740084008400840084009400a400a400a400b400b400b400c400c400100000000000
-- 016:010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100010001000100300000000000
-- 017:11001100210031003100410051006100610071007100810091009100a100b100b100c100d100d100e100e100e100f100f100f100f100f100f100f100200000000000
-- 018:0203120122003200420062007200720092009200b200b200c200d200d200e200f200f200f200f200f200f200f200f200f200f200f200f200f200f200400000000000
-- 019:0000300050008000a000c000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000510000000000
-- 020:01c001b011a01180117011602140213021303120411051106100810081009100a100a100b100b100c100c100d100d100e100e100f100f100f100f100210000000000
-- 024:13002300330043005300630073008300a300b300d300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300300000000000
-- 025:130013002300330043004300530063007300830083009300a300b300d300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300710000000000
-- 026:230063007300b300e300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300f300700000000000
-- 027:205060307010b000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000100000000000
-- 028:13102300330043005300630073008300a300b300d300e30053009300b310d300e300f300f300f300f300f300f300f300f300f300f300f300f300f300300000000000
-- 029:133013202310331043104300530063007300830083009300a300b300c300c300d300e300e300e300e300e300e300e300e300e300d300d300d300d300710000000000
-- 030:030003000300030003000300130013001300230023003300430053006300730083009300a300b300b300c300d300d300d300d300e300e300f300f300300000000000
-- 031:12001200220032003200420052006200620072007200820092009200a200b200b200c200d200d200e200e200e200f200f200f200f200f200f200f200370000000000
-- </SFX3>

-- <PATTERNS>
-- 000:d00016000000400018000000800018000000d00018000000daa116000000400018000000800018000000d00018000000dff116000000400018000000800018000000b00018000000daa116000000400018000000800018000000b00018000000bff116000000f00016000000600018000000900018000000b00018000000d0001800000040001a00000060001a00000090008a00000000000000000000000000000080001a90001ab0008a000000000000000000000000000000000000000000
-- 001:80008a00000000000000000000000000000000000000000060008a00000000000000000040008a00000000000000000060008a000000000000000000000000000000000000000000000000000000000000000000b0008a000000000000000000b000880000000000000000000aa100000000000000000000099100000000000000000000077100000000000000000000055100000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000
-- 002:8582c60881000000000000000000000000000000000000000000000000000000000000000000000000000000000000006472c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b000c6000000000000000000000000000000000000000000077100000000000000000000055100000000000000000000033100000000000000000000011100000000000000000000000100000000000000000000000000000000000000000000
-- 004:d000f70000000000000000005000f70000000000000000008000f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 005:d00026000000000000000000500026000000000000000000800026000000d00026000000000000000000501028000000000000000000500028000000000000000000500028000000f00026000000000000000000d00026000000000000000000d00026000000000000000000500026000000000000000000800026000000d00026000000000000000000501028000000000000000000500028000000000000000000500028000000f00026000000000000000000d00026000000000000000000
-- 006:b00026000000000000000000f00024000000000000000000600026000000b00026000000000000000000f01026000000000000000000f00026000000000000000000f00026000000d00026000000000000000000b00026000000000000000000b00026000000000000000000f00024000000000000000000600026000000b00026000000000000000000f01026000000000000000000f00026000000000000000000f00026000000d00026000000000000000000b00026000000000000000000
-- 007:9000c60000000000000000000000000000004000c6000000000000000000000000000000d000c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b000c6000000d000c6000000b000c60000000000000000000000000000006000c6000000000000000000000000000000f000c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d000c6000000f000c6000000
-- 008:800015000000000000000000000000000000000000000000d00015000000000000000000000000000000800017000000000000000000a00017000000000000000000800017000000600017000000000000000000500017000000000000000000800015000000000000000000000000000000000000000000d00015000000000000000000000000000000800017000000000000000000a00017000000000000000000800017000000600017000000000000000000500017000000000000000000
-- 009:600015000000000000000000000000000000000000000000d00015000000000000000000000000000000800017000000000000000000a00017000000000000000000800017000000600017000000000000000000500017000000000000000000600015000000000000000000000000000000000000000000d00015000000000000000000000000000000800017000000000000000000a00017000000000000000000800017000000600017000000000000000000500017000000000000000000
-- 010:d7c2c6077100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f000c6000000000000000000000000000000000000000000d000c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000f000c6000000000000000000000000000000000000000000
-- 011:b4e2c60771000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000c6000000000000000000000000000000000000000000b000c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d000c6000000000000000000000000000000000000000000
-- 012:4000c8000000000000000000000000000000d000c60000000000000000000000000000008000c80000000000000000000000000000000000000000000000000000000000000000006000c80000000000000000008000c8000000000000000000b000c8000000000000000000b000c8000000000000000000b000c8000000000000b000c8000000000000b000c8000000b000c8000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 013:4000c8000000000000000000000000000000d000c60000000000000000000000000000008000c80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000c80000008000c80000006000c8000000000000000000000000000000f000c6000000000000000000000000000000b000c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 014:800015000000000000000000000000000000d00015000000000000000000000000000000b00017000000000000000000000000000000000000000000900017000000000000000000600017000000000000000000900015000000000000000000b00015000000000000000000000000000000f00015000000000000000000000000000000d00017000000000000000000000000000000000000000000b00017000000000000000000600017000000000000000000b00015000000000000000000
-- 015:459288088100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600088000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 016:64a288000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b472f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b472f7000000000000000000000000000000000000000000
-- 017:64a288000000000000000000000000000000000000000000000000080000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000659288000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 018:d00015000000000000000000000000000000800015000000000000000000000000000000600017000000000000000000000000000000000000000000600017000000000000000000900017000000000000000000a00017000000000000000000b00017000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b00015000000000000000000000000000000000000000000
-- 019:000000000000000000000000000000000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 020:d00015000000000000000000000000000000800015000000000000000000000000000000600017000000000000000000000000000000000000000000600017000000000000000000d00015000000000000000000a00015000000000000000000b00015000000000000000000000000000000f00015000000000000000000000000000000f00017000000000000000000000000000000000000000000d00017000000000000000000b00017000000000000000000000000000000000000000000
-- 021:b00017000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 022:b00086000000000000000000000000000000000000000000900086000000000000000000000000000000000000000000f00086000000000000000000000000000000000000000000d00086000000000000000000b00086000000000000000000600086000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 023:9472c6088100000000000000000000000000000000000000000000000000000000000000000000000000000000000000b000c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d7a0c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 024:4000f70000000000001000004000f71000004000f71000004000f71000000000000000004000f70000000000001000004000f70000000000001000004000f71000004000f71000004000f71000000000000000004000f70000000000000000006000f70000000000000000000000000000000000000000009000f7000000000000000000000000000000000000000000d000f70000000000000000000000000000000000000000006000f9000000000000000000000000000000000000000000
-- 025:b00086000000000000000000000000000000000000000000900086000000000000000000000000000000000000000000f00086000000000000000000000000000000000000000000d00086000000000000000000600086000000000000000000b00086000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 026:747286000000000000000000000000000000000000000000000000000000000000000000900086000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b00086000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 027:74c286000000000000000000000000000000000000000000000000000000000000000000900086000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b00086000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 028:4aa1af0000000000000000000000000000004000af0000004000af0000000000000000004000af4000af4000af4000af4000af0000000000000000004000af0000000000000000004000af0000000000000000004aa1af0000000000000000004000af0000000000000000000000000000004000af0000004000af0000000000000000004000af4000af4000af4000af4000af0000000000000000004000af0000000000000000004000af000000000000000000000000000000000000000000
-- </PATTERNS>

-- <PATTERNS1>
-- 000:400016000000000000000000000000000000800016000000b00016000000000000000000000000000000000000000000000000000000000000000000000000000000b00016d00016b00016000000900016000000800016000000400016000000600016000000000000000000000000000000800016000000900016000000000000000000d00014000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 001:400015000000000000000000000000000000000000000000800015000000000000000000b00015000000000000000000800017000000000000000000000000000000000000000000400017000000000000000000000000000000000000000000900015000000000000000000000000000000000000000000d00015000000000000000000600017000000000000000000900017000000000000000000000000000000000000000000600007000000000000000000000000000000000000000000
-- 002:900016000000000000000000000000000000d00016000000f00016000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000500088000000000000000000000000000000000000000000400018000000000000000000000000000000000000000000400066000000600066000000800066000000a00066000000b00066000000000000000000000000000000000000000000000000000000000000000000b00016000000000000000000
-- 003:f00015000000000000000000000000000000d00015000000b00015000000000000000000000000000000000000000000a00015000000000000000000000000000000000000000000800015000000000000000000600015000000000000000000400015000000000000000000000000000000000000000000b00015000000000000000000000000000000b02415c00015b00415000000000000000000000000000000000000000000b00015000000000000000000000000000000000000000000
-- 004:400016000000000000000000000000000000800016000000800018000000000000000000000000000000000000000000000000000000800018000000900018000000b00018000000b00018000000b00018000000b00018000000800018900018600018000000000000000000000000000000900018000000f00016000000000000000000000000000000000000000000000000000000000000000000000000000000000000a00015000000000000000000000000000000000000000000000000
-- 005:0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000661004472f90000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004692c8000000000000000000000000000000000000000000
-- 006:400017000000000000000000000000000000b00015000000b00017000000000000000000900017000000000000000000800017000000000000000000000000000000000000000000400017000000000000000000000000000000000000000000600017000000000000000000000000000000000000000000900017000000000000000000800017000000000000000000600017000000000000000000000000000000000000000000b00015000000000000000000000000000000000000000000
-- 007:000000000000000000000000000000000000000000000000000000000000000000000000000000000000066100000000a4a2f90000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004472f9000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b472f9000000000000000000000000000000000000000000
-- 008:00000000000000000000000006610000000000000000000044c2f900000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000045b2f9000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 009:900018000000000000000000000000000000800018000000600018000000000000033100400018000000000000000000f000160000000000000000000ff100000000000000000000900016000000000000000000800016000000600016000000400016000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 010:600015000000000000000000000000000000900015000000b00015000000000000000000000000000000000000000000000000000000000000000000900017000000000000000000b00015000000000000000000b00015000000b00015000000400015000000000000000000000000000000400015000000800015000000000000000000b00015000000000000000000c00017000000000000000000000000000000000000000000b00017000000000000000000000000000000000000000000
-- 011:000000006000000000000000000000000000000000066100f682f70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004472f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 012:900016000000000000000000c00016000000000000000000400016000000000000000000600016000000800016000000900016000000000000000000c0001600000000000000000040001600000000000000000000000000000000000070001660001600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000060001667c516000000000000080500000000000000000000000000000000000000000000000000000000000000000000
-- 013:90001500000000000000000000000000000090001500000040001700000000000000000000000000000040001700000090001500000000000000000000000000000090001500000040001700000000000000000000000000000000000000000060001700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000067c517000000000000000000080500000000000000000000000000000000000000000000000000000000000000000000
-- 014:0000000000000000000000000000000000000661000000009372f70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000f70000000000000000000000000000000000000000006372f700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000007c5006372f7000000000000000000000000000000000000080500000000000000000000000000000000000000000000
-- 015:900016000000000000000000c00016000000000000000000400016000000000000000000600016000000800016000000900016000000000000000000c0001600000000000000000040001800000000000000000000000000000000000070001867a518000000000000000000080500000000000000000000000000000000000000000000000000000000000000700018800018000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 016:0000000000000000000000000000000000000661000000009372f70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000f70000000000000000000000000000000000000000006372f70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004472f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 017:900015000000000000000000000000000000900015000000400017000000000000000000000000000000400017000000900015000000000000000000000000000000900015000000400017000000000000000000000000000000000000000000600017000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d00015000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 018:b00016000000000000000000f00016000000000000000000600016000000000000000000800016000000900016000000b00016000000000000000000f00016000000000000000000600016000000000000000000000000000000000000900016700016000000000000000000000000000000000000000000000000000000000000000000000000000000000000b00016d00016000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 019:b00015000000000000000000000000000000b00015000000600017000000000000000000000000000000600017000000b00015000000000000000000000000000000b00015000000600017000000000000000000000000000000000000000000e00015000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400017000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 020:000000000000000000000000000000000000066100000000b7a2f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b7a2f70000000000000000000000000000000000000000007000f70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 021:b00017000000000000000000000000000000b00017000000900017000000000000000000000000000000900017000000800017000000000000000000000000000000800017000000700017000000000000000000000000000000000000000000800017000000000000000000000000000000000000000000600017000000000000000000800017000000000000000000400017000000000000000000000000000000000000000000400015000000000000000000000000000000000000000000
-- 022:b00016000000000000000000f00016000000000000000000600016000000000000000000800016000000900016000000b00016000000000000000000e00016000000000000000000700016000000000000000000000000000000900016000000800016000000000000000000000000000000800016000000600016000000000000000000b00014000000000000000000400016000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 023:066100000000000000000000b472f70000000000000000009000f70000000000000000000000000000000000000000000000000000000000000000007472f70000000000000000005472f70000000000000000000000000000000000000000008472f70000000000000000000000000000000000000000006492f700000000000000000000000000000000000000000047c2f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 024:e00014000000600016000000900016000000c00016000000400018000000000000066100e00014000000600016000000900016000000c000160000004000180000000000000000000ff100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 025:e00015000000000000000000000000000000900015000000c00015000000900015002400600017000400000000000000000000000000000000000000e00015000000000000000000e00015000000c00015000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 026:00000006610000000000000000000000000000000000000000000000000000000000000097e2c6000000000000000000055100000000000000000000033100000000000000000000022100000000000000177100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 027:e00015000000000000000000000000000000900015000000c00015000000900015002400600017000400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 028:4441af0000004000af0000004000970000004000af0000004000af0000004000970000004000af0000004000af0000004441af0000004000af0000004000970000004000af0000004000af0000004000970000004000af0000004000af000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 029:700016000000900016000000b00016000000c00016000000b00016000000700016000000500016000000000000000000000000000000e00014000000500016000000700016000000900016000000700016000000500016000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 030:700016000000900016000000b00016000000c00016000000b00016000000700016000000900018000000000000000000000000000000000000000000700018000000000000000000500018000000400018000000000000000000500018000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 031:07710000000000000000000000000000000000000000000077e2c600000000000000000057e2c60000000000000000000000000000000000000000000000000000000000000000009000c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 032:700015000000000000000000000000000000c00015000000b00015000000700015000000900015000000000000000000000000000000900015000000500015000000000000000000000000000000500015000000c00015000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 033:700015000000000000000000000000000000c00015000000b00015000000700015000000900015000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 034:07710000000000000000000000000000000000000000000077e2c600000000000000000057e2c6000000000000000000055100000000000000000000044100000000000000000000022100000000000000000000011100100000077100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 035:e00015000000000000000000e00015000000000000000000e00015000000000000000000e02415000000f00015000000e00015000000000000000000e00015000000000000000000e00015000000900015000000c00015000000f00015000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 036:9000b30000000000000000009000b30000000000000000009000b30000000000000000009000b30000000000000000009000b30000000000000000009000b30000000000000000009000b30000000000000000009000b3000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 037:e00024000000000000000000e00024000000000000000000e00024000000000000000000e00024000000000000000000e00024000000000000000000e00024000000000000000000c00024000000f00024000000c00024000000f00024000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 038:e00014000000600016000000900016000000c00016000000400018000000900018000000b00018000000900018000000600018000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 039:e00015000000000000000000000000000000600017000000900017000000000000000000c00017000000000000000000400019000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 040:00000006610000000000000047e2f70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 041:4aa1af0000004000af0000004000450000004000af4000af4000af4000af4000450000004000af0000004000af4000af4000af0000004000af0000004000450000004000af4000af4000af4000af4000450000004000af0000004000af4000af000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 042:e00015000000000000000000000000000000900017000000000000000000000000000000c00017000000000000000000e00015000000000000000000000000000000900017000000000000000000000000000000c00017000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 043:9aa126001400600026000000c00026000000900026000000e00026000000900026000000600028000000e00026000000400028000000c00026000000e00026000000a00026000000c00026000000900026000000a00026000000700026000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 044:e6612800000060002a00000090002a000000c0002a00000040002c00000070002c00000060002c00000040002c00000060002c000000e0002a00000040002c000000c0002a000000e0002a000000a0002a000000c0002a00000090002a000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 045:b00016000000700016000000b00016000000e00016000000000000000000b00016000000700018000000000000000000000000000000000000000000700018000000000000000000500018000000700018000000900018000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 046:b00016000000700016000000b00016000000e00016000000000000000000b00016000000700018000000000000000000000000000000000000000000900018000000000000000000b00018000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 047:700017000000000000000000000000000000500017000000000000000000000000000000400017000000000000000000000000000000000000000000400017000000000000000000e00015000000c00015000000b00015000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 048:700017000000000000000000000000000000500017000000000000000000000000000000400017000000000000000000000000000000000000000000400417000000e00015000000c00015000000e00015000000b00015000000000400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 049:066100000000000000000000b7c2f70000000000000000000000000000000000000000009000f70000000000000000000000000000000000000000000000000000000000000000009000c60000000000000000007000c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 050:066100000000000000000000b7c2f70000000000000000000000000000000000000000009000f70000000000000000000000000000000000000000000000000000000000000000009000c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 051:4aa1450000004000450000004000450000004881af0000004000af000000400045000000400017000000000000000000000000000000000000000000400045000000000000000000400047000000400047000000400047000000400047000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 052:b00018000000900018000000700018000000900018000000700018000000600018000000700018000000600018000000400018000000e00016000000000000000000000000000000e00014600016900016c00016400018000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 053:400017000000000000000000700017000000000000000000e00015000000000000000000b00015000000000000000000400017000000e00015000000000000000000000000000000e00015000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 054:06610007c200000000000000b000f70000000000000000009000f70000000000000000007000f70000000000000000006000f70000004000f7000000000000000000000000000000e000f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 055:4aa1450000004000af0000004000af0000004aa1450000004000af0000004000af0000004aa1450000004000af0000004000af0000004aa145000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- </PATTERNS1>

-- <PATTERNS2>
-- 000:400018000000000000000000000000000000000000000000b00016000000e00016000000000000000000b00016000000e00016000000000000000000400018000000000000000000000000000000400018000000000000000000000000000000b00016000000e00016000000000000000000b00016000000600018000000000000000000700018000000400018000000000000000000000000000000b00016000000e00016000000000000000000b00016000000000000000000000000000000
-- 001:4000b30000000000000000004000b30000000000000000004000970000000000000000004000b30000004000a70000004000b30000004000a70000004000b30000000000000000004000970000000000000000004000b30000004000a70000004000b30000000000000000004000b30000000000000000004000970000000000000000004000b30000004000a70000004000b30000004000a70000004000b30000000000000000004000a70000000000000000004000b30000004000a7000000
-- 002:f661df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df0000000000000000004000df000000000000000000
-- 003:4000b30000000000000000004000b30000000000000000004000970000000000000000004000b30000004000a70000004000b30000004000a70000004000b30000000000000000004000970000000000000000004000b30000004000a70000004000b30000000000000000004000970000000000000000004000b30000004000a70000004000b30000000000000000004000970000000000000000004000b34000b34000a70000004000b3000000000000000000400097000000000000000000
-- 004:b7e2f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000c000f7000000000000000000000000000000000000000000b000f70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000f7000000000000000000000000000000000000000000
-- 005:900015000000000000000000b00015000000000000000000900015000000000000000000600015000000000000000000400015000000000000900015800015000000000000000000600015000000000000000000400015000000000000000000900015000000000000000000b00015000000000000000000900015000000000000000000600015000000000000000000400015000000000000900015800015000000000000000000600015000000000000000000400015000000000000000000
-- 006:900415000000000000000000b00015000000000000000000900015000000000000000000600015000000000000000000400015000000000000900015800015000000000000000000600015000000000000000000400015000000000000000000900015000000000000000000b00015000000000000000000400017000000000000900015b00015000000000000000000400017000000000000900015b00015000000000000000000400017002400000000000000600017000000000000000000
-- 007:600086000000000000000000000000000000000000000000400086000000000000000000000000000000000000000000f00084000000000000000000000000000000000000000000b00084000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b00084000000000000000000000000000000000000000000f00084000000000000000000000000000000000000000000400086000000000000000000000000000000000000000000
-- 008:b4a2f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b000f7000000000000000000d000f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000200000000
-- 009:d00084000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b00084000000000000000000a000140000000000000000000991000000000000000000006000160000000000000000000000000000000ff100000000a000140000000991000000006000160000000000000000000ff100000000000000000000000000000000000000000000600016000000700016000000
-- 010:800086000000000000000000000000000000000000000000000000000000000000000000f00084000000000000000000000000000000000000000000000000000000000000000000b00086000000000000000000000000000000000000000000a00086000000000000000000000000000000000000000000000000000000000000000000f00086000000000000000000000000000000000000000000000000000000000000000000a00086000000000000000000000000000000000000000000
-- 011:8ff186000000000000000000000000000000000000000000000000000000000000000000a00086000000000000000000000000000000000000000000000000000000000000000000b000860000000000000000000000000000000000000000006ff1860000000000000000000aa1000000000000000000000881000000000000000000000441000000000000001000006ff186000000000000000000400086000000000000000000f00084000000000000000000400086000000000000000000
-- 012:f00084000000000000000000000000000000000000000000000000000000000000000000400086000000000000000000000000000000000000000000000000000000000000000000600086000000000000000000000000000000000000000000d00084000000000000000000000000000000000000000000000000000000000000000000600086000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000600086000000700086000000
-- 013:800086000000000000000000000000000000000000000000000000000000000000000000600086000000000000000000000000000000000000000000000000000000000000000000800086000000000000000000000000000000000000000000400086000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400086000000000000000000f00084000000000000000000b00084000000000000000000d00084000000000000000000
-- 014:f00084000000000000000000000000000000000000000000000000000000000000000000400086000000000000000000000000000000000000000000000000000000000000000000f00084000000000000000000000000000000000000000000d00084000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b00084000000000000000000
-- 015:bff1840000000000000000000000000000000000000000000dd1000000000000000000000000000000000000000000000bb100000000000000000000000000000000000000000000077100000000000000000000000000000000000000000000bff1860000000000000000000000000000000000000000000000000000000000000000000cc1000000000000000000000000000000000000000000000aa100000000000000000000000000000000000000000000066100000000000000000000
-- 016:9292f70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000f7000000000000000000b7a2f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 017:9272f70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000f7000000000000000000b000f7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 018:b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000
-- 019:600015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000a00015000000000000000000600015000000000000000000d00015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000d00015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000
-- 020:800015000000000000000000800015000000000000000000800015000000000000000000800015000000000000000000800015000000000000000000800015000000000000000000800015000000000000000000800015000000000000000000d00015000000000000000000d00015000000000000000000d00015000000000000000000d00015000000000000000000d00015000000000000000000d00015000000000000000000d00015000000000000000000d00015000000000000000000
-- 021:b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000a00015000000000000000000600015000000000000000000600015000000000000000000a00015000000000000000000
-- 022:b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000b00015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000600015000000000000000000700015000000000000000000
-- 023:800015000000000000000000800015000000000000000000800015000000000000000000800015000000000000000000800015000000000000000000800015000000000000000000800015000000000000000000800015000000000000000000400017000000000000000000400017000000000000000000400017000000000000000000400017000000000000000000400017000000000000000000400017000000000000000000400017000000000000000000400017000000000000000000
-- 024:4aa1c70000000000000000004000c70000004000c70000000000000000000000000000004000c50000000000000000004000c70000000000000000004000c70000004000c70000000000000000000000000000004000850000000000000000004000c70000000000000000004000c70000004000c70000000000000000000000000000004000c50000000000000000004000c70000000000000000004000c70000004000c7000000000000000000000000000000400085000000000000000000
-- 025:4aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af0000004661af0000004aa1af4661af4661af000000
-- 026:d00016000000400018000000d00016000000d00018000000000000000000000000000000d00016000000400018000000d00016000000400018000000d00016000000b00018000000000000000000000000000000d00016000000400018000000d00016000000400018000000d00016000000900018000000000000000000000000000000d00016000000400018000000d00016000000400018000000d00016000000000000000000800018000000600018000000500018000000f00016000000
-- 027:d626c2000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d0a4c4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d0a4c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000800464000000000000000000000000000000000000000000d77166000000b00066000000900066000000800066000000
-- 028:800016000000600016000000500016000000d00014000000800016000000600016000000500016000000d00014000000800016000000600016000000400016000000b00014000000800016000000600016000000400016000000b00014000000d00016000000800016000000600016000000400016000000d00016000000800016000000600016000000400016000000c00016000000800016000000600016000000400016000000d00016000000800016000000f00016000000400018000000
-- 029:8592c80aa100000000000000000000000000000000000000000000000000000000000000000000000000000000000000b000c80000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000ca0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000006000ca0000000000000000000000000000000000000000007000ca000000000000000000000000000000000000000000
-- 030:d00016000000b00016000000a00016000000800016000000600016000000500016000000f00014000000d00014050300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 031:4aa1af0000000000000000004aa1af0000000000000000004aa1af4aa1af4aa1af4aa1af4aa1c7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 032:800066000000500066000000500066000000000000500066000000500066500066000000600066500066600066500066800066000000500066000000500066000000d00064500068000000000000f00066000000d00066000000000000000000400066000000000000f00064400066000000000000f00064400066f00064d00064b00064000000000000000000000000600066000000f00064000000600066000000f00064b00064000000800064000000800064b00064000000f00064000000
-- 033:4aa1c70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004aa1c70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004aa1c70000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004aa1c7000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 034:d626c2000000000000000000000000004400000000000000000000000000000000000000000000000000000000000000d626c40000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000c4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b000c4000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 035:8592f90000000aa1000000000000000000000000000000000000000000000000000000009000f90000000000000000008000f90000000000000000000000000000000000000000000000000000000000000000009000f9000000000000000000b000f9000000000000000000000000000000000000000000000000000000000000000000b000f9000000000000000000d000f9000000000000000000000000000000000000000000000000000000000000000000b000f9000000000000000000
-- 036:8592f9000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 037:d000c40000000000000000000dd1000000000000000000000bb100000000000000000000099100000000000000000000077100000000000000000000055100000000000000000000033100000000000000000000011100000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000002000
-- 038:b02415d00015000000000000000000000000000000000000d00015000000500017000000800017000000d00017000000000000000000800017000000b00017000000000000000000a00017000000000000000000600017000000000000000000b02415d00015000000000000000000000000000000000000d00015000000500017000000800017000000d00017000000000000000000800017000000b00017000000000000000000a00017000000000000000000000000000000000000000000
-- 039:500017000000000000000000000000000000000000000000500017000000800017000000b00017000000a00017000000000000000000800017000000f00017000000000000000000d00017000000000000000000b00017000000000000000000800017000000000000000000000000000000000000000000800017000000b00017000000d00017000000500019000000000000000000d00017000000f00017000000000000000000d00017000000000000000000000000000000000000000000
-- 040:4000450000000000000000000000000000000000000000004000b30000004000b30000004000b30000004000450000000000000000004000b30000004000b30000000000000000004000450000000000000000000000000000000000000000004000450000000000000000000000000000000000000000004000b30000004000b30000004000b30000004000470000000000000000004000b30000004000b3000000000000000000400047000000400047000000400047400047400047000000
-- 041:b02415d00015000000000000000000000000000000000000d00015000000500017000000800017000000d00017000000000000000000800017000000b00017000000000000000000a00017000000000000000000600017000000000000000000900017000000800017000000600017000000400017000000000000000000b00015000000400017000000000000000000f00015000000b00015000000f00015000000800017000000000000000000b00017000000f00017000000000000000000
-- 042:400019000000f00017000000d00017000000b00017000000000000000000800017000000b00017000000000000000000a00017000000b00017000000d00017000000600019000000000000000000d00017000000b00017000000d00017000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 043:b00015000000000000000000000000000000b00015000000000000000000800015000000b00015000000000000000000a00015000000000000000000000000000000d00015000000000000000000000000000000b00015000000000000000000d00015000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 044:988116000000400016000000d00014000000900014000000000000000000000000000000900014000000a00014000000b00016000000600016000000f00014000000b00014000000000000000000b00014000000c00014000000000000000000d00014000000000000000000500016000000000000000000800016000000000000000000d00016000000000000000000f00016000000000000000000d00016000000b00016000000000000000000000000000000d00016000000000000000000
-- 045:900016000000400016000000d00014000000900014000000000000000000000000000000900014000000a00014000000b00016000000600016000000f00014000000b00014000000000000000000b00014000000c00014000000000000000000d00014000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 046:9472c8000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b000c8000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d000c8000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b000c8000000000000000000
-- 047:900016000000400016000000d00014000000900014000000000000000000000000000000900014000000a00014000000b00016000000600016000000f00014000000b00014000000000000000000b00016000000f00016000000000000000000d00016000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 048:97c2c8000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000b000c8000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d000c80000000000000000000ee1000000000000000000000cc1000000000000000000000aa100000000000000000000077100000000000000000000055100000000000000000000033100000000000000000000011100000000000000000000
-- 049:700015900015000000000000000000000000000000000000900015000000700015000000400015000000000000000000900015b00015000000000000000000000000000000000000b00015000000800015000000600015000000000000000000d00015000000000000000000d00015000000b00015000000000000000000d00015000000000000000000000000000000f00015000000000000000000d00015000000000000000000b00015000000000000000000d00015000000000000000000
-- 050:700015900015000000000000000000000000000000000000900015000000700015000000400015000000000000000000900015b00015000000000000000000000000000000000000b00015000000800015000000600015000000000000000000d00015000000000000000000b00015000000000000000000a00015000000000000000000800015000000000000000000600015000000000000000000400015000000000000000000f00013000000000000000000d00013000000000000000000
-- </PATTERNS2>

-- <PATTERNS3>
-- 000:4000b30000000000000000004017b300000000000000000040008b0000000000000000004017b30000000000000000004000b30000000000000000004017b30000000000000000004000b30000000000000000004017b30000000000000000004000b30000000000000000004017b300000000000000000040008b0000000000000000004017b30000000000000000004000b30000000000000000004017b30000000000000000004000b30000000000000000004017b3000000000000000000
-- 001:801405900005000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000701705000000000000000000c00005000000000000000000e01705000000000000000000400007000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00005000000c00005000000b01705000000000000000000
-- 002:4aa13b00000000000000000040173b00000000000000000040073b00000040003b00000000000040003b00000000000040003b00000000000000000040173b00000000000000000040073b00000000000000000000000040003b00000000000040003b00000000000000000040173b00000000000000000040073b00000040003b00000000000040003b00000000000040003b00000000000000000040173b00000000000000000040073b00000000000000000000000040003b000000000000
-- 003:900058000000000000000000000000800058000000000000400058000000000000000000801758000000000000000000600058000000000000000000e01756000000000000000000e00056000000400058000000601758000000000000000000400058000000000000000000c01756000000000000000000c00056000000000000000000401758000000000000000000e00056000000000000000000b01756000000000000000000d00056000000b00056000000901756000000000000000000
-- 004:d77154000000000000000000000000b00054000000000000900054000000000000000000b01754000000000000000000700054000000000000000000401754000000000000000000600054000000900054000000b01754000000000000000000900054000000000000000000701756000000000000000000400054000000000000000000901754000000000000000000700054000000000000000000401754000000000000000000900056000000800054000000401754000000000000000000
-- 005:45a25608810000000000000090175600000000000000000004a20000000000000000000090175600000000000000000000000000000000000000000090175600000000000000000000000000000000000000000090175600000000000000000005a20000000000000000000090175600000000000000000004a200000000000000000000901756000000000000000000000000000000000000000000901756000000000000000000000000000000000000000000901756000000000000000000
-- 006:000000000000000000000000000000000000000000000000400086000000000000000000000000000000000000000000700086000000000000000000901786000000000000000000b00086000000000000000000901786000000000000000000000000000000000000000000000000000000000000000000700086000000000000000000601786000000000000000000700086000000000000000000601786000000000000000000400086000000000000000000000000000000000000000000
-- 007:000000000000000000000000000000000000000000000000400086000000000000000000000000000000000000000000700086000000000000000000901786000000000000000000b00086000000000000000000c01786000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d01786000000000000000000000000000000000000000000b01786000000000000000000000000000000000000000000901786000000000000000000
-- 008:000000000000000000000000000000000000000000000000400086000000000000000000000000000000000000000000700086000000000000000000901786000000000000000000b00086000000000000000000c01786000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d01786000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e00086000000000000000000
-- 009:6382c60000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004000c60000000000000000000000000000000000000000000000000000000000000000000000000000000000000000009000c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000d000c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 010:c00017000000000000000000e01717000000000000000000900017000000000000000000701717000000000000000000500017000000000000000000701717000000000000000000400017000000000000000000c01715000000000000000000c00017000000000000000000e01717000000000000000000900017000000000000000000701717000000000000000000500017000000000000000000701717000000000000000000400017000000000000000000c01715000000000000000000
-- 011:e732c40000000000000000000cc1000000000000000000000bb1000000000000000000000aa100000000000000000000099100000000000000000000088100000000000000000000077100000000000000000000066100000000000000000000055100000000000000000000044100000000000000000000033100000000000000000000022100000000000000000000011100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 012:e7a2c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000e592c6000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 013:c00017000000000000000000e01717000000000000000000900017000000000000000000701717000000000000000000500017000000000000000000701717000000000000000000400017000000000000000000c01715000000000000000000c00017000000000000000000e01717000000000000000000900017000000000000000000701717000000000000000000500017000000000000000000701717000000000000000000400017000000000000000000c01715000000000000000000
-- 014:caa188000000000000000000000000000000000000000000900088000000000000000000000000000000000000000000700088000000000000000000000000000000000000000000c00086000000000000000000000000000000000000000000e00086000000000000000000000000000000000000000000700086000000000000000000000000000000000000000000400086000000000000000000000000000000000000000000c00084000000000000000000000000000000000000000000
-- 015:eff1840000000000000000000ff1000000000000000000000ff1000000000000000000000ff1000000000000000000000ff1000000000000000000000ff1000000000000000000000ff1000000000000000000000ff1000000000000000000000dd1000000000000000000000bb100000000000000000000099100000000000000000000077100000000000000000000055100000000000000000000033100000000000000000000011100000000000000000000000000000000000000000000
-- 016:c00017000000000000000000e01717000000000000000000900017000000000000000000701717000000000000000000500017000000000000000000701717000000000000000000400017000000000000000000c01715000000000000000000c00017000000000000000000e01717000000000000000000900017000000000000000000701717000000000000000000600017000000000000000000701717000000000000000000400017000000000000000000c01715000000000000000000
-- 017:0000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000004aa13b00000000000000000040173b00000000000000000040073b00000040003b00000000000040003b000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- 018:600017000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- </PATTERNS3>

-- <TRACKS>
-- 000:180300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000620000
-- 001:642b00782c00642b00782c008c3010e452108c3010dc41100000000000000000000000000000000000000000000000006f00df
-- 002:8c3010e452108c3010dc41100000000000000000000000000000000000000000000000000000000000000000000000006e00df
-- 003:716910000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ee00df
-- 004:755d10a55d10755d10b55d10c55d10045d10000000000000000000000000000000000000000000000000000000000000de00df
-- </TRACKS>

-- <TRACKS1>
-- 000:1806003018005c1900ac2c00d83f00094110315510795810000000000000000000000000000000000000000000000000ad0000
-- 001:996b57917b57e58067f98367996b57996b5772a9670ca08acea08acea08aceadaaceadaae2c23df6c33de2c2305bd73eee0200
-- </TRACKS1>

-- <TRACKS2>
-- 000:2c00004c00002c05812c05814c09c12c03122c04922c05d22c06132c07532c08932c07d32c06044c06002c01104c02100f00df
-- 001:996000996b10996b17996d97008f102a61e84a61e85a66207a604aaa604a7a686aca6b6a996dac996eec996deb99607c7b00df
-- </TRACKS2>

-- <TRACKS3>
-- 000:1000001c00001800001804001804411806001806c11806021806421c0a001c2c001c2000143b00143bc3000114000310af00df
-- </TRACKS3>

-- <PALETTE>
-- 000:1a1c2c5d275db13e53ef7d57ffcd75a7f07038b76425717929366f3b5dc941a6f673eff7f4f4f494b0c2566c86333c57
-- 001:1a1c2c5d275db13e53ef7d57ffcd75a7f07038b76425717929366f3b5dc941a6f673eff7f4f4f494b0c2566c86333c57
-- </PALETTE>

-- <PALETTE1>
-- 000:1a1c2c5d275db13e53ef7d57ffcd75a7f07038b76425717929366f3b5dc941a6f673eff7f4f4f494b0c2566c86333c57
-- 001:1a1c2c5d275db13e53ef7d57ffcd75a7f07038b76425717929366f3b5dc941a6f673eff7f4f4f494b0c2566c86333c57
-- </PALETTE1>

-- <PALETTE2>
-- 000:1a1c2c5d275db13e53ef7d57ffcd75a7f07038b7642548792936613b5dc941a6f673eff7f4f4f494b0c2566c86333c57
-- 001:1a1c2c69405db13e53ef7d57ffcd75a7f07038b764405599404c793b5dc941a6f673eff7f4f4f4b2cec2566c86485057
-- </PALETTE2>

