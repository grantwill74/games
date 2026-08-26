-- title:   Magispells
-- author:  Grant Williams
-- desc:    A word-spelling puzzle game. Inspired by Bookworm.
-- site:    grantwilliams.info/games
-- license: AGPL-3.0-or-later
-- version: 0.4
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
    --- word 3: aaaabbbbccccddddeeeeffffgggghhhh
    --- word 4: ABCDEFGH!0000000SSSSSSSSSSSSSSSS

    ---@type integer
    local word3 = 0
    local word4 = 0
    for i=1, 8 do
        local c = self.bestWord:byte(i, i)
        if not c then break end
        c = c - ('a'):byte(1, 1) + 1

        word3 = word3 << 4
        word3 = word3 | (c & 0xF)
        word4 = word4 << 1
        word4 = word4 | (c & 0x10)
    end

    -- handle '!'
    word4 = word4 << 1
    if self.bestWord:sub(#self.bestWord, #self.bestWord) == '!' then
        word4 = word4 | 1
    end

    -- 7 empty bits
    word4 = word4 << 7

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
        local lo = (word3 >> (32 - i * 4)) & 0xF
        local hi = (word4 >> (24 + (8 - i))) & 1
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
EXPECTED_N_YIELDS_TO_LOAD = 10

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
"!;!s0;g0;e0;d0;s0;n2;y0;t0;n0;!d0s0;e1;l0;r0;t1;g1;n1;h0;r1;c0;m0;d0r1;!e4s0;s5;a0;eA;a1;r0s8;l3;l1;e4;!e5;t3;nF;e17;!d0r1s0;d0s0;d1;d0r0;eD;!e4i6s0;u5;k0;e5;eAi6;i13;a9e9;!s0y0;n8;n3;k1;!d0r0s0;m1;o9;s3;uC;e12;!e26s0;o1;!l7;s11;aC;!t0;t7;r7;o0;y1;eDn2;e23i6;p0;i4;!e15i6s0;e33;r3;h1;g3;i9;b1C;e0y0;s1F;r4;s8;!e0;i0;c2A;i18;o10;p1;i2By0;n4;i1;e9;lB;a9;i5;i10;!l7s0;c11;!i6;a20;e30;c3;!e24;d0r1s0;e1Bn2;d3;aD;w0;x0;e8;r16;m3;e24;!i13s0;lC;c32;g7;eE;!l0;u14;!y0;d0r0s0;l4E;i6;e4i6;c1;!e0s0;a7;gB;r14;i20;!e1s0;!d0;t16;n2s11;tB;i31;e1D;a10;o14;r2F;!e4s0y0;e1B;nB;nE;eDl7n2;!aCs0;w1;a8;k3;h8;s14;a50;a4;m0t0;!e5s0;h66;i45;a12;l18;o4;eC;!r0s0;r25;e10;o8;l4;a14;o74;a42;e15i6;!n0s0;v3;e1n2;t11;!e24i6;i3C;h1F;r0s3E;oD;iE;f0;o29;e84;sE;rB;iC;a0c0;i35;n25;e1BnF;o81;e5i5;d0r0s8;u3;u1D;n7;t27;r9;p3;a1D;i13y0;e1Bl7n2;e5n2;a0u14;u1;c8;i8;d0r2F;t2D;e1i13;i3F;r1A;r2A;e3;u8;l19;n2o9;i1D;aE;n18;r18;iB;r8;o6B;n16;oE;!e26s0y0;!n0;l7;n8t3;s3u5;l16;b1;r0s0;o45;!m2E;oA0;h3;dB;!s0t0;l1A;i70y0;e42;u0;eAy0;i25;o31;!r0;n2o9v3;!e79;a54;e0m0t0;d0r1t1;z0;e8C;l3B;m18;a4A;a30;m7;m0t1;!r1s0;i7D;f1;s3z3;a59;d0r1s8;!e4i6s0y0;!r0s3E;!r0s8;a25;e99;o9v3;eAoD;n1A;i77;e26;sB;!e67i6;iBB;uD;!e1;d27;d7;n39;oC6;i3D;i69;i1A;uB;h0m0;s19;f7;t19;e6E;n2D;rE;!g0s0;e25;!e4l7s0;o25;r39;uE;i3;!e15i21s0;i0o0;n52;i36;!l7r0s8;!h1s0;eDl7;o2A;!e4oDs0;o34;hFA;t1E;!h9D;k16;!l1s0;!e4i43s0y0;e17g1;!d0i6s0;!r7s0;d0t0;aE6;l1D;r10;a76u14;g19;a1e1;e0i13;d0n0;!s0t1;a72;eA2;d0r7;o1C;e1Bl7;e0t0;!g1s0;d0e1r1;!o6F;eB;r55;d0r16;v27;s5t1;rA7;d0r0s3E;!a0s0;s9A;o54;t1A;!l0s0;b0;t39;o51;n65;!aC;i97;oD5;!eDs0;g96;s7;i27y0;o57;m1A;c19;t41;r3D;b7A;t18;eAi6y0;x1F;i1C;c0n0;g60;d0t1;nFs11;o42;a34;r35;l0n0;o46;u34;!i6s0;oA6;a51;e1y0;eE4;l44;l0t3;a0e0;!eD;cE;d0e0;aCe1;aCeA;e17g0;t2F;!d0r2Fs0;h7;h78;e5nF;d16;o41;oC;t4A;i21;!eDl7;e1Bl7nF;e33y0;o49;l2C;i6C;cB;iD;!e15i43s0y0;!e4r7s0;e18;c1C;!t38;u12;aA3;w9;!x0;o7;yC;!a0;o6F;i5D;o5;lB5;p11;eF8;!s0t3;n154;u59;!a1s0;!e12i6s0;b1A;i111;n2A;e1E;a40;a52;i0u5;n12A;d0s5;e51;l1E;!i3Cs0;mB;s0t0;!t27;f8;e0i3F;iBy0;o32;r1s0;o12;e23i43y0;!s0t1E;k1A;r40;o6C;n83;a45;u36;o9B;r8D;u100;i54;o138;a3C;u1AA;l48;o36;!i2Bs0y0;e1nF;a36;i32;e72;a57;a4B;l60;r32;!h0;e90;aBA;h1A;c3t0;lA8;k28;!l1Es0;!d0f37s0;aCe33;r0t3;s123;n5;e0m0;e79;d0n0r1;n1r0s8;a11;c7;s5E;e4i6y0;d0l1;aCe5;!e5i5;h18;aCe1i13;!d0s0t1;!n1s0;a5;l2D;i8F;!s0x0;r34;d0n1r1s8;i95;l9F;c0s0;eAB;a73;c0s14;g9;s66;c7t0;e106;n2s8;o40;i0o1;iCC;!e15f37i6s0;e23i6y0;e1s11;z3;e49;lE;o93;h27;p1C;t28;t20;n92;l1C;o2;h117;rD6;a31;!e4i91s0y0;!g0;e7;i70y62;r19;!e0l0s0;!d0n0s0;o1A9;i18y0;l8;aDe1;hB;t139;a6B;i30;e6A;d0l1r1;oDF;p7;i1F6y0;w16;!c0;a4C;c3t1;n71;!e4;t47;!aCe26s0;!i69;i57;o8B;t5E;!i9s0;!e0r0s0;c4A;s0t1;c18;eA6;n2o10;e1n2s11;e1i6;r5;tBC;hAF;n55;iAC;eAi43y0;!eAi6;e17y0;n179;!g1Es0;!e0t3;!i3F;h2F;!t18;!e26l7s0;m16;n2F;i49;!i0s0;r1s8;a17;!i13;oA5;hE;m2F;m0s0;l53;o30;n2t0;kB;a93;!d0l7r0s3E;gC2;n61;e6C;k53;!i3Fl7;u49;l35;s3t7z3;c7t1;g3B;eAt1;n7E;e31;!s1F;i137y0;!t3;r53;i12;g41;i148;a65;a2;h3B;t7E;b3;t296;!aCe4s0;u207;t3A;sFCz3;n2s14;l0r7;d0e0r0;aF;!d0e1r1s0;d1t1;!e26oDs0;e4y0;l25;aCu14;a76;e24n2;n2t7;d39;i178;s9At7;i72;i41;aBD;!h0s0;!e4i21s0;d1C;!e4l7s0y0;!e4i68s0y0;e8y0;d0e1;e0i0;!e15i6s0y0;t71;oC7;m2E;s5Et2D;pE;a49;n2t1;cEE;n53;!e8s0;sFCt7z3;!l3s0;y16;eAiD9;l6A;o20;e0o0;!d1s0;g11;wAB;o3A;aE9;d19;f3;!eEs0;n1E;r45;!s0t18;m1t1;!e5y0;m19;!e4f37i6s0;p8;t53;a1o1;c0t3;l2A;e5D;!o29s0;b16;a69;y5;r2D;w10;c41;!g7Cs0;d92;i20C;!e79y0;l19C;e5B;eB2n2;!d0r1s0y0;i35o40;a2A;i8Ey0;e15i21;a24A;i27;d1t0;h2DC;d60;e15i6y0;!k4C;t40;n32;r36;u75;e3Bi3F;l28;tB7;c0n2;e3B;e1D1;o5C;k1E;n2t3;t38;iAE;iBBy0;s41;e0g0;e17i95;c4Et0;c7t3;!k1s0;c167;u19;!p7Cs0;o147;e23i21;e1A;!r1;l1t3;h5A;eEAl7n2;i1BB;lF5;l29;u4F;l233;o12D;e1g1;!d0r1s0t1;!e0r0;!eAi6s0;eDn2s11;n2v3;oC4;n2s123;p16;f16;r41;tD2;n77;fB5;!e24y0;k2F;!d0e0r0s0;o35;t132;!o10;r5A;d0r1y1;!o0;o73;!e0l0;l41;a22E;!i1s0;s52;iC7;eDy0;nF0;l5;d6A;e6B;!d0f37r1s0;a1De23i6;e94;n41;!e26i6s0;e12B;sC0;k0m0;e15i43y0;!e12s0;e93;c3A;!n2;e26y0;aD5;gC9;v19;p4A;u10;m163;r3A;e119;!i97s0;g1E;n2FF;e128;e10E;n28;!t1;t2B;e45;c200;p1E;iF;oF;o59;m118;d3B;!o9;a2C6;e1Bl7n18F;!i3Fs0;m1E;i65;!e0g0;t5A;!g1;n20;!d0r1;i13u5;u3C;o98;g3t3;e191i6;sC0t2D;e15B;c3D;lE0;r61;!g7s0;a7D;l3A;!d0n0r1s0;a5A;eDl7n2s11;k18;e1o1;eCE;n19;i1E;aDC;aDA;!e4iADs0;!s1;a136;a95;r94;n2s9A;g18;eDr7;a146;c4Et1;l189;e1Bl7n141;aCy0;e14;e33oD;p27;a1e0;i133;i50;t1C;k7;l39;e5s8;h38;e1D7;o104;c48;a0i0;a0o9;!i2By0;b1CgB;n3A;a162;!l115s0;d1A;t61;a53;pB;o1D;!i14s0;i0s0;h16;h53;s105;a32;!d0s0y0;!e4i6l7s0;y26A;n16r0s8;i14;a6C;i56;d2F;!i3C;u1C;k27;d0g0;!l0t3;!l1;n82;d5;e34;a6;!e12;n212;a1B2;c1A;g1C;s35;d0r1s3E;h130;n3t3;o56;o13A;o8F;y20;s4C;u9F;z1C;eDD;i4u5;e1g0;e1i18;s2A;d3Br1;pA0;a61;o94;b18;d5B;d0r39;n1r1;!s0t27;!d0r16s0;e59;n1o10;t5;zFE;t1B4;u69;r74;h9D;t94;l185;w7F;d0r8D;o1D5;d41;d0n1;a7E;p5;i152y0;n0r1;e0n0;i2A;e10F;sB1;i59;o1B1;t143;f7n2;l184;!e292s0;n312;e20;d0n16;e22F;!b7Cs0;l14A;e106i6;!d1Es0;r3EE;o1F;l5A;lE5;mC9;e0h0;m45;t384;l2E5;!r7;e2E2;e12E;n1u5;u9;a0s0;!e17Ai6s0;o129;d1s0;n3D;eEAl7;c192;u20;t55;!o0s0;lCC;e1Bn2s11;!i18s0;!e15i91s0y0;!i18;o2D;o16;r48;k5;g27;l82;g1A;s18;a0o0;i2C3;s55;r7t3;!m2Es0;i51;g2C;r1t1;o11C;e1i13y0;t3B;c25E;d0t16;m0t71;!d0e1s0;s1E;eB2l7;o197;i3Fo29;n240;e81;b1Cw7F;b1E;a6F;e4i43y0;wC;!e9;h1E;z1F;k3n3;o6;u32;i2;yC7;oD7;eA2n2;!n8s0;!e4f37i91s0y0;a30e23i6;l4C;!e67i43y0;e1Bl7n2s11;!s8;e10Dn2;!eD0i6s0;eDF;g48;!e8;o50;d3A;h320;i24D;e0l0;c55;e15Dl7;e17i6C;l6D;c11F;a25F;e54;z1A;e6D;oAE;d1s3;!e0l0t3;d9E;e135i3F;!eA;aCi13;i31o46;m48;!e0r0t3;i6F;t4E;!d0l22s0;d276;e252;i3A;!e4i13s0;s4F;!e1B1;r46;!f37s0;bB4;!s0tB;aDD;u25;!e3s0;e9iDC;r65;k5A;f7t7;l7E;oF4;tDD;!s0t2D;oCD;i64;!eDl7s0;b7;!i4s0;u30;!d0l7r1s3E;!aCl7s0;!a9s0;!d0r1s1;r7E;h29;e1i5;u3D;i111o40;e101;rE3;r58;m28;d0r1t0;!d0n8s0;!m1Es0;i31D;a552;c92;f108;fBF;e4i91y0;!lBs0;e3D;lAC;e17i442;!e1B;eB2;u72;r1E;c0s1F5z3;!a1;!aCs0y0;!tB;u57;!d0m2Er1s0;b1CnF;!b1Es0;i34;n171;d0rE3;i6y0;z27;o1A;n0r0;d18;c0n3;n18D;e0n2;l1s0;a8F;o3;m1s1F;d0r2Fs0;d0l1s0;g4A;m71;!tF7;!d0n8r1s0;d0n1r0s8;l27;d0l0;a1E6;a171;t8;n2sE;aCn2;g3A;!i27y0;e14D;c46;n27B;c0u14;!i51s0;r1u12;g3l0;c0s1F;!e5i2By0;aDi0u5;d0r0t0;eD0i6;qC2;i90;e15i91y0;h2C9;d4B;eAiF9;!d7Cs0;i20F;b1Ct19;eC5;e23i91y0;rC;!i6m2E;a80;e5i13;c9C;i87;h5B;c3n7;tB3;!l7s0t7;o237;l1EF;!a30s0;!m2Et27;n4B;aA2e1;c0s9A;!i5;a1C8;eA1;n0t3;!e4i6m2Es0;r1D;t2C;!lA8s0;m2D;a90;e12i6;n27A;e7y0;d3i4;i40E;r71;!p1Es0;!e24i43y0;i4n0;l162;!e17s0;d3D;r4C;r6D;!e4i27s0y0;e147;k186;l58;s9C;v38;!e4s0t0;!eAs0;a32A;a188;d48;o4C;s48;h0m0t1;w39;t112;n0r2A;l1n1;o18;m1p11;v1A;eAi27y0;s3B;i1F4;tFE;d0r7s0;e1i3F;l7F;c7t3B;c321;b27;o99;!b1C;!e1Bl7;eB5;!eD0i43s0y0;g2F;o208;r28;a5F;o1B6;!eE;aA2;oEF;!e4iF9s0;a17F;d1E;e0oC;!l7r7s0;i28F;!n22;!n0r1s0;y14;!l18s0;eAiD9o12;a119;eEAn2;c1k1;e1Bn141;!a4Be15i6s0;b1Ct112;t192;r5E;uAE;h0t1;a20eAi6;c2AlC;eAm0t1;n0s0;l77;s2D;!n1;!i14;m55;e40;d78;e1BnFs11;!l7n22r0s8;e5E6y0;!s52;!s3;u1E;a520e9;eF8y0;v48;n1t1;!m0;e1i27y0;!e18CoDs0;w1E;n1EC;a76i13;eB8;r0t1;u54;e1o46;p7E;l13F;!a0e0;a2A3;!a50;n383;!i20;a1E8;d16A;d35;a129;!i97;!eCs0y0;e1Bl7s11;a1i9;s48z48;d40;!d0s0uD;s0t11;a100;i2B4;k39;a25d0;!g115s0;e4i27y0;!e0s0t3;o232;l47;o6E;d2Bs0;l76;rA1;o24B;d9B;!e9s0;k4C;aC7;!e1C1i6s0;o128;!d0r1s3E;lE3;e11;!i0o0s0;o1FB;l64;e60;!a1De15i6s0;t324;s0y0;aB8;!s0uD;!s3t0;d0y1;a97;s36;k3n2;u4;!a54;h4C;h35;n2C;i2ED;l563;i532;n3F;g2D;m3D;!i1F3;l5F;d0r1s5;s1F5z3;rF;c0s153z3;aCu34;e15iCBy0;aF4;n22A;e322oD;d53;d12C;d0r1t16;eAi13;l2B7;l71;t260;sF4;l6C8;!l9Fs0;a2D5i36;l257;aDF;d0r78s8;l175;e27;e50;r1s3;u5C;a88;g63;e9l3;n3s11;i13o5;g370;o3Au1;a113;eEi10;eE5;o1A1;l32;a1e5;i2DA;a1E7;a13;s19z19;s256;l0n8;e56;r2DE;!d0r0s0t0;n19sE;n19A;i63;r1B2;c63;!e4i6l1Es0;e77;r29;k41;e17i27y0;b1Cr1;l4D9;d19A;u526;r295;t12C;h2D;a2C7;c0e5;uF;!l3As0;u6C;i25o46;t49;!nBs0;n170;e142;d3Br1s0;e35;p28;m5;a523;a31E;!hA5;p2F;!o36s0;n216;d1n2;!s0u5;d71;d18D;eAiD9o40;e2;f28;y6F;!e15iADs0y0;i224;!u49;e5C;i393y0;e1nFs11;a26F;rF3;h177;tEE;o2D0;i4s3;e15Bi95;!c7s0;h190;!e1Bl7n22;t92;e85;e1C;!aCi13s0;r77;!e4i6l22s0y0;c0d1;l52;x66;h41;m5B;u1A;e1r1;hB3;!e554;a1y0;c0s3z3;d0r5;i4E7;h52;e17i31;t4C;kF4;e1Bs11;w27;!d0r0s3E;!e209i6l7s0;!d3Bs0;sC5;!i3s0;eAE;oB;a9n3;!n3s0;i413y0;q122;y31;n4EE;oB8;!e24l7;a314;aE4;aCi0u5;i1A0;w28;c0t3u14;b19;i282;d0r2A6;a4CB;eF;g3l1;!m1s0;m1s0;vB;r1F1;s153z3;r18E;u555;s101;m5D;l1r1;!a0e4s0;n2p1;r78;aF1;r7B;r13;aF8u14;e4i13;l1CE;r144;gF5;!i20s0;nFsE;!e4i6o12s0;w8D;d28;!d0s1;r60;t19A;!e1Bi3Cl7;!d0n0r0s0;a1i13;i4m18;!n3;l1DE;t52;m27;nA1;!l18;uB9;!r2F;!e4i6lBs0;t58;l0t0;n1s11;e672i6;a4BeAi6;h0t0;!i15F;k19;k47;iDC;!i13y0;a275;bD8;!e4i26Es0;!e144s0;oDB;d0n2;cD3;eA2l7n2;!e1g1s0;!a1e4i6s0;m39;!e5h0;a300;!aBA;d47;e17i6;!s0w1;i16B;r9D;!d0s0t0;d0s0t0;t14B;o43E;!l7r0s3E;eB2l7n2;o95;e5y0;r12C;h157;m53;e57;n1A5;aAC;!d0l1s0t1;c32nF;a1i3;s391;l63;r1D4;a1C;k5B;t2DB;a49oA0;iA6;!e24s0;d0n0r0;i5E7;e14C;e12n2;k78;l3o10;a0i13;v18;l53A;u73;d1n3;h1D9;m64;s1C6;aDeA;e1i8Ey0;s3D;r83;aCe0;n6A;o534;e4C5i6;i411;u61;!d0r7s0;e15i68y0;n2B5;aCo9;e135;c2C;e1u5;n4E;!e12i21s0;e9F;u51;eB9;o2AE;aCu5;n2FD;e499i6;s53;eB2l7nF;c32k1;aCD;l2E7;r1uD;e0nF;l0tB7;iEF;!f1s0;n39r0s8;uCE;eAi21;!i137s0y0;i1y1;uC8;c0d0;e0i0o0;e1n2s8;o6FF;!e10s0;r264;!r0s0t3;e322;t5B;uC6;!e0l7;o9F;h0m0t0;oB5;e30x1F;t35;n0s8;g44;i1FEy0;a406;aAE;!e26r7s0;iB6;aAB;n1FA;k38;!iBs0;l7n2;x5E;e6Bo6B;r88;e10En2;!d0s0t16;i4t0;!a0s0u14;e33B;n5A;t29;t60;i4n1;h8A;!s0tAA;!lB;!d0r1s0y1;e10DnF;!l7n1r0s8;n987;d0n1r1;n8t19;r163;r4B;d77;!a1i1;a1i1;!e4i6l48s0;z5F;y40;l168;eAiF9o40;s0t7;l7E2;r2C;c15E;t479;!e5nFs0;u8CC;s547;u213;r31E;a9e1;s32;c0e24;r4y1;u85;aEF;o262;n2oD;r225;i70o81y0;e10Bi86;e1E7;!e3ADl7n22;e9FA;e4i68y0;iB5;a104;!i109s0;a20i13;!o8s0;a7Ei13o46;!a9i18s0;rFB;m0y0;o338;n2A5;r1E1;i65A;!e17;!l2C;o28A;d0n27A;a716;!d1;!t7;t75E;e3DF;c49;o2D7;e1h1i13;o12r19F;d0o9r1s0;o53;!d0m2Es0;t38D;d0t1y1;k6D;tFF;!n0r0s0;u53;d2BC;n0t1;n4B8;i5y0;e158;d38;a9i4;r145;uBA;!e4i21s0y0;d0rAB;e373i6;iA1;j3A;n7F7;n2s8z3;h89;c2B;!e4i1C0s0;!s0t11;t4B5;d1B7;t158;!d0r3s0;a4n8;eEy0;u4C;s289;nEt19;c0s8;t3E0;lCn4;a59eE;c7l1;a2CD;d0r12C;!e0n1s0;!k0;!e24i6s70;e1B1;o28;t5D;c8e1;eB50;c30A;l266;k0t0;!e14Ci6s0;d83;r6CFs1BA;k398;r845;i27D;!l7t7;e0i56;a1F2i0u5;e32;lE2;!c3As0;n3A4;lBu26C;!a4Bs0;a284;p16C;!a136s0;i125;d0l0r1;g15C;!aCi97s0;s2FC;aCe1o1;s0t2D;!o29;s16C;rF2;i2By1;i2CC;e5Bi2By0;u7;y68D;oE9;n458;d1n1;!l19s0;t662;y18;!t56;t56;l249;e3D0;e4i21;o2FC;!e1s0y0;h94;e12s0;s3t7;m57;!u5;d3g3;d1y0;e1Dn2;e150i6;i2CD;g96t1;!w225;!c3s0;c3n2;o1CB;oB12;s32E;!p1s0;uBA2;i21y0;a50i59;e79l7;a1FA;iB3;n11B;i1D3;!aCe5;!e26r7s0y0;aDe1i0u5;t1CF;s5F;lEB;v0;g1i13;l25nE;!e5i1;!e12i43s0y0;l3o9v3;o23D;!l55s0;nCE;!l1r1s0;!a80e15i68s0y0;t87;!e18Cs0;n14B;t229;z38;a1n2;i98E;!n0s0y0;g96n4;dE0;o21;!t1E;r797;a0y0;bCF;e292;d3z3;r3AE;r558;!d0l6Dr1s0;l1n3;!iB97s0;t77;d16k16;!t0y0;t0y0;a5B;e83;r3B;w2F;!d0l6Ds0;h7E;rAE;e33m0t1;h6D;e12lB;o74y109;h11E;c6D;aC4;i7Do0;t5C5;s1A;e33o1;i19;l196;o119;!d0e4i6s0;r4D4;k27n0;r27;!g3s0;d1g1;!aCe15i6s0;t7B;i1t53;f0n0u8;e4iCBy0;!a93;iB9;!nFs0;i60F;!e79s0;a1DC;dCC;e45p8;r1BE;!g43Ds0;s86D;m35;!i3;e1Bl7n154;!o40s0;r63;e18B;rAB;d0t143;i25n0;!h9Dm2E;a5D;sBC;t48;e1i178;a3n2;nF0s8;e25s5;!e4l3s0;r75;!i1As0;n28C;!n8s0t3;!e4s0w7F;i198o344;rC9;l5F2;e1EoDF;e601;a25C;i364;e84o1;s14t7;b1DD;e1i0o46u5;fB;d0n3s0;n264;rCD;d0s5t1;d0s0t1;s18z18;!i54;n60;n386;l459;a9n2;!a42s0;e582;a0o1;!i152s0y0;e353;g7A;n31;e34D;u163;eAi6o10;a2An144;hBA9;t171;e10D;j1A;e6DoA5;a1De1;!fC3s0;n4C;u89;n3t7;p4E;a4Ae12;!e0s0tB7;l14;g40;i4F;!e15i86s0;p1A;e1Bl7nFs11;!a5;n36;t3D9;b138;y599;!n2Bs0;eA4i10;!a8;n3s3;u2BE;e129;!m18s0;!i21B;i9y0;c1s8;!d3Br1s0;c32s5;!a4Be4i6s0;n1r16;e10Dn12As11;l107;!f37i137s0y0;l267;i3A7;a7Ee0;t107;a7BE;s29;r4E;o348;r2Ft1;l36E;e1o9;i13o9;!a23D;i113;!o1C5;!s0y1;k10C;eEi6;u5F;aE4i13o9;u171;h1A4;s76Ct2D;!s0u1;!e1i13s0;n201;h127;i750;!o41s0;o289;d0r7t1;d56;!e4i1B5s0;d1m1;r1t3;l0n1t3;d1n0;!e15iCBs0y0;y1B2;a9e5s8;z18;e81o49;l228;i46E;s41u5;a0i32;m1n2;o5A;!e365i6s0;e146;pD7;b3o14;r2;a4Be15i6;dFF;l5D;e63Di6y0;d143;!a4Be15f37i6s0;i13s7;e12rB;!e155i6s0;!i1A;r7D8;n1AC;a0o9u14;l1n8t3;e26i6;iA2Dy0;eABi6;!e15f37i6l22s0;e23i4CD;l2A1;a46C;!e1E;rB6;!pAAs0;r203;n1p1;!e5i6n3;h1B0;!e1i2B6l7s0;e2A;s132;!d0l1s0;!iBs0y0;n14A;l1AB;i53;r82;!t9CA;s78;o3DD;o10F;e0n3;eB2l7n18F;uD3;!e4i6;h3F;eB40i6;!a4Dd0f37l22r1s0;a332;a73A;eA7;!b1s0;n3E;!n8;lF0;s8t3;!e4i9EDs0y0;a2B4;!e4iCAs0y0;m0s1F;r0uD;d0r16t16;!l3;aE6eB;c5;!e15i21s0y0;e968;!r18;a21;r19C;aB;uDB;e23i2F8;m4C;g5;n3B5;aB5;c13B;c7A5;r89;a0t3u14;g2A1;r2D2;tD6;l5B;n917;!aCs0u5;e6Bo2BF;p29;a16C;i4pA0;e20B;r8A;!e15iBEs0y0;i4FD;!sE;iB8;a1g1;e4o9;m318;d0y0;n6C;e4l3;!l7n22r0s3Et58;i18t2D;s1F1;s288;l88;a63A;tE;!e26n1s0;e5BB;aCe5s3z3;!i1Ey0;a50Ae9;n1A3;!a87s0;!h1;!t6A;t6A;l114;tE3;!t2D;oA3;d39sB;i2B;i3y0;!i109;i109;d0n8;s3t3;!a20s0;e1i2By0;!e5iBy0;s8t0;eBi1;!i8s0;l5E;h1r1;f1C;c7t1A3;eDr3;eAi6t19;l1r7;t8D;aB79;!e15i68s0y0;a30eAi6;!l3B;i2CF;!a20e4i6s0;!e15i6s0u4F;!m2Et38;a3o29;n295;s5t0;c1AD;!e10Bi6l7s0;!e4i6n0s0;!e15i6r7s0;d0n0r1s0;a1eA;e0l18;d52;s1C9;e0i5;e0i1;b5A;k30D;m1AD;a1u34;rCF;!e67i91y0;o940;a3A0;eC8;n46;m52E;!oD;v2C;u16F;!e8B6i6s0;b38;!e14Cs0;!n114s0;t28E;n2B;y1D;eEA;!eEA;!c32;y1C;!e4s0t1;c0n0u14;i4s3u5;e1i7D;a2CA;e103;s78F;d1f1;lC2;!i279l297s0;a722;g4E6;e48Ei6;!e23i6;m41;aDu14;s5B;a17Fe1;s20;l1n8;k41B;e12r3D;d2DD;nB24;!l4Cs0;z41;g35;n139;uDC;v3FB;e5n2s11;r2A6;hBA;p55;p5D;d0r1t2D;!e1i6;eF0;n29A;d55;a50oD5;h275;v63;u64;e0o36;c193;h58;v3D;!i137y0;n423;!f37;o8AB;n0r0s8;m1B3;eDs123;m0t2D;h9;n8s3;i36D;i302;p38;!eDl7y0;g3n8;!l1t3;i3C4;d3s0;r3BE;!b1Cs0;!e1FDi6s0;oDA;oA7C;i31y0;tC5;a524;i15F;c0s19z19;eAC;l9;h5E;!l60;m29;!i35;a46;iA3;c5C;fC9;r40A;a314e1;a128;e222;oB3;r1AE;nC9;e5s11;i299;e1o73;e79l7n2;mA1;!i31s0;!r1As0;g3s3;a291;eB2n2s11;r7tB3;!o10s0;!d0o29s0;i1B5;e12rA1;n28E;r118;eAm0;e15i6l19;o5DC;e40i3C;a37;eAnF;a2D5;a76c0u14;o61;e3o8;e1f7;i4t1;e3Fo29;n244;eADB;m2B;!eB20;e23i6o29;e10Fo5C;iE4u5;!i0;o27;e5n2s3z3;e4i19By0;i190;c4Ag4A;o272;d7i4u5;!k7s0;!h3B;m5A;u2C;!a1Ds0;!e155i6o12s0;e10Dl7n2;uEv27;u45;e0i35;i5DDy0;a8CeAi6;i24Eu1D;m2D3;i146;!h236;!t1A;!s0t1C;e4l3y0;!h1E3;t174;cBd39sB;e5i0u5;a1o9;i7DBy0;i4C2;n2o10v3;g1B3;o7FD;o331;e313i43y0;t46;e892;d0t20;s181;e10Bi6;i38;i4F7;l99;e0t1;t1A3;i73;u2BA;i93Dy0;eFDi6y0;u18;!eC1i6l7s0;r56;eDn3;d0r1s0t1;a76e1u14;o6E7;m3r3;e4t1;l668;!l44s0;l0r0;s6D;c0f7;o41E;a1F2e1i0u5;t2BC;cD8;r29A;eAiCBy0;!e1Bi3Fl7;e15i6l44;c0f7t7;c3BF;b74C;!i3Ds0;c1s9A;c4C;c9Ct38;e202;r39D;!o1s0;!u14;r3E;n132;n85;!a0i13;!s0t16;!i290;lBC;n8t1;zD8;a639;h4BE;a2B8;u6;eAi6r44;e4i35;mE9;a5C;g3r78;n2s687;e15Dl7n141;l9E4;k20D;dB3;g14B;w1D;c3s11;s553z19;h83;d2D;!e42;t828;c180;e7D;c53;l0n3;l55;!e4r7s0y0;!e5i8Ey0;e1o0;n6D;!aCi13s0y0;e649;e3F4;a74;n144;o1E7;v20D;n98D;o54F;mCF;c3n8y1;j482;r0s8t1;!uB4;!e15i6m2Es0;a10y0;n1s3;e4t0;oAB;lA03;hAA4;e1Bn18F;!uCF;!e6A1;i3Do10;e5A2;a8C;d3m3;t14A;i6B6;t1AC;e2AC;eEi21;u44;!e15i6o12s0;c0o9;d16t0;eAi6E0;lB6;l1y0;aCeAi6;eEi95;l4p1;c1n2;n3E8;oAC;!bAAs0;!d0l1r1s0;d0l1r1s0;r49;o2C5;rEB;g3lC;b18v18;cA17;t2E1;s242;c13E;a76o9;e6A4;a354;oBA;!d0r8Ds0;e10Dl7;oDD;b53;o689;e5i4;r23F;r3y1;a4De15i21;e1i1A;r181;r80;e24sE;!eDo10;vDC;e2EC;r3A4;!e4g19i6s0;d1l6A;g38;f47;d0n39r0s8;n2s0;!i13r7s0;g1s0;s3t1;e3B8;a51u1D;c0l3;e4C8;a166;c234;!cB1;aDe4;aCe26;o21D;l83;!r7s0t3;z5C;a6Be6B;i331;b1Cl1;r266;e15i6l2C;n2s3z3;d0e0r1;!d0r1s0uD;e4h0;!s0u14;w32;!g16Ds0;!iBy0;i1Fy0;z187;!iEF;rB13;b29;b7An1EC;g5D;lF1;!eFDi6s0;n141;i0y0;!e24i21;!i10s0;o29u14;n1As105t85E;r1sB;e38;e359;c205;o420;!i18s0y0;!hEB;e15i6l48;!i29Fl7;!h38s0;dA1;r0t0;d0e1r1s0;a3DE;s103;!d1E;n1s8;r196;d0l0r0s0;o2AF;lB16;t826;g0s0;d0r1DF;oD1;n22;d8F0;n32D;!t5B;!e24oD;e13;a1i25;a42oD5;n38;i1C8;!i5D;!o6;a0e0o0;x7;p0y0;a50B;i9By0;m82;!d0n60r1s0;iCE;i13o0;t189;b1CB;!e4i375s0y0;x8;!d0l7s0;d4E;!o14;o33C;c168;n8s0;i90D;h103;x2D;a1DeAi6;l5C;i19y7B;t2A3;!e12i21;l1BE;u4E0;!l7r0s8t7;o23B;eDs11;!i9;k1C;o282;t17E;e271i6;nEtB;!i13s0y0;a402;a30e0;b5C;e135i35;!e5t1;e1t1;b3A;m1t2D;!e30s0;o4F;r1s3E;wE3;r11F;aD1;dA7;eCiC;d0r1y0;d2BCt3;d0e1r16;!l41s0;d0n3B;!l39s0;s549;v94;o10v3;z1E;!e15i21l22s0y0;!t16;s5BD;l4F6;m45F;w2A;oA7;a369;o2B4;n18C;e4n2;eDg1;cBt0;c0tB;n0t0;a1e12;d0n0s0;!gBs0;!a52s0;!s0tB7;!eCs0;a4Be23i6;!d0f37r0s0;n14F;e2y0;e12r35;d82;d0r1t2F;c4E;a20o29;a38C;aCE;a4De23i6;!e15s0;!e33;c0m0n0;!b7As0;i16C;!s0t115;n15E;a0e0i0o0;!e15iADs0;eA2n2s11;b1Co10v3;e150i6y0;aAD2;g398;!e15i6s1F;aCe0oC;l180;t1B8;i4o29;!k1A;!f37l7s0y0;e9l2Cu45;a163l101Bu24DC;a0e5u14;gC2n2s35;!c21D8g2714l2D75m35F8o241s1FC7;aEBFc415Ae2467i3BD2k1CBEm2C86o2845p2214s1B4Dt2D4FyA6E;l26C;r0u12;a54i8Eo6y0;l0n4389r1;e21C4;!l56;t3A5C;aFo8B;n2CD;t621;rFE4;!d0m2EsECt1;a1De79;!e4B7l7;!d8Be10Bi86s0;!d0n39s0;o64D;a4e4;a27FFd3B8Ce1A4Bi1F01oF6tD8u211;h117p47s12D5t71;aB73u434;d0n5r1;t1621;b3026;i3168l237;a1BA1b2843c48C4d23B0e15A2f366Eg1B22i22F9k7BFl3D56m4E9BnF9Co4FB5p32FCr322Ds2371t2EE5u40EDv25C4w146Cx4F05;h1Fi69;o4F40;g5A;a0eAoD;eAi1925;e67n2s11;g16;a1200bC8Cc269d260Ce4D58f13DFi425Ak1Al315Am1n32F2p8r4572s11FFtEB0y1;a2F2i248oE7sED8;e8F;!eC1fE5i6l7Bs0;x2FB;!d0r60s0;c19f477s7vA0C;a2F24b487Bc226Cd4707e3B9CfADFg1937h1i17B6j3Al1094m1EA6n3FE4o376Fp443Br38C8s4006t2726u1660v1B37w12CAx2711y4EDEz3BBF;!i5D4o29s0;o45F0u5;!a1eAi6s0;a3A2i64o166r1C46u1C47;n48D5;a3AB2;a100eAi2F3k28u4F;c1n8;e15i55Cy0;!s0t4DE;s7AF;a2CDn32C;t1u49;!i5s0;e12Ei2FDBo10;!m1043u261y0;b1Ag63m88r8;!s0t2AB4u1;g3967k641t38;o29t1y16;r379C;n3DB0;!c3De4n363;!e24i29C;n2t14B;!l950s0;p2C;e8A;!i13l7s0;t7F2;r573;e712i6;m18n0;d89l1Am22D6n82r3;!eAiD9u49;eAiD9u49;!i5F9s0y0;e10DnFs11;eB2nFs11;b3EC8c3C8Ag42CEi4126k2B4Cm37FAn3344p1E51r175s3D4Ct1763uD21v1408w287Bx47BCy47;!a16e24i6o16s0u6AAw16;d28C;!e1s1;t56y56;o32u54;e2BFi970o21D9;!a80e3DE3i6o32s0w1BC;aCt1;e1s0t1B4;!a35F4eBD6i1640l22oCs0u408w169;d478Ce12n3CEsE;f37l4371;!d0s0t27vC2;e1E7Ci3FE7;!e2A9o12s0;e12l48;!a126c2ADe24i6;!a4De4i6l22s245;c0s2Cu14z44;iA5A;!e4iD9Al44s0;o347Cr638;a2CEE;n356;n285;!d77;dA64;!s0u3BB4;!eAi21s0y0;p14F;oEs3C1t3949;!r220Az88;rBD9;a2A02eC5i1A63;nCADr2D2t1A;e0i57F;aDo29u14;u4E2E;f108m49A;e33E6;!e0t94;d3e142;a4B15;l2824;h9Do54uE;c3A78e836o33D9p8C1t4B32;e1Bf7l7n2t1;c1n2s9A;d38e1gB3Et3AB;!f7s6FEt7;rB69;!e17o46s0;!e84i844s0;tA3C;n22B;eF0i2Bk0y57B;e21Bs11;s85vA4;i36sE;c121h17D;!d0n39Fs0;r32D;s506;!aCe2C7Bs0;i26F;!e0fC3h9ElB30m2Ep2EAs0w11E;a5079e2CD7h3752i4AB5o28B5u4E28y2D24;!p119;a1c0s2C8;e673;!cB1d36B0e7f4312k37C8l237En1p1A08r221Fs201At3355v3F60;!d0s0t161;l37DFp3C05r47E2;n1A0;l26E2;n112Dr41F0;aCi1C;!aC9Eg2DBCl1666m2Eo469Es0uB;r16C2s43C0t1uEz19A4;h1E1u4162;!e4i6s1F;m0s34;!t218;b2D2Dc129Fd1633f2A99g2EE8h2A0Ai397Aj83Bm2B67n4F2Cp1411s1CBDt14Du4F48v250Aw58By875;r1555;c13Ed149t451F;d2E2D;aCi20C;a61Di21;i101;!c1CoE7s0;!e5hFA;l5Av518;e1hFA;l49B;l4F76;a1EE9d2C1e1868f4B6Dg172Bi2A5Aj992k1m359Fo1B28p4587r2BF7u34v2D40;aDi65Co29;!i299s0;!d285Cs0;n2s6FE;!a10c27E9e18A9g590i3B78m36DEn382BoEF1p2D96q208Dr22CBsE63t106Cu18C0;n5FF;!a30e4i6s0;n1o9p1t1w1;!d0r130s0y0;!e4i2F3r7s0;f510t2F;o463;e1Di886;i1C20y0;d0e10r1s0;b89i4p51Ct4AC7u273x2FAAy28;!e1l1BEs0;o14p3;y2;!a4545d2ECDeD99i1AD1l403Eo4281t33F1y1EF0;c19D9g334Di24F9n5D2p4F4Fq9B8;e17i20Fo1;a146BeE8;e1Dl2Cu20;a4FBe9;a1E2B;c1BF;a30i5C;oCs174;!d36E0e23i732m4938s539y0;!n22t3E4;l1206;!s0t78;s0t78;d417;k3nF;!e4063iB;e4625l1;!e4DAs0;!iB27s0tB0y0;l2F30;a22BEe14Dh117iBt2A33;!b401Ae12s1A6wF17;n2Do10;!d1e222g1478l433Fm57An17A7r1A8Es4A96t215E;a166eC6Ai43CCo9t0y0;e6Er19F4;!c6B4e1A01h3C53i1819p2127t1489u1CE4w2801y0;aD5e12i3Do69;g5Bm21EFt31BC;n53o9;!e26i18s0;i2Bu3466y0;a42f1BB1l293t3BE7;o73r21E;!g483Bl7n22s0;e20DA;e3ADhCDi3Cl36A;l28n623r2Fv53B;o72u2CC;!b3C8f7E5nD1s0w655;!e15i6m2Es0w7F;d0nA2Cr3BA1;!a1e6D4;e1i137y0;e1Bn37CB;a348;c2Ae1Bl7n2;i6F2y0;!a24FCb1E3g1E5i2CB6l7Bm23Fs0u1BD;a4FC6;e41EE;c4Ag4AnE;a4D22e1i2BB1mBoA56u12;c1E;i1AE4;r412;gC2i25p1q2CAA;c193n1s280z16D;o133;!o31;a32Ae2212;s2E8t2669y28;o4A8;a10e1oB;e9F0i5C2;!e15i2F8s0;a174;a1E90;n282C;!d0f1r1s0v48;l1n2;e683l8;!e209f37iA77l7o1s0;!e1Bi152l7n22y0;i674;sD11;a703e4641i33C0;aCi109;e6FDiBo93;e6C6i9E1;r3A47;e56Au4F;a80c18h3k28;t714;e1m7DCo4Fy932;n2D97;h117o46B;i4B9k53;u704;b1Ct372D;i72oA6;o4FF;a4De543i19Bo9By0;e8AEm1008;i49E;e5i4BB8;a198l228;i4Du418;u391C;b1Ai2D3ClF1mE29s3u2062w0yA67;aDeF0i9;h236F;n8t30F;!a4AB8c5D0e4604h2BD5i40B0k4F07m78Bo17B4qF21s2DC3t436C;a1E0DeAi6;o10s16Et744;h48BB;e4F5Ai811oC6;!o46s0;e12r1EBC;!d3Bi6r1s0;!a5cBe15As0;lCn3B5;e3E19i4F;d0iEr1;e10En48FC;d2A5;z78;s5DB;d1l545s1Ft2DB;!i21o1F5Bp2514s2F83;c2Bn82;c92s105;e1235iE21l3DBo158BrA9;!i45Bs0y62;!d8Bg14Fi262n1r0s0t2D;c0o5F4s105u34;i4286;d0l3An27A;a1l18;!a1678e23i6o9F0s0y4D1;n55rB;aCe23i2F3y0;a12iEy20;n4p1;p64Ft1E35;i20E6;l2B15;l3Br74;b5Al1932oEEFt5Aw1;a345;!i8Ey0;e2D6;a27FBeBC9g43A5h1D26i4342o3BB5t11u1B8Ay4866;b1Cd41g3;i739o81y0;e3BDi3943o909;l23B;t140;!t140;a31CFc4115e9BCn1Ao75Ct63u4BF;o29s0t7;!e67f24F3i1F39m2EoDu49;eD18g31C0s85z44;a40i7EB;a32d0;a8o2Ax0;!aADCc3F61e142i2416n2E6Fo332BtD47u4C9;a17Fc0s19u14z19;e5Au4856;!e0l276t4607;g19n171;e12u31F;n4D01;i4l49E2t0y182;a80h885;e24BDi1632;!i70o325Ey0;e364;!i362p8DBs0;g269n2F87t42A;a43Ee3325i22FCo4236y896;!a43AFd0f37l6Dm2En1r1s0;!p342s0;g2DDhE;a378Be1117i3771o29C1u4F6D;!e40i8Em2Es13Dy0;p4FE9;!u1C;!d8Bh1B7s0;i5Du5;!c0e24;cBf1l12E4vB;fE;n18t3;d0z1E;a4B16;e1Bi6;e10Di6;n63r85u6Ex14A1;!c457Dd46E5e379Bh30CBl31F7o2D7r3C5s455Dw2FD0;!a1E33c3EABe1E59h199i15BDo25ABt0u34;!a8BBc1EBd4819e3AC2g1F2Bi4E26n0r58s0y0;g13FCn1538;e1DD4;!e773i6p236r35s0;!e239i6s0;i24El21EoDAr43C;o9t4E;e2C92hAFi6;!l7uC6;!i235s0;e0l0t3;a4C5Fb4B6c32E7d12B7e42FDi6k2FA3l3E94m3413nE13o2476s1602u2DF9;e4EE4h110i871y0;i29EEt216;d2Bl55s1F;n493A;a39F8o1;n75;e0i855;e1i13o1;i528;!f37l19FFn4CB5s0t2584;l8m7n3C0s356C;!e5i70y0;a254EbF85eB4Ap4DDD;i3469;d3g269m49AzA4;!d0k4Cr2Fy0;a4Be119;b7As32C3v467;mA4;!a76lB;a3E77k1o481t0u1D;!e1CCi6n3;a25Fe4B60;c3d1g3t11;!a30e433i6;!aF57b3571e3AB5i1870n501o42C5s0u2CF2;!c6As0;e15iAD;a57e17o99;l3B1n3533r1;!a7De15f37i43s0y0;d276nF;a2C9Ee12B;!g3l1s0;lA8m1;aB8e17o6;c58g62Fn377Cr39E4t2FF1y1A;u21;c22F4g15Cs0;a1e491Dh45D;b7Am3D85r44B;g130m177tB;!a299Db3E49e1770i3E61l25CCo467Br75s0u3EB0;a3D;d38k140t38;!d2Bn1s0;h509;d48e191nF;i17;a131Ce435AiECFu1BD;s3z52;c19e5n12A;i8FoF;!e0l3Bs0;l5ErB;!a415Ee3DFi26DFl4CDBs0u3C42;l545s5E;a4453o2D6;f7n3;l4530;!e0l0n8s0t3;f1A;a27D;a2F4E;a3C21r280;a403Dy0;aBDy0;l4C91s0;!b15F2fB0m33Ds0;e265l7n4102;iEo197;p37D4t17E;d0r1t20;b1An28B1r5E;!d0l2Fn272s1EC5;a485Ce1EC3o188Du10;!e5s303t28;l29FE;s30A;r16A;!a190FbFBeBC5f3D6Di21l315n0s52;!i15Fr1E;!e4f37i316s0y0;!a50e12i6o0s0;!e5CBi86s0y0;!a10e13D0i6m46B0nCF6o17A4p3E5Eu1FAD;!c47B9s4561;n12As11;e306Bn1B75;i10n0;d48C2e23i4DBBk411Bl3A9An12Fr30Ft1D19y0;l10FBn1;!e83Ci6s0;!e4i6l58s0uC;l260;a12B3b399Cc6A9d437Fe2937f17ADiF68k12BFl385Em1E5FoC76p157s3510t1u40A5v4DEBy392E;!e79i43lCFo10;t347E;rF2C;a20e1Bo4412u5;e15Bi3412;d833;!e67i21k9E;m5BvCF;aCEe154Ef1695h9Di2578mCFo34uAA8;!e1F8h0i3Cl7s0;e2E63;!e37Eg1s0;s11t3;!e5i27y0;e1i18Ay0;b5C9e4A37m30Fp3C19u4F;!e3D1fC3h110i68lB30s0y0;d0r2Fs0yB;!l6Ds0t1A3;!a31Ed3A65e22Fi1133l22ECr3C7s0y1EA8;o1A4;o42u5;lF64;a95e1Di50B;c0sE;l333nFo1A7;v4;!m7Cs3225;a72i72o81;s10DC;fF2n3D91;i4B77;!e12t0;nF5;eAi6m39;u24B;!a173e4i3F5s0;!eA38i6l22s0;aCi1606;c1Ag285m9E;!a7De1g5Dn4FE1o46t5E;c3An29Ao16F;!a0e4iF9o12s0;a0h313Di113o9;e17i21;a19FDn3u14;e155i1493y0;d77CpA0;i1A0Dy0;a1CACo347;!a10d0r1s0;c8r14;!e26i21m5Ds0wA9;e8D8;r28t87;h7B;a4w0;r168;lB3r10;e94o93;!e4i6s0v80B;a51Fe1ACBo10;!hE2;!e135i3F;!a50DBg745i348El258Cs0u44B1;u9DA;!c254h34E6s0t1654;r240;c11d0;e0n0y0;d0f1r0s0v81C;e2154g25Bn1ACFo220r3254;!n64s2B5C;!rE8Ds0;!a41C4c13Be5C7i421s0tC10u14;l421Dn1;!eDDs0;b1Cc58r4AECs43BAt39E7;g1z3;a3FFDe34FB;d0s57;!eEh9Dm2E;t102;a12i8D9;r7B5;b1Cx5E;!e5i2AD0;!e4l7n1s0;i10y0;n29EB;!eAf37i6l22s156;!eB84f37i3EB1m2Ey0;!e24i43lF5y0;g55x0;!e4i21m2Es0t230w98y98;!a41DCd47i4F64l3F75o28D5s0t321F;!a80c120e15i21s0;e297Ei10;a52i9o36u5;m1n1r1DE8;!e4i19Bl22s0y0;!eEh9D;a376Ae0i35D2o12y4BD6;c28BCd4030l10B5r420CsEt3291;!m2En0s0;a28e1D0Bi3F82l755o8AFr303D;!a1466lF3;a76s2C8u34;!c2238iCo10s0tBCx0;a7e45;e1h2AEi3Dk3174;eA4iB3F;e9F2;n442Ep28;a9c4D2Df8g1B7k19E4l3707m333Fp4634rEs0;!d3Ae0i8rE;e33p8;!aCi13;pA8D;p33E;!m2Er0s5A3;e1By0;e10Ey0;i48F3;r3C30;i48F;r19t19;e24sB1;s3555t116;d0r56t87;a1EEe3C99l24DAn682r57;!aCe1o29s0;a42o27D6;c85r64E;a484;a3AEiAC;a12uAE;d0l1EnE;i4m1An1;m0n0;r1t0;a0n3CFu14;h946;!g5Bi25mA1p8D3s2312u5x3ED0z522;!gAAs0uAA6;eAi86y0;b25BFmE9s1;!e4i43l115o9Bs0;eEr19C;a2047e1E0Ci1F32o31E1r10E0u5;!e6C7l47s0;n3490oE1vF83;o6F7;a1e1o38D1;!e5h21ABs3747;!v7;s57vB;a7Dg16Fs19E;aCe23i6y0;g4E85iEl2A77m2B5An18A5o371Cp37A0s4B89u4E5Cv3FEw1C78;!a8E3e2DAh43D9l4BDoADDs0;s4D1;cElB3r25u252;!e4i3FA8s0;k19lACy16;kD2Al1A;a3FBEeB4Ah31DBk75r27D8;!e14Ci43l7m2Es0w3AFy0;l228o129;!b1E3jCA4k4E91mDBn4643p165s459EwA9;!d0i6n49Bs0;a20u19;o41AF;a69o82F;c11Fe5;!d0n282Br1D01s0;c126E;t197;!a0d130i239Fo9s0u14z1A;uF1;d4F;mE9n48;c1Cl1n361sE;aEC2e434FiC27;dD40h305l3774n28E5q6F1r4600vC8;nBt2D;!aCi28Fs0;!h477l88s0t12C1yC;e10Eo1;!d12DDs0;l3D3;k186r2A;!aEFe13Fi4EAAk1o1;t1w10;c6BEs5;a1B5Ee1DA7i3647o13A9u2187y5102;s57;y3464;c0d1n0;eAi6kB3Et28;a9s3z3;!e0g19l0s0t669;n1C6;!i2B07s0y0;a20E9;e18BoAF3u2F7B;l1EEEn1;sB61;a6F8;p12D;c92s19z19;!a4Be4CA5i1B5n0s0;cEn1t16A;n6B1;a2FBFr33F;c2D8;i1Do1A;i521n240p1;g2C1;!c247A;m92o34t5B;n5EFs53;!o10s0u14;e3C84iAD;e17A;!i6l22;!nEs0;i434C;nEs0;r31A8u172E;d2CiFB7mA96n221Br29Du3197vFF;!a406oF;a1B2Ec7B1e4E3Ei4F99s445Dt3B61;a36oDD;!e17i46Es0;a4DECe3205h316Di2F29l2782o3931r175Dt4526u4EBBy328B;aCo1;a1oC;eBl2C;r6F;!n1Ap1r3CF5s0;c43AE;h3At4BA0;d0lBCn363o4D5s11A;a2691b4376d1192e3954h4A7Ei24B4j322Fl508Bn11E9o4C26r4256s2928u4044vAEEy12A6;n2s89B;aA3l219;aEn25;a3BA2i3F8;a283;h64B;!gBi966l69Cn47r3866s0t681;l1005o237r4DD6;s1AB;!a1969e510Fi3B42l1DBp19C6r3A5As1A6u1;l14Fo32u36;b1Ct1A;a4EF0;e142gBm35ACs12AB;a5098h3948o1;e5n3;!b691d58fBC8g185h3E7i20k1l22m314Cn25CDp4DDCr3C6s1FA3t38wA75y1F9;!e15h18Ai6s0;!i6F;!e4s0t3;f7E5i1k899p3162s0t2246;!e6A1i6k22B;a4De43FAi19By0;!r1AFs0;!a1h38lD85n22sA9At1FD3;l3E08n3E02o30B7s2CCBt2F17;v343w3F3;f3EE4;c18n0s19z70;i36o54;!t4A57;!e5f7n3s52z3;!f37l22rA5s1655t2706;!a20i13;m76F;i34oB02r45CuC8;!e76As0;a1e17i9By0;!e1EDAi41D8s0y0;l85;nFs11A;nFs1F;f31BtBv3;r486;e1Bg3Al7nF;b0e0s8;c210D;e780i6k0lF2o14s8;v761;c3Dl7r4407;!g19r0t19;o47B;l53r3;!e4C0i91y0;!a2BFt27;a0c5Cf3E1A;g25Bl11Bt61;l7ED;!k1As0;!cB1i1Am1E9s0t7Cz284B;!a4C4Dh1As0;s0tF5B;e5o46;!a90c4AeD0i21s2EBy2FDA;!e5o46;r3964v63x120;a1e1Bn2;iE8n145r164t0;p45;f46g544p4C49;a4DE1b89e33F2f612h10FjC26lBABm1C52n38F5o49D5r35BAs2EF7t46D8u1AAw3215z37C;!e529i4D14;!c242Bg50EDk1n421s1203;m1An4637;!a3C51c33F8eB6f385h248Ai2697m2Eo10s82Bt32B7u3D5Cy4B3F;c3m1;g48t3B;!a67Ec3542e23h1DB0i6jF6k47l5Fo390Eq735s3393t4C7Au2AD1;eB8i4E68o126;r28BD;f3DB;aCh89t2A49;c2188l2139o45w6A;a689h203Ar35B3;k1s2D4t47DE;a340A;aCbD7y1;l58t5A;a43BBi4EC3o4514v22C;i2DAs3u5;l1n671;sD3u5;e12r46;!d0lB5;oE7r18D;a492Ce4218iCBo24CAy0;!eAi4CE0s0y0;a720n1405;s19B6t504F;e113;!d0r1s0t3;e0oDu14;a4554e3C34i46DEo1068u4A38;bBpA1;h3k28;b89l27FA;m473;l4BF0n3;l5151;r362F;!a4Be4iD9m2Es0;d113n1DBD;!a13Cc13Ei1C2Fl8m45A6o431Dp2Cr808s4444u2083v38wE8;!aCe3A29f1D8i4C00l22s3CD2wA92y0;l2Cr89;e24l1Cn1;!bB4fB0g5023l8A9m2Es0;!e4i6nD7s0t4A;!e2627i21oFr19BAs13D;r16sC0;lEBoF;d4C76s256;i10A5u5;a0uD;!a821c13Ad75DeAf5A1h4877i6o1EDr6ABs0t3AB7u372B;n1B7;c386Bm1s3C1C;h4FAo81;!b2F5e24g39CDh2348i54As3E2t26D6y0;!a43An0r1s0;!e0g4AAs0;!a291dD8eAg5Ci29Ck1748s0;b177d1840h1i9l1B0En237Ar19ACs139Et1144z3811;aFA9e17;d276f38gA4;e3BFBi6;o4609;u292A;!h1r58s0;!c3F55eF98h2ABBi6l199s353Dt1930;!e0l3Bs0t19;o9C5;a4D6i3Fo29;!eC1i619n22o9Br268s0y0;!t6C0;d0e10r8B4t16;dF5sEz6A;!p1Es0tB3;d0e0y0;e4EB2;gA8i10n2F1Dr4750;e1g123Bl483Er2E14y84C;a2F23e395Ch4B9Di264EoD34r3432u5AC;r3B9;!d3As0;sBA;i49CC;i6o93;eAi1564o1;cF5t0z1A;!b4B0c381dB7l2817n19F5s0tBCEu90;!i27;!a1D0eD52iBEl2Cm157s28E8y0;eAi8Ey0;eB2l7nFt1;l0s1AEz613;b50EBd14CDg179Di472Ej247Fk3BFAl4129mD4Fn2621p4B84rE09s4E72t499Ev347F;!eC1iB9EoD7s0y0;c3e5f7;l38B6sB;l75s1F;r135D;r494Du59;!eAg60i6s0;a130Ae2CFAgCE4h33C1iEB1l4418m1An214Fo258Br22F5u35D4;!d0l1m2Es0;t842;!b2A0e239iADm2Er286s0t1EA;u396C;!e23i21o1Cs0;l1C3r3CF8;u7E;a72lE0;y102;!e4i21k28s0;o32DC;bBc32;n3Et3;!n8t3;c32g130;!e12y0;dBiE1k251n136Ar43A0sC5t61;e1DsA4t973z3FF7;!e135Af37i21l22s0;a1e24f7o5006;a8DAe0iAC;b1Cl13Fn386r1t19;!a10d395e4D3BnDEs4F3Ct127w7EC;!eDDh9Dk46t94;!eAi26Es0;e1FDi6;i1DzD8;c32t61;!l7r1s8;a4i178;n1959;r144B;a51iE8m251;c1386d2Cg12D0s3B0t428Dx283;l1o29tE3;!l1n212s0t1A;e7D6h72Ao134;i1Du34;!a0e4iF9s0;rBs1F;eB2f7l7;e1Bf7l7;c49D7d675k2E7B;a17Fe1k5Fn5059o29q783;!l0r4t3;c48BCr28;!a10i29As0;g11n1;n27;n1B3;e497C;n18A;eAn2o10;e0h0i9D8o29u158;!d0n2298r1s0;a12e23i2B2;s1FtBv3;d0lB3;e341A;e37E;a20e3Bi29F;l27E;a1Dl219o748u73y0;uDF;eF0y0;w2FAB;m56F;n576;d0r1s572;!a6i20o1D;a107Ce3643i388y0;a3EA3d127e458Ai216Ek696l38D3o24FEt2D3Ay47A6;i8Fy0;r3829;!e67i43l7y0;a69e129;!r6CCs0;a1eD;e5i4133;eDi6Cy0;b1CgBt1;!d0n80s0;!e4fE5g30Di6k1l28n0s0t1C15;!a3042i4ACAl5A1o4759s0u50AD;!s0w28C9;e1u4815;e18Ag0i70o29y0;dBtB7;r2B85u12E;o8r3;!aCe0l3n2s1Ft64;a167Cb58e4B91i366Bm28CEnF39o5D2r4EF7t4Av3B2;!m4472r2EB8;c3iC;l63n386s8;!l1E1Fs0;a2BA9;c43DBd4627f39FDg2D9lEC7m12A7n24C1p38A9r1C69s3467t42C2z2CD1;d3m1;n2s3t7z3;a266Ec4191e2D16gA75i1159l2F56n2E1Eo3CFAr3450s3766t346Bx3D39;i281;eFDi6l2C;iB72o40;!b262CcC2DeB6Ei450l4FF4m4A6Cn22r3980s4B06w4135y574;!a80e1AD7h5004lA22o458Cr6ADs0u4E69;!i9l7;s283Fz19;!g2E8AhE20i12s0u9E;a4Be2E7Ei6m8Dr4BF4t39;oC5;e2E0i68k1E01y0;l39n16;n16v5D;d5153e0tB88;d48iEr48;e12Ei152y0;eF63;r1y0;!a2DB2d3F66e1g2ADEk1m2En3006o492Bs0t1;e35Ei15D5o3F78p263u500A;!e15i6E8s0y0;t78;n421;e1Dg1E;b5Ac216Fe184Af64Fg354ClA6Bn152Eo5Cs56;!d0s0t42BD;o29s1AEu34;a50h1D02;d524;a2F0FbE2c23D9e3665i32A2k20E0l161Fm1Ao2A10p1Au40C0w656;!d0s0u12;!a1D9Ce4D4Ci1F91l44o2FC3r3C9Bs0;a10A3b3EE9c33B8f1mCE8n1558o3D3Fr121s22Bv2Cy41CC;!d0f37n8o10r7s0;d0n39r3Bs8;!c65Et38;lDF6o43D4rCuE;!g4Al2ECs2Ct1x0;!a76e4i13D6o6s0u14;n41t1;e1Bn1FC3;u2;m7A7t4553;s3AtDD;!a429DfB0i1B46p25FEs0u4423;s1F5t4Ez3;p177t45F6;a50r9u59;l1t1;!cA06d71g35p267Dr61s0x35;e449;!c2Bd6EFg227n3075s9B1t47;a1e2646;b19g7;a36e1;!aCiCCo29y6C;d0e0k0n0;e5i4o46;n2v18D;u2AA4;c4A74n2o10s105v3;z16E8;!cB4d1CCEn2o10p12Bt10E4;!e680i2B62r6D5;e5l7t7;o61F;!e12Ei6s0z68B;!cBe0r7s0t3;hE90;e1D79;a1De2BA6m1;!p11;f499Ct4653;a3C0Bo42;!l1n59At3;!e4EF2i17EEs0;h2B;h11A;!h1F;!a391Fc38E9d4435hEDn9FEs13D;s3F4w1EB;g185l1F9;!tD19;!i21s0;a0l2C;!z3321;!o2D7;!l0r7t3;l0r7t3;aA97e99;a10o10u34;e80Dr59D;i419C;cEe1;a327De17;a1F2e4;i4n25s550w1A3y1;eAF9i6;c132Ee2033fC6Cm248Cn1ECFp4502q126Bt222Ev4655;i3F1F;!e150i17Bs427F;d3063;!l7n22o29r0s8;!eF8;!h376;!b22ABl7n22s0;l6Ar36v19;a1CEFe4CDCh8Ai3239o2FAEu3626y2B3F;!e24gA4i60Cn0s0;a42i6;o5C6t2F18;!a1B9e4i383Ao1s0y62;!k28r46B4sC53tF49;!nFs11;c0e10DnFs11;e5f27l9F;!a52b20Ei49Fn22oA9Ds0t1976u3D65w385;!e4n0s0;e6A4i37E9o4709;h477o4D5;!t1ED0;e159i194o12y0;p9C7;d18Ae2837i4v1E;b4B0d21DEf3776g869l14B8n3038rFB4s457t3069z49E1;t197B;t151;!a2A6De67i2151kF3l22m2EoD7p23Au4Fw455;!d3B4Am2Es0;c32s1F;!a591cD1g286Ai69s0w33Ax87E;!a61o108v1F1;g1D43h2419;a2D11e0oE7;h17D7;a3F14b12D8c305Fd448Ce481Bf2A16g17DAh5i4B0Dj440Ak1ABAlDA2m3EADn4261o2457p18D0q46FBr15F5s30BAt25F8u1D90v3462w41BAx4491y3073;l437D;d3B4Fl1010t14F3z187;!l140r28s0;eBo3958t1;!d0o9r1s0;!a4Dd0l259n22r1s3E;c381d3455g318lA8n396r134Es3FAEw1;!b14Ee4iCAs0y0;y39;n725;!d0l22m2Er1s0tC35;oB34yC;a1Ce4B2Fi5m1t2D;aAFC;!e4i6o415Ds0;!e4i382s0;!f1D8s156w11E;i50uF;rEs19;!d0s4F8t2D;!e3CC6i86y0;h2DF7i495A;oFA0;!l16E6p3FAFs0t349B;e93r2161;a4A8d0e4l47CAnCACtC5u2679;!e4f37i30Bs0y0;e84E;!e252;eDl7s11;!e4s0tB7;o203u2B3;o301;i49D;i10F;!b45F7c1E4dAC0e4f14Ei44Ek28l4A4m2Es4B99y0;!l22s2EB;!b3A4Cs0;iC8l5F;a1n3As1F;a3C91r94uB;c3Ae12nFo1;mD2;lBs3;h1Ft39;!r8DCt286E;eB6;c2AD;e0k5At4673;!aCi35u4F;c2Bf7;!a667hFA;f31Bu1E4Av3;!e4i6AFs0;n4437;dCFt19;!eABi3C0Eo24ADr19Fs0u1118;c32r48;aC4Fe2A21i13DBo4B92y146;c19d0r1;!f37s0y0;p5Ay28;s7y0;a80e3C86i3C;!d0l39r1s0;n2s9Av3;!e15i6o29s0y0;o14r434;l3157n145r2CC8u1894;s3672;d1Ae1B9i1B9o4C3Au3978;m279E;n3A4r278F;aEA0;tF94;!a4Be1FDi21s0;g46;g3u17;a1De24;c193tB9C;m101r1036s226t38F8w240C;d28e10En28;!d47e10f3B68l35A6m2EpFBs3043w9B5;a132D;a0o10;!a0o10;!r55;e99Eo27DyC4;!a76s0;aCs0;!a3744e15i6s0;a85c3000nA2Cr140B;a44C;!a9l7s0;l5Cm501Cn1q122r1F37s2490tCD5;a41D2e1D1i4968;cBd45BFe162Ei4F36l3BD9m24D6o4AA2p3831t1C4;d160Fg4141m1D7Fn671r31A6s1DEAt28;!e6B;oA91;o3203;n0t5E;!r4328s0t4A44;eF1h145A;b31C6c119Fd230De352g4186h1305l4CE4m20B9n4D61p3F6As18ADt2FBC;i16Bs394A;aEo50;l16C1r1A;iE5y0;e24n2s11;!d0i6l22n69As13Dt16E;m107t1987;!e154Ah17FFi29BFm1EA1sC86t4FA5y0;a0c0s14;l1A4;f2F;!b299Be252i85BoEs0;e6D2i86;a4E97;a30i2By0;e1i31;!e5i31;a2125;a195c13Eo13E;lEn8p1B0t19;i56uB6;h3B98iAC;!a0i6BFp436;aAEAg3D9Aj2290l1DBr4832s3Ft4ED9;!e327iCBs0y0;!g1r0s0;aDFo4721;r6Dt8D;c7BDuB8B;l4391;o2DEB;a20eAi2239;c1FE2k1E02u73;i25m1A;aFF6u9F;!e4i6r1As0u10;!a57e1ACDi68s0y0;!b6FBs0;a56AcB4e67l4E21n915;!l1s0t1;a995o6D1;c254e37CDh127i136Eo2F7ArAB5t1166y0z2721;a20i70y0;o2D5Fu172;a126e1;aCeAi336Ao46u1Cy0;!d187g2Cs0;!a173p1sECt1w169y98;e0n2s11;l3DDBn1Au556;t39v48;n1FFA;n1278;e0h2DC;d0r16y16;n11Br121sC5tB;e1Bl7n2oEs976t7;d0n25r1;a30g48u19;hC;!e15i1E89o45C8s0u6C1w98;!d0n3C88r1s0;!a388Fi3477o5s0;o26A;a30eFDi6l1B3;a4Ce1;a2CE4e957i4A29l2Co36E5;i652;n1s3u5;!a7B2e1CA6h1DB3l3EFFo5D0s0u3A96;r25A0;a40o10u69;!l1s0t87w1;!b1E3e1Bl7n22o1;cEd49g2Bn7r27Cs5;a11C;e49C7i191Ds46B5u0;a4F19;!a39Bb17Ce15i6m2Es0w169;!a1l7;b1Ad28k28;e3470;a59y0;c2Aw1E;b1351d42Be41B4f4EE2m357Bn145Et378F;e294i6;!eB1Ai6;a1FC2o6C;a40hB;!a80c40C9e118Bh2C98i3991l48D1o0p32Fr21Es0u24D2y0;!r37A3s0;!p27s0;o10t27;cEm118r12C;i6A;a31e31i30C0o12;n16r0s8y1;a375Fb4782o50D;!a4DbFBe630i21l47n0s0;c45E5i434k2Ct1Ev89;dF2r11Bs4577w38;!a4BF2e15fC3i21s0;!a136e1h0i4997o27Fs0t42F8u4F;aBF3e89i1C;!c9Cd47i6s4913t47;a9A0e23i2B2;t37AF;!e155i6sB14;eA2o1;!e15i6l2Cr3323s0;!b405Dc329e4f3130i21l213Fm50E8r471Ds276Fw281C;u2C2;a26C4e1372i2451j948l41A5o127Ar1EBEu2552y3BC2;a45A4e4AE2h15F7i1B60y0;d0nEt1;!d0l1r203s0;a1728c53BeE52h4EA7i241Eo285Fp1A22s3ECAt4180u1920;t984;b10Ae268Do49;a97e3AEi6Fo48F;a41F;lD3;a4D54e4AAClD4Bn16B2pB62s4CE3t1083w265E;o29r48;a1196e3797i394Do3ECFr3B4Du9B7;l3370;cBe67;dBs36;a3E88;a4800e1A8Ci100Eo1609u265Dy4362;b8;!eAi6o1s0;a4Dc541d285;hB3lA5;!d0l3Fr2CEFs0;eEi0l44o0;!c4DFk4E65p4E11r0t140v50FBz7;l47C6p1DBFv4055;!a12d19Ei2A56o198Cs0u47F8w5095;!d0s0t1w7F;!a1DeABDi1C09;!c9Cs0;d6As0;!d6As0;!s0t28C3;d409;!e1Bl1A2n1244s0;e495;!n8s0y28;b429Cd11Eg227l1B59n478Er439CsC5v21E;e5fF2nF;!d0l1s0t1y0;!a2925e21FFgF3Bi2F76u14B0;g1k1;i125o3C9;n28r0s8;s3t21Bz3;a62Ee242Fi3EF2l3AFuB9y0;!a28AFd131i470l1FCs0t1;!c19e0i10n3p4Cr55s0z9A6;aC56bBe2E51i448Fl3C6o3799r3691u2399;!a10l44u10;n1FA7r4A0Bx64By3E5C;!e4i19BlBm2EsECy0;e23i86y0;fBFt75Fz1BD;i4r0;eFCAi317o291;g4A64n28s2Cz2C;!g3FAArA7s0;!sEC;sEC;!e40iBo1p151s0y0;!o3F4s0;!e3279i2DFy0;u3B97;!a3D03e1195hCB3i6n3FDEo3FC7p1Es0u172;a28B8;l3BE5;e501Di4F9Dk15El484FmAE5;e36BFi6;lDE;r78s8;e3D7iCBl2Cu4C1Ey0;!b454Be327i250l20As0w1BC;r23F9;!l2B5s0t1;s0t1E8;a1FB;!a1C66b25D8c3728fF4Ai28BEl1042m4A2Fn1C2Ao3ED4p9BBr2F7Cs0t10B2u6ACy0z48BE;i8Fo28B7;a1E86c1EADh4151k2B78;d3An1;!l160Es0;e23i6o8C;a32Ai16Co9;!aC4Ae4f1D8i6l22o5F4p16Es0;e1n2653;cB7Bn1A5;e514i682oAC;a403;!eE1i9DDs0;!e24i4BB;a70E;r15E;l38A;e12h21AAiCu49;l3A53;!rEs0;i5o6Ft94;!b12Bc4B82e2366f3EEDh5086lF8Fn22p4EDAsDE1t3C15;nC9r2D;e1k3;k39t0;e33i5;e33i1;n46s23A1;e1CCo1A7;!a34e14D3i21l7Bs0;!a31E2e14DCh3F3Fi2FB5o5Cr450Bs0t511y15D2;e605i922;h10F3;a27E6m229t1B2B;y101;!d0s0y28;!l1773n0r28;e191i290;!a0i15Fl1Es0;e6Ei956oE1;e17u34;f89j0;e1i634o29;t8ADz1A;!c7C4s0;a72o42rE0;b1c19d19;aF2Ee4840i1F0EoF38p640u3839y1598;i4C8w0y1;a162d0l1o29r16t40D9;e17i21y0;aCe1g0;r8B0t40;!r12Cs0;c2822e861fF2gE2n2866v4979x0;!e6A8r280;i5EBoD55u1CFB;c0e0;!c0e0;!d0r3EE8s0;l2ACAmF6;!aBAt7F;!l3EFs0;!a273Be1s0t511;!s0t233F;e3352i6o29;!e4927i1428r1AEs0;e411Fi6k16;!b6Ds0;h1114l88r49FF;l3335n401Er4238t1023;e23i4CC;e30i35AoD;e0t39;cD1x55;a0e17oE;!e5i51s0;c32h1i3142nEE4s2A19y59E;l13;b3D4e6E;lA1;h3CF3;l1F62;!c541d0l7m5E8nC34r15Es0u4F;!b31DCc1C5d363Df3CD1g24BFk462l409Em1DD1n176Dp29A2sF8Ct1EBv4D31zBC0;a28E0c2F7d0e334EiE1n8p30FAsE;p2DDF;a1B56i2EDr1D8C;!a4De23hAFi21o3862t1u49;n0u5;e3AAi4E7CkCDu14;!h1l497n2657r2C44sD0C;b3DFCc1A23d1F58e44BAf3A49g1A64h1D31i2AA0k191Bl3F95m1BCAn5081p3820r3653s4C63t125Du3CF6v4BC5w4743y31F5z34AE;b1DBg8Ai1s3161t4C07u0v3ED6;m0s8B;!c13Ee1CCi21n3o35Fu4D;c136tD4;e71Fi7C8;b1CgBr2E9;e4E9Ai32B8;l5048;e30D1i97;e90Ai6o10E1s82;!c193g3s0;r25v3y1;z2E58;n53F;!a1C5Ec254CdB8Ee1BAAf1k5022l4B2Em2640n50F4q735r3BCBs1941t2D59v1AC4w2EFFz0;!a2057e1i70s0v2CCFy62;f3lC;s216t0;e25y0;o98u3C0;r0s8v48;c4920g370p41DEr4734v2CACw89;c254d36D6g1191k5090s0t4A77;hAFt28;!a1De4i29B7n38o11Ds0y0;aB76g63n85t1v103;e5i1D;!a1D3b10AeD23fBFi12E0oC8Ds0tAAy33EF;a9E1d49o3ACAs3AA5t4F83;e0i125o29;!d0e9l22r1s0;e23i21k63E;!l300Bs0;!i109l7t7;!aD44b1415d75De4C09i43E5lBr1055s4C4y62;a2380b20BEc2F39d102Ce12BEg1294h1i3A75k11B4l1B78m3CDFn423AoC47p2185r35BDs4448t116Fu1095v4201w1758x0y2D29;a49o2D0uC;e4B6Ch35;n11E0;e1i171;a7i9;c4Ee12t3B;g622;a2501e99i4079o4u1952;c92s183A;e6Cy0;t1AF;!a235Do36;o50B7;i2EAF;e5D2o45C6;a156Ae3F99;e3Bi97u69;n8D6u4C2;f2E6;aCe84;!f19A7gAF5p4426s0w535y0;aCe4;p653;d3Bf2Dl26C;g1DD;!a9F9eE24i6m1E9s0;aE2F;!e335i4420t5DBuD3;s2C82t2AB;a30B4eBBBi6;aCu4F;a1DE2b377Ae1g5025i187Ek47l34C5o32EAt443;n164s0;!b1E3d0e34l25m1s0wED;!a824e4i6s0;u61C;t3A2F;k2840l3A00n32E0p97Ar1703s1AD3t394v306z498E;g96r19s8t517;m3BD3r1F2E;!m0o10t0;bF7m89p315;a8t1;!aDi13s0;a4BAAb485Dc2300dDB6e1862g3925h495Bi1784k46D9l2DD0m27B5n3447p3ACEr2ADBs512At4F34u4304v1F4Dw4DA4x2C9Cy50ECz486D;!e4i4B39l175n22s0;k1o0;!eD0i2FBAs0y62;!d451g3AnAAs0;!l2Cs0uB;!c1B02l57sC5;!i15Fo29s0;r4s5;!aCi308Cs0;!a113s0;!b42F0m7Cs0;e30i248Eo12;!a3528b4A63e1D32f5D7iF58l75o1568p12ACs13CBu473C;d0t21F;h44Ds7B;a87e3BA3i4270;!i87o3353s0;a36e202pCFt3Dw0;!e67f4878i4F62l22o1EDpE2t2BFAu583y0;!a298Fe4544h191Ci787o1r2BE2s0;n4F0;!a2221e5h305o503F;e1m64s11;e1s0;e5s0;r5EE;aD94;!e4fC3i3EAAm626s0u408y0;a326e12o1A9;e3CC3o1A9;!g3A1i86;i16A4;!d0h225p445r1FCEs0;eEi5;e1l2Co98C;r60tB;aC1AeFDi10A1l175y0;!a22Es0;l64r64;iA47o54y0;h584;!cE;f2A7;e2493iEF;e23i21p2599;a2AcEl1D;i3B3A;e8t1;m71t2D;e503;e1Bn27B;e23gBi6o40r3A;!c305e3EC3i3901j35BFl3853o515p122Cs39Au1F0A;c19FBm38Cn4s85;a162e3E11i20o42C3;f3F;!i326s0;c32o11Cw9;!l7u12;d3Bn18Et136;!e4i27y0;e84i27y0;!c5D;c5D;l174;t0w7F;k0m1t1;m1815p9C8;!c4Es0t1;d714;c30Fe7Dh4DF0k1p36C2s15DEt3A17;a2AE4d30CEi469Bl1381o28D2s3D77t772uA5Bw410;vB4;d26Dm5F8n1s972tD2;aE6e14Fg0i8A2o9B;b3r149u1C3;!d0e1r1A61s0;!p955s0;a76i87u14;!e23i3D2As0;!d13As0;cCC4sC5;!a3865g3DA3s0z4676;i470o2FA6u6B2;n171p35;a4A81e4EBAiFE6o422u3AD0;t8D7;n65r19t19;h3A1;!s27F;g44l180;e1C77i19BF;!d9FCi0l38o0s0;c6EAd0f9E3l1681n47EBs3AEFt2854;!aEFb50C0fB8DiBE3l6Do5Ep3396s0;a7e0;n16A;a30i17CFo10;a43FF;u3B26;uE8;!b5Fe15iCAl22m2Es0y0;iCCo46;s19tEE;m0r3;!a3ArA5Ds0;a3FB6e87i31B5o1rD6zB3;s432;f26B1i521m88Ds45v2AEE;aD4i17q914;h77;!eCl3;t27u49;!a4E4e15g1i21o29s0;a1EBBb3FCc3E7Bd2D37e47F6g2D22h203i33C8l2213m3080n3331o1035p301Dr4D85s4FA1t8B2uC8Ev47AFw20FCxF18y33Ez41B6;d0n0r8Ds0;a650;!s0t2BC;e1i3B84o57y62;gBm1;s1643;a31D5i259Co17C2;!aBAh0i6s0;!e4h334i6l55Es0;m2Do10;eAi6n226Dp0;h2B01;!a372c380e4i68s0y0;!e2C20s0;!b7At1BA;c1Cn2;c1743dBeB44p2F65r3BB6t1Ax3FB9;!s1ADu5;n4C0Cr1t30C3;!b45CEe945i1116l1292o1D1As0;!nC4Ds0;!e4i3s0;m2AA;eE1By0;pBt82;!a10b20Ee9gFF7hEDn12Fs2255tB4Bw17F8;b7At139;!d0n401Cr1s0;a54o6B;b82;!a324Cb2296c2287d26C1e160Bf3790g237Dh4A4Di21j2A36l41CAm4948n4507p4589r3CDBs4503t2178v1958w23A0;e4C6iADo10;d0t204;a1e10Fo147t1;a23D5d14De161iADEl204Do1F82s2900u1270v3415;a3DDAb1929c24CBd1494e4846f2B9Eg12C0h42F2k3E75l1BA9m3C7Cn3154o128Bp2934r4C2Cs44F5t1C54u2258v370Bw8Ax1CAz1434;e191h3B45i21k46FAt3C97;!e4C1iADy0;h7Bt3004;a1De23i317;a36D3b2B3Bi3C41m4DC8p2811s4989;a1194f7nFo29;c2E8h83;!e182i6s3CE4;!b58Fm1FCp38s4D05;y75;!a0l7s0u14;e0l4B0Co0r45E0;t469;!a10h263i1l36As0;i70E;t19B8;!d3Bi20r58s0;!e1p4A41;!e1D;e332;n1398p359Cs2C5Bt3984;b42D8e1CA1;c3r1t3;!d39i6s0;!e1Bi9ABl7n22p63r3AB9y0;a1e239i508Ay0;l30DF;b2E90dC64e32g2D9k2Co1C65r2252tBE2uD0Bw1057;dBs0;!eD1i7Dl22o2C16s0wA9;a6C1;!d1002i6r1s0;!h538s0;!a3572e352EgAD3h221i4A95l187Bn25A2o412r1955s0y19B9;e15i6o1A1;!a14ACe602i3373t67Fu49;aE4o9;a9o9;a903e8B9;e10B9;o2D9E;a961i323Ao2A45r45Cu659;!a30e294i6o12s0;!a1B97d1B66e512Ef0i4BBl882n278Cp1r58s31B1;!i496As0y0;d0y87;e348F;i152l44y0;!aAB9e9i4193o4657;i173;d3BAAe34f1F34g4712i1A8l4F81o3F1pB;!e4f334i86o29s0;a3Ah19ECi647k187o2F80t3F40;d4;!e24i4FE4m2Ey0;l147B;o255u100;a2AAEb28e3A3Ci425Fo3702r2D18u38DE;a1C85e3547o95;n3Br0s8yB;h3CBD;gBn2FF;i2Bl48y0;!e40i435s0y0;!n1ECr7s0;e1Bn1C7F;cB1d2CF0f131m2A7n1FD4t2E3Dv2C;aD5Ao51;nD7;l138D;e5n534;aCEiCEu36;j485n1;c0s123;!n3223rC8s0t83u61;t3E68;h1CAt38;i402;!d0p5s0;!e5127l7n22s0;!a4Bi5125s0y0;r2B5;!e12i214;!e67gD7i6;m183n176;g20Dp36r45C1t112;b3AF2dD4l5Em3CC;c2Am566p508;c7t140F;i8y1;!a12e1Bl7n22;e3B2Eo237u3632;!a32A0b38Fe4i6l10Am2Es0w10A;!e15i6lBo28s0;n21B6;n2v53;!e5n7s0;o128r19Fu14;l1r0;d1i31;u2EE;!e144i29Bs0y0;e1Dy75;e5Bo1;!aCeDs0u9F2;r5Au1;f2C5D;!i1E65lAA0m391Ap3A76r1DD0s3EtBvBzB7;!a41EBe4i2CDBl1BE6p4F1s0y0;k95Fp964s7;!e12B;!d114l1n2A0E;e2B8Ai1171;tCBF;m1DEp19D;a54Ee23A7;c205s85;g213;!g213;!r25D;eAiA11y0;a10n2o10;a54Cr2335;e81i299oE;!e155f37i6s0;!r114;e166lB;a4457e2531o4E7Eu73;!a4Be12i6s0;eAi214;a3557o253Du3426;!aC04b1B98e286Ci10k1EBl2Co45D4r1966s0u2EBF;l3o10p1Ev3;i4375;!a29C5e4897h38i424Bs0t1F59;a0c0n1;a1E3Db3FCc1EEd4E2e3EA7l1E1A;l3A24s3A0E;c7Es3v3;dA4;!e12i8Es0y0;!a13Fe4i50F1m64r2D0As0u65B;b1m1r1;h48CCkB07;n19B5;a10i5D;a474e89i1D;n2A8;a150Be1E6Dh2D71;!e26iB5s0;!e17Ai214l669s0;e106BuB49;a309e1fC9m5Bo29;pF0;l1FBDt28;r1AC;!e4iADl19s0;e271iF9;e1i5B8;!c3e0l33EEm23Fs0t531;eAEC;!a104gA3Al1463n22o420Ar606s0;!c4Cr16s0;a5012b4295c30A9d429Be3E27f1FF1g4C21k4615l4F4Bm2438n2882oBDDp2858q447Fr4D97s4E3Bt194Dv2CDDx2E2Bz1A8;tByC7;p0y16;!e0s0t112;l90C;g90B;t147F;e99o10;m4DF5;l7t2D;e15i21l2C;!s0t82;b3Ae34i50EAy0;oEt1;i39F;!b4DEs0;aA7B;eAi6o1C8;!aCk7s0;c15DFd4278gC2s1D3Bt3842;b2C0;a20e12rA49;p3ADE;i0lA8n3ACs0t446;d0l1n39r41C;eAg96l85;!e24f3C46m4439s0;a3B7eAi382;!eAh16Ei6y0;!a40e1F7i6s0;!a4414e4h110i24Fo5041s0w23A;c8n1t0;a12iEu54y20;a5F5e15i68l44r144Cy0;e1fF2;!a170eAiCAl7m8En22o263y0;i4lA8s491u5;!g4F0Al242s0;o76B;g675k38;!d16eA6Cn1Es0;n1Ar645s4C;b611e5nFp16;c32n1r25;c120e1Bg145;d0n3D61sAC5;e1t63;s22B;a2B20b40ACc1BF1d432Fe4C3Eg483Di3A25l124FmCABn2530o3994r2A05s166Dt21ADu2B7Ev20A6w29BAy4A5z1B33;a1e2D47f342Dm1Au113;!a24D0e4i6s0;!eDn22r3605;a2024e2B79i4C6Co4012u49EByD8A;b2ClE8o4558p2Ct4481u4085y3D;!e431i8Em343pB4s0y0;c4073i198n11F3p21A9s116t2320wCx19E;aBE9e4319i43D8o4306r4AD3u1B7Bw32C9;e32C7;a3D14b10E6d181f538k7FEm291Ao971p14A4;a164Eb3B2Dc15B8d1312eAD6g28A7l326Bm26D9n3E1Bo10p3778r3129s4194t1178v483F;a6Fe1205i65;nFt3;!e78Ci6rCCs0;!a3118e10BiCBn22o3BE0s0y0;u1169;h4A99o1;!d0e0;c45B6f740sE;i235;!a4Db17Ce15i6m2Es0;a176e8F;d16eAi6;c1Ce1Al60nEt1E;!eE4s0;a1183b665c1886d164Al3638s1E9Et11A9x0;i44Fo16;e24lCn2FD;t2Dx2FB;b458Dc40D6d4AEBf4A28g1239k1l19B2m1981n42E4p44C7r5045s46EDt1964v44w3E44;l36t48;e3341i34l2BE9n28o3720p1t3B5B;e15Bi1EDDy0;e12Er22;b1DDg4An397p8DFs213t4934v34A;!o473Ds0;b86Cd6A;!c2Cd1eE;t1C0E;!e150i6s0y0;!aCe4fA23i21s0;!a1De4iD9s0u49;!d0p16C9s0;sAF;s2C;!s258;!a4De15iA00s0;m1AF8;!bBg96n243pBr2980s0t2587;a392lF6xBFB;r1D6;!a59;a6CBc11Ee1l39EnFt10C7;d0e10r16;o3D53;a445CcAA1o10t5C;e60i137m1En1Ep1Ey0;!a1198e5m37F6;d3i1766k251n49C9r3F43s585t1E;!d7C5e1f184s0;!c1D4d0l7n39r0s3Ey1;c1EF2r78;!e3E09i6o15As0;!i2EA1s0;a6Ee6E;!d0rE5s0;e353nB4;b2CC6f108g125Ak1E3Fl37C7m4B2Bn390Cp43DAr4599t3615z1B13;l64s1F;h19;!f28s0t107;h455;n3D2Er65;a4D08e0o4693;e17Eo10z121;m328t71;iCn3o2Ap1;!b271Fe159i6n22s0;!k5A;!s35;d3l3p3;g1m3515;a1i77;c415i1;a12e4A0C;e4F65i6;a4506e79Ai478o140Au8F;a3A6Ci27y0;aDDh5D7;e2030y104;t2F72;!a281eBBFi19By0;b10A8c430Dd35C1eADEgFB3i1A36kBl2F8Fm1901n3EB9p4CB6r1C29s16A9t2B6DuE14v33AEw288By4A65z1A07;!d0l0s0;!a3CbA29s0;d0l0s0;a2DA8e2E3Bi4522;d3FFl3A61r63;eDs3z3;c1f7n2s3t7z3;cEn1r4ABA;m706;a39DEe262Di3A28o1A72u486A;a1DF9b3AD7c46C4d3633e2409f3675g4FE6h3388iD38j11EAk4D10l4CFCm1C7Cn1668p3BC7q24DDr3640s3EE3t20ADuABEv1857w3650y2A15z3B44;!l1152s0;n1o10u61;oEy0;a73e25;t17AE;e86Eo95;i4FADu3B22;e47D6hAF;!a0e4i2724s0t1307;a426Cr9D;!a4Be15i6s0y0;!n2738s0;o14u8;!e42iBs0y0;i38DF;a1i81Au81A;dF5;!a4E1FbFBe2124iBEl3F8Bm270s0y0;a4Bi35;a0c0d0;!a20i3164;a418;!e498i381As0y0;t1u5C;!m28As0;k44F1;c2An2A;o3B4;!b11EcA3Dd1AE8eFBDh7D4i86j20El42A5m2Er2Cs1A1Cw2C0B;!a278e26h208Ei2DC0l27o22DFr58sAA3u10;a667s0;!e15i21l5F0s0;o4FA0;e13Fn75;u424F;z5CC;i1A12y0;l6Dn1;d1Ee4;a2DE3e4310i3047o31C5;n0r1DF;!a4s0;!n1CAs0;e1228iBEy0;!i1Do12u22D;i133o3404;a39B6b420Bc2481d1CEAe2F6Af1845g3CC0k31B7l4BB3m29A9n2FD1o2B46p2A2Bq452Cr34C6s4084tEE2u3067v3FA6x12A0z15E3;!b63e1g1r565s0;!e30rAEDs0;!b40A7d0f43E4h3E7m2Ep20Er1s0;a2EE;h280;!a0eAi9l7s0;b791c3A7o39C;!a10e2B06l20Ap5092s0u4B2;n212t3113;aEe411oE;a57o57;e3E6i36F1l567;m67CtC5;e1AE1i41B3;b71Cl2D1Bt1BA;z30D;eAi6s3Bt39;d8Dg16;!a166e4CB3i6o10r342Fs0;!e3ADi3Cl7n22;b228eAi6n28;a9e9o51;a43E7b4B00d3EF7e3DBCg14F0i4B23j253Bk361Cl509Dm1A0Bn45E7o7BAr4A98s476Dt1E32v1CA3y0;!e15m2Es0;a409eAr19s1FtB;e38DD;!s62;!a6B;r22;e3FD5u72F;c92nF;a41C5r160;c2D3En2;!e1p3236y0;aDFe4i6;c28B;!e15i4835o56s0y0;e2FC2i6o3D4F;a14cBE5r164t1;e3Fl29;a65e1E;m47Dn2Dr3B9Dt610;a5Fe9z4181;!i41s0y0;aA24o1E34;!e5A4i21s0;e1Di3661o927y0;r29D;v2CzCA2;o8u8y0;!t40;n2CE9;a3F8Fb3013e1o98F;e335A;e1f7s14t7;i2ED4;sD3;!e6A;a769h0;!l7nD7s0;a1i302;o10u2D8;l75;a1l1F85n32;r5008;d1i10;o346A;m64n2BDs3tBFC;o2229;s3B90z3;!e48AAh1CDi21k38ABm2EsEC;u6CD;!d0f7n8s0;!e1B15y0;n0s11;m130;!r1A;r4AA;r204;c160d453m0n0;!a4Be15i6s0t8D;!bF7e185BgB4h8FDi21l36Cm2Es2461w1A76;a4De23i21;e1n2t3;g15EEi56t3573;i155DoCyC;!t4FC;o124s2C;!rAE4s0;oEyFF3;a5139e328AiF1Ek4F6Fr3u4237;g3r14;!n3As0;!a4De381Ei3499l2DF8m64o12sEC;!d3Bf37p5r1s0;!i152r7s0y0;i7Do10;r3696t39;!b19EBc47EDe3DBEi86l7n22s1693t9F5;a41AAe9F;a7e3D;nB28;r16u12;eCBCk3t390v3;!s0y98;a3BECl39En164o220r1D5t3DB;e25B7i2947l63r1E5u124;fD8;h68C;hC9;a111Ch1864;h21C;eEi70y62;e2A3;e1r0;a2508;g5Bs1ACu5x1AC;s5A;u1158;b292Cc329d1469l3877n1r1;!a149m64r7Cs1ED9t28;!e135iFD9;!i281o1s0;e23f4632i6t1;s4864;!sB0A;aCi18y0;a22E6oA0r2C6D;eAi5087u2CC5y62;a36e1i27o36;o9t446u5;!i2B6l7;!dAAg2Cs0;bA96l85m2Cp88r234C;o3905;e54E;!b1Cd377e0r1w287;e1BnAE3s11;!a4FE5d18C5i2CBFo9Br1A98s8y107B;eDr209B;!s0t342;n1t24EC;!a2058i13o29s0;c4099e3159gBl251Cn2B90rCCBs36B9t267;k2C;!mAAs0;nB3u36;a177Ee16F7;wC74;n959;oCu0;!i125;i14F7;e12r201;!b5Fe15i9F3l7Bs0y0;d0r167A;c206De2E0g2D9i86m2458o10t4340;!t910;!a65s0;pF0r9;aB1Ce6CBl1C11n3FA3o10w1;e1Bn2p1EsE;b1Ct3942;!e6Ei8En3B95s0y0;a4De1837i317;e4i4DDAo10y62;c44l437m1;i2BoF6u5y0;!d0l1r1;w47A;!a20D7e5i386Co505Ds0;s6CC;hACD;!n0s0t2D;gD6l15E;aDAt47;h5F6;a1A1eAi6;t7Eu83;!a80e4i6s2344;!a4Dd0l176Fn47r48A0s0w2B1;h4931lAADp3FABs3703;n45D3r42Bs3671t2F9;c8g8E0kBr427;a4C2F;c11iE;s427w0;l1An8;e4A9C;b7An2;m1p1Cr7;s2AB1;k35;d2A8Cs1F;n25F;!a47D9d127g42B9iE51o1584s0y0;cD3g401n8;n1AA7;d25De56A;!r53s0;d1e12r7;d0nFr39;r4E59;s55tB;e5Bo35;i18t1C;a4FBe901;!e4i21l22s0y0;!e4h151iEDAs0y0;d0e25i210;!a4Dd0r1s27F;l8D0u1ACE;s4E6t2231v19;a345e17i21E9;aEi45D5;c23C9d2739e3EDEf4548g4EF3i32DEj1E2k286Bl22C6m3148n4860oCBBp4048r4EB4s1795t3A8AxAFz50E3;!i4n8s0;r4v18;c32l1;!h143Bp119u49y0;!b29g30F4r1s0;!a14s0t0;d0n212r14D;t551u166;b1C3cEd7Ci4BC2l921m1En2C5s6FAu177Bz1E;i18m1t1y0;!r1FCs0;a59i31y0;e12r20F5;!i1051s0y0;e5117i6l204;a31D8i1D5Au3134;t23E2;!a80bFF5e26f14Eg238hCD1i5118l685m562n2BBp12E2r24B7s399Dw4CC5y0;c11k39v18E;!i3D;i29A;d462A;!a4B0FcEEBd4D38e2DC1fC3g46BAiF16m487Cn3B17o3590sD1Et13F8z38;a3AEo36;b7ApE;i12F;!e15iD9o12s0;m8An7FCo1401r28F6u59v5B;e1i111;d1r36;!g19D1h3E7k2FFAn1AD8s170A;rE9sB7;!oEs0tB;e1Bl4B42n141;o1C45;a47B3i75Ao284A;a45F2e4DF8i2EA4l3E0o49F0u2502;i1D45;o12p38;aDe1i109oD;o5A8;d0t476;!a10eC1i6l259n22s0w2B1;g2Ci13C;!mC9s0;mC9s0;l34A;a49FDb1A7c2EC4d39CEe1D87i17D2l113Bm3AC3n3587o29DFr325Bs30E6t2347u34w4F32y2CF6;i4FBAy0;a8F1i1Do288F;b1Cn2;i50o94;i77o9B;n420;hD6;n3DBF;h351;i21o12Du4;!d8Be36i144Fl89As0t7;a0c167s2C8;s8F3;l1p4EDu4B17;d6Ai0;!d3705p352As0;l1n0;l0n1;i8Fo3Au0;a6CD;e5m2A11;!a4Db63f184l22r1s0;u11DE;!c0d276e5s0;e1l41E3n287;!a4689;n1DE;a3750;a6CA;s250Cz48;!i1t1;a0h3A6Bi3CC7u129;u43B6;!n82s0u5;!a10e2771i450o2FEFs0y0;c3408h4A3Ci84Fk4488l9D6o210Bt744u4150;a2D5Cl3C27o205;m510;!g1k1E;n1r366;m3A9y5;oB48;rB2D;!a3D36d15A6e14E8iADk5Fl3CA5o2D5s2EB;i50A2;!a42eAi6;t39D;a1B2e1;m140n47;!a2EAEd4B28e4633i21l199rB21;c2Ak3n78Es11t3;!eF8Bi6m2E;!l0n0s0;i3Co176;i1247;n189;!c3CBAd0s0t1;c0n2s553z19;c27;a17o93;c8p8;n232Er4104t28;b1B0n7A1;h324B;l2742mB38;c0t201;e308i1F7Do4C1Cu5;i17FA;c0g101l3;a1A53e2234i4D1Dl1561o19A0r2FA5u4B54;!e463Ei221Cs0;!eAiCAl9D4m741n22s78y0;c13Ei1D49n4p38r920s3BD1y182;e487F;n4ADBt0;a0c0n0;i1AtFF;c192n2779r3D44sE;!e6Ah21B2k5F;a46C7e464Ai18Bo93u700;r516;!m188Ap34B8s1F;c92n2sEt5E;a3748i4747u5;!a7EeAs0;c0n363;s1Av9E;f10C;b471d3nE;aCe24Ci3D;aCe79n2;!e8g0s0;h1A45l3;n25r2C;!d4169l16Dr1s0t17D3;h2A76;dA9Be0n0;e5l7nFs11;n2DFB;l1BB4rB;lBu59;e84i1785;n22F3;u1AB7;e0h0m0;t6D5;!l19m1n19r1s0;r51;l1nF;c32r3w16;i65o1D5;a1600c2EEDd1D3Fe2C75g4C80h1i1F3Ak2F28lF8Em1A89n4365o353Fp123Cr488Bs33BFt2A9Au3365v4776wF5Dx23DBz1E15;r3F7;!a4F6Ee4i6s0;!g5AiB8k1A;!b2DDe12m8F9p40D8s0;g4A14;i31p36t546y47;n4061;aBAe994i57;o128t1;n464;s92F;i1Dw10;!eACBi1771o442Cr22;!n82s0;a9t1;y4C3;sF4zF4;t14EE;!b7;p8D5s9C;!iBBs0;!d0m64n0r1s0;!s3E2;!s13D;!c2E8e1s0tF1F;!a1B8Fo14;l14D9n31AF;a387Ee9A5i133l88;a18D4;a4Be4i30By0;!a9s0v63;e2914i2B04l7By0;!d216Bl18Cm1p1s2Cz2C;!aEe4lBs0y0;i4705o3D2y4956;a3A73;a1o46;a0i4F7;o4A84;l0r55;!l0r55;aCm1rB;a3Ce15Bi2DC2;e4DA9i210uA4B;!aCs0t55A;!m71t107;!o2808p614s1A6;a3218bB4cB1g269i1AB4l1CA7n1A0p637r3127s2071t1299v2E4Az1AFF;a473Ac45B2d1B34eDC1f1058i30CDk4D1Fl34EAm1F87o2EF9p32FAqA1At3C54u15F9v1809x1Fy2895z31E9;e5h1167i5148;!lA57o1Ds0;e1u932;a482Bg3;!e51s8;a4FCBe24B6h3377i3D46u161;e2BDDi6;a2FC7e4739i397Bl3B38o211Br471Eu504Dy980;c2087nF;b355Cc29E8d428Ae16E4f4958g229Fi16B0j1Ak3307l42EDm1813n4B67pFD8r1B86s2381t3DE2y1zB00;c2Cf23Cn2o223t121;b1Cg19;eC6;!a129e1FDhB4i2B2s0;f1DF;a3E7Ce222o283;d16t942;!k16r1Es0;a3486;iBo73;b265Fe4923i6o4399;a10e86Eo21D3;i3126o8F;e25oADD;n52t3;!n3t3;!m1Ep1Es0;a45AEi36;!c1DFDi6r47s0tA45;a6D4h979;l103;!fF2;aCe1i4E64q6F1t274Ay0;iAC7;c193EsE;d44lF6s1BA;!c56e12i8El2Cs0y0;!e4i6y0;e4m0;a146lE0;c1765f28E2g49CDh17Dl50CFm4EF8n22s1AEvBA7;d0lBn1;s117t3B8F;!e602i6;h27lF5;!y18;i90y4078;a309i4100;a3DEe1z4608;!e4BCi5t5EE;n540;!b17Ce4i6sEC;a3DE4b1c42FAd998e45g2952i3758k44l32AEm4BCBn4B6Fo42D1p17E9r36D4s5t2D98u40D4v1B05w1E6A;!aE6o29;aE6o29;i18y18;b5Ci3488k4F35m1A;r1s2F9t2BD8;a12n1AF;e0i27y0;!a3E5e444Ei340Dl1019s0w1BCy0;!e209i10CDl7s0y0;c4678d3e142g1i6kBl4F92m1A29n4564p4886r1EA0t36A3;a2e12l19;i25l1;!a1d46BBe418DfB0g38i4465l9F7o21D1s0;a1BD0b217e1740f0g3B55i50C9k1m4E8Fn315o1D10r421Fs3417u2367v5By37BF;dEEDnD1;a0i31;!c184d0s539;m444Ct17E;a4De2BB8i6E3o1y0;a1Do29;i238C;l132B;!e4i319s0;c21EBg583i18B9m4224s1399t486C;!c3753k1As0;e1lBs1F;a3609;r82sB;e432Dg2B27i229B;a10e2750i419l219o10y0;n3sFCt7z3;a3786i16Bm1;!e15i43l19s0y0;a4CB0b983c2C45d1521f108g413Di4A3FkBm324EnBDFo2BEBp304qC2s3155t411Cu319Cv34D7w3B71y29ACz3;c32o34;a23C5d302Cr1;!a7EDe4D41iBEl44s0u1AB3y0;e6Ai4CBo69y0;u64D;a4672;l13FnCE;!e4i392Fs0;g49l1C;!k5FnF3t58w2A0;a0c0u14;r34Cs2B30;k1At2D;lE0u3C;g96nB;a6E9i0u5;t2Cy0;c0e5s14;a39A3e2FF9i2CF9o259Eu3C45y35FF;s1F1tB;a1E6e10DfBF;!a149b17CeA99i2D38n22oB65y4E8;e51uC;!s0t132;i108;!bF7e67f37i21;!a1C81d3A57e1i2E38o41BFs0uD86;a1u1D;!m0s0;i9t2B;a211d1C9Cn25s48FBt85;!b4A78d42B3m3B40p253s4B1A;l1As1F;c585i87r5C4;l5Ar5A;!s2EBtDE;!d0f37n8r82s156;o25u49EC;h94o348;e47El1B54r3xAF;c1FEd0n3x1F;!a4De335i44B2u397;i84s0;!e5s0y0;!d0m2Er1s0y0;i25l57Br2673;c3A6g3A6r1160;a1492d2EF5e10DAiBEl1793p2759y0;a3CeBi1;d1l4F88n1r414;!a1397e12i435o73s0y0;a5064d18e46Fi21k28o46u405F;o4A21;h48AF;a20c0nF;!o4AC4;!a1E66s0;o414E;e4A69l68D;c48F4d48E0i2004n2D27r4029s4E20u4BAC;kA4n1DFo2As5;c0t5E;oB26y105E;e4E8Br37F1;a80e36A7;!e1F8l7;eDi13y0;!aAC4e602i2FD6t0;b303Bo1;f0n2o9v3;!a658e434Bi8EoB5Es0u4E3Ay0;aCEu69;c0o29u14;b205gE1l124nB4r37ABt2C;a4De360Fi21rBu1A0;!eDi8Ey0;a1B4e1EEBi651o1;s19t5071;!a4De4i692o8E7s0;d1AC1l23C3p10Cr289Bt3A4Au1C5v2DEC;s1Ft5F7;h29C3;c19rE;l5EC;a4BC1h4B11i4AFFo3A27;k26AF;a4F72b1737c468Bg1571m1B7p1r35A5s44z23C7;c48C3d2FA2f743l1690n26D0r1C6AsBAt86Fv2C;iB3o8B;a10e4iADy0;d1BF2h2422l131z1E38;tAF0;eEoE;s7t3;!a2DA0c226d24E5e308Ei2297j367En2906s0t2482uA24z307B;a1188e4CCCi62Co208;d0r16s8;o1455;d0eAr9t0uEw9;c122s24F8t1DE9;l118;!d0l1;a40i4FoD1;!s52t0;s0t3;aCeAoD;c19s5BD;!c11e23h27iBEs0t1E0Ay0;hAFtB;a17Fr1;r25sEx1F;!a683e1s0;!e4DAs0y0;c2F7i3238l2EBBn141Bp23Br42D6s34EFt1CF;i33A8n149t2B9y0;a1D4;i3C25n1423uC6;eDl3;eF8l3;o344;o228B;bDE4;!e4i356Ds0;a1A7Ai2E24o346u3E01;f1474;a1344e8i16Bo27DE;h4F9F;t4B5z38;a3B7Ee142n8w0;e24s11;a1BB2b3582c4BDCe4EE0f41F7i1747l2DB0m1B7o1018s38t50E5v3E17y1A8;r2D06;r36DD;!e1m165s8;!b63e12fB0i21s0t0;b4C61g15Cr4E92;t3A87;!b17Cc184e24g636h95Ei2DFl22m2Ep40Ar38BFy0;d12FBe135m45D2n28p1EBr4ED6;eDi6C;c11m16;eAhAFi6;t2DB9;iE8r8F6u59;n181Fr541t2D;s19t7z19;a1i4l0nB;e4FCDiB;!n0s475t1;e7B0;!a1Db18FDe9i3091k5Fl7m4904n22o3186p31B2s0;e3BCEi43rBy0;gC2n65;!aEA3c254e3479fB0h29AAi2F91l38m2Eo3DCs3DD8t160Cw2D5A;c4519;!c1C36d2AFBe4ADEfADFg4EFDh27F1i43ADk2E2El2E46m1DBn17A6r3541s4AB9t3346v1130y3E6A;i817;i31o6F;!l140r1s0;e42m206p33E3s0;!g345C;a16DBe4;c2C01fBFs2C8;eAi9s572;a53eAi6;a2568n65t1;r0s1F3C;e1BF;e1gAE;a1n3t3;!a8FsA1Aw204;fA1C;!a50e15i6s1F;!b6C3e4f1BDDi6k1155s99At816;i8D9;l2FA;a3Ai40A0;r8D6;g8F;!a1Dy0;!f37i6l22mAAs0;m3rB;cA41d257Fe3983fBFn2775;i13u26B;iC8rB37;e2D6i730o17AB;h38A;e15h3879i68lBy0;b1AECc12A1dCB5f25ECi24BEl4C7EmBC4n1AE3p42Fr2B1As2F7tABFu1v23FDw36AA;d0rA1;d27t1;o19F;n2857t4667;d0r40;a0t7;a13e12o1382uD4;k1Al4CD1;!e144oCs0;a4E04;a20i651o29;n1C4;!c5E5e884h19Di69t2013;c3eAg0;!m55n461s29;oEFF;n8r1AFt2B9;e11D;g318s1AE;!d41A;h6As19t19;c29o85r2CF8uBD;!e5i4A6Aw1DC7;r1FFE;w1A;a309;d531g1n47r84CtA80;a0eEEEo3ADB;!a1e4i26Es0;b372r177;a2354e8FiBy18E6;e17o486Fy0;d0r417s0;a324;a1293e493Cf1i1B9n39C2z465B;b16i13;d439iE8m16EAp4A61t2Dz4D20;m220t3;!a27D7m3At1;a326;c0f2D;!a1C5e4F30i9DDs0uF26;aACE;!d0s0t107;!h1s0tAA;e12i3C1A;c30F9;c11r1D;aEc32;s560;a1C8i57;!a20i3Ds0;c13Eo0s3C9Fu211;l44o73;p5s0;!a80e1Bl2Cs0;a162e1;c0n2s0;!b1Cd182Bl37E0m4E5n25t34C0;n8z3;!a4De12i383Cs0y62;iEp1;!d1F9e15As0;s9FBz19;d0s65;aCi2A81oE7;c13Bt0;!e21h16E;!c168e31F3g6DDl56pBs0;t256y47;lA8t1;eDi13;!eC70i261A;o2099;a31iA51;!g0k574nAAs69At4FC;tF6D;o1u6E4;s1F13;a30A1e17o23BCu14;a8n3;!e3D90f1i25Ak2564l29F8m2B3En162Dp1CBFsDC3t70C;a326De4i6;c185t60;a2879;c4F1F;i63By0;e1i12;b806p16;i4s3D0C;a12gB;a414;a219Dl2737n4290oD65s1F;!a39Fs0t1uE;n56F;e3272iDBCo3430;c1DAk4E5Dm4D79;c437h1l3438q1FEC;l1rF;a3CCDd264Ff4CFBn3o4917s1734t3Dz2C;e4F3;d0l34rCFs0vA1;d3i14Cn4p1r4y1;r16s0;!r16s0;f958z3CB;!g1E46;!e23i6t1;u65D;eAi6o1;!e1F8iBl7o0;e17i4778oBD;l3BABt218;!b4A26e35C6i21l1CEnF3s0;!a40d48EEg213i4274n245Ao9Fs0tA1Cu310;d0o29r7;n487Dt1CFx0;v44;e1D1o21DuE;l69B;!rD6s0;!c406Cl443m2282nE0p3C9t3E42w61C;n16r0s5A3;!nAD4rBF7tB2A;e2539;a4De23i1B5uB9;i10n1FAr3E32s20;c1AB0;b12Fc19Dd45A9m8B5o248t1E8C;eEu34;e0t11;gDCi210n1A;k53nF;u59w9;h75;r4F5Dt1;a9s153t7z3;n46E1;l3726;e6Eo81rB93u51C;e581i5;a3445d43Ce1h4853k378Ct4C52;l1E30;d41D;a1Db2C65c4B03d4EEBf2209i33C7k5ClAA0m2DD7n1739p32ACs2E97t11F6u219Fv113AyBD4z1D30;!b1A99d31C9e184Df6EBi77Dk47l297Ds328zDB;b1Cr153tCCE;i4r1;e23i6p5C;!eAi6s0u609;e17i116;a30e15i6;a7u5y0;!c1EEe1gF0Ci116l107m4CDAn1F88rDE8s7F4t1996u4D60w4338z186;!e4i4912s0y3941;e21E8i54Ay0;!b22FDc9EfB0h110i17El2C5Em63n22pFBs0t3B96u1D27w15CE;!b1DAe155f37i21s0;r389F;l1Em1E;!b1D2e15i43l19Cs0y0;l2A6Br43B0;!a4De127BiBEl10ArBB7y0;!b4CC3i1AEFn114s30C6;!b29c98e23h110i21l4A12m2Er52Fs0wA9;a40e83i31AAo106;e20g1o362By34;o3916;i137o6y0;fF2r333s0t2D;nAE3;g48n4B;!e4l115s0;l1n26E9r4F0;!b11CAe4h2F6i6l502Cn4B30p3256s4C4w948;!d0s0t1x231;a1FD9e79Ai478;c9CzC8;a10e1B0Br46A;!a5Ae12El37EAs0;l3F;e3FAi6y0;t3755;r4DC7t19;!a657e15i6s0;o733;e12Ef2Dr506BwBy1;r2Ds1F;!e2F8AhC1Ci2E0Al2A2q3360s0t223EwC8y2FFD;c2CB8d3Bg4Ak28n0r3F07t4B52;c1o9;o29CD;e42i4F;!e1Bi49EDl7n22t36F6w2A0;z2C9;a1F9Cd1k1l1n15E6pA4;a10oE;!e4i1C0o0s0;!a6b1124iFE5l5D9o12FFs0u1F55y0;!i1D3;cBt7;c7tB;!a10e5B5i6s0;!n7;!e4i35o57;e885;a21c28E1e1A09h2AD2i48FEk4C99lDC2m56o1q416Fr197s31ACt2525;c38BAd0f445n3o1C;a1eEi7D0;i35u49;a1659b2774c4665d4EA8e1664f3741g2EC9i4872j4C78l17A1m1F70n3DCCp1FDEr2505s31DAt34CBu36FAv307w1905x397Cy4499;d1r161s4DE9t26B7;a1FAEe271i6k36BElF06w5CA;r4Bw10;!a9CCfC3g229Eh3F0s0u3764;e1u3;!a3666cFF9e4F6Bg4720h27i27E7l1o2E7As0t23D6u2EE4;!eB66s0t3BDF;c180d0e985i3E64l10D9m2884o1F6Dp33EBv2C;a1A44i9s3t39;k1Et16;n1835;h5Fo163;d4DD2g3An75tFD2;d96Ct3B75;hBt1A;o3A3;n65t16;x29E;d35E;!hEDi684l3A05;!a80eAi6s0;eAi91y0;nErEt95A;!eAi91y0;!a1e4h1Ai6s0;a807;cEEn1p9AD;!o8C4s0;l326EnFt1934;!o6B;a1729i1F86m1AFD;eCC;m2En1;!c46An2t4EA;!e9i3Cl5FBn3E8o15As0;e5n179t1DCF;c32t1w7F;e24n2o10s11;m1oD;a4097e11C5i3E0Dl2513o462Fr4FD4t2EB9u395By4FD0;s277;a3Ce630h92;a4Be67o1A6Bt61;t39u20v48;!a4Be15Bg1i1FEnBs0y0;eAi3F;!n71s0t7E1;c11h7;m427A;d0l1EFn1r1;t1E8;e1i5p3F2AsCCt3CBB;a1B84e7F1uB3C;a0nB;a176e3ABDi21o579;!i8B1l413Bs5053t839y1;s28A4;!a40h27i13s0;!e4395iB;b107;!aCDe365fDBFi21l2E69m2352r286s3C78w7DA;a281i47CCo31u8C;!d7Ce2A46i21l2FEm2Es965;a25e10r3A4B;a3B9Ae2BF8g2DBBi4FlCA8m18o18F2r4D59;h4257s2440;n1r4A70s1AF;!b40De4i6pA5s0;!i70t6ADy62;s8t7E;k0n0;g370l269Cm0;e23i6t2ED6;a1Dc1EA2k4CnFsC5Ct11EB;a12o31;!bFBe4i6l22s0;e48C6i97o352Fr177u5;c38FBe5;e3392i35Do13F2y542;!b3733eAi21l22p3F26s0;n44BB;g4474kD96t2AB;l1tB;h1BC7;n154s11;aC02l4m463sE;!eC1f14Ei21l7n22sB32t48DE;a4DeAg0i24F;c18BD;!aCi4F45o27D9s0;c2A1;c1CgB;a310De4723h34C8i29B6l26B8o1B27r49A4u39F9;!i3Cl7n22r0s8t58;a2265;e832iCE7nD6;c11s11;tAFB;i205C;!i1D3p33Ds0;e23i6o1978;!e5106i6;m47EC;!s0v1CA;a299Eb2689c461Ad2CCEe3F27f4483g2A14h985i4BC3j40E3k26DDl168Cm2F6Dn4A85o16Fp104Bq4567r2570s3D75t3A48u3628v1726w16B7y110BzF8D;a40e3B7i9E2o4825;c217;kBp4741s4715;gE3k1C;d0r1s8t0;d0r0s8t1;a158e3DAi6;e2816iBEy0;!a4640e4E89i3D32l782n38o4377s0u49w7FyA6A;l4EA2n3CEs9C;aCe24;!aCe24;a1t38;l4B;d38e20Bi2100tByA6AzB;l1FF3n2;a1e372i239Dm89p1E27;!cB1h2Cs0t533;a0i13o10;e23i316y0;m1E5n421r2E78;!a4137cB1d141Ce3BF7f183i3151n373Eo2842p40EArA85s1E58t2FA7u1AB9z56;dBl35;s14t1;!i13l8C3m120s0;s2CEu5;!a66Bi6;!e10Bi6l7n22s0;iBBo29y0;!e5i11Al11Eo3988u1;a173e1F0i6;a46F5b3137c1535d256Ce4677f2DE0g4E55h1724i24A5j2D12k4228lD42m1212n29BEo49B4pBEAr4E33sCDEt16A3u27F4v5Fw1481xC5y2C8Bz42E6;a4Ce15B;i10l2C;!e15i21l22s0;!d0n3874s0;!a4396c4F2Ed4A2f4D6El3A06m4FBCn2D88o3504p15CAq2EB2rABFs38DCt209Av2637;l3108s85;!aDD6b4965cD7d18A0f25EEg41l219Em2En0p11DFr4AC3s1DDCtE0u36wCF;!e4i4E0Cs0y0;u18B;a1Dy2F7;!a397De1DAEk131Bn37F;!cDF7o1B07u2C48;!i46El7;e40E9h5F;c1AlBu5;i5o1A1;cEd0r1;e6Co81;!a69e4i6s0y0;e3591;!d3Br1s0t20;!a433De1C2Ei39E6u67Ay62;eAi35Dy0;e1m0t1;r6ED;l387n1At3A;c779h2EA5i3192o10t329u1F5A;l527;l42D4;aB71oCD;!e4l7oDs0;n1C6t7E;a1882d2307o2D7Cs0;!d1r0s0;f1EC1;!d0r5s0;e0n242;gBl1n1r2E9;!cF95hEDFt20C9;l1EFn2B39;l1t1288;a395AiD4;!s0v27;hA4o10;!e34A8i6o46s0u9F;a295e1n61;!b706c333Be15i1E0l20Am2Es3FDF;e1F6A;i31o5A8;!n218s0t16;!e15i43o12s0y0;!e10m127s0u4F7A;aB56e4976i2BuBvF2y0;a382Ce5i1BA5o3F29;!b9E0t0;e262n4158;d0n8r1;!d0n144r1s0;i8BFy0;c185t0;h4BCC;!a18B1cB1eAi6k4E05l22o1973s0t1789w293;a1D53;r0t3AFF;e67o60D;t333E;a0e0s0t1;iEB7o46;e150i895y0;!d0i10n4F8Cs0;a384Ce314Eo21DF;eDt1;t18F6;c9CdF0Dk131Fm28s85t4D21;n2s11t61;!e10i70y62;!aCAAe756i272Bs0y62;g3A66n41E9s3C9Ct119AxAF;dBn4By16;!a30e4iF9o12s0;cEg48;z180;e155i6;r1F5F;e0o31;!e1i5;e1C4;!e4FCFi6l567s27DAy98;oEy346;a65Fr281D;!g3683l2C0s156;a40m974o29;!a4De23i4AF;!e15i6s608y0;!a428Bc3B59d2939eAg1i13k19El75n2E56r356s0t3EF6wA9;l1E26;!c61Ae3EDh1m97Cs0;i5C;iE8r3;aF9Ee5hBCo1574uF1;i1D75;e4CiAE;l20B4;u13F5;i8Fo73;!a411e3D0Dh151i24FlCFo56p165rF3s0;o31Bu126;!i13o46;cEd71fACAg46A2n3p3826r61;h1F9;i5n46;r843;g14n2s3;n25r65;d2A04m2681r4D13;!e24Cp4C;e3DAi6t0;e294iD9o12;a42e10uB;aCB0e155Fl3FCFm3n2393r4852s41EFt1778u2611y1;e4i30By0;l64Cr231;uB5;c1s3t7z3;e0i368Ey0;i4o22A;a26E7e2E75o63Cu64;j1Am485;i2BrD6y0;u32E;eAg1D6i86y0;l1A3C;!f37l22o427Cs0;r1947;!aA7Br3As0uD1;a76u34;!d0fB0r1DFs0;r6A6;p4FC4t926;!a0c1e1s0;!a28FBg2E86h1310i40B3l9F7o2B4Bs0;a190e1n61pA5s197z0;!m2538r1s0;l4ECE;e5w225;!e1CCi6n3u111F;a2155e4266i35A0v1F06;!e24i68w1BCy0;t2Dx55;a11D7d204Be1A35iCF5o452Es4F22y1328z7D5;t2881;!a20e4CF1i2F3l22m4A2o60Ds0;k0t28;!k4F44s0;h4E;d19nEt38B;e15iADy0;lE05s0;e3158f39C7t347A;n3Br1;n1r3B;!o34;i4D86l44u605y1B57;a0e34D;!d0r58s0y0;!s0t215;h71t107;aCiB6;d1C4t0;!a34d4E37n40CEs0;a438d2720g11Dl2Cn2797s28Bt1;!a2987b45B0c4E9i28Al620o20A5s7BFw43E6;!e1FDi1EA7o4153s0y0;a29E6e31C2h311Bi310Bo41ADs354Du4187y1B1D;!eEAi205Fw8C9;b3E4e0;n18Bs2Cz2C;b733;!aCEd0fCFr36s0;a1ED1b3746c18FCd4C8De15Af4DB4g433Eh1i12B9j3F87k4E0Fl2B8Cm2A64n38D2o214Ep48E1r3AAAs1487t17A0u1D36v3EF0wD93x0y1B7z13FE;e90i90;a40u2BA;a4Ft10BFz0;!a4339c1Ad3E85f7g0n1Ao11ACr3s0t1D97w0;cD56fBFn2s432t923;e17i3A95;c2BC8;a3C72i91Dn2BC4o4DD4p83;i3F7C;bB4l44Bu2EC0;e9i38C3o2CE7;e1Di2C3y0;h1DEB;s2DB;a8c7t3;!d1l1nB;!r11E6s0;e5y34;r196y31C;o83;r8FF;aCiD9o3D8;e93v1673;t352;e1153;e36C9i46C6;m23BA;!i234Em382Es0t36B6;!e676s0y0;!e1i214;i840;!e4i6s0u49;f54B;!e4i6r1s0;r3F98;!a21AEe4DEEi3F5l22o34E4p165s0;b5Cg3;!a1315c38EAiDF2k3E84lBm2Es0;a1e36El219o1;!a29ABe4i1E0n22s0y0;r5F3;h85n28;!a466b509Ed906e4Fj9Em6D3p4DA3s0;eAi6n6D;c17F4l1B55r2D0E;r6F5;!e15g11i21n0s0;l64u195Aw1Ax0;eEi2558;!a25o678s0;!a0e5i2F6CoF8s0;e1Bg145n2t215;l4n4;!g1EhEs0;n20r16;aCoC;n5r143;c23BBe45EAi3B77l3AC5m34FDo18EEp37FFt370Fv3243;!t16D;!e15i86s0y0;sA39;dDEg107;g2417n22B9;a12r463;!eAi6s0t4467;s2A1E;a300e1t1;g1k1t4A;!oB4s0;a307o24E2;!nFsA18;nFs288;!b14EeD0i838s0y0;lCC8n2CA5s4535;l2BA3r2ED5;lDB;c1n2t3u14;!a80d1e15i6BDm1s0t0;c0n2o9s8;!g38B7s0;!e1Bi8Es1AEy0;o59F;!a556bA59s0uAAB;a49D3e28Dt2F51;!cB1s0u1;h3Bt83;!eFCEi250l27E5n22o1s0;lB86n240;nC18;e48E2iCBl175u1Dy0;!a40c92n2s0;e1l1;d260Dg3B43s18ECt323;!e4i8k4Cs0;i4r46t16u20;n218;!a87b4B62c57AdA01e1599f1547g3F1Eh2F6i3l20Am4995s2EF1t4366v4BDw311y0;e6C7;e1iAB0;!a1E71b3F6c82Eg34FAl426Fm3ECBn2C33p21B9s3D57t5135;!e4h28i6l88s0;f2974g2D9i2E0Fl4F5Em3810n2BEEo4908p40D7r4AAFt3255u295Bw410C;a1B35b46D0c2A62d1DC1e28B2g35E3i1145j4DE3kCB6l24CCm4464n194Co1957p350Cr2B35s3149t3D6Aw460Ay2C43z2355;oF0;aF24e2CBAi1385o25FBu14;e1Bn2oE1t3;i1Ds3D34t22D2;!e4iF9o8Cs0;!aCe4i13s0u5;!b2D6Df1k5Fm3487p4282s0;a12e0iB0Ct29u4505;c9Cr3;r132;e17uCE;dA2Fg603n46At28;!d0i6r0s3E;eDl7n2v3;!a263Ac31BEd35A7eAf1DDEg8AAiFA1k5018l69Em2En1A0Fo3FFBs47CEt3FCDu3806w6DE;!a1A87c30Ae18E7h2086i505Cm29o352rBt1AF9u1A38;!e2767i51o29s0;!fB0l1A2s0;m5Dn2CB5r8s13E;e30n2;e10Ei97l7sC83t4A;a2E07d13AEe3DD7g3864i3035l22CAm2B50n3144p4403r3397t262AvA4w3500y0;d1D6s0;a346e17;h85;n12EFp19E;a995e2749i19o1D8Fy7B;e0g1;b3692n25;c2135e1g3064k2Cl275Ep1AC5r36FBs49E9tBwE27z501;e31iA47;u1B3;!a90c12DeAi6o9;t44A9;e2965i3Ft1C;a4254;u10DE;i25u5;a1e1t1F61;sE7F;a1e581i6;e37Eg0;oB5v3;!c2636d143Fs0;d4FEBn4w7F;!e4i6l4ED8r58s0;!e4f37i8C6l22s0t1ADC;a20e5;t614;d0n5BFr1s0z2C;nB3B;!a1FBh1n2s0;a120Fe24n2oEpA5s19u14v94z19;!o32s0;a1667i1DlB;eA2Bi2B7B;!e155i21l320Cs0;a2F2e710w40B;n707;n1p7;a20l3;!oDs0;!e4i86s0;aDeDr7s0;e142Di1B74o167Eu291F;e31y1C;!a11BEs0;!e10D6i6s0y0;a4736eAi6o400Eu4F;a4C3d8F5eBg4Ch4209i4C77l306m2Dr2930;i532t242;!e15i6oD7s0;b229Ac268Bd3804e1g834i365Ck2Cl1BF4m149BnC31p27C8s226t1675v33EAw1y47;i9o61F;eAg1;e0m16p1E;!c234n58;aCi18;mBn0;o2705;a22CC;!a488e24i6y0;a1i0k0u4F;a4FEr231D;a1552c2CC4e1AA6h127Ci22B7o2588sEt1yEEA;e6E5;k1AnB;!e15h151iBEs0y0;h229tD53;d26Dn479D;l2F7E;!e4i3B7Dm2Es0w7Fy0;r36s0;eB3F;n727;!r2285s0t3;a57i87o20u6;h1C9F;!b4233l195r229D;!a1A2BdFEEe40B2f4E17i396Bm26BCn46FCo2540s0t4755u97Ev1E14y62;a21EAb4A97c1A60d5074f3326g2306h1Di1FE8kD91l41E8m1944n34EDo271Ap31CEr2F05s42C1t4731x8By2F75z11C3;e1i299;a1Di1;c2Ci4n578y1B8;i6BF;aB9;e4B18i6;aC54e282Ai1C8Do4B1Fu2586y294D;!l3274n4Br2Cs0;!h246i21Bt1;a38C1e870;!kE3m2Es0;bCDs1F;g468;!g19;d4CBFe2B52g169Di3Co4895t4A;!e1Bg6Ai3F9Al13DDm1n22o1s0t1CA;e1i72D;d0r16t1;!e931s0;!e5i18;!i1Am2E;!e12f37i8Es0y0;n1A48;e17o8CB;!i1B92s0;yC81;c2Bd38As1F;!a1e155i895l4D28s0w8FEy0;a0o1D44;!a10f1n82s0u14;a14EAe104Di3D80l2A78o2DD6r1C26u1EF1;!e4i6s0t58;nDCt2785;a5Fe724r12E6;!a2D7EeAgAF6i6m2Es1A6;a9D0eFDi5121;!n36A0s0;!b16De1330i125s0;!h2D4i16Bo16BFt31ED;!e24i6pA5;c765d1g1n2u85;!aCe4i13s0y0;!a1eCF7h5Fi43B8l1CEo24A2r17Ds0u10y0;!e1i18s0;e30i393F;!a360Bo2FCs0;!a571e4EABh17DiC5Dk401l4A54;n0s153z3;!a2642b2A2c4FB7e10CCf511i1190l2B2Em277Fo446Fp4590s5108t433Bu1064v498C;!e15f37i6s0t27y0;h1Et1E;s1B3;s27;!e0i0s0;u126;!a4EFCb4429c4DE6d1DDAe4A01fB0i449El3414nA37o1906p4A93r3A03s1560tEBu3E9Aw151B;!d0l7r1s3Et16;t7CF;e17o123F;!bB4fF2l7n22r0s8;a2872k28m28p41Br175Ct28;t1Av1A;!a32Be90Ai341o325s0;a104e262;!i13s0y34;!a161eAi6k2E3o1s0;u235B;r389;u25C0;u26C;o8r9;d3B5EmB;iBoC6;a3A3Fe1776i6oCDu354;e5i5t2D;a3E67eBC6i4844o181Ct94C;a1s0;c3107;eB5F;!i109o29;e5i19EF;a1Di338o10;!e17i2DF2r7s0;d4A4A;n1s5t1;!e1h1769m1p1C2Ds37Ct24CE;!eFDi86l48s0;!tB7;t242;!e15DfF2l7n22s0;!l0n0;eAi6t1;!l2232s0;c0n361o9v3;e0n2E7t3D9y0;a81;i31yC7;a2EC;b1F9m35nE;!eFDi6l6Ds0;e2A4Bz4970;!e15i6oBs0;!d0f37r1s0t4ACu34;!a36Ee4305i6l44s0y0;aCe220Di40C1o54F;e24t61;a9e5u14;i22C3o3FE1;a3AFCe45BEi138EoE1y0;!e26o2s0;c8i4;eEAf7l7;l1EnFs288t7;c2Ar1;!r3As0t1BF;aB4;h321B;aEFe103Ei3062t4C35u2799;a101Cb28EFcCC9d2924f3A18g2D56h3334i304Ak1120l1ED8m4273n407Bo4D7Dp8E4r3759s4901t29C9u304Bv440Bw232Ax45F3y422Bz3A;e2926h2412i13;a69Be4D93l1AB2w0;aDAc594;e48E4i123Ay0;e1k3B08l7Bt3FDDuB9;l30C;o1r28;a10E3e3245i484Eo4993y1C42;i2516oDEBr22u24BA;e1h1Ai20k127oA13t19BC;r424E;!gAAs0;a173e23i6n28;!d2Dg15Cn0t480C;!e33i24FpD89;bC8p1642;i21oD5;l0m2Cy8F9;k186l32;a26A3e18Bi34u252C;aF73d3Be1Bn2u14;mA4s935;!l2A90s0;e820i70o1y62;d487n2;m1B7;!e15iBEl22s0y0;!a0o10s0u34;lAAF;n4A50;r344u4F;!l7n16r0s1671;a1DC9e341Fh328Di3F6El2AA2o3796r2424u4146y2B13;d0o10;!r16F1;!a249Ce4i6s0u278A;l487Ao2853v2CwE8;lA8s1F;a48FAh13CCo1E80;n2o29u34;!aEd0l1m2Er4BBEs13C2t324;a1CBCd58e4E70i2C7Fl2237m18D7n3A31s269Bt4C45u4Fv2747y62;!n8r0s0t3;mD2B;a1F2Ce4DFBi3A0F;a8m3o2A;i5Do29;d2Cs2B9t344E;aB1Ee9u61;!a0e1g366i13s0u5;m44;a3339e23i6;!e12i448s0y0;b1Cl83n505Br2288s200;b1780c156Bg4Al22D5n1FF2r4s11E5t3768v9E6x0;o4DC;e3FAi711y0;l1Dm439En220Fr1009u51;!g7CEhBA6m1E9o1s0u2BA7w410;n2o9vB;c19g19n3FB4t19;g14F;!e4g1s0;e23i844t568;a3D25i245Br2874u31E6;!i1C32;l960uB8;!b3039g1EA9i2659kE01m22n28p8As4738tD8;e16C7i68l14Fr89y0;rC8;c2E32e4829hF4k3A64o896;d0e4t0;d58lF1n4899z3A;c1354o1qC2;!a1B9g21E6l329o50B5s0w311;r26BAs0;!i23Eo1634s0u5;d1Am64t277;!e4i6s1C7;a3E3Di13o29;!a10b17Ce2353i21l2C57n310Es258;l3n1;!e0l0r3D47tB;l841;b7Ar25t19;e43D7i6;d258mB;nC4;i2DAl132;!d258r1s0t78;h1l1;!d3A02l3F36n4B8Fo1EDs0u21Dv46;i36o81;a1B5h88i4;l0r2Ft3;e499i2B2;d5AnDBs1350t0wF88;!f1C2g1BCCh11Es0;a717i18Bu700;a5e3240iC8Am64Ao3E9Er2E87s0t4E09u0;cE50h4CD7n89;!a36n2ECr2B17s0;e28FEi21;a10o31;m251;g3505o10;i50C2;e1l7;l1r3D;n58;e47ADo3D9E;!a1FC8bBe5FBf848m3053o1EDp1DA4s0;a17l3777r134;i47F;a42ADcF00e1EEf14Dg1i1756m3F0Bn4EBp251r200Du24Bv30D2w28;!d502h10As0;!f183g56s156t4698;i77o9;t13E5;d2091;a42i36;e3465h270k626m29o2B66t3B30u362D;!i855l7s0;!r1s88E;!aB22e1F0h4972i4002l118Cn22s208At28ADu437w37F;!a22C4e4h2065i6l88o50ABs0y416;a4D8E;eCF;e403;a45C7eFDi4B14o73u3FDy0;!a492An4CFAp87Fs0;d3BnFt77;!l7n4C67r0s3E;!a18FBe1403h6FCi21s0;e1Dg50D6n29Ds1BEFt336;!e1Bi57Ds1AEy0;m5030n3578r27DBs28B;!e26i6o1s0;c2AlAACs14AE;e0g1Al58;l72Bp4D2Au490D;!e4DAi13s0;d2BBh41D;l8A;d0e1r1t174u36;a29Dc13Eo3322p355r5BFs8v8FB;s3u36;r8DCt277y0z7AA;!eB6Ci4311o98Bs0y62;yCD;hA8D;!d0n2243s0;l28t0;e1t18;j1As19DC;d540;!e239i4C4As0y0;e349;f1n2r266s4D7Bt37D0;e1iD0Eo29r26BDt3A;eAiE98k1Ap3DE0u626;f1nF;bEF4g3Am4752rB;!e84i68l44s0y0;e61;!l3F22;l1n4t3;!a17F2b3C01c1E1e15f184g238h48Ai19Bl2A44m2FC8n2BBr5149sDF4w4093y0;r2EE6;b7An52C;a45De44FEiF0Br73Dy62;a42E8l4D99;aD1eE;a46e222BiEo449;dA63;!a108d41n2655o2727s1EE4t28;!aD5t0;n77C;a1E8e15i6u57;d0r1t174y0;g1zFE;!n1Es0t0;a1DEDe1B5Dh363Ai4A39o16EBr30BEw6BB;e5mA4nB;a3D02f0k1l47ACn47A5r1AsB1Cv794;aBDeDA1;a4Ce12;!a213Ce15iADs0y0;!a12c3s0;e1o10r1s5;!e3801i6y0;m83;e1Bf7n2o29;e1Bn4;!e15i43s0u49y0;dBl1CnFo10;!d2111g157j157;n1t2D;e12i194lBoBy0;m11F;eAi91l19y0;c631e1C3;f7n0t3;a20i10o29;n52Ct4203;!a3381e3607h2E84i801k9Dl9Dm2Eo3B76p20C4tE10w22DD;i564;a1A6Ec63e43F2i1A9Dk2C4o46;s3t19;i57oE;a13Cl3;o4B76u90;e222i1;e3Fo29t63;l478An13A;r8s3;e500B;c708h3913k0t4536;r2Fs0;l68B;!iB3nE8Fr1Es0;e30o74;i109y0;e2647lD33o172;iA5u51;o2886;bCFjB6;a2D1e5Di2Bo46y0;aF15;e1Do1;tB3C;r35E0s960;!aCi5Dk1Es0;a1E6i3Fl32C5;!aCi1B7Eo46s0;a88e33i194;i2BoDy0;r2D3;n2Av3;rE5;a1AEAe15FBi16EFo88A;l38E8r1;!e24i21u1;h42DB;g17D;!a1De15i21s0;a1b88Cd2F61eEg374l1E0Ep7t3C76;a57i663u6;k27n0sE;!e1DzAF;n66C;!e0s0t1w1;m3t3;c19n19;g1D6i20;d38e157Bf1l2B8Bm1p28t38;!e67fE5i43u57y0;!a2DDDb2DC6i1Al2DCAn12Fr1As0u5B7w2D26;e17E;lA6B;aD9Ci37F2o12u41F;!e155i82Dl22rFBs0;g66Al75o0;!i125s0;a2CFFl367Fr2165u4F;o2273;!e1f7i97s0;e3E9;n2s288;g0m3FEn4175r356E;lA8n1o10p29s3583t1A03u5w1;!e4f217Ei6s0;e4g1E;!a17e4C6i250l7s0y0;!h46A4u9AE;d132Ae5f3128g1A25l58Bm1C89n200Ep175Br3B3Bs1216t2E7Dv2F04z1001;i10r151;a0o9r1A;!m64s0t1EDC;p12DuB9;!e2515g54Ek5Fl588o10t380Cy0;!e5z70;a158eD4r56;!b2F5c37F7f26B2g1hA4k2A7l28n30DEp12Dr133Es195EtD27v504z2C;aEn61p46;e226Ei3C;!bBA0sD04;nAEp8;a5t139C;!n6DsE;i124n0t2C;t3w1;!e3Dl6Ds0;!d3CDEg1260k28n58s0t4F4D;d0n60r1;!a453e4i6n38r58s0;!a4Be10Bi6l7s0;a2F5A;oA6rA7;!e4Ch4C46iCCCs0;l461C;nErAC;eF8i9;!n25s0;a5026e2C6Fi1D7Eo4841u256AyB4D;!i2B7Ct1A81u310;e3AAi68;e116D;c795m48DFs19ED;e71Di4BFDo1r727y0;!a1FCFb2168c2532d4FE7e4521f46C8g1A88h16Ei423Bj20Ek28l2BA0m4A80n49DAo4127p4D9Er4DD1s2F07t48F6u1163v3849y49C2;l847;c19t18A;!d0i6r7s0;a69e4;!e15i6l800s0;t61w16;!c1AB;e23i6t41E2;l4AD2;!e2DA7f37i21l22s156;a1i476B;a3276;l30En3B62r2BBD;x56;a40eAi330Fo8C;e5n3o9;!e1l7s0;!i56s0;!i480l7;i3Fk16l16t39;!a171e3762h1545s0;!i435s0y5B3;!a2D41d30De6AEi4757k1n228Eo4935s1C7t199Bu5Cy0;m1An1A;!e5k167D;a4DeAiAE1o12t1832;!e27;h92;a4De3EDi194y0;a26B9d17Ee1p83t3FFF;!aE85eC1i6l219n22s0uB;!i50C3l1EoA16s0;!e1i0s0;t2244;!d1DDl4F42n19B0pD8s2716z1AE2;g587;!a95Cb1DAe4i4F24o11Cs0;r164;c35Ee1Bg96n2s288t3;d3D06e3AAi3E7Fl4DB3m4EECo1EEFp43Fs1A6t1y0;!f37n3EFs0;a1e6El44;c1A59eAi6l2C61n1Ar63s4D4Fv4C2B;cBd19t19;i20o719;a23Et3u14;c1E87h21C5k1CA5tBC;aCe335i21;!d0r1s0t2D;a4AF8e2ADDh2916iD4Dl198Em4302o1F52r1402t4767w4711y1026;s6A;l121;i161;!a113b4A67c4D78d102e28A9f5CCg306i280Fl1F29p2748r2A4s3347t2E3u59Cv303A;!aDF8e48Bg44i60Ck44B0l7BoF6r2EFAsDE2t136;!l1n25s0;!g7Co10s0;a600b2920c1BCEd3738f32C4g3973i504Ck2Cl1FEAm2BA8nFFBp177Dr2184t3926z384D;m3E28;aCi31o46u4F;!a920b10Ae4i21l1FA9s0tDEw133F;e5120;n284;i34l1o5DEp8EDs56t4C53v5F;!i1B2Fs0;a0sFCu14z3;!c4C9eAh2FB3i6oB66p92AsBt38uB9;t53C;i20y0;e99o138;b1Cg38;a2AC;a42A1e359Bi2A4Cu3AA1;!e24i6o272;e5oE1;!e4i711s0y0;a19C3b437Ai1529;!e4i2DFs0y0;!l18A7;!b287;f49BBl28n2Dp2D46r3DE1t29FF;e9ACl2Cr16D;!b2ED2c1C84e15fAE6g69Fh183i3DDDl999m2ECFoA1Ep52Br1EAs4868w169yEC;i111By62;c42A7;!a369Ed13E4e4161g1i596j1E99l16A6n58p453Cs4B63t153Bu259BvFB5;a3D5;!e135i2B6l7o46s0;a23AEd18EAe236Di2EFBl1C16u2EE1;k229p47r2F62s257t102w30C;h49B2;e5D6;m3DABs1C9u5;!e0l0s0t3;!e4f61Ei68m5Bo4020s245t16Ey0;eB75i457Fy0;!a1Db337c12FeCA0h10Ai30B3l8F5p305Bs3DEEt61Aw2A5D;l1EFtBCv102;!c254d38e0g3DD1i640j18nA8Fo349FsF3t196B;a6F8e1o46;b3BDEi3A9l27E8p356Aq11FEs0w61C;i3A8;!a45c4671e4849s0t16FE;e6CrB69;e894i12E5l1CEo73y0;i4FB;!i4FB;o4F02;!r1Es0v19;u98;i3Co298;h1CDDtFF;d4ABl53s1F;dBr8F6;!b17Cd0g636l3860o312Br1s4C69w9B5y0;!h104ElBs0;n459B;t20y16;!b1D2eA48i6;a462Bo556;!i4081k504s0;!a4B43b2AB8e1f436mF7EnDC7o406Ap1E17s3036;c2269e1hBk44l4729v913;a50e15i86;k3FBm10;e84Fh518l1233u5C;!r3D3s0;!d5E9s4B24;l7A0oA06;c74Af108n2t5E;k1B8;!eEiEs0;e0i13o46;!d0e84s0;!d0e4s0;l28C0r57;d19s8v19;e15i7F6;u3990;!cF6e0r1AD;i273;aCg5k28lBn6D7r2450s243;!e15f37i91o1r40Ds0w7Fy0;bDD;b1Cn65;a2844e24E9i2FDCoE42u1CF0y28AC;a4861;!n1B0r437s0;d41e1Bl7n2;a1338;c2D2Cg708l1A94n3489r3698t332E;p0u5w16A;c19rEt17C9;!d38e15fC3i3F8s0;b400Dp47;!a72e12i6s0;e67qC2;e15i375y0;a1De23iD9n3EF;!d94Br35s0;aCe5h243i3120k3923u2F95;!e4f37i6l22s0y0;a40n8;o261;i1s1F;e99Bl22;c19DnC77t14B;e33i6;w204z4D8;a3A0o1D5;f8B8o8EBt28;a2C99lBu9F;l3AF;h2D9A;d1A2;a87i1C34o2573y8F1;!e79iCAy0;o35CF;!d7Fm2Et27;a41CF;o82F;e234B;!a13Fe17i62As0;d0s8t11;e12l1n2;a2C4Fc50Fe374AiB73l23A9n4F49tA28w96Bx2AC6;!nF3s0;!a7;bA4Ac2Ch1i4m7t2Cu195y28;!a0s0u389B;a1d4581e36Bi26B6m358Cn469Dr3285s559t21Fu8E3x118;!b3E4l0mA4n1ECs0t1BA;l3BA;o5044;t4EC;!e15i4ED7l7o12s0;!e12i214s0;!i732s0y1BA0;f0v10A9;s14t3;l418;a1De308i52D;!e4i6s4F4;!n3r4D83;v866;!e46E4i6;c13Bk1E8Fr140t47;c0e79;u146;l3F74r0;!e15h110i68s0y0;!d0s0y1;e45A;a35Fe2A0Bi3DBo499F;!a42d1E16i2Bs0y0;b37C9c2B98d3222f18F7g368Ci16E1k2Cl179Bm4CBDn255Cp1C6Er4E54s15B3t4D4Bu273v2Cw28y4BD4;!a3327fC3g3F68k429l1o3AF9r4185s0v338A;a170i3C;!cB1h1F;!c168s0;!i63Bs0y0;!e142l39Er3FE0;l16n1E;!c1C9e4i6r2468s0t0;!d3C89;f3v2B;aCl0;c0dBn3s40F6z2C;aB9Bf7m27t53F;k2C94;g1o1;!e15Df37i6;c4E6d135Ft18A3;!g32C2s0;!n34Bs0;l668t16;b1DBo3A5;l377Ft47;!s1A;!e4i6l2Cs4D8;t3D;a243Ax5E;!e23B1s0;l0tBC;c4Cs5Et2D;i28Ao72;l57;b2C72g1F7Et38E;!a1e5t537;c0f7s19z19;a14B5e4i21r27B0;gE0;!a9b293cF7d0gA9l4C66r182s0y1;d1p1t16;e1562;t4221;!a24D5e2941i3A04l13B3o49r2B7Fy0;a466i2F5Fm22C;e0i77;!a13Fc226e0hC28o513Es78t34E0z7;r2172;e15i194l44o73y0;c12BDd11Ff378t1CD;!l0m163;!m366;m366;m2C49;i6E6r51;!i8El2Cs0y0;p1735t451;b17Cc353AiA94r0;d39t1;!a57d13Ae17i4A6oF52s0y0;!l20An22w134;a62Ee2C3Ai2B8Do2AF3u4F;t962;d28kBA3l28p2ABt44Az2977;cD3l0n83;n430Bt145;!g0i2F1l60En1EErEtF4Bw1;!l2ABr1304s0t5C;!e10EiBl4B4n753s0t4Ay0;e2810g38i278Eo3478r323;!e5h1F;c1EF9;!eD45h3231l44p7Cs0;d0r39A;i2FE6;i2C23;g27En1;!i39Ds0;d19eEs5t1;e1Bg8AnFo9;h1C;s1E37;!n4688s17B1;n330;i294Fy0;d19Ar0;a22E5e50F8i72Fo1CF6u3610;e5n12A;a40i3887;a0g1i13u14;m345A;l42A3tA73;e2098;aF32e1E21i341o9BuD4;aA65l1D4u31F;g1v3;!e4i13s0y0;!e5z4737;!aA98e4i68lBs0y0;!m3EE5sAA3w238;bB4c4026d4AF0fC89g2FA8h28i50Dl1505m2FCFn25EDp3E83r130s142Bz1839;fD8u0;!e27h92Fs0;a2D10b4811c39FAd1F43e44EDf1F23g1340j75k2Cl3D5Dm218DnF1Bo3BD0p264Cr3549s1A93t1022u391Dv4E58z1FE9;m27n1;c167s553z19;e30nA1;!e1g347s0t798;!a488Fc3C3e3737h1272k45EDl19r10C8s0u3835;a4374d28e6D2i3C3Ft2CB;l25B1t68B;!a2126e4DD5i3933l14F9o249Dr1225s0u36FF;lB4E;e1Bo262;cCF;e30g3At366;m47Dt256;a4Bl3;!d5B;p5B;e1038i6;!e760i6;d0r1s2147;n3D59t55A;!o5AC;a5Fe10C4;l7Bt1;!e15f37i42E3j236l48s0u57y0;r1DF0;a315Eo21;!e4i6l28s1F;!a69d0k345Bn1r1D9s0w1DBy1;e135i17E7y0;n4E53;tA20;!o80Es0;aCi4oDu4F;!e2E12i4CCl8CDo24A6s0y340F;a1DgC2s288;!a9b4ECAc50C5e46Fh2524i6l3523n22s0t2F9Cw385;c2CnE;!e159i68l1DBAs0y0;a4De34AFi388y0;a2F2s1F;a6E2;a11i2C34;a20d0s0;!d0e9r1s0;a1d103e0;!aCe5iD15s0;!c4EFn1s0;h4216s0;!i146s0tEB;!e3E6i6s0t28;b1B6c234o10s11;!c1FE3n4EF4;n13;a4De6Ei21;a2DiE22o1Fy62;r3C12;oBAu1D;!k1En1Es0;g6CElE36n37AEt2F4;e195l1EFp235r2B0s4F;i23A4;!e40s0;nFp16;aDt1;!a3F47e1BiC32l7s0u659;!e1g0i0o0s0;p674;c404Dn2;e2D28;h2865l14C6;a4AAD;i2425;!a38E7t0;!d0i6r35Bs3Ev3D;!a4F2l2FE3m59Bz2FAF;r7BBs20;o403;c0k0;a9c0s8;!e67f37i6;!e49ACo4D5s0uB6;!cB6l63nF9Ds14;!v27;!e15iF9o12s0;!bF7d2F09e23g2DDi68n82As0t58y0;f20D1;r149;eAi6A5y0;!e24iCAy0;eAiCAy0;e19F7;a1CD;d16FCg5F;!nFp1E;!d0s0t39;n114;a316Fe4528h17C1i137Dl111En1417o2196r1FB8t3BF4u2ED1w34y21DCz359A;l726n2BD;b3FCc6B5d39B2g1926i4EC8m4128n4BD8p3AADs185t429Ax7;!l7n22r0s809y1;r1B3;!r1B3;a10lD2;!e8Ci3Cs0y0;a11Dc13EiC;c2D4n45At2C;n10C;p21C;!a33E2c2D6Ad2680e26D3f1D8g48E7h1AEDi2D0Bj20Ek4710l32F3n3DA9o1271p4760r275Cs2445t2869u3E31y2D35;c3686;h274jDE;eA4;t3B5A;a1544e99i1E29o69u3FB1;lA53s0;a1DE7c3CAeA2BoA9D;!e79i18y0;i4C60y0;!l236;!e8i8;!d0l5F0o29r1s0;!i786s0;cEEnFr25;e108;s64E;!a1Dd0eAi6n170Er1s351;p3BF2;b1Cn2u34;a2D3Be1;u5CF;d44A5g34Es3048t3041;a40D;dB4q492r3A0D;e23i21m64;c3E55n2q490C;a2C6oC7;a30A5e7DEi4269l3D66o1253r4F18u509A;a2ED8i1517r1A;!d0i6m2Er1s0w426;z117;d58;e113gBl4D4;!dC9Be0h1E8Di1273l7n22;t4D06;d0n1r0s8t1;d0n1r1s3Et1;o42EE;!aCe1i13s0;!a2AdB42e2AhEDm2Ep270Er2796s0t4BD1x1F;nBt3;c52;!b297s0;a4B3C;o29s1F;iBo42;!e4i6lCFs0w7F;c0d501EfF2lD3t3;!n3Ds0;a9F1e24EAy72;e38A;a2C1Ee3BFCl4C9Am46E9nA84o42FCr202Ds1079u2819;e701;e23i36E3;!aBC7l849s0;!k11l78n753s0y0;e1t3BC;gBr31;!e15i6l7s2434;!a326b21FCc2518g12DBk2D2l3736m2A4n22E3p15D7r3FD7s3C59t2921v1644;!hC5k47s0;!aB58e4AB6i1972o4BDDs0u4Fy62;!a80e49C8i4785l10As245y98;!a2A2D;o10u89E;e6Ei438D;l33BDs0;e12n3;!a47E1d1FCe176g6C9i375BlF3o4BFEs3AAFz3A3;!e15f37i21s0;a20u5;!b50DAc34B2d9E8e15fD3Cg9CFhA0Di388l18DCm2En28p2BCFs49C5t3817w3221y0;h14E7;n0t2D;a76o9u14;i1BBu912;a9u34;!a3895e23i21l2Co3FD8r3B6Es0;d0nEr39;!a32lBo26A0s0;aDAe536;h441Co1;a1E7u49E;n94D;a14CEp3Dt4242;e1r1DB;o14w0;l4527n6D8p118;cED6x1F;a9CCeB;e12ErB6;h494;r4t3;b1f108;aCs1F;c1EnF;l7nF;!a4B55e24iB;a785e502Bi3608o4F80u3619y62;r47C;w3A1;b66Ae2378;b3792;l3o2F;e99iEF;g39Dt0;lAD4;l47BE;e3C2f37;!aAEAb4225c56d3C8De4f1F0Ci21l1C61m1D4Dn3402p4B64r199s0t22C7w1E73;u277B;!e26iADs0;u36v48;c19e30lBnFtB3;eCiCo9;c1EEgAFDk15FAl16C8o30A0r4096t4691u350DwE;a1E85b4DcFB6d4E5Be1CA0g2E06l2F1m30EBn4700o3187s220Et6A9v24D1zB94;n2AFDt2D;!c25El0t56B;c361Af2BE4g14BAsB1t27EDv2C;!m1s0w23A;m63v519;f4AE7;n0r9F1;l1BFFnDE;!iB27y0;t2B05;c713r61x35;e1Bn179s11;c254d329Fm47n1rFC0s243;r47B4;b4813e2AF8g869k3m3F17n3pA69t61v2C;m1B0u4F;g47D1;e3DCD;o29u659;a4ADA;!a1CF7e2067h2B80i1D74o1DC8r48D2u1BD;!e15i1FA8s0y0;a31e2D66i29Bo46y0;!bD68c6A9d0g270i6k2Fp0s52z38;!aAC1e15i6l2B38s0t60;!eDr7s0;d0r6B9;l16r61t16;e99i1C8o31;!a30e25f37i778m2Es0y0;e4879h1C1El1DE;i65t48;c2B91d4681g3249k1583l3841m50A0nDC6o4DDBp1333r3B10s3AB3t318AxAE5;cEt1x64B;iE8n310Cy0;a3B6u34;g39BBt55;!a7DFe1CCf183pA8Es3AF0t272A;z814;!e1s0t28;d201l2Do4u36;l3AE3;!d1B8p47s0;h88;!d377s0;!o4B2Ds0;!a80e3D1h183iBEl26AEs78y0;!i474Ak2FBDo93s0u8C0;f858s39EA;e1BnFo9;i709;!e4i2F44o4BDEr4CFEs0;!a39Ce2B8i45EEo24C7s0;e0t215;!a1BD8e38A2i3A8oAABs0uB9y1A5;p2CA2z67C;!a4Bm2Es0;!a34e2A9i6s0;c92nFt1488;e4i25F1y0;c151;!c6Ad0fE5m2Es0w7Fy0;!d8Bs0;!a2D62e33CDh31C7i33D2o2F67rF36tD8;!e67i1E0l5Fm2Ey0;!a3896d49C6e4168g2A6Ai28A0k4799o3033s32ABt35E2u6C6y0;!b5BAs0;i3D2o1F7A;u22D;eEi0;dF6;!e1zDFF;!m34Es0;!a3D71e14DiAE7s0;e1u54;e15i43o0y0;k847;a20o46u5;a3FAC;hE6E;a80e3594i194y0;!a1CC8d4892e4675i21D0lAA7o1EDr40FDs0u6AC;i31Fu31F;a46Ce1o36;a314o9;gBl1rBu8Cv3A;n39r1s8;a176;c1i5Cp2046v38;!c4D07d1C6Be1D18g2545h954i513Bk3l3DF7m1FF7n4795r1B87s15AFt3257u298v4132w3023y4B8C;a87i5E1oDAA;e33s0;e23i4AF;!d0l6Dr1s0t1;!a3A8Fc3429d1534eBg34DDi4442k4CDEs22FBt47uF1;!e4i164Fr35s0;!i7Ds0;e9C6o5A2;a434Eb4A43c26D7d2F0EeD60f41F9g3982j2E5Dk32A3l11FAm10FEnFBEo193ApE43r2DD2s3B1Ct257AvEF0y5027z26A1;lA8r102;a1DCu36;l60t292B;h3099;aBDe1;!eD0i21l10Ao51s0y98;h2206m4EA5tFEB;!e43C9i86l2Cs0y0;i4ED2;e2B11k7;!h66t384;o298u1D;o479A;hBk47tBC;lBr121;b11Fn11B;a6EsE;!e10Ds0;!e1Bs0;iBD;!b1Cn295s0t275B;t4598;!a9DCe6Ei36D5o56s0;e28C6i21l7B;!e5u57;!e84i24Fo12r22s0;i392m2Cn3C0sC0;!h9Di69;m3AAE;a4Be1;e30i3;p268;n3F02;f3B;!s0wA9;!g7Ci1Cm64o12r103s0;eAiF9o12;i583;c327Bd1140g187k346Em3C5An1149r29BDs2ADFt3182u48DCv395;eD0i319;a392i224l36BDn10D7r258DsA3Ft1CF;l8BEo4A8Br17D;e23h66i43y0;!aCe3AEAk5Fs40A8t1380;e1i3E6Bs1F;hA90l63;!e498i6lF5s0;!aD07eD0i21s0;a309e1;!b25F4e42EC;k3sEv3;!a205De26r7s0;a14e0t1y0;g49BEk1Ct39;e967l274;e3E95i6;o2F10;n1C60s5Et107;b1Ct3;!aB1Fe4iF7Bs0y62;a39AEb43BdB1De4A55lCp8t7FC;!e4AC9i8F7lBsA1t2BB7y0;d0k0;i2CF1y0;!e24i47A3;e2EEo6F0;!z39A;i2Bl44y0;!e4687i86l7n22s0y0;!a4Dc97Bd4211i21k1B8l10Cm13FAn0p4FAFr50Cs8A4t4623;i50o138;l31CC;i16Bo6;b47A;fEwAB;i32C;!i1CDCs0;eFCDi35D1y0;!d0l7r78s3E;!d0l7r0s8;b1513c37FCeE4Dk14Fl1126m3C74n2993p2404r2280s3005v38z2142;e1Bn92EsE;i35o3D01;!l38s0;!e15i6k5Fs0;a41B7t1CCB;d3p3;!e4i3s0y0;l45;a3300b856c43C1d80e196Fg4D2Ej1F31l40F0n1F84p3E1Ds2337t16F3v3A3z1DB7;s6CAu232;g5Bl71n2Ds3E4A;a1E6c4EAEf183Br4EEA;a664i0t16u5;c1eB2n2;!e458Bi3BACs0u1;b3E4e181l0n831rA42t2B9;i11Dy47;e1CF2r3D;l75r75Bu615;i2B9Ft7;eAiAD;a78Do46;e5t143;d41t18;c74DiC4j17Dm58p40AB;d1k30E0p28t4A;aDAe4A3Di3FEFu2C;k41FA;!b1Ce0g3n67Br39As0t3850;r5BB;e42A4r606;!e10Bf37i6l7o29s0;e1Eo81;iA8C;e6;!e1Bi3Cl7n22o87pCDs2BE5;a104eC4i31Cy31C;h6A;d8D;!eF8l7t7;!e338i178s0;eAD1;a12E1b3C93c3F13d49FAe17f12EAg36C1i4284kBlF04m29E3n1604o417Dp3382q4359rD37s4BEAt1103u21A1v3B29w1A6Ax1Fy1980z4346;!a80h462;!m2Eo54s0;!jFBp2EAs0;!n1s4ABF;!e327i6s0;!eB6Ai6s0;i416;iF5Ay62;a1rEB;!e271i40A2o3D8;!b1DAc1E1d3Bl36Cp10Fr1s0;uF0;a9e1D76i15B;!a1e1110i323Fo27F2r45E3s0u65Dy0;!a4DfC3i39DAs0t8DBu1;!e24i6m2E;!e9i8Es0wEDy0;!e28E7i341l4E6AoF93s0t47uD4;a8i30;a3BA6e1511h106Ei346DjCDl3361n36ECo5028r2B57u3E53w26ACy28D1;a4740e4AE6i1DF3o77Er5Au1EE7;i1u1;n44F;n4145;aA2e14D;n44q303;a10h2DFEm75s37CCtDDF;!a33CCd230e15i21l527n0s0;d41s3u5;!a4983e15i4B58sEC;p39DB;aEw244;e8E5;d10F;s376B;!a4651e4i66Es0;a6Ci5D6;e4AEi21;i7Ds547;a57l246;!a4Dd4704e2565g15A1i3065o986s0;n480F;aEp19;!i221k4F1Cn827r1085s11t61v3y1;nFo10;!d0n12Cs0;a0c11eD1n3u3150zF2;o3604;b607d0g3FA5o1pB47t215v3FEA;h3A3p16Er461vB;!a824e3D7i6s0;a4744o50;!u26F;r9wF7A;l1p4E3;d19gBr25tA1;a3E8;eAi20FDoF3Ds18;c94e12n2o10s11;a1l14A;o8A3;e0u5;e0u1;m19Dn114s5E;!e1Bl7s0y0;c11t61;o57u34;!l7r3;a3A7DeB0Ci409C;!a1De1Di1A0Co40BCs0y62;hF1;e12F0;!s0t592;n18r1;u499A;c11d1;!n0s0t15A7;!b1ChBm3018s0;s3Au5;e49F9i1440;k2Cl17C5;a26ABeAi21o3E23;e2AFi46F8o4F;aCk7;a36e6Eh12F2;o34DB;e31r1A;a3FCEe2302i2487y0;e1Bn2t3A;!b1045c21Ef4794hEDi1F3k5Fl20As3E2;h2F9D;a39B0b33EDe1Df207Bh18A6i0k248Dl4445m4D1An4717o354Bp2017r1373s3483t334Bu3A12w4FDE;!a1bBdA9e43ECf513h35D7i21o4E4Dp2F6s3Ew33A;e2FFFt3D9;o26C;i97lC9r33B7;c2A69;n621;n2o1;r2CE;!a4Db44EBd0l456Fr12Cs4FAEy1;a1eBi1;e1l18;!s0t6C0;aA87;oEp28r3s9C;p10F8;a3E70e1F80i339Ao3B05u3049;l2C6AmE07;a1B7Ce17i9D9o1y0;!b29c105Cd648g1E48h35Cl815m213An2F68p3787s156t4D44;a1ECAe30EFi1E2Co1760u15FFyB4D;r2B9C;a232FeA7;e349l44;aCe24n2;a25d1B0m360v134w98;!a8e26s0;!m2Et0;r4F9u1A71;!aF28eA;o7DrF6C;i1526y0;!b1AFCc1B3Ae2319g1DF6iF41m1234n373Dp2260s381Ct3D29u4D0By2A4zF61;a1E7e30;c688s105;r67B;d0r1s65;a62Ec13Be1g1A2i49Dk47t1;r3F7B;k3143p3CE0r131;e1i13o128;r1B0;!r3A;e23n2;!eC1hA4i86l3646n22s0;aB05h3C8l5A5r27E;a1d420De1A15i43F6l3DF5o1F53s12EBt4947u4F;!e3Bi111;d0r1w1;!a20o29s0u34;a1De15i6o12;eDk3n2;i25r8Dt77;dBh1;!b42DhE0o31p31F0r52Ft4CC1w4AA1;g1i2183o46y0;i31o36;p460;!p460;e4i6s0y0;!e4i3577l7s0;r2EC6;aE9b2200l1F9oE9;!c1g8E0i13Fl0nFp390B;o2Ap18u29FD;!l0n3s0;e0i18;!e0i18;!eF0s0;g15CpD1t446z41D;!bA81;m1En2FCEr3237;o25A7;a158e1h2BBBiCF1p41;o4DA8u5;!s0t87;!r58s0;!aA3e764i6s0;!rAFEs0;o5FB;eAo10;!e4i214l1Es0;!a9AEb29D8dBe18ABi21l3270s0t2C0E;!a4A08e4D9Ci24Fl3105o146Fp58;a1De1136;c1gBl436;h320i1D;a1C58c0nBo50As2D7Bz3A;d3kBr40t2029;!e4i43pCFs0y0;n4r7;m3FED;a1250;c2Aw7F;e31i4lE3o1143;a4246;l4516;!e5i21n3;l1E4u1D;i26FAu5;e5g12DjF25r6ABs141At1CFu724v58A;!k7Cs0y399E;d9A5g49l369BmA8Fn4820t394v159D;c1FEr1CA;!a32D2b1515e36FDiCAl1353n4630pB4s14E5t1EAy0;a30m0;!c7s0t189;a88e846h23Fi7EElE2At26FEu41F;e4C5i6t139;!c235r11Fs0x492;!l120tF7;i644;eF7Di21;s3t5B;a35C4d10Ce0f28m47t4AC2v2C;r35B6;a26E3;a308iC5l35D9s0u372C;a4A82g6E1i2841o3B9sA73y62;a2E80b21DAe4ECCi25Ak1B4Cn2804s49FEt2CF3v4D96;a2913e150i4D77l43CAy0;e2026f4E24i4l44oEC9;a0c2BoBF9;g9s1865;!c181f23Ci0o29A8s192Cu5;a52n2;n8s1C6;!e15i2BF6o5Fs0;e3D12oC8r4942u34;n56;!c2D4lA71n37C4r217Ft2740vB4;i2850;a2D25u14;!a57s0;m14F;o50DF;!a10d4702t4EA;!b1D6d0f37l4A1m64r1s0t126;!e15i4C28s0;m5Ar7;e33n1;d1n16;a50BEb5Ac501d32E1e4A88fBFg1900k3m223Dn2Cp12Bq1532s16Ft0u3324v3y577z397E;e1n2o9;!g2A74lF4n4361s4AC5t91C;e17i5D4o46;n3s103;g4381m501p26CFw0x11Fy5;b5CgBm2Ds4ACFt1E25;a10b29DEc2B37e3DF9g45AFi4o20C8p3482sD71t3C65u2DB6v1C82w3AE9y4;!d0n19A3s0;t19v88F;!aC57d182Ce2DE4g307Fi3178n2E4q3284s0t316Aw98;a240Ee90u1D47;!a11BAl22m2032o3CB6p2BF3s0;a5o14;a1o14;a3422i17DF;!b228;m4E;e8Cn2;u4CAA;a28Dt4AC;!a3D95e4A6Di3F73o1248s0;!d0l7n22s0;!i26F1o2CBDt4891;!b1Cn14Ds0;n75u1;c41AkE26l1Dm12CBnCFBp4FDC;!n22Bs0;i32B1;rD4;m1A3;e0m1Ao36CE;!d35DCo9Bs0;e4B3i1E0y0;r30D8;g2EA7l82n107s3E3t17E;!e2C79g7CrF1Ds0;c458;lFA6;k0m0t0;a71o46;a3DE6;a46Ce1;aCe5i13;!e150i86s0;hB5E;!eC1i21l7n22s0t0y0;c0e1BnDAE;a42h28CBi36;f3A3A;e1t87;i4871;l18m2F;t4482;!c2289gBk0nBs0tBx0z35;!d0mA5n43Cr1s0t0;!a3016e1i33B4l188Bm7Cp4578s0;g1t19;n3AACr3003;!e10BiADl2A8s0;a3F0Fe586i2480u73;!a18A2cEE9d2E26e21ACf1CC6g1F7Bh305iAA2k3189m2En4F96pE2s4B57t2AB0w2B1y0;e23i86;n7y1;!fF2iDDr94D;b7Al3n2o10;r2101;!e142i6l1816s0;b2E3Fr1446;d114;o4156;!c4B4Ed12DEf491Bg306l3FE6m629n4406p964r1s3F04z6C9;a244Fe1255n4CD5s430Cw0;!a4Be15i43p4Cs0y0;c1C9u12;c52t1;g175;k47l1;d9EB;!a90eC1i6l7n22s0y0;d3077t39ED;l55x1F;s4CBB;t963;!b43CBd648fACAg15Cl22BBn49ADs4EBE;a1eAi6;i3B3C;r646;!a20b7g3976o4440s0u67A;eDr0sEt1;w244;nD2p42E;!e12i21lE2s0;a1497e2A68i31l2A4Fo4606r1716u30B2;!e593s0;!eEl19s0y0;u65B;!e59;e5n156Ds11;!d3E3Cm319Dn4B0Bp2190s0t2D;n8D;c3D40x1F;t519;n36C0;m484B;!a37E6e2BBAi2E43m89p7FBs888;i6oA0;!eCh1AEBm2FAt305E;c3132p18C9;!s24EF;r35t20;e33oDt1;e24n2s405;a65eEi31;!d0r1s8F2w23Ay17DD;i5B8y0;!e4i6m64s0;r4880;g88D;l307n1;!e1Bf2Dn18F;p8D;a16Fo54;a1lB;a4701e2E2l3E92;aCEi65;e3116i21t16u5;e373i1E0;a4EC6e4AA3i2867o504Eu3975w198yCEF;d27i300;c39FBd3C3Al2826n3B48tCDF;!r2E1Fs0;c1Cf7n695o10;!aB1FeEi56s0;!e4C0i43y0;b4990rFB;!eAiC30o489s0;m1B25;g1r1;g1i1BE;t40F8;e4n1E;a4Ai56;!e212E;cBd2Cn11Bt3644;h27t1A;b1B6c25D;!b343cA3De15i37A9m5Ds0w3BB2y0;n1279;i284;!o6Bs0;b16BAcD57fBm89n4AE1p14A8t1v40DAwA9;c48Cn11As9FBz19;e19oAF3u37A4;k0l16;eC1i86;!a4DbFBe4i21s0;!iB76m38o47DAp5C4s0u1810;e12iA9F;c3d41;!e3DAhAFi6k498Fl75s17D4tEAE;r101;a491EeAi3731;!a25C;b145lA22p10C;!a3EA8dAAe1f513g3136i1l7BoF6r3C5s3ED7w385z7D5;!a2547s0t152D;a1C5Be12i5Dl3677w656;!a4Ad44DDe15i21n0pB4s0y38;l182Fn8;a3C9;t568;aCn2s11;x118;i4l34Fo29;i4oD;l5005r2723;o4BA;l48EF;a1De23i2B2;uB57;r0s8t7;!r0s8t7;o4Fu4BF;!e902;e4932t1387;!a22EiB8s0;z130;c58l2598t176C;f0t0;!a0eAi6t47;!m2EAs0;f2C55;e265l7nFrBs11;a16Co12;!d0i6l7r0s3E;o12p10BA;!a203n2s39E9;b55;l5t7;c2Am3;!r3CCAs0;a95e12;!aA32i8Es4CFt1072y0;l4059;!m3E2Ds0u44F3;k3t52;!e4C51i787l7n22o31D;a12e190;a0e0g0;i1r746;!p175Es0;!n46DAr4FCs11A;g58i2873k44A1u430;d1DDe409g4C79i3Ck28;p7C;!a1587e3051fF0i2E5Bl1o44E1p34C7s0t1F60u4CF8v44;s19t3z19;!e3D7i1E7BoE1s0;!a4Be10F;dA7k28;!e0n25r78t468;a34Di3C2Ay0;!e6E4h1jBp2A7C;sD2;aCeAi6k16A;e1C4Cg21EhAF;eAi6n0rE0;i149E;!n75pAAs0t6B3;iA7El19y0;!a10B0e1i13s0u65D;e832;a4De23i1C0;a1B4g0;i3F08;a2F1b1f8iEkA4m76Dn2A70t38uE;!aCc114d0i9n42Ao3BDCr1s0t114;c174;u129;u653;c11eA;fE2;nBs1Ez1E;!c180f19DsC5t1A;oE7Ar490;a18F8c1C92d44D9e3F79f2BEAg4F1Dh3700i41E0j44AAk4015l3922m301An1CFAp2E92q4B33r3EA1sEE5t251Eu1F10v18F0w4CBCx18D1y1EABz41D9;!a4Be4i91l6Ds0y0;mC9r18;c11n2s637;a2015e654i2076o11D;d0n624s0;!b358p114s0;aA3i36;!d3Dm2Er7s0;a227e150iBFFl2Cr157y0;u496;!a0e0s0;a6Ce35i35;!r29;!l2FF6;uCy0;iAC2l0;sEu14;!a50B0b14DDdAD5eE28f28h77i1D2AlDEm4818oE88p3280s3629u4F;!i77s0;e17o6;d0r227A;p7r1s5;a1e38BEi28C8o46;!pAE8s0;r6D0;d0r0s1C6;a18E0e4DA5i478o2250u3227;a4FD1oD02u32D1;!b385e1Bi285Bl7m1E9n22sEC;!i904o35s0;!eD3o10s0u34;c120d3781s0;a4Ae4A;pE3;c44E0d3D0Bg96k0l2E6As3037t419D;i1Ds14EB;c0d19f7lBtB;!e1954;!c4919d2318e18C7g38FAi68k341En31BDo1s47EEt1BA2y0zB;e3E1;l40rD6;!l0s0t18;!d0s1t1;!a52eD1iEs0;e277Au3EB4;l39A8;l0y0;!l1r1s0t4BFA;!lB4Em3D7Fn2s0xB;m0t2F;a3E65;n4s336;a21e12;o8AF;!e4i6r41s0;!bA25e1Bi6l7nA37;e261r1B21;k48sE;d1t3;y1A;n3770;b5Cc482g2CFBi224l30C5n24ACp4E9Fs3141t4733x0;a9A7i231Ao2DE7;c3EAg1A;eB03;a14CBb3C9Ec2E55d1991e4905f45B4g3F15h485Fj228Ak13B5l36B8m3BBAo9p2D67r35EAsC91t28FCw3FCA;!e1Dt4E2B;rE9;t34FC;!e18Cl7oDs0;e370A;nFsEt3AE2;e16CBo448D;gBt277;!iAEm1r3As0;a163Bb176Ac1754d4460eD4Cf2D39g1396h1i70Bk4CC7l218Am137Cn213Eo3E48p1EFDr2D03s38E5t41CDu47A7v409Ax4DCDy70B;f1t472C;!jFBl228pA43s0;d4363;r67D;e1i97l7;!hD2p297s0;a20e57;d0rDFA;p1Ct11;a61d1i210m27;!m342s0;!a4CB7e135i50C1o489s0;!a25Ci9k1ElBs0;e1g53;a3Ab3A2Af15C1g2888h10Fl1339m1E3Cn4303p4768r253As11B8t462Ev44z441;!i18o9Bt160;a4049e1597iE96l3399o1E78;eFDi43y0;u2D2E;e27F7;e1hA0B;d0n2F4;a3A44u1C;a78Ae294i6;e1i3Fu9F;n77E;l1F9p1;nACE;!d0l314Fr47s2EBw169;!n60;l4A5A;!a2E1Ce891i2B9As0y0;i332;eA30i32;!s1t1;a31D3;!c1k1s0t1;a876i2Bo372y0;e1FE5o74;a281o1u3798;e23iF9o40;n3o36;s4131z613;e2562;l1m2FC0v44;f7n0o9v3;aE4s8u14;!a306Ee2097i18D9l5D9o12E9p2E4r4E50s1B4Bt1B1Eu38E1y1E1C;l62pCFy0;e3C7BoFDBr1A6Fu3D96y52;!a37C2e2831h3B7Ci1A70o1646r2DF4s0t1025wE12;eDn2o9;!n0r16s0;c44gBr2B3;i4984;h35C9;a83Ee9;l14F;c64De0h1Fk2407;!e1Do29s0u4F;m45n4;!g257;e118Eo5EA;e15Bo73;!i2Bt1D9y0;l9EnC1Br39D6;b3FCc2145dAC8f3C33g4FA4p34CEr228Ft2693v50EF;!b29E1dA70n28FAo3DEAs0;e23CFi21;n203;o1r2C0;s3w1;i2Bo42y0;i9u9;nB0;eDl7n12A;e15i66E;m10Cp1s9Ct1;!b49CeAE0i101Dl7n22s0uB6;eDk3l7;!a40i0s0u5;i77u5;!e22Fi6s0;b7t0;a1C94e1A42i13A7o33B3y0;!d0l22r1s0w98;!a23DiBs0;h4272;d48B5s196Ez2C;!d0hEDn22r1s5A3;o241Cu3F1;b3e24v3;gBl0;a0o5;a2336b375AeABi3E7Eo2D78;c41l0;e4i6o0y0;!a80b12Fe15fC3i21l22s0;aEhE;n3AF;i1Dl6An7E7;!a4DbFBe15f1C2i1E0s0y0;aB34h1AEo365Ay453B;!b2228i3631rBA7s0;e12r19;e21E1i68y0;!e15f37i6l2715s0;b1Ct1E;c0o971t5E;g471n103;!e0n3r7s0t3;z4CF;z16D;cB1e23i6o10u12;a2820e57oA0r9D;d44F;o1u14;n40;n65r3;l7Eo10v3;!l88s0t12B8;e1i1k18;a17Fi133oE7;a36t1;dCD;!e6C;!e439Dr11F0s0;e12nF;e17i95l14A;l131;n311Ds0;!d4456e682l47n1993rBs2109tB17;r2Fs8;e15Dn22;a52i13;c13Ae4037j13EAn58o10t3D6B;a2C6l19oEr94y20;a9F4i3A42;n3o8t1;h33D4;!e23i6p4BDAs5A9;l45D0m229t1484;t38D7;b1Cc2C;n33E;n2t28DC;h12C4;!e4i9s0;c0l9Fn2s11t1877u14;a42DA;aB35i45Bu45y62;l2BB;n679;!d0t2F;r57;!a488e4i6s0;a1e5o9;c23Fo11Dq783;!fC6Ei12s0;!d3i4s0u5;d4961r1B2AtB2AwE1;r96A;a9c0s3z3;!c92s0;b476d2D6;!e4i694s0y0;!e4i30Bs0y0;!e5l2FAr149;d1e3Fj4Cl4953n26A2r34B7tB95;d0e12r57Ct39;!e0i0;l0n44C1r25s19;a95e30C8o512r4B44;c2Ax0;g41t3;g3Dl0n4y0;eAi6tC9F;c8i13u14yC;cB6i15E5;!e25s0t20;e1Bn2t3;f6EB;!c168l107s0;e31B8i5DDr1EAy0;c8A;gFDEm64;o3B6C;d217k1l2B4Dn46E2s0t2B2D;h14A0;yA5F;lB2D;a3BFF;e2670iB;i9n8;r1635;!c13E2d38e1g48D4i20k28l5Fn5058s0t28;e0oD2E;a106Ae9;a475Fe251Bi2E9Fl88o4298r4650u124;y3F52;!e327i3A50o609s0y0;i20oE;kB07;a9ACe4i21;!t12C;!a54hA5;i4509;k1El1E;s3F41t2Du5;a104eC4lA5oC4rA7yC4;!e67iCBk4C;g46D6j3AC9k1l28n4A5t2A53;a3DA6i279Ao1A2F;!a4670b5D1c32B2e4F77fEg10i3543m1EC7n1AD6o103Ar44E5s3576t22A5u2E96w3F1Ay0;b1Cm0nFo10vB;!eC1i86l7s0;!i13o9s0u3y0;l1Er1E;r22A3;n1w8D;!b401mAAoB99p3DC7s0;h5C;u52;!u3;b30A3;!d0i6mDEn28s0;t3A6;e12h0rB;!b1p28r82As0;e6Er1D93;i2CFo719;l3Am3BA5o1D0;!e0nB4Cs0t19;!a12e15DCi6s0;o2DD3;e414Di3Fo29;i0o36u46B6;!a133Ai258Ao37EFs0u50Fy0;i11F2u5;u3F1;!e15f37iCAl385Bm64s0y0;!e4i6s66;l7A0;cA57nFo1s13Bt1CAA;h450A;!iBoA6s0;a173e67o29r56s13ED;aCi5;t1D;s2A47u36;l227Fm1nFr39ABu497;a4B27b122Ec42B0d4080e40C2f21Cg27D0i2D2Al4FF6n22AEo2BFDp109Dr3697t3022uE15w5E;a36Fi302;a1A2Ce146h30CoAB7u147;!d0l22r0s0;i324;!e5t2D;!e597f37i6l7s1C0C;e166E;e3125i6u49;i20A9;!i4A6s0y2619;e3C8E;!eEf37g0s0;d1e5;!a29D5d27BAh293l28r1s34F1t1F98;!b206d357e4B7Ai4D2l4ECp3BADs2C28;d4D2B;d80t441;h1FC0;i11C7;c2F7Fe1i18l4E25n22o2AFsBy0;a12c299Ad1D0e1g2BACi4AC6l2415m4229o26F3r1D4Ft49F1u3863w2C22x0y48EC;a3C3De3FF0i21l28o9Br343A;!a4894e39B7l7mA3An22s0;a898;n1s0;a205;o2E01;g20D2;n5056;r76F;c32n0t4A;a3C6Fb1B1Bc290Dd15F4eE5Bf37CEg236Ah13C9i3769j2983k4F54l3F63m342An452Bo1718p42CCq2FE4r4E76s10A4t1783u3E78v3C85w3332x32D4y1E47z3832;a795eCAE;n2s19z19;!s52t396;!a1c951d1524i97k888n48EDo7ACs0;o5u1zCD;a2E42e254Bi204Eo169At2A6Cy403;l276;aB35e8i23C8;n61p89;t264;cEEd141Dg4Ai5n703p20CDrC1Ds1CE7t197Cv356B;c32l3EA;o30EA;n329Cr2C;a2EA2cEi7BBn25o36sEu5;e15i6lB;s34A;gBk4C;!o15Ap8CDs0t0;!e1Bi1B3y0;!eB2i27y0;!a76d0i4s0;!a162c254e4i2E00l329oDt1B7Au4Fw1A;g3l260r7;aCi530o3CDu4F;aEFBe47Fo4D19;!a3B1Ee45Di2F12l90FoE7s0y0;i49oDF;!a3749e4BD9o3F21;!b11C0eABCi4D2l75s0u4F;c32n825t2A3;!g1i1As0;a2Al683n144;e3827;h19Di7Dl4331s58;!h5Al1E2p351CsAFt537u1221;c46FDd4A7Al17D0r374Bt261D;c2AnB;k1D05r2875vB7;!k5Fu1704;!a1e4i6lBs0;!a173d0l1r1s0;a3E26;r1AB;e12o3A63;n8s8;!i13o3A5s0;!s4FEC;cC8l4r14;a166e438t48B3v452;a11CCe1A1Bi1D72o4D46u32FB;o1876;e9i3Ao241;n1B6BrB6t192u5;b4CEBc3E30d41BBf2C7Eg74l3F09m1585n1712p2460r1949s3C3t2F9;t4C2A;s4Ft1;c4B0Eg227m64pC7B;m23Fn1;a1542b4CEEd83e2DCBg0i0n2D93y28;k3r8;k16s4C;h1rD6;a3CE5e853hD7Ci237Fl3019o2963r2793u97Ey1313;a383Fe388Ag587l9BA;o128uE;d3w9;b444;c321d1;a16CAb41A8c3621d38e33BgD48l40B8m143En1281p278Bs5002t37F5;hC82;!d1EgF5s0;bD8t1E;e176i2CF4;!d0m1r2Fs0;!rABs0t1;d0e5g96m35Fn34A5p355;n2223;eD0i6y0;a1e15i6l2Cy0;!d0s0x1F;!bF7d0l22r1s0w5C8;v18E;t1zB;t31AD;i1Dn25t2F94;i133n7E;!l14;e1Do17E;!a28Ds0;!e3ADl7m165n22s0;!e4l37B3s0t4E1;!l26B4o1r32Cs0;e621;!a4Be327iADo12r7s0y0;g3416;a146h1B1A;s19F3;!a1h1As0;a195c63;!b1E3c35CBd3Ae4g69Fi8El4A4p5Fs0y0;i116;a6F8e1;u58E;n8r48A;iBo73u73;!e4i6l28n772p47s0y0;e99i21Bo1968;b37B;c2Cr482D;n4032;!e85Di43y0;!a7CBeAi6s0;l242E;f217At47;!s0u3D5;c1l1;!e67f37i68r12Dy0;i1Ds0;a80eAi6m32F6o11Ds280t2EB3;c7t4FD3;eBD;a22EfBFt2C03;n473;a2B41d2388i35FBk4D3El5000;a4017i161Do21EC;!n2AA;n2AA;c1eDl3;!a8e18CoDs0;a47E7e37DBi2A89l2778o4AF7r14DFs6EAt4Au33D5;!d0e142s0;v22B;n2s11t3;!e0l0r3CE2s0t9B9;a186CcC3Cd258e2C1AgB78h56l1A51m3nF0r3t38A8v4910w3DB4;a2B4E;gBl3Br3BtB7;t177u1D;n3s5Et2D;!aD7i62As0;r103t25C6;cEEe15Dr4E16;!eB8Fi19Bl44sECy0;!e15h44Ai6l2Cs952;a50e4i43l19y0;r2Av3;!bFBe4i21l130Fo6Es3852w3F2yBzDE;eEs11;!d55s0;!l1C9B;e20Bh172i13o1C55t38;rB7;a1f2DnF;!e1F8l7s0;e15i214o1;!e15i4638s0;c44A6l8r1AF6s85;a1261;b5Cc624f1BA4lBt1DEC;e21CE;e1Di31;c0n2t7;d3D92s148;a600e37E3i2C87o2638;!a35D0e1m4E5u3503;e90oC4;!a14E6e15i2904o2569s0;c47BDs0t13BD;n0r3;n3r0;!a39D0c56e3729h1C38i1F69k5D9l69Em2Eo49D6p90Es2C91t1375;!e1i211Ds0;!e94Ei6s0;d1k743mDEr357Ct4F68;a0i97o678;a792;a46B9e1Dr1u12;g164C;!a14d3ABl893s946t7B6;a4906e36DCh11B1i4FBFo25BEr11E2u4386w6BBy7B;e33FA;a667;i1612k5Fl748pBr3304s107E;e15i21o73;l11Bo45;d0x0;e23i21k89t1A2;e71Di43y0;e2E0i43y0;!h110;!s68Ct2D;a4C71eDBi34BEo31u4071y0;r40E2;!d8BeAD9iB0Ds0;!aF4e4;i13l9Fn469tF7C;!l48s0;c85l367Ar20F9;!e15An11A5s41EAt5B;b7Al96FnFs105;!p25B0s0;b856c22DCd18CCe3318f108l1C3Em1n3AC0p3230rE6As1CA4t28D4v395x2D8Ez1C87;!a1AADd379De1gC2i336Fn501Ao14E9s2E66t47F7u3EF5y62;!a12e4DCEuB9;n25t1;r25s11;!a1DeC8i3AFDu5;!i1C4As0;a50i19D7o412A;a4B7C;c4B70;cBt198B;!e90h3A46i3C10k1D39s0tC16u6C6;a2D1e5D;!c8B5kDElAB6r28s0t1EA;!r7s0t53;!b34B0c1E1e3E6g43E3i19Bm2En0r247s0y0;l7B;a4074i1C98oFBA;pB5;d4Bs0;l603o28;!n807s0;tEEy1E;l2957;nBs0;!a5e4s0y0;a80e35EDiC8o731;iAB;nBs3u5;t2AF9;e1m28;e10i2464p27C4tC0u3081;a1l4F3;i1553;u57y1CB6;a523i25;a3E;!i174Fl7;a784l266o1C5r3FB0;a3444i3424;h2A1i2CF;e7E3;!r12s0;!e4i6l19s0y0;a511De18Bi2EFCo13EBu2B0;e37FDiCBy0;t7BC;e471o10;!n15E2s0;a0t1;a1t0;!n3Br2F;r16s8;a1A14i25o24C0r12D9u79Cy52;!g4FC5s325t2E6;c185t3B;!e15h110iCAs0y0;!b21E5s0;c3CC;a1De38FCi3Du51y51;c19m244;e4i9A4l36A;!g2037h1i4549s0;e3Dm0t71;!c2B1fC3h110k47l22n33Ds0t0;b5AEi48F;y2BB;i2Bl19y0;a1c11e1i302;c32w16;a65i6C;h49CBo147r21E;h4487;c43B4h127k28o4FFs5F;e1807i86l48y0;!e31ECi2DA1o8Fr44D5s0;t157;a1800;c83x1F;!a4297e30i28Fs0u26B;d16k16p16;e1i87;e852;aD5i72;eC4rA7;!a309i109s0;!l1504o241s0;a3695e3111g3F32i3FF9l1o1366tCD9u2CA1;g7E;nBFD;i2893o74;!s18t1;!r1s0y0;d81C;!a4F13c26DEd436Ee4244h2A95i2AB5mD05n3o4661p4A13q4C42s2CA9t4EB9;e1l1A2p1;a126e0i2053o147Ey76;!d0s0t8D;a1Dc1209oE;r609;i13o255;a4621b2F5c11CEe2E1Dg1Ai937l45E4m21FEs3t2483;hE4A;!a28D7;!b1D2d0l7n39r0s3E;a24Ae645l3927;!e32F5i5F3s0;s1Ft1D;g44iDs1Ft2B08uB;m87;!d9Eg38s0;!e15i6l48s0;a4Ae18Ci6;!e4f37i27nD7s0y0;g4D65q303vBC;e5A6;t44A;!i38B3n3B04s0;!a42CDe172CfC3iBEo149Cy0;k0t1;l64Cy0;e33BB;cE5Do3EB;hBk2701;a74Ei14u14;a30d0r0s8;!f1Cn1s0u34;g4728;s9At3;tFEz78;d32A7;o4u5;!s0t18z1E;g19i12n4r27Ct3y16;!d425e4s0;!s0tC68;!o1626s0;c1n0;c0n1;e1F0i6;e140Ch23DFi4A45k3945o2308t2F16y0;e373i46B7y0;k1C40;e1h2C;c32sEz186;e4n1Et4A;g15E;aCo10;a3ACCeEA5i5112o3BDA;!t47;a51i31o34;h9E5o777;f1g3E25s8t21FvB;!a4De15i1E0s0;a73e1Do697;d4265m318;a54e25o94;g1DA9;l1180n18r75s1F;!e3BDBh2BiFD4k4B20m29o46B1q2F3Dr4B5Fs0t1B0Au4F04y0;l1E28n4AD7s8;!d0s947t8;i4n3s3;b74Be12i59Bl3855n4E3Fr6D7t4E2F;i38o8F4;!a1356b4F39g28EEh3E7l3C63o21s0w410;e4FDB;n2267;!a4DEDe1FDf37i46F2l22o4B50s0;!l2553s0t317D;!b4DBe6Er486Es1A6u6C2;i317C;o2F92;e147i507Do12r22u399F;aBAe51;dD2t3;i330D;!k53;!d1FCs0;l4485s2E0C;o3A2;!a1i0s0u5;kA7;!a80b6FBe15f14EiEC4l33A5m2A0o157Fp32Fr2C07s46EBw98y0;!nCC;nCC;l1ADr1t38D;e6DFo241;a2852e6B;!r34s0;i7Ay20;h897;eAg1C9Ei6;!e764i6s0;!c0n0s14;n2E7;e0oD;h398u803;!e1B47i325Co48F1p263t3034u4AEA;m64r195;a1AD9;!b64e4E56f5Fh3F0i6k4874l1BEAm2EpE2s3D09w21Ey2063;e1Bn1;!a1o87s0;a21A7u0;cF5d27;c2Ag0k3lC;c180r4C47;!c337Ff1D8l7m1E9n22s0t3403;i1C2o13F6y0;!e49F6i21s0w169;s3E04;a30eAiCBy0;!d3448r430s0;e4AE0i5Dk4E22s56t0u49;!b44F2e1Bh1D63i3Cl7n50Cs0;s48t7z48;aDo6B;o49A5;a10n22A;eBg63n5E;!g15Cs0t446;aCe292oD;m57t1;!d0p5Dr1s0;r7s5;e1r0t1;!cA5;d1s9A;i4BA4u5;!a1DF5s0t1CC3;o1576;c85;!lBF5s0t38B;!nF0s0;g19v22B;a4713b496i1D;s432t7;mB60;e21B;e38A1;a24E0e9;!d0r10Cs3E;h1C2l1866n4D0;a90i1874;eBnE0;e709hB;c1DE6e3156;u6A;!a32BBc17A5d4E0De3532f9FDg50E7i10k1C88l22o645s43DF;cC08;eAo29;c7l1r7t6F3;u90C;!e4i8Es0y0;c15D0g4EC5n1p19F1r240Bs2D60t47z19E;l41rD6;e1Do1470;i5B9;c1sFCt3z3;!e15h1i6s0;!l4043n0;c1F8Bd82m4FC3p1B94;i240Fy0;n16r1;!e11DDg24B8i1370n1DCAs0uB;a55Fi9;iC7l7Fo119;m16F;e31C;e2709;o1AF1;c486h542s1Ft20E5;!g27p4B6r28s4FB9;u3212;e1n0;a2C2eFE2;dB68;a4626c164e6Er64;gF7;a1C30d1Ae47B8i27C3o0r2B;d88i161;r286;!a43Ab9Ee15i6AFm16En460o73s0;aF7FiA93l2B1oD58r924u4779;e42i4E4Co73y0;p21Fr1A5;!c4BFFr307As1460t729x117;!h220Cs4D8t2883;iBBo8F;a15A9u4F;l5A5;y3B8A;!p1E;!e4iCBs0y0;!a43Ab3D4e4523i21s0;h35o13C3;n8r39;!i34;a0d217u14;z9A9;a4AF6c39A5d2E3g1146i350m50CEo3904p44s271Dt3C5Bu351Av27E1w2CC0y8F;p2370;!d0n1o9r1s0;f39D4;n492;a1c13Be224;!aC20i4DF3k5Fm127n89o5034p177As0u4C89;!a4Fd373Fe393Bi121Es0;!i684s0y0;a57e10EAiEm163A;a3898b9Ec457Cd8DEe2972g1ABDi2DE2k83nCC5oDECs4888t7F0u48CFx1Fy4034;f31Bi6E6k44r2507s1Ft4AD8;d5De67;n4A5;a25oDF;c551;dBn88;c0sFCt7z3;a426De4515i21B5oF44r1C2;m52t7E;!b2EAs0;!r49F3;v2E6E;b1c1C8Co2A3Es440t1E5;s2E0D;r4C5C;lD2;d8Bf16;a2E03e154i2923o1915;a12e8p8;a2C5dB0o6Er3Du7E8v7Cw9;c37B2e1n2t3D;t4C4C;e1o2216;!d58s0;n79Er1;e4o6B;e2CD;a31Fe12;h4AB;!e4i6s0t148;!l16;gBi1D;b1CBsAFt0;a1F14o0;h2E95;u57w327C;b7Ag213n1A0;a95Ce3D;!aD1s0y0;a1822d313Ee13DAh4662i1DD2l23E4o1A19r36DAu19A2w5D8y195B;!i2C3s0;a149m2Cr3350;!a4Dd1e15i21s156t25E;eDD0yC4;t592;!sCD;e38C;e0p0;a87h4582i4C0Ak1CB3l3B57o2439r4D91u13B7;a1De42o1;b13Cd0e14n124Dr1;!a12d9Eo12s0;!e4m1s0y0;e35i2B2Ay0;!d0r1s0t20;sEt1;!g11BFs0;e4i6E2lB7;e56Bo1A4;e1i25C5;!m47Dr24A8t255E;a10e1B40i6;l5s4F8t2D;!e4580i16Bo4A3u2D4;!e4i6k1FCoE7s0u34;a25Fe15i6;!e24i6v3AE7y0;!a15Fs0;a2FF7c24D7d3B80e4D34f33ACg2005iEF2k1C13l2E2Cm402Bn1818o3052p32AFq2411r497Bs3BE1t3BC9u48B7w15C0x335C;d3Br2F;!a380Dn4ECo91Ft3409;r2915;!e5h1CCAs2Bt4BA5;e1i13u14;r341D;a24F5e3E21i44A7o4620u37B0;!h1r58s0t1B5F;a1e15i21;i73l5F;!c7h3Ak1AA3o1s0t270;a30t2E1;!i31o46s0;e5i4D7;m9D7;e56D;!e1iB8l20CBs0v4AEE;d5Bi70nA9ErE0y0;d0f37;g1m27n544;i1326;a104d1l8r40;a0e5i13o27D;a30E5e17i953oF;!a20e31i13oC;a20e1o272;!i1DoEs0;!l7n0;a10t4B46;!d97Fn758r900s0;e3625;o569;e3EE7i6l2C;a76i13u14;i30o6D9yC7;!e0r1t3;!a116e8Fo46u14;d1D6gBr151t215;eAh1181i6;eB45t746;a1DCnF;!e2BCAi41F3s0y0;!d0l6Dr7s0;!c4F8Ff1287h752l206n0p47r3DB9s34B6t3CFEv2B;aC55;!a340e15i373An4D71s0;!e15i6n0s0;d0n16Ar16t0;cDC;e5s1F5u14z3;t342B;u2E3C;a133r32C;e6AE;aFDDoEFyC;!a1E40c46ADe38A0i210Ck0l4166oB8p8C2s0t3553u33DEv446C;b7Ae1lBn2oA08t12C9v3;!s0u3;u3E58;a200;!a441Ae110Fi27EEo1s0u4F;h3153o128;!a25;c5F6;a4FEf2436n17F1o46u3670;!e25D4s0;a784f4D6Cm1Ao62Bp3524r2DAA;cB1tFFz9BD;a23D;c16A1d4C7g44k1n2497o1AAFs56t21F5;a4316e168Ai3910o19CBu2475y623;f2Dl3;e176i19BD;!e4259i2B1Co2D5Es0;d4D76r1t4CA4;!a0e4A42i21l2Cs0y0;eAi33AB;!eAh41i6;a3A9Dc30Ae43C3i2684l4C88m4BE8o3B7FrEFEt4B65u331Cw1Ay2E3A;!a2317s0;a4F4Ai92Cu5;!d0l446An0r1s3E;!e209i250l7s0;!a1e4l7s0;f108i10l3Bn1ECs20;a30e2CA0i12FEu3D;!a6Be3;!t1x98A;i154C;a3FC5e2274;aE0Fb18BAe1CA9i4EF1mB83n2950o1533p3C64u30Ey0;i4r0s31A3u5;l4C9D;b46c1Eg4C14m28C;e3BBD;!l7s0t1E;a4Ce17AAi473Bk121o9Bs3D3t10Cy0;r8Ds3u1CC;oB41;!i113;!n216;b41;!a12DCe4i6s0;!aA3e1i56o20F0u3F9w11E;n28p28s9C;!a22FFb476Ee1AC2i3CEAl246Fm2Eo23A5r1975s0;g4An170;!a9D0b495Fe15f37g636i21l75m63r247s2593t46D;!e4iBEl257s0y0;a57i57;e1i9;!e33F0h40Bi21s0;!eEt27;d3C8Cp955t984;!n23CA;a3188b230Bc367Bd2623e4FDFf17E2g1A54l4DCAm3BE2n37ADoF66p4824r43C5s2ACDt2331v2E72x12C2z3474;e33CEi6;a36e33DFo1Cy1C;e17o99;a702e9o51;e3C2nF;a9l37D2n34Br1Ds4Ct4ED;!e5C7l7m8En22p3410;!a76d289Di38F3m118n2293s1FFt1A1A;a34iBy0;!l1C9n2B92t29;!lF3m159Fp182s0;!e1DADiBEt1y0;l62Dr2649t0;k0l33E;a1e1452i1A32o12r63;!i69t27;e500o31Du172;e4i2031u32;n365B;g1k28q4A3B;a2131c39C3e1202s475;l378r10CFxAF;iBACy0;c35DEd3273g2F86l2682m12ADo45p1CD3r4D7Fs3F6FtCDCz3BA;o39;a150Fr3BE;a2AD8e54o8B;aCi634o46u5y0;h4FAiF;e1128i21;e25l1;a35F1e14DBi323Bo208;o13;!b38d36ACe7f103Bg15B4i8El13E8n38E3p2BABr2C0s114B;!l0s0t2D;cB57e1g1i1172n2;n22Bo1;e1Bl7n22s13Bt493;e9h1F;e25B2;e18i18;i13r18;rBx1F;!aCe33i1o1;!e4h4761i6s0;u2B6E;g96k48t0v19;!a4022c20A0e454Ah44A2i31k13ECn439Ao195Fq2EFr3987s0t1733u1D;!h5D5s0wEDy0;eD3iEDDu41D1;!a3E2Fe38AiA4Bl7o13BFu400;a4315r3;!a4Ce17Ai31m2Es0w7Fy0;c4417n1252;eAi5;e24i5;!b14Ee586f37iCAl22o4Fs0y0;a43A2iFFo23Du24D;a26A6b47e1;a4430r18u34;b7Ad3BfC9;a9i13o9;s56;!i399l1CAs0;s8t3v3;a44CEi34F4o364Cu5;e76B;a1n3;h408AlE2o3407r7DD;e1301;h3Bm0;!a2765e586i26F9o1F92rC06s0u2F3C;a4E4e3B15i2E9o6E;o5Fu4E0;n1C6t1;!e4i692lB3r25s0u30v27;a473Fd0;a3843y5C;o39C;!a4Be67i43y0;!e4i214s0;a3D7Be5150iFA8o50BAu17CAy1705;s2D8;l1467n1BBAr860t131z2C;g49AA;!n7D2s0;!i4392s0;n35B9;e5i13s0;l9Er85t0;c951d41ED;i36n5A;nD1p4930;e1Bl7n18Fs35;l1E4Bt1C;!a4De15i21m2Es0;b1Co24Dr1;!p469Cs0;d2E60e4Fg37ClD3o36B;c0d1l9Fs4C0F;l58r424A;e51o8u1C;e15iADl175;m2E25;g11D;sEt7;l157oEpA5;l94;d1Em1Er1E;e1o4BA6rA7;a50u59x66;!c7C6e23g3B85iBEn23Cs0y574;!iEmCFn1r36s0;t118;!e159i6m2EsEC;r34B;!eAi6s0y0;m1n1u5;o36y31;k6A;r0u1CC;a4064e4325h3AC7iBEkD43oErB26t4C3DyB11;a4157e710f0h17Di2AF4l2E1Am1AC6o28E4t31EAv23EB;s2E34;!a39Be34CDi21r18E2;b46f16n16;b196;a1790eEiFECy0;!a76t854;!a80e4i6l22sECw33Ay0;m143;k3mB7;aD70e10;h30D7t1300;n16r16;!b1Cc58i9l44F0s0w1y1A;f198v2C46;a265;t443;u1D81;a2B24e3DE7i2C2o1D5;i34r48s32E;n0r2As5;d3n3;r10u2BE;d439p2FBs224Dz9C0;i2AD7;!eAF8i21l75s0w134y0;c167e67;sB1y0;e46A0i6;a1895c6BEd703e142gAFDi61k0n1709s47A9w0y1;c7s7t1;m1498;e1h27;!e0l75s593;a1661b25B4c4CA2d49BCe3C00f480Dg277Dh347Di4575j12C6k27ACl2010m1189n2262o15F6p2219rFA2sBAFtF30u223Fv4845w130Bx1593y1;!a12;l3EA;!e200A;r2As3;a8uC;e12r1A;bABBc3E6Ed44FAe1gE33h0i3C67m1821nF71r43CFs2C35t35B5uB3Dw410y1z17FE;!n0r0;a1e329Bf0i174B;!e1w134;g11Dn47;e4i548lF5oC6s0y0;y109;l60r16;!e4h130i91s0y0;!iB8n2368s0;t2EB6;a9c0d3t3u14;c19d1E;r36t0;!t71;e1Bl7n2s36;!a4D52b21B1d3D35e2903iC1FlFFFm205An1C73o2F71p169Fr405As3265tFEy0;eD0i19By0;i180Dy0;nFC8;!e3E9h1i30Bl2A8p1A4s0y0;aDAe4F8Bi4Fo5E;l261m3s116u36;e33m0t0;!lBs1C7;a1cD3g8FAl295Fn2FC1p38s1B80;!m1BDAp229s0;!b2EA0e15fB0h305iAA2l3AF8pE2s4865w8C9y0;!a40i13o29s0;pBsBCt336;a4A8Eo187C;t4D69;!o29s0t20;d8Al63;a3BC8b2B21e0l2AB7m3F91p3BA7r5043t22F0u1;h443;m2C15s1627t348A;!l39s0t1;!c2Am3760n295s22BCxE;a34E9l43EE;c0e1s8;!a3C38c17EDe514Ef38F9gAF5h500Ci5080l40DFo95r39E3s0t158Eu34A4w33Ay0z3FD4;c0e5s8;!a3B39e1774h1D2Ci379o5031p7Cs0y294B;e359t1;a0n52s14;e25CE;!aCd4BABe3DAh2769i4E7DoD7s0w3F2y0;!a1D08e319Bh1i152s0y0;!eAi43s0;!a43Ae12f37i68l22s0y0;eF0i6;f46n1BDp162Fr323;!aCe144i13s0;e4i4683y0;d4385;!d7Fi6s0;eFE;a2F2Cm1;!c1DCCd2ABe26C0i0k5l2A2m2En4E5Fs0t1;c32lFE;a2C9Fe172;c1s153z3;n2A1BrEs1F1;!d0l6Dn3EB3s0;gCA6;cB51i5o1C5t38E0;p18;s737;g1Ak1E45;u360;!e24Ci299;i4FB2u147;b33E8;d1nF;u166v63w11D;!a80e14A5i6n0s0;l1CD;a4B35eF22i33A7o4F9Es0u465F;aEFeAD6r45A8uC6;y2D6;!b18EFl7n22;r249t25EA;e1g1i3F;a2F43e173Ai68u5Cy0;c68Ai32l2108r117Bs226tA60;l41DDs5Et46A6;h32A5k29B9;t0v3;r4232;aC5Au575;!e24i21s7C;e13F;b1B38c43A1d10CBeC2CgDE3l15DBm26C8n4431r115AsE8Bt183Dz2631;!i65Cs0;!r7Bs0;aB9i49Do6A8;o4170;aBA8d58e4AgED4j5As0t2164zCD;n3t1;!e4i3B49k1EE5o211As0y0;o3D;!e1404;c208Fd4E90eAg28h2ADi7CDk1n506Ez2B53;!iEs0;e84uDD;!d0i6r1s0;e597i86y0;a4F5;r12D2;i38s2A00;!a4DeD0iADm9DFo12Fr247sB14w2B1y0;!a4Dn8r16s0;a4105e731o2529r8C7u1FFC;e2C2Ei6r6DC;n8t0;i25n8D;b2D4Ef10A7m2D15n376Dp1DDt4F26z2C;l44r2A29;!a3461d4F27e0g270Ai3A0ClD84m4663n22;c0e1u14;g622m1722nEp404AsDADt2BBF;n36B2;a4E78b1BBCd33E7e11FCi4E81k3859l114Am2309n50Co24CDp142Er4DB8s3B06t92u29D4v56C;c0d1e5s3z3;a2DC4l1n2186rBAs3E3t19CF;fBFu5;t127;p2D5D;a44CAd0m28D6r1284w0;a3293d2326e4A89i21l2C;r3t1;!i109l7;!c163Fe1A95i21l22m1E4o1D2Bs78t4075u1FC1;a59e17i6y0;e202o21;a162i1647;iB9r34C3u495z2DE;!h110iA5Al7n22o1FBs0;!e128f37l22s0;c0n361;!a401Fc255Ad1e202g44i10D5k17B2l2D7Am218nC9AoA50p1D28q768r140s0t480By0;a9B7e1CC9h2561i1A49l40BDr3DCBu50B2;!s0t2DD8;d0n516r1x0;a149FcE11d22E0e41C0f1475g1iE72lAB4m2ED0n49A0s15DDt2967;!e2677i26El7n22o23F1s0;a4FcF6r677;b1EA5d3Af577k1t3;dBe5nB;!g3298i6n35CDo4r45DCu2DED;e762i6;b16e185Ci6F4s247Dt16y0;a1i27y0;i3EB;a1Dr2E13;!c594i27ABoA08;a3BEDe27l175F;!o6FuCF;!d0s0t20;!e0i20;e0i20;l2A1m57E;!e36i2B6l7;l27oA6;!e1074i21p323;pC60;c7AD;!a188d0s0u5;a221d148Ei11Cn68Ao2961p304s330At2DF0uBEBvFFw2FB2y1;s500t7;m107;a6CeC;i480;!s0t2C;c0n0s3z3;m15CDs440tB7z3CB;aDe1i13u5;m18u5;!i27t8Dy0;!e15i70Ds0y0;e1468i4DE4;r4F7DuD;!c226d867e4i341l26C9n4EBCp28r4317s52t24B1;!a21Bs0;i20D6y0;m253En3517t4045;e1384i6;i27l633r7;r595;e1Bn2t389;!a30A6b58e4F2i4985o32BEr1236s0tC0Fu3D37;!c34BBe1h0k192D;b187c13CDl5099m2362r4EBt79Fu3932;c8r39tB;kC51;s52t6A;g15Ci25m45Fs1AE;e6Eo10;d0r2Fs8;eAi6t39;!l4m2D3n1Er9w98;a7Ei0u5;r3s0;!r3s0;d38g44k5t2152;v9EB;e2EAAu5;c3DsE;!i4199s0;e15Dl7nF;i198o74;a20c62Dd0e1i0o26Ct1u5;i109o46;c269g269s267A;a1e265Bi20FAoF6;a80e40C6i21y0;c8r1;d0r16A;z364B;o2E88;aCc0f7o9sFCz3;t48D;!r7s0y0;c3Dx1F;e3054o57;!e3s0v18;e36Ei3C;a500e3072o47EFr606yC4;!a73s0;a4Do29t10F2;h28BF;!d1fB74i1550k4E5Am4368n1p3A5Ds1FF6t1D9E;a0o29;a3539;!e35s0;!a72cA5i6;cEi10m19;!r7s1096;a17ECiA51o227DyC;tB59;!d0f1D8l22r1s0;a49mA8B;e40i4B8B;a54Cl1FCD;i40D3;e581i6;r9DF;!s1Ft1;e4uD;a202Eb184Ce4960h1682i3685n2B12o409Bp848r14A2u14E1yFABz2F69;e90i0;c2Ae5n2;c19Dt18;o6F0;o4929;a61d0l1Dr23CD;a2E8De37BEo2EEu51A;o36s3u5;a170Bc334Ce17DCh2675i1710n1At1824u34ACw157y124B;i38B2y0;l4783;c2DC7r331Eu5;c23E9g770n86Br941sCC2t71B;n195r63s467;e83Di29By44D0;!b506Cn1DEs0;!e4i43l7s0y0;a4F73b3C8c3F2e4000i2D0FoA6sD0Ft42DEu46B;lA53m1s28FFt2E1;h2D4A;l4A6FsEt4ECD;mB3D;mB60sC0t2D;!i4B9oCs0;e5n2s11t3;!e836s0;u3071;a36e12rD2;!d2E4e2D04g49E3l160s0;a2DeBy1D;b4360;a9e4AEi21n0t3058;d1Ce0;e142i21;o45CA;!n22CDr1482s0;e1Bf3AC8n2;o2BF;!c7CA;f7nFt7;e15Bi8;!b4C;k5An2;d0t40;!lD80q768s0;!e106h42D2i6s0t49C4;e2256i13;a4BeD0i43y0;tB95;c316Bg444Di1508k317Ft2CE;n33FCr1Ay1;!d35D5e4DD0g291EiB03s0u45E;h4004;!e2795i6y0;!a0eDl7;d0n1A3r16;!a4Be15i316l225m2Es0w7Fy0;a31BBe536o1;!s0t7C;a1986e450Fi3A0Bo1F3Fu4FAAy2C38;iB7D;n3CFDr46CF;r8B0sBt4A;m662;aA81e1i9B4r8At26AAu310;e83z1CE6;m5An2;!a4176b691d4E43e17CBi6l329s0t11;!i27s0y0;!e8C;o32Bu32B;a4A3e2EEo36D;c45CCw3C1;a19A5eEi1D3Ey62;l11D8n170t2B;e386E;!c48n14Dy16;e5t3;o5E;a25A3e4B25h306k40BFo1r4A5DtBC;i11E3m7u3E1;e12DFi3C;a261b7AcD3d26BFl1m973r3ABC;!i296Ek1l2A2m417CsA1t2B7Aw1A8;e2240;r334;a20l1;n0r8D;o179CrD31uC3B;eDoD;a4Bd1A2i6D4s0t798;!e4CA3i27s0y0;!e2036l1D86o1BC1p10DDs1FFt4991w263y0;e42C9i4Du437;n122;!e1Bi508Dl7n22;i6t16;c5De5;g187h4F0D;g0i1;i9u14;e239i21;n1139p46AF;!e4i6l7Bs0;m56;!m56;a1842i27D3o35;!a1DCd0f37s0t16;m119;b2F1Bc8A8d5060e29A0m3DEFn4669p3A6Ds155EtA60;!a4Be15i6n0s0;e6Er1EB7;aCn2s1F5z3;rE0;!bE0e4i43s0y0;!e635i6s0;!aB22e48B6i1F26s0u1D3D;a36FeC1i101Eo1u1782y2F3E;b7An717;o69;a4207o26A;!c11s0t27;m118u4F;!d18Ai1k7C7t0;!e25CFi68o3DCs0y0;i1099oE2D;!l3732;n16o9;!hEDl259;c85n2o1t1BA;f164n32;c25Ei10;r38D;!a2991e1C1Ci22DBm180n2177o1A3FyF03;!i279l7s0;d0n16r0s8;k1985;d3De4;aCe1tDDu9F;e18iE;h1A1;l18o4;c0m0;d2A5f794iE2Cl13Cp355s440t1Ev1Ey182;!a3F4Bi24B2o2B19rDBA;!eD0f37i91s0t0y0;l4951o489D;d3380;a28ABb102c43E9d11Be3AA6f4C9Bg928i3057k405Bl20ABm4FFBn1CE2p3944r375Et440Dv44F9;a3B4;r1D82;h7i13;!p1BEEs608;a31A1d36F3i271Bl3o7B9;b1B7;k63E;a1f510;rFE;d1AD4i64;z98;!i29Fl1Es0;!c1990f8l3C7m1CF9n8B7s1697t1B6Ax11F;l458r31FC;!c13Bs0;i4D3;!d0eDr7s0;k1t1;a173e67f37l22;e18C3i170;k3A4;!e4iBEs0y0;aCi3F;c3D23g3780n28p88s928t3652v3580;e4E71i86;m44Ap10C;!a2EF3b4668e15f11DBi21l2454mC7Ar247s4D82t16Ew238;!e29FCi6s0;!aABEcAC9o4BA;!a4De15f37i21l5F0s1CD6;c7t42E;aEe8Ch296Ci4C6Du84Ey0;aCEr4A;t201x66;a138Ae4A58i452Al7Bo46t681y0;d3r8;!e304Cg4E4Eh2F6i21s3383w535;!e15f37i194Bs0y0;m88n2C06;y2FCA;b1Cp1;e2059i5A7;e53;c3d1s3;f0t1;oA7D;!i56uB9;!e4FF8i4B48l55o713r7s0;i8l3;n164;b102;aE67e0i4A76o51Cu2C2;i31r25;aCt389;n89oE;i2096;eAi3D;c1Ce12;!e1i6s0;s483;a125Fi4o3A36r4294u49w1E3;e5nFs11;i338Cu5;b3848c1A18d3B4Ee1F11f612g1928h4613i11A0j1B85k37ACl138Cm3D10n2B68q4666r2CABs1849t1A96u1A50v17E6w2B1ExAFy3854z2B02;r0s80A;iB9F;!hA04k4C;!a2403b187e44C3i190AoEF3s0y0;!a942i1s0v4D5A;a4B37;!cB1d1A2k4766l1m140s11A;e2341h1i2504y0;e1i10;e5i1F4;t1CE1;!e8Cs13D;e33oDy0;c29EnB;!d0g2Ch1l22n8s0t0u15A;e4D29;t58C;rE2;a723c58e28A8h455k4A5Co4A75u3783yA55;e5BE;b43F4e29ECiCF0o422;!e4i6l37Dm1s0;a20e6D;!g27Ep631;a658e1i34;a7C1;c0m18D;!e15g48i6s0;!k37Bs0;a29D6e1u34;r23B;aAEe12;a4B8;a3B18l1297o1C02p13E0w5051;t38B;uB6;d0e0s3;!e4i2DFs0u14y0;r21B;e4i6u1C;c3Di170;dA58nFsE;r690;m88;dBt1;!d1F45eAD9iB0Ds0;dA52;tBBD;u252;a1F2;d519l1EE2;f696;a291n2r1;!o10s2ACFz19;a30e23iCBy0;rB36;b5;aCo12;!u34;u605;!e1F8iBl7s454;b2F;sB9Cu5;t0x0;l1u32;a87Be159i2DFl2Cu172y0;!e31E5i210o157Cu3D9Cy310;a3C94e3EFDi1628l5069o2B5Er484Au465D;g14m0;e118F;k8AtF9B;i181o241;aCe5iC;s231;eAiF9o8C;e1iACo46;i2Bo1EDy0;eDi345E;h1l3;h3E;eAi5A7;!h3E;!a17D1b2169c485Ed3742e17BCg1899i1CC0k5Fl199m1CE9n3D8Co4B9Fp43E2r404Cs3814tCA7u6C2w7FB;a2AA6o46;d1DF1n149t2C;y2444;l3t1A3D;!a3F70b293e15h5Ai4735l7Bm2Es2F26w3AC1y3B2;b40Ac4EDe42Cs3BAF;!a1CC5e2B5Di4940o295Ap31BAr1E4s2789tB01;aA6;e3B9Ei6uA49;v49D9;n2D1;dE5;n2s14t0;!iDCn2Bs0yDC;!a3AE4e23h0i1D7Bs0t1A5Ey0;!s5Et2D;e7i8Ey0;!e7i8Ey0;e6F6h60i865y0;c1Ce23n2s11;!aDe1FDiCBDo29s0u1D;!d21B8e23i21;!l0t40;e1FEEi51y0;a126e63o338D;g0n297;o88B;!a4Dd0l16Dn595r1s0w511C;c46C1;a143;i4o46;!e0l3201s0;a188e5;!cDBd3565f50A9g2Ci16BBl5DFp20Er1As1F18w410;e0i4;n866;!e4f19s0t87A;n39CFr63x120;!d18C4l7Br58s13D;aB8i1Dl2D4m2B0r35AEs85u17B0y0;iBE0;n35Bt414A;m2A17t55A;a3214e2150i3888lE86o443Cr1EBAu2D81w489Ey4CE1;e49E7i168E;k3An1FCB;i99;e8EC;lE34o1046u1892;n8B;!e12s0y0;e39Fo26A8;!d342s0;o6Fu3202;!o28s0;a119Eo147;d0e10n16r2F;l103n3756;m4262n82;aDE7g63;!e166Fi6m2Es0;m775p514A;a2F2e712i25B3y0;g19n1;!i1p2C2Fs4134t3B63uF1;!e239i9A4r77s0;!a3D8Db4120c64Ae0f8g1721m17D5n45CFp38FEr45A2s0u4B9Cv5Fw1A5Bx23F2;eAi13oD;e94E;d3FFr1z3CB;a4189i475E;c32n8D;l153En1;!e15i43o9Bs0y0;a2376e1i0o1;t2EAB;a1BBh6DyC7;d3055;m9En1A;aCt1AD;a4FC0e350i38;eA6oA6;f0p1;iACo12;t1DD;!b10Ad0fBFl620r1076s35By1;d2CmAB2p5As493v285;!e2470tFB;!e7s0;d0m1;o6Fp5D;!e15i6l3330s0;d1D20e2741;g0i0oE7u5;!p2F6s0;a4B49e25BCi1567;a379e126o44F4u2CA;!d8Be4i145Dl2A8s0;d172;r331;!e4B7s0;a1081e7DEr2375u3398;!m2Et353;i1o1750;!e1F7i6s0;n8D2;a1B17o44B6;a10l463;b7At112;!i31o1s0t19;e4462iBEy0;t12B;tEB;!tEB;aCd3e1s0;h127r30E7s6DB;!a0bDDEc1AEe15fF4Eh3908i68l39C9m165p236Cr367s494Ct300Cw7DAy0;a59eA1oB;c2Bl1Cn2x0;d1A3;!i1At0;!s0t143;!b1d0s0;a4A4Ee1E1i3E79o3D3uB8y2B0;a78De18F9;d0n1r7s0;cCDi2405t616y0;!a20e15i48E6o3CDs0;a2519c2383e4082i301Em75n26E8o148Cr4253t2EA6u2AEFvD1D;l40E0;s2Cz2C;!e4iCBl44s0y0;!a50e9C1s0;!e2E4EiCBs0y0;i77o29;!e4524s0;!e5Bh60i2Bs0v3Ay0;d998gC99r14ECt3C26;!eAi6s0t3252;!a1s0t2E4u20C0;!b1Cj6Dm1Es0;!e0n489s0t19;u2BA4;!e67i4CD;z132;e507Fi4011;!k1l2Ds0;c2AdB;k791;!a5As0u1;!s0v7;!k27s0;e34BD;a1C48c20B2h1Fl11F8m23BFo109CsD16t156E;bB4l20EEn2835rB5A;d0n1r1t16y0;c1F16;!a43BCb153De3233i2BD6m384Fp188Cs0;!a80b3D4e15h9FFi1E0m2Es325;a2D1;u1A46;e321E;!l2Cs0;aA3e4i45A1l44;a36eBiBo19E9;h347k4CDDo2E70;aDu5;a3Ce457Ai3D4EoBBA;u18D;a4052e1F33i6o1C72p4909u3ED9y0;!i31s1F;dA58fC6Fp1BDs378;hF6;aCe5n2s8;b3B6Fc1B7Fe24f4A07g24B9l4C31m148An17EBp35F9r3C2Fs3C3t46D7v219;!i9s0t1;!jFBpAAs608;d185m16As0;n3p1Es11;n54Dp3F06r414s2ECxC0;a0x0;e1Bk3l7nF;i62Bo28A;n2rE8;o52;a2163e559i3D9DoE32;!i0n8;c0g18;b172r23BEs8;e23i6oEF;n38r40CF;r1C5;e9F6i20o29;m2FBsC0t2D;!h46EF;cEB;i60Ft107;d4Es0;n289;aCi1DACo1;d4Bi210y3D;e251A;!iBs0t1;e3D1i40C4l2Cy0;b4C41;eAi4227y0;g25;!f38n2s0;a73B;!hDA3s0u2BA;a3B6eAi6E0o29u34;r503As1F;!a4A3t1D9;!cB1s0t21A6w238;n2t32B6;i2D42o29y5C3;l48n2t3D;a5FAoF;r48C;aCs3t7z3;b2B29c2158d1F96eD4l1EEr1s358x3558;a1e1g1o46;iA7Fl7Bn5EDo29r4732t25CA;o9r1;h3F9i9BC;!a4Db3D4c9Ee365g15Ci21lE2m2Er247s2148;l1BA7;aE06b2859cE49d2944e37BBf36E8g3A26hC8i1AD2k27B9l2FD8m479En219Ao4D5Dp4C33r5039s468Ct36EFu256Ev2C05w2C1y4F61z171E;h28B3;r2D70;a1e56Do980;g366l1B61;!a4926e23i21o10;a4F09e43EAi21;o6Fs0t2D;e1i15F;a4CCFe1oEF;a40u34;e3BiAC;!bFBc2612d347eD0i1CCCkF3o15Ap20As312Dt1EA;c32k1n1;n4BtB;rA44;!a61o108s0v1F1;n48EBs105;!a1DCe1l5CnF37s0t1;s8BwA1;!f23Cm1n361s44B7tA9C;!d0f37m2Er1s0;!a38CEe3CD8i4FCEl1D5Do4E99r3E36s0u4239;c0d3n52t3;c0d3n3t3;u6D;a173e1i0u5;!d0n16r1s0;i3Co74;a15CBe23i6;r46A;!a481i5Dk27s0;c751l2CA7;aA3iB9;a188d5Di2812o29;a37D8e4F8Dh3Ai13B6l3BE9o2C4Au2830y3420;eBi37Ft1DB4;n4r3y1;i1D3p5Bu3DB8;!e24Ci133;p1r0;!lAAs0;b47B;!lE1Cn22s0;!eD0i21s0;!d0i4CCsA27;!e4i6s0t16;a1355b5CCc31B3d3E41e10A2f2D6Bh665iB5k5075l956m3C95n3167p1A77s4A2Et1v1165w1148y1;!a4Dc184e10Bi21l7n22s0w169;!i4D3s0;n143;c3An2o10;aEAFd4A5i13o3A5;c39F0g3093;!e3870l1s0;c425;y80C;n0r1A69;d25A9;mE4;m9;nFu4C2;!b4644eFDf42BAg24Ei4139l620p32Fs0t1EAw21CAy0;i393o29y0;!b1D69e15i21n0r1As0;!b1Cc7m119s0tEFD;aD17d3C96e1781g3C32i4C48n89o1BADt4802u1601v615;a31o31;eAm1t1;!e6ECfB0l4B4n22;e24t1BF;n47r204Ct396u12;!b2463e4C36i3F1r87Es0u25FA;b1015c40CAd0fFF4g4DFCi38E2kBm5128n18BBp3668sD1t1CFu11E1v3w10FFy1DA8z89;l63r2D3;a490E;u418;b1Cg15C;!h2FADo1AA9s0;g312FnF;p102;k4Cn2s11t53F;!e460Di136Cs0y0;d20D8n1237;!e104o1F49;e3Fq300D;!a40e67i6s0;g1wAB;f1v19;oB48y3A2;!a100e23i4F87;a4DeDo47B6r854;!a87i2D17o4C18s0u50F;!a1603i799l22o25BAp1A52s27EC;!bAAk1l1AoE9s1F;l50DEs0;s11t58;e4i26E;h252D;k8D2;p4E0EsA39;a189D;e0o8B1;c637;!e1F8i3Cl7s0;!a3AC6e294f4A7h1BFi1931l19DDm4F16o1359p134Cs4639;y4B;a1e1i3F;a30b2F8Bc366Ce67kF3m2A79n49FCo39D9p3DC1s17CDt383B;c18s2A;a1e424Di24B5l4260o1r3A79u1A;a39C;l444;lF1r1;!e4i7D3s0;e1o12;d2B7t0;e4i194l4F57y0;!a4Be209i250l7s0t0y0;gDDl0;c92h334s7;a503o14;!e4i481Cs0y0;e20D0i6;iCD;uEE6;c2Ay0;!d38eD0i21s0t2E85;!e4i68l22n1s0y0;c32p1w16;b1r423EsAA9;e3595iCAo6Fy0;o30y31;r63u4ED3;!a4Be39E0f37i28DFl6Ds0y0;!a1EFFc3AF7d44BEe4A9Ag1650hA9i2AACk10EBn2C4o463Cs327Et4DC0y0;u310;!e431i24A9l22sEC;c134g27C0t53C;r189;a10c35n6C;!g2E4Fj445oEs8A4;!c32r0;!d0l1C4s0;!a10b3C7e4f385i21o10D8s0;n22Ar1EB2;b3B13;e22Fi6l1E;!e1t4E3w1;!r2BDs0;!e35FDg3566i6o2781s0t37C;i2A25;t405;a20e1D;c3E2CpFD7x1F;p26F5;!a25Cd0o29s0;a3436e29A6;a1D5F;m1ED2;!d0e308i6E8kA4s153Ft2509;a4FC9;iE30o0;!a4222c13Eg2359l13Fm2Es2AEvDAw28;l945;a1Dc3B4e24k38l121m64s3CC4t4CA9;!b1324c4Ae0;a3DC2g3C04;rBs36;h1At1;b3E0Ce223h11Em4790p1F97;r872;!a12g1CAs0;!p4F;!d0e142l7n22r0s3E;a0e0i13;t1592;!a591b337e12i17Bl7n22;eAE0i9F3r12B2y0;h3A;d1AsD1t37E8;a4DAl4;aA19;!d0i6k1374l131nADCo42p2907r4EE6s398Et4602v1F76w4B7B;oFE;d1r1;a1D7Cb2C12c4EF6d17D8e2F8Dg3E3Ai49CEk37C3l3F1Cm1A9Cn406Bo25DDp1CB4q35BBr15D3s4D5Ct179Fu206Cv2C89w2633y31C3z7F5;!e2FD5i1923s0;b55i25mBp22E4;!m4As0v1;y97F;a153Ae1826i6o4FF;!d0r10s0;h603;eAl1;b1B6e5o1E9D;!e9s0y0;!l7y6C;s79B;!l303s0;h1y0;d0g1t143;t6A7;!b1ABd4450f37l1m2Es455BtEB;h1AC;a40n3;a282;d16l0r331sAFA;a8e9y0;eAh509i6;o4C23;!a2474i4D7o46s0;!a1F35e106h28i2374l38o30F3s0t2A22u1;h3C8l1E8Bo205;a1Db2Cm34F3n419Fp402Cr1982t1D50v2C;n47D0;b13D1c340d1BF0i392l1F08m30D6n11Br3876s2E8t1496w19AD;!c9CeAi6s0t2C9A;d23CEn1;i370C;r24D;!a4De15i21l22o673s0y0;e85i2By0;a63Ae35;!a1d1F8Fe1C6Fi6E8n2728pDEs11At130;aE6i111;eAhFAi6;a51o65;eDn2o9v3;d78l3Bp1Es35v19;aFB9i25l175o2303u2BA;i571;e6EiE0Eo80r3B86;rF12t399;z613;c15FCd2DD9f5073g3CD7n1062o4CF6r3DACs48AEt21F;d0h0r4E08sE;a376e1;t1B6C;l445;!a253b4DBl22s0;j0m3;r3DD0v186;e3E6i194y0;!a2B09b3015cDBo1A1Fs3460t37Cw246E;eA99;w3BB;fEw9;!l800s0;rAE4;c1956g4A16k4154lF50r0;k16m1En0t193;l1B5As3t761;y2F55;n1r0s8t2F;aDAoE9;d323tB7C;a26Fe9Eh14D4i135Bo1E84r2210u354Ey7B;!dAAlF6o3Ap8As0;!a3E5n0r1s0;!tB86;k4FD9;!a1A67b2A2c3A32e17AfC3g3F23h2F6i2A2El20BAo257EpB4r56Cs0uB9y0;a557i13o9;!a1249b7dD3i9n22o2F31s58t819u125Cw2FA;d2D20e12s19;c0l2ABF;e14Di1;!e15i6s0u1D;d0e1l1r1;!aCe891i49DBo213Dt0u5;y51;e84u14;a87Bc4CAe191iCAk67Du114Fy0;a9EFc4FD5h39A6k1F12o293Dt19A6;!a4B81c215e1Bh726k6F6l185o409;e23i2A31;g0t16;nFu32;!g3Ak16r1Es0;bCDl3A;!d0l1r1s0w7F;!a369e17i3Ds0y0;a10D0e27F6i157Dl42D5r29E4w5CA;i26;k1rD3;iA02;e823i70k1B23y62;!a174p6D3s0t3613;a4AC8e2E30i4FC2k2C83o2745r510E;!g1En1Es0;e22C2i6;d149;!b4F60e3135i4695s0;a4708e12hD3A;p483;f2Dn3x3B;!a24Be303Eg3EC2h929i3867k5FlBr287s0y3086;n1t133C;r627;d1520k53l1887m7E4n29E5r1622t1y1A;c1736e1D92i155Co4566t19C4u18FF;!i8BFs0y0;eAi31;e0i14;eBlB;aDA5b6AmBnB7Fo10p1Er38A;cBgB;!e15i6o29s0;e3E05i3C;!fBFn2s0;!bBn32A4o252p4DEAr1A26s0w9;bAEC;!c6C5hDD8l4E01n21A3o3F7Fp6D3s4823t2B61;l1r416t3;a4563;cBB6g2016m25F0n4F01pB47vDE0;!e15i711s0;!a5ClA61s0;!i53;l2AD9m3DD3r1sC0;!m0n0s0;!a3D3Cn12FoE1p3507s0t87;a30D4e4DF4i2971o28EDr1E4;b1Cm1s0t14FE;!o30s0;n0r58s0t1;!r2F00s1FFt3A07v1A;!e4i4FA7o29s0;a0i12;!f37i3364l22s0u3D;!a970e9Ei25o1BC2s0y52;c48x180E;!h6EEk4C3Bs0t3B0;eAt0;cD3l0;l3917;l463DsC22t43D6;!e12i25Ap3A9Cs14B9;a4Ce49F5i47A2oEy0;e10El7n22;!e9B0i6s0;c1k1r8;e7i3y0;a126o29;a1B4o1;!h196r287;r4A52;l4A02;i106Fl345t3427u4CD6;a0c3C5e3868h3B11i4FF7k2333l30E3o3DCq2EFy0;s126;p28r26E0s213tEA9;e30t16;z38D;n1tB;!d17Es0;!c2137g215nE6Fr1791s0;k641;b1Cg451Bn3216r5FtB;d2Cm217r2C;p124t1BA;!l7n8;m8Ar20E;h1070;!a1l2Cs0;!e26i3s0;!n16r0;!e15i6o1A7s0y0;a30eE;e17o289;!a1m56t3;d0n0r1s8;!a382Ae3970iA46r11E7s0v1884;c13En25t1E8;!d0rA1Bs0t87v38;e0i20C;f39EE;e67n3;e1Do34;e23i6l19y0;!e0l0t19;d2Cr44s1BAv1507;r66D;!e3D7Ei6w7F;e5s27Ct3z19;!eFDi21s0;n1o9;e489Fi6o73s0;e5Di4B9;g567;b7A1;o4A68;m470C;!e15f37iCAs0y0;a4EE5i4BEDt7u34;l8D1n195u112E;d4C;e1i484CoCu5y0;e776t0;e5n2pEB;c381;lCr0;!aD78e16AFi2A91uB4y0;r7A6;a50o1C;l0nBA4;k1B8l0n28r4BBC;a27CBc1A97d119Ce2C8Ff877g246Bi6o48A7r2472t44DA;r709;p130;aA3e1f3C7DiF1t8A;a16CoB;c10F5n2o10;c45Al2579;a1418e5o76Eu310;e3D7i6l2C;a10D4f29B0i22EBn8o1u14;nF6r44D6s267C;f1r1;!e5i5D;!d0i6l22s0;!b1Ee84i86l7r5B;eEh16;a1A78;z186;l71m0;!r15Es0;s3468;l27BE;e9F9i3169p35C7;!e1B81i6m41C6o199Ar3A1Es0t4F0Cy3D;d7Fw7F;!e4i6l22s156;!a2328cAC9i4AF5o536sF1;a59i2C3y0;o199;i4962;i3456y62;a104e9E9lDB7oC4r4F9;aCeDg0i0u5;a5Ch2C;!e1nF;d64pCFs461Ft44Bv2FAC;!e0n3;a38AAeFA5g2D21i3AB1l75m45Fn2EEBo2122r3A8Cu1C22;!e15i6oD7s0y0;!e1Bm75n22t1495;e3028i25D5;a1D8Bc85i21Bl382Fm4Dn164r345t3884;!a173b88d37De12i17Bs2EBw98;!a10CEc417d4277e1F0g43A8i1FFDj30B6k3079l50E6n297Fq2EFs3C0Dt1177x666y8Az374;eB2l7n1967;nA89;a261b4774d2610k44l392m3E74n1D94o413Ep2080u1C4Ev3w96By0;g96l55n195t1;!eAs0y0;!e23g2Ci5052k728l7Bn7CsE08t38y0;l996n29r18;i226Bo333;c1EBh8A5;e147i38;!a4E4Fc3C5Ce1Df513h41C2o31r4A4Fs0t32A6u72B;aAC2;n2s51D;!d0e1oDr1s0t1;n252A;!d16;o1A9rEB;n2r7;!a4De426Af37i508Co670s0y181D;l3D93;u1E61;s2A54;g320E;!n8r0t3;!e3DFEi151Ds0;u40;a10e18Bh21Ci2AAB;g38n1BB6;!a36;d56Ef15D8lD61t490Av257;i275;!b36D9l10As0;!c1F1Ed261Eg3D33i2DAl2AE5m2AECp241Br1914s0t1168;!m2Eo6Ft18A;i1E3Al44y688;!eAg4525i6m2Es49B6;a1b98e3B16;i72o163;!a87g1Aj9Es5132u34;c303Fg9D3n1C12r430uD00x11F;e84i6;c3C5e222Dk38D5;h164;!e7ABi6l3s0;gAD0x1F;l55x0;!a39BdB0e15g63i6m2Es0;!y94;n23DCp12D;a20eB;e6Bo6By0;tCEC;e299;!a4De4E3Ci442Ds0y0;b19oE;!i5Ds0;a28E;!a1A05e10Bi4543l7n22s0t11y0;d28s5CDt1AD5;a1F4;!a4BF7e4i338Fl22oFB8s0u21C2w23F;d0i6s0;t3E;e1i279;!e3ADh0l7n22;!b233AcD7e63Di6l2A8w7F;aE6eAi1C0;l506;f7n2s9A;!e15f37i6l7s0;a294Ae18C8i4999l22Cm404En3329o693r3303t177u3FDvD09;e1Bf7nF;uA4D;!e10i2DBFp5C6s0;e357Er1853;i3C1;e45DF;a401DoA6;!e40i3Co1s0;i37D7;c1n1;n16o1D0;aCo0;n113;c3B3;!b173Dd56fB0g27BBl75s0;!o59s0;f2AA7t4D15;!i51o11Cs0;e48C1;!e859;l362A;e322g3;!eC48i6z4857;!e5o31A;t7FE;!cB51p8C1;t2600;e1r34C2t301F;!e3E6i4777l44o246As0y0;n1s464F;a2962e3E40i4A5Eo3ED8v22C;aCo29;e0i23E;a1iAF;!a3E5c13Bn22;e1Di1D;!bDBe50C6h58iCAlBo1Fs0u4Fy0;!aD64e4CCEi33B0k5Fl22p37E2s0u1Dy0;!a176e23CBi2671l2Co1077r1938s0u27B4;k4E;e5g501Fl3E00n2;aDi31;e1n27B;c3f7nFsE;!c1286d4DAFf2F9FgAAEk7F0l79Em28n1F66p4B7Er47D8s11B2t48CBv180A;!a465e4i694s0y0;!a49A9e34E7i2ABCy0;e306Do1u9BE;e23D0u2340;!p43Ds0;eD50;o163;h5At27;a4A35eE25i2D53o49C1p0y436B;!h1i7B8k102s0;aCe0i0t39;d1CsB;u474B;!d39F3i3Cs0;!e0s4F8;!a4As0;t1841;a20B7e17i31o2C29;!r4ABs0;!d0nEo1s0;e0o9;h5C4;!s0u49;d1Cg1;r103;f2D;!n4ErEs4F1Et83u59;!e12i21n75s1D3A;e1o28A;a1g0o36;i1D58;n1r61t61;!e4h217CiCAl22s0y0;p274;hAFt616;a35C8c4F3Di0o28sB1u908x1F;l44u792;d44n367Dp28Bs211;a4658e42B6h4258i1D2ElE5Ao193Cr1B4Au4843y4110;a1DD5c1BBBe3C90f1nF1Ao29;c3C3lBBEt96C;!aA3;aF31;i2117v19y0;!iBEo2DF5s0y0;!a4Be15i6F4l6Ds0;a3e1o46;!a10c3EE6h28k3D70s0t18E1u116C;!n28Cs0;a1E9Bb303Ce2C63i2BF2n2B48;h56o10;!b12FdFAFe15f46E8i25Al1086m2C73n0rB5As36A5tFEz3EC;l34F;s7BD;u23B;!c11Ee8Co3A10r89s0;e776;h2FD2;b7Ad377g19n8t1A;lB3B;!a5F1b38Fd357e15f263i21m2En230FoA1Es0;g1s1Ft441z1F;r34D2s11;b7An240t19;!a4Dc1E1e4f37i619l3B28m562r1C2s3D1BwE4Fy0;n103;e17i393y0;!i27nD7s0t78y0;lD97;a569e3Cu3C;e1F0i4952m38p1608s56;!b102h2B2C;!m0t4DC6;a0iB;i13y2D;!a4Ae4i6l2D8Bo9s0;i16E0;e1BfBFm318n2DD5s1444;c0n3s14;!a4De3882i6t26B3y0;gBs0y34;a2EC1iCo398D;!aB98b1A9Ad10C0e8FCg3A92i15BBn1DC0s0y0;!g55;g55;l67E;c28Bl63;b1Cn27At112;h1r391;aB99;d0g1i31n102;b2DDEn2F7Dp5ABr1D8Ds1D0At396u495;!a3D6Cb43F3c1506d4D53e215Cf1669g20E8h4419i42BBjB4Fl1A2Dm325An3166o4AEFp3873q877r3506s2601t2B3Cv1E3Ew3BA4x4D8y2CBz4476;a428i0o505u5;d3Bg5Bn1sE;i27o42uCE;!i4F7s0;c3A6g3A6;!e24iBEu3376y0;r25t0;b7Ae438lBo1t1942;!t85F;f107;!a1F3Ec4622e4A4BfC3h4B5Di2998lCBAm2Eo20C1s456Dt36D2;a281i48B1o7F3u4A19;t4D18;!e33s0y0;e1s0t1x66;t1DF7uEz3;k25BBl58m21CBn2763q2028r30D9sD4E;m288Dn43D3o1A7;aCB4e185Ai4529o3C18u3DFA;!e4i6A5s0y0;lC25;t5C1;!t5C1;!a210Ae4DC3i2CAEl1BDBoDE6rA9s0u4890;a2AE1e0i17o2FEB;i1D24;a1c120m83t446;r3425;m64n363;a0e1Di435o51Ey3B2;u2B3;!u2B3;!e15i21l22s0y4A7F;s328;e4i6o54;s9Az3;iFB2;a3F92c0;d0r5066;e1i2D87oB;r12D;e298;!c2Cn4859r19BBs0t16B8;!aD4eAi6s0;eEAl7n3C8B;u12E;i4ABDo86A;a0e0i0;i3CoA6;a223Ab2EACe45E9i4010l102m45E2n37EDo49D2p30B0r102s0;nB59;!e4i6o9Br286s0;u380;!b4118c3D4dAC0e4f14Ei68l22s0w238y0;!e24i6u3D;a359;a1i199Cr1sDA;aC71e11D0i3D7Do21FAu3394y62;!i24;o14E2;a25A5e44DCi21E3o11B9r3F9Eu3EE1y7C;c3B7Ah3846k1s5015t1223;a33C;eAk1;s6FE;!r114s0;!a0e79iCAr247y0;!c32d0m63p12Dr28s0;a94Fd0;aA97eAi6o69u6F;h11FD;c324D;t3y1;i27CC;!b41B1e5i56s3B54t0;!b368c3C17d266Ce1g3C22i37B1k32DDmA3Bn3FA9o46r304Eu34v432Ay1CAB;e10Ei3Cy0;!b50ElA3B;!e23h5AiCBlBo1s0y0;t3634;e5n2t7;l487n1s2696y16;aF5Ce4264i1610r1948;l4C73;f89;a2ECo2249;aF89e4E49s10B3t46CE;nFr5C1s11;!d7Bf10Cl182rA9Bs0t165Bv19;e125i35A;r3B9t2806;lB33;a3BDe407y180;e1Ei6;e676;l38BBm5Bs2596;l1s5t1;m55n8rA68;l47y0;!i25nD2p24AAs1FF;c8As116tD2;n1389r2F4Bs3;e71Fi3C;i12t1;d0s0v19;o2FCr216;!a1De1FEDn22s156;!d7Cr265As0;a76i248u14;t247B;!d8Be1C1i6l4A7Bs13D;l3B2B;!d0r145s0;!a20e24i43y0;eC3Di6;!a69c6Ae15i3F8Am2Es0y0;e1Bl1nF;s0z0;s66z2CE6;d1s11;aBAr19u49;!c1;!a9i9;!g142Cl7s0;e2E0iCAy0;e18i4;!e1Bt25DC;!d0m337n0r1DFs0;a9sFCz3;a0t0;a1e289A;!g796i21p8C2;e1k127;e24C;!e24C;!e1i2Bl7s0y0;t42;l57Em0rCF8;g561i99Dm28t35A2y0;i163;s6E2;hC8;n131;eB8Fi43y0;g303l19C2rDFDs2C3Dt5040;o514;y244;o88A;gBn25;!e1fBFo15Ap261Fr1EAs4143t0wBA1;d181;!a203b4CCAe1CD7h3FA1i17Bl7n22s3BCAu34Aw5C8;i393m1Ao29y0;l251;c15Ee5o9s153z3;d666k235F;a1m653r1480;i1F5D;e3D86i70oB65y62;!e1Bi3Fl7n22;a173e23F0u3D;!b368c61Ae165DfC3h3F0i17ACm2Eo4A49p23E6r418Bs0u451C;t1BA;!g63l64n1s0;i3Cy0;!a13C6c359Dd2E54e1B91f3D62g4473h3501i4FD2j1D46k182Al49Bm3351n3D60o273Dp1E09r450CsFBFt4C92u2CEDv3616;cAC8r47B7;kA4;e8i4;c7t28C;!d0nEs0;a4F78e31C1i47B5o1101r4C9Fu4FB3;e3200o12t13FFz89;i10o51;!b83e4i6s0y0;lBr100F;!e0l0r2F;c4Ct3;e1E1oDBu30E;o4040s24EBu2F1;!e23i6s0t193;!m19DsBCt66Fy2D1F;l75n44E9t1Eu526y83;a61D;i42B4;a3CE1e2048i86;e35E6k16D;l13Fr120Eu42C;!eAi68s0y0;!c2783eB25i35Dl6Dm2EpB92s4301y0;h16y16;lCn87D;!bC05l90Fm23DAp5Cs325w2B1;c3969i575l1C4n28r4967;!l7n4F51r0s3E;a71e1;d0i10r1t1y1;!aDCe5C2i2B97o440C;!eAB;a1757e4F14i3B87o238Eu10F1y1805;i7D0oE64;b1Cn467Et3525;e1i302o4DBF;lA5r1;!e23i2F8;!d0l7n595r1s3E;d3881l85n1902o17A3r133s13Au7F9w1ExAF;!k1l5DnBo1DrD6s0;c2ClDC5n13Er2912s16Ct390y28;e33E0y24B;c1d1;e1FA6;!i290r287;c32e65;m42E;!mF60p19F9s0wA9;!a414Fc45B7d159Be1f2A0Cg3A67i56k19El69En3DB7o10s0t42D9w134z206;g96n25;eAi6t16;!e24i6t16;!d363Ee4i6s0;a1D0o1;!bBs0;g2Cn3;i338Bo10BE;!eAh320i6;!e1F8i21Al7s0;e60i29F;!a4A09c3Ae473Eh0k89l110Co1997r4C8Cs0t4ACDu20BC;n2t0vD6;!s0w2FA;r31;!a4Be17As0;e139Fm5B4nFo49D8pE61u1689;hD9F;e1o1Ct1;c77d1z18E;aCcB1e1F0i6t280Au4FDDw238;!a12d1E72s0;a1A33;e14D5;!e0r3Bs0;!a21EDe10i47C1s0;iE54;a59o49;a1F04s0;a1A74e1C41nFs2EA3t1B06;!eC1i6lB8Cs0;d0l2B7x1F;e5i3EF3k1;!s1uD;!i70o61s0u34y0;!a2ABAd403Ce11ADf4C4FgA1iFEAl512Bo2C81p3A3Es3620u293Fv31AE;c167n2sE;a0e3Bu14;!l302Bs0;t2668;a3059h3754l1E1r49ByB11;aD7Fu387;!a30E2e4h41ACi36n22s0t0y0;!c58s0t11F;!a1EBl2860r33CBu4AC1;a13b699;nBu5;c4CAh2D5k339tB;a3D6Ec4E18e65n2oCs2498;e5nFo10s19v3z19;a1FAFi503Do225Bu1768y43FB;i16;t34F;f1752;a23Ec1;!i3E96o494As0;a12l2A9;!d3A99e3AAg113Eh2ADi1C75k4772l4En2B49s0t3966w163Ey0z3;g231;i6D;o93rEB;d0s0v3;l88r1FDA;b2D72d102e2834i336Bm18D8n102s4784;n827;a42i116o8B;!i8Es0y0;i3u269D;a59e17;!a1AE6c3FCCh3F38k7Cs0u4D75;a28CAd0s5t0;a2A8A;nDC9;a4EA4d150Dl40C8n4B10q6F1r666s386Av4804y1E;aCd27;n0y0;a1e0nF;e7F1u3D4D;!e1156i21l10Am165s0w98;!d0h3Ar1s0;l1C4;!e441r10Fs0;e16CiD2Cy0;!e15i2AE7l63s0;!a3B6e15i2F3o9s0;n198;cB1i4F21;!a198e15i21l228s0;aACu69;!a4E4e3Fn4C5Er133Ds3027v3;o99y0;!e4i43s454y0;!n64r164s45ECuBD;a37Ei2DE1o46u3FD;e5l3D00n2o10s698vB;a54CeAi1514t47E0;a4235e1i1BEDy62;d19An1r16t1;t344D;!c3147d464Bf50F5i6l2ADnBE4p184r1662s0v452;a36Be21A5h1ACi203Fo4FBBr1651y62B;l2676r25;l3CB2o129;a9F;!e4i317o409s0u5;!nF;a12h4410k28;!d16e4i6s0;!a93e67f37i21l3AF4o0;a1g38n4F90s11t38;e80Dl4D0rB;l4B6;d2BCr4;a17Fe5s27Cz19;e17i442o6;e4i3Dl1Em1E;d0n16r1s8;l8B;lB5Bn0;e232o94;a1e33o1;i77Au9D7;r28t11;e30C1i6;t58F;a254De2F99i3F9Bo3A43;l1ABn1596;eBB5iF07o32E9t0;!a112Bc2BA5d3E14e15i6AFj17CoF55s0;f23E7i4F37;p1t1;aBB8c26A4eD8Df61Eg13C8i38A5kB0Bl38E6m20B3o16D9r4C13s79FyB44;aCe1C1iADy0;cBe1;!e4i21s0w134;a4106e40E5i21C8l306o2725r3DBDu38E4;f41F4i2385o29;t201;!h1C4i25D3s0t38;o50B9;!aCi2B10s0;cC2eCDn695;!a27A5eAi29Bs0y62;n65r1s1713;d0g1;!a3B50e3DFi5Co1400s0u40AA;h14;eA2v3;b3FC9c1EEd3CF7g1531i2734j1AFEk4F97l2B2Bm604n266Bo276Ap9C9r321As0u4BB7w2CBC;d21C;r4B1;!a4Bp1Es0;!aCi15Fs0;a1C68e4497i360Al2EB5o2E99r209Cu1449y13F7;i13r2AD;!a2911d1C56eB06i421Cl9ECo444r23AFs0u107D;a1637e10E5i4E60v22Cy0;n377Et1;i6o20C2;!i2Bo29s0y0;!b238d46A8g89s0w33A;d1n7E7s1F;a11C2;!a3286b4E93c21F7e2960fB0g12Fh406Di56k5Fl199m4DDn244Bs21BEt1F22w535;e1Ao307;!a4De15h1i21s0;!b1617d160eAi19Bo45DBs0u108y0;a1DA0d3CADk5Fl48CEn2938o1E52r1t193B;d7k4Cw1;!a372b4DBeAi12FDlBo2224s0u4A2C;cD3t6D6;c3Dr34u59;a1Di890;g5Bs0;a2E5Ae1850iFF2o18D5y62;t4A06;!a12l154Do25;!c9Cd1B8k5s0z17AF;!e40D2i68y0;lCDB;h1BDo73;e97DrF6t511E;!eD0i375l2E44s78y0;aDn0;!a2C36e4i6l44o311As0u49;!e39E2i6s0;s4EFF;a2D1DeDEAi3B01l396Eo3D08r3AEBuF4C;pA9E;!n27B;!e4A9Bs0u1C;!a73;c2An2;e1v3;c34DE;n3B;!a44BFb607e2EEAi24BCl1D38o1EB8s0u47A4v9E5;!d0n39r1s0;a4DeFDiBEl44y0;y180;a2E79;nFs14;i7Do500t71;e0s0;e0hDB0t184F;gBn9A6;e23iD9r35;!b3EEEe1Bi3Cl7n22pB;!gBi20F;!d0r0s0w7F;e4288;m3AD8;i173t218;d0s0w1;a31DFe2F01o1CB;!e17Ai6oE1s0;d4E2l2F1nB2Fr2604s1t8B2z3CB;!e31i20s0;o2A9Cs2C;!d28l4F6Cn47s0;h41ECk47;e3920;!e15i191El2FEm2Es4AFEw6DE;k53m0;i23Eu5;a23A3b3Ac1C6Dd43F1e2211i2E61m48A8n163Do4BA9p3F9Fr36B3s1A6u3F12w130;c2EEEmB6x1F;!e5r1s0;d182t0;!aCe15i21l88s0y0;l16m16s35t16;i91D;a13c2166;!l75s0;a352De2572l2BC9o33B6r3DB5u4383;!s263;!e4i6l3s0;a59e781o54;aBDi4B01y0;g15Cr2661;e1D41;!e150i375s0y0;t3FF2;iF40y0;!e4i44Es0y0;eEi6o6y0;h37B;i1Cy1C;g48i133t1;uD1;!b42Dd146Eg63hE0o31rA50t46Dw1F68;a17Fo9u14;!bB15e10s0;e1oE7;c5E9n997;e28F4i172o36D;g475D;!e4f268i6s0;m5F8s5E;a1DcA3Ee23i6p1Cr3D;eA7o95;d297;a4576e5110iA14w1A2;c8g0;o19;e2A88;eD4;e661;m4C5As22Ct3DC9;e20BrB91;eA6F;e3706;n7r55;o2173;!d0e0s0t0;eAg16i6;!a312Ed187f513iD0Dl13C7s0u387B;f41B;a2A72c3DA0e368DfBFo45D7s4EFx0;bF3r11BwE1;!e4i4CCnFF1s0;a657e1;!e4i6s156;e4v5B;i2533;a10i6C4o46;cBs115F;i259Fp35FCx492;e23i25A;bF0Ap4B59;!a2BFEb2F5e4i6lBo1F51s0;a1hD81;e316E;a76i13o9;!c41A1d108Ar2536s4F8;d0n8uD;e67iBEy0;!d0g7Fl6Dr1s0t16;f7o10t19;!e150i6l19s0;a3FBF;kDE;!a34Dd328Fn3s11A;u3D0;!e0l0n8t3;aCe15i6o12;!d0l5Cr1s0w4BAF;!a4DFAe1Bi34BCl7n22;f1l52Ao84Av10BC;r25y1;j482kBn6Ds121F;!d0n4r1s0;c120l64s1F;h2AC;oDF1;a3962i36;t121;g1n1;!a407i152Fs0;a20e449;!a2757e24iCAm63u1E5y0;u4E;!a196Ac4887d107Fe4889f6Di4F74l83m1DD8n2181o2AAFr248Bt32CF;e143i3C;e106n19v19;c7DCe47Eg58n2;a4D3F;e3CF0i6;b1Cc32i4r61tB7y1E;u275;!e1CCi6;r27C7;g0t1E;c48fC9s48;t577;!aCi169B;m26CD;a20i759l1DA2o40E8u5;e192F;!e1iBl1437s0;c32rB;i45CDs3BB1;c25F3;!a4De12i21l533n0s0t4A;g2Cl1C3n4DE5p508r2650s2F97t3u3E9B;l285t3669;sBt35DA;h64;l1BF;e3930;a555;b16c4Ct39;!e4i39CBo1Fs0;!e15h16i6s0;m0tAAF;a25Fe23i6;e0i65;!aCd39A1eAi30FEj7E9rF51s8;e4i29By0;a11y0;!b3BBz117;a2330e1A7h58Ci4CD4o1EBDu2752;!c226d45D6eAg7i2FBEk131r7s0;!a693e23h4A83iC0Bl590p503Cs0t36CD;g16Fx4EC;a720b28EBc50C7d35EFe8A7g33D7hEF9i49E6j3463k1A1Dl3277m3An32D6o1EEr2F50s3CD5t27A3u1BDEv1DF8w3F16y1161;a1390b113Dc2EECd19DAe3103f4724g29B8h3EEFi4941j197Ek8B3l2AC9mD5Cn19A1o4550p3BFDq2878rD8Es4AD4t342Cu14C0v4A6Bw355Bx0y4EBDz1CA2;l3u5;b1d5BEl18y1A;d1FEs0;e1Bl7n18Ft85;e4i86;a4De14BEiD62oDrB;i210;!i210;!e4C0i6;!e1134h4745i2C9Dl30DDmE2o4569s38t4FFAz1A;!p3BBCs186E;a87i31;h1l0;!i1337k228Cs0t1357uA4D;eAi18;r3Ds3;l2095;a340;l357z88;!b3C87dE8AfE5l22m2Ep178Br1s1DEEt6B3w3FEC;!o35s0;k19s336;w102;!b7l2E41;!e1F7i21s943;a0e5s153u14z3;a4Bd1Ae1A7r265C;iE44;c1FElBs197;rA4;!a9s38;!d5CDeA38f4076i6l22s48B2t38vBB4;e51m1EC4;a1AC3c480Ee67g29E9mDBEn191Ao734s2C96;!d542e0i3D20lD66n3DC8r17B3s0;eAh2871i6;hEn3CF;!e1Bi41A3l7n22s0y0;aCeAi3E59o505u34y0;t46E6;l3Bn8;i2E52p2045s89t132C;f28k70Cm1s3440;a1C10b9Ee3260g8Ai1318m5A1n1o2Fr6B0s8u4DFDz5A;lE1;a54o1717;e1n1;a9e99u10;!a4E1ElBo0s88E;rA2E;aCi2By0;!a211Ec616f2F9Bk5Fl1E8Ao7Dp5Ct2064;!b2F5e96Di388p15D1w339Cy0;i1t7;!a309o1s0t7;d3FF4;b1Cc713d1D07gBl2690n3C0p6CAr430t107xAA5;l1n8r7t112;a44ADr1EB4u1;!i181Ak1625o95s0t3EF8;a188e804i3ED3o29u45ABy0;!m297p2F20s0;l266D;c0d19n11As19t3z19;i3522;!b4649c3DBAd0fB0g230i21jA9l7n437Er0s809t496Cw2AEDy1;c1FEe5n4DD8w3BF1;!e36i4352l7s0;t1u32;c4121g1Ei4422nFC3p38r1Et440v1Ey182;i4Fu8;!d7Fo31w7F;!a3;a3;!b538e4E03g4D89h305i2BlF82m2Er17Ds0y5107;a1Db3BBlA35oDF9;a13FbDBe1f3k2Cn25o270Bp3EDF;n1ECt19;e27E4;o3D88;l737;!a0dA4e4i6s0;e173Ek2B14l1Dn7D2p24B3r40F7tB;a456e1r1088;h83l2Cu2BAy0;e63;a20eA;!g151Ai6s13A6;!e400Bi25Ap745s0;s4Eu5;!aDF5b187dF0Ee46Ff21C1h3F0i24AFk1l41BDm4DB2n131p2BC0r13D3s50D5t4518w3F3y0;!e14Ci43m5Ds0y0;d0r4F0E;!f183;e43D5iCBlBy0;d40B;a20e67s11t4A;f29EA;!e4f873i6r323s0;r0t19;d1n85;!c58r2929s0t1577;!h3;aE6n2D;a44D2e191i1D6Co0;!c11gBl0s0t3;c0dBn1s14t14Bu14;i3An18;a3224e5B0i20o348u4C83;!e239i21s0;!e4i6s0t120;!r3As0;d34C1e16F2f8g48BDh1An3DC6o1DF4p1C25u4w52;cAD0x0;aB29;!o10tA7;!e1i18l7s0;a1E3B;!b342s0;iDC4r2A92;e4F25i1A;g20;i1B16;bA25c3A7Cd9A3e12f183g187Dl304Dn29C4r22C0s2D9Bt159AzA6D;o12uF6E;!e4i1C0s36F7t139;!a10bBF4e3715g2DA2iBl1DD7o3EA0s0u5y57B;b1Cl0n8;r3986;a4An1E2;i6o2AE;!d0rD5Ds0y0;s1FFt2D;s491t2D;!s1FFt2D;!n1pA0s0;e23i21l2Cy0;nB0t7;b6FDgBl34DFm41DBp1122tBz9C0;!h385AtFF;a59e94;aBDiAC3;!d0s0t1x0;e2D34i1A13;aCo29u3D;bB7Au124;h4D0i220u4F;!a0oDA;l16t27;aFl44o1;r4057;e45o45;!r115s0;o4579r2997u541;!aEe4966i6l6A7n22s0;!e15iCBo1sECy0;n544;!e10Ei878s0;eAi73E;p18D;g22B5i0lA8s0;g5Bi4lA8m3s5Et2D;a11Co54;i5m0t1;!m4E5s0;e4i6o1;!kF4;!a69e23i43o11B3s0y0;n1988;d4E2g23D1j1Al2C50m1BEBn8CEr230Cs5111;!a1DfBFn4182p21Ft1EvBA;r3B83uD;a28Dt20;!l2B5s0;!e1EF8h199i368Fo9pA40r22C1s0t2E3wB4;c2Be1n1x0;u4A8;!d0i214s0;e261o3379r13A;e209D;!e15i17Bk5Fl7BrA7s0;i31o49;o4CED;t7y0;!w27;!eAi6l1E;a4Ae15i21;!oF6s0;f7n2o9;n1sE;e3070i2E9oD;!oC;!i4A2Ds0tAA;!t10A;!eB84i6;c9Et1855;e22Fi6;a3E3Fe33FEi2609;!b3Am3As0;i1Ey0;m2C;d19D;a5F5e4i68l44y0;!i1B5j4BADs0u1;e5CBi6l19;!a1b49Ce6ECh110i21Al4B4n22s0w6B7y0;eD1h7i20;!d0r1s0t4C8E;g3Dn2114y0;!a348c0n3s0;a40e29Ai10;e1C80;t4E9;a53o1A1p775;a126o29F5u2B0;g3k0;!a521i4119m343oC01s0u4B85wA9;!a17FoCs0;r58t3u172;a15FDc26D5d17CEeE93g4730hCC6i159Cl129Dn283Dr1420s2D01t34E2x164D;!l7t0u12;!b2DFAf1115g355Al100Am1ECBsB01w2268;c2E8g47BB;n3As4D4D;i111u5;!i31s0y27D;n0r1A;!a12c4ADeB25h3F0i68l38n357sA2Aw1DBy0;e4i6l1CE;a16C6b2708c4210d2ACCe2BB2f19C1g15BAh413Fi1827j421Ek2E9Bl3794m467Fn1869o4C22p2C24q1F4Br3F8Cs3D5At224Bu1615v3CC2w39BCy3F56z4A73;i8l44;n6F9;e5l19nF;!d0g72Ai3Fl1EFBs0;d1n27;!eA69i1B3Bo9F5wEDy0;c11l16r39s48;!e3F0Ei4A1Eu34;!e15i68l36As0y0;h5;!d0r0s8;r3585s4A24;e1o919;!d1f37i6k28m2Es156t140;a488;n47A;s2F0;z3FD9;a21l4DC1;i4337;a31A4c1BFEd1851e469Fi757k422El1257r1s185t285Dy757;i4EB0;!r4A92s0;g1oB41;l29Do4E45r243Bu7F9;!a4428e47D4m4F75p29s0;e4i4E2Ao1s0;e5i5C;a43Ee99oD7;!l22;t267;l2DDC;i0o101u5;!e15i21lBs0t0;f279Bt0;n4706;!a20b4125c1087d4B83fF2g3F3k5Fm22B0nFo10p2A0s1DDDu34v33D8;m64z88;!d0l22s1C3F;i4CB9t257D;a40e391BiDCCl290FoD4r3ECs1107u318F;s14B;a32g1sB7tEEu3B1v5B;c20B5d19B1e1D77f213Bg44B9l3D79m2C8An2055p2EADr4408s3EE2t1CB1v40BAz2768;aD8iBDo22Dr7B5u44;r2892;eB39i6E3y0;t31EB;!eDl7n1s0;a1E7e23i21;!f37l22s0t18BF;a1eAh3498i6s4E8Ct36F0;a13c0sFCz3;n165sDFE;a2B22o198;dBA;i1F;aE1rF3;i11A;!s1C7;r110;!eB19r7s0;cB1k47l27B6n181Ep2A4Es2FC5vB;!a39BeFDfAE6i6m2En12Fo12FrA7s277E;!e5kB;!e1n22;aCcBCAd0n2sB1;!g4DAAlA8;h32DBn46A5rC2B;m4Cp36t3;l2E5s0;!b2D64l22nF3Fs1732;!g1DFAs0;d905k1l2B44m45FFn315p3C9r45C4t3F9C;eDr235C;iA07;l278n423s2C;a6F7;h98Am0tAE2;e0h3B;lFACr82;n3C1;i2975y18F4;e4404i2953o4438;cEd0;!e15i6l7s0;g4CBAi35;nEr39;!a369e2A9i382o12s0;aEeB39i21;p39w39;t3AB;!a320Be85i1A5o73u4D1;!e4i6o283s0;l0r7CC;!s0t5CDy1;a136hB0F;e4174;!d0n54Bs0;!l1n0r1s0w7F;!l0r0s0t3;r17D;bF1n336Ev14FB;a2C7e1;!a1DeD0i6s0;!n3B8Ds0t0;a5A6i1A0;e1i55Bm3CEFnEp55z522;n2BF9;i25C3;!a2F02d0e3C79f224CiA02l4C25n6Do5123p394s325t0;a20i4D3o29;e13B4iBEy0;c3e902;!f1D8n24E4s0;cBo10s66;aCi113;r360;e17CC;e5hAFi5s531;!c167;e1FBBu3C11z377;!c3D;i392n13Cr434x1E;!e265i86l7n22s2F9;d0n16A;iF1;h314A;!m16Fs0;aA3e673;l8BEn1DEo412r2284;oA1F;g55n82s33C9;!c30Ak25AD;e4005y0;a1De30i77;e0i3A3Dm3411;!i6s5E;a25n1BE;a395Dc0d3s14u14;e1ECD;!a3DFFe23f37i6l22s0;a1F05;v132;d0r2Fy1;e159i17Bl175;a60E;c301l3BA0;c1BFC;a5Cf394Et24C4;i3u3E46y0;a463Bh6C3l3B00oF67u4BCE;a4De4FE2i1DA1y0;r4E73;!aA3e67i21y0;a166c234e4n17C7r697xAF;c27Ci1361l3B;!b197Ac1919g269mB4r217s0vFF;!i0u5;o1DC;o5FC;!a1BAEeAiADo46s0y0;a166d5BeAi21;a77Fc0s4160;!e1Bl7n22sC5;a84Bo29;a20c23B5;u51A;!e135i480;dD8eAi6;a72i415Fl9D;a11Ce17o50;!d372Fe5i3E2Ek47o1C5s0;!a166e4i6s0;e4i21l1CE;g2F52k864;a2A3o8;e1o104;t423F;a1A1;e3096;g19p16;o407D;cEx66;c0n0s14t3;!c2D52e418Fl7o32CAy4452;c11t16;k3s3;r1v63;!e34E1i6l7s0y0;!d0mD2r1s0t2Dy16;c4964h3BC;!d0e9l7s1;c120n179;b1Cd71r414;eAoDu5;o10s2EB0;!d17Ee4i6s0;o153;!e15i6l7s0u49;!a298e15i17Bs0;i91B;d3l4E;!e3B69i43l2A8s0;e23DEi68y0;aDh0t91C;i4AD6y0;!cEd1B0i8s0;w3E33;a349m0;!b3A39l7Bs0;dEB2g11r2C69;!lBp20C7s0w134;e1i20B;e1iB;!e5iB;r344;p47s44D;eAB9;a1Dk18F5l2491;!a19FAd0i0o29r1s0u26BwA33;e3F96i136Fn2B58;aEd0y19;t3538;h454D;n48C8;e1D1lE2;n3s0;!n0s52;h632o10;nCEo29s3;aD5o3659;!a4Ce5i125s0;e262;a33Bh117Co24E3y2D77;c9Cs2C;l1EFr0s0;!i413y0;eDr3u1;e4318i21pA4;gBl4CE;!s0t14B;!a2BD9e1o1C;!e5B5iCBr7s0y0;u59D;a31i31;a1De273i3B92o160A;a4FEeA67;!a4BeD0f37i6s0y0;e4206s1A6;g4494v46D1;h596;eC03i32E;lE0s1E;e8Au2C6C;h461Bt24F4;!e3EBBi21l22Bn246o241;l4B08rA62;l16A;i400A;!a530e4iE3Ao3D8r393Es0u2485;c0s9At7;k3A85;a20D3b353Ec22AAd1C27e3BC4f3600g50E4h2A35i28F7k28BAl3845m47A1n4165o4F00p2864q39C4rC66s2DF1t1325u2360v240Aw4A00x3F0Dy2C47z2C;i3A56;e0i8El50EEm1o14t0w6Ay0;aA3l280m5DAn1C2o22B1p1Er124u124;e930iD4;!d1n1s0;w23F;b2A2h198Fk3FF6o1s49D1t40AEw426;!e159iBEs0w35Cy0;a2956b47C2e1D06i26EEo21CCp4AB7;a505;e830p982;b4341c2FE2d2C09e2828f2391i1AB8l1910m49E8n33F4p2B31r32CBs124Et4275v1852z0;aFe72i72o138;t4B45;e7F3;iEA7y0;eA4h60i865y3B2;!a1C44e2554g75i4BAEo91Fs0u5;b1c585;o4817u1BF5;hF91;!d0i18s0;oAEw10;!fC3iBEs0y0;eEC8;x231;a1DcE;e90t1898v4C8A;oA62s11Au5;b611mA5;l1An4BD7r2E6;!b14Ee1fC3h27i3010s1E83t244AwA92;!n6Ds0;e4iAD;e11Ci2E36o9AFu5;a4d4E2i3E5Dk1D0n2014o95p304r389Et4351;!aB87n4996s0t87;a5E3;!a4B9Ec1A31e3C39h149Di2512k4781l3BD8oE89r300As0t12C8u1B01yA55;h15C2k1378o0;h30E4;c340;dF2iCl412Dr11Bs4992u59wD3B;!h3E90i54k5Fl12B;!e4i13r7s0;b1Cd7F;gD6;!e15i4DACs0;t1v48;s1D5Ct1764;i936o48A;mA1r4F58t1343y38;e15i43o93y0;g64;d3B66e1v3D;r22D8;!c48s0t2D;!a4De498iCEAs0y0;a4788i13o29;c95lC;!e0m35r7;a25E2eC39i4F5o29A4;e6AEi6;!a10b3122d37E5e1F4CgFB0h89i4E2CkBDBl10C1n441Fo3Ap28r18CFs2F2Dt184Ew33Ay62;!r61;!e8A7i54;a337Ad1g1B44m1B9n2898p4B22s11t3890;i3D5Fy0;a25dDDt48E8xC0;l216;lA8sC0t2D;d0r28;!a431Ad1B6De4FC7i6o10s0;!k0p51Bq0r41As0yE2;!i4n1s0;a10h4090o10;e1BsE;!a1BDCe2BCCh36DBi2FF8l1D3Co493Er2FECs0;a2277e23ABo400;!n22r1;aCe3A60i13u4F;a4086p3CCE;!e0i35o40;!d0n27Ar1s0;r28s4F;!a4Db3DCFl10Am2Er15A8s0;c2At1;!d39n1Es0;n48Cs5;!i904;!e4l3s0y0;!g19r1Es0;!aA32e15i21m93FsECu7D;c9Ci378A;b2B7t131;a1EBFe934f3EDCr4B87;!o1D4;a1759e1EAEh3716i4E15o32D9r4AA4u2C13y2BA;e3A91i8F7y0;e47Eg96r990;a3B24o10r3DFB;a25Ce4;zBA;!a2B40c4EDe1i248t47;!k0s0;b10Af8AnBCCpB;e0i2339;f0n0;e159iCAl2Cy0;!l67Er3s0t20;n1r336t1CFxAF;a38EEe2613g204i172Ao3B0Cu4CBE;!s66;!s70;!m2Eo34;!k1E53u993;n504p7EAr4357t3BF5;i128;c2Ad1;u2C8D;!d8B;d145;!d0f1D8i6l1D65s0;l8Au4762;!n0p46sB0At1DA3;!e0n0t19;e0n2o46;!b14EiBl22p165s0;tC5x8;h3F8Ei1D3s385Dt8D7;r14y0;!y31;bC8c74Dl625m1C1Ap10C;f16n3F7;!a4AFeAi6tF7u5;n0s0t5E;d2B;a355c3FBAd3D6f8i1C3l1027n16Cr13Cu4283w9;!a34u34;a446Ei1A;!e4i43l19s0y0;l1A3;e3032r2BC6u900;!aCe4oDs0;o4E87;t4198;d0t71;aCc11En3;l5D5;u16;!aDs0t15E;m38;e23i6u32C;d9Em1A;!c98e2295f263i17Bl29AEn22oDBs0;!e1F7i21s0;!e15f37i324Fl7s1Fy0;sEt3CB5;e21B7;s120t260B;e1m3A72p28;l0n48F8p4F06;o104y34;eBu310F;!b3EBFc2567d3F31i6m2En25r3529s0t4C16z41;!c8iCr7s3Et3;d3Bn41A2;!a2935b1000e2B76i20l75m3421oE7p127s1A6u216Dz37F;!b9Ee50B4i1CD1m1C2o81Bs504u30E;aCi15Fm0o29;o9t47;!e5i1FD0n25E3s3E2;!e4iF9o12s0;!a2345e5s0;sCF;!a4De12i6o12Fs0;l1EECm64tBC;o3Cu3Cy1;aA6Cu69;!a0e18Ci60Co1s0;g5BsC0t2D;n793;e4i4753o670y0;!e4BCi38F6s0y0;l1t0;e8i1C35o36;d103Fe23Bl432Em2311o10;e4i46CCy0;!a25F2eE16i1BF7s0u4B61;tC8;a80e4iF3Cy0;e24t1;a3A1Ae99Er3BE;c11tE3;o36D;!h246;!a1DCl88rDEs0;!b50F2e20Bl3D27r36B7s0w169;a8m163x0;!b6C3d0n1C50s4C4;a29DAb368c1554dE9Be3278f15DAg29AFi4B5Bk29l2332n7Cr216As16D3t2191u4Fw2061y2C4B;a4D67o3E6D;t9DB;k1n2s20;mCCnE;!d0n0r2DEE;!a8i13s0;l4D49n4;t104F;eAh1Ei6;!d14B3g122Aj347l454n1EF7r2CD0u4AB1;!d0m2Er2Fs0t1;!a255e152Am2Eo3EC7r45Cs3662t49B1u1w169;e51o4CCD;e159iCAo1E6y0;iFE;e14C5i3CA4l2Co488Cy62;!a80b47Be150i68l36Cs0y0;!e9i9s0;a788;!e1DC6h110l122Fn22;!e15iBEl88s0y0;!e15i450s0y0;a1231i4F5;r300Fu495;!a17F5e15fC3h60i41D3l22s0w134y0;a2984eC4oC19;e4i86l2Cy0;!a30e24i5BC;a3F94;i39D8;i4EA0o3E82;l1n37C5s58t1;!oFz2B;!a8B7e287Di2B96l36C4o34s0t1;d0e9r196t16;!b17Ce12m2Es0t38;!eB64l7n22;!n3B9s0y98;e5fF2n2zA4;o1D0u47F;a20b13EFoE7s0v63;l3Bt19;c9Cp2D7Fs2F4t1;e24f7nF;!eEi28Fl7s0t7;hF2Do1F93r3824y3A2;a0e26i6;d3Bn2;dE0m19;!pDEs0;c457;!d0n0r16s0;!g14Bl1s0;r86C;h358;!a90e67i21;g25Bi2C2Cl1C3u34C;a520e9o51;d1B5B;n1056;!b103mE9p1518z1A;!f2634r2F81s0v10A0;i18u3y0;d1En7;!i126Ap444F;aA3iE;!a202Cb14Ec1EA3d1224e3092f1BBFg32C8hA0Di1940kF27n1A9Bo3E0Ap4F1s0t2D08xCFy0;a52o29;!e10F7g7Ch1CFEl56o10r1F3Bs0;a4D48;d0m3;l418n179;s19t19;a1l102o4A56;g263Bi69lA8t1B6;hA7;s5Dz5D;b3EB5e3C2f4A1Al2AF2n1BD3p2A37s3EDBv4ED0z1419;a42eB1Ei2Bl251y0;d48DBeB8At6EF;!d8Bi1F3s0;!i969s0u5;iC1E;k47F0u3ABF;a2EE3i4E86o9EEt8D4;u3C4B;!a3A15b44FCd1D03eAgBF8i4B9Al2247m371n3DAFo209Fp4C1Dr3CBEs2266t47DFw42E7;n52t7E;!f37l7;a10e2F9i1A5Fo4809;e4CE9i2069l70Fo4ECFr4280u3CD9y0;fC9nF;d1Eu30;a0e1o2EEu34;c32i4r48y1;!n18r53s0;m60;eF01i3009;eAi2F3;a51Fe0o136Bs4C;!a39F5e26C5l7n22s314B;!i339B;a5DC;!e15i6l115s0;!b2F5c3B23d52e4g19Ei6k1l1m372Ap17Cr2527s259At16z3097;!a12b42Dc4D6Bd2BBg3D43h236El6CEm3E9Cn3442p2389q303r1AFAsF5Et2764w6A;a1105b19C8c43FDd16AAn2986o29EFr4469s5101t14B6u1638x2D54;!g401s0;!a397eCE9i71Em2Es0y0;a50CDe13BBi2A9Eo3D1Du48D7y0;l2A61;l617;!c11m12Cn0;a20t139;e174;a46F7eEiACo4F3Er70F;iB3n1679;e4iAC;o57s1E55t3ABE;a1A5e4i6;!a467Ad0e1Dl22s156t3A;h2B16;b3289n85A;e145o17uB4;!i738l38s0;i6FuC6;u1C9;t17B9;!e4iAF7o29s0;zA4;i8r3B2F;!i2Bl2Co1CBs0u0y0;a40C7i9B4;r33DBuE8;e150i1F9Al175y0;l0t82;aB6Be23i6u19;a376;aE3Fi36Bo51C;!a1b35EBe3F3Ai1C96m4595s3C03zA09;aC49h4DE8o24ABr4D25u38D6;a4095l44;!l199p9FEs0;a0c0n2p4As3t3u14;t1D6;tC2;e6EiF6Fl44r1DC2y5B3;t3717;l28n2AB;e4l8;l47t0;i599;!f7;n953;g2713;q62F;a0e4u14;!gB;e5E;e5A;a3DA5e2A8Fi1D6Fo37A5u505Ay459F;g19s19;e12Bo31FA;c301;!a4D1c2103d419EfDAg214Ch4A7k584l3540mC92p25D1r1EAs13C1t2400x120;aE6rC2;l1n28;!e1Do10;a961e36C6i6t107;c11n7t39;e4A;e4177i33F;a1B00;eDr119B;a3DDe411Eu3;!d0f37g1Am64s0;r6D0t1;i15Fo29t41;e3372i3B8B;!l3E1Es0;!a54e42h1E;a9e901;t200;c9Cd1BDFl28r28;a76p0u34;e0iB72;!m2085s1060t61wA9;l2827n4CD9;c425Ed3FEEf42CBg4C40i4BA7k1l3406n1C39q2EFr4F8As175t3C4Ez4D73;!d0i21s0;i4A3Al2387t28;i42A2u31A;n55u61;!r1DABs0;!b1Cg699n4B8t72C;c4495s853;e4CB1i2By0;!a1F4s0;!d3;c1e5l2286s14;t380;!a1465cD7e4C6i250l7s0y0;i31l468F;g0t0;e2E2r237uE;c19iEy1E;a3B93e1BCFo1EDyC;i54o4159;a4F11b3C23c12AAd3D82h2BE8l49F8o1265r232Ds4EC9t2EA8u1DB8z494;a362;t3CAC;a3D64e5l2F0nF;!o20;o4402;c3B3nF;!i68s0y0;m1p2877;c0s11;!c11s0;!l3484s566tBC;n4851;!a113d1E2i28E9;r4B6;!b5AEcD3s0;!a1o46s0;d3Af7;lCs11;a17Fn3o29;aF42e352Bi6n3oEr3378;p4Av1A1;!e5CBfE5iB9El2A8s0t11y0;!t4DDF;!a4Be2C90o36s0;k510m28p28;!a4De33E5i6rC9Ds19B7;!d47h110i152s4DBEy0;aCe31iA87o4300yC;aCe498A;!d0fC3l2FEn1DErC5Bs0;n1rEt4D66;!s0u98;e11FBi352;p10C;!l5As0;aCDb1F7Cc1464d3259e7B0f26F8g26A9k43ACl4D0Em4E36n4AD1p2821r2CD3s1AF3t3E86v1801x223Cz15BF;e1i0;!e565i3Cs0;!i6s4387w169;e3DF8i86;a1C28e1953h34Ei27C6o15E7rD26u21CDy4805;r1021;i24D4;a8AE;aCc0;a76c0;!aAEf3C0Cm2CCs0t1CF;!e4i3903l999r19s0y0;n0s1F5z3;n40A4;!aCd0r58s0tCCy0;z28F1;!e67i43m2Ey0;!a4De255Fi21l376EsB32u32E4;!f183p5Fr1s0;e23B7l2C;l0t14B;!a162s0;!g4922u34;a76l1u14;!m20DBp5Cs0;e12o81;c2167k28;!e4h8FDi6s0;c9Cd149g2Ct247E;fEi10m0tB;u25y244;e132;cEd3n4B;g2CoE8;c5Cg25Br15C4s44t44u61;!e15i838s0y0;eAi125y0;e41FCh4816i42Fk131o2E33t1CD;t491;!l1Dn3s0;e80FiCAs0y0;e2E4Dn2;c1ArB;fBFo223v2B73;h1B43;!b1DAi5Cl22s0u47B1;i412l31B;c43E1nFs11;n29D;aC37eFC1l2Co98C;a62Co11A6;!s0t1E5;d48n48r34t0x0;d0p1;c301Bi1Ck3A7En21F4o2F96p41D7q3B14s21B3t1D84uEC3;!e159i6l705s0;c3Ae1Bl7m19nFt1C;a307Eb4539c27BDdBf380Bg4D4Ei306Al45DDm3140n2A85p495Dq122r3EECs4DD7t2F9Ax2054y6DD;aE7Ce18B0i3EAEo23BuB8y688;!aCbB4d32EEe4977iA78s0y62;n3r3;!d0m5Ds0;e1Bf7l7n2t707;a1iDC;rEs1F1;aEFe2D84;!t6AB;n3084;a4307;i2704;!a93b1D2c98e2C3Ei6BDl22m21C;e10FoA0;aA3e721i1B5;b20E3c3A7Fd25Df2940g41m1Ap17C3s89Cv27x0;s363B;!e0r78;m3439;e0r7;e5054i4F;a1e30;lE8r2E9;e762i68y0;a25Ce1oE7u387;!iACCn819s0y0;e1i29F;i2By4E8;a2BFeDDB;o3F;a36h494o404t2CE;e7i8E;!e4i6s0uE;!a4Be4i21l22s0u49y0;!e15i375s1594y0;a1e1607i32E2o3B09s0u2B4F;dA01y1;e222o283;a1iCC;n4s11;n76Ds401t201F;e17i4D9Fu5;cDAs89t2EB1;!k18;a10o29;!a3D51e4FA9i3F8l7m4F84n22o1p28r4D3Ds837u162Ay0;k3C62;a288Cb1714i3B3Fo3A68;!h4F9t283E;a47FEc975d5D1e3B0Bi3DA1m34F6n1E7Dq9B8rBs1A7Et4933;!a3EBCe4EDFf37i375Dl22o106Dr4A72s0y4C74;c4409n1;a87eEFAi9E2o1F89u34;u864;e4BE9;!dA9e4i21s0t365D;i19FCy62;!a20e17i4C44s0y0;i1o9;i9o1;a2917;!b2D05d0f268g3l7n22r0s1ACA;!e240Dh151i21l44s0;r0y0;n2t11;!r7t19;!i1p1A2;a43B7l5D7n4873u5D8;e36C3l44s466Fv3EBD;!b1CBc185Fd4321f131k2A7l131n1s4D95v2C;l371Er10C;e2435y0;r2C4;a55;!l1Eo570s0;c371;e4t1E;b3F6c1DA6d2462f2F88g25D9l4B5Cm3C77n1BC8p28D0sC2Et3AFBz392A;cBt4B68;g2Cs2Cv3;!d3357e17s0;n4E9D;!l0n8r7;!d0lA9m64n8o1s0;e0f14ADt3EC;eAoA2;!b1363e1889f56Ci1B9BlA61s0y0;e48Ei91y0;!d0l2AEBr1s0;a8e9A0;!b1Ch249s0t4384;f3985n164s32BAv5F;!a50iCs0;a136e12F5o28B4;d1Am0;!e0g0s0;d3Dk53lA8m30DBr4433sC0u2448w0;r1174;aCt0;hA90l5A5o25;l44oE;a124d64i2EF6m33DAn52CrE1;m2ErE;d0uD;c1dBs19z19;!a162Ce974i3n0s475;t1F73;c1F1Fe1l1q122r3BEEs180;!e5i20s35;b1D2s5Et2D;a8w1;!k4Co1CpCF;c24Dk18l1335;i51y0;i24Eo1E7;a3CiF;e4C57i133o1E2E;a4EEDu5;i65n2;c3CA;e2791;a4327b4053e3E15i2225l102o1053u3B94y3FE5;l25Dn8t2E1;a8BA;g44m35E7n113r2994s161v2452;g1r14A;a4E32b15A5c1830d47Ce2459g1F1Ai3AB0m8An139Bo3F6Bs3EA9t1227u19AEv1A;m1943;e289F;a658;!b256Be3D19i470m58o4BA2p28s0u1755;a30e23i6t47;g10;!a3684e1F7i21s0;!c1F00d28g102n7Co355Es0t66F;r44;e36o400;e69;!b187m120Ap87Fs78;a34A9e4EC4h16DFk3ECo1s1C7Et3651;!e23f37i6l7y0;e42i70y0;a822e47CF;e58E;e53Er345s85t34A7;eEi27Dl6D;lCCm0;a2A41;!a80e56Di8Es0y0;a74o31y20;!a12d19Ee40B1g2A2AiAB8k26EAm4001nAAo734s0t28;e19DBi21u22D;c85r85;d0eAi6u20v48;r10C;i20Ft56;cCCDd4D8Ff2B1k77Bl18FEs226t42EB;e9Ei36FuE;u699;!a322EcBDCe1430h4CDFi3496n4556o3D50p29D9t2AE2u4024wC59;c5ABk8A;c4EF;m38nB;aC8;h558;l997;c0t7;a34e34;a379Ft286D;aDAc13Bd2121tC8;g96rB;e4B2;!a80;o9Bt1798u4F;a438Ei4019l4EFEu4BA1;a36B;r1y1;b2447c12D3d3E38e3A9Ff2996g17E8h2305i1092j4A3Ek2786l15B2m37A2n4BB1p20AAr1B50s353Bt2C0Cu2051v20CFw4771x56y5089z3871;a30d48n16D4r6DFs42E2;i6F7;a0iBB;bD6;!a4Be15iADl48m2Es0;h95D;!a76i1u14;i15A;l4597s13Bt44EE;iD2Fo4FEF;g96mBn2;aCe17g1;b1Cf330;!e5s0t3A;c9Ct47;!a3194e5C0iADm2Es0y0;s0t174;!a1Di13s0;!a4De3EDh28i2FEAn1E2s0;!aCi189Es0;!a27Fk3s0;r4954;r2D2u6E;n1r30F7;cB9n3B0Ar1s4C58t1u30;!e159i6l1CEs0;a34F5e11A4r4B40;a28D3e21D7i1028;!a1061d1B0Fe3BC1g5E5i3FBCn1797s3907t3B0Ez18;h0l293Ar2E91s35AA;lE8n8;i27CAl26F6;n2D0D;n18E;l2F0;d1D29r47s1CAz1CA;n196;e5l3;e1l3;nEp16r36;i15Ej18;cEn65v19;o723;e1r39;!d202Fg4Ar28s0t47;b1A66;e6A0i6;e10E8i16B;g122s9B6z9B6;n3CC;hF6i3C4k1C;a52i3F;mB6;fA45r8D;!i1l510Bs0;gE1l36n1873;!aCe4i214o29s0;!n52o9;n3o9;a406Fe3CA6i2A30;!e4C1i68y0;e4i125o36;a4E4e2F19i6;!e4iBEl75o29s0y0;e313i6;!e3E35i6;!e4iCBl685s0u4Fy0;e4B2k28;!n2D1C;n19s99B;!a1DCe1r1s0;a1e4060i6u1D;rA1t633;!e31;e15i43lA35;r1v1A;o26D2;a530e12i21l3o4ACC;e3B7h103i1Dr4F9;a9c0e5;n2218;c177d3FF;e1i153Cr16BC;a4F4Cs243;r468E;cD3p3D5E;a262Er26D;a3F72i2EDo45AAs0y4014;e5Bi642y0;a4AiBy0;c2Af125;!r0s8x29;!eC1i6s0y0;i77s1A28t2ED9u2674;l470Ap58;!c7e0l3Bn14Dt112;c1Ah5085k339;!c3664s0;!nB;!r4s0;b7Ag3;n2B3;!i87o36s0;!o12s0;i9k1E;c1Ce12k4CnF;!i3A33p3446s1AFt1;!e1o1;e101l19o387;!a4421e1F7i68l22s244Ey0;p7D7;p16FD;u63;r3395;b1Cd89l1t2E1;e1219iBBCo2D7y37DE;!c394s0t358E;m10n36r1;e1FFBs0;!eB2i27l7y0;!l83s0;o30C7;!a3A81e159i21r7s0;a1i1y0;!r470B;a2D0o31;!m88nEt161;e12g0;l286;a1D34e1F40i3B53k8Ar13FBy0;l1Dt1;r472;c175t0;!b9E3d18EBg32Bl1E1Bm5DFn8r3C6s3A77t4DF1;e1CC;e17i27CDy0;!d1B42i1k16B6s0t49DF;!e1CC;r124A;h34B;!a8e4i29Cs0;e2D89n3F4Eo2A5pF2rB6;!l13B2;e6Cf1i13y0;e10n26B0r3951sExE;a30CF;c420;gA1;!e15i8Es0y0;o220r3CE9;e113Fi3199oE47u4109;d26Dl38DAs4504;a1A0eAi6;n1A3t0;g910;gDD;e23i6o12;!cC2d0l1qC2r1A3s0t1B4;h2A26;e767;g15Cm429En17C6q122s3E3u2B3;!a1DeAi2B2t16;a1i25lBr27D;i34vB;c32e0i208l1FDFm50FCn182Dr1t2A28wB74;e2AE3fB0;n573t1;r65t127D;b537k16EE;a41E6b2546d4046f4A86k3m4373n221o2C6BsEECt2421;e1kB9D;!e24f37i43y0;a12kB83o12;n417B;d531r1;!d230e4i21o9s0;e23i2406;a3545o2AE;d1FB3e1i977;!i13D5s0;nDBs935;!o862;o40C;m2818;!c49g19s0;a2428i4511;c164d82l28F3n949r718;g4Al207Dt47;!h1090i1s0t0;d2Fe4BC0iE5Ck1B7o26Cv2D14;n3823;e241Do4DDu3145;!o1p2CDCs1C7u1;!y1C;tC33;!d0l22D9n3DFDr0s3Et38;e582f7s0;i3E8oDC;e208h21CoB9;l16r1E;l1Er16;l1n88;!f7o10t2DB;eA6l19r19t1;e259Di6;v274;a3098t87;c47F4eB2l2B7mBnFs1F;n4345r26C3;!e26r7s0t1y0;!d3Bl22r1s0;e2CB4;lE73;r15A4;c813t174;c0e5s27Cz19;d0e293Cl1n2E7s0t1;e41C9;t32F9;!a459e1590i3068l7o1s0;c85gBt3;!aCo9s0;b0p28;eDl7n2o1;oCs0;!oCs0;e12i6l19;l1Dr40;c11s35;!c9Ce12o332D;a25u273;!e1h471Bi3Ds0t1875uB77;!aCe26iCBs0y0;!i13o1s0;e60Ei47FFo1016y0;a416EbCB7e31B4i1A04m2B82o24AEt354uBD;d27g10sE;e59n4B;p192;r9CDs1F;!d0s27F;e90l3;a50e1nFo10;!i28Fs0;i4o4570rAF2uEC5y19;!a72eEF5h9Dt215;!a1EBg2968l222An186Bp8Ar1As1C2Bt1v1C4F;!g19n3EEBr1s0;e365Eh233DoE74;!e17i279l1Er7s0;n386t112;i4B94l1;!r1Es0;s4Cz4C;e4i2By0;a20i425;!a39Be15i137Fs0;!b1E19f1620l22m5Ds1C7;!l160n28o1A7r9D1s0;!aCe1o3959s0;a51Fe0o29s3C80;t1B7;n4276t216;eAi6l1761t1C23;!f183i2D6n22r2D2s475y8D4;!d0g1E7Er7s0y1;a8nE;h509oE1;n0t11;i4y16A;!a21e11C9t160;a15D6e3D87i25DBo3C09;!bFBe15h28i2DFs0t58y0;p6Ds274;a456eE;a2C5;uB0;a32e138Ft5F7;c89Fl32C6m82p40F2r26A5s161w1B9;!d0l22mD2p10Fr1s0t2Dy0;g3AnFr0;b1F9;!n212r1D3s0;e3C9Dr4393;e150i6l2C;e5036iDFCy49A3;h66s66;!a20i3Fl7;a9e79o9;!e12f37i6l685s0;e1i87o29;!l485As0;o3124;!a174Ae10Bh10FCi3E07l3n22o173Fs576u4Fy0;m11A1o422tDCE;d71sEt2D;!e1i7D;!l7n22t48DA;a600e351Dg29i2C97l4364o3678s2Cu3909v4936;!d0f37l22m2En47r23C1s0;e0i279;h3Di4;t244;!i1E0l22m2Es3B07wB2E;gBnFr34;a1E9CeF19i206By0;!o241p1413s660;e4E6Ci1162;i5E1;a5EFi1A;!e3F01i5147l44o1F56s0y0;!e10Bi6l7m2Es0;cA5e1Bf1n2v3;s157Az3;a100i3E62o5033;i34Ao56t38;e3F3Eh28B6i68n89p3E2By0;a6Eo1;a1e22Fi5F3l5Bo10;aCe1364h3315i470;a4660e3B7i20BsA7;aD41;a465;e1F7i6lBo35;!a10E7e3DA4i27F0l294Eo2A4Dr3B41s0t18Au1391;eDs1A;e0i13oC;a50D8e159i4F1A;s11A;!a10e15h8Ai68l22s0y0;s2B;!s11A;!s2B;!b4E88d42BCf3FD6g2C19hDBkEBCl380En907p1904r2BAAs337Bt3C68w2035;n14BBs328Eu2862;aE19;!g9Em1E9n3AoBF2r992s0u601;!g1663s0uE8;e4l7y0;iB9Fo40;fB53;!a8BAeEi0l1Eo36s0u5;a36o3928p1Ay65C;aF4l1C;!e15i6l44o9Bs0u3FE8;e1998;g2153;!aDF0bC12c3567d1C5De4D35f33Fi4470lEBEn2770r186Fs2909t2FF3u1Cv2756;!e5i43y0;iF77;e3B81i1EB1o10;!e4hD32i6l8EAs0;a126e10Fo415uD8;r42BE;dBt196;n2Dp55t3D;!a4D62c3B6Be24i6l22s2ECBy0;!a7C1i12o508Eu12;c26CAg1510q499D;f16l1D40n14BDs2620t4BD2v27D5w53B;n25t11;mB6n189Fo45uBD;i701;t897;m3n71;!e15i419sC44y0;d1r10C2s8;eAiD9o12r19F;!e7ABi6l7Bs0;a799;g11m424n144;g4E;l1CCD;n3CEsE;l60t3AE;o1332;h0k5D3t19A;!e67g15Ci154Bl22;b100B;!a158e158f37i362l7;c1d217r2A01;o17Ey87;i2Bl2254y0;!r5Es0;t112w9;!eEAn3;!c226dE46n171Ds0t0;i3836y0;f7n0t14B;f7nE;!o46s0y0;i5t3D;o2Ay1;h104;!a47F9;b1059c975r16A8t1;!e4C34h104Ci158AoC36s0;oEx66;e2695i6;r808u59;b1Cn4r3375;g287;!g287;a33D0eF69i40E1o29u5Cy4E8;d1i2By0;a30e271i156Cy0;!s0zFE;e44E7i6k18u0;r421At16F;rFE9;i3DD4;a13e5t7;n19F;xC;a4347e2E0h4370i2614k481Fo1t1B62y0;n2o9s14v3;!a80e15i68s0w1FA2y0;a3B6n2u34;!e0rC88;c3AD9oCs3CA0t50DCy205;c0s550;r4B19;n2E67;!d0l1n0r2Fs0;s170t4353;!a1e0i1ADs0y0;a0n1E2tFFu14;!a12e3E69i6n36CAs0;c3D69d8CEf4268lABn4BB9s254t27A2;s3uB45;a22Ee5D;p1F9;o803;!e5l19;k1Es3FB;e0o29;n69;!a4Bd0s0;f19E1o0;r3612;a3433e4BD0i4D12o47C5;!b38Fe40i8El10AsA26y0;e2FB4i19C0m121o21p369Au3F9Dy2922;n1r28;!aCe449s0;m3735p118;eAi24Fo3807r45C;eEg1Eo8u9;e26i0o1;!d1B6Fe0l7t4CA6;!a1848b4BB6e2F0DfB0g3340h24DEi186Dl1069m2Ep4DB0r1CAs420F;e1D80o3C55;!e18r114s0u2ED;!e4i21l3s0uB9;i399mBn1sC5;r60s8;e10n464xE;c41t3;c2B32n467p42Fr45F8s4508u83A;aAC1;eAi21l3369y0;t148u10;!e9y0;m2E3;i4FDr266;rFy1;i2Bo165y1;u24C;!c9Cg2Ck47n89s0;d4F94l22E8rA5Cv1F54;!c9Co26EBr23Fs0;!e335i68l228u1106y0;!cB1eAi6s0t45EB;a3Ci95;!d8Be3C2El7s0;o355FwC8;h2FC6;i77y0;l16v19;e1846i6;e1844i6;!e2AD4i2B2s0u126;!d0l7r41;s9B2t1;a50e17y0;!cB1e15i6s0;e12Er280;!eC1i6s0;!a1i9s0u5;!e1f740n1s0;r425;h5CE;a4Ft30B1;d83t28;e7E;a2838b514Dc4501d1A75e12f1k3D42l1392m1410n235Ao738p4746r1A5Ds1E69tF23v1Aw5A;u2D1;a4770e21D2i3219o37F4u14A6y1FA4;a1DiACo12u49;!fC3p7Cs1FFt107;c92l3o9;c1A17f273CkF5Fl1B6En34D0r22FAs7E4t90E;t5D5;!g3E9Fi0s0u223;!b49Cd230e15f46B8g347h2990i450j7B9l705n0o49Ep32Fs425By0z525;eEo93;c1eDn2;n25DE;i232k186;u9E6;d9Et9E;a4D33e67m1zA4;a2B81i248;nFq7B7;m14AsC0t2D;nFt7v3;!iBl7s0y0;!i2Bl7s0y0;g370D;l5FD;a1e1i147Cy0;c3A7;!c3A7;!eEh4C15pE2t17E4uB4;u20v19;!e24i450o0y0;!b3940c1Ae1g7Bh1s1C59t5ABu29Dv26D8;h1453;!e6BAs0;iCw0;!e23i6o16B9p2E4s0;!aDA;m1109;e966h1891;c1476i2BDAr8ADy0;m24A0;a4B5Ee17EFi2B69o1A3E;l3808z206;e42iB;n3t5E;!n3t5E;s5w10;!a28A1e4998i4D72o3209s0u408y0;a1DnB7Ft3;b3CA;!g19s6FCt16;!b38Fd0l7Bs0w169y0;!a3228e46B2i32A8o6FDy0;c295CmAB2;b2D;!a2951e635iD9s0;e1D9Di1556l8A9n4C55o15F3v3;m49As85;o524;c3d286f190l598m424p4Fv774;a9t4E;i21o1E7;e7E6;r994;!e4C1i43u49y0;q7B7r564s211;a30e1F72i3451o42D0r25F6;y69;c2Bn40E6s11t2F78;e30n1CCF;a17e37E;a3C52e375Ci57o166Cr150AuE;g8FAr102;g9l39;!b1362cD3d24C8fF10l2FAp2667r56s25B9t56v58Aw655;s5FEv38;c35n2o10v3;!f1i2278s0;aCr19s1F;e183F;n1Ar26FF;!e1BnFs0t1;a1De15i6;!e5Ai0sBu4F;r85;n18o1D52;s312A;i90rEs915;!i45C3n0o46s0;h5AF;n0o9;d200;n3977;!c7i12E8s0;a1F2e1i0o0u5;a37EEb4918d3C20e3A08g1441i6kBl39DFmD9BnEFo1720p114Dr1861sCE0t234;!a410Ee33CFh3A40i17BDn75o1EDs2DC5t3C5Fy0;nF45o402s13B;a4E29;o3A5t112;a3F0Ce59F;!e0i39AAm165o15As0w98y0;l188Em3BF8;b7An825t19;l1n3AFEp1;b5Cd0l2A4n28s2F70;i4A5B;s5Eu5;a4BeC;gBw7F;!d0o507r28s0w10Ay98;!d0rEs0;!d0r1s0uB0Ey0;r18tB;!a113e147h11Es0;c92f1n2s0;k3A0A;!e1AF4;r145t1317;s1BA;!gAF6s0;e42C;d201mB;v1A1;c19e51m39;r229t11;q2418;b7Am1320s880t3EAF;m18r0;r3D6F;d4Bg3A;!cD8g44k5Fs0t157;!e680i4F;a1o65F;d0r60t0;c3Di15FrE3;!b1EC0c4C93e6ECh4DADi57Dl9D4n22s13Dt4041w6B7y0;!i4296s0u4F;!i0l115s0u5;e4C7Di86;!a4Dd7C2e15f37i21l638m26DBs0;a2F63i22D3o3371;!a10o298s0;!e15i3838s0y0;!p29s101;!a28Dd0f183l34B1m2Ep165s0wA9;!eB6Ei6o0s0;!d0i6l1CAp1C0Br131s0;!a4Dd8Be4gA10i4636l10As539y0;a3390e323Ej2EDEn4C05;a1A5r6ED;e4i26C2y0;c3B3h1Fs32CC;h3094;h35A3;r473;e20D4i6y0;g0i2EC3;a3DA8e1D22h219Ci2B99l2D44n2C0Do2469p2C53r1858s39D3t2007y144A;m74F;eE7En580;!eC1i91l19p4Cs0y0;eB68l4C7m9EEs4559z2ACB;!e10Bi21s0;!e597i21s0;nBr16u12;eDDi35o40;d38e1lBt339;eDCl6A;a199Dh4A25i2By0;h2A7D;n25r1tB;z56;c0e24s8;e265l7nF;o444;s1173t2Dz48;iB52s0y0;!iB52s0y0;k3n2t0;!i152o172s0y0;eFy0;e10B8;a10h5D;!a42EAe5t0;!l44Cn3F1Dr0s0w169y0;c38g227m64n11Br14F5s36t37CF;!s5;m53nAFB;aE94e421i61;!i53Ds0;!e15i21l2Cs0;a2992c2CE5d0e3046i2F1Ak5010l3C6Cn3431o4Fr3BB3tAEBw2AB;d3AA8g3641m38C7t1276;a5140e3D7iCAo73y0;cEp1;a21BCe21Dl21Eo3DD2;!nAs78Ex0;e33i8;d149n18Br2Cs28Bt4D00v103;!e433iD9s0;!d38r58s0;e8ECh4C1Bi692o909;a221Db4699e1570f3F86i1DAAm2FFCo1E6Bp32B4r73Cs889u4F;i41D5;!a15EBc254e30ABh5ADi3FB2o343Br2C17s2441t7CEu2AF5y3E34;b14E;a0eEi4o61Fu14y4F;e0i1Do10;c38BC;c213d1BECt0;a4A8Ci3DECu2C2;r1t112;a4Be67n2;o3A5;!d3s0t3;d0s3t0;!e1707i202Bs0;!a30e15i6s0;!e4i2B75s0;l4o1FD2r164u447C;a1e11y18;!e0r78t3;a6Eb4021c3DB6d3494e31A5g4309l1Dm16BEn3530o198Aq2EFs1A1Et50D9;d35i25;e22BDi43y0;!b94e14Ci448l3s0y0;g1o394C;e8Ci70y0;!c2Ao1s0u1;l3Bt2CEC;e476;a281cD3Ed17D6e3E06g2B95i1CD4kCC0n1E96o3A98t33D1u4CEx0y1A8;!e1i4A9s0;i5Do35;a4De3B21i21s0;!a4B7d0n61s0w16;a1BE7b3B02c1B45d444Be102Ef11Ag2257iFC4l25D6m21C3n50D4o2FD9p1049r3B27s10EEt2849y176;!e0l7s0;a30e23i6o3D8;i7Do29;i3723m3A35r3C8Ft5C;n793r45;eF1;a575;t48B8;i1FA;cBeAs698;e2D5Bh43CEi5BCk187Ao3246t11F9y0;!lE3m16n7s0;i6o6;e1iBBy0;i9DA;e29CCi6o12;!e24h110i6o283;l39B5n4D9;d55s55;!l12BtA9;sAC5;a4F2Ae3A54h643i1FBAo1BCBu1A6Dz3C7;o1B9;oB82;cEmD2;b8B4;h2B6Bk279DpFFt728;tC9;g133n0;!i6F2s0;h447BiBA5;!a369e24i6;a2AA1b21B4d1ADEe22FfEB6gC4El1B10m2F4An1500o1186p2CE2r2C10s16EDt1199u388Cv1A80z3D15;!e15s0y0;c34E8l221m2A08n389Dr2E64;i224l205;e1Di3290y0;g41lB;r14A;!g356z3D48;a23BDe25E6h2479i6n307tBCu1E2Fw98;r3F;c0o9t3;!e5n2Bs0;!a1DCd0l34Am64s0;!a80e15i21s0uB9;z216;r4585;i3995o366F;!e15i21o29r7s0;e128F;a9e5o2CD8t5E;a2CB1e491CiF62o287Cr1B11u31CA;!eAi6p4A0s0w169y0;!e5h27s1F;lBy130;e4i6oC4;!e4h16i6s0;a2361e239i6o73;l39n39;g241Ft1;eAo46;b0s0;!b0s0;!e433i6;e1t256;!d0s5;!aCg1i2E49o50A;!l617s0;nFv48;n85r1;a1De429g2CiBl44o56;u206F;d213g2CFCn334p46s85;a1D7Db1E1Ec4E6Dd30BFe4A94f1BFBg2FD3k20F4l1EFCm2ECEn1F75p2758r218Cs16B4t42A9z1BF9;!e1CCy0;e1f108n2;!e24l7y0;e477Di7D;s11tBC;d0l13Fr1;!aF4i1Dl16;i8BC;m2D8D;!e4s0u5y0;i13o36;f23Cn312o2A63t3;r46D2t88;e1t1E;!eBi21Al257Bs83Fy0;h2Bt1E;d0m18r1;dBn20;a10o3DCu10;c5AAd470Ee559l348Dn3ACq2814tE1Eu427x4BE2;dBi1;d71Cg5Ck28l875n196Co44B4r2BEFsE0Dt4D80;e63Fi6z187;!a4Dd0r2Fs0wB2Ey0;iFEo94;e4679;r513F;!p5D;!e13D7h5020i32ECoD7r2DDAs0;eB06gE99h3299r1137;!w3EC5;!f6A3s0;e26i448y0;!a4Be119i27s0;a3089eAi4CF3r2CE3uF1;a4B7i3F;s105t7;d0e4;a92Cc0e5;b7AnF;i4D26o12;!i5B9s0;a41Ek5F;!e15i27C5s0y0;!e5i6;!b1DAe431f2AC0h1B96i3262m2Eo2156s0y3EFE;aD67i11F1l1n70Co31A0;h249;!e24i6m4A2o63p4C;d0l47s0;!a497Eb1C4Bc3712d2EBCe1D12f445Eg1F2Ah35CEiFD6j44A3l384Em1E5BoED9p2496s3BE8t3A21u4454v2C68wA9z3A97;!a2744e1ED4m8As0;tBA;!d0f37l5136r8Ds0;!e23i21p2B1Fs0y0;e23h119i68uDy0;c319Ed177F;a59e94i67BoB7D;!m1n1;m1n1;pC7;n3611o29;m677;e39CC;!d3Br249s0;t27A0;!e67i68y0;c58l378m1t33BC;e23i68y0;!e23i68y0;h3E4D;!e4i778l669s0;!a1F77i70o28s0y62;d0r0s8t2F;!c4DFe929i15AoAFs0t409D;e33i5t1;r3319;h4949;aD01e5Di1E;d0m3r1s0;t3D4B;n4769;!a1F50e498i4573o1BE8s0u4F;!o2C77s0;e15i43o54y0;!a0c4A8Ad3012g1A0Ai39FEk4C6FnA21o4478r939s0t2C4Ey453D;m3A9;p16t7;i3Fl2C59mA4p4F1s1E95t6D6;!e191i6l2C;bB7A;!k2C5FmC8n48ACs0;!d3n0;x1B95;d1i717;!c160d0lA9Cn22r0s29E0t201y0;!a450Eb293c3008e21C0f5ADh3E63i34A3l7DFo40F5p3711s1F48t1605;n25r301;!a4Fe2AC2r3BEs0;t389;iACo40;!e3E9i6s0;!a4834e2E7Ci1E31o10s0y0;l8E9t4E1;!aA3e4i21p3CBCs0y0;a3EB;e4461;r618;n3263;h6E5;u2CC;a10l77;r1BF;a4A20e1ABFi25E9r1E93t50AFu3997;i9AF;!e0h9Di34Fy0;!e2D58f37i39Cl1FEFo1p37C0s178Et15C9;c9Cl11Bs1013t28;d3B5C;!s0t120;!e4D43i10;eAi6t0;a1Dd48i408EnEp21A0r4F56t324;dBi4lA8n1s16A7;!n161s0;b1eA;aB9b89d2F5Eg15ClBm1E03p21Fs1BA;t1D9B;cEl1Dr3E39t3w19;b7An2E7;c457f1g4An2683p2A60s44t1A2;!d0l4369r1s0y0;e482Fi22D;!n185Er1AFs0t3950;!e1s0z5119;dA1nFt2E08;o10rA7;a8u28C1;a2F2e3Fo36;e17i21o4C12;l274;a0i13u14;e24F6oD;eDl2CCDr3;a9d3A7n0r13C5;!a80c44i25rE2s0;a20o862;!b377Bc4ADd0fC3g796h7D4i6l15ACp97Bs19C9w5AD;!e15i21o1B6s0uBD;iDl360En1E5r3117y142;s3A7A;rCB8s3u4CEC;d23D2eAg1B8i419jC8k1y0;a702e9;!m1AsCD6t107;!n11F;h3172;aFD5e12;a33C5b4E10c25B5d2577e313Af4D7Eg36CBkE3Cl4BBDm2394n4876p4D2Cr3546s1DFEtF14v38w1DBx1D95z44E8;d28sBC;!e4i15Es0;r820;h468k39;a1b102cEA6e46BEh30CAi37F9k40Fq122s3A2Et1D48u4BDF;!a403iBs0;!c193;a2EEFi2Bo40C5y0;!cB1d4A1f3CC1g2833h1j37Fk16E3l35F6n371p28r1788t28;iAEo74;e0k1lBr3471t3682;a2D09l19o565uE5;c1n3r1s432;!a12F4e3F48iD72oCAFu51Ay503B;r25vBy1;!c9Ed9Ee1AB1g911i1971k9El42FBo3F85r22D1s0u604vD1F;a2Ad0e4;n246D;e1C5;d42El3Bs2D;d2C0k1B9Cl102r2DF6;a341Bi223;i278oB38;rE1;!h34DAl14As625t48A3;!b1D2c1E1e84i6l22s0;d3B3l34m2CCCr347B;c0eB2l7;!a2C39e1s0;b1Ac26CCg38C9l27E2n180Fr1438s4E9t2E1B;s474C;!c64;c64;i6A2;i3275;o20A4;!a1439eA30i156Fo32FFr4686;!b7Ce1A65i4D7l1DDBs0;!a30e4i29Cn11As0;s2489t2D;!s0w28;e46CD;d0r1s5Ew0;i1D0;h217;!e3o6Bs0;e15i4D9Al44y62;e150i86l219o11D;h1Fu2597;h4A53;e3E80;h1i3D38t31C8;e6Er19;h196;d4AnF;p36;d3t189;g215Ao1;l16AE;m2B28;!e15i6l19s0;!e0g3E18k1B8l7n3087s0;r60A;a42F5e1i5p1AF;n2s405z3;d3F7t889;e805;!t4FA8;!b2DDe1l7m28F0n22oE7p24FD;!e4i6kDBs0;d0r1DFt1;aAElC;i70o2E57r22D4y0;a2E22i248;c18eA2l7;e5F5;a7Ei3F;n2AAs8;a300s2949;!a24D9e2DD4i2314o4DA1p3F00r3562s0u1D99y3508;!a453Ed35C3e2942i3CE8l160nE83o2AAArBs0t3A8Bu27C2;!b1DDeCm3485p2233s0;aE9e3EBAi30B8l4659o2C14r26Du2FD7;n2r35;e2001;aE5i1193y0;k2Bx0;e1C08i6;aDF3e344Bi6o2DE8u3A0;c200p134Br5133;l9Fr518;i4s55;rD6uC;d0l39;!d0f37s0t20;!a87dB3Af2AA9i13m415s0;c2A65k56t5E;!d0p1Er1t1;a10e349EiB;a42C8;s6FA;h88s2C;a105Fe42E1h117o1A11u17;c0dBn179;o14CF;m2443n3AEE;d0l1r1t16;f37;a467Ci18E4;!d0e55Fl32Bm2Es0;!a1e1Bi31l7n22;e3E9i989y0;!a90e756i128As0u3E4F;l990;r28C;v1098;!e4i6o28s0;eE6D;d0l5ECr140;a4Bd39;e335i21;l0r25;e1t3374;a87e514o51;e204;d573;!a30e0h38s0tAA;a1Di1D;!p189Bs0;o248F;g0t11;bE7Be3B37i25k30A7o34F2qAAEr3B5FsF3;u3F88;a1De294i6o12;a291d2CB0e0i340Bm2861n2839o4EFAr1213s245D;r7s0;o2B8;d14Fg96t1z19;e12AFi86;aDd3oE;aE92e6E;j0;i3Dt7A;d0e1r2Ft20;!e4i6l525s0;l2D4Cn124CtBCD;e359i148u158;y81D;a49uE;i267E;!e0i3247s0y0;uEBA;k0t11;t2B9;c3DnF;d2De5s2AC;g136;a5EBeAi23A6t5A;l2253;o223;a45e14;!e4t11;e313i663;eAo1;aCn3u14;i2Bl2Co73y0;h297B;oC7r88;e12l2C;!eAi6r1Es0v19;n3813;a4A0Ae2079h60i1A5uB9;!a89Db368g3996h28s0;d1g1E;d0eBi16F8o50B6t38;!e10;e1F4;l1A2t451;!e1h78i3234l75r22s0u3EACy3B2;a1B3Ce1DE3i35EEo4513u3730;a1o28;eC21;!l1E50;g269s402Dv27;e4F2h2896;nAE8t0;iAElCr3;aEe15i2BB5;d1708;b1ClFB1nEt517;!e5t802;!e4i6r247s245;l181n2056s102A;a234Ae1i3A8u4F;a1e1B88i352p1DDu5C6;!r874;aECAe0o3C4Au14;sC0t3822;!d0l22r47s0;e5i5t1;!i6w311;f46C5o49t1u0;o1s424;l21FD;iA05y0;b0g0;a1A4i178u9F;e15i1C7Dy0;a1e767lCt1wAB;cCFe24;!m1C86s0;!a2848d28FDe5116f1FF8i21lC0Cm250Fn22A1p207Cr48C0s0t1917v4498;t75F;mBn1Fr18;i11D;!l1Es0t132;d0r93B;d2A5s2C;a4D6g0i3F;a24D;i204F;e28F8i18ED;!e0h1E6Fi0s0;!a2C2e1462iB6s0;a33C2e1242g28k28o333Dt41;!e0l0tB7;n4Bv55;k7C7;n18Dt14F;r705;e6Eh9BDr63;a1AC0s1F;!e4m2D3n1A4Dr13Cw9;!t360;a25l1C63;!e135rAEDs0;f19v19;!a428Fe4h49ABi21k7C3o0s0t3B2Cu1CB5;!d8Bm2Er0s0;a173e23f23Ci6l1BFm64s1Ft2F4;n3Ft7;b742d182g21DDl1924n317Er1F8Es4C06t1E04;!t628;t628;e18i13EE;bFE7c330Ed2C04e41F1g1E63h34EBi34ADj1FB2k3DE8l3E71m3B0Dn14F8o4208p3586r496Fs38A3t4E61u250Ev208Bw487Ex16DDy50A7z4E1A;l1AD;e1oCD;e1o29;aBDo176r367;e5o29;n18Br26FB;!a449Bb5FAc3637dAD3e289Ef184iD51l17Dm2685o8AAp4171r2EB4s1F4Ft486Bu5Fw3A8EyC2A;!i1A85l7s0;c2BsE;a3A1Ce3B25;o15A;!a78Ae3EDfB0i34BFo23Ds0;tD3F;aD0AeD1r3CB0u124;h27p6A;!e3FAiA1Ds0t1EAw1E44y0;eAi1893o4F5BrEB;!eC1iADl7o1s0;d627;a161Ab1491cD39d1F09e4D11g5038i1D61k1l3A13m1o474Fr147As742t2AD6yED1;a3EC4o1251;e10DnFt29;!d0l1445r1s0;o1Fu34;c1383z3CB7;aFy0;n70Bp4988;!eC1i6l2A8r4190s0;c510A;e17i43y0;eAo9;l2AAn1;a1921h38i20E7o4882t2629;l25EB;y34;a1885e4FE0iED0rA70;!e12Ef37l2Co0s0;u168D;a108b94Ac7B4e1F0g0i3C14k50E1l199n2D45r4313s71At110A;i13Es2D;h36F9;t3B73;n148;a0n2u14;r1CDB;mC9x4C;g96Ex1F;n0sC5;iAA8;e1u34;!b68Ec5076d3D04e1g2B0Bi4652k30D5l22m18D2n4054s388Dt4510u3B8v1C83w112Fx58y339zC0E;a1F4e1;a10e5;!a10e5;e1Bn2p1EsEt29E;h2A1;!f37n85r1sEC;!l0r58s0t270Fv63;iB8B;!e4827i6p2EE7s0;e5o101;a65i59u10;d44g25Bs493v551;eA36k2322oF6;d219Bf430Ek1308l2846m1275n4413r11B7t2C2BzF4;!a51s0;r50F3;m34B;a4DeAi6;eCi385Co12u49;e5iCC;n48C;a4F7Ee72i7E3l4C17o36D1r46FEuCEB;t9DE;i400Co3CDu5;n121r19F2uD;i31o2105;!l1E;h4560k2A67o1t4279u5;!e501Bi6s0;d0t139;!a916;e18Bi2EF4;b2DBEsC5;a136oAE;!a9e21E2i2217o1s0z2C9;e6BAi43y0;g3w7F;a2B43c263Fd4234e10f1232g2E02h3AA0k2D2Bl44BCm2F6En2398o2606r47C3s3ACBt10C6u36AEx2A82z3C35;eAi6t568;!i20Fs0;!b933s0;a660;a2CD9e3A52oE9u275;a2174e190DhF7i507;!e4E63g3D97h11Ei19Bn145s0y0;d3Br1s0t389;e4s11;d0n197;c2F2E;a170;l3t1;u50BD;!i297Cs0y0;g1D6l0;!d0s52;a2CCe30iDBD;i1006;t2626;a301i4F;!e635i6s0v5A;uCFDwAE;!m7Cs0;g1EFAn3r7;cA2Ee67;t12A9;!e4i6oEs0;e428Co116r4C;h2C;!e3i1s0;!hAF;e15i27lF5y0;r190Et174;n2t5A;a1207e4A11i1342l4E1Bo1E4Eu3083y3F8D;aB9e4;e12i7Dr46C0;!i21Al16Dm2En22s0t46Dw2189y1443;eAi24F;r30F;c0d1n3t5E;!e4iADl1182m5Do41Es0w30C;a284d0r16;aCe1i18;g82i29D2r3A;c35Cd439g19E2r3FC3s13F9w47z176E;n416B;iA7F;a20oE7;a45A5e249Ei2672o10AFy7B;eAi1700mF6;!o9y0;e28Dp34A2t1;!c3568eAf3885g96i6j1E2l264An29F9p28r1936sF3At2F11;!l115r7s0;!e15i43o1Fs0y0;!d0l1n0r1s0;a1e1o1;!a10e1g35F2i4028lD77o233Es0w311y0;!a20e4i350Es0;!d0s0w244;!a3312e4iB8o55Fs0u310;i13l0;!d0r641s0w7Fy1;!e1i1175o1y56;!k28l49E4p2D55s0;n1r1D9;a2000;h46EEi1DlCCm2718n18FA;!l38CDs0t4DE;!l7o12u22D;!n31s0;p46;eAh9B2i6;g25BoE8r3uE8;!a80e4B3i2DFlBo1s0y0;g4C4Em941r1DB5u34;a4975e4B8Eg3i29Bk1m44Ay62;v6CC;r12B;c31A2i454El4765m4C08n4F9As4B5At2855x168;!e1g60s0;e8Ci3Cy0;a365Fe221Ei343Eo5109rDu36D7y1490;e293Bo46r3AF;a1696m38Cn4F95s13Ct21F;a264i18;e90i9B3;a1A5CeDA8i478o1B76u1A4C;e4iA00l44y62;!b633h1r196s0;n949t1;e12nFo2FC;r29Ey1;c321rB;m8ApD8r2A5E;e4i6lB;f542;a1F2e202i4946o3979u4F;e3473n2;i28A3;a1084e1C71o1B4Eu1;c1D4Ci3C7An46BDr389Av1Ay5D0;iCn153;!a3138cB1e5h1BF6i30AFr1A8Fs0tFBBuF43;!a39F;nFs193;!e15i6s0t1E;a26FD;a16Fb368Ac29C7d5Ae1f46E0g233Bh2899i4F6AjC17k2D9Dl332Am1FA1n2557o2760p1EEAr41D4s2A7At40F4u326v2235w28y1D4Az3C2D;i5n65;!iAEs0;!i8;a693i2A97;!e67i70Dy0;c4EC2g4Ar412E;e429l3A59nDEo507C;!eD0i68s0wEDy0;d0rB88t1y19;i13y1;r3s9B;a3308mC8o4628sB0Fu1Aw1Az3320;d287Fg44AFl6CEn3ACt4798;n3694;a1C8Ei4A40o56y47C8;l5050;e4i316y0;l2B9D;a10e350F;k2761;!c6Af5Ds0t1;l1y1;!a2B33e5046i3C58o174Es0u3B89v22Cy7B;aCc1s14;a0g189;h20EFo1;!cB1eDi49EFr63s0u3B4B;g374m173n28Br28Bs4CE2t1;a54r6F5;a99Fh5AFl37ECoC7Er6DC;d905m533p47;l30F8;y429;e47E3m18oB9;e16DErF34;c7g19;b16D1;!r3B1;!d0gAA7r1DFs0y98;b1g1C4k68Fl28p229;i45o6B;!l6As0;a16e40i4648y0;!bCFCg15Cs0t56v58Aw655;!l10A;a4CF0i8;aDD2n423o3D2sD1;m7E;l2Cu528;a20i0o36u5;!aA4Fe4s0;a6E9u6C2;i3Fl2E6o29s0;!e15i21s1C7w134;a126l1BEs0;i190l6As2C9;eAi14;m1656n146A;!r35s0;n1s9C;n2FDs8;!g118i97l1;a1BB;f334Al2BD;a1i18y0;!e4f37l22s0;!r950s0;a253e3E99g44i503En1E2;!e0l1r7s0t3;e1nFs2060;l41Ar231tB7;!aA3e155i68l44s0y0;c2041i35k3ED2t2Dz7;e12i5o1y0;!e12i45Bl2Co73s0y62;d1m1o3C;t907;a503e90;m101;b7An77;r1E11;!b7C3e3011o5Cr20B1s0;a4Be24i6;rB09;y4A34;d1Ei6mE5n1;!c9Ck140r28s0;eAi44Ey0;e5s2Cz2C;!c4E84f1gD46k0l28n306r1s43B1t58z1744;a1701b41FBc4411d16F0e2C9Bf39Fg4916h440Ek199l45ADm1211n3DA2o47EAp35ECr22B8sD14t3509v2379x22DAz29AD;d1g35n3r61;e474D;a5100e4D36i5113o1F9Bu4D8Dy3296;eB6h44D;a54Er2C;iC8;i1At109;e12i97;c7ADt47;!a1F6Ed2263e4D57i359En2595o11ECr4E74s456Et21C6z8C7;l2BrDA;a272EtBu34;d1l1D;fB5nFv3;a3D24e429k47r28t140;n2D68;n1p8;n4875o37BAs2F9t4A;l545;m15E;l3139m0;eFDi21;!e1B1t25E8;b25FFc2Ad42Bf4FF3g48A5zA6D;e771o12;f1B29g3F0Al28nE03r0s3232t1065;!l3BnEt839;s7F;l3Ar1;c193t1;e202i6y0;!b0cE2d301Ck40Fl353Cm41B2n1ArE4Cs0;!g60s0;a41FEc32E8d4C82fB5Fg3EF4k3FEn1806p3CFCv774;a50e50;p2C0;i5E0o4C3;a188i27F3;f330;i65u5;h127o5B4p1BF;a880;e1D1o9B;a146lFBo21Dr21E;a1h1A;aC7oA0;i20Cy0;!a3198e17Ai6o10s0;a122Bo0u4F;!e5i5Ds0;f2170;s36CF;n0s2C8t7;n2t58;d0p0;s7t2D;!aCg0s0;c64v63;l16n3F7;b168c2Ad4780e1f2Cg43D1i49EEkBm410Bn47BFpD24s5t4427u4B3Bv4E14w2D33y47;!b2A0e15i71El7Bs0w1BCy0;!m29;s4CAC;c9Ct5B;a47AAi50A5l4542o32FDr230;!e1D0F;e282;e2C5;a4C8Be2BAFi390Do1AABu45C5;!dC9p35;d1C53f3F65i4924k20Dl5E9n1933o4ED4r2630s193t36CCu11F7;!n56Fs0t2Dx3837;aCl3m0r3;a30iE8o85r201BuBDz3A;!gBl3269s0;t849;u2A;r1B7D;a1d1i2By0;s3Dt3D;!fE5h110l6DpAAs93Ew134;!eC1i455As0u34y0;!a2A23b28E3e21F3i2E82l75m1EoD6Cp3295s30EEu5;!i1F3l7s0y0;g3DnCEr26D1;!a1b4793c1F15d488Ae4B34f4FFDg1F5Ch430Aj83Bk44l23AAm1FD5n3617o13B9p2520r23F7s4FF2t2BCDu423Cv461DwE39x1EC9;i376;e85B;g0i0o0;c167e5nFs27Cz19;g3n289;eAi3F5;e38A6i396D;!a4C11b20Ec9Cd6DAe46CBg3BD4i17E3j8Ak28l22n448Bo31D1s0;tAE2;!r8Bs0;b38AFc394d2321e2D19f3CCCg74i17Bn25C2r45BDs1BC0;aEn3;a9eC;!e17i2B6l7s0;u15E;!d5D3;a4850e140DuFC2y3E24;d38t47;eAh66i6;h447;n82sC0t2D;!b42DtDDAv857;c5Cd88e5fF2o29t45F5;e2043iD76l3y0;a8m14F;n424Ct1D56;e4B3i68y0;e1522;!c168i31k8DDs0t17E;!e39C0i6k939s0y0;aD7;!aD7;gBl3B;a1cB1l1FC6;!a136eB6Ai68s0wBFy0;!bAAi5Cl2560s0;!r60s0;g328;!a4De44C8i6;!r28s0;a315Ff3A19t0;o40u49;!s0tD8;a143Db43EFc4FE3d40D5e2179f1309g3FB7h1i1C49l3C73m2040n11CDp440FrE0As2ECCtED3z3C1B;iFDA;oBD;s5Et35;!i26Es0;a1E75e117Dh47F2i6l1179q1528s337Dt3B;a589o46;b4885d19F6f46AEg2D9i49k3521m30EDn1811p291Br16E9s125Et5Ax1F;aA3iB8l578;a4By1C;i7EEn195;g374iB6Fs3C9u21Dy47;!e4i0lE1Du211y168;!i6pE;aB6Bi27lEBo570;!fC3l1Es0;c4Al13FnCE;e4i1C0y0;n19FEr40EEw0;s38Bt49;!a3CeE1iBo73s0;c82l1A;n2t61;i31A9o0;a20c3Du14;e3C1Ei2A03y0;a4D17e73;a48D9;eD3i4944;c4B72e113l4775;l2Dn4680x1ACy1;!a95;e8i2By0;o40CvB;c92qC2;a3FA7b4C96gFi49m369Dn51Bo269Ep1r1E56s504Bt427Du221v44w30BBx449Dz6EE;a36e1i4F52o3513;!iDC;e1B79h44Do21DB;!e1Bf37i3Cl7;m21Cn1C37;!b42C4e2535f33FiCA3m26ECs0y0;m14A;a34A0e52o1E8E;r2Fy1;!a1Dc7C6i9o10s0t48D3;a173rB4;a20e1i5F9y0;d0l1r2F;g277l5122n36At1CF;a362Ce193Df2CBBh5082i1409l161Cn407Co1581r302Fs1992t1A21u15BCy3A11zB1B;a21e1;!t19;c403AlEm1BE0r7;r1435;a87i4D7;k1l1;d4B4A;a0f2C4t92A;!l185s0;bA0;e17i4562;!a21F2m0n4A04o41B0s0;b476;e63Fi6o10;d1D;c7d148t0;!aCe13FuB9;!e4i7D3o51s0;!g4A0p177r14D6s0;!e4i317As0;!a4Dd0l7Br1s0;a87i1652o214Bu2094;n1A58;l3880r4DD;c78Bs0;!b1Ci4l1w0y1;d0e1r1y1;aDi0oE7u5;!h1BC5p23FEsCB2;r3s11;a20i7D;e135i4B8A;o1979;e6Al7;l53Ao3B1;n0r2F;a113e1CECi6;i4BA8y97;n87;!a4A05;x55;p6A;a255;eCEl1;a6Ci87C;h5F;!e2E20i68y0z2B;!a30s0t1;b41C3;l1DC3;e1Bk3;i308D;eEAn12At3;r3622;e24f7n2;!e158h1i37F3s0t4EB5;e15Df37l7nFs11;aEc2880d833g3751m4E30qCCFr2885s0u30;a10r5F;kE3l39;a465o3FD;aEC6o490B;!e15i396As0y0;c7s7t2D;aEw39;a1bC6Dd0e2B00i21l29EDs2075t43CDu23F6;!a4Db14Ec380eDB4f37g356i2A06p358s593t1EAw426y0;l195r397;!l3220r107u4F47;e3317i194y0;l1684n438A;a0d2919o9;iE8m1Et256;z35DF;a126e20F6i46Bu6CD;e15i21y0;iAE7;a430Fd34Ce2C6El1989p1C9Dr41Dw9;!k46;a12i1ADF;!a422e4E3Di6rBs0;c11Ei18;!e10Bi6l7sB96;p4FE8;e24A4;!e3FAi6s0;!e67i6y0;e48Ei6y0;l3o9;!a488eAi68y0;!a5B1i2575o3EBs0w2A2;a9m3w1;a59e17i20CAy557;a379Ae5138i36EAo1u1448;w517;c117AgBlF4sCED;o579;nED2;e327i548y0;cBe24k5Fl259nF;!d0gA10m44ECr1s0wA9;!a208b160Dc24DBd246Cf4F8Eg3BD7h2C56i210k389Cl4C2Dm2455n41DAp1FB4r2D07s3CC8t4390v27w4CB2y98;p37A;!k8Dl19s0;c0f31FFl7E;aA3e24;n68C;c8n2;m517;i647;a1D7;!a2FEDe883l8Ao124p252Bs0u1A0;!e4i290s0;s2B9;e48Bi1FE4s35;!e327i21s0;a25e17F7h1897k331Bo4654t3EB7;i4039;!i148;l408s1E39;e31i31;!h0o10s0t1E8;i32E;!a432BcA95d42FFe1CC1f493Bi4D0FkDEl425Cs0t7F5v2437;a379;iB7E;d3Bn1r1s0;e23i1E24t38y0;!s0t167F;f278l56;d19Ee2C54g5E4;m148;a5063c33D3e1C17g4A18l245Fm68En3574o151Fr224AsC80t21Fv89;!n7Cs0t1A;gD6z19C;aCe26o9;s3CC9;!e349h31E7i38s40AF;!e0l1;e0l1;a4D6i6F;a5Ce0o143;e5C0i21;a4Be5E8i70y62;p4F3;n6Dw7F;!c329Dd3687l1n580r3A3Bs217Bu1A86xAA5z82;y12;!cD3e0r2C4s0t215;a54Dh40CBl28DEo345Ft13A;!a3190d4D8Bi3Cs0;l3m1;i6n70F;t16C4;a20u34;a281u34;!d0r58s0t1;!z3;d3CFnB;!c4A66e32ADh13ACp2CC7s102Bt1E5C;o8y0;!c35Cd1AFl1n3570s2A7Bt28;!d0m64r2Fs0;!h1l0n65s0t0;h42C0o10;!b38Fc109EjFBl3349p208CsECEt0wBF;i11Dl4E57r29Dt1FC9v3;a15E;k19tEE;aB71;i4n4y1;!b4DBs0;d2Fi4u5;a437Cc285En112As3CAEt4EB;eDn1;nCCs11u14;!o3D5s0;a483Ce4E1Ci105Do93u45D;!e1Bi3Cl7s0t7;eFDi6F4y0;e8A0;a4C6Ab1B99c2B74d1135e1E18g32C0i374Ej3ECEkB63l387Fm500En318Cp472Fq2A3FrC61s2AE6t1020v498BwE76x121Ay1;!c53e1;e2B0A;!k1Es0;s307C;r92;eA1o8B;c3n48;c29nB4C;!l2A4s0;c0n7E0s19z19;!aCe17s0;!e13D2y0;r2BD;a116e1iB81o2D79u3E1;!a1AC8eBh1041i374Dk2Fl407Fm4344n1D9p1r1s4C0Et296By0;e12h1;eDFu9F;!a283Ce294i4C39o3DCrBAs0u456y0;!a4008b2A57cDBeF72i3359m44D4oE7p1E6Cr12Ds2D4Bu3CEC;e17i8;c85i2E15l1F8Dn2894r1B64s2CC3v46wE1;e24f11E4v3D;e1582;r6B1;!a128Dc3d3A6Ee14D1g3271i7Dl22n28D9o1691s350Bt293;!a136De2585i2D1Am2Eo73s1C7u842y7D1;l2ADC;!a0e1D7f42Ai3ClBs0;a80d3Al64;!e1F8i125l7u49;aD54b34CAc438Cd4571e1A73f1686g28A2i504Aj851k2A3Cl44FFm1F44n32BDp49B5q1r442As21BAt432Cz1E4D;m10Cn1;e1iE6B;a1i31n3t3;!e6Co223;o0s0;r2722;a13u5;e4By1C;c3E60eDDt0;l28n54Bs88;!d1Ae42s0;l145s13B;k3D54t126D;!e1i1C0o10s0;i4y1;!l53s0;h28DAi3Al3;a4BeD;!m2Et6A;iA86;aCi3D;!d38ADi18B2l52n3E4Cr64Fs351t9Eu90;a564;a237eB8i1201;l1r196s5;!a1004eAi24Fs0;c0d3;e221Ai6o1A20z49B9;n50F6;aCc0e5s153z3;w98;!h44DEl7Bs0;e278;!b337d7BeCE5i68l36Cm2Es34B3y0;!k0o0s0;a8s5;!a4Db49Cd230e15i6sA26;h1i31;e1hFBCzAF;l2207sB;n43FCs288;c2Cd2C27s0;c92e1Bl7nF;f1m28v1CE;lA8n58;!b1EeAi6k16r1Es0;!a281e1F0i225FoB02u2F6F;i72o3C3E;a2784e23i6t1A;e1Bn22As11;e1h806;c2559e348Cg1AB6k30A8n121;c2F7d3FFk59Dm5129n119Ds13Ct0v8FB;nC6B;!aA83b1DAe3D17iC5l1823m2Ep2BEDs0t9F8;g397Fn1E08t351E;e4555o2128;a4Ai34;!e3C2i6l7n22y0;e6Eh258o50A3;!a3Ce4i142Al7Bo0s13Dy0;a0i13o9;!a0i13o9;a12i2By0;!e22C9i6;a1i48F2o1963;k1CBl2FE0r3AB;!aCe1o2703s0;m3074n52A;e76A;t3A9;!m41s0;eBAi334;!a4219e3596iEE0k5Fl4591m481Eo4869t4DEFv1C04;!l259s0;m23B3;!a10e1E98g30CCn3F7Ao35D6s0u8F;!a16D7c45CBh1BFAlAB6m1BACr40E4sA2At2506wED;!a1F2e4i2D94s0;!e5g1s0;!h27s0tAA;o2902;!c4C87e33A0i3CE7o4BC8t33F5;e2CF5h3Ao1;m4583o5FFs0;tE1F;aCn2v3;l88t1;i3C1l11Br217w38;nC5;d19n2C70p1C;a40i20o506F;!d8Be1C1i319l7s0;n4s3;n2tB;n2t2B;!a4Be10Bi6l7s0w7F;l38EC;!l7n22r16BDs20CE;!o4D5;n8t610;e151E;s3t3z3;o1E5A;!e12i6;eAiF9u49;d4394;!fC3lD5Fm14D8p3E12s0wA9y98;e12i8Ey0;!e12i8Ey0;!d129Ae1f37iDA6l7n22s156y0;r8B;a4Bo12r19F;iBA5;lB31n5;d3m7;d88fBFt1184;!i498Dl44s0;aF53e5i148t7F2;!a1e84i6s0;i8m0;e8i13oABu14;d3D2Fn14DsEt1;a3F18d0i2BEl3CFr770s5E2t1B30y5007;bD4r88s506;u4D6D;!d0f37l4C90m64r1s0;e55;sC0u5;q3453;b4B02c427Ed4748f268Cg2D9k321Cm245CnD6Fp4DA6r2B51s3t48E5;c235n14BCr2F21s85;!e0n0s0;i16Bo56;!f4A7l10Ap5BAs85F;a1F6Ce6D9lA5o262yC4;a2310o4Fu72E;l466Br4y5;b43BFc3385i36k1l121m3n243Cp254Fr38B4;d27n39;o10s0;!a4Be15h2A0i194o4F5Fs0y0;h39;d39s3t60;h349A;e5n2s3;e4fBFg25Bn0t64;r2DB1;n2r34B;a305Ci103u13C4;i4EE1o46pB6u5;s9CD;l592;a124d149n7FAuB0E;!a1DA5g2008s0;!aCEc13E7e6C7i17C0l7Fm30C9nC40r4CC8s20F8t130v3Dw6A;!b1CFDc2B89d3CB9e48A1i3C08l4C7m28A5n4D98o4013p9C9r3DsC8Bt4EBx1Fz4BE5;e1C7Bi21y0;!i3Cl7s0;m4BFC;!i25s0;k37D5l47n8D5p124t31D7;f13ClAB1r15C3v7B;!a188Fe859i21o116yF84;!d6Ag3h1s0;a4854;!g297hEs0;u31F;eEo10y0;!a4B80eB2Ff873g3C60h129CmA95n22oA3Fs0w356;rB7B;e34D8i1A55;e12f27;i338o2B4;a4ACiB81;!c32e24i6s0;t40E;t15E;!eC1f37i86l7s0t1;!d3Bl7r0s0;o497u93w1;!w868;l28r1B8t1A2;e30v55x1F;!c3F7Ee1Bf2Dn2;a1F8Ai3A9Eo1F9F;aD8r33F;d3F67f16B5;s170;e4i194y0;l2A2F;a12F8e17;a3i41;c47Ai25;h1ClB;o650;!i3l225o49t353;t8E8;r1F36;nAC7;e9iBo73;!pA5;c1AE9f37D3g41A6i42AAn42AEp304q122s1DD9t11D2uF11y2449z1A;!eD0iBEl22s0y0;e8Ck5C;l44DF;d0l1r1s8;!i29F;t33C4;e1s51D;f15FEv2B;r5131;a222Ce23i68o11Dy0;l1n1Ep35r7v19;!e1C5iD69;!l1An1s0;e1i3C;g117F;!e12i4A6l7By0;r50A1;!i41l53s0;!cA41f3B72n3ECCr92Ds5067z2DCF;r71t27;l2143;a298De3D58i4C24l29F1o190BrD6u788;!e294i6l31B0o10s0uB9;!eDl7yC;a4D3Ae1E0Fi4D8Ao14FDr199E;g1Cn1E;g389tB3;uFE;!d0lA9r1s0;nC95;i61;h18B6;u2E93;!b1Cg179El1n65s0t3;s193;!e4i6l219s0;d7t11;a59o99;a2F2e1i16AC;n2o9u14;!n0r8Ds0;lABA;!dCFs0;e923;l2E6;e3Bi3Fu34;o10p3A;e1i2CDA;!e4i1C0l30Cs0;e1h2AE;e48Bi29C;b527;l0s14;l372;c245;s231t2D;e1s7B;!e142fC3i4DBAs0w23A;!l60r3F05t36AD;e363i1ECCo92D;d0r78;c3E87h371i4690m3819n159Ep61BsD74t41AB;d0l48BFr1s4F;a17i22AFo2F1E;u4B79;a428i125;a4De24g63n1r63t3800;!e1iACo8Cr19F;!a4Be15f37i6s0t0;h66t27;o481;z2CE;aA3e15i6;!a657e4i43l6Do10s0;!e15i6l236s0;t4B4D;c1230h3E45;o12r14Au12w11C;a113Ce4B56i3F5Fo12y0;!eDi3l7;a10B6cB1dA4e1f3DF4l29F4o1442p2365y0;i521l1n1At3;!e15i91l48s0y0;e17j5A;!e4i6l0s0;b422Dd2Bl8r1BBDs258t0;a12e12EDh3179i6k2C1Fo4BF3y1A5;t4A1C;!a47BeAi6p1FCs0y0;f4B07t1;a1o10;u387;!d1s0t193;e24nF;e15i1ED5lBo0u3Cy62;a1E1De3ACDiA93oAC;e1Bn3v27;a59o73;o2933;!i7Dr19Fs0tB;!n1At3D;!c4C6EkB10;!e28F9i21Al7o1s454y0;c11D6d272De1Bg2A48l7m1559n4833p2B25s11t4A17v142F;n1E5o29;!a20eCEi25A4oE7s0;sF3;f38l88;!e5l1o36s0;a2521c1519e45B5g17B8j2E4Ck128l4245o4FACr1119t4BFBu158x1E13;l8AmD73p61Br1C3Ds3C75;e7i1D3;!a93e4629i69l46p4CtEB;!k899n129Bs0;!a47C4e5o29s0;aA3o27C9r89;f178C;!eB6Ci36B5lBr75s0;e2DmC9;i8t139;sE41t40;a1A6Ce3955i3AE5o4226u252F;o8CB;!n7s0;a60B;a73e3338i24B0l272Fo32D3r3F6Dy3A2;c62D;d71g35;!e1i97;g350n221s1911;!a2FEEg2EAmD6Eo12s0;b2ClB6Fo85u59;bB63c6EAd19E5fBFn3p44E4s45BC;fB93l1r704;!b2D92e23i6s0;r132F;!nB7;nB7;a19E0e222i105Bo73;!e2082i21m165s0w98;d1C00l82n4C27s0t46EA;a1i3C;h2E71;t145;i4n3sC0t2D;i579;!e5i6n3o12;d38g44k47;!l46s0;e40i9C3y0;i1F6o81y0;c25Ed1A;n421B;a0f7t7;u1080;lA5;!e15Di6l7n22;x4C;n89A;!e5i6n3t0;l572;!l189;m13E9;e1047i6;!a4Db3630c35DDe8FCfC3h0i6l22p5Fr13DEs2D99t224F;f2A5Ft12F9;!e3D1h264Bi6s39A2;!b1e4s0y0;l7y0;!l7y0;e3AE8;o3E3;e5n2u5;a4684p1u1;lA98;a20i99C;!c253j9En17F0r2B45s0t1;eB2l7n141;a9d0;e15i194l2Cy0;r7y16;a2C11;o3C0A;e5f7;!e4iF9o12r3952s0;!e4i26Es0y0;n480A;a273;r2346;!i31oA16s0;e5s105;lCD;!a18E9b2D1eF29h11Ei619l44o1Fr313Fs26C7;e1D7i21A;a20e5i3D;!e4l12CDo1s0;u116;m1r25;a36F4e3AABh4E19i335FlE66n21C9o1EAAr1376s9Eu366Dv5016w146Dy2517;!oF86u129;n4s8;e5FD;a80e3082;i284u5;n3DE9;n3AD4r3B51;e40o6C;n1483;e1CE0o0;!c25B8dA4k28s212B;a3e0;!m2Et9E;o879;a7D7;t1334;e2B8i73n924;e308h6B8;gBi17Fu6C;a12e12;e5h3lBo9B;a10e431iBADo466Cy1A;!s351t3;!d0i6m2Er1s0;e1C8;i18E;!e4i6o9Bs0;o41B8;i13yC;e4F0;n45A;a4036c2E9Ee1F4Ei1CDFo10t4434u419A;!e4FC8i1CF4l8D0o3Ar2C5Cs0y0;a18BEe1C74iBDo369C;i31C;a339E;!r4703s0;s5Bz186;!d0fC3r1C4s0w1BCy1;!s357A;d1k5Fn2548sC5t94A;i25s3;fEn14F;lC72t29F0;e31Co4BA;l38Es3;!e39ACl3o41s0;!a36E1eFDi1E0o2E18s1F99w23Ay0;!e24iA31;s4Ct2D;b1FBFc30ECd2C0Ff243g3816h1i4551kCD3l2EC7m3F51n1B3Fp344Ar4763s2EBDt766u478Dv1FB7w26DAy1;g3D;c2AFCs1945;r2C1;m0n11C;!a4Dd0r1s0;n2t2F;a1Di45A7y4067;!e23i6o6Eu33AD;d0l12B6r1s3E;!b10F4e15i21kB4m5Dr247s0;e2D8;b1306e1F1Du362;a435Eb241Ac1AF2d1909e3B6Dg370Ei17BBn131o4D47p253r2AADt13A1u5;a1FA5b1EE8c22EFd43ABe2DFCf2119g1i15ECk5l1B90m11B0n1AC9p322CrFCCs2E8Bt4DF7v89w2995x1Fy1775;d39s2325t1;e2D85;i9u5;!o5C3;a1Dc29DBd88n1031tB;c120m1C06n39Do223s407u5v8DD;r2702;oCt249F;r1549;d4031m52Er3718x0;g1i2011;e12iF65;!i26Fo35B;i3690;bABBl921o2446p304r1572t71Bu3D31zAF1;uA88;i4E44y0;!d0f37r1s0t0y1;eF02o23A8y5C;m52Er7FF;!aAF0c15B5e5C7i3CD0nDBo169Cs93Et1DB9z3;i61oDF;!l1s0t87;!a77Fe1DfB0i3B67m2549o170Ds496D;!d629e0g145Bk309Fn7Bs187F;!eFDi4584s0y62;r430z10AD;!a427oA3r41D;i3B3Dy0;e2B8;b82t1541;!a4F3AbCE2c4475d4D24e1A7Ff2471g3D99h2397j249Bk3A7Bl1F74m42DCn493Fo3D1CpE9Fq4A33r32D0s3DAEt4A87u4C2Ew470FyACF;f858p3534r1AFs20v2D;s5w0;!d357e4F2fC3h2AB9i4E7Ap3892s2F4Ct16Ew1A2A;m64t2F4;m0r1A;!m2En1s0;!e14Cl7s0;h34;!a1eAr7s0;aDm4D;m19Cs19;e37A7o1EB9;oE2Eu14;e30iAC;g38n56oB;u59y3D;e1i1l3;e51o8B;h27CE;nFt2CvB;!d0l44A0s0;!g8B8s0;!aCr7s0;a314e1oE7;gBl0n8r25tBC;c120d25DnEB9;!s0w0;i5EE;r249;!bFBeC1i17Bl7n22p6A6s0wBF;r1BD;a422Ae5009i4C0Do3F2Fu2C5;!n0s0t11;e381;!eC3Fg0;t63;c19D;lDEp5084;e1i23Eo5u5;n8r1t107;e17i32y32;d332CfB5g3520l1m31An2A3Dp12Dr3C6Ey28;a20y1C;h1896t19E7;e0i21;o1Ds82;a37B9eF0h36C7i3639k2226o158Ft2945;a467Dh4987o47C7r82;!e0l1nEt3;!a0e12o46;!a4Be15i43s0y0;r177;iA74o124;c13En1CC7t37A;!e4i3F5As0y0;o1291;a52i0u5;!a95Db4B0e142m434An2C7Cp220s390t390u2BEv3w3F6C;h164Bl75;!hE0i69m2Et27;!e1D1Ei86l7s0;l4r36y1;c80C;!b27BCd2F38h183i6l2BC3m2En22r1s2790t2FwBA1z3FE;c3282i3537s75u1946w3CF2y38;!pD6As0;!e166i1C90r58;!b1ABc1D4e4C6fE5i86lB8CoD7s0tEB;e1D0i925o2034y324A;!e1i479B;!e3D3DiBEs0y0;e5FC;u36EB;f7s65u12;!nCCA;a80e84i31D9o36u5;k20Dy0;f56;a1De1i462D;t14C2;!c3D2De1F17h2A1Dk1mE2Bo10q122s35t2856;a1g19E;g19l1r231;f7o9t7;a3CCb1e3BE6i6lF3nF3p1;!d0l7n0r1s0;eB8iE37;h2CB3u57;n4314;aD1n8D3;e2Fi9C3y0;a0e496i4F;a59e15Bi65o49;aF97e1EB3i25A;l62n140p4D37r2B87t10C;k189;i3F28o46;a253o49CF;c235;!eC1iAF7l7s0;!e0f37i61;!a22ADc3BCCk466Ds0;e1h4F03t20A2;!e4FC1i18F1r1222;h19D4;a3Ce12B;a0cA1Bd285e5f309Di31m18n361;e25m2746;aD30o345u19;l19n53F;d19e108s0;e1l140;a30e30;c0e79s9A;t94B;a1n333;a25Fe4i212Fo33CAy0;e17i9C6;n2o3BFrCE3s351;e23i47E4o46y0;a46BCe1Di647o15EDz4C1A;e50E9o101y20;!gAAh151s0;!d1D55g2A27i21k2E3n7Cs0t28;c50C4;f7n2t3;e9l2C;r18Es1F;e31i14C;h344Fo5C;!a4Dd1512e3242g2Ci21o1s0y0;!f37i5124l22s0y0;n14D;!e1i13l7s0;a11e4i6;e11CBl10A6n179;!e4CD2o2369;!a4517o1A27s0;!d0n16s0;u7D;i46D3;h1Fi4D;!e1F8i3Cl7s0w99;!e26iADs0y0;!aCoD;aCoD;a3F5Ce1i57F;i2651y1246;c1r2Ct3E0;!eEi4C70s0y0;d27tB;o4C6B;g19t3;!e4D5Bo207Es0t47u4C9z2E3;a1oD;nB91;a8e72;d0s7;k1As376;oA74;k75;!d387Ae1h1349l78n22r0s3Ex1F;a3D0F;b4C7i35DBn82;n1BE;!d38n1F64s0;f44;oDr7;!oDr7;!a4Cf37s0;l4uCwAB;c402Fn1BD;!c0i1;gBl3Bu3D5;!a1E6s0;c19d16e51;!e1Di2EDr14Es0u7C9;aCn2s153u14z3;d16Ag4AtEE;a3F5Ec68Ad3C44e4D68f1916g3367j5Al1F46n2B4AoF99pC42r260Ft1C91u322Bv4FDAw2270yF4;!d5BAe3BC5iFC6s0;!d0o29r4Cs0t1;t471A;!i3Co7CA;e67;e23;e1Di13;bB5Cc3FEd4092eBD7f3D1Fg32EFkBl3900m1365n120BoEp2107s1B32t482Ev75z3EA6;!a1e1i13s0;l149;a1A;c108Cs14;!a465e3i6s0;!a1eDs0;!bD8e15A;!e155f37i30Bs0y0;e0h0m0t0;u38F0;d0g96;c2D1n3;!c234d8Bi97l1s1014;a31F;e40E7i250o57;e265;!e265;b63i85sB;d1l25D;l16t0;!k1r1s3Et11;i4A47y0;!d0n8r0s0;c1At2BD1;!d8Bl4AB3s0;!eAF8i6o12s0;tD4;l2DD1;a2A71;i338;b3114d1FDDeAfEB3g19C5h3B8i2123l2C2Dm4870n1BB3o58Bp2D30r49B0s2242t244Du1F7Fv227Bw130Cy2AFAz27C1;hB21;hEAD;a1d2B2Fe4C03g96l1A30o11C8p220s494E;!aC6e12DAfB0i3Cl22s0y0;e313i6o35u49y0;c270Dg3An2;e15iBEl2Cy0;i30rEsEu12w27;!aDFe15Di6l7;n2A4As9C;t1C1D;a49o44A4;l7Bm2511s3511;r85A;b128Ec5077d1624e23D7g3AE1h17B7i4DCBl41A0m20D9n1BA6o3D83p874r2643s4EE9tD36u4249v505Ew2B93x18CAy3A16z1D96;a34D6i4557;a104yC4;e24i6;a3B6e1i28Fu14;a3D55o51;!b4F85c47CDl45D1n29A3oD1p12Bs1FtF7;i2Bo1y0;i25o29;a54De19E6h231F;e1296i54Ay0;!e14B2i6s0y0;c472g1A;kBl202An4D5Er25s0t87;!d0l22n1BDr17Cs0;!a0c1E76d0i6l22r293s0t4BEy0;s3649;!t436;a4DD;n3AB6t1;a3548c140Eh127r2414t43FE;!h9Do6FtEB;i3CoE2r58t4CFu171FvDA;o88Bu1FB1;hB09;!d0l1r1s0y0;!e12i1011o710p7Cr41B5s0t4D23;!dBl75n18E8r1s0x120;s66t1;g11Dl15An64rA0Cs85;!e4i2198s0;a10e6E;a80e49s1C6CvB49;a12oDB;o32F1uE;a4B1iE58o126Fu116;!a12d8Be4hEDiBCFo57s0y62;lA8n396u59;!b343d0r145s0t1y0;l4Cu5;l540;e3104i393Al2Bo13E6r4541;e4i3C;e1w60;!l1As1836t38CB;b1DE1;!l0s560;!a1FF4e4167g3F37h305i46A3l1CE8r247s0u2CB9w169;aA2e1u14;!d0r3B88s0;!e239B;!e3F64h2FC4iF2Ao20DFt37DAu2CA;o2B18;a51i3Cu1D;e8g0;l39t39;g3i4r8s1C6y1;a20i2386oE7u5;a46C2i3552y0;s1BF;i2o2;i3C2B;f1FF5;e1725;!e1F8i250l7p1A4s0y0;dBn0;!b508Fm64n725s378Dt1;a21e124;i309B;e3CFFi6s165F;d0n1r2F;n1B52;!a155Ae1473h751i1E68l4AA5o3EFAp16r4197s1FtC7Du1653;!e1i10o10s0;t2039;!d4AE3i6jA9k0m1A68p21F1r24EDs0;a918;e224;!e224;eB8i6;a769e294i382;sBt16;!e1F7fB0i44Ek5Fs0y0;s44vB;c63i170k2Cl337C;o2C8;lCt11;i1F83;!h157;l96Fo29v3;e8f6Di10;b1Cl1C9m926;z3681;i53D;nB3;!c1n27Bo5Cs0;e166Ai250;n379;e1C79h632;d66CrBs9Ct9BA;eBi3Cu4BF;l2A6;o1CDz15C5;c1lA7;a4e2C25;!d0r1s3Ex0;!a7Ee2594i14E4o12uF1;a4D0Dr27D1;n44C6;e1A39i3Co1;o35A8;u2EBA;c48n16;!c9Cs0t4A0;e3EB;d1EB;a730;a890e5s27Ct1z19;a1t3;e781;i1o3A;r78s1C6;!e0k1l22p9Br1ACCs0;a76o10u14;!e15i21l75s0t230;eB8Ai6;f39F6t8BD;d274Cw2A40;!e10m3D94z41CE;a1280;!e4i21o10s0;c5AAd1CDmCB9;d2Ci4124n4D02p1029s211;e438;f0p0;p1EwAB;dBm49F7s116;l3m3;c167n2;pCF;dD2nBt2BB0;m0o12p1C;aCe1iE4u5;!d646e12;c9A1f1569g3B46m4881n3A37r4C9sE3Dt231Cv3D07;o2D8;eAi6l525u41F;!b22Bl1n29Es0;!l1AF7s25Du5;!e4i6lBs52;e1665i183C;c0e67l6A;n5017rAB1;!aEFi4DCo10s0;eF47i1723lBm2Eo408D;i886;!pDBr37Fs0;d23B2k5Bl19m1Ep3FBr1Ev6BC;o134F;h1E57r1414;e34x1F;!pAAs0tBC;a3F80e17iCEu51;!d2433e24n4C50s4ABE;!eAi21l1E2;!e15i881l36Cs0y0;!s0t4ECB;h1FBE;!e1r0s8uD;r5B1;!a37C6bDB8c4FF5d63e46DDf22A7i4103l3E0m562o172p2B23s0u65B;!eC1i4163s0y0;b7Be42i2Bp1C4y0;!e4i6l19o9Bs0;e313i6o17;!e1808i4A1Fk5Fl7n22s0;!h2CBs0tAA;!a4E46i178oC4;n1s3z3;a10r1E4;d1C1Bf1l2F45n113t4334;!s0w9;!e0l0r2Fs0t3;a2D1d442Be5Dk1l218t18A;a1eEi2By0;b16e1;c4B1Bg65Ei161l47F1m199p221r4DC4sB23t1B1Fx27A7;i25nB;!r160;c1F63x1F;a1e1k3066l35AB;a12b46D5mADAp3899;kB6;!c4ADs0;e507;!i69k9Dl9Dm2E;c22F7dCDf3830g4AF4m343oB8p3EFBr344s1040t11DCv3FC1xAF;a4155;i21n8;!b5Ce109Ai2D61l7m741n22o43DCp5C9s0wB4;!e1A84s0;e30vB;a30e3EB2l13Ct242w28;i20A8o175A;!e30FDl7s0;e26i55Cy0;c3o40Cs0v3;!d0r3564s0t16;a59Ce3FADi4B41;!a28Dr1s0;o2F8Cr94uF;e0i0u5;r3C43;c46k2C4o10;a0g0;!e6BAs0y0;e4i6r1E91s0;s3250;h2607;m1As0;d3r1;d52r1;!a3DC3b476Ae3AE0i1CEBl1CDAo2199s1A6u1D00w535;c2F7g25Bi13Ck1En438Fr3906t4A5F;a484b2DDiBo376C;!a1A0e1AAAi14C7o12s0u3;!a20i7EBo12r19Fs0u5;n1EE6;!d4AC0l28n58r1s8t47z334F;d3FE3e0k269Fl5BFm36FCn0r3AA4s45FAt1BC4;e1Do35;eAi6s3B;m6C0s5E;e4035iBDl2615o1699r4DCFu1C5Cy52;m2316t2D;!e24Cy0;d0r1tA54;!r7Es0;pA7;d10ECe24;i5A7;!a173d0l22m64r1s0;!a3BFeA4h274Fi44C5s0;!d0e10l5144m0s0;!b9E0s0;c4195p5F7;lED;!e292oDs0;!e15i21l44s0;t22D0;hAAA;a50Bo31;cC5Ed3DF2;a4D6A;o4601;a34F9o280Eu14FF;e1i35o40;!s0tB55;e373i3F11y0;l472;!d16De135i28C5s0y0;!a30h1;a589;a10o4471;!e4i6s0t0;a4248eAi2456o22A6y62;e3CC5;!b691e97Ag1867h4E7FlAADm3E8BpA4s1613t37Cw3B35;!s0t87Ay0;a4223e2E39i3F89o26EDuD7E;e8t3;m1t71;m71t1;d0e3Cs0;!c0n32Ds566;!a118Ae20Dh371Di69k4ClE0t1E06;t328;!t41;d0n12Cr1;f96A;n0r618t32DF;o45rEB;c0n11A;c0nB;f405ElBoBA;!m5Dy0;p27sE;!e5u44C;e346h117k5Fs31F9t19E;!l14EDm184o1A7s1197t42A0y98;i325FlA15r3A4F;a16F6d258l39En195r3BF9t3A6F;l2Ar9s7y1;c3d18t0z18;a1A56e2084i4AA6o35C2u684;!a80e15i6l7s0;e1Bm3;i2Br7y0;a1262b49e1BC3i475Am9ECo3701u6ACy0;!b1D2e15iCAl22s0w23Ay0;!b335E;b1t0;h18A;m92s7E0;e255g2Cm31Ar925s37B8v3;a1DhD5B;d1AFgE1;a100c0e1i0p1F2Fs161t3362u4Fz102;i3F33o12y0;n40F;a254Ae4C84i21BBo1D6Er7CFu27A1y2F57;l381Fs0;f140;t1v3;aF0;!d0i9s0;i24E6o81y62;!aAF4e3D1i6r58s0;!a0e35BE;b29n6D;!e4i194s0y0;b3B12d1g4592n37B7p419Br0t37D;!e203Cl44;g1Es19;!a4534cF6dB8DeEi170k1F03l1CB7o8Fs0u528;b3F6g1E42i4lA8m1961p1DFFs44EFt22C5;n29B3tB;!e23i43p115s0y0;!s0w6B7;!l2Cr268s0;!b1D2d0s0;e1r7;!e5r7;d9Bn8;l2A87tB;!aA7Ds0;!c277s0w10C;!a146bFBe3EDi21s0;i4C1F;eD1i158Cl468Ap2Cs310A;!e23hE2i6p978;a822e9;a42FEe176i4066lB;c88;d0r218F;d0r203;l0t6F3;e46Fi180Co5F4u30E;a4BE4e3E0Fi39Co1uB9;n456C;!i278m64s0t33B1;!iB8s0;m3Az2A5C;t2C37;!a28Dl143r35s1;i343C;fF2s170;eEi27y0;!hEBy0;!g3BB7lA8r11Bs0;!dA8Bn3C81s0t83v19;a4A90o72E;f3BFEt47;nFs105;l48n83;n4Br36t48;a241;lD6;b358l0r4F28;lB6Dn74A;e52;!t63u166y47;c4DFe680i0r58;n2CA6;bD4cBd5Fg5Am852s1Ft3B1Av38y1z27A8;d44Bi195m0s1BAx204y0z3A;a354uA13;c3d1t1;!e1r7s0;a24DFi3191u3A0;n2BD4;!a1Db1Cc1Ce24m0nFs5Dt38Dz5D;eC4n28CDo9E9;!e4BCm2E;!b17Ce1C1iAB8m2EsECw1D9;d18s289;g587n13Es2F37t4F3;r686;e4415oB78;!e1FDi6s1050;eA91;!nD7s0;!d0r2F;d0r5A0;g5Bs387C;e5Dh44D8;b5024;o53u2658;a7e10;!eC1i4378l7s0;a11B6e24EEh204Ai129Ej2FF0oBD8r1BE2s12C7u207Av147Dw4E23y1F21z392C;s215B;o3D5;!e67iBEl2Cy0;c4532d4500e3C5Eg4B8Dm4113n19E3p3121r1121s1311t16C3;o29t7;!e15iD9l7o12s0;e12h979k2C4;sF33;n3B5s3;v2D;l2CA8m304FoAEuE8;!c7gBl0r7t201;c44m44t1CFu21D;c11f1t61;!e4i44El7n22s0y0;k7B;l58s56u234F;!c2ADi5;d0e4lC;t511B;!a267Fc3993e1C0Ah33A6i4009l14F1m10B7n37EBo2F4Fp4837t3481u3DAAw2F14;!a36Fc2C1e24i6m2EnFs0wA9;iAA9r5A;b7B4e3743i198l2CC9oFE1;h7i2522o29;e5g1;!a70As0;d19Ag12C;a42e3E29i11Co4900u3AD6;aCc0u26B;!l60s0;l2C66;o652uE;!d5094g315n22Cs0t28;b326c3FF1fBFn1s5EDt5E;kBA3;!a44C2c2C1DeF74i101Ar1803s0t27E3u2751;h60;c10D2m26AD;!e4f28i6s0;n0r185D;a17Fo5;!e15i17Bs0;!i9l1n0s0;g2Bx0;g1Fx0;p28s646;!h1048k0l75p28s4D4At13CE;!h151l22s0t33Dw40B4;i6A2p9EtF7;a9d0r1;c41d2F60e1F0f1D8g18i35Dl29D1t28y0;!i43y0;!c3708l3DF3m309Cn22FEp304r4492t225Eu4EEF;c0n2s14t3;aB04c14DeDE9g40B6n2Cq122s9Ct0v1BF8;d0l1r2Fs0t2F;!a76i19D2s0u14;l2BDCn3r15D9s440t243DxBF0;i20uB;y33B;d5Ck8EDlA8mADAn30F5p1s2C;aDlC;iC4;!e0t1;c5096i3029n3A1Br1657s235;lA8mA1p9AD;i1F30o57;!a173eAi21o12r22s0;i3A0;!a7eAi21s0;t215;h214D;!bD8s0;d0e142y28;d197D;h1D11;!l377s0;a49E0;!b1D6fBFgBs0t3405;rB8;a50e15i6;a1E2De1AF0i2171o6F0y62;aACi9AAo8E7r41AEu120;e780i6;!a95o138s0;c4D64iE;a1c0dB;!e5o36;i210l38A4;e5o36;g269t2F;!a3BE3cCD8d4292e371Bi68o3C49s0t1B41y76;e4i6u381;e12l1r1t19;a34b4Dc4937d1e1C57hCDi4AFBl206m1n42A8s3t4FFEu1vD3w10xC0y131;i1Dm19t1939;!c11e0l0r7s0t3;c4BC4d37Bg9D3i4n4E9r298At2DA6y142;a1e78Ci284Co36;b390c2F7i85m35Fn2731p220r3;!e4o29s0;a3FB3i161Eo1F8Cy0;m48FD;!a381De3248h377Di2BC7p2F64t2081u4ABCy0;!a100i3Cs0;a46AAeB;g1s5;a823r26D;e4i6l19y0;!a80eD0iEC1s1C7;a134e17i57Fo102F;k3441o5C;e349Di194y0;l38Es0;!a4Bi152s0y0;a57o94;n63t1540;c1B6;i2Bo3592y0;d0l492Dr0s8;i2CFo1FB;!d0l16Ar1s0;e4FpD8;r140;r0tA20;!p58s0;i14F2;e0g44F;!e17Ai2B2o10s0y0;!c58d977e0t1611;!e17iE75r58s13D;r7F;e39EF;!b4BDc39D5d0e33DDgBn371FoD1p4773r3342s0t0;aAEsE;!e0l1r25tB7;e26iC65y0;k16n0;!b3BBe15i21l4EC0r3579s4F4uBwA9;aEo32;!e4i18s0;o10vB;i298;l2CEy1;d2Fk68Fl2662m0n431Ep3EA2r54Bv4214;!m2Ew7B;b39;b3FDAc4EACd2D8Ag2E40l1CAFm431Cn510Dp368Br3386s4EBFt4436x56z4A62;!e1Bi279l7;n2t242A;c1D4e1Bl7n2;!e24i6s3BB8;!a231Bd357e13A8h4ADDi3F84l2528o4217r1589s0u5y0;w617;!eC1i6l7n22s245;!a1C9Ac2624eC8i4l4E62o2D1Er2AE9sAEBt1AAEuB9z1F;d0r244;!e0i0s0t1;c1s14;c11i9;e1Dr48EA;a3773e1EBoD4t443;a3110eAi214o29;!e24i290s0;!a45c2918e0l55m274Bn2A8Dp1ADrBE8s35F5tB7y28;t6DF;a4Bd1f7;!c77eEh104Ai4CF2;b38p4594s280;!a47E9e3561i6l64s0;k43F;!e12r7;e191i21l7;!e4i68s0w1BCy0;!aA3e14Ci4231o73s0;!a4A91e3CA1fC3i3663s0t16Ey1456;d1e1l28p2DEt28;d0r1s1C6;!b367s0t227;r66CtC5;y6C;!bA59c6C5s1A6;e17t16;r35CC;nB80;!l1As0;a16A5e189Ai2261o2EE9;!g1n38;b1322c4E2Dd1D1CeFCFf2F25g47D3h4726i4978j485k27A9l19D3m1214n4322p4796r4FFCs2F47t3E22u3554v2A24w1FE0x121Dy4446zCA9;e1i3;!i3Cs27F;!s0w7F;e1Bn2o10;a1e135i3F;d0r1t1y1;c399BlBn1t1E5;b0r32;!e4i43lF5s1Fy0;!a16FBb198Dc290Ed42D7e3734f3B19g3ADAk4463l4D7Am3B20n1860p1563r19DFs12B1t37FEv11C6z410D;e24C5;!a1DCl1s0;a1071e1i3387r1A;!i4m18s0;e721i6o203;g3s5B;e14F;!l5104s41C;eAi341o3A5u5;a136e23i6;!a104i2Bs0y0;s4108;i739y0;c2A55dFFe2420g2847n10AAq1962;lE8;p38B8;e51i51;!d0l7r7s0;!d0l7r0s0;a1C1Fb1d0e1D9AmB0n479Fs23B9tB17w496B;!a2622c779e3CA8i2BC2o326r32BFs981u43F9y509B;!e5n2Bs3EDD;d1ED3;h40CD;r1B48;!d18Af1DE5g23FCn15AEr5FFs0u1v34F;!a19D8s0;c1D1D;g4Ak229m533nB80s1CEt3F45;a1l19;e5i31l19o46u1C;e14CCiDC;c1Cn3s0;k3l2As2Ax0;c1C05k0;a1E6b158k1Al1m267Br8DFs1F;g3m1y0;!e26l7s0y0;i6p2C;!d0r1s0t0;e1F25i4C98o4DBC;!d0r1s0t5;!a33AAd29B1e280Dg219i83m114r3660s0u2C51;c11m1;aAC4u4116;cBl121rDD3;a128i256DoD4y0;c7l1r7t3;o166;!p3As0;!d0l17Cr1s0;dD8i224;h168;g9A2n3968r3974;aA7Ao95;e870;!e1r19s0;m1r8;!d4E8ElA15m216p43B5s0t3C7;e4i408By62;e0yC;eCy0;tA0F;!a0e5;a0e1;l99C;g0o1;!a1A4Fb16CDe1039iEC0m3918p2012s0w4CFD;e4i6o190;a36EDb39D7c6BEd3886e4F82f1CE3g3B1Di45FDl39F4m1629nEA8p3DC4r2F98s354FtEB8v0y36A1zB00;a1e89B;a15CCi451DlBo133u387;!d2E5El1A90n24FFr4DA2;!a20b3FCe3418f3CEDg89i4AE9k3F25m2F66n4230o2D6Er7B3s2D63t3883v11Fx3A9B;e9i9;c0n2s9A;d0n0r0t0;!e308i8Eo9Bs0y0;!aCe26oDs0;n28t47;iD4;!b1Cn71s0;h244C;d0n6D;n3s14t2973;!e10Er32Fs0;a302c4725d460n2o47B0p239Cs2788u14x1F;r2E9;!e18Ai27l53s0;l0n1EC;!e15iCAs0y0;d0l473r16;!a80s245;a0c1;a20e30;p4F93u2334;k3B0F;i24E1;l5083nBD0p220s13BvBw50D7;!a3D2Be4B12f61Bi2A80k157l4839m3DF6o2162p4E95s17DEt3356u35F3y0;a3E98;p168;a25Fb60D;a0e2E0i68k16EtDB;l0r0t3;l1r18;c3CE6d3g4F31l35E5m3E72n30E8p39BAr47B2s212Dt116BvF92;n469;nE18;a2999i0u993;r25y16;p16v18E;c0n1D54s9C4;b12FdA9eB2l7n141s432;!d0e0s0;r14C;!d1D2e23BpA0s1FFt2D;h32EDs1F;!e4A48i6o0s0;!d0e1i6;a4CEFe2025h29C8i66Ez1F;h4A2i1C67uC4B;d3C28;!a12e15i6l22s0y0;!a10g7Cs0u39B1;e327Ai2By0;!a4806e5;sC0t36AB;!aCh255Bi152l22s0u4Fy0;!eACBiCBl2Co275Fr22s0yEC;i45o49;!s48t0;a2BB4;a4382i1243o3709;!a3953c160e2F58g230i40DDo46A1pA4s78u45y2955;d0r7F8;n312s11;m29F7;r29E;!l7n22s0;c44iEv50F7;g96s1E;a3D0oC4;u147;p3B58;e4i6lF5;a32nF;!a337Eb66Ac1B65d22Ce2E3Eg4D2Fi2F08j41F8k1450lEF8m1218o2118p7A2q3C24r50E2s1B2Ct4921v5065y2825z350A;!e209i86lF5s0y0;c30AEr4801;!a4Be4i6m2Es0;e1i2Bo176y0;e1z2DD;!d0i6r2ABsFFAz1CE;b447;!i31o10;aDCc167n2;h4072;i3Fn19;a2C67b453Ac851e4E39i25FCm27FEo3DDCpE8Es0u19AAy58D;e5s2C8;eAi33B9o46;!e4i6l8E1n0s0;eDl7n2FD;k0t3B;!c41s0;n87D;!b44F7l75s0;!i5t27;a126;l3B1o1;e1g3F4Ci1142kF56n50BBs4F7Bt58;cEr25D7s1C6t2CD;!c1d0r1s0;f108g19rEt19;a1De23i3F5o12;n1ECr1t1;a298;!g1FCs0;iA7E;e23iAD;!d13AhEDl7Br7s13D;e97Dl0;a6Ci6;aCbD6Dc3AFAd2776e130Ef4350g4E96h2AC8i3266j1Fk32A1lFC9m3E51n3FBDo0pEA1r2FE5s1FD8t28CFu13A3vF79w28DBx449Cy4333z295D;r4038;!b280s0;l214An53Er7s434x1E;!i13D8o777;a17e43C4o5EA;e222i2DB7o1;!g3i9r0s0;a30e103;!gA4l24FBp6D8s116Ex197F;y76;r2A75;!eC1i6l88Fs0;e1Bl7n3CE;l3r83;o4957;e28B9;!m2Eo1;r2C08u1D7y1;m4466n11B;l22B;h2DE;i8Ar73D;!i31;d4C30n640s402z729;e2889;eAs0;b43Be0g0l4A6E;!d13Ae44F6h1623i6k75p2A7t32EB;a8c5E5e1EAChE79i4C81lD03m315Bo4AB4p49AEt2499u443E;!e23i21s0;e12i43y0;a4596;d0r487;!n544o10s0;!e4i6s245;m71n2D;a1n18;a16F5b3E93d23EAeA4f5019g11A2i56k1787l2732m49F2n2807p4CF7r625t187v2B;oE2;o8F4;!a3BB0eC78o2D69s0u6;!iAACr4898s0;eAiADy0;d0e5nFt4335;a8BBb1CfF96;!a25Cg1Ei805o36s0;d551;!e4i63Bs0y0;a3BDe245EiE77o7u222F;!e30E9s0;!a1817e2576g436Di3ADFl2042m165o36B4pB92s0uA72w5C8;!i90m2En2Cr164s3211t1CF;aAEl7FoDF;a459;!a4098d3FFg332Fi6l1984n4903r3A83s1D2D;!b1AB;e31CBi125y0;e4i68o25F7u4Fy0;!g1A;a188g1;!a4DA0eDB5l75n12Bo1;!s299F;i3480y0;h1A4s491tD2;!a80d1e4i68s0y0;a188e12s1F;l1m1t7AA;n315;!a248e3BDm7Cs0;!e0r7t19;aB10e359i30F1o399A;!s1t16;bA1i4y1;l16v1E;eDf7n2t3;k0nE57;a34FFhF75i0k2DFDo135Cu2602;c11dB0g2BD7n2271r1D68s1E10t1A9Fu1v2B;a5062o1F0Br4AFDu3F1;!aC3Ee4i6l3204s0;!p2A6s0;m0r182;a4Ae4CF4o30r2E94s0u1;!e24l22s0y0;d3D6n149p0r1Et61v2C;e1f38l237C;c4Et60;e4D27iBFEo3A2CrA1y0;a0t3;d93Cl0t93C;i1268n82y8F;lA0E;a48A;d0l1D89s5;e3AAi68y0;a4Be15i6l19;!d0i6m3C66r26D4s0t1;c0i25;n2CBp1B0;!a20e10Bi20C6l7s0y0;e1nFqC2;!a4De37CAh288Ei21s0t5B;p1s5;eDn2t0;p16Av6BC;!d0e1n0r8Ds0;!i3Cn22;a4ACe308i3674u5C;e5s405z3;!d0e9l7n4A32r5070s8w380x1F;!e15f37i86l19Cs0;e8i21;e365iBEy0;e50E;a4De24f37;l1447;!e1138i21An22s1A6y0;a4A31dCFFp42Fq8F8r4A51s5E2x4251;!dA9eBDl58s0;!d0r7s0y0;aD4e8E5;i0u4F;eAiAE1;a42i65;k1Er297;d1f2D8Cl58v4531;eAi1A00o12r19Fu49;!d5Be1;g41r7t3;cEe10g50C8t1;c160d1CADg1007l2FA4n511Fs3C47t3E8Ez89;u383;l1Am29r4Ct112;l219;n153s8;!e17i5B8r7s0;eAi30ADl41DF;!e4i6o3As0;!a3E5Fb3FB5e335i4F12m46DBo2B8p2C0r160s0u4F;g704;!d0fB0h110l22r1s539y98;!d0n4068r1s41Cx0;hA4;e3283o149A;!d0l1r1y0;d0n83;e1157i3A;n2t59E;s3366;nEsBt19;e67lE2nFo29t1A;l140t1;b7Ae1CCfC9nBt1;e20AF;a354eA56i14Co331Du26B;d6DAe5g2B0Ei471Fo1s40FAt12CFv17C;!a49C3d4212e45FBi3D68l3544o2A8Es0t4CEAu1ABCz1A;r2C2At1;f2B34;!e8Ci21s0w1BC;!a291s0;o266F;a25D0e262Fi7Do13A;l642o5055r27Et3CC;c13BAd1CD2l84Dm6DDp12Ds2537;!e12i6n0s0;aCEi433Cu69;aCc290CdFFe34C9f4D42g26BBk30ACl5042n1B67r26A7t4077v27AE;i24C3p215t1974;l1r5E0;!b4E12lA40s0;d35nBA4;n2sE9D;a2401i4148o0u5;!a42e4iBF1o2E8Es0;!a4De15i29B5l22s0u5y0;e0i137y0;n122D;!lF6n2E50s227E;a34D4;u26B;c0sFCz3;d3n2;eAh3l3;d58l233;c8iB82;!a20e1833i3492o126s0;a40i0u5;l15E9;c1D62n92Eo10;c7A3;i4CD3o129rF3y0;a1o3E9D;e4611;a4De569r3020s1CDt3Dz98;eDl7n2s687;e23i6o54;a1100e11AFh48F0i43F0o1377u4D7C;a3E47c3268dB8Ee1i25Ak155Bm12B0n1F9Do1358r39CAs1E88t17A8;!a2B8e24i2632;!r1s0t114;e10n144;o7AC;l3Bn0;i83Cu232;l264;!e1147i1l127EmB67s0t1;d0m2CCn35F0p8t0;a65e3DB1i54;!e4l7n0s0y0;w89;a0g10s812t7z48;nFv20D;i20o101;m3C40;a3C3Ce42E9i2C84o7B2u1BB;i2112p41;x1AD;a59oC6;h64E;a87e947g82i13o29A5y898;eCg3;a36Fi51u158;oB23;m7Bt47;g3An2;!a358De4i6s0;e40i27y0;e1Do333;s1AD;!d0n3833r1D88s0t2943y1;o1B2;e3FAiCAy0;i70o3F2Dy0;fB5l3n1;a291c491FeAfBFl2Cm2Cn50FAr2092tD8;t546;!c3g3k1;a0l19;i12n1;!e1012g494Bs0y0;!aA54n487;a133i3BF6;i3Dk6D;!a100h197i56o106u34;l2F0o12;!a22CFd4C85e0g19CDh0iFFCk1102l7Bn2777rA85s39At42CAy1A8;rDB;r55B;z4C;i40FB;a33AFb4088cE38e2C88h1C51i239Ek3DF0l4BB0m238o45Ep34B4q29D3s4AFCt2F27u507Aw500Dy35F7;s6F9;!e9l199s0u14y0;!g3569s0;a423DeA8Co49C0;!b151c42Ad439g23C4i4n3ACs0t4FEEx118;l4E9Ev5D8;!b46DCs0;a4CCBe318Eh92Bi32D8o1B6r1D4;e543h5Ai4AFk2985o4FBEp2A4s2F6u4F;i256F;!a4496e31o4E82r6F5s0;i223l0n11Ft217;c9Ce1Al47;!a4Be15i6s0w7F;l47DB;e42s0;i5B6oC94;a136o387D;c235t0;a51i3C;!c2Cd88eC1i17Bl7n22o73p4F43s0;c32r2F;a1i5D;a2018e456Bl55Ao2A6E;nACD;!eA48f37i6m2E;lF5o332;i7Do3A34u34;!e1EhA5;!a4Be17Ai6s0;l1n92o10;a32d0l1Dn8;!a80b1DAe4i881l22p52Bs0y0;!a23E5d127e2DFFg21BFi6j56kF3n4E35o12s412FuEzA1;!fEDhEDi86;t33E;e12l249n2;e125i3E9;!cB1h24C6s0tAA;a40e49B8i31;!m88s0;a72e1Eo4F67;a16;e4107o283;e93o29s19;!d3Bl69Cs156;!k7;a36i22EA;b1Cs24C9;eAi425;a2349;!e15i6E3s0y0;d94;c167f23CnFsE;c120d2FF4lD49n3E50o10;a3F93e4FEA;lA8n513D;r3258s2BCB;b7Al60tB;d2C60;!eDi65r7s0;!l1Dn240rACs0t1;o90;gE4E;tA6E;e12u32;!d0t0;!a80eAh0i6o1EDs1129t0;sFA;k5Fl0t3;c3B4f13Cg4D94n33Fz1E;c27AF;!d0r1s8E2wBF;!c0n3u14;!e4i6pA5s0y0;!c9Ed648i50Dl82n3A1FsC29u5;m3B;cA46nB6s33D6t71B;!e4As0;m452Fn3526;r1F;l267s5E;!a5F1e1527i4D40o1s0;a44EAb4A9Fc4E7Bd18B8e1645fC97g1983h392Di2136k3E10l4D56m2AC1n2F8Eo1C8Ap1111r344Cs39E1t364Du15B1v13D9w42E0x4144y2EB7z21B0;i12t61;a3C3Bn144;d64p12F;e4iBEy0;!d225eB1AiCBm2Ey0;!s0t4A;r8A2;!e22DEi3938l7n22s0t4520;!c40FCdBn284s0;!c321e4i6s0;a4De191i6;!d1CDm6Ar3449s0y48B0;s4E;c6B5l17A2r44B;d1DE4;y87;e15DnFt226F;a0c2BF5e0o9sD1;l50E0s2787;p508;b2542e1BE4p1E60s258u59C;p3As77;a1De543i6t1;!g38s0;e5i6C4;e9i2Bl44s0;eAi1EC2y0;sB2Ct1;a7A4;!a7A4;a42C;b7AgA4nEt72C;!f183p527s0t7B6;!a4Be1C1i2660s0;r3s9A;h3ADC;!c85d44k2ClA4Ar1EDBu220y28;!a115De12Ei2635o0;n3B9;!a136iA05s0uB70y0;d3C71k1l4B7Dm28p131t1;u28w28;a54o57;g0o0;!i27s0;l55n1CBAr51s418At3D13zFE;r9C8;d50CAe23i21;i11Dl114;p75;gBn83;l4AD9;i4E40y0;a0h62Fi2E31o69D;!aCk115r7s0;!a763e90iE81s0;n36r3030s9C;a82;!d0l22r28s0;n121;i93Al1CE;!cFC7d1D85gD8k1lBn16Ds71Ct4A1;a459Di38DB;!a38F1b268d270e2FB1fB0i6m2EpE2sAFE;!i2813;c1Ed1Ez1E;l2D4;i3A01y62;a4BB5s14A;a4Be43BDo68Eu4939;aBDo176;i9l3;l1E67rB;!d0l75m2Er1s0;a20e3B;!s0t4C37;s0t16;cD3s2AC;a1CB2e4907i1631l991o3847r4B88;c3195l32B;!cE0i6;!c48e1i0s0t3Bu5;r3B7B;i4BEFs89z89;c1352d3D11e274Eg1731i9t4836y35;t1C14;e2F0Ai65Fo1D98;!a4CC6e320Di23ADoF1s0u5C;b3E4;!e15i382s0;e0lB6;!eABDi6y0;k2CB;i10nE;!a1A5e2F93i68o73s0y0;o81u3936;!a1De1F0f263i6s0t32B3z1F;f37o29;e4m1;lA8s0t2D;a16D5b56cBd2F22e3F53f82Cg2AC3h166Bi4432j81Fk2663n1BB0s2DADt1794u4FxDEy0z44B5;e981;s3A;a957y0;a24B;rBC1;a1546;!a1Db4E66d0m4EC7o29sB53;g3Dr0s8;!c2104h1B9Ai49Fk58m82Co422s345Dt4CC2;gAFAn25s1E;t4A60;!t112;e3F5B;g39;y9F;e24n3BEB;!a52m1EoE7p6Ds0;i25l2C7An1p2384;t2Fv3;!e1u275;!e15f37i43s0y0;b74B;!d814e4EA1i358Al160s0;a42i59o3745;aCt3D;d1h1;eAi6z4CA;!b340Ec1F57d23CCe4E6Ef1485g383Ei200CkD4l3CF9m1266n2423o407Ap390Fr2582s4DCCt20F3u3119w2E83y232Cz4033;r1t5B;eA88o46;e1698;a1854b40B7c10BDd2664e4C62f2BB6g32C1h2248i20FEj1D6k2762lC75m4324n1DB1o25ACp4617q336Dr2717s37D6t2CE1u36BCv31ABw283Bx6B0y50F9z2A1C;c1f7nBo1D;e4i6uD4;l25A1o74y109;d0n295o29r60;d1n52;k186n4F71o8t405u16B;b1Cl3n2o10t7v3;!a47E8i77s0;aF54;aB58d44e90l0sFAEt546v2363;f4EB8t1;e5B7l30Co176;!e5i4A6o3Ay0;a62Ci390o12F;o12p1C;!e1Bl7n22y0;r1CD5;c13Bd4FF0;i922l44;!a66Be24Ci3581y0;c35Ed285l49A8n2182s0;!d0r1s0t87;g3017w59E;d1B63;e1EoD5;i8Fo3A;hEi35;!b2FA9iD90lB7o298Cs965;i4AB0;e271i1F27;e28BBi6;!e4i6s0t35;c32t7E1;a3213u51A;!e15i6o255s0;!e42i2BlBs0y0;k4994s1F;a9n78s1F;a11B5c11d3e243g4B1Dl403Fn3889o4204p1r10EDs23E1t1530u1EEv5Bw1xAF;l3n2;eB2f225l7nFs11;gB05;d0l1r5142;l22E9;a13C;r2B1B;h1B8Bk0o50B8;i7AoC4;n8t6F3;!bB3e4i6s0;u1CC2;d1k0;w3AEC;c49r285t2DB8;d0e1n0r1s0;c1s3t3z3;n29CEp1r2Fs9CtDAC;dBAA;h117t1872;!a589e3A38uF1;!a4Be15i91s0y0;!c7s0t59A;a10e1D;oDAr40A;iB7C;e1BnFs174u14;a1Dd0e8g96;o69D;a24At7;a4Bc0e24t843;e2AFnC8;!e5i1j7E9;i30D3;r42F7;i21Bo1;d0n1r2Fs8;l96E;o30E;e649i1F4;n1749;a3EC6c4A0Fe23DDh2743i3497jFA7m715o2EC5r19A9s43E0u30BDw2A3By15F1z3229;k1m83r32AAs7C0tC90;b1s1B3t16;c48i4;l48D6;e12h110;a10u232;b7Al0t19;!a26E1h41FDi39D2s0y1DB6;o11D;eAi6m0;d28k28;!e4i86s0y0;i3lBy0;!e5m2E;e6Bs3;i14C;aDAe349o1;e84i35;a2Dc11;c0d3t3;!c457s0t1DBB;!a20e1C1g0i6s0y0;cEEe1l1nF;!e4i316s0y0;!d71g56l0n4647p50A8r323s0v7AF;gBn1s16Ct61;r130;!e5s3;l36;!c9Ck28s0t11;a3CmA1p16;!d38l28s0;!e24i6zAF;d1Au8F;d0r1s5EF;b13F0e1p4354t29B4;t44C4;y3;i3965;y52;!a309i31k1o1s0;e1B53i86y0;d19lE0n25;o80E;a50nF;a162i6B6o29;!a4De15i194s0wA9;!b1A7e1h2526s0t2EAu22D;d0l6A;e6A0s5;!aCd0s0;e273;e4k39;!b1D2e4i316p5Ds0y0;i1C18;pEv1F1;a12i95u5;l28r1;b1c234l33E9m9D1t3B4Cu38BD;!b422Ff4E0Ah110l25F9mAAs0;e57i48A6;dBr9;l2F;!e25i6s0;d5Bi161Bu5y0;e1616;!h9Di3;i24E;e0o6F;i1847;!a4BBAc1CnBo3A45s105;!iF70t23B4y0;a50i59o24F2;h29iC;b1Cc2093i5C2n959;!a4Dd0l259r1s37F0t594;e1BnFs550t3A;!d7Cg44s0;!e1i2B6l342s0;!aCe17g0s0;!g33Ds0;k2B56;a167Be3851i3F1Bo2EC8u1950;aEE7;h28;a40EFe10Fo158Du95By1E0B;!hA0lEB;a3389b3CABc57Ae464Cg911h5003i19EAl4FF9o1CEDt1D4ByC93;!a76i23Eo0s0u14y0;d2313eAi1812l35CAm42DFn43C8rE9Et331A;!n3s3z3;n3s3z3;!b7As0t38B;a20u69;!e46F6i0l7o0s0;t1w1;a9i0u5;r7uD;l1t107;l429F;!a10e1s0u49;!a4De106i6n0s0;!s0w16;!e4i6r426s0;cA64;gD2;!gD2;d1FE7i3D63t16;c2An3;a45F9e967h436r25AE;o129u7C9;a93e12l48r6D;nFu2BE;!l0r55t3;l459r3;i20m0t1;!s6D1t1;tB9A;e1n12As11;l31B9r749;!a1FE1d4974e3287g50A4i1B77k47l75n1073s1407t3667u4Fy0;e103C;n8D1r25D;r1089t4D03y1421;i31BFo3C6Ay0;l151Cn2735r36D;!e4g0s0;c55n118p55;a14C1e3E43h26FCi4B1Eo361Fr461Eu3B99w6BB;h1n2149;u1DB;n0t4C;a10oB8;iC45;v558;o9u14;n2159y0;b1Cn1;y139;u198;a1E7Ad1De3007f1D8h1104i6k38F7l3CA9mB6n1A34oE62rBB2s0;a474i2F34o20C5;iA5E;!aDEEs0;!b58e4f7A9i6k4343m28n2180p1995r758s3919t2780v2B;g2088;a1s3;!a4B6Ee4i418Eo1EDs0;aA3i45By62;a20i0u5;bA5;i41y0;a4Ae4i21;a404eC4l4BECo3E7Ar17D;l1670;!aCi5Ds0;n11Bw1;a80e23iA31;eB6i2CFo29;aA3e23i6;!b1DAd0i31r1s0t161w455x0;c4188m3BB9n2o223;c3989m101;e3y0;e2CC2o2F0C;d0rB9B;!c1277g41l1s32;!c1D6e3704l1451s14B1t4618;i3D4A;!e4g5Bi6n1p118s0;e17i4ED5o280B;rDE;c1s3z3;a100eClBu34;h79D;n6Cu14;e42D3i3226;i251Fo30y0;a33FFeE53y0;e0i253l1;h55t2D;e1i0o0;e1Bt7;s1C9t3EA4u5;aC00e4842i4893o44ABu3E57y48B9;aCe1i2805u4D55;n5BE;e502Eo5B7rF6;rB9s36;c1EBk4A03n8C0;e512Ci4401l38r341C;e20F1;c1DD6dD2n1591p1037s1Fx2E8C;a3BF3;r33C;g15ClA8;i8A;!e4f37i6s1C03y0;d1BE;!d0i6l5ECs156;a0o2D31;i4C75y0;r55t112;s1Fu5;!e4f37i86l19s0y0;e106k28;!d36E7e90i1863s0w169y62;a1D6Be3512h2E5Fi19D6l2BC1oE45r4BB2u2044;iC85o488D;!l55;s1C9u5;!d0i6m2En22r0s3E;t2CE;!e6EiBy0;e6EiBy0;!gBl0t3;m3vB3;aEi20F;!w1A02;eC09i6C4u4F;!n4AE5s0;a100Ce4FA6i2CADo1CBy7B;c3d0s3;g101;cB1eB6i3F39y0;!e10l175;!s41C;a12r1;m1r48;b7Al996n8t546;e10Eg41nF;a2D13i87m677o474r5As2ACt182y2556;l32B;a90e380Fi1EA4l33FBo281Bs0y1F5E;a4E02e45Ei1082o41F5r5091u4F7Fy62;cC2e1Bn2;a4E94e3957i35Du471Cy0z1A8;a6Fo35s2D;e48F;!m88n4A0E;i12C3;!p9FCs5A9w1BC;!e202i6s0;d45E8e2C62gB9k1l27F9m2A4n3CD6o48BAr52s1D33zB;a4F69h157;!eDoDs0;aA76;a1EB6;b1Ee4l16s19;!d38El0;e1BnFtB;b272Cg34CFi1FA0k2299l4D50n1683r4E75sBw5DF;d39t16;!iEo0;n32Dr1t38;a50e1;!e39A7i86lF87s0u49;r5E0;t14FC;!a1De1E22i2AE0s0y0;a10lF1nE56o22BA;o42u406;e5n2u57;!eAi233Cl44s0;u936;n1sC0;!a1e9l7Bp286tF7w7F;o15C;a45Ef77Bi411Do21C7;u381;e207i3635r435Fs0u736;!n1674;a32oEF;!e0t290B;aCe0i279;c121d2DABj485l512Fn4ABBp255r396Ft1176u26F7;e117E;!i32A9s0;eAiD9u12;m2140;i70oFy0;!r1s1Fz1F;s74E;l132;a4C3;n627;r590;a4489i70y62;!e9C1l7n22;a25AFb2426c22EDd41D6f4F89g3101h2E23k4F63l1150m12A3n4A59o3A30p46E3r291Cs27B1t2466v357Fw5Ex14D7z4DBD;!h12Bl246;a2CC1e1h482Ai2D82l358FoF08r2730t10B1u4727;!b44CCc2C31e15i19Bl4ED1n22sECy0;!e1Bi3Cl7n22s1D04;a1BE9e4398i978l2AD5o2534r2202u3D22;e3E20i6;b177d1C2l63m64r4094t177;!e529i91m2Ey0;!n28CrBE6s0;!d0s0y16;c55d58i116m415n11Bp452r1BC9tBx346C;a49E5;e4B5;s1890;!c7l7s0;a53Eo15E1u434D;!a2B59e4h206i25Ao821s0;!g5B;g5B;f5B;l561r37A;e5B0p14EF;a3CoE9;i4lA8r168;e26l7;e2B0Fi21l9D6;e4A8Fi3B9F;i36y16;!a4838c4588h311i937o1s0;!d0l22m2Er1s0t1E4w144E;a20i0o29u5;!e9iBs0;e94l3;g0k47D7;n2x0;!e4i6s0t1;a9C5;!d2FDDf4130gBi43C2l2A2m64An395Ep4F1r2A51s19ABt230w465C;u464;bDBgA4l1888m15D4n364Fs2802t3757;l64m2CE;!eC1i1573l7n22s0wA9y476F;d64g11Dl116nD3r2F0t44;!c28AEd0e1FAAg264iB7Ek614oF9F;a16Fb362Ec2Be5l278n2022o1831t204;d37F8;s34;i330By0;u2D8;b3680c4C97dC7Fe44C9f18C1g2891h40B5i32D7k24F7lD9DmDB2n2BA2pD20qB5r2D32s19F8t1BB7u28F5v4C86w38C2x2D0Cy2DB5z283;!pA5s0t43F;e176i460C;a2D0oDF;!e4A4Cl16s0t18;o1539;cEEs11;a21eA4;g35s0;g20DDl18Cm4D0Cn92p1r3EC1s754v137B;o2215;e90n2t256;g1516;a28Dl2B5;k0m1;i912;i679u5;aCEp452;!e6E;i1D59;!n1FAs0;!a39C5e409Fh151i282El13CAm2Eo45C0r3998s0u8CFy0;a3D2Ce15B6i1459o2753u1CD0;e1i9CE;a2656e3551i3401l4512m131En2C3FoFD0t4441u45BAw1A;e9i31;g109Bl1r2B6C;!eAi27y0;!a530e106i6s0;!g1o29s0;h4F66lB;o3A5E;e202i6;a25B6c21D6d3EF9eFA3f4065g1D16h37B6iE40j1436k8B3l43EBm1164n405Co311Ep381Bq13FDr165Es49DCt1AD0uCC7v3D98w5145z1648;n4AB;l4o2A;a4p1;!i878;!d0e1nBs0;e4D32i49EA;f1DDtAFF;l195n32FEr286F;d0r1t1y16;r260;i40;l32r25s11t61;a4200c458Fe4694h31F1i16C0k2356l2F3Bm22B2n3o4CA8q3B91rD22t2EC2u34F0y4F3B;o74y1FB;c0dD2n3s14;!nE;!e26s0t1;a1bCF9;t28AA;!a43F8b20Ec11ABe1CF1i5105l4B3Ap1303s0t1AE0w4911;d132;!a3267e4E80i4027o313Br3A3s4F4uD4y4E8;!e12i6l48s0;i4CA1oD;mD8;g0k0;t143u5;tC58;k133B;!c1D4;i14o6B;c4As3BF0;!e159h1iCAk5Fs0y0;g96l16n4r1E;n1r1t40B;e2D2i32F4o36u14;sA86;a9e9o49;r7F8;a4A9Eu3E1;!d1BB9e35E1g6C9i1FCAs2729u1;b447g63wA9;a0h33A2rE0B;e1i3A8;a499Be2DB3i374Fl302Eo218Br2A84u17E1y4EAD;d2Cn2B8E;g0i20;e2AFiD9E;a81E;n1pD7;a1BBi1B08oACu1BB;!a393Db39ECe1903i456kA4r33C3s0;!c1sE;!l0x0;!rFD3s0u12;c2Ad3;h471;!d1El22o1s0;l19u36;!e0l0r285s0t2B9;e528;i3C4u14;a4Co57;c2DtB;g5Dk4C;!i7C8l7;n267;a3E0Bi1618;!c2A43f37m2B0r0s8;a20oE;a0c44d11Fg28k41B9;!a4479bB4c4DFeF8f38h145Ci15A0l2DEFm1580o47Fr10C9s0t1154u1FDC;cBd4FCn398BsC5t47;h278;h177i12D6;n3856r3939t28vB89;!aDcAA1e313g64i86k40BBl22nAAs0t4B09u189Cx3F;a58D;l3C1D;l2B8F;!c11Eo60A;r16E;a188f2D;e0i27;a3B82l3AEDn1C93p3E8Dr31;!d0s0u5CF;!d2E62i33B5;eAi6m64;e332u1D;f83;a4B96e12EiC8o2D7rEBD;!s0t41;r6B0;a1F2e1;r5B;!b20C3e24g92Bh489AiA78k13F1m2Es1B0Ct373Cy4EA9;!e13AFh38i17BlF35s1C7t415Cy0;i4m18s3u5;e225A;d46ECr417FtB5Du7E8v336;a2432e2324h27Ei37E1o129r3C57u2072y5C;l3n2o8C4;r26F2;a30n386;a109FiE3Eo1792r181;f103;!a203Ee2AD3i3F5Dl1525p37BDr33E4s135Et38u3244y4B86;b26B5;!e20Bg43Dm2Eo10p151r103s13D;d0r2Fs3Eu5;l39Er85;d43Fg2Ck47l37Dp4F50r1s3C3;!e3D3EiCBs0y0;l0r2F;!i10;e31D;d7m1E;!d5Be33i21;a2F0B;a2052i272o3740;s4447;r522;a1F02e5FE;e8Ci34Fy0;!i4Bo1;a364eAi68o46CAy0;a282c234e1123i6l475Bn47r3502s43Ft0;a30iACnEpE;oA2;e79l7n2t0;!n274s2D90;a2F2e1341i4719;a41D0o2FB6;e12Bh88;s211t4A;a4810s5w0;t441;!e159i6s0;!uD;a0e23i2E7Fk21F9l13B1m2BF4p481Dq122s3328t34AAu0v2712w9Ey0;m99;yB8;i60Bo3A;!a170CeF2Fh97Ci44D3n22o4400s43C7u2979y44E2;e380Ay211F;cB1e1n2ECAs201Ct2Cv511;aB87e1B51;u282;!d47l176Bm1E9n2AC5s2021t696yDB;!i20o3CDs0y0;e150i6o1;i3D21m1n0;c2D4Dk2B03;o5F;l3040n1;!d0e9f37r1s0;d0l0tB7;!o14s2DE;a20i178l52y1D;!k5FtF7;a10o4DF9;g2D23j12ECk47n492Ex66;d108Ef1g3B34n3CB1rFE0w206;d0e1y1;c177l1FF0o12r124x1AC;k1r1;!c32e5o5E1;!a4117h26F4s0u2C;i7FF;e0i31;hA0B;a2766c490e30i2BBEk4056o3CF4q1BBEu6B2;iF4F;d16l35D8r3437t1E;m4Ds55;!e67nF;!b337e15i6l22s0;a2CDE;g53;l3Br7t112;c4C7Cd0g25BiA94n1347tA28u70Aw598y1E54;!a80c160e4f6A3hA4i55Cl10Am2Es0y0;!d0o12Fr1s0;b13Cc64e25n11A3w0x117;r1D0;!e12h151i71Es0y0;a364eC5oBDyC;k1El0;!b138e4i6s0;a3CD3eAi37E7;b1F2Dd1843e42fCD2g4480h2F41i1A37jEA4k4380l4789m1BB5n2DBDp2070r313Cs3475t1A7Dv4C43x10BB;!b56Ee1F7iBEl7Bs0y0;!a2073cE95d271Ce55Dg4DF6i37BCj3A9k0n2283s24F1t32D5;!r0s8t1;!e19C7m3C6Ds0zA09;!d0n483r1s0y0;a94F;!c3As23C6;!i4A9o29s0;dFFl47;a3618;d3BBh1;i1ClFFo23E3r1AtE91u44A8;!l16Dn22r1s1AE;eEo74;!a5141e4635oD4s0;!a40i47CBo38B0s0u5;a15F;h1Fi31;!b2F5r1A;!e19h5CEi3Cl7Bs2EBw1BCy0;a5o9y0;o4r8;a0n0;!a50n28s25A8y0z16D;!c11d182l0r0s0wA9;!s0t470D;!a785e3D0Ei1FF9l259n22o28s0u4Fy0;b3s8;!n85t1CD;!e536gA12s0;!aA3d27eC1i6l7n22s0;!a16B1e43D2s0t48C7;!a2078b33F6e2792hEDi18DBo5DEs0;aA5Fb3F71c3878d2ED7eD2Df3112g34B5h17FCk6E5l1367m4756n2102o3719p4969r3FC8s33B2t2D86v44E6x952z17D;!e15i2C32o12Fs0;!a503e12i2E2Fo1D5s0y0;sDA;e1B14;!b1Cs0tBC;a54De7A8n23D3;m8A;bA0E;l1r2969;p1FB;s42F;n2392s2550t42ABx38ED;r123E;f2132i1A;aB98e23h4AAi1951u34;c0o9sFCt7z3;!e209i1075l7s0u9CE;h1BF;!s3656;h47D2t37A6;!e4t0;b2A42;u14E0;i9l75o29t38;c1Ar1;r56B;r469;!gBl0s0;a1412i3601o128;a383;d47t3BC0;!i6p323Cs2F9;!eDs8;a664e42u34;c4BD3dC07e1131g2F79i386Ds0t14B4y62;e642o2EDCrE2;!e4574i6wB;!eD8BfC3iA1Ds0y0;e17l1A;b237Bo1461p2BBC;e6CB;!a371Ae23i1ADDo1s0;a1C5;aA0A;a1C2eB8hE8C;a27AAiE80;!e85Cf37iD9s0y0;!e24i1F79o12uEF6;!mFFp124s0;!r4184;c0n0s0;a2B94e4714oBB9;n1o2A;n2s11t7;p16Cs2488t2D;e85i17C8l44o716;i2CAu4E0;k218t4764;i104;e17o36;!e3337i1B5r3D8Bs0;a116e3491u2FFE;e1i3A;n16r7;i16l116y28;eAi41;eAi328;c13En2Cr24CF;uCF;o23Du6;!o104;t277;!b1FCs0;c5057h1C62k30FCr148Bt3B0;a25Ck3;m7sBC;d1Ek1E;e72i6FoAB7;e6A0;a0c0s3u14z3;e53D;!l7oD;!l12Cs0t1;x11F;e33oDr7;a65l1n41CBr36;!i12rA42s0;iAC3;!a1bAEEe4BDBg2429i2C26l8Am2Eo73Bs4C4t3D89uE5w3031;m39r7F;eAn8;eAiA11o29y0;r2FB;k39qC2r7;h4D87i0o5DEu4F;g3An4;lCm3s8;a31FBc234d486i1715l1F0Ds1C9y47;a2D43u2A1AwD6;rE8;a42h4FA;!e15i6l19s1C7;n2s20D;d19s3B5D;!d102g24E8s0;e41C7;c4Ag4Al28n674r1;a0o14C;s14u207;e48Di1D23y0;!eAi1C0m45C9;!p19;p19;a161;oE5;a30o8;d1p3A;!b7Ae10Dn2s0;r2DE5u1E70;sE0;l3C7E;!n639s50CB;a3A23;!i15Fs0;a1iEB4l3;t2FE7;aB18tBC;!r56s0;!a2AE8b4247c34E5d1A8De3B2Ah4D09iE48k89l29DCn2C4Dp335Br4914s0t3721u2A94v1Aw47C9;!s0t40;!e2CEBi21k5FlE2m150Cn1r7D9s4F98t4A;!b268d1D6Ae4f268i6n1A06s0;e12Bp360;!g3k48D8;d0n22E7r1s8;e15E0;e1i7Du5;n2t29;!e6Es0;!e1741l7n22t339;eAi6nF3;!d0i6l3689m108Dr4289s0;!g7As0;aCi0l4Cn0u5;t4586;l1290n27;!d0n16r93Bs0;o41F6;a32d0e25;c394Fe1g4955r378t44u14;a556e8D8;!p4E31s0;h0k38;r346;!b3F2eC0Di29Bm2Eo51Ep260As0w23Ay4DD9;a43B3i57;!f61Eh246m2E;a460FeE23o1348uD8C;e106i3D;h4BF1;hBi4E7;i24El643;c443Ad114e24fF2n3o29;o2EFD;cD3n35B4t4646;l3BtB7;k32B5;e57l1Dp8;a2204eACiC3Au26F0;d0s8;i25y0;i2323o46u5;!bC96c1E4r5Es0;b43Bd37B5f1C3g190Cm1En34Cp448As5Bv391E;i489B;!b3Ad0m2En174r1s0t1;eBDoC6;a2BDE;a8EFo2BE7;dBv9E;!a39Be12i21s0y0;wA9;r2D3F;!d0f37r1s0v4C;g3A86m3292;j7F;t4F1B;e6Ei176;c301k1;c63dC63g747n2A83p706s547t433Aw28y28;a1003n4CAo5Cu14;i6nB;!d43Ch228nF3p44s325t0w134;r3C06;e23i6lB;!t3648;i18m0;e422Ci388y0;!a5E3i3F;e4CF9;a87i2090v27;n4A15;t3912;aD4u3452;!p3B52s0;a36C5e83i4CC0l1A4o46u5;a23E0e3BC3i34D5o22CEtEBBu113;l2AA;k1A7z82;g48r16;d494;!b36A6s0;aCi481;e1E07i1416o14C4;eE9An82u660;r55tB;t4E27;a31C;h7A;n2F1F;!eFDi17Bo18A4s245t0;f7n363s0;n3Br32;d0nA4Cr1E;n1EB;a38C6e15i21y0;e5g264Dl4943m708nBs1B72t2E6B;o12F;a0e74h1i125oE7u26B;!r4114s11;a54i50r1D9;a38A7b16ABc2B42d35Ee934f2FFBg1E20i5EBl3ECm2EF8n991p1A8Ar16E2t40A9v3614;!e15i1C0r4Cs0;c32i25;b1Ce24n2s11;c2Cd360t2120;nBs972;nD6;!b368c253d3F76e27D4fE9Cg21AFi91Bk14DAn4FCAs0;b1E3e1Bf286n141s105t3A;m45EF;!e12Eo262s0;i4BA;o3EEAr4B69;!l7r7;l415;a9e9o20;o10u59;!a31EEe2E0i54Ap2E4s0y0;!fEl3E16n4B66r18DEs3u2D2Fw4DB9;c32g1;i13C;r4F0B;s2F0u5;i6E4oB43u54;!fBFn3s0;b447wA9;!tE5;a1iE78k27FCo1;!a4De265i253Fo2DCDs3EyF6;a76u26B;!a2A12e4449i1F4Ap29C6s1Ft455F;!d0m2En0p32Fs0;m1B2;!a4047e2590iBEEnAE9s0uF05;b1AeEn7;lDB1;d0r2Ft707;a3A6h0;!o2;o8r3uC;s34E3t2Dz48;f3i10nEr14s19;l63nB4rA5C;t4F86;e6EoB9;l22E2;!a2129eD0i3D7Co29s0u14;e3185;!c2413e4i6s0;s211;l714;!e67iCAy0;e2F5Bi24El9E7r43CuB70;a28ECo94u9D5;!d42DDe6F6g5E4i1F3s0;!l7F;!d0s0w4C29y0;aD4;b18ACi2133m1548o938;c11D1f23Cl3FDn2sE;p39;e12i3Cl19;t89F;o37FB;!l7s0y0;a5Fe35A4h1C2i6o1DE;a1B4u30E;a22A2e2377i2E59l1A7Co4069r1687u841y0;n8r78t3;n1o8E6;a7EeF0n2o128Cu14;n4t1;a2C7i2By0;oF1;!e15i91o1s0y0;a465Eh5AFi4Do4AF3r1BCu2C;zDE;!l7n22;d26D;n4F5C;dBDA;!i1C8Fo5s0u5;c11r16;o32E3;l233u5;u249A;g7Ch1l30F6s156;t6BC;!a4Bi97r7s0;f1BD4iFEn114t28;e55DfA4El1E74t629;i3Al1DC4;eE9l3025;!e661s0;!a475Cb34D1c1630d29CFeFDf2E68h278Di21l23F5m165oD7p171Br3ADDs3A14v24Ew1E82y98;!e4h16i6s0y16;!e10Ep1Es0;a2A0Fe410Fi8Eo73y0;a3CAAd1CC4e4F53g1762h0i2236u18DD;a50r31;r3981;d1n25r198t9B1;e2823;a346Fc2583e383Dh36DFi4425o3D49p485Bs2358t33A1u3345;e0f4537vB;a1b183Ed2E4Bg1E36k3235l11F4m5001n0r1D42s754t192Bz5C;i2571y0;aBB0;c1Cd1g35nBr61;a10e4619g402EiF76l1B19nBo1p3363r3050t4DAEw13C0;e3DAi21v58;!dA9;d0e61;b4Dd1r6B5u2D3z3CB;!a1289e67i3D5Bl22m2EoBB3y7B;i255;a388En2p508r378s34CCv120;!d0l9Fp631s0;eEi2495;!d8Be1C1i86l7s0;u802;e18Bo5F;o4r2A;e2B3Ai1D0D;t139u59;gE31m3C61n31F8p304s4E8Dt38FFz268F;rAB5;!e2A9i2F8s0;e29A7o2692;a4111c309Ee1g2D9k3060nFo3193p35B7r298Es33F7t32B0u154Fw2541;l11C;d1An1;a36l3u5;a104eC4;!e4i86l55Es0y0;e1iB8;nFtB3;g5Dn2o10;c95;a0eA2;y3F7;!m0t71;!i27o6y0;!a10e56g2E6Ch2E19l2FEs0w2FD4;!d218Em4DAB;a1e3Ei0;!a4791c11d12EEe4AEDf9D2i192Ak4E47l477Ao2890r302DsA82t40BEv88;h34D9n3;!a31e10s0;!b3D18cD1g377h1n1D64p7A7s0t1A4x58;l4F6m0s0;d7t1;l1B70r379Es29;!d0s0t479;!a4Be239i43s0y0;n2803;!a1i13s0;!e15i6p3825s0;d0l0r1s0;!f37n22s274D;r16vB3;o4379;e25o6C;l6An35A;l0r78s3t3;!l0r7s0t3;!d8Bi319;!a4CE;l1nE;a166cBe24g63s1F;e15i9ABy0;e2897i6o3CDy0;d1eE;e5n154;!e85Di6p4C;!a3724bAD1c1E4d15B9e1F78gBh3E7i4l7D9m2En22o302Ar3992s0w3294z3C5;a4FD8e70Eh0o2193;a4240eBD1h24A3i2DE9o4B53r48FFu2C41y42F3;!a4B26c45FCeB1Df37Ai125r1829s452v447;e6Eu4792;aCi2CF;e2E5;u211;u124;!i6l0;e465Ao3309u3E97;o2F74;a23Bb28EAe45F4i3C29m10DBo927;aCeB6;!d0k3Ar1s0;a5F1e3AA2iB08y0z187;!e38i13s0;f1C4k3FC4r24D3s35FEt1883v2B;i1D57;a20eAi4A9o36;!d0n255r1s0t28C7;a5i2Bo40y0;i2F4Do30AA;!i2AB3l7;!e15i6j236lF5nA1pA5s0u57;o3A2D;e3A41l64Cm64;r19y16;a1132b3CB4c1C95d537e3972f1429g2648h22D7i10D1jE70kDC8l4EDCm2AA8o2C80p4213q27A6r2DAEs23D8t42C6u4F29v10C5yACF;!a75Cd0l4B4n4831r0s3E;l55E;!e209f37i86l7s0;!a21D5e49A6o3As0v7C;!dFFeAs0;!e15i6o6E7s0;o2F77r367u3C;tFF0;n1r1D6Dt0;c1619f2A9Bk2AA3l3893p1032tD83;e231EiDBBu4F;k38FD;!pD5Es0t0;!a4DC5c3CB3e31F2h3679i35C0l2020m5CAo2BA1p15C8t20EDu34w48CA;o188;r32C;b255D;a2CAe17i16B;m6D1;oCu14;a11A8;a2809eB6i3CCFo40Cu4F;aB28i31F6o10u4DCy0;a80e2294i6;!b7Af121n1p8CFs0;a143Ad413Ae1125i2192n495Ep8u215Dw28y1;!c813l7BpFBs0t201E;g4BDmA0A;e31DEoE65;a12o329Es3u124;u371;a8Ce30B9i2BEl1Dn8p8;a12B5i15Fo29;t2710;!e4i3CDDl2FEs0w850y0;a84B;a0c3D;e3E1Fi290;l42BF;c0d3f7u14;m0n2rC;e33i6o1F;!eC1i86l7s0y0;!d0e24D8f3593l22r1s2F36t3D9Bw11Ex0;g3Dn2o12;d0r3251;r9A8;e15i4BB;i452Dy2E47;a1iBB;a1486c48E9d34BAe1i384Al2FB0m12B4n11D3o4FDp4E79r2798s31CDt305Dv512D;c44f108n25BDt3D9;l9Fn2t34A1;!a40D1c41BCd2707e1C24f3589gE0Ci3B36j1FD1k8BDn3F81o4E6Fq114Cs2327t2141u49v3206y0;u4A0D;e3C2l7o10;g9CFm4FA2n49DDr15E8u12;e6B1;g6A;e23i17B;a2115r88;i263Dy0;z3EA;!c39FFe5;!e15f37iCA5l22r27EAs0y0;!a4Be4iADs0;a2F53;!a4A10bBE1e307Df3BEAi483As0u3FD1;a2B60e275Di9D5l3F69o2EF0r4142;pD2;l29o2BA;a1i57;!l0pC7s0;a43A3l1ABo1A47r3ED5;a1314;aE6Ce2F33iCoE7;a46E7e6BiCBo2BFu3Cy0;b2CAFe1n2s11;r355D;!l25Dr35Es32BC;s3u14z3;!e4fCFi6s0t274;fC15t5A;l43BE;!n3o29;e72iE;r252E;!e5k4C;s44t28;!s117t28;c1EAFfEE8p16D8r268E;k4Ar9t8A;b1Cg37B;i109o0;d33BAn2Ap67D;!l7s1;a22D;s34t14B;f16s8t16;m1B7t1;!eEAl7n2s0;!a8i8;l5097;!eBDh246lA5o10p1BC;o4336;!aB85e3F24i40C3l27r7s0;e1u1;!k4Ct39;g96k3t0;s6B9;d0eAi6;a2AA5c196DfBFn3CE;l460En103r3DD9;u1D2F;sC0t107;r1999;h34EE;t4EA;r3u5;!h3772tF7;!c1F65tB36;e17i413o479Cy0;!eEAn3s3;!a1433d1C43o443Fs3946;e4EF9g3DD5s11t0w3F3;d0nFp27;d0r8Ds0;c27DCd0f3CF1g350l1o1D4Es22A0t58x5E;k8Dm39;k0o34;!b367e9i8Es0y0;n4B73r2FB;aDe9n8;!eAs0t3;eAF9i21;h6B8;e238ArB6;e10El7;aEcEi109nEr3CEEv27;aCe1i9D8y8F;!eCl7n22;!a4Bi13m4E5s0;e24nFo10s1F;!aCe4l7s0;!e17i97l7r7s0;e90i284u24F0;o93A;a165Ce4490lA9o3BAEr3F42uE;!cDBd0m2C85n161r1s943y557;bDDd0x1F;n6Do1;s319A;e12f4252;a4De2A58i2719l4AE8o273Fr1336u2DC9;!a7Ei2887s0;!a3A69e25C9i6o93s0;hC5;h1C7;!e26i43s0y0;a3739e2343i101Fo2195y0;b1Cn212r7v5A;l57E;jB;c43F5;e4i5;e1i4;f0v2B;!e0n0s0t2D;!t2D6F;!e12i25As258t41E1;c65Er48DDs2B83;n2s698;cBi56t3AB;aE4n2s9At7;!i10y1;i4n578y182;b1EeE5m35;cE0e67t16;e416i3001;e1o34;!d71s0;l233rB;e4i29By62;a12A8d0e55Di4C56l46A7;r3y5;!a10gAAs0;aBDe4iBEo29C0y0;a4963e0i29F;a4B95e1CB8i4742r3F9s382Du5F2;!a16e24i6s0w260;i3E1Cl4388o8A1r26Du43A6;!lAAAm55s0t1;!l19u9F;i1D67y62;!e3F30i4E34s0y203B;e36B1i6l3305o30C4r22;iEl1s211;!a52n3Ds0;a7Dt1;!b1r1FCs0t28;!d0e226Ar1;r2700;i36l5D;!d1e4s0;v3171;a0s33C;!a369d0i2581s0;c391;r5B2;!c3196e0tB7;!e4i6s0v18;!aCi20Fs0;a8c2A;a116;a18E5;n333;i152l44u8y0;gAE;!a4BeC1i86p1D2s0;oFu31;u2AFF;i2C93;t34B9;t119;a1D3;l4F6r77u5;aE4u14;i13r7;a9u14;o108wE3;a7Eo8;b8Ac71Ae1i3894l3w9E;k3x0;!d0z3;i2222;r8C5;a300E;a6AAi2By0;!a2A8Be2B54i44B3o1F07s0;e4k1E;a326AcBl48F9o29s35BC;a2D00i26BE;!a10e860hEDi1F3s0;g1Al75Bn23B6r2C7;t1x0;e773i6;!a1De23i6u49;!e58Fi460Bl2Cs0;eDo10;!i3Fo29;i4m1;eC2;s8v18;!e96DfC3iB08r3C6w311y0;!a8b7fB3i9o829s0t41;a428i109y0;h71;a72u3C;a4Dc9Cm28;l19nE;e296Ah246t412C;!s0u4Fy1;e30k16;c174Dd2800l2FDEm4F0Fn307p67Fr3As418Ct9Ez38;eAh0t1;!e15i694s0y0;c4E1;l4r9;w462;!a76c2A07e1i49Fs4538t2CFD;!b2FA1d0l3354m3044n39F7r0s3E;!b25A6dA5h34l5FCn1s0;!e5i21t1;iAB0o12;a3306e158lB;u8F3;!iEs0t49A1;n236;c1FE;!d0r1s0t16;u20v48;m1B9r2259;e4091k0m181n4BE7r19EEs82u3493v3;!tEAB;cCFn114pBq4DF2sBCt3;!l1113s0;!d25;a4De2733i1B5;!e12fB0oE1s0;!a31b368e5115h110i468Do26FpA43s20BBu4Fy0;!e4192i13r56s0u4Fv80B;l7r78t18A;e32h67Fi2494k1738;!e5l3EF;!aA76s0;a3519e23FBi3170o2068;a284Ee1B36i16A2o24C2u4B7F;eAiF9o8Cu49;a243b438Bc18BCk1879n4025o3713rBsDC0t4101u835w3368;t41C1;h99A;h44;e12i10;s3B3E;r1BD6;!a11dAAs0;e1g818n121uE;a8t1y1;a1578;s3F;e1l2E10;aCn3;nF3t395;a3B70b466c23E8e330Ci2B36k1B4Fl4D88m604n1C31o2D02p17FDrBC2s20Dt2292uFD1w3428;e42i125;!a1A5d9E7e42s0y98;!e15i43r35s0y0;!a3E5d0o3343r1s0;!o10p3603s0;l584r1D83;c0e1Bn2s11;e349o1;!n2s1E8;!aDAiEFm2Ep5F;!bFFl455m34ECp10Cs0;s85t61u16B;!c12Fl5EDs0;a2F06e484l3934u14;!d0l60s0;!aCe507Bi1295o1;k320Fn1;!d0l48A2n292Fr1s0;aA4Fe5s14;!aBAs0;e2ACEi72o138u2;!n2s0;r2654;e1t92;e5n22A;a54e72i50;cEx1E;!a20;n0r1yB;a1Db1034cC98eAg32CEi1503m4A7Cp1s511Ay0;i18A8;!e5s1F;a2F6Bi2492o1D;l3Br7;d339l28n4122s2CzB;!e155i43s0y0;l1t1F19;e252i1A;e5o4863;!i4r0s0u5;b20E2d1f3782g41BEi2F1l1639m3588n4C95p50BFr4E98t1814u4D1Cv4DFEw134Dz56;a20iCEu6C;rB46;u6DB;a42i3623;cB54d53Ei6E6n2A5r23EFs7t701;l1Dr40sE;cBg1;!gBn8s0;c35Cd439l82n71t17E;a47A0eC87i41A7;a1454e9o54F;d0s11;a4468h1kA4Et2555;i12u283;h20CC;oD13;cB1g0k140;!l60tB;k0l0;n1t457B;!e42o40s0w14E;a1F3Dd2A2Ce4B6Ah1777i36BBj1321l10Am417AnDD4o2932p1426r4FB6s182Eu2301v223Bw98y5130z408F;a1De23i4D30o8C;r414t14A3vB;h3FDC;h1n1;a40e23i6;rE4;r184s32F7t2D;a5D6;l1t988;h168o56;g0s5;r2D9F;o28r48CDu26EF;l29E;p4AsC0x7;d1t540;a13ADe3C7Fi3EC9o23ACu1730;!i13s0yC;e930;!dE0i1F3;e5l7n2;l148D;f38n18FsB61;a57i87o20;d0n39r1s8;!d1Ee15i6s0;t18D;iDAFl1E;!e2DB4h2Ci8Fs0;!a2BCEc86BhE7Di56t3BEFu87;e1Bn27Bs288;!e4112s0;y2CC;e1D7r1AF;e0hFF;a1CD9e1BF3h7oC6;w260;!d41Cr2FB7s3556t25E4;a1fBFl4896;i1329;g525n38;e5Bh60;!a85e23i2D80lF81o1s0uB8y0;!e0r1EED;cD3d0n52A;e155iCB;!s0y3763;l3At1;mBt161;!d0r47Cs0;c420n454o10t16w1;lA5o10rA7;b7AoE1sEt238B;!a1De5i27m2Ey0;o2113;i634;!aCF4e5Fi0oE7s0u5;e9iBl257y0;a18;l1n144r2Ft3;!a6F;f108l1A;a1970;f95A;p19s376;a2C7i21;n4E3;d0s0t27u5CF;a1E6n3D73sC7C;!d47fB0i3Cs0t1;h1DBE;l2AAs0;e265nF;i3Cl7;i12w32;!a150Ee3F58i6l22o44Cr17Ds0;e26i6l2C;nEzFE;!a7A3g3Ai133o1s0;!b1DAd0i9m3E6Co29r1D3s0;!e1Bi3Cn22;aCeAy0;k216C;l3EF;!e26o1s0;a250Bh1BE3k2C40lECBo1A82;!eBi9EAs0y0;n1s1F;m48t2E81;a247C;a292E;n53u5;!a4Dd0i3Cl259n22r1DFs3E91;e79l52n2;y1E;e3217i8EE;!a3518b2FE9c453Fd3264e2E9Cf39B9g3002h4E9Ci6j41F2k17F9l5143m1A4An137Ep2592r1CFFs1AE7t2484u124v3921w27BFy238;a1b5C9;a20e0;a20e271i29C;a4973s105;!a14o14;iA34o5C3;e19i19;c13BhF2;!f9D2l32CDo10s46D4t14AF;e476Ch1i390Ay0;!e4i6l6Dm2Es1425;a3Ce67iCBy0;e40i1F3o9B;d0e10r203;e14F4fEkBl598m2050n2019v1151;e6Eh1;f3C50iF1t8A;!e8i4s0;k28t1FAC;e3109o3DADp56;d0sA0F;a2836e1C1;eAiF9o40r35;n2As11;!e15s0t38y0;i944;a1C2C;!u48F7;e1Di125;c3D3Bo11Ds15ADt10C;!e15f37i6s0t1D35;a3AE6;l48t39;!f184g588sEC;n361;i25x4C;!a2AEAe2AB6i21o3789s0u2E98y1A8;!e4i21l4C9Es1B69;!d0e0r0;lCn2;c167s105;!e31C4m165;!a4Be15i6m2Es0w7F;u1093;e351i9;k23ED;i325D;p2687;c3911k28t451;r8s8w1;i45D8;i45DA;a166e1F7i6l44;a0n1o9;a0e0n7;!d4BBFg20E4k5Fm8Ao9Bs0;cEEnBr1;n19CE;e15A;!o29y0;o29y0;e18C;i340Cy0;e3F90oA3r82;i1ADBy0;a4Ce37C1i2F46;o3045;iE8;!s27Fy1;b1CBi3;l4uA6;!k28;!d2De0h1;c1Ce12g27s0;!a5t882;eAi13o36;m18r1D0t0;i47DD;a4058o174C;e861fF2s0t500F;r266uE;oAEt3;c6D6e1i152y0;d2Cn37E4p235s8;!a6D7e225Df2D7Di3802l4C68o16DCr2F03s0t0u1AA0;aCe5o719;i4358;l1C3r41E5s0t0;e2390i6;u87v6CF;r51s1F;!e1AE5h4D0k982o82s0u4F;a0g2E0B;a0e23i2DFy0;c34DC;a13D4hA4i4A22m287o42p3693s1FFtD7A;!a1C3BeED5gDEiB;!a11C4c2106e679l395m1E9s0t3E8Fy4164;i31o101;!e3A82h837i3F8o29s0;!l1r7Cs0;e1BnFv27;l3Bn8t610;e4C0i3F5;cB1;a6En35C5t1;b1DBd114m1565n4867sB1tCE1;e5f7n4A23o10t7;r3A1;nFuE;d44rE1s3CE3;d1p516;n4202;h56;c0fC9n19t3u14;!d187i3Ck1n2A4s0t37D;r4s11;!e654i8Es0y0;!e1p1E81s0;!n153t4E;d407E;!a83Ee9i8Ek5Fs0y0;m4BE6tB55;e192EiE1o121;e28A;sC0tD2;a0e3384;b4B0;cEEk16;a9e0k1;e1Dn3727;e20FFnF;!b4172c488Ee5014h1l42AFn34FEoF3rCD4s26DCt4AF1;!aAF4e23i6BDs0;!b37DDiA07mAAo128s0;e1Bf274;d5A;r194Eu6E;c120e1Bl618n1EE1;!e357Di1B26l20As0y0;cEEr3;h11;nBv3;cEi10n284;a54o63C;!e676i3l7s0;rF4;d16e4AEi1ABBk47n78p2430;h18F3;yDEzDE;!e4i2F8l6Ds0;a1C5Fe1AA2i3B60o3A2Br1F47u5AC;y3779;g3x0;e4i29By12F1;v16FF;!d0l789r1s245;!a5E3e1DCDi1FBCo1t1u1672;aFFDiBy0;!d8Bi97;b2C76c2023d3947i21BDm393Cn3902r489Cs2DF3u13B0z22EE;!e4i21k3BCs0;!e15i6l3s0;e73;e1i2905;i3C4o46;e3476;e10Dl7nF;n25s16AD;a50e17n1s11;!d17De3598i292Dp358r366As0;a21F6e0t127;a0c30Fe1h2C1Bi31k1m1As2D50t308F;n1r35;cF4d0r1;t3B0u1B9;!d1CiA5s0;!e4i6l69Co11Ds0;e222o1;a24Ae1i4546o29y0;k4A7;nFs19z19;aCe1i248o1;i4l0;!l7En8t3;c4459e4A36i3597l50FEm4Cn4884s2574t3B33u3163v18;o570;a27D2e39C1y81E;!e1Bi3Fl7s0;c441D;n37;f681;i989o54y0;dAFFgB;s190;a33C6e23i3AA3l3BA;i70l7y0;!c89d1BB8eAg1283i7CDk47l22nAAsD29;!a12E7e3472f37h4CB8i14D0lDCFoC23p16C5r16D6s44D1u19F0;e0i16CCo6C;oC4y879;!e3A58hEDi3Cs0;!e5A0;aCd2Bl9Fs1Ft2DB;c2Ar9;aCd414B;!a3FF3e4138i21s0;c9Cd8C8n58t0;g157j954k362n320ArC8;!a509Cb5137e2276f17A9i5B9m22Co2C58p4B05s0tB4;c3e79n7Es11;d3673n2s0;m346t4A;!s1DA;!a1D7Ag3960m26E4n15EAo2D74p4330s284Ft27Eu158z35B8;m45C2;a3C98b15A3e2DBA;s24A1t0;c19l1D;s0u14;!eD0i21l22s0;e36;a0c0n2FD;e3840;dB3s5E;a291r18E;a37AAb0i38l8As44t2E89;k8A;!a16s0;b44tC5;rEu40;!b1ABm2Es0;!l7n1FAr1s0;a51u1C;fF2m64t2B9;h8D;!e554i8Ey0;e63F;!i13l2Ds0;d16g1680;!b17Ce2A9h60Ai502Al3F97s1Fy0;n3788;aAEFe6Er2551;!a5037b228e139Di1FB0k1927l32DAr58Cs0t4B97v28y0;dBn65u1;j6D;a3D41;mD2n2D;p197;!e1FDi6n0s0;l1Et0;!d3t3;d3t3;o101;!e1Di20F2t160u34;n0t3D;!i2Bo29r7s0y0;m36BA;!e79i6y0;!a50D0e1A9Eg4424i3DBBoB0Bs0u2E8Fy0;!r1FA;i81;!d8Br7s0;!e5A4iCBs0y0;!i8En4BE0s0y0;i51s1F;!s0t38B;a1F2e1i9o29;s65;c32dB;e3D8;!a3A71e1Bi5D4l782n22r63s0y0;!i35o12s0;g435Cl267;gA5o1Cp16;n118;eDl7n22A;l0n3FA4;iF7;i90r164;n8r1t3;n1ECr5A;l4A7D;o404uE;bCD;o9C2;!o9C2;n1B71;o3EB8;!b14Ee1ECEfB0i4925m2Es0y0;a4173i6;c145m29;c53h3;l236Bn2F3Fr141Es3676;!h10m2Es0t1CAE;!a373Be2B88iE59o46s0uB9;l8E1;!c301s0;!e0l55s0tBC;n1B0;!b1536c1368d3BAe495Cg1DFCl2E77n3184p436Fr1746s22C8t30DCx11F;!m18s0u5;kD95;a0e3CA2s3EE0u34x66;b983c4BEEd4B71e5g3EC0i30D0m4BCAn4F55p201Dq4DB5r243EsBC3t766u25CBv42E5w17E5x56y4B6B;!i279o10s0;!a23B8e15i157Eo36rC8s0u311F;!e5A4f37i30Bs0y0;e5E8;!eAi6l36E9mB4Bp4568r1388;!h1s13D;!e155iF9s0;e44C;!n1B04;i5B6;!a1e15i382s0;!i5B6;!a3D52e108Fi10C3l18A1o3014r50ACt623u18D3y62;a2978;e0i644;m8;a354Ab5Ce1l75r3D3u361B;!c7s0t2074;aCb7Ae23i290;d963;p1E49;!a47FBe484Dg63i1t3AB;dBi25s0;a4De239i21o52Du4BF;!e4i21k5Fl364Ao2AFs13Dy0;!c3655h358Bs0t502;l11EFn0r1C7A;eDn22A;!e15i30C2o29s0wEDy0;!aFsA82;!a453e5C0i21m2Es0wA9;!d4C54g16D;aDDg48iEs11EE;!g44m47Dn3y47;!a58Do1;p131D;l71nA1s3Du5;iD3D;!d0r2Fs0t0;lBo46;l48C5;a1745e10F0iA6o99Du36F;cEs8;aCn4F33;d0g48;!h1s0t33D;cEn464;!e4h1i6s0;e17t1;aA19d7C5m789;g1B8k7EAt38;l0t19;e5nFsE;gA4;a6Ee3FE2h21Ci3024o336CrA71u9;r1u1AA;!a4718e431i1A2Eo2241s0y0;f1834nF;eC1i6l48;c4751gBn2832t3B74;a496s0;e1u55;e14Di3056v58;!a9A8n2E9Dr4821s31D2;bBd1f3CAg370lE8o2E73t18AAu1772w31E8y1C;a1D73c1DE0d20B8e15CFm251n2EA9s2EDAt91Au448Ew16x4372y28;b1Ad1264f40A6g2D9l36C8mD87n4697p4F38r2FCCs2CtDEDz20EA;n132s105;a28C2e1828i45E6o2958;!b25DAd35FAg715l5047nBr715s15E4t4D84;d1l4pAD8;d0t249;r2628;a170e449Ai2A5o512;iBBu5y0;!c0e1Bn3;e1n210E;l59Bs8A;!a2964e4083i4612n22o5B1s0t11u276Ey0;l41En397;!aCe53Di299s0;iAD7n1y62;e7D6i2By0;r227C;aDB9eF6;aB04e23i6;!e3180iBl3;u95;!d27i31o1s0u34;c1A4;a36E2e322Ai1319l2272o2BC5r4BF5u31A7;iE8n0;!aAD5d607e42B1i4D6Fl2C1o4D16r342Es0u736;e830;a2E2Ae4B13i146o37D9r643u27CF;!c3D8Ed1711g42B2i47BAn3B0s2A3At2DA3;mA1n65r34;a178i0u5;m6FC;!eAi21;!t4FFF;a4CC9bB5CeF0l1A83m4E0Bs4003;d41tEE;!a93eFDCo6F;d81Fn63;l1D0Em0;a4Di4B04;e6Ci1066;a3106e33i35Du2E0Ey0;eAi5114o4EE7;i55B;!a24E7bFCBe34F7gD6i1F67m39ADp1s0uEy0;c92n52;d1f38g4A1Dl5nB6r2AFEs243t1A8B;a13A5eB6i3D16oD6B;nE2;!e4iADs0t0y0;!a3E73c4BF6d3C37e3D05f12D7g3095h0i1259k43F7l22n4D0Ao1D0Cs2F49t127uBD2;!e24A7;i4oDA;l1n27;d277C;!b3606c6C5r1A;i50D2;e30g1Cu20;!a69De4i6k867l1n1108p270s0;w380;!e5i644o46s0;!a3B64b4458cE2e2408i14ABm3D1AoE7p15F0s0uA79y0;c42EFl25C8s1063;!e10Bi548pA5s0y0;a469A;a47E6e174r1A;aCe15F8h1EF4i3FF8o4FF;e42B7iBEFy0;t9F8;!d0s0w1E3;!dAAi39BEn1DEr3B03s0u171C;aCc4332e23g3EF1i4685k39B3nA63o4915pF6Br4BEBt4255y0;c32r0uD;c32r25;a7Ei31;b49c3AdA7q122r3FD3s1B83w1;l149s4E1;e99r236;e12l44;c1D37eB64g3175m3D74n4C3Cp200Br1FC4s8A8t3348v515x1F;r5D;w47;e0i3Fo29;!d0m2A93s0;a121C;a3DA7e42Ci47ABo46;!b2DCCe4C1f263i1BE5m2Ev24Ey0;a49D;e9F6i68y0;g2FCD;a162B;d0r16CF;!e4i168Bs0y0;l4DA7t1;!i10l1Es0;!a4De4f37i68o0s0y0;a32h38uD4;!g2DA4l7n22s0;e86A;d3181n3ACp36Bv14F6;b4C02;!e5l25nA1s0;d3Br1t39;r417;a378Ei13;iD7D;c3CD4iDt27F8;!e529i91y0;u31;d3n1AC;!eDFm2Eu49;!i35s0t7;a3288e426B;!f1BFDi70s0y4ADC;!l2773m1n18r3FB8s8F2;c4593g11;eCl1;!a43Ab3423e12i21l4C94o515p431Fs1EE3t6EEw43A7;l458;e18i0u5;h55;i451A;e0i8Ey0;!i109l1Es0;l28mB0r40Ft47;n398A;!h11Eo9Br491A;o282D;k1B8Dr44CBt3872;l204;!l4AA;e4i6o262;uB33;n1960s2At277;a14e3D84i8C6o400;!h2C3Bs0;e1BD7;!eFDi1C0s0;!hEDi21As0y0;e2264s1Ft40B9;!n1s38EB;a59o1C8;a1871e1E79i61o4220u14;e12i2By0;!a227e1A3Bh2A0i68s0y0;!c89e2AF0i1706l7s0;!e4i548s0y0;n18Et48;!e4i448s0y0;i14s5;!c1D4e4iBj6Al7s0y0;!e12r7s0;!f3C0Fi3Ct4EB1x576;b28n63;!e12f37i3F7Ds0u3D;a3e1i3314o241;e16F;!h29D7i4FEo3575pA12r3A20s0;d0n8D;m0n2;!d0r1s156y0;!e1iB8nF3s0z331F;f7n2s3z3;!a3C48e3F57iCAl44o48A9rABAs0y0;eDu5;a76i1FFFu14;b0d1;aCe33g0;a49BDe1A7;a1i70y1226;!a8B9d99e3C5Dl7m1Ap1As35B;!a136e4i2617s0;y35F;l1DCBm6FrE;!c0d1s0;c0d1s0;iB8o1ED;!e4f37s0;!aB85eABCi6l52Fo13DCs0wA9;rB5;i13y26A;!d8Be85Ci319k4Cl1Er7s0t40;h1C2iEFlEFt1458yEFz9E;hEB;g0k1;o307;c281Am56n179t0v3;a1379e38B1i5035o40A1u6y2066;rEE3;!cD1Ch1Fk3152o38D9q2EFs1C01t2F2Au10;o507;d16i210t0;a453e265i57Dy0;n671;c1DBCi1C3k5Bm2Cn39BDp355r4A8s13Cu16BxAF;e4Dl35o49EtC5;p218t47;a3A22;e8CiBy0;g1E12;u14A;d2A0D;k1n1;r19t1;e4062i4AD0;o1A24;e15Df7l7n2t7;!a30e23i6u49;b75d1e1D09i2130l160p1Ar4AD5w906;g747s19B3u5;i2281n2B63o2D83;n4BE1;l27B7r6D0;e71Dh1E5Ei21;aEDC;e12f38rB;a11Ce1Dp1;a9r46C3;l0n8t3;e30lBu1C;k1CF5;!a9A7e3D26i482Cl75s0y1D7;e172Fi8Ey0;!d0i6n28Er78s0t2D;l39E8;eDn2s19z19;b1Cg3n65;d0s5Et71;e0i6;i5y1;!i1994j53l1n2EFEs0u90;c5Cm11F;n1FD7y16;!l242s0;!e3i0s0;g5Bi4m1A;i383;!aAFCe5t0;!b2BE0f37h183l2BDBr1s2772t46D;!f37s82Bt1FCw169;!e12f37i43l6Ds0y0;dBs3u24C;a3E76e80FuA79;t4696;a1C33o58E;i16y29E7;e119iB3o40;!e4hEDi29CBl22n22s46AB;b1Ae1B9;l1r16;n3AC;a2CAo67C;e60Bn2;f4C01g350l455Cm238Fn2CF7sD8Ft38v44;a69oA1F;eAi4D45;aDCb29fD08u34v19D;i2Bo2AFy0;!n2s45FEtBz19;!e15h151i21s0;a2A52o1BD9;i174;a4c2At0;a4De4i6;!i801;e0k1n0t11;eABh1Fi21t2954;a4De4051i21l3B0y0;d7F;i31o1;n118D;l98y0;!a20e4i6o29s0;e3F4Dn0o9B;g55l1BE;p0w0;f191F;b1DB2c2AdE60g29E2i16D2l333Cm3100n5126p3C56r1F1Cs4356t3FE9y131zAF1;m64n83;!a12s0;m118r755;!e4C20i32p19A8s0;d27t38;a54i72o32F8;a3F49b1B0c22F8d2C7De2245g5152i3761lE02m15C7n4A79o650p3CAFr2BECs22BFt1DAFu13A0v3w1CA8z2E37;!d1El7s0;a30n83;!c7e0t3;h38C5;i144u7;d0r39s8;!e4i6s0u5;d1n4797p2C00t10ABv6A6;!p2F32s0t38;c167e5s812z48;!i3DD;!iE;!b1CBh11EtF7;i3DD;!a11AEb40DBc1D8Ed11CFe4AABf1A16g3828h217Di2B86k19BElEF7o34ABp367Cq2EFr1E94s2EBEt180BuD79v11BD;!e67iCAm2Ey0;cD1;e6A8o261;!n1s3E;i2442o1;b1CgBx1F;l39Er7A6;!d0l2BADm22B4s0;!c50D1d15B7g1Al28D8m1240n4FEDq122r28s3EtA80;a44CF;l7oF6;aEACb2694c3F59e2589g1256i7B8m4B4Bn38F2pBD3r39F2sB5Dt4CA7z4CE5;r2E27;e47DCg4A8Di3C;b4183c1935d4BCDg64h112CqA44r2B0Dt13Au172;l13Fw1;e180o46F3s857;e4355hBCBi3261lBo360Cr22;a3DEBb2F82c1A40d36A2e275Af513Ag3A1Di1F38k16E5l42F1m2543n4540o2D48p3CA7r319Fs3AB8t121BuBFAv4FD7wA9y1913;g19n212rE;e3F;l1C9t66F;a0e1o9u14;e2C8;d204;hB37;!d0l0r0s0;eC4Cr3F4A;a15BEeEFCi2230o2C4C;a1s11;aBDeE1;!e15i21s0w169;i137lBy0;a31o20y61;o34sFA;m5D1sC0;!a1d6As0;a14B7e9;a0i20o46;c0o10;d0l0r2F;aCn3t7;rB3;c2BAEd9B9g1A5Ah206iC9Ck1331l329Am436An1F42p125Bq1579r1A43s4603t1E5Du3E56v3C36w98;!i3Cs0y0;uDA;!e1s0t45AC;c32z186;c519d1DDk2CBnBC;eD92;a364eFE;g1C5A;e4326o17uB8;!s0uAEF;!rE3s0;b1Ag145w2Fy3A;!aDi2868s0;!l0r7s0;!i13u3;!a18DFd4858e42CFi4E5El4F15m160n22o10w1A92;b1n52C;aD7o104;a2006eD12iEo512r3C2C;!e15i6l219s0;!a42Bb2C21d478Be4FD6fB0g30B5i1CB0l2D65m1E9n4267oF48pC41r3A80s0t46DFu311Cv15C6;e4i4645y0;iA66;!a188e3Di20s0;b2C1;!a2D7e4DC2i1588p45B9r474Es0;!hEBm2E;!a12D4b3Be4g40Dh6Di73Ej6Dl196m2En3Ds0t3AF;!r1s0t1;!e24i7F6lB;a360De123Dr2E65u25FD;e1fB;a394Bi47F3u4B29;g100D;!aCe33l3s0y0;a65e17;dD2i4m1Au5;!f183n22pA8Es8A6;a4455;!n11Bs0;e9i6l3;!c2645h16F9i4299p1432t69F;a38Ei3Do0;!d0e1h1E3r1DFs0;d0n1r1t16;!l7n1Es0t1C;c4AwE3;!a50eEA;a0c0o29u14;e30i4oDu172;l2A7n0s243;l1r217;e12g38;!a12e5i2By0;h2C30p1E00;r231;a30i1F6y0;f1EAp2C95;g27Eh3A3l195C;h66o66;s2BB;a4AoAE;a3B79eBECi38CFo36y62;!nFtB3v3;!a16ECc3E3Ee3AD5h2A09i4BBBk22Cl38EFn4140o126Cp1479t868uA72w2B47;t4B74;!n22p2665s1A6;z11A;zB;!z2B;e1g6Au20;eAi1E0y0;!e191iD9s0;j18n53;n287As221;r10AE;a50Eb457Ei10m4624q914s4B2Cu1751;!s1B8C;!s11;l49FBm816nF13;s1E8;!s1E8;g96k16n4D51t3AD2;c0g5Bs51Dv6A;o3809;a3ED1e11D5i317r22;!e2D6oDAs0;i181;a1B09;a8c8t3x0;d0r1t3241;i5C5;a2AF7e4971i3857o4C65;!l7r0s8t171;e48D0g1D13i2A13;l38;a6E9eAg4405i3937k30Do3A94u34;l28n1r3550s35t1;c1B0Dg34El20A1o3FFEp4348t4FB8u439F;a1FAy6F;!a11BCb3BD6e35ADh157i21l206m1097n34A6pCD7r2315s3BCy0;!a903d0e697f88l22p8EFs2CDFyB;a11i9;i3956;tC14;dD4A;k1AzFA;f2863l44;b1Ct161;n718;gBnA3E;g3s3t1;!y1;a3BDe712i6;gBi2E76o47FD;h4BC6;!e0gBl0r0s0t3;a2A32b2982c4AA0d309Ae4F08f39A9g3BE4h12i2372k1F0FmD98n3F62o5146p3BCFr1285s2ADAtDE5u3A09v1838w42B8x39AFy1z5072;e2342i2By0;r134;!i13s0u3;i13y6C;h2829;!hFFs0t502;!g502h1s0;r267;t1F81;!c28DDe4i21n22s0;!e4iD9o12s0;h1E97;b7Ae1;d3BnF;!e0l4BD5m79D;r39C8;a1m64oB8u34;e8i0o1;a1De23i6t8B;a30i4862;o232uE;a2FB8b656c120fBFg227nFo4DC;f47D5;s0v3;!g399s0;p12DsC0tB;r82s3699;n79Bo29;!p266s339Ft5C;e3627i3F;e19DEi3785;r198;!c4Ee1C1i6s0t3B;u2BB;!e15iA77s0;!d9A3e0i295El1n2E6Ds8A6t276Cy1;!m1As0x1F;!d0fC3s0;b1D25g25Bn3DF1;a0c44r3A88t22A4;g96t0;u5A;!eF80i6s0;!n27CrE9;e8CAo4E67u4293;s10F9;pA89;h1908;d3A4De1r7;!a253bAAc329e7A2i20l23D4s0uAB3;e12h1ACr2D;c5Ce1Bl7n141;c4828g91El4EE3m0n28E;e5u14;d0r0t16yB;l16D0;i2699;!d0e10n171As0;m4C38;aC3eDi490Fo1D5;d1Ct7;yFED;t4050;m7B1r103t4CAD;aCDiA5;!a50e67i6o1A1;e1y6AA;d1En1E;xF7;!e35Ai6s0w6B3;!a1d0mBs0;a333Ab20ACc17F6d137Ae3F3Cf1557g1F95h2049i4E77j12FAk2510l2639m35B2n46F4o45A0pC50q13E1r20D5s315Dt416Du47F5v327Fw293Ey665;a20i9o74;a23Ec0;e6EiB;a0o4605u3E1;n36D8o1A7;e4h1E;eAoF8;i13t2D;e3CA3o9B;a106o1u435B;n5DB;!s0w2FF5;a1Dh3Du3D;l3F2;i9n2B;n1A1;u1B9;!a4C0Be1DFBi3102o1E9Fs0uBv7Cy7B;a9e9i65;!d0e6Em64n11Br50BCs0;aE6l1EoE7y0;e7i2B;n41FF;c1BAB;a4Ci386Fu6;i402Ao2C5;!aCe0s0;n323Dr133;n19p1;!a3E5e15i21r22sEC;o23F8;!a20B0d131e4CD8f9FDg315h4F7Ci46B3o1DD3s2B7Dt3FBBu1y130;gE04;e17o8B;aBDe4l22;!a4149e3EBEi2D95o8Fs0;o27FD;!pB;a9e9i31;!b44AEf36ErA21;l25u69;a255e1i12BB;o9A;!aE1AcBd1BA3e1DF2g2A6Fj9Ek513Cs2976t5Cu4349;f182;!aA7Ae25F5f37h30Ci30BCl2Co4263r229Cs0u379y43B2;n2E16;!a208b6FBc9Ed0l3459m2Er49B3sECw2CA4;eAh509i6o13F3;g42E;cEi10qC2;e412B;m2D5;r9EF;r7t1E;r78tB7;!b1ABe15i6s0y0;o146;!d0l22r445As0;t22B6;s1At7;!a31FEb4CE6i9BEo4CE8s0uB54;eAB4u206Ey0;i1ADo1u5;!a2220d0f1BCm2En1r1sECy0;r5s0;x78;!e4p7s0y0;r61t2D;a82Dc596d4F20e43A4i13E3j1427l33ECo23EEs392Bt49BAv2E11;a3FDBh4367i4FB4t230Ey2F90;a42h2644i36;m82r17B5u12;a3E2Ad463Fe4E13m2FF2n42F4o3207pC8Fs3313t2ABEu77Dv2E28w2754;a212Ai30A4oF6u8;a263Ce1F41i369Fu14y62;d14Fg96v3D;p810;!o1BDs0;a0i3BFo986uE;i3Cl3EA;!d0iD4lF1n50AAo1r4A2As1FFt2Du1;k16l0t1;r7CC;!a188d0fB0h246l20FBm1BDo9Fr58s0t4B90wED;c13Be23i12A4n218p1FD6s3;c2Bn11Bx0;!d8Bi97s13D;i3F4o3C13;e26o6B;i9m28r8t1CFu16B;aF6Ab18CEc3457d1E77e20A7f4484g18AFl3F4Fm4BB4n3AC4oDA4p271Es3FCBt3B65v3861yC8z1A;a17d0o10r231t16y1;aA66s0;l2503n66D;a12hAFi0s121;!a20g48i3Fo29s468;t4D63;iEs1F;c1n1s34;i111o12;!o1D;!i27l19s0y0;a4Be202i4664oDr1;!h78y0;a9u9;o1F4;!e23i6o11D;c35AFd4FA3l3E4Et277v53B;e23iF9o12;c1B6dBt2F4;!d0f37l50Cm64s0;t9A2;p85;c32w39;!a9F4i6BFo35A9s0;o17EA;h1FsA68;a428e12t7;a2D3Dc199Fe1EF5g39DDk40F1t28u3602;o6By0;a28F2e273i27F;!aD1Bc2DEAe29BCh43DEi18CDo1078pCF2t30F0u148F;i1220y0;dBe5;c4B3E;!s0t388B;i1BF;c7l1t3;t810;!i319;i0o138u5;rBs4EF;!d0r12E3s0;e0t20u12;g46n18;!l6Ds0y1;!e4f37iCAl22s0y0;e1i38;iA5EoC;!a90d0hEDr1s0;!aF0s0;a4B1o7;d3183;l2F5CmE17;!a14FAe12i25C7j6DCmB4o2B0s0v134y62;a0e0i4147;!a80p165r1s0;a20o46;r2BB3;l26CE;!i3DE5o4196s0;a7AEe1o1u4F;lB3p7u30;a1oC4rA7;e12r16FA;n218t1;n6E1rBF6s1FEBt1;b1EFEcD1g71Al89Cm8Ap1r5134v168x2FB;aCDDb2197c3B31d1543e43D0g2652j1D17k44l4CFFm4AFAn3D67p49DEr4B9Bs2F42t481Av2876y1AzFE;!a253s790;r3A84s44;!a37DCe3710iD10oEDBu23C2w4E1D;a2C2e6Bo40D0;!h16Eo6F;c9Cd34C;!a32E6e113i3DEDl22o1F1Bs0;e1Bg96l7;!b588s0;e1F0i42C7k5C;c32mB;i56o10;!h1Ei18m2Ey0;!eFDi43l48s0y0;i31oE7;!a3ECDe15i6l6Ds0u1C;a2605;c3FA2e1;e427;d4FCCg44BDk56l4r34Es314Dt21F;aE9e1Dl19uECC;c2357d1Am1Ar58t6DBx1F;d7Bv37A;e181;!a52b56Ed0f286l7n22r0s14A7t1502w134;a3E7Dl4;e1nFp1E;i31nEt112;c3d3;r1A4;d0n4EE;a0i20;!h2C71;h401Bt53C;!c11t7;gEC;!f26E5l0m45B1nBr3s0t3B3;a335Dc2BD3d3F46g1B89i16CEk2Cl39B8m1204n18AEo3AF1p1EF3tE5Eu1395v213w3D3Ay0;!a4950e10D3i6l10As0;!r8A5s0;o424;e1Bf23Cl7s13BEt58;!a4De23i24FuB9;!lB77;d0f0l8r0;b3834c31D0f478Fg49D0h4C9Ck1D9Fl2A9m1856n2465o2027p15B0r1694s456At477Bu4847w2201;e18C2;c2B6A;a318DbE97c426Ed466Ee28E6f4C4BgF46h30E1i4493j4DDEk18B5l4982m4EB3n502Fo43B9p33FDq27B8r4C8Fs3FC2t1B82u4CC4v2F35w4179x3C4Fy3F19z2B9B;b32Dm38oA5B;h270;!m3s0;a1345i355o3C70;m3s0;o87;b3D8Fc1EEf1C8Bg834i4B4Ck374Cp2688r4B93s1676t12A5z20EB;l14Fy1C;u1AEE;mA5D;!h1i9n371s0;i2364o1;n4BE;t44F8;c14Ff7n2;a17e8A0i3F8;c96;n20F7;a398FdBe2F3AiA65l2A5Bp8r173Cv5B;!a20i3Fo29;!i6r180;o46FF;n425D;l1Ay0;g2Cn1r1s21D4;a6i6u6;!i27l6Ds0y0;!e1i13r7s0;e297Ah1l257Cu4Fy67A;d0n3s11;b1CgBh1tB;r6D5;!e15i3CFBl259o12s0;l139A;a76e33;hE5F;!aCe33;nC9s190;e2291h4F3Fi2279o441E;a166h0i2By0;a195b1D60d80e1044f1D8g4C72k138Bl3F44m47A8n3B47o2A66p200Fr3C9As1859t31E4u27B2v186w4E6B;l1BEs20A3;m7n8;e10l9FnBt1;!e3BDDm2FAn258FtF7;c32kBn2o10rB;!i3Cl2Cs0y0;h44Dq195Dt0;o1CF8r2DsA84;a51Fe7A8o1586;e17D9oEA2;l459Ct13Cv2D76;i5B2o5A6y5B2;m14B;g3Am2FA0r31E;a8Fe1D1o21D;e883t1D9u14C3;hF7i2B65l5FA;c30Ae3454i73oB43u12F6;!d27g16;!a115Ec3B32d4AB2g18C6i2477k7A9n3765s1A6t2D73y0;!e18Cl7s0;i28A;e497n2B70p718q315Cr916s5E2;!e931i419m19Dp8As0;x3E;!a4Bd8BhEDi3Cl20As13D;nEt256;d0e373g0i4D9Bk47y0;h0k0;!d7Ce0i3A8oEFs0;i40EB;!iBBs0y0;i786o678;e222i3A;lBo4;n690;k4CnFt14B;cF4;!d0fC3l22r1s0;eBiE;b1CtB3;!e4i21o49CAs0;!e15f73Fi6s0t0;d48sE;!e0m283Ar2D4;!n2BE1;h19CA;i3D0;a362o10;c2Bx0;!b1DAcDBd7C2h183i509Fr110;a876o5C;a2CAe2351o3A90;eD4h391k58s4CFt11C;e0t7;c92f7qC2;!a4e4i6s0;a404e9;!d0m2Er1s0y16;a57e42;!s0tF5y0;!lB3A;s2A20u2BB9;e23i21k1l1A2y0;a30FFcBu14;n4E52r41A;e1r5A;h9BF;l9D;!l9D;f31Bn2;a4552c88e3818i21p19Er486sC79u2988;rCB1;rF7;lE8n164pF2BsEt61u16B;c340n71s2F0;i3B1Fu34;l5F6p49D4r326C;r2D2u12;a3E03b464Ec2A59d2A38e38B9f44E3h242Ci3536j4B0Ak2C02l262Bm3CEBn4D70o18D6p1A3Aq502Dr111Dt3088u38D8v2C78w4F79y1E23;c1n3;!e4674r2DEy0;g3n1;l3714;n0s14;!b3F6c5078e1804g29B2i2DAk4Fl4F46m4F91n17F3p3BBEs2A1Ft20E1z2C0;g127;rAF2;vB9;a549;!fF2n2;!a4De15iBEl259s0y0;a30e353oC7;!a224Ec1779d2F9Ee449FfA23g120Ci3A93k395n338Eo31FDs2A98t3DDFu21A2v2936y325z4ACE;e1B3D;a4EA3c22A8e2E9Af40Bg2BFFi2931l1360o41A4u44C0;!a52e23i68l22m7CoE7s0u1y0;r36A4;a8Fe3253iA3o42;!k28n1369r169Et86F;c5s0;!l22nAAs0t47;!l0s0t3;fBFg1EB0l686;!e4i6m2Es0y0;a2B6Fd1e3F54i1D14k363Cl163Co28p3563t2A7u4EEEv2794;!n16s0;a50e4B3i6lBy0;i591;c3g2Cn2DAFp8vB0;r19At11;c32d444k27ADl1880n0q122r21FBt4A;e0hB;e350iE;iAC6;d1El3Fs0;l3F9;a13CFeEDEh2BD0i2089n37Bo2CD6uF3Ey12F3;!a30b2002e0m4A0oBB1p47s0;a1D71p47;!e24i6y0;a12u232;r3F10;!c193s0t933;!d0j6Ds0;aE5;!e15i21r22s0;e21F0h3A;!e15i21l22s69A;!i2B6l7s0;!m3531;d2431;k279C;!n1A0s0;e365i43lBy0;!d0e0f37r1s0;y56;n1o10p39w1;g5Bi4nBrC9;a4D3CiB8;!e15i6s0t0;!i7D;y97;h3897p4808;cEEvA1;a456e3A8D;oDC;g44F;a4F10e32o4308u73;!d0r0s0y0;!a4De7EFh1Fi4D2sA8At0;e18Bi33E1;o17;p3As550;h8Ak47;sA1;!a20e31s0;!e385Fi47AEo1s0;!gBr25s0;lB3r27Dt1;!e4C8s0;e14C9;e1CF3i8CA;gBt3;g3CAm1;b47C;h82i13y0;h270C;b6D;d6AeB2n2;c35ClA8;t3FC0;c7BCe1Bf1FB5n22s23FA;!i70y62;i1B24oBED;l1t763;a1802e1799i4AF9o11DAu37D1w988y33BE;e12i21;eAf1E41i6;a1o1FB;aCb58e1o29;!fF2l9Fo9F;c0d0g5Bl1E5n1;l303m31An2B3;c185t1;c1Ee51m1Es35z1E;!a9DCe7EFu34;!e5s18;!i3Dn3Ds0;b1CgD8l8E9n170;o108;i152yEC;e4o8;i6D9;!a1i3A62s0y0;o63C;g5Bs459At2D;aF8eDn2o9;a3DEl2C;!e16E7i6m2Eo1;g27ElA8m251sEt396;!a10o10s0;p4A9D;a1DoE7;k1l3A;!a144De12gAAh4B38n4285r51Bs0u1575;b3560f6FAi1C3p3793r76Ew1FC5;s80A;lCn3s11;!a50B3e894i44D7s0t6B4u435Dy0;a50dBi3F20l4AAAm2110r4CB4u29C2v3;!iC13o3160s0;aDCn2;a2D0;!r7s0t41;i3EFC;d181e42A6gBh3165i2134k28l28n3812tCF3;!a38AEeFi4E51o54s0;sB89;j53;d5F;b2C42eFC5i6l4E4At1912;g63s2E1t145;!a21EEe1EF6h44FDi49Fk5Fl22o2275p472Dr35s0;n61Dr1t18;!i3C83o1EDEs0u15AB;c32k1l1;!e84s0;e4s0;c1Ce1Bf7l7nFs0;!e24i6s0t11;!e4i6l2Cs5A9u4F;c13Bd38g1B8t6EF;!a4087i56u34y0;!b38D4d1F94i6l6DAr1s0t2DDBz2C;o7E6;e0h4241iB;!b7s0;u1C70;a1e411Au111A;e5t7;a43B;a2A96eD7BiCEE;c192kC9;a100n1rBs35t3;e4l4E;b27e1Bn2;a1457e25DFf446Dg2603i50D3l445Fo4451r1AC7t46F9;a30e23iF9o8C;!r196s0;e6D2i280Co9B;e417E;e48Bg1iFAA;rFE3s8;!i1Cl22s0;!e12iBs0y0;!e12i2Bs0y0;!a4D6eC1i2F8l7s35Bu34w7F;a2D8f23Cp3DB;r145F;c1D6;r17E0;!aD1s0;f7nFs190;!k4Cs0y0;!e1BC6o1s0;!e17Ag0i6s0y0;d88n397s1Ft18;e1Bl7v3;u1AB;!d0i6l278s0;!h170FsDEt1A8y1B31;!a2666c2815d168Fe0g3Al466nBr1s1424t4945;g3D81sBC;e17i20;e37Ei20;a1F71e1D91o3844u700;!i54p40D;!b2077c1EC6d9E8f3DB2g1C21lED7m31DDn28pE4Bq2AC4r4A1Bs2591t1825wD63;eAp0;l1Dm2F5Ds3DDE;e5f203D;h0i4DB6o101;!e159i6o1s0u14;a10c1e1Bl7;nE55s1238;g5C;!e12l115r7s0;!l19;e1Bn22;i289;v18D;aE9iD4;!e23i290l19s0y0;!a1B9e654f37h110i1BD2l22o343Fs0y0;!a2BE3c1AA8l3208m2382n8r497As1024t2DuF90w0;k90B;!d0rE3s0y1;i1E05l37A;a3C6Bo36;!g251i2Bo28r13As0y0;dBe453t1;!d5D3e449i6o12s0;s5FE;a33DCc1C64d2B26e410Ag16Fl35E8u36w1;e34oE3B;e276Di388y0;eF78u41F;e2755o54;l40A3r35D3;i2C64;c2Cd2D9Ci4s9Ct61w2CBy182;e12F7;!a181Bd177Cg127i4D3o13A2s0;!e4r7s0t3;a3963bF9Ac3624d1CDEe18DAg1017i3BA9k31D6l2Cm2901n4AA9oCDAp1B8Eq3495r5029s4B51tF09u4BF8v27DFy3B7;t4C3F;aDeAoE7;!a5Fe1Bh82l7n22s0u1501;a36o49;e919;!d2E45nAAs9DEt4F23;!a43E8b7eAi5BCo98Fs0u2C1Cy0;k3E5B;m5EnEs35;!e28C4iCAo31rDBs0y0;i817l1A;t41B;!o3As0;i3090;!iC52s0;e6Ci77Ao2D7u95B;d1AFtD2u2194;l3o10v3;a3AF5cDEe3123i3516k12FCl3D30o403Br31E3u36E6;n1r2F;z29DD;d0l11AAn1r893;!a47E5l75s0;i3133s0;c2Ae3924l12CCn3DC5rE1s23ECu510C;i111o8C;e5Bi75o126;!e23i4BBpA29s0;iBBt1;!i29Al7;!e222s0;!a76i18s0u14;c518k28m1;l1t3F;a3E81e30i918o50;d0nB90r260;aCd28e0n4928t53C;dBn1A;aD1Ae23i6o7BA;r4Bt3;e2E48;s2AC;e9i13y0;!a11e5;!b538k2396r1s130D;eE1i9B3m2C74n3435p5032;l3875;i2Bl2Cy0;s2At3;h7Bi6F;e1i1DoE71;e4i1B5;b2544c477Fd36F8f1g4F9Ck2C52l282Fm234Dn35B1r193FsCFEt2CD2x4291;a42e6Ao4C59;r2Ds2D8tB7;e273Ei6;e2251;f612l1An461s1F;o312C;f85r2E9;cEr1;l4r14;!c52Bd0fC3l4A4r4EB7s0t126wA33;m4B36s25E5t17E;!n212Cs3;i22E1;e1n16r0;e1Bt1;s9C4;e0o27DD;r39t3B;!e1D1Fi86l7m2E;!d0eDs0;g28k28;!e5B0;e6C1;mF7n17FB;!aA6Fe19B4i6s0;!e10Bi21l175n22s0;e72i45o49r88;e1Bn695t3;!i31m2989r4980s790;!sB2B;sB2B;a54Ci8Fo272;e59F;i2Bl257y0;i1C99;!e5n2D;aB19;!e12i3Cs0;!b24FAs0;r39s0;t45D9;e1o29y0;n42A;d18A;c32d0r16;d1B3;!lF1n2s0;!l45n1298s0;a4DD3d5088e2F15f289Cg28i384Bk1n18o4DB7y5z41;l1AFn29F6;e198s0;b628d44g2Cs493;c4DE2;e206A;a9A9;!a1C0Dc226d2329e3f7B3g209Ei1471l43DDo4EAFs0tDD7u423y7B;o811;iA9F;a1316d199i0l1BAFt28u26B;a9CB;!e16Cn115s0;c7s19t1E92;a40h0i109;e42i2By0;!e42i2By0;!a0i0o0s0;e1636i4D74y0;s1Ft112;i2CB7;eFDi6;!d477g96s0;e39A0;t5FD;l2116u1;c944;a4Ai445Bn230;!a9AAf8s0t1;d4Bf2Dn2;!i91y0;n2o40C;!e51s1641;r4070u12E;p1r1D;e0i15F;nC24;a4F9BbF4i3B1B;d2EF2;d28p33Er28;c3F9d89e298l2D6Cm77n8C3r400FxAF;mBn71;!e15i1C0s0;o2C8E;h2A9D;l52A;a0o4D1E;a126e12C5i40DEo18B4r30DA;i652o497F;cCC;d3Br57Cs5;a59i95;m3A1;h4123;!e4i6Cs0;!eAh1786i6pFADs0;a1c1Ak95F;!a87g7Ch1112i35As0;!a36E4e4271i84Ao81Br6ADs0;n2o9t1;a36EE;r16t1;b7Al1;!d0i6l1m8DEn2003p157r28s0t3914;!d0l22r1s0t126;a1b1CBmB67n114o4F2Bs30Ft4902u1537xC0;!d225i3Co1y0;!a1e10FAi2F85o39F1r16Es0uD4y62;i59o54;g1Ek1El1C3n13Cr13ABs19D5tFFy1E;r2CB;l4F0;o4023;!i21Al2B84m268s44B8t6B4wA9y0;h0r0;m74FnF;d0l39n16r1E2A;f3D7A;!w134;o104yC7;a9c0n2t7;b4416c2678l2F1p1s57t3D76u221w4152;b8AcEEr3775sC0;g1m1;a0e30;a12l2Co52D;a2D57e398CiFE8o12u1422;s35t2C7;m0t7E;!g2E4h45E1r8C5s0;i148t40;!aFEFb11F5d2CA3e4848f73Fh110i17BFn1DEo52Ds0w3E2y2B64;!e26s0t0;l4D1B;a32F0e20Bi2EE0o13A;kE3mE3;e3AAi70Dy0;d3F3Be299Cf3FF5i1E7Fl114Em1o5021pBy1727;!aCc151dB42e557h151l0r1s0;!d39A4i6k3F3Dl4D5Fm1n1B9Ep431Br0s3EtE84v16F4;e21CF;i83;!l22n8ACs0;a3E3Bc46e4AAEiD88o3CB8s127t2160u6B2y0;i0s1F;b1B0;!f98s0;g192n65;o404;!e0l2A86;h3358;eAt264;a40CCe433i6o12;aD4h1;p1E4C;!b1D2d0h11Ei21l49BFr1s0t227;!aCi13o1s0;n3y0;!k242o29s0;i87C;tC;i3C4Co208y62;a466Al1C9s1Fu14;a4B31e1327i20BDo12BAu3767y11A;e42u49;b3De1Bk4Cl7n2;o2CB2;aCe1BnFo29;a3805i24BBo447Eu261;d1E2;eB2l7n2s11;h1E1;pB46;d29A1e1i2F73l37A1o3D2;h1Fi8FsB;b43Bf958l1245;!b50AEd40F9e4g81DhA52i6k2A73m3C31n154r1C4s22F6t47C0z2B0C;a1D0f364Et131;i18t0;r1D9;!d0l7r1s0;!hEBo6F;!e3Di25D2s0;!a40e9B0h1ACi32E5s0;!a4822b2946c25AAd1658e3869f3FFAg2BE6h1E9i2205jB4FkDB3l3146mC0An29BBp1907r3722s26E6t35E9u34w4692z1B5C;c1ABe5;s5093;e2AF1i2DA9t40;a149e15iCAy0;e44ACf5DAg34ClE8n35E4p1Er2Cs4EDDt4B1Cv2C;!a9CBe2A9i863s0;a15AAe35Ai4C5Bu14;bBDEm268As1F;c2BFB;!a4De15i21l22m64o12s0;c1FE6g96n11C1;o887;m2D3u59;!c1E4d0h151i6l47p10Fs0;h8n1E;!t10C;o1A7;a1e0iD28k28;c457kD8;a1A0;e15Dl7n2;eC1l7n2;!d0r1DFs0;!l1Eo29s0u31;!a1De35A1i2BD2o129s0u4F;a10d9Bn273As0;c1gBi12;o116;i5B;aB29oE;!e4f1D8g3177i1B5k27Fl22m3D0An2FsA9AyC46;a2EEr1A79sBC;aA83p1F9;!e1Bl330s0t7;i4n2Do10u5;r8s5;eC4;o241;c0n37A8;a2F1Ce99;c2E8;!e3CCBiBEl22sECw23Ay0;!aEo45DEs0;!e529iADy0;!a9e296Fi17Bl7n22s0t11;a1B49e6Ei2Bo45B3y0;aA2fB4t2DA5;uAA6;n52t14B;c3C8;i239Ao23Du444Ay62;e1Dl22;!e1n2s0;!e5n2s0;p27vB96;aA3z1A8;e71F;i0n2BDs0;!e661i871s8E2y0;a10i21y3301;r49B7;c28Bd0i12n4758r64t2F4;b1s2AF6;i1Dt0;e14i13;g3t1;a48C9e404Fi173Bo4215u21A4;!d0l408n4812r45BBs0;!a3419b88Cc226e1F6Fi4A27l284Dm33F3o560s0t361D;l1n221s287E;!e23i6m19CCs1753t11BBu4D;!e285A;!lB6Dr39;a43EDe3A9i6o512;!i3A8lD3;!a17BEe571i17C4o190s0y25E1;a29D0o6;d1210;n0u2BE;d0pEr8E6;i1702o5A8;cEEh4DB1k3E89s10DF;g1iBB;!f37i6;e24n2s35;i1n4DFFu913;lA9o237;!a4De15iCAs0y0;aDe3o4FABu2DACw8A;a0e9;a9e0;lF20n4CAE;tDCD;o83A;b7An2p2B;d46n7;a57oDB;k28n47;a2B5Be1E6E;k490;t4807;aF8Ae1CCi3C;l2Cn89rE8t1477;l1An1;d0r1t16uD;!a36e4h1AiBEm2Eo36r337s1C7wBFy0;!a414Ce5i1C97y0;a1Ci1C5;u46;!a1523l1509o29s0t9E;a65A;a1o8;!a1D5El2E6o16Fr121s0u48AD;!a3FEBc18E3e8Fo442Fs0t5C;d19pEs5;l815;t276B;d6EDo29;!eBg3DB3l88o4E06s4F4;k19E8m1;a1A57e4F5;y1DEF;!a80c9CeAi3311k3400n4205s0t5;eE00o2E29;l2E6r28E;y2FDF;!e4r0s0;!aDDe4i448s0y0;m2En2B5o10;d56e461i20Bn1371;!a0e26s0;e211C;i3821;p1551;e1Bl7n12A;!a0e1BiBl3115n22r1Es0y0;a20DE;a11e3AD1;!i3F83l199s2F89y1D66;!e12i91r7s0y0;e4i6l44;!d92i6k2Fl1p1A4Es2B71;a445;g559l4F41r0;u424;o47E;a100e5;a2927e2FC9i1922o872u179A;a3DEzB1B;aEE1;!d0l1n0s0t1B4;a149;!b1Cd3Ai1Ds0;xB;!t2686;a69e23i6;!eFDf37i91s0y0;a2175e4486i3316;!i62A;!aA3eC1i86n22s0y0;c1FDBe5k462m38n31EFoEs1F;i13o505;a113b11D9c2948d2395e2F40f2BF1g1F90i1FCCk4Al494Fm16A0n1881p281Fr3A51s477Ct4E48;!s3E;!n4042s8;!e15i36A8s0;a1De24n4D4t5A;!a7C0c3961e1C19h3CBFk20DCl2FEq122r4D8Cs0;n39D1;h290A;p1C3C;e159i68o0y0;c4136e266Al11E8n27EFo0r5AtB;!a1185b406Ec2C8Cd3915e30FBfDA0g446Bi210Fk32B9lF3m4749n4631o3210q122r38B5s3BC6tBE7w311y4E41;!e1BnFs0;a66Be1254i319oE;!b48B4e223i3A70m3EA5p3C07s0;i190l48;!b4DEl20As0w134;!e12n4814r1F20s1FFt1F6Bu479;a162i3584l1A;!k0lBp352Cs4656tF59;d0r7t1y16;d0n1A0;!d0e1l1E5s0;!a31D4d8C8e2DC8i29Cs0t4CAF;a13e5s8;e1o10t23F4;hECD;e7FAi435y4682;a8e24;l16t1E;l0t29E;!e1F7fB0i19Bl2FEm93Fo1s0w455Ey0;!a260Eh2580i2BDFs0t3C82;!l5Ay0;!a4Be10Bi20AEs0y0;e186;e1g5D;r38C4;a4Be15iAD;n1FABr4CE;a87i1796o749y205;eAm163;e398;g1FEx1F;!c2E8d8Be3E37fB0i21k63ElDA7n37Do1918r229s13Dt3F35v2Cw23A;!a41A9e1DfC3g2F84m2En472p2FE1s0u4B75w3131;d0l1EFr10Ct1;!eAi45A3l7s0;a4A3eEi148;e6Bo2BFu51;!e150i250s0y0;e1F0i863;g622k68Ft25E;o8EA;l1n2v18E;e220Bi3Cy0;c38CAe5g63;!aDCAb14Ec4E42e4DC9h12BCi4EDBl7n22o36F5r1A0Es39At2D36uAB3z38;o443D;!d0r2Fs0y0;c0d0e0;!e209i3F2El7s0y0;r23FF;l36A;e34r48t4B4F;n11C;a1F2e202;!e4i6s3BC;!d0r1s0wA9;!a1Dc18e1hA8Ak4F70s0;t1BE;d26Di363F;!c1s0u116;!d0i6r1s0y0;!s752t1208;iAD7y0;eCo51E;u39C6;!a4A46b3599c266d29FBe351Bf0g5Ai1A41k3310m20B6n10F6o1A62p2EE2r228Ds3F03t21E0u103Dv41C8y2FCB;a0m9C7o9q8F8t2A7F;m3173n272s4007;!h4855s0;d39E5l26Cs0t1688;a4B21c316Ce505Fh22ACk3E0Eo2410r22B3t2566u2208;!e1Bn2;eB2n22A;!e1oD75;t4A1;a1DCd0l6Dr197;cE2n2s11;dBm2Ds4DE0;g1A91l2402;e4B2hB;h38uB;b611;dA34n82;a38ACe23F3l4D39o93u79C;d0r25C1;cA7n1;!a1C6b7fB3i9o829s328t41v27;!e67i1D5BpE2y0;s9BFtFF;e3657;e5B4i379;!a50e630i86s0;n2A39;a30i3Fo29;iA3oDB;r1302;!a40F3e4i0s0u5;!e352g2EAl40DCmD59r293s0u8A;b6Am8A3;!a4BF9c467e2E0f28i1ADAl36Cp2CCAr43Ds0t4830v2By0;c765l1FB9n6E1r164s1B58tB62uBD;nF4D;a441Be21F8o172;a4EB6e28B0iEoA6u6yC7;gCD;!e4i5011s0y0;!e4i5013s0y0;a9c35;!d0l4Cs0;i4642l3y0;!f6EBsC5u1w1;r22F2s3F77t2478;!a1iE69s0;u263E;i4CA0;d5Ce172g1406o321D;!b42Di6n22;!o10v3;lE5r2A6;i4o412t0;i4D2;a2B0;n4089v2Cw0;d1s14;!i3A5Bs0y0;r1F5;aF1Cb2BF0e2304i4C64l1Am2FE8n1263o4610p10E2r3559t2966u1AA4y4E83;a1D1Bd38D0e21E7g5E4i4565k1AA1lDFBm2ABDp9BBr110Et394v18;e12u12;iDn3B5uC;!i4B9s0;!e4i6l48s0y0;eBi39EBo0;!a4Dd0l638r1s0;r220s1A;!b8FFc4FF1e15i419l2618rEB5s50CCw4243y0;n1A8;o1Dt94;c2ADp1AFBt2453;a59i4C19y0;g47k30D;hDEF;o29u34;t1Aw1A;h2B72;b4E38c13F4d19Ef7F4g46F1iFkBm2157n4E00p39FCrBs2E35t20ECu273v2E17w194Fy4616z1CE5;e30oC4;d4E3;t308B;l496E;i27o9By0;!a4Dd0i21l206r1sFFE;z82;!e84i6s0;iCl4o2Ar3;a4De2E21i6;e17i663;c1091s11;t4397;f451k2C5Al47m28n4803r47t0;c19eACm19nEs18E;!a17BAo93s0;l3n2o9v3;eEi31oC7;!fE5i8Es0tBw850y0;l63oE;b1Ce438n1566o1;e3Di1BCDo27E0;d8Be135h242t0;eC67l4D04;d0m0r1;!n22r1s8;!a9d48Dn3;f675t1E;!lCCs0;n5r16y1;r2D8F;!a80e1C1iADl22s0y0;!i8BCm1As1878t2Du5;u1229;!e1C4Dh2CE0i3A55o1EDt1EC8y0;e5103iB6p47y0;!aCD0e4D81i33A4s0u361E;!i1614s0;!l1n1r7s0;r2736;p1r1;m46A9;e1Bn317Bt2851;d0r57Ct1;!fC3gDD1s0w415B;a20i2500o29;eEAl7n2t7;!a615h75k15EFo340s0;i102Dy0;a12i31;!g6B8w3F3;l447D;l399;c235n1r272t2C;!g258Em50F0s0;u43AA;s267;!k0l3AA7m28n1rDEt2227;c514C;r39u12;!e760i6y0;n4C7F;t4477u4F;e1i20Fo9;!e83Di6s0;!c254d0k1p28r269As52t2B7w8FE;r14y16;a1E64;!aCo29s0;uE9;!b1187e1Bi3CjFBl10EFm141Fn22r52Fs0t1282wA9;!cD7s0;b98p83;l29F2;d1u506A;n2s5B;!i1Dl3Br40FFs0;a14DEbBc4FB1eFDFf11EDg3891i3E13m105An73Cs39DCvBw0y1ED6;eEu20y0;a1B12e9o51;a12c8e2C2s3061;a1274i9D9o17;rA;nFtB;r4986;e3B56i21;!a2CEAe3514g3E52i120Dl339Dm41E4n30F2oEpDEsECu3FD2;!e33t1;e33t1;u39B4;c92l1BF;!o1;!e4i4EF5lF5s0y0;c0n2sE;l1t8D;iC4o1;i21Ay0;i9EAy0;n4826s686;c235EdB94l31E0n497Ds26C6;lA8s3E3t1AE;c36D0g17Dk181n1CAq771sDABt47;!e88i36AFoF6s0;i3FoDDDy1A5;pE5;!n831o4547t87;a12h47;g270;!e8i1s0;!c3BA8e3F34h45B8i33A3kBr1269s0t2698;e543i6;a0c8E8n2009u14;c0o8EB;!p3535s0;a8Fe9E;i261l3D9Fn580p4F2Fr3DCA;c205l0;!o4FBD;a8DAe4BClBu1C;!e5n3t0;eA4i1D3;r690v7;bB;!e15iADm2Es0y0;u17;!a7CBe15i86s0y0;c0tD2;a407i75Ao74;lC62r3D6;c1C76m5F8;s19t0;r60tB7;a7Di70l1t28y0;l2FBB;e42i2Bu6y0;a4c2An2o2Ar4u4;e23i6s0;!e23i6s0;!e5B5i6s0;s4250;m1An1F9E;e4ADFi6y0;!g44FBk28nB0s83F;n1t59A;e2EDBi6;i251Dy0;r19F;gA5;r0s0x78;!a20i651o29s0;c6F9;d47e2D49i1F24l16EyA36;n12C;i232Bl257y0;!s0w514F;e1Bn18Fs105;a8e2203o10;c0k1l2144n82s16F;!d0n65r1s0;e11A;o4r33C;!i21l7n22s0;n1A4;!a32d1f1k3A1l1472m242Dn66Ds3A4Ez5B;!d0nF7s0;iCBo6y0;c2Ad89g3C0m408Cn2910tB9A;rE68;!e9iACCl22s0y0;!b38Fe27B3i21l1141s0y0;g1E43;n42B5r1;!g48;n2A50;a12e1;e3E;!d0i6k0s0;r13Es2Ct13B8;a4959e4B3Di1B2Do3ABAu48E3y0;l1D0;k42;a3D6i12;n5E;l3971;m7C4;d19r48;aBDi18B3o31Ay7D1;!n56r4E07s454F;!a1DC5eF0Fi25E7n38o887r2CFEs0u14C8;eC1i6;oA6u72;i6F2;f7n2s11;!i3784l7s0;f1D78s0;b56dAD8g25E0l270n83r157sBt227;!l1A10r36s759;a356Fe271i29C;a1B9Fb2F54c4A71d4AA8e1i702k1l19D0m2CBEn306CoC5Fp4BE3r107As12AEt3E54u2CD5;eCBEoA5;h632;a343Dg0o36;!a70Ae261Bi6o5EAs0;e12o4A2B;i2Bp7y0;a87eAi6;a30d115t8D;e15i3642y0;!e288Ai21o238Ds0;!t60;b1CfBFl3E66n2o10;cB1e3DFt28;t1E2;e12hEi6A2m1E9u3FFC;a2616c2Bu14;n14D2s8u5;a3s0;m94;s3C1Ft1394;e407;!a1BE1e155i21n22s0;!gB15s0;!a3DCEeDD5i317l16Dm1BDr89s0u46B;a14A9r1t1;n2s3;e9i13;!d0l7r417s0v3D;b23A2d2981e142g1A7Bi31F4m463An427Br215Fs28CC;w8A;g34Ei4t1;l2C1;!i54o6F;!a80e4i68s0y0;lB5B;e1q122;n516;eAi6r124;t5AA;b3F6l84Dm2138n152Bp1ED7t507E;a4e506Di1C8oCC1y0;h21E;o416C;!t38u22D;e1Bs51D;!c197n71r3z522;b561;w11C;l8ACt28E;dA2FeAl2D91m5DAn291Dr7Ct1C3;r1AB5;r7DD;d1CBBsC11t2DB;p64;i9o40;hEn3B;t21C;!d0n624s0t1;eCs0;l35n35;e1FDi6A5y0;d1Al1At4F59;e3AF3o4EFB;o10t1;!e72Dn19AFo29sA18;d0r1t5A0y1;aAC6l50FFm11D4pB9;k1l1r1B68;!a1B39b116Ac1D15d131Ag108Bl4D9Dn29F3o3297p1431qC2s1067w356;!a1e1r7s0;i1965o372E;aCi16DAo489u5y3D72;!f6A3;e3D1Ei31;g976n1x1F;o5B;e3DC0i6;r48F5;!i5F9y0;aCr3D;h374t7EC;!f1258l69Bn18CBr4722sA27;e57p8t0;aCg0;l1r1t1;k250D;c1eDf7n2s3E;c1692k374p38C;!a3E5Ae884g2146h1A8i3C4Dl3C6o1742r437Bs0u42F9;!a2C3Ce477EiDCBo56s0u29y0;s19t2D;iC7oEB;iEn25x1F;!a36FEi4A9s0;!c11;!e4f51Bi6s0t3935;hB2C;i4m3r4;!e1F8i3Cl7s0w7F;a1B1;!aA3Ce4AEiC2Fo3795p2523t3AF6y0;f1767;a59e17i65;a14E3;e14kB;a100e1Bl7n141s105;eDo9;aBDi57;!e1l2Co6B9y0;!m3443s0;!a2F2Fc3FC6d2B55eBg4AF2iABk2EDDm2A18nDEo2C0Ap3A5Fr1719sCA1t1CDu4F;!a38C0e17f38i46F0o1B6s0u36;!e23f14Ei3F2Bs0t225Cy0;a59o31;i50DDo51Ey0;!e4i6l22s0;t4F2D;e10Fi69;!aCe12s0;d47t0;l3s18u5;a34D;e18B7;a61t3F;a69e0;r330;!e1FBs0;a2F48i451Eo35;a1D70b4FB0e3336i3BBBmB4o1AF5p3527s3BAu3A89;i111y0;!b247;e10En2t0;b1Ci835n27F5r2BD;e1Bn2t0;bBn19F;i1323u22D;a474e5049;!n27s0;!n426s0;!e14Ci41E7m2Es0y0;e17Ai6;d0n2BD;a4E8A;a23Ei248u908x1F;!i480l7o12;e48AB;a21De2D6oB18y2EDF;g7r2E74;a0iB8;e150i43y0;i23El3u348B;eAi68y0;b3688e1g1C3AiA14m27A4n50FDp4CABt4BCFu24Bw3458y1;e49F4;a3C69b178DdD35e205Ef458Eg1B20i351Fl12D1m3AA9n4CF5o2473p48A4r464Ds14BFt3076u10B4v279Fw178A;a11A7e4F17i3BD5o49A7;e1k4Cn2;a1E9Ad4Bt19x1F;e17i8F;u318B;r3281;a47FCb2038c4981d2970e4C7Bg2DE6h205BiBAEk4B47l46C9n50A6o1C0Fs1977t2F13u27EBvDAx2E09y1EE0;p186A;l5En19s1F1u59;!e3C92i6s0;m1An1D21pBAsC0t2D;n404Bo34D3rF;c1EEe15DgD25n4EC1s2ED3t3F2C;n1BD5r10CA;b1Cc5Cd1CDgB;!a134AeCFAf14Eh840s0y21D;c2427d3F50e1g42ACi2F59k2A7q4EA6r13BCt1CFCw2B1Dy0;i18o29;!i6r55;a227e2908i6o129;dBm4178nBo8F;c9FFe1s105t58;n4533;!eB6hFFl7o29s0u22D;c32r7w8D;eAi4B78l3FD0t1E8;i3C02;d1B0;!e15i43A9l7m3815o1AACr1C2s0w98;!d0r3391sB75;d50Ey483;!e1Bi51l330t7;t91A;!c82EdB31l938n305At3D8Av49A2;s2A34;sAE9;a35B0eE87i4BC7l2F2Bm49A;a9A1c472BfBA6m514BnC38o4DE7p395Fq4EE8rBs2563t13AAu2FB9w43C6z4AE4;!i13oABs0;e119u49;e6Ao400;e1Bg96nF;!s2C9;!i20r19As0;d48D;i178y0;a1EDFe846i4CD0o243FuE35;a21A8eC1i2608o98By0;!s0tCC;d2641h1i152Cn1FB6r4CE7s3654;d37B4o1A1u1;g145;n16o10;a47FAe416Ai178Fu14;a21E4l1BD1;gDE;!e7i3Cs0;nFt21Fz2C;m38Es29z3E6F;!e0l0r7t40FE;e493D;!s0v19;!s29CAtB9;c0n0t3;a35Fe1F28iBDo1241;d63;a20e1677y0;e15i316y0;a4d0nC8;a428e1Di2CFo29;!d4Ei4m3;!aCi20;!e26i9oDs0;!e5z6A7;a4716;!d2870gE82l22m1DBs0wBF;!kAAs0;c326Fe804h253Ci6k3085t1B3E;a26Fe90k40Ft2373uB6;h19Dy416;b1B9Dc2959d1127f2E53g439Bh28i42F6j3E8Ck10E9l462Cm38CCn1DCEo3ABBp2CD4r4A30s1B93t34F8u4D90vCC3w2338xAFy2A7Ez38F4;d3D6n11B;n3CDA;a25o14;n0o10;e1170;!r2C4s0;c3Ae1Bl7n413C;!c20BFd3021g49AFi3Ak46BFs3791;a1499e14AAi1CD8l3333o4754r3636t33F9uEy294C;d8Bl16;!e15i4CDs0;tB9D;e10Fo1D5;eAn2;e52BoF1;!e3C16m8As0u116;!eDl7n2s0;a2A9Fe4323i1F4o1D51u349Cy0;e24n2w236;n1t7;n249u12;r3999;!e6Ei2Bs1Fy0;e7AEi8;e3D78i6y0;i16B3;!e12Eh110m165s0w98;a99F;k1Et1E;u6F;bA1d19r1A;l1E5;a50l31B;r1C07;h95El3EDAn1t1DDF;i2D51;!e31B6o2B5Fs0u13F;n2s105;eDDC;a300eAi6;a6n11A;t299;!a1s0u2C;eA6g96t1;!a230Ae13A4o3D28s0u1B03;!a4DdA9e155i21m1E9n308Ao46ACs1E4F;l1Ao11C;l1E4;t28C;p201;a30A2e2350o22F1;t6D8;!e4iCBo1054s0y5B3;a25ClB;!n1BA8s0;g8EE;b103r89Ds12A2;b1Cr16;!d0r1s3EB6t962;!b1Ae5s0;i12mE9;g5Bi25;nD2;!n4EA;!a1e15Al207Fm3B8Eo1595p8E4r3B9Bs3A74;!o73;!o54s0;kCD;s34C4;a28eAh180i341pD8u2E04;e12r1267;a0c0tBu14;n52s14;n3s14;eAi317;h2625;!d0r1s1Fy1;k4C5Do2DCEu44CD;eA2i18;a24Bc306Fg1B1Cn1B18o3B8sD1;e664;!e40;!aBAeA4ChA04;!nC84s0;a1eEm75w1E3;!a127FbFBe10Bi86n22s0y0;!cD3m4287s0t192;!e0k1s0;x506;eA6r3;a3ACFe40i165A;!h246l2Ct28;e433i3658;!aDFi6n0s0;!n65s0;!cFF8sBA8t5AEz3B6A;o2B77r367u472A;cD3l3Bt3A;!e4i6o10s0;c1Ce5;l2B;l11A;i14CA;!e10FDi21Al175m29FAn22s156y0;a34e4i3434o670y62;h1E2z12CE;!a1052e1215g328Cs0uB;!e1D8Ai21s0;i45F1;!c4ADd13Ae4fB0hEDi6k4B98l1393p2B3Ds13DwED;a3B4o93;a32Ai4;c0e5s153z3;a1B4b102e1i1346;!a4443b20EeDD9i21m2Eo515s0w6DE;n260;!oC69;e1E6;i89E;a40g3CFnF;a4Be4i6l19;n39t39;a12eEi224o3D2;i3FA0;eEi2By0;i46;aE1;!a0l83;a22Ei20o4787u1EB5;e1CB9i6;m39BF;!c4An3E4B;a42Bi21;e0i125u158;b447Ac9DBgD82p17DBt818;h1Fs1CD;sB56;!r1s5;d8Bi1F3;c5Ce1k5Fn94Cs1F;d0rE3s0;!d8Bi1F3;!a0e1i125;!a40ADc115Cg3E8Ai4329k450Dl1AA5m1217n3645o26CBs11At22A9u1030w2E05;a0h2AAo0;o6y0;c3BCDsD1;o50Dt490;i4C32u4ACB;!d0l4A4n0r47s143Ct3176wBF;!c193d1n39s0v48;!n22w134;m318n0s3;n4786z115B;l545n0;!d1r1s0y0;d0r1s0y0;!d0nB90r1s0;e10EnF;!e79i2;e4614i8Ey0;!e26s0u14;a2D0i36;d19l1;i969;!d38e194Ai1E0l7n22s0tEAAy0;g91EnE;nFt0;eAi6l16;m21Cs1F;e1s14;e5s14;!g0h5CEk4883l20AnBA0s0;n16r0s8w8D;!a484m2AB2s0;b27eAi6;!a50B1c9Ee23hDA9i6k75q122s1820t3CDC;a12e50F;aCi248nEo492F;i2B3;d0l1EFr28;e4AA7;n2AC7tCC;!e26o41s0;!a101;a101;aBD5;a1i5068y3A2;!o8;!a549e4i2F3l22o3DD6s0;!d0l1EFn0r2486s0t36F2;r8F;a261Ce454Co28A6r3858;n28r149;!e159iADs0y0;cA1;kB6nB;a1C8e93;l1m1;r130y4E4B;!a1s0y0;a172De4018i2BFCo4F4Ey0;e17l2B;a8A1h4FAiBDo4D92r1E4;n10ACp1A8t1A8;e5nB;m399s0;aFA4e51i6oC73;!p115s0;bDEl1ABEo3AB4;h2E5Ct2D;b3725e1i2C18l1F9o514;!d0l296Dr4C10s13Dy0;a50o50;a184Be1B73f8l3078nCE6r1649t3929w28y5061;!a50e15i298Bo31As0y3302;a33A9i2CE8o3AD3r4B1;eCi9;!a4B2Ab23C0c1CEEd3D45e1033f110Dg1E62h4C04i420Ej4BC9k3A6Al36A9m25EFnD06o4016p3803q1685rC43s4BA3t40ECu4320v428Ew44DBy2176z281E;"

---@type integer
DawgStart = 20821
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
StLoading = {}
StLoading.__index = StLoading

function StLoading.new()
    local loadingText = { text = Text.new("Unpacking words...") }
    local loadingPercent = { text = Text.new("99%", 'fixed') }

    loadingText.xPx, loadingText.yPx =
        CenterRect(
            SCREEN_W_px,
            SCREEN_H_px,
            0, 0,
            loadingText.text.width,
            TILE_H_px
        )
    -- shift up by one tile
    loadingText.yPx = loadingText.yPx - TILE_H_px

    loadingPercent.xPx =
        CenterRect(
            SCREEN_W_px,
            SCREEN_H_px,
            0, 0,
            loadingPercent.text.width,
            TILE_H_px
        )
    loadingPercent.yPx = loadingText.yPx + TILE_H_px

    local state = setmetatable({
        dawgThread = Dfa.startParsingDawg(Dawg),
        ticksElapsed = 0,

        loadingText = loadingText,
        loadingPercent = loadingPercent,

        nYields = 0,
    }, StLoading)

    return state
end

function StLoading:tick(_)
    local results = table.pack(coroutine.resume(self.dawgThread))

    if coroutine.status(self.dawgThread) == "dead" then
        -- an error occurred
        if results[1] == false then
            error('error occurred when loading words: ' .. results[2])
        end

        wordDfa = results[2] -- loaded the DFA
        DawgLoaded = true

        return StIntro.new()
    else
        self.nYields = self.nYields + 1
    end

    return nil
end

function StLoading:draw()
    local x, y = self.loadingText.xPx, self.loadingText.yPx
    local color = PALETTE.WHITE
    print(self.loadingText.text.text, x, y, color)

    -- actual percentage
    local loaded =
        math.floor(0.5 +  100 * self.nYields / EXPECTED_N_YIELDS_TO_LOAD)
    local percentStr = string.format("%2.0f%%", loaded)
    x, y = self.loadingPercent.xPx, self.loadingPercent.yPx
    print(percentStr, x, y, PALETTE.WHITE, true)
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
    music(0, 0, 0, false)
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
    local mouseClicked = mouse.left or mouse.middle or mouse.right
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


---@alias SubMenuTransition SubMenu | nil | number # the number is for the new game start level

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
        self.buttons, mouse.x, mouse.y, mouse.left)
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
---@field btnStartGame Button
---@field btnHighScores Button
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

MENU_GESTURE_OFF_X = -4
MENU_GESTURE_OFF_Y = 4
MENU_SFX_CHOOSE = 48

MENU_COPYRIGHT = '(c) Grant Williams, 2026. AGPL 3.0+.'
MENU_COPYRIGHT_OFFY = 40

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
    local startBtnW = print(MENU_BTN_START_TEXT, SCREEN_W_px)
    local hsBtnW = print(MENU_BTN_HS_TEXT, SCREEN_W_px)

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
        (TEXT_BUTTON_H_PX + BTN_VERT_PADDING_PX * 2),
        hsBtnW, TEXT_BUTTON_H_PX
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

    table.insert(state.buttons, state.btnStartGame)
    table.insert(state.buttons, state.btnHighScores)

    TitleNode.parent = state.nTitleLetters

    return setmetatable(state, {__index = Sub_Title})
end

function Sub_Title:tick(mouse)
    self.hoverCycle = (self.hoverCycle + 1) % MENU_WISPELL_HOVER_PERIOD_TICS

    local button = self:updateButtonsAndDetectClick(mouse)

    if button then
        sfx(MENU_SFX_CHOOSE, 'C-5', 60, SFX_CHANNEL)
        
        if button.name == MENU_BTN_START_NAME then
            return Sub_NewGame.new()
        elseif button.name == MENU_BTN_HS_NAME then
            return Sub_Highscores.new()
        end
    end

    local pointing = false
    self.hoverButton = nil
    for _, maybeHoverButton in ipairs(self.buttons) do
        if maybeHoverButton.hover then
            self:pointAt(maybeHoverButton.node)
            pointing = true
            self.hoverButton = maybeHoverButton
        end
    end

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
        if level and pmem(MAX_LVL_REACHED_PMEM_ADDR) < level then
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

        if not level or pmem(MAX_LVL_REACHED_PMEM_ADDR) < level then
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
MENU_HS_SCORE_W = 60
MENU_HS_LEVEL_W = 30
MENU_HS_TIME_W = 40
MENU_HS_BESTWORD_W = 60
MENU_HS_BESTWORD_SCORE_W = 40
MENU_HS_TOTAL_W = MENU_HS_RANK_W + MENU_HS_SCORE_W + MENU_HS_LEVEL_W + MENU_HS_TIME_W
MENU_HS_ROW_H = 8
MENU_HS_TOTAL_H = (N_HIGH_SCORES + 1) * MENU_HS_ROW_H
MENU_HS_TABLE_NODE = Node.new(
    nil, 'n hs table',
    4, 20,
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

    -- testing
    local hs1 = Highscore.new(999999999, 2, 999999, "hello", 1234)
    local hs2 = Highscore.new(2000, 5, 4444, "goodbye", 54321)
    local hs3 = Highscore.new(3333, 3, 51525, "bork", 99999)
    ClearHighScores()
    SaveHighScoreIfHighEnough(hs1)
    SaveHighScoreIfHighEnough(hs2)
    SaveHighScoreIfHighEnough(hs3)
    SaveHighScoreIfHighEnough(hs1)
    SaveHighScoreIfHighEnough(hs2)

    local state = SubMenu.new() --[[@as Sub_HighScores]]
    state.buttons = {back, clear}
    state.scores = LoadHighScores()
    state.nRank = nRank;
    state.nScore = nScore;
    state.nLevel = nLevel;
    state.nTime = nTime;
    state.nBestWord = nBestWord

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

    local headerColor = ((#self.scores == 0) and PALETTE.DK_GRAY) or PALETTE.WHITE

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
            sfx(SFX.clearData, 'C-5', 85, SFX_CHANNEL)
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
    sync(1, 1) -- switch tiles to bank 1
    -- music(1)
end

function StMainMenu:delayTick()
    if self.nSyncDelayTicks == 1 then
        sync(16, 0)
        music(1)
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

---@alias ActionFun fun(self: ---@field ticsLeft integer
---@field action ActionFun
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
        letterPartEmitter = LetterParticleEmitter.new(),
        postGameOver = false,
        nSyncDelayTicks = 1, -- for switching music
        hoverButton = nil,
    }

    setmetatable(state, StInGame)

    state:newGame(lvlStart)

    return state
end

function StInGame:enter()
    vbank(0)
    sync(1 | 2, 0)
    vbank(1)
    sync(1 | 2, 0)
    vbank(0)
    music()
end

function StInGame:delayTick()
    if self.delayTicks == 0 then
        local song = StartingSongNo(self.level)
        SetSongIdx(song)
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

    self.wispell:restoreInterest()

    --for col=1, 8 do
    --    for row=1, FIELD_TILES_PER_COL[col] do
    --        self.grid.cols[col][row] = GridTile.new('a', 0, 'normal')
    --    end
    -- end

--    self.grid.cols[1][1] = GridTile.new('b', 0, 'normal')
--    self.grid.cols[2][1] = GridTile.new('t', 0, 'normal')
    self:spawnTiles()
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
            local btnMusic = clicked --[[ @as SpriteToggleButton ]]
            if not MusicEnabled then
                MusicOn()
                btnMusic.toggleState = 1
            else
                MusicOff()
                btnMusic.toggleState = 2
            end
        elseif clicked.name == BTN_SFX_NAME then
            local btnSfx = clicked --[[ @as SpriteToggleButton ]]
            if SfxVol == 0 then
                SfxVol = SFX_VOL_ORIG
                btnSfx.toggleState = 1
            else
                SfxVol = 0
                btnSfx.toggleState = 2
            end
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

CHEATS_ENABLED = true

CHEAT_KEYMAP = {}
CHEAT_KEYMAP[13] = 'mem_profile' -- M
CHEAT_KEYMAP[12] = 'level_up' -- L
CHEAT_KEYMAP[2] = 'cycle_best_word' -- B
CHEAT_KEYMAP[21] = 'unlock_stages' -- U

---@alias Cheat 'level_up'|'cycle_best_word'|'mem_profile'|'unlock_stages'
---@return Cheat|nil
function CheatKeyPressed()
    if not CHEATS_ENABLED then
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

    print("Level: " .. ToStr(level), x, y + 24, PALETTE.WHITE)
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

function ClearUnlockedSongs()
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
    ClearUnlockedSongs()

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

function MusicOff()
    MusicEnabled = false
    music()
end

function MusicOn()
    MusicEnabled = true
    SetRandomSong()
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
    LoadUnlockedSongs()
    cls(0)
    sync(2, 1, false)
    appState = StLoading.new()
    -- appState = StIntro.new()
    -- AppStateTransition(StMainMenu.new())
    Mouse = MouseState.new()
end

function TIC()
    Mouse:poll()
    local tx = appState:tick(Mouse)

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
        appState.nSyncDelayTicks = appState.nSyncDelayTicks - 1
        if appState.delayTick then appState:delayTick() end
        if appState.nSyncDelayTicks == 0 then
            appState:enter()
        end
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
-- 110:0444443044444443444444434444444344444443444444433444443303333330
-- 111:0555556055555556555555565555555655555556555555566555556606666660
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

