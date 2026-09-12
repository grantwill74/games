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
"!;!s0;g0;e0;d0;s0;n2;y0;t0;n0;!d0s0;e1;l0;r0;t1;g1;n1;h0;r1;c0;m0;d0r1;!e4s0;s5;a0;eA;a1;r0s8;l3;l1;e4;!e5;t3;nF;e17;!d0r1s0;d0s0;d1;d0r0;eD;!e4i6s0;u5;k0;e5;eAi6;i13;a9e9;!s0y0;n8;n3;k1;!d0r0s0;m1;o9;s3;uC;e12;!e26s0;!l7;o1;s11;aC;!t0;t7;r7;o0;y1;eDn2;e23i6;p0;i4;e33;!e15i6s0;r3;h1;g3;i9;b1C;s1F;e0y0;s8;r4;!e0;i0;c2A;i18;o10;p1;i2By0;n4;i1;e9;lB;i10;i5;a9;!l7s0;c11;a20;!i6;e30;c3;!e24;e1Bn2;d0r1s0;d3;aD;e8;x0;w0;r16;m3;!i13s0;e24;c32;lC;g7;!l0;eE;u14;!y0;d0r0s0;e4i6;l4F;c1;!e0s0;i6;gB;a7;r14;!e1s0;t16;i20;!d0;n2s11;i31;tB;e1D;o14;a10;r2F;nB;eDl7n2;nE;!e4s0y0;e1B;!aCs0;w1;h8;a8;s14;k3;a51;a4;m0t0;!e5s0;i45;l18;h66;a12;o4;eC;r25;!r0s0;e10;o8;l4;o74;a42;e15i6;a14;!n0s0;e1n2;v3;!e24i6;t11;f0;iE;h1F;r0s3E;oD;i3C;rB;e85;sE;o29;e1BnF;a0c0;iC;i35;n25;o81;e5i5;d0r0s8;u1D;u3;n7;t27;p3;r9;a1D;u1;a0u14;e5n2;e1Bl7n2;i13y0;i8;c8;d0r2F;t2D;e1i13;i3F;l19;r2A;e3;r1A;u8;n18;i1D;r18;r8;n2o9;iB;aE;o6D;!n0;l7;oE;n16;!e26s0y0;b1;l16;s3u5;n8t3;oA0;!s0t0;!m2E;h3;r0s0;dB;l1A;o45;i71y0;e42;eAy0;u0;i25;!e79;o31;!r0;n2o9v3;!r1s0;a4A;z0;a54;d0r1t1;e0m0t0;l3A;m0t1;e8C;m7;m18;a30;i7C;f1;e99;s3z3;!e4i6s0y0;a25;d0r1s8;eAoD;a59;o9v3;n1A;!r0s3E;!r0s8;i77;!e1;iBB;!e68i6;d27;e26;sB;uD;t19;uB;rE;e6E;n2D;i69;i3D;f7;oC7;!g0s0;s19;d7;n39;e25;i1A;h0m0;eDl7;i0o0;r39;!e15i21s0;uE;o25;n52;!e4l7s0;!l7r0s8;!h1s0;i36;i3;o2A;e17g1;hF7;o34;aE9;a75u14;k16;!e4oDs0;!h9C;!e4i43s0y0;d0t0;l1D;r10;t1E;!d0i6s0;!l1s0;d0r7;a1e1;!g1s0;e0t0;eA3;o1C;d0e1r1;eB;e0i13;a73;!r7s0;d0n0;e1Bl7;!s0t1;!o6F;g19;t39;n65;rAA;s5t1;v27;d0r16;s9A;o54;!aC;!a0s0;!l0s0;t1A;r55;o50;d0r0s3E;b0;g94;s7;x1F;m1A;o57;r3D;eAi6y0;i96;t41;c0n0;oD5;g60;c19;!eDs0;b7B;i27y0;i1C;t18;nFs11;a50;u34;a34;d0t1;!i6s0;o42;e1y0;o46;oA6;l44;l0n0;r35;eE1;!eDl7;e1Bl7nF;e17g0;h7;h78;!d0r2Fs0;l0t3;i21;oC;a0e0;d16;d0e0;cE;t4A;!eD;aCe1;e33y0;e5nF;t2F;aCeA;o41;o49;w9;!t38;o7;i5F;e18;c1C;l2C;aA2;cB;u12;!x0;i6C;!e15i43s0y0;yC;o5;!e4r7s0;!a0;o6F;iD;e50;r1s0;n2A;!i3Cs0;s0t0;e23i43y0;!e12i6s0;d0s5;i110;o32;n14A;!t27;u59;lB0;f8;!a1s0;mB;a40;e1E;a52;n125;b1A;e0i3F;!s0t1E;p11;eF9;iBy0;k1A;!s0t3;i0u5;l1E;o12;u1A8;n82;a45;l60;e73;aCe33;o9B;c3t0;e79;e0m0;s12B;u36;o6C;aBC;!d0f37s0;i32;i54;o36;r40;a3C;a36;n5;!h0;o138;k28;h1A;e8F;e1nF;r32;r0t3;r90;lA7;u101;!l1Es0;l47;a57;!i2Bs0y0;a4B;c7;!e15f37i6s0;r19;h117;d0n0r1;eFB;g9;n92;t28;i8D;!d0s0t1;a31;o2;!s0x0;c7t0;o40;eAB;iCA;o93;n2s8;e49;l1C;d0l1;s5E;!e5i5;aCe1i13;!n1s0;o19E;!g0;a5;r34;e23i6y0;a11;s66;i97;n1r0s8;rD6;p1C;h27;i71y63;e7;t20;d0n1r1s8;h18;c0s14;e1s11;!e0l0s0;aCe5;e4i6y0;c0s0;!e4i8Es0y0;i0o1;l2D;a72;lE;!d0n0s0;l9D;z3;n70;hAE;eAi43y0;i18y0;d0l1r1;oDC;c4A;!c0;t48;iAD;i30;a17;!e0r0s0;!eAi6;!i69;i1D9y0;n2F;a4C;e1i6;t13F;!e0t3;tBD;hB;h2F;r1s8;!e4;m16;!i3F;i57;n2o10;e17y0;t5E;!e26l7s0;!aCe26s0;n173;c3t1;r5;w16;p7;a6D;e1n2s11;s0t1;n55;c18;e6A;!i0s0;!g1Es0;eA6;o8A;aDe1;!i9s0;l8;i49;!t18;e4y0;!i13;l53;!d0e1r1s0;c7t1;n61;d1t1;!d0l7r0s3E;a2;aCu14;t3B;n7D;a93;m2F;l0r7;a65;k53;oA5;a75;g41;eAt1;aF;t7D;r53;h3A;i12Cy0;e31;!i3Fl7;hE;i12;gC3;s100z3;!e26oDs0;s3t7z3;e24n2;l25;i13D;m0s0;kB;l35;b3;d0e0r0;u49;o30;!s1F;g3A;e6C;t287;!aCe4s0;n2t0;u204;!t3;n2s14;n2t7;s5Et2D;t53;aBE;i73;!o29s0;i171;m2E;n2t1;!eEs0;w10;!d1s0;o20;cED;m19;!g7As0;d1C;!s0t18;i41;!h0s0;!d0r1s0y0;c0t3;i228;!l3s0;!e8s0;d39;!e4f37i6s0;oC6;b16;t70;e8y0;aE6;a1o1;!e4l7s0y0;eB3n2;!e4i21s0;l2A;o3B;e5F;e0i0;a69;d19;m1t1;!e15i6s0y0;!e4i67s0y0;!e5y0;y5;r2D;d0e1;g11;n1E;y16;a49;f3;l6A;e0o0;l198;eAiDD;wAB;!e79y0;d92;c41;pE;p8;s100t7z3;e5B;s9At7;r45;n53;e0g0;l41;!k4C;o5C;i91y0;l29;e1g1;t61;t38;t12D;n32;lF4;e1E3;s41;c7t3;eDn2s11;o131;!eAi6s0;c4Ft0;k2F;n2v3;r36;!e0r0;u4E;o72;r5A;f16;h2D7;!d0e0r0s0;!e0l0;!e26i6s0;i27;eEEl7n2;e1A;d60;d1t0;r41;!o0;iAF;e23i21;e17i97;l262;e3Ai3F;h5A;u76;!d0r1s0t1;c160;a2A;c0n2;k1E;!e24y0;e15i6y0;tB7;i35o40;o144;e15i21;!r1;p16;n2s12B;!p7As0;l28;tD2;e3A;o35;i1B3;n77;l1t3;iBBy0;oC4;n2t3;t40;a23D;d0r1y1;fB0;u19;!o10;!k1s0;!e0g0;n2s9A;h53;a162;n41;!g1;!i96s0;a7C;oF;eDl7n2s11;p1E;!g7s0;e6D;s102;a2DF;!n2;!d0s0y0;i132;p27;h16;n2F3;e26y0;n19;e1EF;a225;k18;e120;e14;!l119s0;n20;c4Ft1;!i14s0;m116;n28;iF;r61;a0o9;o1D;nEB;eDr7;p4A;aDA;u3C;k0m0;o59;n3B;n16r0s8;c222;a97;!i3Fs0;eCF;eDy0;h38;c3B;y274;d3A;!o9;l39;g18;pB;t5A;gCD;a1e0;t1C;v19;e15B;aD9;a6C;c3D;a53;a32;d1A;c47;e93;k7;!e4iACs0;i56;e129;s52;e18Di6;!e4i6l7s0;d6A;e45;e1Bl7n18A;!e12s0;e1Bl7n139;!d0n0r1s0;!d0r1;o98;lE0;r95;sC0t2D;m1E;e95;i13u5;iC6;a143;b1CgB;l3B;!s1;e33oD;l191;aCy0;aD5;a135;i65;i51;r3B;i0s0;a0i0;a5A;t2B;!t1;!d0f37r1s0;i1E;!i1s0;o104;m167;!i2By0;a1De23i6;e5s8;g3t3;u10;e113;l5;g1E;e15i43y0;e11B;e1o1;sC0;i14;t55;o6;l4C;!m2Es0;!e4f37i8Es0y0;e20;n3D;n0r1;c1A;e12E;d5;l17B;!r7;!e15i8Es0y0;!e290s0;u1C;n84;s2A;i59;u69;k3n3;u20;!e68i43y0;!i18s0;o56;zFD;g1C;l328;w80;e10C;a7D;lCA;e0h0;o8D;d1s0;eEEl7;wC;d41;mCD;d0t16;!s8;g2C;d0r1s3E;eDC;d3Ar1;o1DC;g47;b18;n205;!l0t3;eFBi6;e1Bn2s11;d0r90;b1E;i25C;t355;h9C;d0n16;y20;l149;t1CD;m0t70;o1BE;pA0;i50;h137;!d0e1s0;n2E7;o51;e0l0;s18;a0o0;s4C;d5B;u9D;!s0t27;o13B;e81;a0s0;e1i18;!i18;e112n2;r47;e1i13y0;g1A;!e8;d0g0;s35;z1F;c248;r1t1;d0r39;e0n0;o16;oD8;sB2;d2F;n3t3;i2A;t3A;e22E;r74;a30e23i6;o2D;a61;lE2;l5A;i2D1;r7t3;n1o10;c18B;r40D;s55;u32;l84;i2;l181;e1Bl7n2s11;n1u5;b1Cw80;o95;e4i43y0;u9;g27;eB3l7;s1E;!d1Es0;e1g0;z1C;d0n1;n1r1;a6F;!b7As0;!e12;eDB;i3Fo29;t5;f7n2;h1E;p5;o127;!n8s0;a1C9;o190;!o0s0;n254;e59;h313;yC6;k5;m45;!e17Ei6s0;d3B;eA3n2;i154y0;!eD0i6s0;k27;o11E;o1F;a6;!l1;e34;i4u5;t95;e310;!d0r16s0;!i3C;!e9;!f37s0;r7D;oEF;a11B;e105;!e0r0t3;!a30s0;!e24i43y0;n0t3;t2C;m28;d4B;a8D;a2FE;d0rE5;b1Ct10E;oF5;c122;s9E;i64;!l7r7s0;eA1;d47;c0s1F;!i4s0;n2sE;s2D;i8F;e6B;a170;c92;!d0n8s0;d0l0;l80;eAm0t1;a5D;i3B;k5A;a1D4;b1CnF;aDB;l1F2;t152;c0s1DAz3;e0oC;d0r2Fs0;e5i13;l1n1;e17i3C5;e1i3F;!e4i6m2Es0;c3n7;r70;a8F;m55;c7t3A;tFD;a7F;qC3;i88;c0u14;e0n2;i110o40;a4E3;s3A;c55;o18;!eDl7s0;!e5i2By0;aDi0u5;b7;c2F4;!a4Be15i6s0;a185;e9iD9;c9E;!e4i27s0y0;n170;r65;a18E;eAiDDo12;r1E;u30;r46;!d0m2Er1s0;!e0l0t3;i6F;o23B;i34;!eA;t18B;d0r1t0;e134i3F;!e17s0;!e4s0t0;d0r0t0;r4C;!d7As0;!tF8;!l18s0;n0r2A;d1s3;s4E;i3FF;n26B;r5E;i1E6;b27;!i6m2E;aCi13;i286;!b1C;r58;!m1Es0;i6y0;uAF;e1i5;rC;eAi27y0;m2D;u57;d9F;c0s9A;e155;l27;!e4iFAs0;f7t7;a266;v38;!l7s0t7;!eD0i43s0y0;i4n0;!a9s0;!d0l7r1s3E;!i50s0;!a1;t10E;eD0i6;c2AlC;r28;i31E;i31o46;tB4;fBF;d18;l6B;n197;w39;!e3s0;c0n3;eAiFA;e166l7;!p1Es0;n294;e4i8Ey0;r1u12;r1D;l7D;!m2Et27;e1Bn139;e12i6;!s0t2D;!n22;eC5;o215;eB0;rE5;u3D;z1A;e40;n4B;!b1Es0;g2F;!d0l22s0;h2C9;!e1BE;d0l1s0;d3D;e144;!aCl7s0;m47;!eE;!aCs0y0;o1A;c46;e23i8Ey0;m1p11;e17i6C;!s0tB;u25;!d0n8r1s0;d0n1r0s8;e15i8Ey0;f108;s47;t8;!n1;l162;r6B;a1BF;!e1Bl7;!lBs0;o3;b1Ct19;!i5;h0m0t1;t4F;tDB;lAD;o4C;o99;e7y0;h0t1;v1A;e255;u73;l77;m1s1F;!eAs0;aA3e1;k187;h5B;!tB;n0r0;!d0r1s1;!i27y0;d1E;h29;m70;a20eAi6;l58;o1BD;d3i4;aCn2;c1k1;aA3;z27;e3D;eEEn2;g3l0;!e1B;eB3;n0s0;g3B;e54;y14;oAF;!e4i13s0;d0r7s0;oC9;bB1;!i14;l1s0;g4A;!n0r1s0;!lA7s0;!aCi13s0;l3o10;a322;o505;o264;m27;a28D;r87;!d0s0uD;t5B;d282;!e4i6o12s0;d3Ar1s0;sF5;!s0uD;i4FE;e1u5;i685;eAiDDo40;i1A6;!s0u5;k4C;!n3s0;iA6;n1D8;!hA5;n2E1;eB3l7nF;r78;e9l3;n213;!r0s0t3;!e15iACs0y0;e6Do6D;c0s14Bz3;t2B2;s1DAz3;i168;t251;!l9Ds0;u6C;u499;d70;e9D;nFsE;i1y1;m5B;d133;cD3;d188;n2B4;oDF;n2p1;aC6;a111;!l7n22r0s8;!a54;a1e5;e11;e51;i2D8;e112nF;i2EB;g44;a49oA0;e35;e59Ci6;!d0s1;n22A;n48C;e1Bl7s11;!e10s0;iD9;a1i9;e1r1;s23A;h19A;e60;c0d0;e27;o20E;e15iCBy0;!d0r1s3E;!e1g1s0;s1B5;t133;l70;e77;r1s3;r0t1;!a51;e517i6;uB6;e1i27y0;uCF;k38;e4i13;h0m0t0;i4s3;r26D;l16E;!e54B;aF5;!e1B8i6s0;i13o5;e4i27y0;d9B;e2FDoD;r7E;y31;l52;!g119s0;m5;e57;h178;a11E;a1i13;a96;!d0r1s0y1;!e24l7;kF5;d0n2;s53;!d0l1s0t1;d197;!e193oDs0;e1BnFs11;t2EA;iEF;!d0s0t0;d0s0t0;e3AF;!e26r7s0;l5D;c0d1;t188;v47;u50;!n3;p28;l1E2;r13;l0t0;uC7;c0t3u14;p2F;c0s3z3;!m0;aCo9;y6F;h52;a277;w90;d1n2;!s0tA9;u531;o2C0;aCu34;t29;eAi21;a2F7;iB9;o6E;!e221i6l7s0;a2EF;c0e5;l6A6;!d3As0;g2D;a75i13;d40;g62;u61;!s0w1;d0r1t16;!e4i6lBs0;d0y1;!r2F;e134;n1t1;t49;eA3l7n2;e1Bs11;v18;!d0r0s0t0;a1C;!e12i21s0;a2AF;u5C;w1E;s105;s0t11;eF9y0;r133;eB8;q11D;aB8;eAi13;g3l1;e1nFs11;e113n2;e2;a101;h8B;!eCs0y0;oB8;nA1;l62;a1ED;h14F;n1A3;r1D3;s378;m3D;k39;s36;u1E;i4CE;aF0;r77;!a0s0u14;h1E1;k48;!a0e0;a2E8;s14Bz3;l0tB7;r9C;s0y0;a1E7;l0n8;eF;eB6;t60;e611y0;!l7r0s3E;p7D;r142;k3n2;u54;d78;o237;n4F;!e9s0;!i96;r1uD;!aBC;i20C;aF9u14;l7n2;aC9;!i20s0;e15i67y0;!o36s0;a51C;d2Bs0;e1C;i3D3;o9D;k41;aAF;h41;a87;!m1s0;m1s0;uF;r25E;k78;e0i0o0;!a0e4s0;!nBs0;d0r2BD;!lB;i62;d1n3;!e4i6l22s0y0;a1y0;e83;!l18;e30x1F;!e0l7;e5y0;x66;o97;l619;!s52;!s3;i226y0;e17i27y0;!i15E;!e4i298s0;a4BeAi6;eAF;i4m18;!e1Bl7n22;k19;e12n2;l147;a13;e1o46;n19sE;r1C9;d0r78s8;d0r5;m64;!i20;hB4;!i12Cs0y0;m39;rF3;i2E0;d48;o3Bu1;!a1e4i6s0;!u49;c2C;i4n1;h0t0;r1D6;r82;t35;s3D;rF;t150;e153;e2FD;w28;!l7n1r0s8;d175;!i1DB;oB0;l2B3;!c7s0;aDeA;!i3s0;e17i31;n5A;n1F7;h4C;l233;gF4;!e4i6l1Es0;u1A;a2AD;i223;w27;l64;c32k1;eB3l7n2;l1B6;e17i6;o3D5;r19B;g339;f28;eE2;b19;i4t0;a0i13;!e24s0;eEi10;l1r1;e56;e478i6;aCe0;k5B;e0nF;n39r0s8;lE5;sC5;i3A6y0;d35;e146;s47z47;a9n3;h35;i3D4y0;d0r1s5;!d0s0t16;t4C;r60;n368;!i0o0s0;aDC;!d0r0s3E;rA1;r29;!l3Bs0;c62;!e5h0;l32;l48;c32nF;n0s8;n2C;!d0n0r0s0;!e1Bi3Cl7;m5F;!i13y0;!iBs0;u72;l304;n6A;i27E;tED;a25d0;u4;e1n2s8;n174;!s3t0;!e142s0;bD4;aCu5;n3s11;a447;o1B0;l49E;!e0s0t3;a4BDe9;e5C;d28;r2DD;e1i91y0;t58;aAB;vB;l544;n3F;n1s11;a2CAi36;!f1s0;e15Bi97;oB;b1Cr1;d53;o120;o2A3;aE1;t52;a1i3;uC8;d0n0r0;o6A3;a513;s19z19;!d0r7s0;h2D;m53;l75;aAD;i25o46;n188;t92;aCi0u5;!a1De15i6s0;x5E;e134i35;i8B5y0;t939;l263;!o6;m1CA;s5C4;eEy0;a59eE;!e4iA0Bs0y0;e483;e59E;!e0s0tB7;!g42As0;eA26;a340;!e26n1s0;eCiC;i1BB;r2A1;!tAF4;i4t1;!i1As0;!t5B;!fC2s0;n3E7;h11F;!n114s0;l7E1;s0t7;n252;g5;g3r78;g39B;!eDo10;d1l6A;n279;lF0;!d3Ar1s0;eA46i6;d39sB;t149;!a1Ds0;cA23;t229;i111;r7tB4;s78;aEF;e4n2;s32;vD9;e4i21;a3n2;rCE;!a4Bs0;a0e0o0;e10Co5C;cBd39sB;o11B;!t2D;b5C;!d1;!s0u1;!h1;!d0r3s0;i18t2D;c0f7t7;d0t1y1;!i31s0;e6Do2D6;aAA0;!d0r90s0;d3g3;n38;n2s696;!i10A;i10A;d0n1r1;c13A;h95;a0i32;s5B;n8s3;eA3n2s11;a37;l1C4;!e4g19i6s0;b138;r242;a2CF;i71o81y0;n2s3z3;d0l0r1;!s0t16;a1e12;!r7s0t3;a2F7e1;!e5t1;e1t1;s106;a27A;e10Di86;l82;lC3;e15i6l2C;u6;eA4i10;!e15iCBs0y0;e4l3y0;j1A;i2B1;m57;n149;l1n8t3;!e15i6o12s0;d2D3;!e193s0;a5C;a3AA;m325;l5C;r331;e12r3D;uBC;s27F;d52;t1B7;e5BF;e220;t2AF;mA1;d0e1r1s0;c3n8y1;e1h1i13;s2EE;!t7;c161;l2AE;r322;h1AC;o803;!u5;!gBs0;z38;e3o8;!o14;b53;!e15i6m2Es0;c7l1;!e14Ei6s0;!l7t7;s1C7;z18;w1D;m3r3;e201;n297;m0t2D;a6A9;d0s5t1;d0s0t1;c0s19z19;!i29B;v95;a50u1D;!e4i1BBs0;!a9i18s0;oAA;r455;!eAEEi6s0;!i0;l0n1t3;g1s0;!i5F;g35;u4C;y593;e45p8;a1F7;r1E5;a5B;n2B;!e93E;n407;c5;t271;e4t0;e0i35;n34C;d55;!r18;aDe1i0u5;s6B;t46;uEv27;r0t0;m35;u45;s20;e148i6y0;!g3s0;i29E;e327;e33o1;a21;!b7Bs0;e3Fo29;!a4Dd0f37l22r1s0;eEB;!e26r7s0y0;n60;s27D;l4p1;r8B4;c5C;lF1;e3C2;b5A;e5n2s3z3;a0o9u14;e82;m2B8;o680;!e20Di6s0;d16t0;aE1i13o9;n36;r2C;mE6;eAnF;t7A7;u5D;m41;!i288l267s0;n14C;r3E;u44;g40;o12r1A9;u464;!o1s0;b1Co10v3;oB4;t191;!e24oD;d3s0;e1o72;u2D2;o22D;c7t1AD;!a4Be4i6s0;a46;!t16;h1r1;!l44s0;!i3Ds0;d0n3s0;rAF;n46;e4i67y0;k10B;h58;r19C;!a93;a2E0;t90;k207;g5F;eAi573;uD9;!o1C1;o29D;e539i6;!e23i6;a8C;a1De1;i3y0;a29E;e618;n3s3;e342;r56;a51i59;f0n0u8;aCe5s3z3;tE5;p38;h106;!t0y0;t0y0;d82;e1i2By0;!e5iBy0;a42oD5;!a42s0;rAB;x2D;!l60;n26D;a4Be15i6;!e30s0;eAA;c4F;!l3;c53;e1Bn18A;l55;a4n8;t515;g7B;u53;!t6A;t6A;l1n8;e7C;!t56;t56;dCA;e0o36;!e15iACs0;!aCs0u5;r2;z41;o332;a1EEe1i0u5;n34D;!o40s0;b7Bn1D8;a5F;d1n1;i5y0;n118;eAi6o10;iB0;u16B;e24sE;o446;n8t19;m1t2D;b18v18;i4s3u5;l5B;!f37i12Cs0y0;r211;aCF;l87;!nFs0;t47;g3lC;uDF;eDs11;rCD;u7;n142;!i1Ey0;eB3n2s11;r279;c0n0u14;o354;!iEF;r49;n3D6;h124;h277;!i223s0;!eC1i6l7s0;!e1i6;!a20s0;e6D9i6y0;!e15i21l22s0y0;a1u34;!d0m2Es0;!eFFi6s0;o64E;nCD;!e4i6n0s0;i7Co0;n12D;oA2;u742;i13o0;a245;tD6;k2EC;i260u1D;!e1i13s0;!l2C;a20i13;oBC;eAiFAo40;v62;zD4;e164;d152;!d0l6Br1s0;l19C;b38;!i9;l25nE;a2An142;n13F;n0t0;!i18s0y0;e5i0u5;s18z18;aC4;eEi21;e40i3C;a75o9;!a8;u2CD;o61;a4De23i6;d0e1r16;!uCE;a0y0;d9CE;!n0s0y0;a0o1;e13;a1DeAi6;d3m3;t179;!e24i21;aB0;o2A6;eA8A;r13C;!p1s0;!a4Be15f37i6s0;!l55s0;t7E;n1r16;c0m0n0;!l39s0;a1o9;eEE;!eEE;t88;t186;n3E;!n8;!s0y1;e12r35;a159;rF1;e26i6;i527;k1C;e30Ei43y0;s543;b1F3;eAi6r44;n139;!e33;!pA9s0;d1y0;d3z3;s169;n8t1;a1eA;a3A7;!s0u14;!i8D3s0;e32;a1n2;e644;!n8s0t3;e4l3;v0;u167;iE1u5;h1A2;a1D1;eDs12B;h9;!e5i1;a6De6D;!e1Bi3Fl7;o27;d0r1t2D;oAB;a0t3u14;d16k16;n0r0s8;uD3;c2B;aE9eB;n2oD;l114;t3C4;o93F;!h1D5;!s0t11;t3FC;iA2;!a256;j469;a9n2;!d0l1r1s0;d0l1r1s0;l23C;o53;e0i5;e0i1;o21;!e15i6s0u4E;oD1;t36C;o241;t666;d0r1t2F;m4C4;iA1;o1BA;o872;lEB;r1s3E;e148i6;!h3A;l1n3;d0y0;d1g1;eAAF;r93A;!a52s0;!i12Cy0;d1f1;l182;!hF1;e25s5;l3F6;c3B9;l782;s41u5;!aCe15i6s0;k0t0;!e5i6n3;a104;d0e0r1;d0l0r0s0;n1AD;l5F;e4h0;sBD;i372;i30F;h7D;e143;!i13r7s0;bCE;l3o9v3;l99;m2B;t1AD;s37C;c0s8;t77;y5F0;!a5;a75c0u14;d84;v207;i9F4;e15i6l47;e1o0;aB;l14;!c3s0;p5F;g0s0;a5D1;d38;!e4s0w80;e380;rFE;i4F5;lBu269;i4pA0;d0n26B;g94n4;hBC;e26Ei6;r1sB;u83;n1s8;!e1E;n6C;i123;c8e1;n95C;h5E;!b1Cs0;o3A3;d7i4u5;c3n2;b1Cl1;s8t3;r3y1;o10C;a1i25;n4C;r7F;i31y0;a2CA;eEi97;i13o9;lBA6;a51oD5;b3o14;rA9D;!l41s0;e1Bl7nFs11;a4Ae12;!e0n1s0;!d0o29s0;a51E;h89;e38;e15i6l19;i592y0;hA13;r1t3;l651;!h38s0;fB;a30e0;a9e5s8;a75e1u14;o40E;a10y0;p169;eEi6;e12lB;a169;o6DF;z5D;!t1A;i195o36B;i1D2;!e15s0;a978;!e15i86s0;h523;e34E;i3Do10;d0r1s0t1;r122;d56;aDu14;aCe0oC;l107;n271;l1y0;n1As102t8B6;y40;tA37;eBi1;!e24i6s71;c9Et38;n740;g15A;!e42;!o8s0;!d0n60r1s0;o439;e106;p1A;a275;lCn4;d2D3t3;!aCi96s0;d0n3A;!s0t119;a9E8;e1i0o46u5;!e5nFs0;s9B4;a8CeAi6;a41B;dB4;i4o29;r198;r43F;i53;g512;c1s9A;!e4i6;e290;n6B;r2BD;rB9;w2F;!e15i6s1F;e2y0;o257;s0t2D;n3A1;r17C;e0n3;oE6;!n2Bs0;nCF;v3D;fCD;r2Ft1;!e4l3s0;!l3A;k6B;n22;w2A;!i54;!e153i6s0;!d0f37r0s0;m1n2;n210;l5E;o2EE;i270;m4D8;b29;s3t1;n2AC;e22F;!e1s0y0;s3t7;!e4i1C5s0;n4E9;a2AA;pD8;!m2Et38;i19y7E;c18C;a3o29;i412;i169;i330;a6D4;w32;e1o9;c22B;!h9Cm2E;!e385i6s0;i5D5;eC8;e79l7n2;e1i1A;!i3;e23i542;!n0r0s0;e79l7;!e12i43s0y0;m4C;!f37l7s0y0;i556;eDn3;k39B;aD1;c0f7;i15E;c4C;i57C;e1BE;!d0l1s0;!i154s0y0;s17C;r4B;aCe26;i272;!k7s0;a3CA;x8;!l7r0s8t7;c1n2;n3t7;!k0;n83;c30C;r1C4;e1i171;!a20e4i6s0;a1EEi0u5;l9;n0t1;!e79s0;cD4;m84;!t1E;eB3l7n18A;i1t53;e1f7;!l19s0;e12s0;e3ED;d0n8;i1BF;!d0e4i6s0;!e4i21s0y0;i143;!g177s0;oB5E;n1p1;!e68i8Ey0;r27;!d0l7s0;d0n39r0s8;e15i6l44;!e4s0t1;oAD;!e15i67s0y0;lBD;d0n0r1s0;hABE;d0t152;n1AB;eABi6;o29u14;s5D;m0y0;r4DF;c3s11;s45C;e0l18;l1r7;s14t7;v415;i72;i4E;a120;i34B;eAi6t19;b7C8;i2By1;o28F;n2s8z3;y1C9;e0t1;e5i4;l0r0;l8BD;o2E0;!l4Cs0;a1g1;o285;eDr3;i354;b3B;!s0tB7;x7;!aCi13s0y0;d0o9r1s0;!u14;g1CA;e1Bl7n14A;!i13s0y0;!e15i21s0y0;g3s3;!bA9s0;eB6D;e23i326;e112l7;e6CD;rF2;r76;r3B0;r554;!m18s0;!e10Di6l7s0;o5A;!oD;n161;!w203;r34D;z1E;z5C;s24A;e5s11;e567;o27D;!e4iCCs0y0;n193;e5n2s11;!sE;r4F;nEtB;e5Bi2By0;a873;iCF;o92E;e4i189y0;!l7n22r0s3Et58;nEBs8;!e14Ei6o12s0;!i1A;r4y1;s1D6;e2A;i19A;i0y0;p29;r8B;t103;a0e0i0o0;d1n0;tC5;c182;a20o29;iB8;t164;s5t0;h82;n405;e112l7n2;n25E;l1A0;d103;s8t0;u170;d4F;m5A;a45E;a52E;i887;d1m1;!e5DB;e4o9;!i230;s86Ct2D;!aCe5;!s0t1C;g38;r23C;c1AE;a4Be23i6;d2D4;g2AE;!e153s0;k3BE;e6BoA5;!a0i13;r167;i2B;l16F;o74y10A;n1s3;d0rAB;a9i4;e4t1;d0r1F5;c13E;t1AB;t170;i13s7;!eCs0;!e17;o10v3;r84;eAm0;e1Dn2;u89;t107;r0uD;aCeAi6;!i10s0;l0n3;s47Bz19;f1C;dA1;h6B;mCE;g1i13;c16F;d0r7t1;e1EoDC;c247;!cB2;tE;m1AE;!eDl7y0;s29;!r1As0;c32s5;e33m0t1;!l1t3;e12rB;eFFi6y0;c6B;c0l3;g94t1;iB6;!e15iBAs0y0;l6F9;!e12i21;s1A;dE0;e166l7n139;nEt19;t5F;e4iCBy0;s12D;!d1E;o4E;!h258;!e4i337s0y0;j3B;rC9;t545;!e35Cl7n22;a74;oDA;i38;n8s0;n7D7;!iBy0;i1Fy0;o2CE;c0o9;g3n8;b1BA;e12rA1;y18;d0t20;eAiCBy0;l268;i19;y1D;!uB1;t2D3;eAF7;a7Di13o46;h3F;!c3Bs0;!a88s0;f48;n2o10v3;!k1A;o359;!a135s0;p0y0;eAD;!d0r1s0uD;e194;d0r133;t566;lB9;u1FC;e1ED;l534;!e4r7s0y0;a4DCe9;iB4;e2B9;nABC;cBt0;c0tB;aB1E;i9By0;!e4i6l47s0;wE5;!e15f37i6l22s0;!o10s0;r203;e479;r1AF;a4De15i21;i7DA;o1ED;i702;!e5i91y0;dAA;!o41s0;r62;!f37;i2DB;aDe4;!a1i1;a1i1;r3A;e384i6;s3t3;d1C0;!i10As0;i83Ey0;aCe1o1;g150;d0n0s0;e112;n150;d0r1y0;e10Di6;i9y0;o28;z184;c1s8;iA10y0;p55;!b1s0;l387;c963;r116;!a7Fe15i67s0y0;u64;r89;e85o1;t316;!c32;!i35;!l1r1s0;!d0l6Bs0;c0e24;i4D3;m0s1F;e0i56;nA49;lE3;u18;!iBs0y0;a7De0;d77;r5B4s1B9;e4i35;u863;n31;a30eAi6;v2C;a9e1;l202;!e1i2DCl7s0;a35D;d0r16t16;o4CC;e23i6o29;i21y0;k27n0;p4F;t1C8;r89D;!e15i6r7s0;oDB;r0s8t1;c4Ag4A;!o29;e112n125s11;e11E;d2D;e1i7C;e3C1;!i8s0;i25n0;e81o49;y1C;eDg1;o27E;u2C;a185e1;c49;!i2DEl7;m29;s86E;o256;n2s0;n2528p28;u759;!b2EDe24g125Dh4A98i4F8s3E9t1064y0;i4n6A1y17F;c46Ch4FBs1Ft193D;l39A9;e35EAi1A;b4405;!e5s32Bt28;!e15i21l44s0;e2D46;a4D88b4Dc3726d4F8Fe2ED2g4852l31Dm32EEn2D6Bo3087s2F3Et62Av28CEz8BE;k4CnFt150;i31oE8;r3B7;i4E83;a4B1i2FF3o219Fu11A;s1A0;a3EA9b2C2Ec2CA1d1B5De2C7Eg3D5Eh497Di3837k3CEEl2682m30AFn3C20p1F61r18E3s30C3t18C7u4960v3DBFw4500x38F4y4DC9z2EAA;g8D;e40i8FCy0;s11D3;!h1EA2uB69;a10u264;a9eC;!i244s0;aB30e8i1FB4;l312Am1nFr2A70u463;aEc462CdA2Cg1421m12CDq3F39r30EBs0u30;y17B7;d445A;a61d1i1FDm27;g35s0;r36EA;r19y16;fE;a54o2BAF;e1n0;n2s5BA;!a1o46s0;aEi3E1F;!aCe26oDs0;!e17i2607r58s140;iAFCl1A;!o10tAA;c92s18D9;e220i3B;!aCi5Fk1Es0;!c1364e4i21n22s0;r8s8w1;!i1168l7;a34b4Dc505Cd1e2D83hC9i30AAl200m1n111Ds3t48E2u1vD3w10xC0y12F;!m348s0;c0d19n115s19t3z19;c0g18;!t38u1F9;e17t16;o31BBr358u3C;!e4i6l3s0;cEd70f8A6g2D9Cn3p2F09r61;e1i30AC;a4An1E0;!i4m18s0;r6F7;iBo42;eAo29;aB16b21D7c201Ad1E15e8DCg2637h37DDi3AE5j1588k18B5l4781m3Bn42FCo1E9r4E96s5152t40B7u1E81v1961w316Ey4E88;!aBFAe4i330Bl22o3732s0u2222w242;o4426;!o10s25F1z19;a88eAi6;c32mB;n0o10;jB;n1E65;u218;u126;eA1o8A;!a3CCCs0;gBt3;aCeAi6k175;g2CA0;!a9A5e262Ei6s0;d0s7CC;o47A7;e5m351E;!a3A3Ad2142e22B5g1i70Cj38A2l4312n58p4DE8s191Ct2314u33F1v388C;c60Be1i154y0;cBd19t19;h19Di7Cl445Ds58;!a488iD1Em395o489As0u4DCFwA8;l1A3C;wF3E;r3FBD;o126s2C;c3C8k25A2l1Dm28E2n4E34p2733;e3612y0;aFy0;c3Di174;a45F4e2B31h35A5i4CF5o4001s37A6u40CAy3007;aBC6e3483i1DBB;a2F40e26Ei6k10FEl4F4Fw6D8;c44m44t1C8u22D;a1e467B;a3BDeAr19s1FtB;a3BbF33f4998g3507h10Cl3B0Dm4EA5n2183p29E4r4C78s3B04t4B1Fv44z409;!d0r4627s0y0;eA1Dh2601i5D2oAE3;!aDCe166i6l7;!n32CF;o1D4DuE;iAFo74;!i1Am2E;lA5;!c7s0t2347;!l7n1F7r1s0;i2Bl2Co72y0;!h109;gBl54C;a1eF4E;r31ED;d0n190;l1ED1;m326A;!h347;g55l1C4;!b1599c513Eg283mB1r208s0v103;!aCFc1630e5ADi18EBl80m3FBEn3885r1770s4787t137v3Dw6A;!m2Et0;tD15;g55Cl189An4DEBt31F;aBEo16Ar358;e1733;!bBn3F4Ao255p1296r4F86s0w9;r2B4;a1C1Be373Fh4923i2F99o4944r1169w56A;e113n4951;i25y0;n194s2Cz2C;m2En1;!a1e9l7Ep276tF8w80;a20e3A;!l23EA;c19Dt18;b7C9u126;a35C0;fA6E;!a22C8c3E2De43E0hF0Ci230Dl1D42m3FF3n2870o1D54pFF8t1670u50FCw2A52;e12r1A;cBs1FCD;!iB3Dr2275s0;s4Ct2D;d16D;a378Bb340Dc1708d3171e4394f1C4Cg4272i38F2jA7Fk2FCAl4AA3m2A42n42CFp3951q1r3037s2276t24D8z2608;e23i21p35F1;!c0d1s0;c0d1s0;!e12h14Di596s0y0;!e12r7;!m4026;d0e1r2Ft20;b98p82;!l3E40s0;!a249Fe3D19h223Ai344o1F5Fp7As0y25D5;fA85;e39BBi67l14Cr89y0;!aCFd0fCEr36s0;a1e561i6;eBo17E7t1;!d0fB5h109l22r1s50Ey98;a1062e22Fi2195o13B;!i63As0;eEoE;e99r258;c77d1z19B;!a69d0k1C94n1r1E1s0w1E4y1;i13y6C;c18E0lBn1t1F6;aF89eD4Fo1866;a73e1Eo2228;e44DD;l3AEFo23Br4310;b4ED;!a2E29e134i26E8o471s0;f4FB;!a66Fc34D4e23h11D4i6jF6k48l5Do4FC7qB37s3116t3BF7u1B9D;!a2B9Ec1F3Ad40D4e26C1f45F2g1F48iEEFj4BD0k78Dn3D40o439Bq1D2Cs1DBEt4F94u49v4EF8y0;r6D1;a2634e3697h444Ci6l4B4Dq4FF0s1B7At3A;!r835;!a1EA3e12C6i2424n22o601s0t11u4C0Cy0;c3A00e927g4915m3318n3FB4p2568r2774s826t46DBv4D9x1F;d15C0l83n4F17o3482r132s13Bu966w1ExAE;e327F;!c32Ds0;!e0l3As0;!i3Co7AF;a2596d2BBe1D10f4BE2g21B2i418Bj9BCk1m5074o3345p4B42r3A5Au34v22AC;a4F5Be2887g2DFCi2BEAl76m4D8n27AFo407Er1FA7u2DB6;!m1A92r2516;t27u49;!b84Fc2656e15i3E4l4B3Br4ABCs3F7Bw38A0y0;!a7Fe4i6l22sECw37By0;cEd3n4B;!a52m1EoE8p6Bs0;d4BEB;a4EE7eA52i4964;!i3l203o49t380;l58t5A;rE7;l49Cn1s12E3y16;c4D27;!a2992e4i0s0u5;!i31o46s0;a2627d280Di1A4Bl3o9DE;!e146fC2i1AA5s0w236;aB6;l7y0;!l7y0;!a10i279s0;!e22C2;!c258Fd88El1n603r4311s1F54u2807x9A7z84;!a7Fe4i67s0y0;e112nFt29;d1k5Dn2E50sC5tACF;a8Ce3386i2CDl1Dn8p8;e3C1Ei2FBF;!o1950p579s19F;eD3i14DBu415B;a3DAi21;!e1B90hEAi3Cs0;r944;e1BB9h4A80i1BB7lBo3690r22;aEo32;!a361Fe2616i3EE3o5057s0u3CCy0;!a4Be17Es0;!e4iCBs0y0;a2E07i106u45D0;b1F3g4An376pA0Es1FCtE46v3AD;!c15Fd0l998n22r0s3307t210y0;a65i6C;i3845;a2797c62e1643i21A8k2A5o46;!b38Ee1Bi19FDl7m1EBn22sEC;b1s3CA6;a59i97;!t19;c1Cn3s0;!s816;s816;r214C;n456Bs102;d0g94;e31B6;c11eA;lE0u3C;l16BFt5A1;e30i33B6;a1B69c46e2474i1845o3D9Fs11Ft42AEu628y0;l40A8n1;!e4m2B8n16A2r145w9;!a606e4i6kA1El1n3D27p273s0;!e0gBl0r0s0t3;!e4i6o10s0;g325s1AF;!n56r2974sFC8;!a111s0;r230;e1ADDi26FA;!h1s0t3AC;!f1F1s156w124;a16CEb14E7c3DA7d1D45e48F0f2C34g2EDAj76k2Cl28D7m223Bn31C1o3D88p21F5r33F4s1DF8t144Du22DBv1E5Bz4D7F;n3Ft7;eC15h129Fi577k3064o3124t129Ey0;a69oA32;e4ADFi3Fo29;!d0i6l28Es0;iADDo40;aCb2865c152Cd44A3e5067f301DgEB7h289Ci26F7j1Fk30A0l13B7m4480n306Bo1p4592r2430s40BFt494Fu11E7vC5Fw3FAFx378Ay23B4z160F;gA67x1F;h2487;!e220s0;e1i33B;b7C9;!a4Db62f17Bl22r1s0;e31r1A;!e21Ai3Cl7s0;y3;y52;eAi18;i3C40p4F7Fx500;cB29;iADo40;!hF1m2E;r5BF;!d0e1i6;!a428n0r1s0;s7BF;!c4Fs0t1;w10C1;i61oDC;d0p0;a12i97u5;b226D;b1B7Dc138Eg1723i1210k310Am481Cn2AE0p34E3r16Es3E5Ft3E1Bu4AC9v3BE1w3BA4x4F2Dy48;!b1152l10Fs0;g4458;a1e1BE1f0i16E1;!a30s0t1;c3433;!g3l1s0;a69e0;aCs1F;r0s8v47;aB2Dd58e4Ag4F1Bj5As0t3B67zC9;d0t40;eCFl1;e1i4E16s1F;i7FD;a305;!d2De0h1;s4Et1;a33EEe4239i1573o3BF5;i8D6o54y0;e3F9AiA36y0;a1621;a14e0t1y0;e4ADi21;!b1A0d195Bf37l1m2Es4348tF1;a34A2;r42E1;h3302i3Bl3;a4A26b4580c5CCe294Dg7EEh1C36i36C5l4827o2CBBt41CFy2418;!l5Ay0;e1i31;r23BA;e34E0h1C91o44D1;n0s14Bz3;!e5i31;r4C69t325Cy3384;o5088;u22F9;i3F59;e8i21;l87t1;aAFl80oDC;c11t61;!d6D1e12;aAD7l4A58m2AC9pB6;rA85;i17;!a1A0Cc329Bd3784g4980i21F0kB2Fn506Cs19Ft4A39y0;m11B;!nFs11;e3C63i6;i4r0;e17i3738;iEs1F;r5s0;h3E;!h3E;d0l1n39r401;i4546;a1d2579e389i353Dm1E01n1488r2B5Cs48Ft21Du9D5x116;r4FBA;z2EC;!e1Bi3Cl7n22o88pC9s12F8;hA5EoB3E;!g5034;eAi1B2Ck1Ap15EDu659;c94;a51nF;i1311o8D;a41B2b4C9i1D;i7Co10;n29F4;gEC;e1A44o0;a272Ae48DAi4FB3o35F8u16CFy63;a59o72;h2BA5;s361E;a2FEe2452;e9FBo4DE4u353E;l5CE;a7Do8;aBBDe1353i2DCAl4D42o3B98u4CEFy1EF9;rFy1;f106;lAD1;e4i3515o1s0;!o3Bs0;!e235i2F98s0y0;iC8l5D;a359F;d0s0v19;!s0t78;s0t78;a2801;i1n1EA4u958;a1C2Ae1AB9i4BEAl1008o4C19r3F41u942y0;a4BFi350Do332A;!c2B7i5;!e35Cl7m165n22s0;!l82s0;c2EFDg41D9n1p1B0Cr278Ds1617t48z1A4;u98;t945;f88Fr90;!a4De15i199s0wA8;c4CB7;a277Fb1F31e119Ei3102lFCo3C07u23F6y4741;b55Bd0g23F9o1p841t206v2856;!a22DDeC1i6l216n22s0uB;!k0p52Aq0r3C8s0yE3;b0s0;d3l3p3;!b0s0;!e0l0r4D26s0t860;l4E5;e53Br36Es83t1F84;!i306Es0y0;!e35s0;d559;!i94Es0;!b911t0;m116u4E;!i5Fs0;nFD2;a1o2901;h3B02;a3CD5iA18o22FCyC;e4DDi38A4y0;!e0l282t23F8;a50F6e30C4iCoE8;b1FF9n26D0p6D0r1229s17E5t3A2u4FF;dBi1;i44F3y0;a404B;h1i31;a1D1d0l6Br190;i2C8Eu5;p39FE;e4i301y0;eDo10;aCe1i2E87q711t1B51y0;h1CBt38;e3y0;p48BAt44C;e134iF42;a10lD2;c23F;a2D32;a4BeD;a9A6e34Ei2562o39F5;!e4481iD6Dl892o3Br4CE5s0y0;b2D7ArFE;a1EEe1;a10o10u34;i9n8;d1n252Fp4DC3t228Bv674;e6BA;e15iBAl2Cy0;gAF;a1A01r280;iE7n13Cr158t0;!o6D;o8r9;o186y88;i1Ds4890;s77;!n3BBs0y98;!a7Fb516e148i67l36Fs0y0;a50CDeB9i1880o427u4E;a3F8Fb1c47E5d9CFe45g14F3i23EDk44l2702m11E8n4942o38ADp1777r13E2s5t3719u1FE5v2197w3035;!d98Di0l38o0s0;!d0l3304nBE3r0s3Et38;!e4fC2i1956m659s0u3CCy0;g4Ak229m4DBnB3Fs1B6t12BD;a1e390i296Bm89p4F97;h2C;!hAE;i9u14;k24B8l48n7B7p126t3DFA;!d0l7r1s0;!eDB2i253p825s0;!c13Ee1B2i21n3o38Au4D;!hF1y0;s150;g62s316t13C;p1EwAB;dBt19C;rEs19;!oE4Bs0;a111b4531c120Ad3D67e49C2f2FC4g2C92i171Fk4Al37A9m3204n2BA0p35E2r4A79s19EAtF91;a2218c32A4d37B9e1824f2942g35FDh1092i2E64j2F97k2062l249Bm22D9n50DAp276Aq4D17r2B5AsC64t1C50u39AEv3FEAw4CD1x2192y35BAz3DDE;e24lCn2E1;!g3061m24D0s0;!d0l7n22s0;f3BE;!d0i6l6AEs156;n4Bv55;l1An8;!eAs0t3;a4846i24ACr2317u3BA5;l3AB9;d16l0r354s941;a4D2Ae18D4i3E09v21Ey0;a4F9Cd1AeC1Ei4130o0r2B;!gB;nC5;r6F3v7;!a1De164Ai3F6Ds0y0;!m38C;n27A;m38C;m3E96;!s5Et2D;e2160;!d0r1s96CwBF;e1k40FFl7Et2D39uB6;c3n47;aACEc58e4932h3F5k3F8Ao1E95u1583yA33;!k0l1DE5m28n1rDEt42BC;l76;sC0t107;i241C;n16o1CC;g2859;n2t496D;tC;lDF;a257b257FeFAEi312Bm1093o964;i130;kA4;bF3r118wE4;!dEEBe33Eg1537h2B7i2F94k1ED0l4Fn1A28s0t2D86w12F2y0z3;h1595;i179;a1205d1e4441i2DE9k1E96lEAFo28p255Dt2C8u2346v2E22;!e7C2i43y0;n1t4B22;!i91l2Cs0y0;!l7n0;r1v1A;aB72u4BF7;l64r64;!a4E1Be4DC4i2B38l4718p4089r3034s204Bt38u476Ey29CB;!i2DEl1Es0;a548i6F;y12;l3D0n173;!c11e23h27iBAs0t177Ey0;e70B;d4B9y528;!d0l4696r1s0;iA2oDF;aCe338Bi13u4E;!a35B1d4BFBe1F30f389Fi21l3475m24FCn26D2p28C2r28FEs0t1160v441E;i17Co231;u35E;m373;aA01;dBn65u1;i1Dm19t18CD;e1B4Do11Ar4C;i104;i2A7F;i15E5o2481;a2EEFe39D3i1FE1o488Er3512u5;a9E5i4131o2463r514u661;r4ED;!fBFn2s0;o4Eu532;!b151e6EEf37iCCl22o4Es0y0;a4FDDe503;c62d39E6g93Cn3FCDp65Ds45Ct1382w28y28;d0n39r3As8;n46s19C3;!e4i6s0t13D;n6FD;e5D4i6;!p2E9Ds0;y1955;a30e4101i477Bo494Dr14F8;d2Fk67Bl1D3Cm0n2A7Ap12A2r4A1v20C6;cEd49g2Bn7r27Bs5;c2FC;l3A9;c1Cf7n5ACo10;!a75d4339i4E62m116n3E59s20Ft4594;i367n145r42Ex1E;eAi31;g3k0;e12F4i6;a9c40B3f8g1C0k3563l2C77m4CBBp5147rEs0;!i9l1n0s0;c19e50m39;r106;!a2819e1o1C;eE9Ao34D7;c29FCd3g4FBEl50D9m3E07nF00p2A14r1D31s4360t24EFv2C05;!e1iBl2D9Es0;!d0i6l22n64Fs140t16C;d1e1l28p2DDt28;!a2305cC16d25C7eBg1715i2A05k1D68s1BA0t48uF0;!c32r0;cEx1E;r78F;d1e3Fj4Cl22C4nE97r1090t9A2;e4i5144y0;g25Fl118t61;oE3;o9BB;f0n0;d0r1t179y0;h1C8Cl87r4126;d0n2A7;o30B9;!aCAEs0;!aCeDs0u9BE;tEDy1E;b1Cc391Di6A4n81B;c0n3s14;!aF74i71o28s0y63;k3x0;d0l1r243B;e17i2C3Fy0;!s2C9;e881;e4690g4EADi3C;o34C4;e34Et1;a1e5B2oB86;u3EB6wAF;!a49FeAi67y0;a0c2Bo33A1;!e1r7s0;a142De23i6o73A;e26C4;!a3426e747i2EF5s0y0;!d3i4s0u5;!eAs0y0;a2D8Ce2664iEoA6u6yC6;!d0r1s0wA8;a4EAe1E5Di4A76r91Fy63;u4F;!n436Es0;d2D80m4C4r3718x0;!e5Bh60i2Bs0v3By0;n1CE5;aA94c0e5;i33B;!e4i11ECs0y0;c466k28m1;a249;!i111;r285Cv62x121;e2E5Eu5;a0c0s14;rD8D;c8p8;!b395c94Ae15i1BDAm5Fs0w24B7y0;!s0t41;h117o50D;aCl3m0r3;!rCA8s0;!e12f37i43l6Bs0y0;h2D97;e5i31l19o46u1C;!e4i3B7Co1Fs0;a101e1Bl7n139s102;nFuE;!a1e14EiB98lCA0s0w768y0;!e4i6l58s0uC;!a287CeD0i21s0;e273B;e1Bn18As102;f1n2r23Cs36B2t14FB;cF5d0r1;e2DA8i260l814r434u8E4;d3i1BD9k243n272Cr20F2s62Ft1E;g5Bi4m1A;!e1z199B;l295;!a28A4c98Be3C8Di3E37o2FAr1527s870u44B7y1CCD;!c124o656;a14E0;s6F8;aDBh691;e28E;cBe24k5Dl24FnF;a1o10;a2F6;d0e25i1FD;nE3;e23i21k5FC;iEn25x1F;tFDz78;a2D84;u1F0B;l242B;e3971i3138l38r2294;e25AC;!e26iACs0;!e201i6s0;z78;k5Dl0t3;!cD8s0;s83vA4;b1003c297Fd2788e13DBf10FDg4610i1F43j1Ak230Cl439DmD8AnD0Ap1F6Cr3A52s2F9Bt283Ey1zB66;i1Dl6AnAEC;i49A5;!c7AF;!a220Be161Fs0t35AF;a97e1Di51E;i20EDs29C9;!a1560e430Cg1911i3A1Dl128Am165o446Bp730s0u8E6w706;i3529oB84;s4710;d0l1F2n1r1;a18C2i103o256u25C;f7nFt7;e30E6;e399o1;d3kBr40tCA9;e241n2503;!l0n0s0;aCFi4916u69;!a1243e15i39FDo36rC8s0u25E5;h460oE4;!e112s0;!p42As0;!e1Bs0;l237Fn13B;!b64e403Ff5Dh3CEi6kE62l2EE0m2EpE3s16C9w209y3946;p3A4Du3062;!e15i6oBs0;e5l3DD2n2o10s6DEvB;g4CFn38;!d1f37i6k28m2Es156t141;k896;a0e0s0t1;l1BF1;c3Be12nFo1;i39A3o3F0yC28;!e3AA4i21oFr263Fs140;o806;!a4De15f37i21l679s3DEF;d12B0e1i1C0Cl2EA0o3F0;!d0r416Ds0t16;a25e10r2CAA;!a170Fd4AB4e2AD7g216i82m114r1603s0uEB2;e1u1;a33A4e99;t4CD;a52n2;!e15h196i6s0;b1E4o39A;a4Be15iAC;i71l7y0;r7uD;e1FBi6lBo35;!a390c35Ee4i67s0y0;z99B;c38B9;!b4179e22FBi563m58o28A6p28s0u4194;a1o20E;t7CC;e23CE;!a51n28s309Cy0z177;!e15i21l22s0y2DF1;!a43FBe12i42Do72s0y0;!e5i5Fs0;o1231;a13cCBE;aEn61p46;g3w80;!g956s0;!c3B6FdA4k28s397E;!e39Dg314l4261m26A4r27Cs0u8B;e3046r506E;z5EE;b7Ee42i2Bp1B4y0;a7C5oC9;!e4i6s1F;a30BC;fAE8z431;r6F;e5058n84u6E6;eAi67y0;l28n67Fr2Fv45B;r19t19;e0g1Al58;c476h2CAk2FFtB;uDA;iBo72;d27t1;!e159i2E63r58;!e39Fi2084t6F8uD3;c121d42FFl47A6n1C59o10;t268;f108m4CA;e9i2Bl44s0;!aFAAe308Ai2F06n38o9DFr25A4s0u18E1;d1m1o3C;eEu20y0;q50C3;e0i228;!e5i50s0;aCe1iE1u5;g5C8n13Es2F6Dt45F;e48B2i21;h3B2;a347;c1FE4iDt2106;!i3Cn22;c1n3r1s3EE;!a100Fc206e1BhB55k5A0l181o3BD;e2FDg3;b3E6e0g0l37BA;!e4i2BEs0u14y0;a3219eAi437Fr138DuF0;n4AD4;d0eAr9t0uEw9;w127;b1Cm0nFo10vB;!b358s0t21B;p382;a69F;i4A34y0;!a10e7F4hEAi1DBs0;!e3DCAl3o41s0;!c64;c64;a1A82c28A8e4B5Bi1755k2CF0m1E23o13BEp2AD9s25A7t264DyA03;a0c74Bd28Be5f341Di31m18n32E;e12Ei154y0;o423B;fBFu5;!c9Fd5C6i50Al84n439As2E01u5;e3B6B;a3EC0;!e24i6s0t11;!p1E;pB3A;i3Cy0;a3261i384F;a4753i3DE6u2E8;!e0n25r78t4B2;!e0r78;a2B57b435c1101d1156e4E0Fg4A8Eh211i50F5l4C64m2FAAn486Bo401Cp2128r4E76s41CEt73Bu3C48v1D51w1BDFxBADy382z2836;e0r7;cDAs89t1404;s3z52;o13;g3CD3;b4F32c449Bd1D6Ae1AE0f4F11iE51l1C48m1669n3ACEp1D76r4136s3FC2t4E72v1945z0;h833;h44;!d7Ar2151s0;!d401r39D7sEECtD5A;a176Fu0;p528;a4De3E7Fi2F5;a1485e4018i57oEE3r3C25uE;aD5Cd1D1Ee1981g10B3i3E39n89o1351tE84u203Ev650;c3823d3B3Ff3011g44C6n338Ao2175r3B1FsEDAt21D;c4A8d1F3k2B6nBD;a1e10F8u1EBF;i488Dy34FA;!d1F07i1k4379s0t2D31;a101eClBu34;!l10F;kE5mE5;a1e17i9By0;d4A87e2119;a25n1C4;h44D6i932;h5;nFq882;!a4Bm2Es0;a35De886i153o3DE0u28C;t2707;!n3Bs0;a2EE8e4175l502o1F08;m87;f2FBu5064v3;d0t21D;d0r28;bF0n1409vDC0;o1A23;e427Di6y0;p4Av1B0;!e15i43s0u49y0;!e4i6m2Es0y0;!a2FDCe15Di21r7s0;!b65Dc4B06e15i1ECl219m2Es356B;n33E6;!e4f37i6s2649y0;e32B8i34B3o3895;!e4i3s0;!e26i43s0y0;aFC4b3D7Ac39F3d3F0De236Df4BC1gD98h1i5B8k3663l26AFm368An3398o4F42p40EBr35C7s42C7t271Fu2845v2AC5x46D9y5B8;!b328Ce23i6s0;a75i88u14;n8CF;a4B6Be6Ei2Bo43D4y0;a17CB;h46EiF;d4649r1t299C;o3527;n4t1;a537e319i3D50u5C;i495;a4E7D;f3709g34Fl388Fm3488n3FAAsBB3t38v44;fA9E;e9A5;e0t7;b429e6E;tB1D;!e49E6f37i35BlDE8o1p19A5s315EtD1F;c7l1r7t665;l21E6;t3D8E;i14s5;n0r58s0t1;l4871n8;a73o42rE0;!d0m2En0p38Ds0;m4F57;d0l1r1s8;!d7Ae32D4i21l309m2Es9FC;dBm24BCnBo8D;!d0l36B7m4F26s0;n3s0;!n0s52;!aAAEe1DfB5i3BC3m2EC7o1BF3s466E;!a7Fc15Fe4f6B8hA4i5D7l10Fm2Es0y0;eF0;!aEB4e1FBi21s0;!b2F27i7F0mA9o120s0;!eC1hA4i86lC0Cn22s0;!a5C3cD1g4FA5i69s0w37BxA5D;a368;aBF5e9;m8;e17i21y0;l95;d0n90;!aCe4l7s0;h1r378;!l47s0;n4r7;l1AD0;l7Em36C8s45B5;fF2m64t2D5;c330;!c330;t3w1;iBBo8D;l5106;!e18r114s0u2EB;!a3DAb1641d2E39e4E91fB5g2A0Fi395El48D7m1EBn2606o2461p2E59r249Es0t43E3u431EvEC7;a1D5EeB76u937;o516;g94k3t0;!d2365f3C30gBi1476l29Fm626n2997p4B0r4DE7s492Dt212w34ED;n7y1;a3F6;i4D3Bm29B6r2EF1t5C;e26D4i6;e2740oC8r15FDu34;!a50s0;c3Be1Bl7n15A5;y22FA;a4EDDe3D6Ei1BBEl1EB7r1C05w6D8;g14CEt55;s1FtBv3;m39r80;o2B08wC8;!a3F6e1F71i12B1l7o1s0;!d132El7Er58s140;e1h2A3i3Dk3BA9;!aBCh0i6s0;!e4i60Es0y0;!e4i301s0y0;n49D9s1262;tBC;iE7m1Et23A;c0f197Bl7D;a147bDFe1f3k2Cn25o3941p238F;h1Fs1D0;l306A;!i91y0;!m41s0;o72r209;!a1436h2FD4i177Ds0t318B;!a39EAe12C7h48E4i2FD0o4C6Cr3E4Du1C2;a10i21y20B6;d64pCEs10B8t417v1259;a1284e1BFCh20A7i3F48l2D6Eo1ED6r227Du24CEy2154;!a1Db1Cc1Ce24m0nFs5Ft36Cz5F;l2DD4m0;l76n3573t1Eu499y82;i57D;!i57D;a1s3;d1Ei6mE2n1;eCBBi3F;d0r90s0;!aABDd99e2161l7m1Ap1As366;e5g131j1461r5CAs34F6t1C8uA20v55D;i19Al47;c0dD2n3s14;a369De19CBiCBo3587y0;lF1oF;!l7r0s8t170;a673i36Do130;k3A29;aCC1c13BBe4245h3FA9i48EFj49B8m5DCo4CF4r3A9Cs434Fu4B92w3F12y1FB7z1975;h27p6A;gBl1rBu8Cv3B;!d28l2944n48s0;d0o29r7;a2F42b3535c44CDd4EDeDF9gED7i1657m8Bn4D89o243As4CB2t4BA2u3143v1A;!a8b7fB4i9o83Ds0t41;!s18t1;!a1282b3B96e2141i1720l3379m2Eo444Fr49F7s0;e1FC7i3068t40;c0n333;i26C;e3CB3i2B55lBm2Eo3763;a3E0;l30CD;a6En1EF8t1;i3AF3o3F66;p18;p4C16;h507Co144r209;!i288l7s0;n281CoE4v3DA0;!aCi223s0;a3E6;!eA4Fi6s0;e6F5o231;b425e17Cl0n85FrB5Ct2D5;c32r25;d1l379An1r41F;h1AFBo5C;e2CF;s44t28;!s117t28;oDAr455;b19C;b1Ce442n1FF3o1;e2C75g38i49E2o224Dr320;o1D1;o581;d1193e1F2Cf8g44EAh1An44AEo147Dp4B8Bu4w52;p34E4;c0s100t7z3;e0i6CE;e4k1E;!h38DEsDEt1A5y1B23;!d3D06i6k2D3Bl1E84m1n36ABpC48r0s3Et1AD4v2268;f692;!e4i6l28s1F;dBiE4k243n477Fr4FC5sC5t61;a59i31y0;!a1D4s0;d1F8Ak53l302CmA53n328Fr1BC8t1y1A;lC9;a54i73o2646;s3Bu5;a10h342Bm76s29C8t1E3E;bB54;a4E03e3739iECD;!i484o29s0;eB32i6;l2F68;a36l3u5;e26AiDDo12;!e6D;d0e10r16;!a1e5073i23EBo4BC4r16Cs0uD7y63;d27t38;n3F1;d0n5r1;h56o10;!b2AEBd77Bn225Do2EC0s0;b1Cc5Cd1D0gB;a1DoE8;y4D03;d2658n2s0;a50u1C;e4i4F7Ao5F1y0;a220Fe37BFi424Eo36y63;a3B10e4BDFi265Eo1942u4CBCy4759;c32l1;a6Ee11A8h20Bi4E15o4EA4r78Bu9;!e4i6s0t121;!e1CCFi6m2E;i21n8;n32E;cD3d0n48A;c1s14;!pDEs0;eB61;aA72h1AFo27EBy3E5E;a1Dc257Ek4CnFs336Ft5117;!b7Ae38E6i470l3BE2s0;!k11l78nADCs0y0;e12nFo2EE;!cEd1ACi8s0;l3EC6;a5F7i194u670;e452Ag4D73i12CA;l35CFsB;dBn20;a4FE0e2039iDD9l1514o160Er3F70u1763y4749;n11BE;z1D3F;!n1B74;a4B3e4F8Bh4F18;a4Ce13C0i3AD6oEy0;!e15i91s0y0;a9n78s1F;a1b3B49d0e37FEi21l1B26s3C41t4E75u3AD8;eC1i86;!a123De1s0;l1Ay0;a6EsE;c8g7ABkBr421;!a35CEeE52i1CFAo56s0u29y0;!a447oF;!a52e23i67l22m7AoE8s0u1y0;!e4r0s0;a476Ai808o1405;l9Dn2t1BC3;i1FEl0n122t208;m3A;e17i3A6y0;l0r25;c181t60;!b1C69fB5m3ACs0;b1Ai489ClF0m19E6s3u3211w0yA2A;c4A43i3CDBn50D4r35F7s244;!d0e9l7n1661r2995s8w35Ex1F;e4o6D;!f37l22s0t18B0;p5E0;a12e8p8;i3CoE3r58t53Au38B3vDA;e1Bn22;l1r3B1t3;d41B9n1;n42C;!r1sAC0;!a1e1r7s0;l1B5Cn3;!l382Ep3C84s0t36BF;aCt394;d0m1;a3BECe29B0iE93o93u4EA;c390Cg347Bi297An604p324DqB6F;!a4271e1DfC2g1CF9m2En47Dp4119s0uBD9w1522;e4uD;!iC59t3A0Eu30A;fEwAB;e2810i86;t14D;!a57s0;!r8As0;!a3A7d0i3954s0;o3D7uE;e590f820lCF2t66C;e112l7nF;i12mE6;uEB;h1D32;!d3Af37p5r1s0;aDe1i13u5;!aCe1o193As0;!e1B2;e1B2;!c0n3A1s5EC;lB4r272t1;a40i4EoD1;!e24iBAu470Cy0;i31nEt10E;e12i7Cr43D7;iE7r3;!d38eD0i21s0t4DFC;!e5n2Bs1374;m8BnA35o46D5r4ADEu59v5B;a1De15i6;dB18gB;c32r0uD;eAi6l4CFu403;a42DE;!cD3e0r2A5s0t206;e4i6s0y0;e5DEi344;!e168Di86y0;k0n0;t10Ew9;i39A1y0;rE3;a6BA;e23B5;!eBg3CDDl87o32E2s4F7;i13yC;c361Dh1AF2k208FtBD;t2436;eAn2o10;!a40CDe7FBi3n0s508;i5042o37F;!h14Dl22s0t3ACw28CA;a50i3C;a173Fi5006;f56;!aDi36BCs0;e12h0rB;!b252Cl92Dm1BF4p5Cs32Cw2D0;e12n3;l510;a101D;oB0v3;!e4i6m64s0;g2Bx0;g1Fx0;!e4i3A44o4D20r41EDs0;gF8;eCl1;e5n2s3;e1884;i2Bo165y1;c1529e5;!e24i6pA5;a3AFh1FAFo2635y1F51;!e4i35o57;m3vB4;f36FA;f2749;!d0fC2s0;eEh16;!o28s0;c0d3t3;e610;r191;e5g1;!f6B8s0;e134i1082y0;a1C18mC8o36C0s98Cu1Aw1Az272E;!a4477i24A9o5s0;c2389eDA4hF5k2990o9AD;g7E0;gDB;i4Du3D0;!b4E2s0;k0m0t0;c2Ae5n2;m4D79;o6y0;gA1;!e2907i6;a0e2B0i67k16CtDF;i110o12;!d0l1r1;!b1E8d0i31r1s0t163w3F5x0;g283t2F;k2EDD;i311Fo292A;!e4f2A6Fi6s0;!e2C17o2522;e127Cg25Fn2889o21Cr2283;!e21Ai3Cl7s0w80;a30i5C;i1AEo1u5;l19F1;n3D9;!s0t496A;s0t16;a344;aB06e239Fi47BDo1DC4uDA0y63;e4CFDn2;e9EBi6;!e15i8Eo1s0y0;cEi10n27A;!r3Bs0;cEn1t175;eAiFAo8Cu49;!e4A51i28FDr1AFs0;aCc0;a75c0;!p1Es0tB4;!e12i8Er7s0y0;!h12D1;a9e9o50;a12e1;y2;eAi6s3A;sEt4010;a0e0i13;!i2486k52Cs0;i48F6;l4C70;d0r39s8;b1853c4E28e19F8k14Cl2F0Bm1992n1D8Ap3B81r33D4s42D0v38z3FCB;a1020e2077i20ABy0;a3F8De4CF1i4B36o264A;a3E8i808o74;o266B;a2395;a61t3F;d3E24;!e15i6o29s0;e4i6u388;v21F;i2B94l2DDBoB6Br292uC7C;dBm2Ds4AD6;e879;i35FB;a25dDBt4C13xC0;!e5s0t3B;n2r334;eAiAC;d47C1;i27A;l43B5m229t369A;e1i3;i49D3o12y0;o81u3CA0;!d0l4F0Ar1s0;!l3A7Es5ECtBD;u1F0C;!aD1s0y0;!a4F58e2B00i3AF5o8Ds0;e23i6lB;!a61Fe15i6s0;k1BAl4D39r37E;a4EcF6r5CD;e4F0Eo1FD4;!eABi2C32o504Er1A9s0u3AD4;h2734;a9d0;!a1Dd0eAi6n4FCDr1s39E;!m1As2EC5t107;e217B;o3267;!e15i8El47s0y0;!e45D2f37i21l22s156;a2176e57oA0r9C;a103De262Bi954oAD;c178d42F;a162i57Co29;c83l4F0Cr119B;!a41E2e3F68g172Di3041oAE5s0u1C60y0;!l1Es0t12D;a3B60l691n4097u58F;f1CAE;!e15i43o1Fs0y0;!a2ED9fC2g168Ak3B4l1o310Fr1B6Es0v4790;a36e12rD2;a385Ci0u9C7;d0m2DBn3768p8t0;l3C82n3365s8;a789o605;a1b20FDd3879g331Bk2A2Dl3428m40B5n0r36D4s8A4t5081z5C;!e165Ci32p44DFs0;o2E2u2E2;!rCCBs11;a2B50b4AE5c283d3820eFD5f133Ci2621k1Al3A7Dm1n4EA3p8r1E97s3404t4270y1;y252;a97Bi2Bo390y0;c3d3;!cB2i1Am1EBs0t7Az31BE;e3264;c3E7;e1fB;!eEt27;e29DnC8;cB2k48l40EDn1242p4F38s33E7vB;d0l50E2n1r81C;c20D8oCs4519tCB2y22B;!a4F55e76BfACCg4041h17D7mB8Cn22o94Cs0w350;c4CB9g339p132Br1BDCv219Dw89;n14As11;e0yC;eCy0;!e2709i58As0;o3E0;a0c44d122g28k3610;!a37D2e26Ai3D2Co41ErBCs0u449y0;!aCs0t502;eC1i6l47;c208Cd4D0Bi1C81n373Cr3E2Bs4619u4187;a51e51;e2F45i22E5y0;!a2ADDe111i2C81l22o3EC2s0;!aCe0l3n2s1Ft64;!b3848s0;e8FB;!i10Ao29;!e0i0s0;b8Bc624e1i124Dl3w9F;o40C1;!a0s0u31D6;e5A0h60i838y0;c19g19n117Dt19;a167l4E3Cu38C8;!p58s0;d0r8C3;d1Au8D;o3402;!a28BDe4100fC2i2B13s0t16Cy4260;r36C;i21o131u4;!e26o2s0;a1908eE7;eBl2C;!e1BnFs0t1;!d0l22s4740;u2E04;z4C;!a4Dd2035e3EF9g2Ci21o1s0y0;c32Dl33B5;!a32lBo11B8s0;c32l3CF;!i181Cs0;u161;e4o8;!e1561hA0Di3F4o29s0;!d0l1B4s0;!d0n0r16s0;e5116;a23C9b3991c4395d3BFEe1F7Fg3224i43D8j2287kB0Bl3799m3635n4257p3D44q4151rC70s327Dt396BvEB8w3CAEx38DCy1;e1Bl7v3;u750;o39A;!s3E9;!s140;i3Fl300o29s0;e57p8t0;!a1245d3489e24AAi6o10s0;e8Ci3Cy0;!i4DF1o18B2s0;!a0e1g38Ci13s0u5;c2Cr3576;d3BA;a2745e8D8u815;!c232h2BE9s0t225F;d0r78;l1AA0;!e18Di6l2C;!l0r7s0;s18C;!bF8d3E98e23g2D4i67nB08s0t58y0;r254;!eAi6s0t26CA;!e432i6s0;l23A2;!a299s0;g3Bm2CAFr322;g2CoE7;n3Bs2139;e196g0i71o29y0;a9s14Bt7z3;a16FFe281Ei40A6o257uB8y67A;i20o105;!a1EEe4i1A4Fs0;!a1e4i298s0;e6EoB6;a2401e1027i28FBo28EE;a10e1oB;!e363Ai2FA6l55o6BEr7s0;!a2C85e15fC2h60i4427l22s0w136y0;!cB2d522f1C26g5026h1j396k116Cl1CB8n335p28r3C5Bt2FF;d222;uDC;e60i12Cm1En1Ep1Ey0;!d0s0w1D5;a1e20F4i1FA4l2BEBo1r2ACCu1A;!d0s0t27vC3;!e113iBl4CBnADCs0t4Ay0;sBt16;a16Ae4EE0i21o6CC;o9F9;!c3g3k1;m4815;d0e10rB50t16;u3F7;l62nB1rA61;!u1C;i3DF7;e5g390El27E1m5FAnBs2CACt3776;a9e2981i15B;!a4A24d321Ae1i3268o13ABs0u4FAF;h273;zDE;a1A64e34Fi38;i36DAoFC3;!e5h1F;e4i1C5y0;t19BC;e166l7nF;!b1C21c4989e3D6Dh1l1DFEn3953oF3r4FCBs1C80t41E7;eAiFAu49;!s0t2C;e4802;!i5F6s0;a6E2e9o50;d2F5F;!aA5Bf8s0t1;k48l1;a0c0n1;!d576e43Ei6o12s0;e1EFr1A1;!e237Cr12B7s0;bA40c1816dAC8e12f183g29C5l4CC9n2E35r37B0s505At1FBDz8A9;aB1;!l4E64s401;a65e44EFi54;!f2F75i12s0;!e12t0;a2EA3b640c121fBFg21BnFo493;c0tD2;rB0;m7n8;i25x4C;a1954e16EAh709i1AE1o1E2Du3092z3D2;a32d0l1Dn8;!s0u4Ey1;v11B5;e14kB;!n22r1;d1D2A;t3056;!a4Dd0r1s0;a8A8e1E71h1AC7i19DDl443Dr4C92u40BA;m0n127;e3E1D;c3526e7E6o4F96pB9Ft210D;e17i6F6o46;a4AoAF;!l22s2E3;g41lB;!e3B5Ai6s0;e33oDr7;a1367e934i13CEo367Eu2F03;u40;t304C;a44Do93;a3D03eAi20Ao29;a1A2i171u9D;a3734g0o36;a59oC7;!a3D37m3Bt1;a38Ae4004iBEo4D3D;!f1472l690n343CrC02s99F;a54o57;f1AF3;!i4n1s0;i160Bv19y0;u991;n19C;n292D;l1n3325p1;!a176d0l22m64r1s0;n68A;k1A7z84;i13Dt40;p40DD;p18B;b4209;!e68i1ECl5Dm2Ey0;eD1h7i20;!b1Ch263s0t1C33;aCFiCFu36;eD7;c229Bo43C;i224y0;iA8Ey0;o2D9;!b1Cj6Bm1Es0;a1eA0FlCt1wAB;a169oB;!d8Ai96s140;m10Bp1s9Et1;g2D4hE;a793e0iAD;i77s1FFAt29C0u1135;c0e68l6A;r4s5;!bBg94n239pBr2CB3s0t4738;a4B17p48;aDi0oE8u5;a1n3Bs1F;!e329iCBs0y0;n2t71F;a3864;!d0e1n0r90s0;!eFFi86l47s0;!d0e1nBs0;!d0l22mD2p10Cr1s0t2Dy0;e18iE;mBn0;e2A8CiCCo6Fy0;e6Ei195Eo7Fr2A4C;h134Ct25CC;!e4i6E1s0;aA59e3D;aF7Ei954l2D0o2A63r767u28DA;l3EA2n49E;aB07;f5B;t4D6;eE45u4BCAz3AE;e3F25;a4BEDeFFi181Ao72u3ECy0;i85s0;s19t19;!e221f37i86l7s0;!i4n8s0;g2Cn3;b2ClE7o23E2p2Ct4D90u1293y3D;g4527l268;!e6E;d0n1r7s0;!h5F8k36BDs0t37A;u46;n1p8;d0r2Fs8;v554;a281Be280Fi33F3o2E2Cu1810y326B;l28r1;k1B72;!d3;eEo74;!a3A7e2CCi32Fo12s0;c2AlB3DsF0B;n2B6p1AC;!d0lA8m64n8o1s0;a3E1e3E8y182;l7nF;n2Do10;!cB2e15i6s0;!l7r3;!e4iCBo2F7As0y6A2;c2Bn84;u14F4;d50Fl53s1F;!e4f37i9ECl22s0tF29;o606;e33p8;eFFi6;!a7Fb14ADe26f151g25Dh40A9i15DEl59Bm6FBn2A8p4012r4292sC7Aw17FAy0;z25DB;!e1Bl7n22sC5;!fF2iDBr76E;!a30e25f37iA64m2Es0y0;!d0m2EsECt1;t13Fu59;s1Av9F;i1At103;!a30e3F3i6;l1t3F;!a88dA99f430Ai13m3C6s0;p169s24DCt2D;a18Ee12s1F;n2r35;l268s5E;!i245En3D87s0;n7B8r1;e2FFE;u5FD;g1k28q3B6D;e10CoA0;c0e1u14;c1Ag28Bm9F;!gBi223;l243;d3Bn1;a1Dl216oB5Bu72y0;g4457;!e10Di6l7n22s0;gBi1D;e26iBD1y0;r1CC;!i30B4s0;a57e388EiEm500A;!e4210i6p4A2As0;!l219n22w136;b3FB;!e0l4143mA22;!b675cD3s0;p45F;a4De24g62n1r62t3A37;!t48;i1F7;a3524;k3A64;i7Co3C9Cu34;eF9i9;g47t3A;d0x0;i4y1;s268;i42F3;!aA55c13Bd8CBeAf61Dh3F38i6o1F0r5CAs0t34D5u20D1;s843;!a11A5e24iB;lA4A;!e12iBs0y0;!e12i2Bs0y0;pB0;eAi6n24F0p0;m70t2D;m18u5;!a1F7DeAg78Ai6m2Es19F;n430sE;t107E;!p23Cs5145t5C;a20e57;a1l149;r4EAB;m1En4C71r3B9C;c390Am340n4s83;e17i1EDDoBE;!e4i45A7l16En22s0;!i10l1Es0;x55;l4ADD;h16y16;kA3A;g3r14;s1CE;eFy0;g0i1;o19ErF1;a3E2n2u34;t1F9E;!a4Be1159f37i44DAl6Bs0y0;l1Er1E;!d362Ae1h47E4l78n22r0s3Ex1F;!a7CDc1EAd3D58e1984g3C44i23B6n0r58s0y0;a157Ee2107lA8o335Er1DF1uE;!d0l22m2Er1s0t2D96;a152;l2C40n18r76s1F;a1i31n3t3;!c1123dFCCe19D5g1D95h9B3i2E9Bk3lE07m4F14n4D57r26AAs487Dt238Bu28Av3725w2301y307A;!a1e3493i4644o2BA1r192Bs0u6B9y0;d3C0l34m2696r1905;c340Ek39Cp340;i28E3;b455c536e40BsC17;e17o6;iD94u451A;a1BC1dBe1C04i80Dl3F6Bp8r456Fv5B;!a4Dd0l24Fr1s26B6t58E;!i9E7y0;c3EB;d4Fs0;!i331s0;dBs3u25A;g941n25s1E;p0u5w175;a2829b2FF8o50A;t502D;!e0g3D57k1B7l7n24C5s0;n1F8;r23CuE;!d0lA8r1s0;i5C7o28F;!e15i326s0;l1n1FFs11F4;aCu4E;!e31A3l7n22t2FF;!d203e7A5iCBm2Ey0;!fC2p7As20Ft107;!e221i86lF4s0y0;n31D1;b1EeE2m35;d0r1t63Dy1;!i71o11D2y0;b10Ff8Bn398BpB;i5y1;!e1fBFo15Cp37F5r1DEs38AAt0w9A3;!e26A9l7n22s0;!d2Dg15An0tF9A;h38uB;eF0h3054;!b1A7e1h1FF4s0t314u1F9;!a162s0;!b1Ee85i86l7r5B;c0s11;!c11s0;aCe85;o980;c507e60Ai0r58;lB55n2A7;aCe4;!e2DDEi21k5DlE3m1CC4n1rB8Es2F00t4A;!e4f52Ai6s0t26B5;!d0e85s0;!d0e4s0;a70e1;eAi37EDo12r1A9u49;!e0l76s56E;r1y0;d3g283m4CAzA4;!b1DDd0l7n39r0s3E;a4FAb2D4iBo289D;!b1B42f37h183l1FA9r1s2575t4AF;i12u284;!a2411c2534d3C65eAf5082g809i1125k35C3l57Em2En28ABo3813s1337t5109u4C09w70D;g3Dr0s8;e24Br3589;k16n0;a36A;c3C0;a32A;!d0r1s0t2D;p38BC;!b6E9e4fFB3i6k1A45s833t88C;n3359;n314Bt3389;o19;s1BDE;t78;!c2B16d1B78f3890i6l2B7n2359p17Br503Fs0v3DC;d1r163s3485t3626;!r7s0t41;!o59s0;!e395Ao267Cs0t48u47Fz2E5;r10u2CD;l1rF;!f1i3ECEs0;i1CB9y63;!d2058e5iCA2k48o1C1s0;n12Ar1128uD;e1g53;!m2Eo34;l76s1F;d0n25r1;k1t1;!a2576eF4Ai1858l4AE4o49r3400y0;!e2A00l16s0t18;a42f17CDl27Ct483C;t494;!c56e12i91l2Cs0y0;i1Ds3B88t4B85;b7BlA58nFs102;eA4Fi289y2EA5;!d0l1r1y0;g94l55n192t1;lA65n1E2o3B7r2B86;u4D38;e3E0Di259;a10oD30;o216D;c1Ce5;!d0i18s0;r49B;r1022;aCi18;t6DA;b2A59c1734d50CAf36F4g13FEh28i1749j45D8k365El4A48m26D6nE08o2EACp1A7Ar32C9s4A9Bt2E58u4AFDv1309w1A9ExAEy4B69z2E9A;!n0p46s8C9t107C;a1rF1;!e0l28F3s0;i4Eu8;!a4Be15Bg1i226nBs0y0;!e3F3iDDs0;u7C;a75i250u14;e24t61;f3ED0nF;!e79i43lCEo10;e8FtFE6v260C;!e235i6s0;i54o22EB;o2CF;a598e3014i312E;nBu5;!aCi11A3o4A21s0;!a1d46E1e10A2fB5g38i375Fl733o3B6Es0;a3D02h3CEB;h3B;!e2815i4581s0;!a10c1BA9h28k312Fs0t24E8uE92;c1dBs19z19;!e26E2i33Dl2AA9o4977s0t48uD7;a30Fc46BBd54Dn2o387Ap350As14DDu14x1F;e1i73E;e4AC;!e68nF;i3BF9n84y8D;e14Ei6;o186C;a40F0e1F5Ai4672o12y0;aDi63Ao29;!a1E66e26r7s0;d0l3Bn26B;i3C85;i3u13F0;iCE3;aCd27;!a275s0;a1944e3247o50D8u670;!e712s0;m122;e1i4B7Eo57y63;!e11EEi1B15s0y47DF;aBEe4l22;!gBi9FFl6B7n48r13D2s0t608;b370;!p98Ds591w1C3;e123i432;!a1l2Cs0;!o34;e4i6u1C;!r31CBs0;a51e467i6lBy0;!nFtB4v3;!d13BhEAl7Er7s140;!e23i29Bl19s0y0;e1i13o1;n42E7r1B79s3;!e1Di2C18t15Fu34;d4BAl31Dn76Br350Es1t73Bz431;b2B3t12F;e9i31;!p17D9s0;t321B;r84sB;o98u3CB;!a20i3Fo29;n376C;!b180e1B8iA27m2EsECw1E1;!n163s0;!aA71n4473s0t88;!e434Bi21p320;!b4FEAf1k5Dm1493p322Es0;!b3BB5cD3d25D3fFA4l307p3EDFr56s3351t56v55Dw657;c32r2F;e12i5o1y0;a9D;!a348Be1F7BoD7s0;l8Bu2652;!e79i6y0;e26BDi6o453y0;a162e1;h46C0n3;c312d42Fk5A6m24EAn2F9Cs145t0v748;m3C2Ds1C7u5;i3AA;a4389b16BBc3C6Ad1979e2736f4D31g178Bh12i1E74k1DA2m1B8Fn4E56o5053p3E05r1261s355Ct1158u1F81v2848w2CD5x1D63y1z2F46;e5i66B;!e4i6s436;e581;!c47Ad0fC2l489r3B53s0t11CwA9A;!l7y6C;w533;!a135iA38s0u8E4y0;!a4De15i807s0;a2DC5e1Di61Co29BFz3FFF;lA0C;n0o9;!d0e6Em64n118r2746s0;g281h353l4332;!d45CB;!l80;!e4f19s0t987;eAhF7i6;a65e17;!b1BFBe24g962h4CAAiB05k3B58m2Es193Et4A0Dy25FF;dBh1;!e18D8i224l16Em184Cn22s156y0;i244;c9B9f108n2t5E;c32kBn2o10rB;!e12i6n0s0;k0l0;!d0i9s0;!d39n1Es0;i4A38n157t2D5y0;b4265e1g4E7EiB96m11DDn4120p4667t2B23u237w14B3y1;i24FAs89z89;a1162e73iB91l3A87o1C0Ar46F5u4971;!i31;!e26o41s0;e2A80u403;s31F4;a188F;!e15i4388s0;i25A1;!eEBs0;!c47n155y16;d3p3;a2E05d18Fi0l4963t28u28C;!a4De15i21l22o6D5s0y0;pC6;rE6sB7;!s0t37A3;l45FF;i5Fu5;i8Do3Bu0;a65e1E;r2Ds2D9tB7;!aCd240De456h24CDi2A23oD8s0w3C3y0;a5e4C37i1974m626o2DC2r3E30s0t355Bu0;!eAi6p4F3s0w172y0;!b180c17Be24g632h9C4i2BEl22m2Ep455rBF8y0;e3EAi6y0;a88i31;c46k2A5o10;e68o56D;!e4i6o3A6Bs0;!e4i189lBm2EsECy0;d1e5;!a3E8i4BF6s0;!w1DEB;!a4Ce5i123s0;g1i1666;e12h1;!e22Ei6s0;d19e108s0;s3C1A;!a3AD5c32BFd34BAe590g1F41i224Aj374k0n334As3AACt3D82;r46B3u6E;c512d2884t2822;!iA7En89As0y0;n47EDr2A1t1A;aACBc48D3f7A0m3CB8n1841o4651p1B58q1F27rBs1F55t3EF7u2254w16E6z356E;!a10D0d3B7De113Bg4B7Bi2258n318q43F4s0t1987w98;r447A;a2465l215A;h354E;e29Di3609o4E;d19l1;d35F;!a4Be1B8i376Bs0;!a10b1BDDe2381g50DEiBl27A7o1E42s0u5y64D;b1s1CAt16;s1C7u5;r28s4E;b231Bf108g3E0Ak4B09l1BA7m2AEEn34BCp151Cr1EF2t33B3z4902;i60Fy0;l8m7n3CBs2A40;e1iB8;m105r152Es1FAt2AF0w1743;dBi25s0;i12t61;e12C3t16E2;a448De5i13Dt796;e1i5EBo29;aD49bE3c44D5e43C3i1A41k2EA7l41C2m1AoDBAp1Au367Fw640;c9Ed157g2Ct28F7;aC08;!e4i2F5o3BDs0u5;h3ACA;!e4l7n0s0y0;!e4i975s0;l62r2B8;a0o29;a8c8t3x0;cBt33C0;a4E1e999o25F2;!d0s0t1x234;c35Fd28Bl1072n2B95s0;mD2;eC7;i1Dt0;!d184i3Ck1n2BFs0t379;e12oFDC;m47DDs3D4Ft186;a3Bh513Bi61Ck184o4E17t4674;aBDEe2DABiBB6o26DEu27D8y3BE7;a41AFi46E0;!n3F7Ds3;a2582e4C7Ai6o558;c4B9CdBFCl117Br3285t279A;d3BFt8BB;e329i547y0;n2s526;l3F6r3;a1610bF17c2D77d1DFCe2123f2502g39B5i317Aj438Bl2223m3B05n4370p2BC6r2EF7s2E6Ct3293u4205v302w15F5x2D26y3561;a23De56Fl116B;!a165Do2EEs0;!l7t0u12;n2B3F;hAA4;b390r178;gD6;i3414;l1n92o10;!e153i43l7m2Es0w371y0;b55i25mBp447E;a0n400u14;a43DAe2D28g3i289k1m3B5y63;!a4Be20Di21s0;!m267p4B2Fs0;n4FC2t24FF;t861;c0e79;e24n45AF;i1CE;!e164h1i1A90s0t4068;!e508Ei168o529u2C4;i4FEt24A;a49B1d3814e1154i251FoF6tD4u218;a45e14;a2D6Fb303Ac514Bd4D0Ce21DEfF79g31CDi3721k85Dl15CBm4BFAn16F7o1C46p2E1Ar1479sBAFt34A6u4566vE3Dw3CACx2DF9;e3FFCi86;b29Fh4374k4B45o1s3C45t323Ew41C;tC5x8;t13C;r324;e4C35;l1n2v19B;i1C28u34;o91Dy13C5;!e1146i21o2663s0;n1C72;o1977;!a1862e1BA4i3D6Bo3FACu46Fy346F;!l0r4t3;!a1b81Ae3350g44A7i32F5l8Bm2Eo96As4BBt1838uE2w3AC7;e5E7l8;!d0iD7lF0n1D12o1r511Cs20Ft2Du1;a5o14;a1o14;a82Co97;!e6D2iCBr7s0y0;g17C6nF;e1i30Fo4036;a6DF;!r60s0;d9Ft9F;iC6oF1;b1C51;s2F87;!l7o12u1F9;m2C;i1683y63;!a10d0r1s0;!i8;!n2B66r1A1s0t3C8E;e40B;d1n16;a1AF0e4;!eAh41i6;!a5049e30i286s0u28C;n2126;!c2FCd8Ae3198fB5i21k5FCl4B94n379o3D7Dr229s140t4251v2Cw236;e0o9;!d0l0s0;d0l0s0;!e4iFAo12s0;e82z25E7;o45rF1;a344e11CoBCDu2AA;e1D79;!n83t1D0;!d116De700l48n4A3ErBs2E84t992;!i13o46;!d0i6r7s0;a9e9i65;dA4;i3BD5;!a8D0e37AFiBAl44s0u34B2y0;!a75tB71;a1eBi1;c3d1g3t11;n2725;a425Ee4982fD3Bg1FF8i4996l485Ao15B2r4D2Ft31EA;!d0s1t1;u5055;!bB9A;e391g0;a13e5s8;c12Ah17D;e1C76;bF5C;n2F60y0;i5C;!e5h27s1F;!d0r0s0y0;k2E0B;n6C4r4A44s4B0Dt1;u4F7B;l1CFr1D20s0t0;!e221f37i76Cl7o1s0;e2642f6BCg3ABlE7n17D0p1Er2Cs2538t14A1v2C;a2B68e5hBDo444BuF0;a1D88;eEu34;aDA5d0s5t0;p16v19B;a4ED6u416;v918;m149;!e4i77Do29s0;!a2564g825i3101l3E87s0u13B0;kB65;!o4EFE;e644i32F6o2AA4;aA2e15i6;a4E58;a36o192Ep1Ay63A;sA54;r0s0x78;eA6g94t1;a2E42o2CB;i186By255E;c819d45ACe1559fBFn2C59;m3292n13D1r317Es296;n0t4C;l4DA0oD97u49FE;a59o31;h1C;d0l0tB7;m4C83nD21;a159h0i2By0;a0eEi4o5BBu14y4E;d1A2Bi64;o8FD;e2414l2C;!e15i60Es0y0;!i31s1F;g14m0;o3569;!b1DDe15iCCl22s0w236y0;a51i440Fo3447;e399;a52i13;e144i38;i176t1F8;n8AAs44Ft3A66;l635;i2E8;!rE5s0;a9CA;!d13Bs0;u3D0;!e2225i67o41Es0y0;r2As3;!r56s0;e5Bo35;uA30;d2Fe455Ci149Bk1C0o269v30CA;e0o6F;!a2572d1E79h27Cl28r1s115Bt4825;a2384c345De3629g797i4A8Bl274Fn4A93o3060rF76s1C0BtF19x3D5B;f3A;nFs14;r13Es2Ct36AE;a40B6i9s3t39;!d0l1n0r1s0;i4C95;!a4E46e398Ei4386o3650p344Ar1F4s14DFt889;a59i1E56y0;d1029k5Bl19m1Ep415r1Ev69D;!r58s0;!rB17s0;!s0y404C;!a108d41n1CF5oDB0s32B4t28;!a57d13Be17i54Ao161Bs0y0;!a428b2390e12i21l3408o4D9p1D4Cs32B3t5F8w3F88;e35BFo686;a31C2e16DC;!f707sC5u1w1;!a8i13s0;h3A8kBFDo5068;g6B6l76o0;k3B00;a2837e235i6o72;cEDn1p967;!b5C2s0;!i307Cl7;a0o153;d34A0s20C8t2B2;a10e2E9i3236o346D;!a1C6g45A3l2F9o27FDs0w2F1;nBt2D;e30lBu1C;fEi10m0tB;j6B;!a5E6hF7;!f17Bg5C2sEC;!c11t7;!a2374e2A15f151h86As0y22D;!a45D3b17F8cEDDd4704e3A3Cf1071g50AFk18A5lE98m3872n3E1Ap3C2Ar31A7s2179t415Fv3686z4993;r25vBy1;d9CFg21DDr2A29t2BE8;b7Bn77;!d8Ah1C0s0;a788e6Er45AD;i4y175;d1D7s0;e452D;a159cBe24g62s1F;a154Do42;r2A50;r2B6;e375o4D2E;!i10y1;a3E10o36Eu19;!lE5m16n7s0;d0e146y28;m44BE;cEDvA1;e15Bi48D6y0;bF20c184Dd4F8Ag12EEl2DAEm2BC9n33E9p3B8Er360Fs3251t17BCx56z3E61;k3l2As2Ax0;h334;n2t2131;q1572;r0u12;!a12l31DCo25;!e17CEiCCo31rDFs0y0;a367lF6x4438;i8C7;!e0s525;!c22F7d28gFCn7Ao1867s0t564;b151;d43F8;a57e17o99;c3CFg1A;i932;!e6Ei91n12CBs0y0;!a101i3Cs0;aAE6;!e15i17Ak5Dl7ErAAs0;a512Ae4C10i32F4o31FDs0u3058;!eDl7yC;!a4173e11B7f37h23AFi2CE1l408Do139Fp34C2r3369s4391u4A69;!e3B15y0;!a3B39eBh329Di2B21k2Fl4E85m3218n1E1p1r1s3423t4A95y0;!d0l6Br1s0t1;d4C;!a2FAb3B97cED8g4F54k2A1l320Am2BFn28E5p12E8r1D18s267Bt26E7v24A0;pAA;!c58Ei1E92o73F;s30Bu5;!b425l0mA4n1D8s0t1B9;t4623;cEn4BE;f46g54Ep395D;a162d0l1o29r16t1703;tF1;d6As0;!tF1;f2C64;!d6As0;!aCe147uB6;!e3AF9i0l7o0s0;!aC6D;a448F;e23i1005;a2FB6b5Ce1l76r419u2775;e1iBBy0;g851;c4475l2E2;c1D21d10E8;b13Cl9C8p10B;s69E;n1D8r5A;e4i6oC4;aCi18y0;!e17i4D8Dr7s0;bB50;e7i3y0;l39B3;!aD1s0;aCi5;u1CA;a1006e34C3o2F6u46F;e208Ai3C;!c2A6Ed205Ag4DF8i3Bk44CBs2B99;!s0tD4;!b2EDc260Ef48B1g1hA4k2C8l28n3D77p131r20B4s30A9t26DAv52Cz2C;d82t28;bB27;d0n31F;a49CEd23El34An192r32E7t1788;i5t3D;c3C6i1;!c339Al26BCo45w6A;g0s5;a20D0e179r1A;!bFEe4i21l1C6Ao6Es2211w3C3yBzDE;w475;f4A1;e1874i19C6;!a4DbFEe5A3i21l48n0s0;d1324;h2FC9i1DlCAm27ACn33BB;m18r0;c27DEx1F;cEi10qC3;!p11B;d41tED;s44vB;l8D0;a462eA2A;e22Ei6l1E;e23i86;a972eFFi3950;!d0r1s0t16;k1n1;i5E3u5;eB3f203l7nFs11;!p3CBDs0;m0t794;!a34dFA1n30CBs0;!d0s0u12;a0e241B;a2DBe30i33C4;a3CiF;n6EDr1t18;e166f37l7nFs11;i4A2Fy0;n2DAFo1EF3s2E9t4A;a2590;f300;!k0o0s0;!a4Ad26A3e15i21n0pB1s0y38;a15D5i1D6Eo0u5;a3F7AeEBh2F43i1855k1E16o452Bt502C;p6Bs295;!l141r28s0;a8e9y0;a724;o21EF;u59w9;!e5i1j8FE;i375;u1A0;e37F6r23BC;!a10l44u10;e4769i4F8y0;!a20e4i6o29s0;e81Ei3DC0y0;!s1t1;b1Cs21E7;vB1;!k5A;!e4i6l6Bm2Es3F63;b43C0;hAA;a9t4F;l1B57r65A;c363n70s30B;n118w1;eC4;!d7Ae0i33BoEFs0;!a4De4i5D2o93Bs0;e48E3i256Bo10;d0e10r1s0;a17e391;e2915k3t36Dv3;lCt11;!r19Cs0;a11Ce0i30E4o29EDy75;d391As23A;!a1EAl2AABr46A3u4D97;!a179p655s0t4F95;e445Co23Bu4F48;a83c2792n75Br1E32;e12u32A;a30e23i6t48;!i224l177m2En22s0t4AFw1CC5y432A;!a75i238o0s0u14y0;r8EF;a1AAEe2B8A;!e15i257Cs0y0;e0i45B0;!a4ED7c3F49e5077h1536i4EBFk21El3432n355Fo3DD1p4B43t960u8E6w47E0;e12l1r1t19;!mFB9r1s0;m1F6n42Cr1E82;!d0i6m2Er1s0;a616e3Cu3C;!c2Bd68Cg21Bn1CDFs890t48;b7t0;b2FAc34BDfBFn1s5B0t5E;f19v19;!a42eAi6;a57i88o20;n0sC5;c335;eAg94l83;e0i4;rAA4;n3DF4r4C7t2D;c25C8d0g25FiB7Bn14E9tAC3u6AAw6C9y4077;!e4i6s0u5;d90g16;a6D6;m325n0s3;!eAi6s0u5EA;t190;!d0l7r7s0;!d0l7r0s0;!c89e4FD1i39D0l7s0;a30iE7o83r4A5BuBEz3B;u21;g53;t1EB9;lA7s1F;c19rE;eFBn19v19;l3D2B;d0r3A4;o50C7;s17EE;d0n75Br4008;a51r9u59;m1An4A56pBCsC0t2D;!fF2n2;o1C6;h485D;!dA9g2Cs0;!i31B;i1o1BB1;!c16Fe2A62g641l56pBs0;d0l4679s83;lB4p7u30;e12f1208;!nB;d0n0r90s0;a27A0o4E3B;c2FD1eAi6l4EDFn1Ar62s11D0v1CEA;a2651;d0m18r1;!a75iCFCs0u14;g94nB;a20l3;!aCo9s0;!c1;i3313;!a1BC2c3d462Ee3922g2BBEi7Cl22n29B1o27A4s175At27C;a1E9e2A5Fl44A6n700r57;d0n48C;!eAi6r1Es0v19;a1l45F;!a76AeAi6s0;a4B3h41D5l249Ao211Bt13B;a1DcA66e23i6p1Cr3D;!aCe17g0s0;d0s57;n407s3;e129p397;d0r1F5t1;aA2iB6;b46EC;!b1DDd0h124i21l1365r1s0t21B;aCcB2e1DFi6t2CA9u16B7w25D;e3231;n2s102;d28sBD;c2812;o8r3uC;d2885n6CAs41Bz99E;!a990eEi0l1Eo36s0u5;!a4Be15i8Es0y0;!a25Be4FEFm2Eo1648r514s1608tE0Du1w172;c32n92Ct2AF;n28t48;u57w4B1A;!a1i13s0;!c4Cr16s0;i3BBDl3y0;e21F6;!e4t0;aBCBeAi395Co472By63;i752;!c130l5B0s0;!a1C6Ce5m17C1;a1451o274;!m0t3098;l63n141p4FD7r2E6Et10B;n1rEt47F2;t1F73;a4e4E3A;!r1A1s0;i371Ey0;l58s56u25FA;n8C4;e6A0i9F7;h8Bk48;k1El0;a40Ek5D;a587e1FBCi438Dl371uB6y0;a2AC6h6E9l31B9o2B46u34B8;e30o74;!a40e68i6s0;!e0r1t3;!t1F8;a30e26Ei1E98y0;!a4EE6h29F0s0u2C;e7D3i23A4nD6;c0s52D;!i9EDl22A2sE1Ft868y1;e8i1DC3o36;!a25;e113nF;l2Ar9s7y1;i1628y0;s4A9Ft2Dz47;b178dEBBh1i9l312Cn347Er509Bs4DF3t16B0z2700;l1779r1;!e68fE2i43u57y0;f7n0o9v3;c41l0;a1717h2951k23F7lF71o3C33;a4E71eEB3i4DD2o46C2u18D3;c1B1Ed0f424n3o1C;e147n76;e6Ci908o2A6uA60;a33E5d3FB0e3574h223Ei3A61l46B1o27CAr1E8Du4F12w58Fy34B4;w6FC;a1A55;n65Cs53;e26i44Ay0;rF62;!c2747e5;a1h1A;b16i13;!e15g11i21n0s0;!b35EBc2F9e4f1815i21l3636m11BDr43E6s2ED7w15AA;l157;!e1i2F17s0;!e4n0s0;!a11FCc13Eg3366l147m2Es2A3vDAw28;a0eA3;e1Bf295;a69o7E7;c7t1033;a4E49b29D9c2158d39E7e11C4f2688g4E2Cl4FFCmBB2n3D36o1FA3pD65r12B8s3E5Bt3D63v2309x37F7z3577;!c83d44k2Cl897r295Du21Cy28;i18A3y63;!a162c232e4i1EB3l2F9oDt3AEEu4Ew1A;a1E6e1;a10e5;a2022;m55EtC5;n41t1;!a10e5;g4928t1;e1481i6;a1e5o9;a0g191;a8D9e288Ai2BuBvF2y0;a1Dk43CEl4D8F;z36C;d32E1l392Bp10Br3420t4544u1C1v1E1D;n155;!e4i311r7s0;c13Ei4B38n4p38r8A0s27BDy17F;!o9D6s0;m64r192;m1p4C2F;e23i21l2Cy0;!g2C06s0;d36EErF9Bt721u8B0v3A5;n157B;bBc32;l3BACp3E42r332B;a2Di39E8o1Fy63;a3410y5C;aCi0l4Cn0u5;n3042tB;r25s11;a32h38uD7;!e15iBAl22s0y0;!c1773e1Bf2Dn2;!e4B8s0y0;a3C42i15Eo29;n76E;a9e5u14;!a4DbFEe4i21s0;!m4FCs0;aDe9n8;!a0e1BiBl3A08n22r1Es0y0;a2267i26C5o1C42;a38C9eAi6;!d70s0;o14u8;aCe31iAE6o2231yC;!a5Ae12El43F2s0;!eAi6s0y0;!e15i3516l62s0;d0i10r1t1y1;d3D9;!e4iCBl59Bs0u4Ey0;a4Bd1Ae1A7rD0B;!e12i20A;d0e0y0;eAi3E47o41D8;!h540s0;nA16o29;a1EDe30;e25o6C;c438h1l3EF2q294E;!a3C5Fe4i6l44o21C2s0u49;!e23i21s0;!b3Bd0m2En179r1s0t1;h10ABo1;l1F2n2CF9;!eC1i6l2BArD6As0;n0r1A;r13A8;!d0l7r78s3E;!d0l7r0s8;e4459;c0m0;eAi3D76;a2CE;!e17Fi6s2704;!e5ABf37i6l7s50FB;a31e31i3C43o12;!i9l7;l1Am29r4Ct10E;!a3D2Ee221Fi451Co46s0uB6;a2AD3cBl2C42n2o29s1CAD;l1n28;a1Dc396Dd87n446AtB;!a0e1i123;!f4A9Ar1AC9s0v39D4;!s212B;e220i1;k1l3B;t810;e1Bg3Bl7nF;i38F9;!eAD3i6p258r35s0;!c4Fe1B8i6s0t3A;e4m0;f8AF;c160f240nFsE;!s0t4A;s19t3z19;a389;!t145A;a4B9b2CD9i10m205Eq87Fs1187u29F7;a11y0;a0f7t7;z187;gDAE;c0s12B;!l5As0;a2073e3C06i4DA7o43D3r4BA7u1CF8;e2CD0i3D45;!k18;r37CE;!e4l3593s0t4EF;!e4i6lCEs0w80;a356Ac2D74e1g2ABk12C9nFo285Fp50EFr3190s2372t37BBu3E7Bw3133;c32t7F3;e48D;i61;e5n14A;e1Di1D;!a75d0i4s0;!a2855eAiACo46s0y0;!e15f37i8Eo1r42Bs0w80y0;l4F85;e4i1BB;a7e3D;a1EDe23i21;cBe68;!d3AEs0;i74C;d202Ce23i1AA6kD44l464Fn130r2F8t37D9y0;!s0v7;r1449u4FF;eEo93;o203F;z53A;z177;d0e3Cs0;m400B;m1r25;e0s0;a3F3F;o2053;!s47t0;a4E57d16FBp414q907r37A8s5A4x3048;!eEh9C;p4334;e3D6C;!bFEc4494d3A8eD0i1799kF3o15Cp219s37DCt1DE;i352mBn1sC5;!e668i91s0y0;o114B;!g1A3Ei0s0u1FE;e25o744;m2BCF;!s0t6BF;z1795;e3AiAD;a4C6Ae23i6;nEsBt19;d0r1s8t0;d0r0s8t1;!l1n205s0t1A;l0r2F;u28w28;t3FF4;c11m1;c92nFt14F0;a2662o42B8;a23B3b4D6Ec3AF2d47Ce3F9Ff2F12g4369h24CAi222Aj1730k2825l392Fm1E10oDC2p3CF5q1B52r4A57s13EBt1DADu1AB2v1104y800;b507Ag2FEDi1935k2F49l2C51n2FF0r1C39sBw629;d196e3108i4v1E;e151Fi2F5o275;b1DDs5Et2D;l30Bo12;!b62e12fB5i21s0t0;n3s14tED3;e1Bn4;l1F4;aCr3D;!a4Dd0r1s293;i5017y96;!m47B2s0u199D;b8F2;l16t1E;c3EC8;!r7sFE7;i27l66Dr7;l2Cu491;c2Bn1A34s11t437D;!a8e26s0;!aCi5Fs0;g4B47l84n107s454t186;c1D7;dF6;!e15i21r22s0;aAF9eB;!e23hE3i6p757;!d0s5;h3151;c2F69;a9s3z3;b1Cc6BEdD53gBlDCFn3CBp69Ar40At107x9A7;c197Em82E;!e12i20As0;c64v62;mA4;b7Bl60tB;w214z49D;c19eADm19nEs19B;!a778cF1De146i3DB8n4926o2B69t2C48u47F;g9CDm37C8n3D24r34AEu12;i6n57A;!d7Ef10Bl17Fr7B5s0t4413v19;!c9EoCB6r242s0;e73i6Fo7F6;!r161s0;a793e555lBu1C;c4A45e36D2gBl3197n2959r4548s2043t268;c920u80C;!a1D37b29Fc2739e2063f50Bi4B30l32FEm158Co42E3p3477s1658t323Du2DF4v307F;k53nF;!a4Db180e15i6m2Es0;l419;a4D12e4597h1349iC14n370oBEDu25C0y17FF;!a14d37El81Cs83FtA97;!b278dE6Be4f278i6n3B45s0;a10e4CE0i6;!e0l1nEt3;b37A4c2A91fBm89n4B71p1769t1v43F7wA8;!c246j9Fn18B3r1BE6s0t1;aE80e60D;i4o4E1Dr8FFu464Dy19;eBEoC7;n3E57r3E3Ft28vAC7;!o20;a578e1o46;!e4f33Ai86o29s0;a4054d35E9e3A0Ci436BnFEAp8u4DC5w28y1;e1E3lE3;!a7Fe15i67s0w3CF6y0;c5Ce1k5Dn76Ds1F;e23i21k1l1AAy0;e1u277A;!n22A;!h7B2k4C;eBu3975;i22B3;!i9E7s0tB5y0;!e0f37i61;i4l3A9o29;i488n254p1;o1448;e1Do1;!e4i6l6B7o128s0;!c7s0t6D7;dDDDs1F;e42i71y0;c82x1F;e1n2t3;c11BAh1249k40E3r26D7t37A;c0i25;!a2DF6b2F3Cd9DCe2741f28h77i4C57lDEm44C4o3865p1F0Ds27B7u4E;e4289;!a2A98d214De3CB2i4B96l15Fn328Bo357CrBs0tD72u1464;i25s3;d2FEA;s60Dv38;u380C;n1tB;d0r42B4;!e68i67y0;e23i67y0;!e23i67y0;c0dBn173;l24Bm3s11Au36;h43FC;n2821;!i13l7s0;n2341;dB4F;a6Fo35s2D;!e1761fC2iAB2s0y0;n453A;n448;l45;o1Dt95;!e22Fg42Am2Eo10p14Dr106s140;c2Aw1E;d614;aADiA5Bo93BrE5Au121;e5i470;o9Bt3B23u4E;a29B7f4313i4752n8o1u14;i5B;!a4F23e3D4Ei31ABo12s0uC13;o39At10E;a3C32e15i21y0;t1C0;g64;e194oA6Fu231D;a73i13D4l9C;eB57l4D4rB;m14E8;a0c3C9e217Dh3439iE4Ak3CC0l3948o41Eq30Dy0;a5De1823h1B1i6o1E2;a45EAi17DEr1A;!a24FD;n408;e18i372E;e26l7;r3ABD;!i48A4;!a3796cCF6d37F1hEAn8B9s140;!?0e20Es0;!c2Ao1s0u1;aE4;d3EE2n364p389v1E25;r550;!e15i6n0s0;!a7Fe34ECh4D3Al9C8o2E12r71As0u4F01;r16s0;i62Eo630y62E;!r16s0;c0g5Bs526v6A;!d48l2611m1EBn3C4Cs4AAAt692yDF;b19g7;!e1t6B1w1;e1m32BAp28;!s0t84;l17Cn31ECs103F;!e40s0;!a1De23i6u49;a5DeA20r11D7;a4BE6;!m2Er0s6F2;a8t1;g128l15Cn64rB8Ds83;e79Do12;!d4C66e23i21;!e4i21k28s0;h546i30F3u2C02;!e0h9Ci3A9y0;b1C56e314Di25k4A36oCC6q80Er3E9AsF3;yDEzDE;!d0eDs0;r106t1142;!a3B62e10Dh1651i4AEEl3n22o3CEDs68Au4Ey0;!a694e10F9f3741i2AB3l1323o38BBr4455s0t0u23C3;d0r1t20;a20u19;a1l1197n32;!f183p4C3s0tA97;h71E;!n60;i31o49;!a9D5e2D8h2526l465o744s0;!a65s0;t63E;!e35Ci3Cl7n22;r26A2t1;!a7Fe1B8iACl22s0y0;!a3853e3140gB4Ah1FFi225Cl1F26n2A96o3B7r1E1Fs0y1FBE;s3AD;e1256;!i241FoB3E;eEi0l44o0;eAh3l3;i260l209oDAr434;f4D94t1;!r7Es0;!b18B8eAi21l22p4F30s0;a12i2By0;!l53s0;!rEs0;!s0t5A8y1;lE0s1E;l994n0;e1131i6;!l1Dn3s0;l16m16s35t16;sB87;a4452e4337h117o449Cu17;aAE9tBD;a266C;b10Fe32D7o49;i13y2D;n1B0;i27Au5;!a30h1;c83i2B61l4876n3B89r4346s3B56v46wE4;!a43F3e455Dg4937h317i3C89l35ACr261s0u31A5w172;c4Al147nCF;aDlC;c434CfBFn2s3EEt862;!c13As0;!d0l1n0r2Fs0;i209Cu5;a36t1;c18n0s19z71;b8BcEDr2229sC0;w450;f1t45F5;b7Bd3AfCD;!h0o10s0t1E7;nFp16;l3E4F;!aAF9fC2g2DE6h3CEs0uF97;u4E48;!aDB4e17f38i3283o1BDs0u36;eAi357Du4842y63;!g3750l7s0;d0n205r155;!b35Ap114s0;o40ADs2C;!e15f37iCCs0y0;e384i1EC;n1s3u5;!e5tA82;a65Ci1A;!e4r7s0t3;t4011;eAiFAo40r35;o1D0zD61;!c9Ed48i6s48C3t48;cEe1;t7DD;!a5De1Bh84l7n22s0u1381;iC47;oFD0;e1r15D0t2CB5;!t48B;c1f7n2s3t7z3;m273A;a2B1Ee25D6i36D7l308o2FE2r45FDu36BE;l1E05;e5n173t34AC;!a2B5Be23i6oAF6s0y511;!i498Et4E7Fy0;!d0t2F;o48C0r4DC1;!aC7e18C6fB5i3Cl22s0y0;d0r0t16yB;a0s359;a1e435Di6u1D;!iD9;e43E;e1i12;!t1D77;!a4Ee45FCr43Fs0;i50y0;n3962;l5F9r234;a3585c3427d28A3e4B65g222Fh1i2933kCEFl3399m2711n447Fo1172p2D60r33EFs35A3t4C67u2096v50FEw42ABx2956z3208;fBFo1FEv2ED1;n1C0;o29s1AFu34;!a1Db38Bc130e1584h10Fi31F3l979p4C55s1CBEt55Fw265B;d0g1t152;!hF1o6F;d1g1E;aB6e4;c9EdA08n58t0;eDi13y0;!d0p5s0;c83BnB9s3BAEt5F3;n19s80A;a1e10Co144t1;dBC;e14EiCB;a204C;!a4280c2E95l1FA5mF6Cn8r3F56s17C4t2Du4CDAw0;a3C2oC4;r722t291y0z96E;n446;bD7cBd5Dg5Am89Fs1Ft33FDv38y1z36A0;!d0r58s0t1;l5Cm32A1n1q11Dr1414s2CE7t43AF;e79l52n2;c5EF;l5A2m0r37F0;s71E;cD3t60B;e55;!l4384;a690e1D3Al27D6w0;i2B3E;!eCh350Cm307t1307;c182r2549;a2C8DcF83d2501e510Af1C89g1i4D04l9AFm2348nF0Fs5080t1718;p46;c1s100t3z3;c13En25t1E7;!l1An1s0;!b267s0;u197;!e3i0s0;e8D8u2313;g15Ai25m4D8s1AF;!c1376e2617i1F12o4C24t424F;o2FCC;a27ABb2320d3DF9e21A1i3A5Dk33DBl1m3936n4B6o3099p463Fr25C9s33CFt92u247Av61B;a42e6Ao33D7;e0i18;!e0i18;tB92;a2DFoC6;m183n16A;a2037i88m5CDo4BFr5As2B9t17Fy3CEF;!h5C1s0wEAy0;t8F0;s60D;a5De1BCB;a1o46;s3w1;c1n8;d23A0l84n1A80s0t240C;!a1287d3CB0i16CCo9Br4719s8y3A43;a8s5;i3691;b1Ct2467;a0c5Cf3EB5;aEB;eAt0;b27EAm2571s1F;!i25s0;a4015e126Cr4A14u2909;e8Cn2;!d27i31o1s0u34;i260o1ED;e319h570;dD4eAi6;!a3E32d1A84e11A9i1565l13FCoD5Es0t3F07u4765z1A;eEi27y0;e1nFp1E;e35ChC9i3Cl37D;c1s3z3;a3E77e4687h3933i3BE9o1206u2ADE;a988o46;c27E8d40E1e4A29f3B4Cg2C1El4AF7m4CD9n47CAp353Ar2122s4FC0t2CF4v4534z1189;e4DEg1i19C7;!a250e3E1m7As0;n3A;!d0e676l2E2m2Es0;!lF6n49AAs5137;r36s0;eAi10B2lE6C;i18t1C;r2Fs8;b2E83c40FDd38EEf1087g4D0Ek1l3F16m35B7n401Fp1AAAr4C60s4BC7t3B9Av44w1403;e2D6i79Fo190F;!h9Ci69;a127e17o51;!b264BdC68g5DClDD5nBr5DCs3A70t3F19;c11Ds477Dt2464;!l171As0t392;t790;a2E9Ei1283;d16t761;!b48F1g15As0t56v55Dw657;!m3674u24By0;b435c6C6d29F5g33B8i2B35m4AECnFA7p4FFDs181t28B3x7;eDn2t0;a194Fe2E11h2731i4A49jCB7o1A18r20BDs5020uF32v3B8DwC0Fy4D9Cz421E;i29EAo57;a4De3401i6;n205t2408;aDn0;!a52n3Ds0;o4098;n4B0A;!a0e4i25E4s0tE17;i3Co28A;eEBi2Bk0y64D;h373;g39FCm3105;t222;e249l7n3BCA;l116;e1m64s11;mAD4;!e23i6s0t18C;!e221i1836l7s0y0;eEEn125t3;a1E6;i4o3B7t0;e1w60;!a646e25Ai4922y0;n3F79;a2978b3E8Ec29E1dDE0e3357f2BD2g4F79i2001k4FABl4A55m14CDn4D8BoFCFp4A53r26E1s1D5At4B15u4BB9v23BFwA8y1A0F;a3EE0b1B4BcDE4eCCDh12E4i19E5k2089l4B7Am25Do46Ap47A0q3594s46A7t4331u3F10w499Ey174E;aADEi1Do174B;a4469i13;t1ACD;t287A;!b1d0s0;e1Bn3v27;!aBCt80;!e1236s0;!d0p2735s0;c1n1;!e68iCCm2Ey0;d2FFl28n2949s2CzB;!d0nEs0;!z421A;tByC6;g207p36r321Et10E;c27Bi2EB2l3A;aA2BeBB9;o130;bD4t1E;s24DDt2D;mBn70;!l0t40;e24n2s3D1;e3DBl7o10;a9i13o9;f1v19;r16vB4;!a57eE12i67s0y0;a14FCb26EFc1310d5054e20AFg4EB4i1F06j3BB2k116Fl3667m416Cn12C5o5086pF45r2839s1CC0t4E8Bw42D4y17A2z2C52;a3279eA9Cf30E3r39F2;!e31i20s0;e15DiCCo1D4y0;r766;e1l141;z2718;a7FeE1Di21y0;s69Au264;a8nE;!d0n1o9r1s0;a46BEe297Di449Eo1A58u45E1;k16s4C;s3EEt7;r3BB;eAt25E;c0n115;c0nB;h38D2;n2EB9s27F;r3BF;e383A;eAi33Do39Au5;!a40h27i13s0;!e27;!d0n16s0;d20A8;e12l47;e8t1;!i4FDEl18Fs4FF4y1007;!b2D4e12m9D1p15B5s0;!s3E;h95o3A3;n1o9p1t1w1;!a20e4iBC9s0;d7ED;!u11A4;y2A8;m149sC0t2D;c35F6d1Am1Ar58t584x1F;eAh0t1;o1u6B4;!e4i43l119o9Bs0;g5Fk4C;a30d47n5038r6F5s2D53;e1s0;l282;!d459g94s0;e5s0;e9i13y0;b288BcE13d3769e39Dg31DDh2868l3945m148Cn49E1p3167s2C2Bt4B01;e24nF;iFDo95;aD7;n1C4;eCE4l2CA4n173;l4A08;h1n1FD3;!l7r1s8;!i10ADlA69m4B1Dp1E0Ar4282s3EtBvBzB7;!e26i18s0;l59Ao28;n3o36;c92f1n2s0;e15iACy0;!a1eAi6s0;a4c2At0;!eC1f151i21l7n22s725t201E;iFD;e3D04i27A3y0;!n64r158s1750uBE;!i15Es0;a1B3;a49C1;!a35Be2CFiD67o50FFs0;g0t1E;!e3E5i1045l44o1F23s0y0;i4n2Do10u5;e68qC3;i2Bl2Cy0;n4DA;!a75i1u14;g3Bn4;eAg485Ci6;a1D08e2B41h1D6C;!a4De4B4iC33s0y0;n3Ar0s8yB;!c1882e1028h1327i16C1kBr371Cs0t4366;!a147e4i3076m64r4E6As0u697;f89;eAi3D;uA8F;h0k38;e1iB1A;a30n82;n0y0;aE1o9;a9o9;!a28Ae15i17As0;d47sE;!l1s0t88w1;g25;d19D;l2F89n2;n16r0s8y1;e1m0t1;l192nD0Dr338C;!e4h2AD4i6lAA2s0;a571cB1e68l3F93nA7D;!o30s0;!i5t27;c2An2;h1ClB;m1p1Cr7;a2B5c13Eo2133p338r588s8v748;!b386c31B0d1474e1g1CEFi1AF9k2AC2mB14n3E14o46r2249u34v4CECy3D4C;c13Be1764j2269n58o10t2784;e5n213;!m2Ew7E;a2648r18u34;a51e17y0;a1d1i2By0;a163;m1oD;!a1i0s0u5;n1t25E2;t4774;n29DC;o883;!oF6s0;a389e3F27h1ABi34DDo3BFFr24B3y5C7;!b1Cn26Ds0t50E7;l2BrDA;d0g1;c1E8k44DEm2790;t467F;h1C2o72;!a61o108v1D6;a1ACAb4EC1eC5Ai219Em780n4523o39BFp31CFu2E6y0;f83r303;a0iB8;c5Fe5;!n1At3D;c0n0t3;!b2A0e15i596l7Es0w1C3y0;g4746mEBAnF12p31Cs3297t4A1Fz41B3;e1EE7i6u996;!i20r188s0;g55n84s3601;z22A;c4F7CsC5;g15Ar1C79;r19A8t39;!e113iA28s0;a40u34;i18u3y0;!a246bA9c2F9eB7Ci20lBE7s0uB36;eAiDDo12r1A9;!e3921i43l2BAs0;d3w9;d0e12r625t39;a1C1;a94B;a461Ei2EBo162Fs0y1234;h3C7q14F7t0;e12Er22;!o4051s0;r60tB;a0e23i2BEy0;e41BF;c296l62;sABF;e804t1E1u1F5D;!b358e9i91s0y0;!e509iACy0;r1539;uCy0;e2927o3081;c0o582s102u34;a6DDeAi49A7t5A;!a174eAiCCl7m91n22o265y0;!a4Bi154s0y0;aB59d0;i5F6;!e1h78i30BEl76r22s0u31B5y457;h66o66;e1h2C;a718i2By0;r0s843;o1CA1;!e5g1s0;e94Dh9B1o136;r4t3;c1DF7d860gDA3h200iEC2k1AE7l3D94m3EA0n13A1p3C6Bq362Br33F9s3C60t3660u509AvC3Cw98;n106;c0g105l3;!a3834;m35CA;r97A;i13y274;uDFB;!p4656s0;sC0u5;!eC1i39CAl7n22s0wA8y335F;!i5FEs0y0;!e15f37i6l2289s0;!e24i21u1;!c226r1CBs0;e17o41E0;i77o9;aE39b8AEc2E2Ed283Df108g4ACAi4810kBm43BCn4957o2483p31CqC3s233Bt12AEu2823v2FCEw26CCy3C54z3;v3CD7;g1t19;e3703;a3Ce68iCBy0;m1D2F;u50D2;!a43C4e4i585s0;!a4De2869i6r4431sC1B;e23i21k89t1AA;g404;bBd1f3FBg339lE7o42BFt2456u4132wD3Fy1C;a30t316;b4511c48C7d4591e3949f32C7g149Ah1D14i3C8Ak47DAl34D2m386An14FAp4DC8r44F2sFD4t4889u2431v2BB8w13C8y1BBDz46CD;c32k1n1;!i10Al7t7;a0c0s3u14z3;d44n3D0Cp296s218;c435Cd8BEl3E9EnE21s2A33;o8B3;aD9c160n2;!e6EiBy0;e6EiBy0;l58rBFF;!a40DCc1AdCD2f7g0n1Ao300Er3s0t1A47w0;!o2;a135o1798;a97e12;a75s2C6u34;n2FEB;a3F84e856o2B9DrA86u488C;i623;l411n411Br1;!a4Be10Di4526s0y0;!eDBh9Ck46t95;n2386r288Cx5D0yBD4;sB2y0;eAi7FCy0;e0h1ACFt46D4;!hE3;e3DDi151Bl2Cy0;l15BCn430s9E;c43B3g348l1D80o2988p43FDt509Fu13F4;m8Br22C;h1B1iEFlEFt425FyEFz9F;!n297s0;!a230s0;d297;!e0i2E69m165o15Cs0w98y0;e0f1C98vB;l155C;aF39i3A60;a292Bi1A;n2BA;!e15Di6l6F7s0;!g435Eu34;e12r210;e6Cf1i13y0;!d0n4A1s0;e40DB;e30t16;!nD8s0;c32i25;e12Ef2Dr1BA1wBy1;o8BCu3FA8;a238c0;!l1s0t88;e2D9;m1ACu4E;!a7F;eEi272l6B;!a4682c3374h2F80l97FmD78rBBAs90Et4324wEA;!e15i6l9D2s0;a20e6B;aCb7Be23i29B;y13F;k6A7;!a4BeD0f37i6s0y0;!a7Fc121e15i21s0;e17Ei6;a12b1B04m7ECp15A3;a14e178Di9ECo420;e3C21i6;!d0r1s0t88;!d217e15Cs0;a1DF9e2A89i18A7k8Br10CDy0;a2F6E;c18Ct1;!d0r1s0u969y0;!e24i43lF4y0;l47n2t3D;e2E80l5F9m64;e35B2i21lABB;r3EA1;c1A3F;eAoF9;!a3388e15i3C2Co2DF7s0;u25y252;e12g0;e467i67y0;e870;!a11Ae8Do46u14;!d0s52;o454;!r411;!a31e10s0;d1En1E;!d1401e754i9B0s0;c1CDA;c92n52;!t133;m198s19;!d55s0;d1k1ECCp28t4A;l2D81n1;i1CDB;a2622b5BDc2A53d3178eE06f504Bh633iB0k32A2l9EEm12C2n40E0p1E86s1267t1v2A4Dw27D2y1;i649;l4C0;i1D2p5Bu2353;!b3CE9d5C6f8A6g15Al1AFFn3A25s1722;e12l1n2;e12r4309;!r1607s0u12;h5D;a575i0t16u5;a1E80b14A8e4CAEi2588o43ECp4862;aCh89t3371;!a69c6Ae15i28C7m2Es0y0;m52t7D;a225fBFt2040;d521r1;c1At13BA;n2s3t7z3;e5BC;t1B1C;b1Cc2C;!d0s0y16;g1r149;b897c2Ch1i4m7t2Cu192y28;a389Ae10E2i383y0;!aCk7s0;!fF2l9Do9D;!eCl7n22;i3D1E;m3BB6;a88i715o278C;!d0i6m2Er1s0w41C;!a20e17i4735s0y0;!eDl7n2s0;!a4Be329iACo12r7s0y0;n27D5;!e1l1C4s0;!e24i21s7A;!a2C5Ae15i136BsEC;d2Cs2D5t2D30;aCo1;a1oC;d58l262;!l3B3n23C1r0s0w172y0;d2Bl55s1F;a7Fe2271i6;!a2Ad7B3e2AhEAm2Ep385Br2303s0t25CEx1F;dBn87;a4FA;!e12f37i91s0y0;!a176eAi21o12r22s0;!i3EE8s0;a0c2F8e1h40C2i31k1m1AsBB1t2B8D;b1d70Bl18y1A;i852;a3DC7hC86i0k251Co49F5u2904;e166l7n2;eC1l7n2;!e4B8s0;!l3765s0;!bF8e68f37i21;!a159Bb3C55cDFo28F8s2720t357wF38;b2BD9c2F9d2236l2F2Fn1r1;a23CAc3EDCe13A3h40BCk1F6BoC2Cr34A7t1960u1D53;d0n1r2F;o15DDu410;!d0i6n4E5s0;p45;!a313Be12D4h49C9i3412l2BC7o44B0r3AEAs0;b16e406Ei6F0s2CBCt16y0;a3C24e2453i4203o4AF6u382By115;s11t58;i46;!gA9h14Ds0;a1C7Cc506Fd1157e4EEBg4C33h4479i2F15l337FnF0Dr3EC1s2AC0t464Ax473F;n15BA;i6o93;rD7;!e15i6o64Es0;a1BE3b1E51d22CFe1C40h4F67i468Fj4695l43B0n35B9o3582r2B5Fs2D69u3FB6v81Ay164F;!a4Be68i43y0;!t10F;f7nFs19A;c0e1Bn2s11;u2C5;i3Cl7;!l269Fs0;a0o313Fu416;r614;sA1F;c122e5;!d196i1kA3At0;h453C;e12hEi69Cm1EBu4D1F;eDt1;e1i12Cy0;aFBo1u2FA4;a32A0bE38c3570d1DDBeF5Bf115g2C46i2422l2F19m13C9n3287o44E4p33C7r34F0s1E5Et3B40y16A;a1339b36F8c3B41d4F82e1E27fB2Bg288Dh1i3DC4j3Bl31F1m10CAn2F4Ao3DA4p1CC6r14D1s496Ct495Cu360Bv2BD5w423Fx1B2Ay39B8z3652;m6B0s5E;!a29Ae4ED8i189y0;s22At0;r710;e0o1290;e30Ei58D;!f1F1n2F55s0;!a97o138s0;!a4167b368Cc492i28Fl708o3F4Ds85Dw45F9;a1BD2b1ACcD1Ad321Fe3E7Ag4ADAi1526l487Bm4D21n2E08o69Fp2190r3841s38C3t49BEu4DF5v3wFD7z11FE;c4Cs5Et2D;!e17i57Br7s0;o417D;!d66Ce0g4D1Bk442An7Es344F;!b380Ed0l18E8m4C0An4EBEr0s3E;a4E0Ce1C70i86;e50E9;p217;a4Ce12;a29Ai39E3o31u8C;!d0g112Br7s0y1;a1EEe1i0o0u5;n371;!e1E49iBAs0y0;l0t150;t878;h3C27;i230o1;a2DC7e1i2FF5r1A;l3B27r84;e340;!e4h14Di38C2s0y0;n152;s3u14z3;!cA90kDEl97Fr28s0t1DE;!o368Fs0;eDl7n213;e4i6lF4;a468eAi46F2t1EDA;d441;!o231p4BF0s6E6;d0n16r0s8;a3CB7e5D8;!v27;!b404Ee329i259l219s0w1C3;a1e15i21;!e1s0t28;c39E4fBFs2C6;t3C9A;e34x1F;l3t2A6B;g2D51m48Ep2499w0x122y5;o6Dy0;e9BE;f7n2o9;!aCh260Ai154l22s0u4Ey0;!a4DdA8e14Ei21m1EBn23C4o4037s28CF;!a4Be15i6s0y0;b1Co25Cr1;!dFCgF77s0;r1t0;h8C5;!e1Bf37i3Cl7;b178d1B1l62m64r3119t178;d1l24C;!a105;a105;!o1174u11E;n1B5t7D;c0t7;m34DE;!d8Ae1B8i86l7s0;!a658o1;e4iBAy0;e17o27D;r4F1D;a246o1E21;l19EC;i13y1;d64g128l11AnD3r30Bt44;e4177i21y0;c32t1w80;!gBn8s0;a162i211C;r441;aCFr4A;b76d1e33B2i4D50l15Fp1Ar4B0Bw82A;u1E9B;gBl3A;t737;n65r19t19;a4A7Ae23i213Bl452;d1A57;rDCA;!e68i43m2Ey0;hF6i412k1C;i1C1C;!a589e23h28FFi3F5Dl64Ap3E92s0t140D;e517i6t13F;l118o45;b286CcD1g624lB41m8Bp1r2A08v16Fx324;!c92s0;!e42i2BlBs0y0;!i4995o23E0s0;n89E;l83;!c1n294o5Cs0;!e1Bi3Cl7n22s4724;!cB2s0t44FFw25D;c19CFo1qC3;aCe5iC;a1cD3gB28l2E45n4099p38s4400;dBC4h317l290DnEB9q711r2E7EvC8;l5t7;!i1At0;r4258;c32n90;a2F56n65t1;cEd0;c92qC3;g1762;a2ADi2By0;d1l4p743;!i1952s0;i24Bl4184n603p455Er2999;c32rB;!l1Eo29s0u31;n53o9;e50ABi6;g181l217;i332o2E0;e1Bg94l7;e7i1D2;!b484De1Bh2470i3Cl7n4B6s0;a1D9Fb3581c50FAd134Ae2132g1DEDi510Fl3DFFm4C1Cn3E94o1F10r1C8Es182Et1602u1AD3v13F5w1D0Fy549z469F;aDi31;bA0;oA6u73;a1380;!aAF0b45CCc56d355Ae4f4064i21l148Am2CE4n381Ap1C3Ar18Fs0t212Dw20BB;!e1n2s0;!e5n2s0;!e24iFF2;d0rADBt1y19;aAC1;!e15i6p3AA2s0;e4m1;a82F;a1Di1D;r37F2t19;!a7Fb130e15fC2i21l22s0;a0d208u14;!c11e0l0r7s0t3;n40D7s67C;e69Bl321o16A;b22CEc4E05f4AE3g2DCEhD32k2441l2CCm42B7n1239o2E49pC8Er3DD8s10EDt39BDu1A93w2794;u2A8;i1Ds0;e1s0t1x66;r8D5;a2398c158e6Er64;a25EF;lA8o23B;!c58d894e0t3CA5;a1B0Be466Ay0;gBn25;!a93e4B4Bi69l46p4CtF1;n44B1p40D1;i26;e249;!e249;a1B3i4221oADu1B3;a31o31;eAp0;a503;c1A2;e4i17E2y0;!c1C4BiCo10s0tBDx0;a6Ce35i35;a16Bo54;!l7uC7;o120t1;!e5i27y0;e1i196y0;c32z187;e5CFi46F8o1rB56y0;!a12d1949s0;!i6l22;n3C0D;!i69t27;a132i1DF4;!a1A95b228Fc2EC1d407Ae2F4Ef4B13g1726h1247j38BAk2312l2C73m16EBn2F14o3E69pC60q1AB5r4C75s391Et3154u4079w3787y800;e38E9;l1mFFFv44;a25e4DE2h4F47k1B59o1F45t1B54;a33F5e1959h44F1iBC0u163;b89l4DE1;b184c374Al308Cm25CBr4A4tB7AuDA9;a4B78b1864c3156d4974e27C7g498Bj1736k44l137Em2620n4CDFp2C19r3D74s12FAt3ADDv375Ey1AzFD;!d0i472s99F;c3606d226Fl34D8n15B1t162E;a36oDB;e24i6;eCo4EC;h7D8;a4859e1018i1ED8o4A6Au3E3B;a4BFe89i1D;x324;!f37i3D0Al22s0y0;xB;!i88o2FEEs0;a4014oA0r25D9;d80;e30i365oD;!e4E7Ai1BBr146Fs0;h6As19t19;a2244r95uB;!i13o39As0;!i43y0;eA3v3;i154l44y0;e3C9B;!e0l0t19;a157m2Cr1B62;aEn3;f6BBl1An501s1F;i7Co29;!c1F96l3B2m1B73nE0p3F9t2AEDw5CB;k1BCF;!bD4e15C;i429Co74;z3CF;i2BoF6u5y0;!g2A64l7n22s0;e47A5t3FC;i888o5AF;a4084e50A6i553o1A7Cu2519;!eB3i27l7y0;a4C1e8F;b1Cp1;!c3De4n333;!hEAi705lD26;e3A68n603;e784;f2F;lCn80F;gBl3Ar3AtB7;!e5133i86l2Cs0y0;!e10DiACl2BAs0;a4556e6DiCBo2D6u3Cy0;!l1n25s0;e1766;!e1BnFs0;a660;a30eFFi6l1CA;e142Fi647;!a3BC5d0f37l6Bm2En1r1s0;e1504;i123o3F9;!a4Bi96r7s0;r65t3FB2;!c53e1;r236B;b4B89c2ACEd24Cf18DDg41m1Ap2F41sB41v27x0;d1FCAn4w80;!d0e146s0;p131uB6;!s0tF4y0;e15i43o54y0;!a38FdB5e15g62i6m2Es0;e15Di199o12y0;a2471e277Ci4279o4816u2B88y1D04;d188n1r16t1;i2Bo1F0y0;a1C2Ce3C39i2ACDr1BCC;n2sAE2;l9C;!l9C;a20iEF7oE8u5;s7t2D;a21FBe3785iFA0o3989p6CAuCA5y114D;o108E;!d44Cg3BnA9s0;!b106mE6p2A61z1A;eB3l7nFt1;n18r1;!e3D78h109Ei3917m13A5s1E57t1C2Dy0;eEEf7l7;n6B1;a2EF6;i332;g1o3367;!e5l1o36s0;!e142i289s0y0;b4625e1E78i121Eo423;!e4i6s66;g5Bi25;e264o95;i495E;!a147c1FAe0h1C1Ao3CB9s78tE1Bz7;!e87i23EFoF6s0;c1r2Ct3C4;!e221i250Bl7s0y0;a10e15E3r4E6;a3193i359AlBo132u393;t198F;e1377;l1A4D;a0h30DFr4106;!c23E9d342FgD4k1lBn177s669t522;b75Ec3E3d212Fe3E13f3A5Eg2A5CkBl4CC1m1924n1B33oEp49FCs4C81tCB8v76z3C78;!lA1Bm55s0t1;!e12s0y0;u401E;d20B;a11C;!i1ECl22m2Es50AAw847;b8F9;a2C2;!f530l10Fp5AAs9E9;!a12e2A11i6n251As0;a3716x5E;n0r6CBt190D;!a20e31s0;!a322d4355e22Ei332Cl34A4r3D2s0y4109;a587c13Ae1g1AAi477k48t1;c1273f3BB3g3D16sB2t1A85v2C;d49Cn2;e4691i6;e468Ei6;eDCu9D;!i4253p3F98;a1EEe1i9o29;!e24i411Co12u3678;!a2557c4D66e8Do2A93s0t5C;b1Ae1C6;cBl12Ar15E0;e4AA6;e20Di6;aD4Db478Be3132f5007i16ABm3072o287Dp1E68r751s8BBu4E;h4515o1;a4Ae4i21;c1471d2880e108BgD1Bi9t4314y35;t3A9;a4Ae3CA7o30r322Ds0u1;!b1A0c1D3e518fE2i86l9D8oD8s0tF1;i2A7C;a1e33o1;c2Cf240n2o1FEt12A;aCc0f7o9s100z3;eE4i745m39C7n114Cp1FE7;!a20;f16n3BF;!e24i402o0y0;h5097o10;e5Bh60;!b280s0;m33Fs29z1DFA;!b42Be4i6pA5s0;a7C5;e2C41;!e0l1r25tB7;a15E2b17B6e314Ai40ECl1Am1499nC8Do3A84p36B5r2577t196Du1215y248F;a12hAEi0s12A;o3F78;m786t504A;a229Ce30i7D9o51;!a1e4h1Ai6s0;!a7D0e4578i49B6l76s0y1EF;e4808o12t4CA7z89;!d0e1h1D5r1F5s0;e1t62;i4r46t16u20;!e8g0s0;!a10e141Bi6m3D31n1BF7o24CFp4946u2423;r7y16;a17e9E3i3F4;!d0fC2l22r1s0;!e14AA;aDu5;!g227s0;!d0f37l4538r90s0;!e580l7m91n22p2A44;!k3911mC8n1854s0;e16CA;b1Ag62m87r8;e393Dy104;!b4699e255iB0FoEs0;!r114s0;h3EBl12B4o22B;s2FCt3501y28;a72e1Do68D;a20e1E44y0;a3202e17iCFu50;e23n2;cEe10g4CF3t1;!o14s2DD;d0t70;a1cB2l2CAB;!c1D3;a30FF;!a2914c1C66e17E0iDBCk0l4108oB8pB88s0t1016u4C31v4F74;a11i1690;!e2965i6l7s0y0;a4318c16CBeD9Di31DAo10t31A2uF13;a1023e22DEi25FBl4CCAm4CA;hCEAo1;iAFlCr3;n4252;a926eABD;!a1F4Fd11DAe0g4DEDi4CE7l3D20m2A79n22;e1CCiAA5o17A1y50C8;d7k4Cw1;d64p130;e8Fl3;a3DB2e1F1Ei101Fl7Eo46t608y0;!s21DF;cBC3e1n2t3D;a73u3C;!e15h1i6s0;!b7CAd3E84g2E2l24D5m629n8r3FDs496Bt4EB7;r50;o48D;e441Bo17uB8;l28r1B7t1AA;n4655r1t229E;!e4s0u5y0;!i6F6o29s0;d1C4;!gA4l4074p569s1E58x1EA1;e1Ao302;i108;o4EFA;aDAe399o1;!l1s0t1;e17uCF;!b3780n1E2s0;r6DB;!eAB;r1v62;!a4631g18D2h3745i22D3l733o25EBs0;c15Fd1614g3E5Al3A79n249Ds105Bt1A50z89;l8B;l136Dr4y5;l3295o11E;e1n1;!lCAs0;!b180e4i6sEC;l1Em1E;c160e5nFs27Bz19;n1o10p39w1;!l1r7As0;e8B;s306;l12F;!e17Ei2A4o10s0y0;!d0f37l22m2En48r1FC6s0;c4E60;!c1D00f8l3D2m410Fn9AAs209At2697x122;e1i288;!e4i6r1As0u10;!m19DsBDt564y1E4D;n4BE;!e3BD3h1C82i2371l29Fq42E6s0t19A2wC8y2C91;c3203e3C4B;!d8Ai1DBs0;c11h7;e156Ao4F3Dp56;k39t0;!d24E7g3066i21k2E5n7As0t28;e26EiE9F;!a231Fb2CBAc3FDFd16ECe2546f356Cg338FhE2Ei6j3228k15D9l2383m1FB1n4B0Fp3467r4403s2B92t31B2u126v444Ew2C36y25D;a20i9AB;a429De0i2DE;lA7t1;a266e15i6;i16l11Ay28;a3331e15Di48C8;i419A;d0r2Fy1;i15Eo29t41;e388A;i2Bo42y0;a206Bc24C7d0e2A0Ci13ACk2EB1l360En44F4o4ErF67tAF1w2C7;!eF9Ei6wB;!a482l4F88m5A9z268D;!d0n2321r1s0;b4AC;!e26l7s0y0;a85Be23i2A4;e607i21;n52CpA11r15BEt1EF4;i73o167;!e509i67y0;!a48D4d3241e746i4048l818o422r3D51s0u2A06;t20B;k1At2D;g25FoE7r3uE7;!e1BEt2701;!a2EADe5s0;!pDFr396s0;c24B6mB9x1F;a9B2p217;r31;e179;e339Fi2056o3CF9rA1y0;e33i6o1F;i6CF;!a4059b7dD3i9n22oE11s58t89Au2B67w307;g1wAB;r39E9u59;r4171t16B;!b519s0;e399E;i367m2Cn3CBsC0;s14t3;!h2C4i168o3FA1t32DA;!b58Ce90Dg37F9h250Cl8B8m496EpA4s34D1t357w4118;!e1FBi21s0;e3CF2;i4A2D;l393n1At3B;!iA28;m3t3;d0e4lC;!s0t987y0;a42h152Fi36;f7o9t7;!i3Dn3Ds0;b675i45A;!e0l35B5;b1Cl147n34Cr1t19;!a1B82e1410i2F5l177m1C2r89s0u50D;k3A8E;!aFCAe4i6s0;t2Dx55;!b1A0;i1Dw10;eAi41;eAi306;l48y0;e10Ci69;a36e201pCEt3Dw0;t7AD;u115D;hF8i2159l662;c1n2s9A;rBs4E7;d5AnDFs1534t0wC07;!i224l3A77m278s3221t612wA8y0;!s0w0;a47C5d0i2CDl400r8CDs5A4t274Ey2D58;o2116;!c6Af5Fs0t1;!a76Ae15i86s0y0;cBeAs6DE;k2B6;b3BCl9A0m259En1737p44DCt4501;n268;c4D40e3A45i46DFl46DAm1161o2580p1DF0t44E7vBB5;e1E3o9B;a2753c0d3s14u14;e1Di31;f2B52;!a50EAe14Ei21n22s0;c32n0t4A;!e5i43y0;!a4E9Ec49FDe4A47fE5DgAC5h173EiF7Al1222o97r24BDs0t420Cu20BAw37By0z195C;!i238o1201s0u5;!e15DiACs0y0;!e5Ai0sBu4E;o823;g10;i1Do1A;!p2CEAs0t38;e1s7E;g0o1;c32r3w16;!i54As0y2E09;a53eAi6;eAm1t1;!a1D1d0f37s0t16;e23i6oEF;a399m0;y76;l55x1F;e1D60o337D;d0s0t27u5B1;!g31F2h3DEk5005n2345s467A;a1A81;l3At3278;!a82Bb504e146m1B56n22BEp21Cs36Dt36Du2CDv3w136C;a2e12l19;e3C1Bi2FB1;a2B8Bc1CBDe9E1n1AoBA5t62u532;!l413s0;!e4i27y0;e85i27y0;!a50A1o12ABs0;d0r0s1B5;!a2ED5b278d273e31FFfB5i6m2EpE3sB17;!e4g1s0;e1o8CA;a15C9d549i13o39A;!d8Am2Er0s0;yA87;a3107e1B8;d0l147r1;rE0;l1358r57;a3A1FoA6;l4104;a0c0n2p4As3t3u14;e2CB;a1BFi57;!g281p68B;l3338;!s0u1CE4;hAEt693;t781;a4518e16D;o427vB;e18i4;g4CF8n2FCFt2A71;fD4;k19tED;g1D7l0;a96e3B0i6Fo45A;!d0l60s0;a4537e232Ci2CEFl21Em23DDn4FAAo589r3104t178u3ECv504D;m1CF2;e5n2s11t3;eBg62n5E;m8B;a110C;iA30;!e0l1r7s0t3;eB4Fl4D5m7A4s49BAz4087;i2Bl5107y0;!a4Be4iACs0;s8v18;!e15i6l19s0;!i9F7l7;!k370s0;!a4C34e1330i466Fo4786p3A2Br4FE7s0u48A1y2770;!t10B;e6Ai51Co69y0;d0e4t0;gD2;!gD2;e4A4Ch24Dt281F;l2742n20A2;a270Ae1D49i4E5Fr3B6s3B08u6F9;!eAg4C82i6m2EsCD0;b6ACe1089m2F8p24E5u4E;a9e5o3747t5E;aDe3o362Eu4342w8B;i10Ay0;a1EF;r2B45;a1De26Ai6o12;!b151eD0iA77s0y0;!e23i6o128;k3n2t0;!a20b435e19E1f2ABFg89i2987k31F7m174Cn4E02o4163rA80s39AAt348Ev122x295F;e8Fi8F;a2B78i1F97u2034;a1C16e6D;aA2e23i6;!a1e1i13s0;l4038;!e4i6r261s23F;!e166fF2l7n22s0;t1w10;c0o7B9t5E;r297;!a323i31k1o1s0;!c77eEh3B13i221C;i42A4y0;a100Be3C47h2072k44Bo1s3F81t2F53;!a1FAAe2668o1317;!eBFEi6;u88v5B4;!a10eC1i6l24Fn22s0w2D0;i258E;!a2C62e2B0i4F8p318s0y0;e222Bi6;eAi43C2o1;e40i1DBo9B;!aD6Bc3F31d953e37EBf1k18FCl2135m29D6n45E9qB37r102Ds12E9tBE8vE30w18C5z0;o3EC3;r2BB;r2F92;a3Ce15Bi3A22;d0r1s638;!i705s0y0;!b1E8e14Ef37i21s0;!e1FBi6s0;l2085;r6Bt90;a34BeFD;aCn3u14;b7Bn490;e36o420;b1Ct163;a20CFlBu9D;e3F;!e1p3C75s0;a1869tBu34;f28El56;!e687fE2i775l2BAs0t11y0;!e1Bi3Fl7n22;!e15iFAo12s0;!b44FmA9oA01p1BE0s0;!a480eAi6tF8u5;rAB3;!a20i5E9o29s0;a5E6;rD6uC;e42u49;c9E6d1g1n2u83;iF75;o52E;!l15D3s24Cu5;e4FF;c9Ei4D6D;e2BF8i3Co1;r109;!l3051;a18;e210ByC4;l170Eo186Dv2CwE7;e235i21;p2C1;!e3E5i6s0t28;c2Af123;a7Fe4i1B35y0;!a7Ce1g5Fn42E9o46t5E;e1916i1933l99An22F4o2C47v3;e4i3Dl1Em1E;r2A3Ct179;rA3E;f107;a1i0k0u4E;eA3Ei71o1y63;eFBk28;c122Bl8r4C61s83;c4A5Ap1F70;l1BF9n1;o5D8;e1i88;d0t4AC;!e0l0r111CtB;n5r16y1;a0l2C;c3013dBeAEDp26A0r1EA5t1Ax1AD7;t2484;i15C;!e1Bm76n22t371B;!d0i10n2DC0s0;h29iC;t297;o15A;!a15ABl737s0;d111n3189;a53Bo1FB6u4071;s0t179;!c2Cd87eC1i17Al7n22o72p3592s0;b16c4Ct39;e379DiB9p48y0;!d0n26Br1s0;a3649e1870f2A3Eh3727i33A7l3866n19A6o17C9r13CCs4F3At4D77uE71y4C20zA24;!b1EeAi6k16r1Es0;!a1A6e3B7Ai4B72o12s0u3;o463u93w1;b1Ee4l16s19;e5DAi6;e12l44;!a93e2166o6F;!g3i9r0s0;c83n2o1t1B9;a451Fb2CF8i373Dm187Bp3D07s4489;!e1BF8iCBs0y0;nFu556;r303;o48ABu5;l3D43n1EE0p21Cs13AvBw41B5;u1AC2;c0n2s9A;c44gBr2A9;a3D46o0;v8C4;a3FF0b0i38l8Bs44t190E;oCu0;h158;!a2507d3532i3Cs0;!o935;!b450z117;a24Bb7BcD3d3ABFl1m91ArD60;a524e2BD8i303o6E;!b7;!c1F4d0h14Di6l48p10Cs0;!a12e15i6l22s0y0;!bE0e4i43s0y0;!e9i3Cl6DCn3D6o15Cs0;a4D0De2110i1E89o13A0u3326w195y365B;a1i5F;!u34;u5C9;a4C44i24AEu3C87;lFBCr25;e4i289y0;a3CE8e8Fu4536;l3346n53Br7s42Ex1E;!d0n1665r1s0;!l7n8;a20d0s0;!b133Ee4h2E4i6l2654n4383p2728s4BBw89C;c84l1A;a2B56eAi27BE;!eEEn3;m32E4;!c36ADfEA6hB4Dl200n0p48r1925s2609t21FAv2B;a17E8b2F7Bc4558d3E8Ce1i6E2k1l13D7mE77n1F8CoD4Ep49BBr486Fs4FF7t3FC0u2542;e42D9;d0r1625;l3877;a338c2A82d3FAf8i1CFl16AFn169r145u2E48w9;!c266DsB2Dt675z3E20;a105Db9Fc4105dB45e3262g482Ei3256k82n23E5o1DD0sF44tB6Eu2A77x1Fy1F79;e2A92;!a42d4621i2Bs0y0;f87Al1r678;!i28Do366;e50o1DD7;a543;r559;l0r0t3;b1c247l432Em801t2494u140C;eB0F;i2BD3;u4C9;!e1C1i2DAC;!y31;l7E;n133;i1930;!e10Di21l16En22s0;!a0c36B4d0i6l22r27Cs0t523y0;!b25Dd443Fg89s0w37B;l7Et1;o48B7r11DFu4C7;!n3s3z3;n3s3z3;l3n2;e99o138;!c1d0r1s0;!eEl19s0y0;g3677k6A7t38;e155i1;!d8Ar7s0;!b386c55Fe24AFfC2h3CEi13A7m2Eo417Bp1A46r2E7Fs0u4692;r24D9;!a4AEDe4h488Bi21k755o0s0t36CFu36FE;sC0tD2;b5Cg3;!l1n1r7s0;!d212e4i21o9s0;h4524p3B61;!a7Fs23F;!a135e1h0i4A30o293s0t39EDu4E;e4990o74;eE2Fi3BF3;!a2574;o6Fs0t2D;e6Ei16A;e8Fn2t23A;k1F8tE47;u1D38;cA75;!e12l119r7s0;a2DD3c2212d10B9e4FE6fAE1g3BF0i6o1741rF02t4B2C;!l55;!eB5Ff37i269Am2Ey0;n2781;sD3;e8i4;c0n2sE;d0r2Fs0yB;nEDErEs1D6;!e148i86s0;u2744;y2CB;aCeAoD;a1e1k21C1l4E6B;h5027;!i27s0;oB83;aCn2s14Bu14z3;!e4i6l19s0y0;a1fBFl3A0D;l42BEr303B;g32Bl4975r4EFFs146Ct3D42;r13BC;eE32h38FFi34F1o2E75;!k7As0y1C38;a7D9;!h19Cr26F;t3D56;h783;s48CDz3;a3074i22D0;a698c124e1l34AnFt4C74;lE4;a3856;l1C5C;a3FBFe3378h281i178Co11Er1BA2u4365y5C;a88i15E9o8A5y22B;e0m1Ao1F83;i4E5Co12;!i3172o1A96tC58;eEEl7n2t7;aCi15Em0o29;!a4E5Ee804l8Bo126p2DC9s0u1A6;e4434i16Do372;k1n2s20;!eAh313i6;e9iBo72;f1nF;gC9;n1817;!g47;k16l0t1;!e1E62i3BC9o45C5p265t22CBu251B;a2284;a20i7C;!l121tF8;l1r1t1;aA88f7m27t485;d19r47;a1iCA;a225e5F;r4v18;s8C5t1;h47AB;t21CC;i154yEC;e6Er19;a13b5FD;b7Bn5F7;e4273iBAy0;!r2E98s0;s174t20C5;e4t1E;!a19AAe23i3F46o1s0;!k28n2B28r2A8Bt98F;c22CAd4BE0fB11l16B3n3EB2r1179sBCt98Fv2C;b5;l4r14;eE99iAC;i13u28C;a1019e44FEh3C03i44A2oCAFr15E8u33F7w56A;!a2D8Ee4CBAi3FADn8DEs0u30E0;eDn1;e1E3o22DuE;n1B5t1;m352s0;!h335Ap11Bu49y0;s218;m1C9;tCD;e8CiBy0;!b2962e15i21kB1m5Fr261s0;!a75s0;aCs0;!e15h14DiBAs0y0;!a29Ae1DFi12EAo7F7u1DB3;!a225s0;a81;a323e1;a4C9s0;l49FF;a1D4c492Af334Dr1D1A;a176rB1;a42i65;c283g283s28CD;a14B1e4EF7h21EAi508Fy0;dBn0;i682;!l48A7q858s0;!a1FAEc4604h2922k7As0u3FC8;e463Ch273k659m29o1E93t16FDu35FF;gBr31;i207E;!l2C30s0t519;d5Ce16Dg1DCFo4940;s3D55;a658;!d0p1Er1t1;g3l251r7;aE2i4532y0;nF4;a4047d1379e1BFFiBAl1085p4551y0;e1i96l7;!aDi13s0;l147w1;a361CcB97e377Ei5009s349Ft34A8;!a2757b18F4eABi3655m7Ao4DA6s0;r369F;a3e0;i4lA7r16F;a2919b4912c31CCd18B9e1196g14A2i470Bk1l1A9Dm1o3B19r2891sB38t4B95y1513;e25l1;!gBl0t3;a1A31t88;aC7De0i17o23C0;eB76iCCs0y0;e3C13fEkBl6C9m39EBnBFBv160A;i12Co6y0;!e0l0r7t4EE5;e482h2021;!e921i189l44sECy0;!e1oF01;aBEe4F0D;a4795eAA;a2948p3Dt3273;c44iEv19FE;e0i15E;e9BAi574y0;n2s344E;a356e17;e4EBBo1uAB1;l1r208;e3Ai3Fu34;a10i66Bo46;!i3D;i279;a30n34C;!k1r1s3Et11;b7Be442lBo1t471E;b7Bg1FCn1A6;!e31A1l44;a1g38n11C0s11t38;a25B3eF6;c2982e1hBk44l1CC3v958;!a40c92n2s0;i1B1o35B8y0;a1De79;e30vB;!e30rA21s0;t545z38;i10n1F7r41B4s20;a1Di4AD0y4D13;!e26i3s0;mA1r3B1Bt1861y38;a3312b633c1441d2E92l42C6s4F16tF43x0;t62;n10B;!a1D24e15i6l6Bs0u1C;g394tB4;i386D;!e4i6s0v7D6;!e26Ei37C7o433;d1FC2e33Ei4FA0lF36m4416o3BD6p458s19Ft1y0;!eEi286l7s0t7;a32nF;aA96d44e8Fl0sCC0t4A9v1927;a185r1;!e4845g476Fs0y0;a766c26A6h3B92k426Co3CF0t3329;hC5;h1BC;!d0r2F;d0r63D;b1Ag13Cw2Fy3B;!e56Es0;!d80o31w80;l262u5;!e916i6y0;a20e68s11t4A;a4878e3795o4B32;e5138;!a140Ec1FAd35F4e1FEFi385Ej4AA4n1D74s0t1801u7FFz1631;t4A9;g1k1;aF9eDn2o9;!e10AFiB;i5o6Ft95;e113i3Cy0;a1Db4575cF90eAg1549i3B80m1328p1s214Ay0;a529eEi13D;e43C;n1r46A0t0;e2796;e6D3i6;!e1p2E38y0;c9Es2C;nErAD;!n52o9;n3o9;!l7r7;l0y0;r161;!aDF5e155Ei199Cl1011o3AE0r440Bs0t196u2655;a1m64oB8u34;i1575;b425e0;!iA5Al7s0;a1De23iDDn413;l1Dm39C8s3BE4;!fB13lDE2o10s482Bt1FD9;r374E;e192l1F2p244r2DAs4E;e5DAs5;a40m7FBo29;!g27p510r28sBE2;n0t2D;s151A;!a1F6Fe1Bi22FDl7s0u661;l55x0;!l2Cs0;i13r18;i95B;!a20g47i3Fo29s4B2;m44F6;c1728gF66i2A8Ak2A2Ft2BC;t3517;r2E61;aCg5k28lBn694r35EDs239;c11t16;a1E29e26E9h39F6i6n302tBDu1DEFw98;!f98s0;d16k16p16;a1BBh87i4;aF5l1C;e1l7;a30b4EECc2E4Ee68kF3m3D8An242Fo1FF0p3E16s2A3Dt13EA;a2BEFb48e1;e15Di17Al16E;o983;a3CFFe27FAi4EE9o250ErDu3FD1y4D61;a157e15iCCy0;r0y0;eCi9;a3A2CcB2dA4e1f4AB5l4688o1D8Ep1BBCy0;c2AdB;m404;c226lBs190;n4814r132;!e3EAiAB2s0t1DEw3E6Dy0;e2BC0g3831s11t0w3EF;aCe79n2;!b398d0l7Es0w172y0;!a111e144h124s0;e5Bi76o11C;c62Fi88r57F;d157n194r2Cs296t50DBv106;!d0s0t515;!e26i9oDs0;l2E16n106r2C7A;e31y1C;!a1De5i27m2Ey0;p126t1B9;y17B5;a462Di42BB;!c1D7eC25l4BB6s1B01t3A31;a4AABd10Be0f28m48t32BBv2C;a1D86c4432n4D46s4B97t4A4;a2C3Ee37A1g5C8l9FE;a4Dc4C7d28B;a304Do473;!a4De3CDAi6t2B51y0;!d0l1988r48s2E3w172;d3FAn157p0r1Et61v2C;!s0t64C;!d103eAs0;a10r5D;!g3Bk16r1Es0;aCc1FC8d0n2sB2;cEn65v19;t13Du10;aCi4C8o453u4E;e31E;a1e0nF;e23iDDr35;!l119r7s0;d2AB0g5D;e17iF72;m56;!m56;l2105;r931;d10C;nB94;e185Fi378F;c0n0s14t3;!a4Be15i6n0s0;e68n2s11;rB7;a22E8e32o32C6u72;eA3C;k5FC;o723;!e15i337s1D39y0;!a8A0b10Fe4i21l4939s0tDEw2BFF;b1BAi3;i21oD5;!e15i6l3s0;e11Bu49;a30d119t90;!c1DA6t98A;c11r16;r674;d2EB3f3EB7i2E9Fk207l66An49A8o2E5Ar216Fs18Ct1DFBu457D;cEs8;g283s207Fv27;b4Dd1r6C6u2B8z431;!i35o12s0;a7Cg16Bs1A4;!e166i6l7n22;n25s3455;!l4F43;!b5Ce258Ai380Al7m787n22o4927p6ACs0wB1;g16;!e1Di2EBr151s0u791;!fE2h109l6BpA9s884w136;t0x0;a1829b2344c3146d4662e4590f1760gC71h2B24iF3Fj3C81k955lD25m2C9Bn4EF3o2D01p217Fq2CBEr50BEs262Ct4560u487Cv3D30w4DEEx0y24DEz4380;!e15i184Bs0y0;e4DA;!d0n8r0s0;!aFs9B8;a2242e34E8h60i1A3uB6;a246e494Ag44i3743n1E0;a1lFCo4936;d8Bl62;e12nF;l202o11E;!e1B2i6;h1AC3iAD;e1l1;c4C51;n84sC0t2D;!e21Ai259l7p1A2s0y0;l3620m0;e518iACo10;m64n333;i3Dt7B;a4E51cCFBd953e1i253k2BABm2A6An458Fo4EF9r46A1s4872t41BC;!i35s0t7;!d1n1s0;!eAi6l1E;c637i32l10DEr3807s1FAt9B5;o1A7;a277De1CCAi14A3l32AFo2416r3DE1t484Cu4BE8yD07;!h1r58s0t2C44;e2913iCBlBy0;!s0t343;i56o10;a238t3u14;e17i16D5o4BA5;g3A80n28s2Cz2C;!a4Be10Di6l7s0;l89E;a1052;!b7Bf12An1p940s0;i9CC;a23BeB8i418E;!bFEe15h28i2BEs0t58y0;a20y1C;l2A8;d1322fF40;m1As0;d1A1gE4;e49ADiB;d37C5e1729f3974iD47l1691m1o3306pBy18F6;eEi31oC6;aE9e14Cg0iA05o9B;e42i2By0;!e42i2By0;a2404c4A73dF2Ce4F66i7C0k458Bl2006r1s181t1F89y7C0;r4A67u1EFy1;!e4i547s0y0;!e4i44As0y0;!b3EBf7F9nD1s0w657;!a1d0mBs0;a4307e5o95Eu30A;!f240m1n32Es23E3t998;a51Di13o9;m0s34;o39;p7A;a38DAe99i1AABo4u3FA7;oEy356;u2C22;h82l2Cu2D2y0;a346Ai399Do3FB5u5;c4D11m1s2263;!e432h1i301l2BAp1A2s0y0;!d0s0t107;i145;c2511d84m30BBp11FD;!d1r1s0y0;d0r1s0y0;iAF2l1B6;!e609f37i301s0y0;!i3Cs0y0;e380nB1;!e239Bi86l7n22s0y0;c3DE8;e12r46;d210l2Do4u36;!e15s0t38y0;a4EAAe38F0h167Di440El4E8Eo27D3r5001u49CB;aCd2Bl9Ds1Ft2B2;!e0l0r28Bs0t2D5;a20iCFu6C;a185o9u14;m865;r8s3;!aDE6l300o16Br12As0u4801;!e5i21t1;r0s3448;!d0l7n0r1s0;l1t1C14;xC;c2Ad1;a28e10EFi3125lA63o760r3E74;!eD1i7Cl22o45C4s0wA8;!a741s0;iD45;h3804;e4930;eAh1Ei6;sA8D;m44;p197;hBk48tBD;s3u36;!e5t2D;i38s4E80;!a7EFb3E0Ed1BE5e7F1g165Ai3B76n343As0y0;u143;eB15t86F;!e1r19s0;e10l9DnBt1;a19EBe28AAoE6u277;n0s0t5E;c11iE;aBDCe310l2366;l5En19s1D6u59;n4B2Dr62x121;!d336e482fC2h46DEi4225p1C03s1CE3t16Cw1ECF;!e4l7oDs0;!fC2l1Es0;e1i1k18;e23i6u346;l30B;i39A4;a469DiF51o4A1Du25D7y1843;!d0i6r1s0;n2B5;e3F17;!a1F3CfB5i4819p12EBs0u22EA;i4oD;!gBl0s0;g41r7t3;h70t107;a9t1;!g5B;g5B;d87n376s1Ft18;!f37n22s4961;i20y0;a14BAc247d46Ci342Cl359Ds1C7y48;a867;!a867;e0l0t3;l68Fr3504;e61Ao24B;!kF5;!a2FA1g39D2s0;!a4Dc639d401Bi21k1B7l10Bm3E88n0pC89r4B6s912tF06;!i4C01k1l29FmE16sA1t39D8w1A5;!c49AFk9A6;a0n52s14;!n31s0;h2Bt1E;e155i38A8v58;eAi6o1BF;n344;!a4Dd0l1E13n48r4035s0w2D0;h2ABE;d6Ai0;a13A6e194i4F1Co2005u2DA;!a111d1E0i1DA5;l3FE9r18E9s29;h19Dy3B1;e5w203;a1i3C;!aEBs0;e3B1i1C11;!eA3Ci6s0;a2A3AbFCc143Bd118e347Cf2299g9F5i2330k4693l363Cm29E3n115Ep32F8r2761t1FB3v2BF5;i9o5BB;t2A9E;c13Cm29;a8m167x0;d0lB4;!m2En1s0;!a93e68f37i21l4A50o0;b1C19d3DAeD9Ff45B7m1FE8n3E89t36A1;!e3F2Eh38i17Al1A02s1BCt3D29y0;iC8;e1903i4E;eB0E;e33oDy0;n1r1t3BA;r34F7;c0d1l9Ds50DC;a1A6eAi6;c3d1t1;a3176e4758iBEoE25;o5D;e17i3C5o6;y345A;aEe8Ch4D72i4F4Eu881y0;!i56s0;n1Ar56Fs4C;n490t318F;y105;g3FBm1;a96Be9u61;mA4s763;t4976;e0p0;g19s19;i8Fy2B8C;c461Fd3e146g1i6kBl4D62m2A31n4387p3832r3FE2tD8B;!i13s0yC;!i6F;t36C2;aCt1AE;!d0l2F20n0r1s3E;!c2FCe1s0t4BC8;n4CFA;d38t48;!e4i6s23F;c0n2s47Bz19;!a143bFEe3B8i21s0;aCe15i6o12;oC4yB90;eAi426y0;!i2D1s0;m55n8rACD;h1Fi69;f1r1;!a1A67i484s0;hDDA;eAh66i6;e23i6o8C;d635;a0l19;d4A8l4231;!e3s0v18;i9m28r8t1C8u168;i3440;!e5o36;e5o36;o2D6;c485FnA6Co10;o2AE3;e4i2926o10y63;!s0t224B;h7Et4AD1;a20c0nF;i3B1;h217;r4081;!c2F1AdBn27As0;!a10d2F22t487;k2Bx0;a4E1e0o29sDE3;!e5u3B3;n2FACp1r2Fs9Et4838;n69;!e2245i6s0;!b2D4e1l7m27A6n22oE8p2490;gBt291;d0y88;e0h2D7;e5oE4;n6Bw80;eEBi6;!aAFf165Fm2DBs0t1C8;l390;n1sC0;!e15iCCs0y0;!a7DeAs0;!eAi43s0;e9i6l3;m4953n118;r24EB;h441C;i0o105u5;!e33i24Ep38C7;iADo12;!g44m4A3n3y48;a5D3;u257;h117p48s3603t70;r263t499C;a481Bb5Ac48Ed330Ce44C2fBFg2852k3m40CFn2Cp129q179Cs16Bt0u1FE6v3y63Ez36D1;!e148i17As1BA8;eD1i191Bl4A99p2Cs1DD2;p16t7;dF4;!e23i3217s0;!l1FE3n4Br2Cs0;!i34;a8FD;hF0;y4AA1;a0g10sAF8t7z47;l419C;cB2e23i6o10u12;l16t0;d39s2CDFt1;!a29FAb65Fc4124e41C4fEg10iEDCm25D0n24A4o303FrDBFs3925t41A1u273Ew263Cy0;iEp1;l300r271;o105;!e687i86s0y0;!b37DFeFFf4BFFg260i3536l708p38Ds0t1DEw3D79y0;e5f27l9D;e17i4D18u5;u410;k29BDo2BAAu3C4A;!e4iBAl76o29s0y0;s432F;e30i4oDu16D;!e12f37i28B7s0u3D;a15A6e3476i6o3994u2E8;!r61;p286A;k3s3;i2Bo29Dy0;uE6;!l0r7t3;l0r7t3;e719;t4DD;!n7;t1A1;a1De23i6t8A;!h124o9Br2B60;!d0f37r1s0t537u34;a75e33;!aCe33;!a3Ce4i424Cl7Eo0s140y0;kBl4EF2n3CC8r25s0t88;i1Ey0;d3A3F;c3D8F;i4676y0;a1Db2Cm1B98n1ABDpD81r4507t4262v2C;!i47D4k2376o97s0t20D4;n4BC2;a10e21A6g22F3i48A5l3D86nBo1p12A1r39CEtDF6w44B8;a4CB0;k4Cn2s11t485;!i288o10s0;!l6As0;e1lBs1F;n16o9;i13r2B7;d1g35n3r61;aDCBe4E4o1;eAi3E4EmF6;!a2862e5i4EDAy0;a342i3038y0;i132n7D;c1E48g11;b217;!l2A94r107u3744;!a4C0B;!eAh16Ci6y0;r8EA;!a39C3e4h200i253oA55s0;s1A06t0;e1Bn213s11;l534m0s0;a1AC0e1286i1C96l3E04m3096n2B11o444Dt3AF0u256Cw1A;c4F2Eg21Bm64p3694;oEt1;a1De23i43Ao12;l426E;e112nFs11;eB3nFs11;!r35s0;n4BE9r2A97;e6Ei498Dl44r260Fy6A2;!n85Fo471Bt88;a315e6D3i2D75y0;aF5Es5w0;e12i10;e1Bn2oE4t3;n14E5;a0i20;!a70AeCC7i26AEo1s0;!a176p1sECt1w172y98;o2D16u8F;b1Cl82n2177r1070s222;l8EE;a21e126;a3CA8l1E5Co22B;h12FBr4762;o9t4F;k1B7l0n28rF2A;!rABs0t1;!aCEBe3D8i3100o3723s0y0;!aA2d27eC1i6l7n22s0;c1A87g3Bn2;s34C7;a4De6Ei21;w1A;b1Cc32i4r61tB7y1E;a59e855o54;!e4i243Fs0;i18o29;!d0s75Dt8;i2By4C5;p0y16;!e15i23F5s0;i3878;!o10s0u14;l4o2FD3r158u1ED4;d3n3;a1De557i6t1;i2Br7y0;e1B1Di792;!c9Ee12o3BB1;e17i11A;f7n333s0;s2D5;!e15i542s0;eB0Et0;a88i470;!a14EEe484Ai6l64s0;!n1D8r7s0;h1Ft39;iB8o1F0;a443Ee26A7i4303o348Fu20D6y4553;!eC1iACl7o1s0;!e15f37i2E3Aj258l47s0u57y0;o726;!o726;y88;!a180CeD8Fi37E8s0u3505;r21Cs1A;c159A;c3F53f1363k2201l3E06n14EBr22C5sA53tA79;a0e26i6;a40B;g13C;eAhAEi6;i3B42l23B;d3Af2Dl269;a3BDCe10;!e21AiBl7s406;!e134i3F;!a1b498e6C8h109i224l4CBn22s0w599y0;e17i21o4B28;g28k28;!r1F7;i0lA7n364s0t445;!i28Em64s0t1058;e8i2By0;e2059i20FFy166D;!e4i6Cs0;!d0g834r1F5s0y98;o82;c3981n1F16;c47Dg1A;bCC8d3Bf63Ek1t3;e15i21y0;!d0i6k1C2Fl12Fn778o42p2444r176Ds2960t1507v1516w4058;!d0l180r1s0;c3Dx1F;g3Dn2o12;r701;!c3e0l1EE5m242s0t521;a2892eC8Ci15B7o1C17r1B1;g26F;!g26F;!d34CDm2Es0;!d0k4Cr2Fy0;r2EB6t87;a6Ci6BA;!e1u277;a3772e2188i24BFo2518u1835y4805;!i50o127s0;o2BDA;!a473bA48s0uAD8;c4665n4B5p414r4779s3169uB51;bDBd0x1F;!o1D;!i91s0y0;!e221i248Bl7s0u817;e1577i6;aAB9;!a11Cc2B7e24i6;!eAi4C7Bs0y0;!e1926i2A4s0u11C;a4868bFEEc40E5d20B8e4A8Cg4BF5h1iEB6k4446l1E40m483Bn4ED9o44A5p225Ar3A72s3BDEt3403u21C0v2C6Aw25ECx0y2B4E;t71B;r232E;!a16E9b468Dc1C85d101Ae458Af4663g10EBh16Ci2155j22Ck28l1153m3730nFF5o1D5Fp480Er4776s4B6Dt5078u3B3Bv5093y40C3;!e0l0n8t3;iF8;a11Cl1C4s0;e14C;!a20FBeD0i3D71o29s0u14;!e1672s0;r0t7DD;d7Ft409;!a10e15h8Bi67l22s0y0;e30iAD;i38F3y0;a3139;e84Cl295;e545;a8uC;!h520t1AC5;a359;n1r454Cs1A1;t1C4;c367Ae8ACh394Ai6k49E0t3875;i0o138u5;r70F;c5Ce1Bl7n139;e6Eo81r87Au51B;!a482Ad0e1Dl22s156t3B;!a7Fe1Bl2Cs0;a8u30FC;!dA9i1E3Cn1E2r5101s0u3CC7;e39Ei9;a1EC0;n37F;!a2CFe24i3D08;!e5i6;h1Fu221A;b3Be34i4CB6y0;k1Er267;a1CCo1;a299l2B4;c18CtAA8;aDAc58E;b0r32;a4C03;nFt7v3;i647;g41t3;d2Cn412Ap244s8;l4C3;l255F;nCC2;a34e34;a2E1FbF3Dc2130e20ADgF34i950m2308n29C2p2B90r131As721t3AD2z3B94;h104;l4uA6;!eAi6l337Bm9FDpDB8r2EAF;a4943i250;h3B6i9E1;e495B;a0i13o9;!a0i13o9;!b755e3998o5Cr19B5s0;a40E9n3u14;fB0l3n1;l14Cy1C;a4d0nC8;!iBBs0;aD89d2AB5e366Bm4F28n2150o352Ap298Es1115tE79uB10v50BFw2E51;o5B;d3118pB9DtACA;a28C3e89i1C;d1985g1593m3BABt42DD;!l39A5s0;n4350;!d48e10f4172l44F9m2EpFEs41A8w982;a3FE7e2D6Ci4F33o3DB7t76D;n366t25A9;e1889i21;d55s55;c0t5E;t409;a6FA;!e8DB;e1o10t3BE3;!e25DAg0;e3392i383y0;d3BC2h287El12Fz10DB;bCEjB9;l4BCs5E;!e4i23FFl7s0;!d0s525t2D;!l18Fp8B9s0;!a20i3Fl7;!b16F3e15fB5h317i853l216EpE3s1668w946y0;!t3773;a127o54;h13DF;a2970e12EiC8o2A6rF16;!d99Be2C7Di1233l15Fs0;e3595i3B;e0i13oC;!b4A3Dd353Bi6l613r1s0t237Dz2C;k1Es415;!n64s3DBD;a2754i338o3F8E;!eAi1C5mFBE;!e4i6nD8s0t4A;e3DC3;m0t7D;l44uB07;n2t2F;bB83;!i439;!iE;i439;l1An14C5r300;r3D8B;a4EE2r9C;!f7;r4D7E;n1o9;e1BnFo9;!a1B0Fd0f1C3m2En1r1sECy0;!e0l0n8s0t3;a8De33E3iA2o42;e3D52i91y0;eAi20A;!e134rA21s0;aEBFe6E;b198CeD36g857k3m4F6Cn3p77Ft61v2C;n1B5;aA71e3A7B;a1A5DiBE1o35;!d0s0t90;n7CE;!g917i21pB88;a16Bb4498c2Be5l28En3CE6o43D9t214;aE74c2Bu14;aCFeE40f41CCh9Ci301CmCEo34u8C7;hE9CkDF7o1t35FAu5;c32e65;lA2Fo736;!a4831e8D2i167As0t612u4528y0;h1EAF;i5E1;n2tB;n2t2B;n6E7;!e1r0s8uD;e16Ai1E94;e4i807l44y63;e1BfBFm325n3873s27FE;c92e1Bl7nF;l1t1;cD1;a3A9De3E22i253;d0s65;!i27l19s0y0;e1742;i2187;r29B8;e0i21;aB9Ae1i7DFr8Bt39BEu30A;!a0e4iFAs0;e1049i253E;i412o46;!d0l6Br7s0;r5Au1;l1A1nD56;n4r3y1;d1143o1B0u1;e17o99;!e1D;e3AA;!r31A9s0;m2FBBo667s0;!d0g901m38FBr1s0wA8;!e6B4h1jBp4ABD;!a1613e436Ah7D5i349Bl4B6Co4B4Cp16r1F05s1Ft10AAu426A;d9Bn8;!d8Ae1B8i6l2BD4s140;a8m3o2A;g3E2Ej2FA5k48n17F4x66;e4AC2i37C;r3849s2DB9t31C4;aCc0u28C;r3s11;a453Dc664d598e146gA41i61k0n3376s204Ew0y1;!a10e6D2i6s0;a4i171;iAC6;e0i65;!a4516c3F85eB0Af3A0i123r4650s3DCv40F;e1E87;h568;hA1B;!d0r2Fs0y0;!eEEi2F35w946;a238c1;!cFF3s34B0;a1DcE;l16v19;a87e33i199;rB4B;!e4i6o9Bs0;i38o9BB;l2727t1F8;a531;e152i3C;e1Bn28B1t15D4;s19tED;!e5k4858;!b1D5d0e34l25m1s0wEA;!c1048g206n203Ar2189s0;i18m0;!r9F3s0;r163A;l7r78t196;t178u1D;d3AnFt77;h1FsACD;cEx66;!b7l47AD;!a7Fe15i21s0uB6;a8e132Ao10;h3842o120;u11A;u4BEC;o514F;e45F;t4891;i7F0;!e79iCCy0;i4E22;eAF6i6A4;o1B41;a9BD;!e79i2;a13B1e316Fo2BC4u1;a0g1i13u14;a3192e23i6;!a15Es0;e1Dl22;d4576g4C9Dm1986n6FDr2916s41F3t28;!i67s0y0;!a51iCs0;e4CiAF;l0t2A2;a145l3;!aEFb4D41f8DDi4FF1l6Bo5Ep2CFCs0;t2B22;f3F3E;l64u30C8w1Ax0;i4l0;e27A9i3ADAo4904;i13o541;!g1A04k28nB5sA07;n1r2F;c2908n2;!a8Fc4AeD0i21s2E3y1541;a295Ae4D93i20B2;!e3i1s0;!eC1i620n22o9Br278s0y0;!e15i86s0y0;e0t20u12;i3lBy0;!a246b4E2l22s0;i4n25s52Dw1ADy1;c32sEz187;!a245;e4D0o31Eu16D;!c3868g41l1s32;!g1120l7n22s0;!d3749l193m1p1s2Cz2C;t235B;!l0n3s0;!a10o28As0;a4D2i35E0m21E;b1Cl1C7m99C;!g32EArAAs0;!d0i6n271r78s0t2D;l217p1;k6A;e15i6o1B0;k1o0;a0i31;a497Fe1A7;eAi123y0;lB9B;r3F6AuD;a75i13o9;e1Bl7n22s13At497;nC4;u1C6;e328Ao69BrF6;!e4i21l4C50s21A0;!e421Fl2DEFo1220p1B17s20Ft3494w265y0;r263;!a1s0u2C;g132n0;n0s11;!l2Cr278s0;gA7i10n136Fr2A13;!k53;l5Av466;!e1Bl7n22y0;r78s1B5;!e4i21l3s0uB6;!eAi298s0;m334;o36s3u5;l3Bt1;o40F8;a1i25lBr272;a2DE3e1740i805o43BEu37D0;!a4Dd0i21l200r1s37A5;t61E;!t61E;e1CE;s1258;!t177;a39C9h14F;gBl3Au3E0;!d3BDDe24n1820s10A0;!k46;!a4FD0e4h390Fi6l87o3F5Bs0y3B1;a12oDF;lAD0p2273u44F5;l80Bn29r18;i477;u12E;!e4i6r1s0;b3CBF;l2AEm5A2;d196;d1CA;r1F;e5i13s0;d0l2B3x1F;e1h8F1;p36;r1A0;c182d0e73Ci1313l33ECm3F50o19C9p36FBv2C;!l46s0;d0r175;d90FpA0;c232d47C9g3C7Ck337As0t50E6;o4r359;a18Ei2769;nC73;!d0n65r1s0;a2180f0k1l4F4Cn2E37r1As785v72F;l1n142r2Ft3;r601;!g243i2Bo28r13Bs0y0;!e1i0s0;a20i171l52y1D;c3AB4w408;n8r39;lBr47BB;!aEe10C8i6l672n22s0;!i154r7s0y0;l2AAA;!a20i13;!h459l87s0t21E8yC;aA7Ae22D8y73;!a2488e325Fl7mB63n22s0;a1Do29;!c9Fd9Fe5094g7EEi269Ck9Fl1FA8oCCEr4F0Fs0u5E4v4A17;a39B1e2D0Ai448C;c92s102;g5Bs5098;!d0n133s0;gBnA66;a1D1u36;d3r1;d52r1;!d26DBnA9sB74t2FBD;g5C8;h12AF;i189Bu31A;c5Cd87e5fF2o29t28DC;eDl3;eF9l3;!e5n2Bs0;a3D35e46D7h2544i36EDl208Dn4E7Bo32B1r2ACFs9Fu22B8v4F22w36E9y3F61;a1e4316h4EA;!a4Be11Bi27s0;e4E59i6l15D7o39DFr22;c269Bd370gA42i4n492r2087t11D5y146;o18F;c9Ep44C9s31Ft1;e1Bl7n125;c2Bf7;a12h29EFk28;l3CFDs13At47DE;e15i337y0;!b200d336e1B92i4F2l494pD79s48F3;e1r0t1;t3C8C;aDAoE6;a36e1i1E76o4855;a4De3A9Bi21rBu1A6;u43DF;!a6De3;k415m10;c1lAA;e169i4DEFy0;!t440;i163;n16r7;e12i3D9B;a1iB35uB35;!e39Fi67l202u1C02y0;a323;d2Cr44s1B9v4B8D;a1EEe4;a3679e1i18BEy63;e442;bB65c330o35B;!n3Ar2F;aB8Fe9;h1A79;n3D25;a18C0;!h5Al1E0p246FsAEt47Cu1BCE;z2C9;!gA9s0uA8F;a3E1e6D3i6;e630;p56Ct3015;e1Bm3;a156Fe4D1Ei1C88o1CE9u4703y67F;cCE;i45o6D;a11Ae4BAAu2809;aEw252;d137A;c11s35;pEB;!g233;a2D36e10A8i4849lC98o2003r3212u3DF6;a30e106;a6F1b28C5c4020d1EEAf1663g1F7Ei2D8Fk2Cl179Am3790n173Dp127Ar147Bt1989z33F2;eAi647;!aCd0r58s0tCAy0;a30i2By0;c32D;l1Dr40sE;u3067;e47AAi823oC7;c3D49f1DF5g201Dh17Dl304Em3DABn22s1AFv9CB;b3AABsC5;l2729n654;o10p3B;a2941e42Ci61;u46D3;!a30e4i6s0;a235Ac386Fd2E5g21E4i34Fm2831o2D57p44s1289t274Cu4E47v41A4w2F2Cy8D;e1E99i381o2883y4FB;t3BE;n1t7;!aCi286s0;r153;o69F;a1iD9;t384A;d3294s13D;o15C;!e1i2DCl343s0;a34e4i4433o5F1y63;e746g4EE1h2F4Fr1B1B;a0e0g0;aA2l280m6BCn1B1o1E85p1Er126u126;!e704;u25A;h3919l3;k2Cl4FB2;!c1E9e1g2C93i11Al107m22A7n30B6r2EC6s74Dt36F3u265FwEADz187;a4775e18Di370Ao0;r3u5;d3572;a176e68f37l22;c1E;h2D20t103;!f28s0t107;b1Ct1E;!eDi3l7;!s605t1;aCABe4B20i1DA9o3AD3y0;a25Ei18;d2BA4f21B6k2174l3B90m39ABn11CFr27F3t16BDzF5;s19t2D;g15Am480Dn12FEq11Ds454u2A9;a185e5s27Bz19;aBCe50;e18Di29B;eAg16i6;a10o29;hF6;!e319i91o9Bs0y0;r2Fs0;!e26i21m5Fs0wA8;l98y0;!a4De15i1ECs0;t1u49;hDC7m3ADCt4634;d2ACf72Fi447Cl145p338s43Bt1Ev1Ey17F;e8t3;o1A39;aE9rC3;!r7t19;g418Aw71F;b1958;i6DDo16D2u2DFE;s8t7D;c1E9e166g11E2n4BF3s3A10t3131;!a1FEDe23i21l2Co1347r3984s0;d2E4A;h6A;a3CAzA24;!a7Ce15f37i43s0y0;v395w3EF;c7s7t1;!a1b3AC4e4A1Ai443Cm4AADs49A6z8CC;!b13DDcD1g3AEh1n4075p786s0t1A2x58;mF28n48A;i9E0n192;!nEs0;nEs0;s0z0;d1p4B7;e2B75g209hAE;n1DC8;!a4Be15i6F0l6Bs0;!a7Fe467i2BElBo1s0y0;aCe1BnFo29;!a1e131Dh5Di3334l1B6o36B1r17Ds0u10y0;s174;l3DBC;!d0i6l22s0;n1EA;c2An3;c3o427s0v3;!a211De5t0;aAFe12;g1o1;i142u7;l1r683;k3542;!g38s0;!a548eC1i326l7s366u34w80;aCFi65;!b130d37C6e15f1F39i253l2117m11D8n0r9C9sD8CtFDz44B;h313i1D;m2631;e2C83;o5BB;fF2s174;nBs3u5;!f7s5BAt7;a36CCoEFyC;!l19;e3F01hAEi6;l28n2C7;eC4n4F40o898;cC9i1F58t693y0;l4397o74y10A;!r2F23s0;c32lFD;i34l1o595pB7Es56t125Ev5D;!e15i1620l24Fo12s0;e4B27;!eFFi17Ao2CCBs23Ft0;n2s11t3;e36E7i6k18u0;c44Df145g4AA7n377z1E;!m18s0u5;!dCEs0;c446n406o10t16w1;cAAn1;e2CFi72n767;s29CE;o84A;e23C6;e1BsE;a4C1o14;r1A9;!i6w2F1;!b1BBBc1F4d8DFe4f151i426k28l489m2Es1B2Ey0;eD03;o2AA5;n96F;b3896c8A1r278At1;cEl1Dr16AAt3w19;o3514;e0i0u5;n90;a126d64i4C0Dm44CEn490rE4;e23i17A;a3A04;e59Ei1E6;d62;o8F;u848;a9E5e2406i6t107;!e4iFAo12r4593s0;!s0t206;aCd28e0n423Ct4D6;d0e0k0n0;e5AD;t35E;n4D14r802;!e0l55s0tBD;i168s14C8;a2C74;!k1l5FnBo1DrD6s0;e113o1;b7Bm4C8Cr417;a74Fi4F00;a87Cc70Cd3B32e1F77i183Fj4082l4EA7o279Es17F7t1812v2F02;o25u47E8;e3188i21u1F9;a75i1A8Au14;aE9n2D;a461e8DA;d4E;a2589dBB4k5Dl5102n3731o3DA1r1t2EC3;!aCg0s0;a8i30;a617r2AEF;a3DDCbBe113Fi33C2l3FDo1579r3863u4B25;!e3C10i6y0;r3335;!e193l7oDs0;e8FBp7CB;eA1D;!a2046e10i171Bs0;c7t404;h1E5u46F1;i368;!aC61c4B5e2B0f28i3943l36Fp3B86r42As0t49B0v2By0;d3Bf7;o10t27;a6E6;o10u59;l33Fs0;!o72;h1E4F;d0r7t1y16;a3E;p137;a29En346;n1F8t1;oDr7;!oDr7;e72;d0n4B7r1x0;!aDA;aCc124n3;!e4i199s0y0;t5D6;n1DEA;s5Eu5;a42e96Bi2Bl243y0;a18CF;e249l7nF;!c9Ek28s0t11;aEo51;!a31B7c283Fd19ABe2147g501AhA8i1EF7k4F8Dn2A5o15C1s4622t4658y0;a75o10u14;d13C;!f37l2115n36DFs0t242C;e989i67y0;aD4iBEo1F9rB53u44;e4D7A;l28En405s2C;c3C0h1Fs1C4F;a5111;m3B2C;b4C3;a1u1D;e8B1o97;!a0b2895c1AFe15f24BBh3BEFi67l3A9Am165p2C24r358s44C3t42AAw83Cy0;!a3CDd0o22A8r1s0;e4fBFg25Fn0t64;n4021;eAn8;!l22;!e1s0t3B7F;o645;c187FiE;y3B4;t3E1E;a3E62e297Bi1AF4o4006y0;!l4545;i1399;e33oDt1;c7l1r7t3;!i60Fs0y0;aCi111;l3AD;!e1h34A1i3Ds0t1318uB39;!a1684e2680i474Dl44o4291r3FDEs0;e1oE8;!eEh3D68pE3t4034uB1;eE09;a3F72e22Dl209oC94;!e4i43s406y0;d0t263;o2Ap18u3C0A;!n3Ds0;b3232;a0i12;e19i19;r12BA;a21e1;o3E8A;d0n39r1s8;o3F;l3DE2;a2DeBy1D;a4129d4Bt19x1F;a88i4BDAoEF2yADE;a3000o290A;l64C;a1De42o1;lCn407;e716i86;!b1DDd0s0;a4De24f37;c312g25Fi145k1En27AEr1D1Dt3952;!a1eAr7s0;!e21Ai3Cl7s0w99;!a26C0e965i25E3s0y63;!a1611e3EDi5Co3C2Fs0u291B;!s0t1F6;iB6r155Bu4FFz2DD;eF18;!e19h594i3Cl7Es2E3w1C3y0;!e409r10Cs0;i31o6F;b2DA6d124g21Bl1B4Cn46CBrF7FsC5v209;!b2EDr1A;t12D6;c21DAe5k475m38n19A4oEs1F;uCE;p2CB9sA1F;t4A8;!k4Cs0y0;l3F;i31o6EF;c181t3A;!e4fE2g2ECi6k1l28n0s0t16D0;e29A1i31;d1Eu30;c4Ft60;d38k141t38;e1Dg48E8n2B5s1E6Dt3A5;i29A9;c341g341r3288;y1A;!s0u3E0;!bB4e4i6s0;!b3B83c4F3EdB49f3C3Eg1F57l21D0m26EAn28p1EEEqDDBrBDBs14D6t46C1w4095;!r74Es0;!s0v1CB;d38e22Fi4D2BtBy7C4zB;!a1c845d1385i96k78Cn4B63o9B7s0;r4B7;a9c0d3t3u14;e1r0;g306;i346;cE85d1391g184k4358m2C6Cn2F2Br4A27s2477t32B6u3E3Dv345;e1A6D;a55;o372;n2E1s8;a4B57;!e20Di6n0s0;!c1D3e4iBj6Al7s0y0;c4345g17Dk17Cn1CBq79Ds2157t48;i8Do3B;!a91Ee8Fi207Cs0;!n16s0;i4n4y1;m38nB;bDB;f16s8t16;!m0t70;e23iFAo12;e65BiBo93;a4De451Di574o1y0;!e9A9s0t380F;i19Al6As2C9;a51h2C56;l8F9;e24t1;!d434h202nF3p44s32Ct0w136;c9C1t48;!h3;c0d1n3t5E;a18EDe4584i31l4659o1F42r4FD6u405A;a0o5;!a2C7Ce1486h46C9i4E8k5Dl22o18ADp1918r35s0;cA1;!aF46o36;aD9n2;!c247d8Ai96l1sC27;!e17Ei6oE4s0;iB1Ao12;a351i50u164;!i2FAs0;l28Bt3F0F;!e10mD6Fz4C28;!a972bFDDe15f37g632i21l76m62r261s48D5t4AF;d0l6A;n2s3D1z3;a0nB;d44lF6s1B9;a164e1h2264i223Fp41;c121e1Bl6CBn3786;mB9;!e4i43l7s0y0;!d0r6A7s0w80y1;c1D3e1Bl7n2;eAoA3;a462r1CB4;!i12rB5Cs0;g3Bn2;a25F7;r8FF;o387C;cE63d1757e1Bg3D28l7m3A88n2763p12A9s11t3FDAv4C89;!e13D8h2Ci8Ds0;l1951n174t2B;e17t1;a1418b3907e1647;!l16;aCi3F;a18A6b4D2c4094e4918i2E8Ek1AD2lFB1m5E4n1361o36F6p4582r13EDs207t3E58u4AE1w3AC2;n382;g5Bm463Et3771;!d0s0w252;r9w2A83;m336B;a0c0o29u14;!e4i21m2Es0t212w98y98;!e1i13l7s0;m65D;!s293;a2975b2C49c1E46d130Ce1A89f43CAg3883h4F04i30F0j1CCBk307Dl1818m1B6CnC65o3D14pDCEq4D74r3C46s1B37t1BE8uE04v2976w301Bx3FA2yD19z46C8;b5AcDC4e1645f56Cg4C23lA4Cn42CEo5Cs56;r28D6;cCEn114pBq120BsBDt3;aA2e4i34DAl44;t5ED;!a4AEe4i60Es0y0;d1Cg1;n25r65;f128Es0;!e329i2D37o5EAs0y0;!s0tD31;a382DeDFAi3DD5oC0DuF8D;a4792r1t1;a63BeAg10E7i215Ek2ECo170Du34;!a2D1FbBE4d332FeAg1E5Fi3708l11FBm335n14CAo3F90p3B14r15BFs4425t4730w31A4;b1A30d1g1E47n1FBFp3B07r0t379;i77o9B;e23i86y0;t41AD;h7Ei6F;e4i123o36;h4D4i21Cu4E;e12Ei4E00o10;a5t4CDD;c2E86d3DD7l9A0m641p131s4FF2;!a1s0y0;s141Au36;c98Bh3418i1F66o10t2F9u36E8;g3n1;d4AnF;e37C3iEC3l443o1BE7rA8;!i3DBAk2097o93s0u7BA;bD6;y34;!e15i6s0u1D;a12l2Co4A0;a88i244Ao3BB8u39CB;!f1B1g2D98h124s0;d0e1r1y1;aCe1i190Au2F91;c0o29u14;a10e4870i3E4l216o10y0;a1893e155h117iBt2427;!e12Ei6s0z5A1;a2C5e36F1;i908uA19;c2A2nB;z84;n550;a19B3b435c1E9d4BAe3717l4A6C;!s0w307;!e15h14Di21s0;a75u34;!cB1d1E77n2o10p129t3C2E;aEe9BAi21;i9l76o29t38;!a342d2129n3s115;!e1g0i0o0s0;r62D;!e0k1s0;nCAs11u14;a2EFeAi6;o25Bu101;t87D;e81i270oE;!r50Fs0;!a84Be6Ei4024o56s0;n3F95;eDs3z3;eAi14;i3CoA6;d450h1;!b5AAs0;i5E0;!e23h5AiCBlBo1s0y0;i2Bl233y0;r46A2;e14DAi1F9;e99iEF;b513Dc4788d4C4Di2A7Bm3829n440Ar236Es4F2Cu4F5Cz483D;g5C;!e6Ah3901k5D;!a18Ed0fB5h24Dl247Dm1C2o9Dr58s0t1B24wEA;f2C8;d41e1Bl7n2;t3927;e40CiCBl2Cu1696y0;t1E7A;s4E4A;!c49g19s0;m3n70;e17i97l149;!l60s0;o4BA6;!a1e5t47C;i4r1;!e24f37i43y0;p1t1;!e17i96l7r7s0;aBCr19u49;aE82;!e33s0y0;r5F;!a327Be23i21o10;s10D7;n2s9Av3;!b1AA2c2014l47C0n264EoD1p129s1FtF8;i461;!i461;g4683l19A7;!e4h137i8Es0y0;!eAi21;!a1EDEb246DiAB1o4D69s0u8E2;!d0r1s735w236y1B7F;e31i153;!d0s0t1w80;e33Ei67;l70m0;a40n3;t1CE1;a50o65;!a497Ee1230i4409k5Dl4851m1EE8o33D9t38B4u4Ev43CB;h2AEi2B1;!d38e2C37i1ECl7n22s0t1FB9y0;a10e3D8i461Do35E1y1A;l19n485;e1787l5F0;l1n288Fs58t1;k42;!b3270c1C1d47D3f3187g4A18k475l2304m31ADn366Ep108As2BC5t1EAv436Cz30F9;!a12c3s0;!o2A6;c32n1r25;e4AF9i6o29;g14n2s3;c0o9t3;!d0n71Ds0t1;a4992bBc372Ae1563f1528g3E3Ai50D7mD34n751s1C58vBw0yF5A;!l1C7n3D89t29;l57;c1EnF;l6AE;e214F;s55tB;eAi6m0;aCFu69;e16A7i30B0;r3F8;h1DC5;a49o2985;!i298s0;e762i6k0lF2o14s8;!a0eAi6t48;a73lE0;u195;a17i1706o31D7;a183Ai3A0Ao120;b26D8e3DBf4A11l1C35n262DpE87s3FE0v1839zD18;a161Ch5029o2DDAr31D2u3F28;g52Fn106;a29CCb3E6dB0Ae19AClCp8tA35;e76Fi6o211;!m7As0;e420Ei86;!a529t1E1;!i2BC1k1D9Cs0t3F1Du991;t4635;e3DF2;!a25A3e2930fC2iBAo3F3Dy0;nFv207;r8C3;eA6oA6;d417EeAi18D7l4A4Fm2FCBn40F7r1329t32AD;n4D02;iA95;a8o2Ax0;n45B1;!p29s105;r8B2;i168o6;a20e43E;!n684s0t2Dx414B;i1Cl103oC23r1At1139u2FEF;u28C;e30i3;t4D51;eAi5;e24i5;n1A5;!a3481c56e114Fh4DDFi3E33k6C1l57Em2Eo1360pA79s489Bt3906;c2666dECEl11EBr3464sEt31F5;o3F29;!d3A76e8Fi138Fs0w172y63;h55t2D;e57l1Dp8;eBi3Cu532;c15Fd3DFm0n0;e12ErB9;e9i4EC9o2DBE;a30i4057;b27eAi6;b55;p5s0;a2937eC4o4903;e3E2Fi2156k161lC69mB9C;e12h48DFiCu49;a2C2e5F;h5C;e2A35i21;hB52;e24f7n2;a45E7eB81i553;!d0f37l4B6m64s0;n0r407C;!nFs929;nFs27F;sA1;!a8DsBA3w214;!m507Fp229s0;t197;!a10b180e3DD6i21l2619n474Fs23E;h494B;u31;g43D1;tA91;d1F6Di2186t16;g5A5;h7E;a2644e365i1A08u14;n388B;r131;g1v3;e5f7n3673o10t7;e0n2s11;t522;i99;!a42CDc38B7g3E23i305Ek19E3lEC4m4887n3710o5122s115t43E8u442Bw3996;e67Do3E12rE3;eDn2s19z19;tA2E;!a211b239Ae2DFAh11C1i17Al7n22s484Fu3ADw706;!s0t392;a2B73e1u34;!e1A76i21l10Fm165s0w98;g3815v4E12;!bE2Al7n22;g12ACiEl2C33m1406n3851o2AFBp1EE2s3DD4u2E24v3E3w3F42;m21BD;a4941;l3E28m1223;!a38FeFFf7C6i6m2En130o130rAAs4938;e0h0m0;!l133s0t1;a31D8c0nBo4DCs5028z3B;!e68g15Ai1FC1l22;i80C;n16r1;o46B;i5Fo35;i47E;a473eA50;!e4f37i2F0s0y0;c2Cd397tF85;e24n2w258;a537iB40;aA2e6D5;o32u54;n0u2CD;l0n1937p2DB5;e0i3A14o6C;c1eDl3;aAB9d9F6m729;l38;a21c3ADBe202Dh2D9Ai262Ak14BFl10C6m56o1q3B82r190s1C06t2953;e451h106i1Dr520;n4Br36t47;sA00;e23i1A3Do46y0;d8Ae134h24At0;a30CFeC1i1C90oB73y0;r3s0;!r3s0;a1B3h6ByC6;!e4iCBl44s0y0;b7Bn2p2B;!aCe4oDs0;d2Cm208r2C;!eC1i6lB64s0;g16Bx494;!d343s0;aFDBe494CiDBEo78Fu12D5;!e26i6o1s0;aEd0y19;a16A;!d0m64n0r1s0;c18BkCD;r1A1C;n41DF;o14w0;s483w1EA;h20EEi1D2sE26tB92;t10C4;!o46s0;iAFD;pBsBDt3A5;a4B2Ae1444i1350o18E2u454A;a3B38e23i6t1A;n1AC;l4F62n13Cr1D19u2429;!m87s0;!a0e1EFf3F1i3ClBs0;e1Bn21BC;!aEFe147i44A0k1o1;yC9;aC34e374i6o535;h208;!i6s5E;!i10;n58;!e4i21o10s0;c28B0n1;oD9;cD3l3At3B;b622mA5;a4C9Bc1F52d2285e4D5Cm243n1E61s2B7Dt770u398Fw16x1B66y28;!a1e4i6lBs0;!p434As0;e8Ci71y0;r2EBC;n2o1;iEl1s218;!e9C2i6o0s0;eCE;!d2163e23i9C6m3653s50Ey0;e24t1CE;b1C0;g50B7;c179;d1335;o6Fp5F;k3mB7;i172E;e467i1ECy0;aCe1i7C3y8D;c9E6l34F5n6C4r158s473Dt84EuBE;a0eAoD;aCe5n2s8;c18CCd49EFf1775g2ABl24B9m4435n4BF9p2BE4r5021s4483t1F9Dz1D36;aCk7;l424;t39D;a44FAdDA8r1;m374y5;mA19;a10t3328;!a30e4i29Cn115s0;l4908mA34;e388;d900nFsE;f993s3421;!rFE2s0t3240;!l0s677;cBe1;u2FC8;f3lC;h3Di4;pA73;!e4i3BCCs0;!a1A3d814e42s0y98;!a31CAd3AE6e1g246Ck1m2En4A6Eo4AA8s0t1;a3935b19C8c3FD8e2E0CfC37i4A41lC05m1C0o3001s38t2A3Bv4F31y1A5;d3Ar2F;!c1g7ABi147l0nFp2220;!a2B7Cs0;d0n82;a284Eb188Dc484Ed2EF3e30FEf4EEFg150Ck34A5lDC6m26F1n49D0p3063r223Ds477Et125Av38w1E4x4EBDz3451;a291Ae195FlBD6m4DB4nAABo1D05r3746s139Au2DBC;i25B;!e77Ei6l3s0;!e148i337s0y0;yA1A;c0s9At7;!eC1i6s0;k34D;!aCe1o29s0;b3424;aCeAi1D2Do541u34y0;!a299r1s0;o93rF1;e177A;d38e1lBt2FF;a20u69;d0nAD5r1E;m1t70;m70t1;e716iCA6o9B;a27F9h24E9i2By0;!o29y0;i51uF;o29y0;d4Bg3B;l218A;!i71o61s0u34y0;g2D12k848;n523;r25y16;l0n9AC;e15i1BA3lBo0u3Cy63;r4D80;!a2F7Dd138Cg11Fi495o4285s0;!aDADo14;n25t11;a9u14;aE1u14;b4BD9d2D0Eg179Bi2CDBj2DDCk3B2Al2E1Bm3847n1E7Ep37AEr3511s3755t237Ev110E;j0m3;c13DAsD1;a13D9e2943i32F1oB5Ar5Au4955;l1288m3214r1sC0;!g4F9h1s0;hDC5;!a10e1037i402o4BA8s0y0;k851;i34C6o256u1DE2y63;gDBl0;e1Do4134;i347;c242o128q7D1;aE2;d7t1;!a39D1eA;h295jDE;a0c11eD1n3u43A3zF2;o36y31;b8;l2109;r4E11;l1FA0rD5B;e26B2i6l214;eAAo97;s4C0;a2EA;h18B4;a2893e120DiFB2;a299t537;c12AdC2Fj552l11B2n347Dp25Br2C86t3E85u1FD0;l1B65;!d0nF8s0;e1h27;c1Ce23n2s11;n2s14t0;r4AA0;eAi6B5y0;!e24iCCy0;eAiCCy0;tB74;g1D4E;l147r392Au40B;!b256Ed2AF8e2CCDf707iB10k48l3443s306zDF;!e551i8Ey0;m2954n1D0Do1A7;r19AD;!d0l1;eAk1;g474A;e3Fo29t62;kAA;a51e15i6;a26DFi250;!c16Fs0;a30g47u19;eAh460i6;mA70;d1El3Fs0;!aCi13;!e23i21p29D7s0y0;!c612e4E6Eh1692i3499p5140t1AECu4EB2w3658y0;!b43Di6n22;e111;!e4142i6m2Eo1;d3BD;!e4f37s0;!g5Bi25mA1pADAs21FCu5x330Dz49B;p1Ct11;e2FE7i47E7;c92s19z19;e77A;!w2C1B;!e4E67;aD95e205Di4B9Ao8ECu1B3;i1F3E;!cBe0r7s0t3;e3857h3C7o30A2;i32Au32A;n2t58;!b29c98e23h109i21l283Cm2Er52Bs0wA8;l157s4EF;a2FE5b1899i4233o21AF;!l0s0t3;!e40i42Ds0y0;d0l0r2F;q882r5E1s218;tC3;aBEi1A9Cy0;!e134i4D7;!s0wA8;!a1DfBFn4B62p21Dt1EvBC;d1C34;!e4i460Ck105EoE2Cs0y0;!d0mA5n434r1s0t0;!a246sA1C;g12ADl1r4894;c33FAd5018gC3s3B72t4C76;!e551i2B87;e1n2o9;e3E5i199y0;i5n46;n437;dBn4By16;e99i1BFo31;c50BDm56n173t0v3;s5w0;!a4178c236Fe5012h4236i3669o2556p2440t4D33u492C;k1B7;d0r16t1;mD4;!e5n7s0;e432;a20o46;a5075;i7Cs45C;d3FEp324s1CE6z7AE;i1D9o81y0;!g78As0;d0l39;r1AAD;!eAg60i6s0;s5D3;!e24l22s0y0;!p27s0;r3CBB;e17o983;i3120u5;hEi35;l127;l0r55;!l0r55;a4A5Fe47EEh2051i259AlFE1o4FA7r2D2Fu4BABy3CE1;o2Ay1;n478C;nD6;!d80m2Et27;cD3p2E23;!a72s0;d181m175s0;i1E02r4C48;a3B95;!a2886e12gA9h40AFn381Fr52As0u2DBA;b5Al1EF1oC7Bt5Aw1;l13;rF5;uD1;e17i8D;l36t47;a1BE;!f37s829t227w172;e5iCA;uC7E;!aA2;a187E;t382;s5A;c47C4e3CB5f49C3m1E8An1B5Ep3237q3924t389Bv4D55;g18Bn65;!l6Bs0t1AD;nAFp8;a12r1;z82F;a4B8l4;a33A8h2DB8l1E5r4E5yA06;h59A;e504Fr370E;!n1A6s0;a40i20o38F6;c13En2Cr3DE9;m95;s1AE;h2B;h115;!h1F;a20CCr3B0C;e15iC8Ay0;!l3AnEt868;a176e23f240i6l1CEm64s1Ft31F;a1D0;!e4i6o284s0;c8D5e68;a30eAiCBy0;d1i31;l40rD6;a31i31;!eAi21l1E0;r627;!d0l3CCnC1Dr183Cs0;a143h15E4;aCc0e5s14Bz3;s35t2AD;e0t11;a21lF93;!e35Ch0l7n22;!e4i2EDBs0y0;r4s11;!a2AA1e2598i6l22o3B3r17Ds0;d16EF;e23i6t41EF;l643;aB8i1Dl2C4m2DAr3FB8s83u4709y0;!a3666e26Af530h1CEi1E2El1940m5002o20A4p333Fs397F;h90;!oFz2B;a63Bi0u5;!d0l42A7r1s0y0;e195s0;nD1p234D;e17i20;e391i20;!a17e518i259l7s0y0;c17A9;a266e23i6;a4DeAiBAAo12t4AF5;c664s5;a1De23i3C66o8C;eDl7n2E1;e0hB;!a20Eh1n2s0;!l0s0t18;s750;u70E;s121t1100;a1CEEe4148h4C97i4AC1o3317r3E54u6E3;e1v3;e6Eu2CA7;a266e2F08;c1Cn2;aCi40B8o471u5y107A;p45E0z55E;!a3D84e4h1919i36n22s0t0y0;n16r0s8w90;!a363Ee4DEg44i5F2k391Fl7EoF6r2B77s209Ft135;dBe5nB;a1Db3707c46DCd2093f40A2i11CCk5ClA69m3D3Bn4685p4D6Fs501DtECAu2B2Bv15D1y4864z14E6;n69E;m865nF;c15DCe1i18l50A4n22o29DsBy0;eAi6o1;!a3F00eF23g4411s0uB;!d0n850r1s0;s0u14;!e24h109i6o284;!d8Ae1B8i31Bl7s0;!a97;e1Bf240l7s2EBAt58;a40e10E9i3F9Dl3B85oD7r44Bs3FD2u2A8E;n4503;!i27;d464Cs3D97z2C;l97A;!a245d0o29s0;!e15i6s0t0;iAA1o4AB;c4Ag4AnE;!d0s0y1;n4B07s19DBt4A9Ex46C5;a505Ei27y0;r78s8;d3An19Bt135;e59n4B;e8F7;a785e698l3934n4564o10w1;!e24D4s0;e12i3Cl19;i4m3r4;!d38n1D93s0;!e1h48ACm1p2388s357t49C5;!a4Be4i8El6Bs0y0;h2B01;!e555i267Fs0y0;l40En376;!c2D0fC2h109k48l22n3ACs0t0;a10c1e1Bl7;!d0r4EDs0;a2D6e47F9;!aE6Eb213AcDFe4568i514Am44D4oE8p19DCr131sBD7u45D6;a36e1i27o36;!b2689l76s0;a3AE1e3621i2841k2F67r3u3F37;!e40i91m2Es140y0;a1De30i77;!eDi65r7s0;!g7Bs0;!a1b1A74c4E41d20EAe3A1Af179Dg41C1h4C73jB33k44l3FBAm3BC4n2939o22B2pC4Er2AC3s46A6t18F2u1A75v2A75w47EAx2AC1;!l0r0s0t3;i1E63o0;e4174i168;d0h0r48DCsE;e0k1lBr4BF4t4EFB;o1260;!a4De4i6l22s23F;!a4Be15i2F0l203m2Es0w80y0;a3D99e12h1660;a0c0tBu14;!d0f1F1l22r1s0;!a3B77e1FBi67l22s1111y0;c1BD;e5i50C5k1;d0e3A6Fl1n304s0t1;!i0n8;a1b6AC;e1753y0;!a2EF0i4A42k5Dm11Fn89o2B1Bp1632s0u1D9E;e1Bn2t3B;p3A0;eD3i3C38;sC0t1053;m0r3;!a1EAg132Dl1506nF48p8Br1As402At1vEAC;!a2C2Ab29Fc1F4Ce17EfC2g4CB8h2E4i3319l3239o23AEpB1r61Bs0uB6y0;!e4i13s0y0;b2048nAB3;aCe0i288;a51u59x66;k1Al4CCD;d4A78;!c16Fi31kA51s0t186;e600i6o10;e40i45A9;a1e22Ei58Al5Bo10;d0e1n0r1s0;m92sAC2;lA65o194Cr17D;a14FDc2257d3EFDg4EA1i26FDk2ClE68m281Dn4C79o3E5Cp2402t2239uC99v1FCw3C69y0;!e0l7s0;!e1Do10;f7nE;n31E8r3C8;m4A3t23A;eAi6z476;a3C3Fe3225i1E12oF22u3F9C;!b1Cg403Cl1n65s0t3;!s0v19;!e15i1C5r4Cs0;!a2D9BbBe6DCfA81m276Fo1F0p18BAs0;t206;!a976e3DDi6r58s0;d0r31C8;e6Ei9EEoE4;e0i31;c2Ad89g3CBmC77n4287t9C3;!aA2e68i21y0;!g1En1Es0;a4By1C;!e15i21s0w172;!d5B;!p3C59s0;h3k28;cB2eB9i23A7y0;!l129tA8;a0i13o10;l0t84;n1t6D7;a2D9f240p443;!e169n119s0;i1o3B;e30Ei6o35u49y0;a25u26C;!t70;b89i4p51Bt23E4u26Cx4EFCy28;i39D5y63;!l7n1Es0t1C;l33Fs3;oA83;a45CAe1457i1B46o295Er1DA8u6E3;i291F;a37B2o2650u254A;!c244r122s0x500;!i5FEy0;m374;o1A9;!c232d0k1p28r4BB4s52t2B3w768;d3Dk53lA7m239Cr1E7DsC0u3385w0;hC8;h209;i9u5;!n0r16s0;m16B;!a1Dc18e1hB4Ek4C77s0;r36B;d0r40;n22AD;c83r71E;!eD0i21s0;!s0t519;iF0;l12A;!o54s0;u393;n229Ft502;!e4i426s0y0;tC8;!a2F32b58Cd3F33eE7Bi6l2F9s0t11;!s0t50E3;e1DsA4t91Az49D5;!m64s0t3AFD;o451B;b5Ci3A74k4AFEm1A;a42B;e23h66i43y0;!e0n0s0;!e0s0t10E;aCe0i0t39;e1r39;!d452Cr40As0;!iBs0t1;!e0l0r2Fs0t3;o2DC6;f1F3tB18;a61d0l1Dr3C5E;eAi43A;b252Br2CFF;i3315;!e4i6l19o9Bs0;a4A19e3B4k48r28t141;!e332i171s0;g1B7kA11t38;m0n2;a315i250oE8s3A4A;!e1i5;nD42t0;!i4F06s0y0;aCs3t7z3;!lBp465Fs0w136;uF0;!eC1i21l7n22s0t0y0;!d0f37n8r84s156;e17i58D;e122Fi2By0;r1CE;eE01z185D;a53o1B0p923;n425Ar1;t38DF;n197t14C;d87fBFt13B6;f1B4k37E4rC75s4DA9t3CDFv2B;g3i4r8s1B5y1;a1b98e2A07;p22D4;!t62u159y48;a2E31b4B56d82eE8Fg0i0n18F1y28;!b3429c1DAFd481Ae20E1f481Dg1EB1i425CkD7l4B86m21C6n2D17o3C9Ep3F1Ar339Bs4896t3DC8u2804w3497y2A34z1F78;dA2E;!c3Bs464E;e26C;!e134i2CC8;!aF5i1Dl16;o450F;h60;g190B;r1321;k42AC;!d2CC4e49DEg6FFi4C40s3835u1;g348i4t1;!l141r1s0;l2C3;m5BvCE;!a363e15i5132n1CE8s0;!eDCm2Eu49;l3E7;pB4B;b39CCf562i1CFp4A91r95Ew2E81;a20t13F;b1BAsAEt0;!e4i6l28nA3Fp48s0y0;a4De23i21;i20Cl22B;b7Br25t19;i4A04u1F9;!b4EAEe3C18f61Bi1FECl7BDs0y0;!eFBh4BE3i6s0t1FF5;aF15e1DBDl3955n3A32p84EsCA4t20F5w1EC5;e1465;!s0t40;!e1iB8l3344s0v2632;!a1A71b3D4Bc463Bd62e420DfC9Bi2EE4l3C4m6FBo16Dp4798s0u697;e824l0;l3CCs181E;!a4398n2315p9A4s0;e1Bn294;b1535g15Ar45DA;aD7uF57;eB95;aBEe1;iCD6;g9sE91;!eAi27y0;m2442n285s3BEE;a220Ao46;n481;d1Ek1E;a63F;a0e1Di42Do4ECy457;l4607n47F1s15F2;d31A6e0k3495l588m462An0r1E35s1CA3t4DB9;!gBl4B8As0;b1098c362d18C3e3095fC4Fg74i17An4C00r500Ds22B1;a472Dc11d3e239gD23l2BE7n3651o44ACp1r323As4029t3ECFu1E9v5Bw1xAE;!l60r3608t4031;!t634;t634;cEr1FD1s1B5t29E;y3AF;d39s3t60;a448Ee223Ci3444o839;s66t1;n2t61;i379C;a54i91o6y0;l866s0;!e5i6n3o12;c1759h335i119Am2446n34E7p68Es3ED4tE69;a51e1;h39CtBA9;a44D3r142Bu1;!d0i6l2351m1DE7r1446s0;!a3Cb78Es0;s9At3;a3539b19F3c44B2d3148f35E8g13A9hF6Ei1CA4k3DBBl2D8Am2E65n4E2Bo3FE8p8E9r35D7s4C5Ct320Fu4D22v4F1FwE8Ax4336y408Bz3B;cBo10s66;e8Fi0;u4AA;a25o14;!i13o9s0u3y0;!sEC;d669g5Ck28l739n1221o3757r5089s3147t42CB;sEC;cElB4r25u255;o3F7;!oC;l28t0;l141t1;d14F9h1i49C6n4E45r284As46FF;!b1D5j4EC0k2A39mDFn3ABEp165s2AB8wA8;!e551i8Em2Ey0;l1A0n210F;k4Ar9t8B;e136Ei6;aCe5i13;d1427e5f4C84g4715l6E0m4147n46AEp4D08r1875s3B7Bt41F6vDF0z1860;a59e15Bi65o49;eAi30DE;aDo6D;e214;k530;e88B;g0n267;a2D2Ae86Dr244Eu2E93;c70Ee0h1Fk48BB;g12DF;a1673;mCDx4C;!a4EF4e207h227Fi69k4ClE0t131C;!a4De15iCCs0y0;a29Ai5004oB61u3843;d282n2;c3BC1k0;!d0r1F5s0;e46Bi700oAD;b1E4g8Bi1s4D01tEAAu0v1435;!e25Ai132;!d0z3;!a4De23i24EuB6;!eAi4212l7s0;l3525s0;!r2357s0t3;a45BBc1434d23Ee3170g9F1h56l3565m3nEBr3t1B7Bv2826w3EA8;c92h33As7;a1A4Cd295Be4F56h24F5i4A4Aj3987l10FmD3Cn4067oC30p4770r3DCFs34C8u1103v3F14w98y3967z20BC;!b1Ae5s0;a795h0;!a4Be10C;!c3296d3E5DgE59iF68n37As44C7t43DB;c11i9;!i4Bo1;n37CB;f4C06n158s41A3v5D;a3F62e3166i21l28o9Br2591;o1A2;l1r3D;!a2661b4183c17FEd2462g3322l1A97n4E13o514Cp4164qC3s149Fw350;l6FC;i1s1F;t672;!o32s0;a1DD6;d0rA88;a1b1BAmA17n114o2FD2s2F8t1BBFu4FECxC0;!d0rE5s0y1;!oDs0;eAi2F5;!d0l22n1C2r180s0;!eAi4743l44s0;r4617;e5i2828;a30i1D9y0;!jFEpA9s572;d2D3r4;eAo9;b11ADc971gE66p4166t8B7;!aCg1i1C4Ao4DC;bF8m89p2F2;a19Ae1n61pA5s190z0;!e25i6s0;n76;aCe1g0;i2BrD6y0;!d26CEg4Ar28s0t48;!c4E6n2t487;!eB1Fi6l22s0;e10AEi4734;!e15i43o12s0y0;a1s0;n4FF6;a31AEo493E;c83gBt3;e3FAE;c13AhF2;l48t0;u3C2;!a34e479Fi21l7Es0;a1eEm76w1D5;g1Ek1El1CFn145r1175s4E19t103y1E;e1102i2DA9n3D85;f0t1;r65At1;i102Ey0;l41rD6;a336De459Ef8l3277n3638r3646t3308w28y3265;!a1502c1782d3023e1246f2C09g439Ch4E3Di2808j34EEk2E5Fl4E5m20CAn4DCEo1F60p20DBr4A81s4BA3t17AFu4B8Fv3FC6;a1m6ECr4448;l0n4237;e4B64i2By0;!d41DAp374Bs0;!a270Bc4D1AeC8i4l47EBo12FDr475BsAF1t2D18uB6z1F;h39B7t2969;a7u5y0;d282f38gA4;!d3Be0i8rE;pEv1D6;!e196i27l53s0;m3B99;n1s36A4;!e290oDs0;!a1422e4C4Bi124Eu5E5y63;d0m3;i48C2;m13D;s2924t42D1;!i154o16Ds0y0;l1424m2067;!iBAo17D8s0y0;s0t11E3;c4103sE;h83n28;a1g1A4;e6Ao420;!e0l0s0t3;a40e32C0i31;a1971l4m54FsE;e1i13u14;!i13u3;m4C4r948;e2419l44s2699v2054;d27n39;eDi11FA;n258;d1675r48s1CBz1CB;s1DE3;a4BF1b3BFCd4B03e34CEf1590g1491i3695l338Em408Fn50AEo50CBp1622r1E5As3057t3D3Eu3164v26C9w3F04;t1w1;b44tC5;c1gBi12;!a433Db4771e487Ei423Dl4AE9o4F36r76s0u4232;!r419s0;cEd0r1;e1Dy76;d0r60t0;u255;!a20i3Ds0;a1De1E55;a453Fe9;c1A7B;e1846;a3FEBe72;n19E9;a660e1i34;s0t1E7;o40u49;h1B0;!m2Eo1;i4A2;c0n0s3z3;a1CACi2B15t7u34;a30e23iFAo8C;fCC9l44;b1Cd41g3;d41s3u5;a256;a88e284Ci9E2o1C62u34;a14B6e2D8Di35Bo1uB6;!aD76e15iACs0y0;c9C1;t1u5C;!a40e1FBi6s0;d5D;m64n2A7s3t443A;l62n34Cs8;a14C2;!n1Es0t0;l34Ar758;a4D52r292;g3s3t1;!a88b3C91c5CCd97Ee114Ef49D8g1C12h2E4i3l219m48D9s3352t250Fv465w2F1y0;aD8;!aD8;d0nEt1;eEi71y63;l32r25s11t61;b1CgBh1tB;n50CEo1A7;e95o93;o4F91;!a1D1d0l3ADm64s0;i31o1;c2FCh82;a7Fe25A5i3C;e1C09;a1i3220r1sDA;l3Br1;!a4Dc1E5e4f37i620l27E0m6FBr1B1sD92w275Ay0;aEFCe668i50ECo128;a6FAo46;l3n2o938;!s50B4;!a1207d227e16Ag6FFi1CDDlF3o3968s42A2z353;n2A10r1Ay1;eB8i3B17o11C;r2A1u12;gBn2F3;a2E4Fe84Ch440r46D0;i4n3s3;l913;a16E8e306DiD9BoE4y0;!a470Ec536e1i250t48;d0l0r1s0;a51l2FB;!m2E36p5Cs0;!a63Fi3F;aCe17g1;iCn14B;h52F;a6i6u6;a869e23i6;!d0s293;d3n2;!eA74i6y0;aCiE1AoE8;!aEE7cBd4217e4991g5139j9Fk1C52s4589t5Cu1C92;eB8i6;r7t1E;r78tB7;a50i3Cu1D;i2BE3;!e5i6n3t0;!d3Ai20r58s0;!jFEl202pAFBs0;p2C;a28ECe3733i383Cl2CAEo18B6r3ACBu3ABB;!b2F7Ee50D5i1D9Ds0;!v7;eDl7n2s696;!e4i975o50s0;g678;e1EoD5;a17ACb5121c24DBd2B97n2879o3E97r1700sF8Ct4554u23C5x3C70;c3F8;aCe1tDBu9D;a3111eEi2C7By0;!a7Fh475;!l2B4s0;e6Do2D6u50;r44E6;i4F5r23C;!aCe1D59f1F1i3826l22s3EFCwB4Cy0;f17F;!e5i6CFo46s0;bA62e4895i195lE49o174A;c67As102;!n297r468Bs0;a51e17n1s11;!e15i43r35s0y0;a41Di10Ay0;l5A1;e1i0;a0c7ADn22A5u14;sD3u5;r6ADtC5;!i354Cs0y0;a0x0;a2185d2D40l2E67n316Cq711r5C5s26F3v29EBy1E;d4297;a4DeAg0i24E;e4D10i259o57;o2E6;!d48h109i154s3A97y0;a3BD4b3999e2952i2B49n1183;yB8;n749t1;dA2C;c62i174k2Cl35DF;kDE;g5BsC0t2D;c3370dC49;c208;aEFD;p943;r772;d1A4e485Eg6C3;!e4h2946i6s0;l321;a1n3;s2DC8t2Dz47;a4Do29t354D;b29n6B;c92nF;l28mB5r448t48;a25Be1i3303;h1Fi31;u144;n88;a1640c45Be2CD4h207Bi4495o23B8p3E72s1771t2A0Au27B1;l866m1s403At316;e5h4F44i1DDF;!a2902e2536i83Br21B8s0v1438;d0rE5s0;!aCk119r7s0;n192r62s4B5;d19s8v19;!a2BF0e17Ei6o10s0;a456Ac16DDi0o28sB2uB79x1F;i683o53D;k2527;c0l9Dn2s11t3324u14;e5nFsE;e52;o1FE;!d0n16r731s0;!b1Ce0g3n70Fr3A4s0t2551;!d0f1r1s0v47;!i1l109Cs0;!a7Fd1e4i67s0y0;a3E2e1i286u14;t2Cy0;e824rF6t218B;o12p1C;lA2F;nB4;c3CE3r28;c48F8;e33i6;!b49A1eC4Bi21l1B6nF3s0;e4B9;r55t10E;!e5i18;e5nB;e24n2s35;!l7s1;!l7n22;!b1Cd38EDl1F63m4FCn25t1DB0;i25m1A;n8r78t3;i34vB;e0i6CF;e3DBf37;a4DeFFiBAl44y0;d0l34rCEs0vA1;!a409Ee2890i14BBo1s0u4E;e5l7n2;!g1932lF5n3CD2s1CAFtB70;!d29AEg2CD1j3A8l406n4478r166Au11E0;r40F9;!eE14i6s0;m25B1;a468l10DD;a172Ce46ABg28k28o1EB5t41;nCFo29s3;e561i5;i8FrEsA7D;zBC;b5Cc71Df140FlBt3B5D;aCo10;h84i13y0;c1497;f2A36i34F9;!a8Fd0hEAr1s0;iCBo6y0;!a88AcB8Ao4EB;!e6E4i3l7s0;dB1q500r4DFD;cD3g44Fn8;!b1DDe4i2F0p5Fs0y0;t973;hD37;w242;n0r1yB;u968;!e4i40A1s0;i343B;a2BEC;!b43Dd1681g62hE0o31r7E2t4AFw1C27;!a4F49e2756h1i154s0y0;b1356;!e4D05h3BAi21s0;!e24i6v4B41y0;c4140p717;a6EDi21;t15C3;g3Dn17BBy0;!a16Ae2E71i1D25l2Co319Br232Fs0u286E;t4885;!a20o29s0u34;r47F7;!e24iB2C;!w960;a346B;a358Eo6C;n1s0;n1s1F;d0r0s8t2F;e1f7s14t7;r136;oAF2;u253A;s31A8;c53E;r8s5;!e92Bs0;!o1p413As1BCu1;i2Bu14F2y0;e1r5A;b2291c4986d256Fe1F75f40E2g4EC2h23DCi3BF4kCDEl1686m1CA7nDC3p46A8qB0r33F0s26CDt3AC0u3075v4354w3E31x4639y42F1z284;h35oD4B;d39t16;d56e501i22Fn4B90;c37E1g5F4i163l4C02m18Fp1FFrC9Fs723t3B78x37AB;a6B3e40C6i2803;!e134i2DCl7o46s0;!a45c3B70e0l55m14B0n3A1Bp1AEr1834s17A6tB7y28;aCe1B8iACy0;g128n48;a4539n142;d0r1w1;n36r1FB5s9E;i46E4;c3C9e1CF1k2558;!fC83gAC5p1865s0w4FDy0;n0rA7A;a3D75;a315e3Fo36;a0m943o9q907t4C1D;o4r2A;fD4u0;d3FD7;d3050;!i3450s0y0;!e4i20Al1Es0;c11l16r39s47;i3158;dE2;a159e41B0i4648o9t0y0;r60tB7;!a29D4b2C2e117Fh124i620l44o1Fr1B16s16F9;l3n1;b7Bl0t19;h56;!k1As0;!aCi20;b4D5i1CD6n84;i168o56;e50o8A;r80;l794;c32d422k327Cl3A02n0q11Dr364Ct4A;z4276;n614t1;!d0i6l7r0s3E;e25A;!e25A;a28BCo73D;l1F1B;e148i86l216o128;!bF4Ce1Bi3CjFEl430Dm10BFn22r52Bs0tF84wA8;!aCc14Dd7B3e51Dh14Dl0r1s0;!a88Be9i21DCo3C01;c4AwE5;n16o10;m152;g39;g0m3E3n1437r2221;o84Ay369;e71B;w481;!s0t3AB3;!d0l1n0s0t1CD;e83i2By0;lD3;i2BoDy0;!e1Bf2Dn18A;!e183Bs0;i6CC;n118r12AsC5tB;d7t11;f4BB3o0;!e4i6l4CFs0;!a29C4cD70i4901k3D4AlBm2Es0;r2AB1;!e3EA5o1s0;aDBg47iEs12B3;a12n1A1;o13B2u280A;i4F2;!a2026eAi24Es0;g1FC;!g1FC;!g4B76l2C1s156;e17i223o1;!d3Ai6r1s0;!a4De28ADi6;t1D30;bDFgA4l21C3m2B80n2443s1D83t31E2;!b1E8cDFd7FAh183i15AFr109;l1n1Ep35r7v19;n29E;sBC;e4A;a4ACFe2167i3168o4C49;e4069o54;!eD0i337l3CD8s78y0;!c1107d465Bs0;r19Cy305;k3305m1;iBD8m7u416;e921i43y0;!aCe33l3s0y0;!b4E2e6Er163Bs19Fu703;a4502e279Bi4563o40F2u2717;e28C1i86;!i286s0;a2F7o9;!a4B4Fe6EEi3244o3AEDr182As0u1F47;!e5i21F2w2547;r129Cs3u32D9;a196Eh1B9Bo3918;s3EE;!m2569s0;y21B9;u6B9;r149;i25u5;a3s0;aCn3;m14C;e71C;h8D7m0t947;g5Bs1ABu5x1AB;r38D0s43EDt1uEz497C;a4C2Ce82i4215l1A2o46u5;t3F8C;h23C8;a4474n2p4F1r360sF88v121;p190;c3d18t0z18;g22BD;h378D;l2B53;!f183g56s156t1B7C;!n334s0;r41Ft197AvB;c121n173;a1Dh122E;iAB;e1t436;!d2D0Ci6jA8k0m3372pD3Er12BEs0;m4969;cC3eC9n5AC;h19D3k0o4C27;e392E;a1De3B4g2CiBl44o56;!fBFn3s0;aBBC;!n2E32;a1AE8;b1AeEn7;!a3BA7e4i3F52o1F0s0;a4FB6e218Di4317oD91r260BuEDFy7A;c9Ed167El28r28;aCl0;i154l44u8y0;a43B2e12D3l2CoBA0;g0i259F;d0l550r16;m99;cEDk16;!e26Ai6l349Co10s0uB6;n55rB;!a7Fe4i6s46A5;g2AD0l193m4158n92p1r2ADCs8A4v218E;i8B;d4BAg1618j1Al48CBm45D7nAB5r400As30AB;a5043iEF8o56y29F3;!a10b303Ed46D2e25DEg1744h89i2A3Fk18B1l186Fn230Ao3Bp28r32FCs28ACt4CE2w37By63;!a4Bi3D0Bs0y0;n20DC;c1929d6E5k1BAC;!a4Be3383o36s0;e5nFs11;i4373;!e1Bn2;eB3n213;hF1;!d576;a1C8Be1217gF3CiECBl1o3B73t3E67u2E76;a2509e4C1Bo97;a1C8F;!r227s0;u159v62w128;f10B;!a12g1CBs0;i3D6oD9;e39Fi21;!a11CAe607iACm2Es0y0;c0e5s14;bC8pBF9;a179;i813;!a1o88s0;!a3CDn0r1s0;i72l5D;!e23i43p119s0y0;n1A6;n3180;t3540;!e3B4Di21s0;aCoC;e1i5p2F6FsCAt211E;e2038;a1De24n4DFt5A;h19C;a9l414En334r1Ds4Ct536;!a3533l22m289Fo3D5Dp3327s0;!e15i21l22s64F;i880s0y0;a4CACo21;e30v55x1F;!i880s0y0;n3y0;!a73cA5i6;!d0l729r1s23F;d78l3Ap1Es35v19;e1Di13;a41A;aC06i7DF;a266b56D;!r119s0;a3e1i15DAo231;aE18e102Co420;e4A6k28;g27CF;!i21l7n22s0;e3BBEiE4o12A;!a36F9c1B48d4C72e424Df8A2g456DiC8Bk345nC95o4083s3199t4A0Fu1141v144Fy32Cz1C41;!e15i21lBs0t0;a4ECEb2F58i3DF8;a7Ci71l1t28y0;eAm167;!r5Es0;t394;d0n1r1t16y0;!d216Al28n58r1s8t48z1B61;!e2BD7i1118s0;hD6;r47D;!e1B2i6n3;e687i6l19;!aB29g3Bi132o1s0;!l0r55t3;!e849i6s0;!s6E7t2D;i3F0o393F;!e1p442C;!a1DDEe4i6s0u4325;a1A7De2E25hF7Ci13AFl4A66m12F1oC0Ar10CBt272Fw3E00y28F4;i10nE;e457Ai21;e3909i6u49;f4062v2B;!e1s0z21BA;l2200n3084r193Bt4A0C;a174e387Bi2ACo535;!k5Du2012;a4E6Fe49CFi189Co4C04;l3DC2;e38E0s1Ft1BEF;r19t1;a21F9e9o4CC;!b138e4i6s0;k4FD5r2684vB7;c0t210;!e0k1l22p9Br4D86s0;oE2;n27;n1CA;a17e279Do686;i3Dk6B;n196;!c1sE;iE7n13C1y0;c1Ce12k4CnF;!a0c34CCd46FBg4760iE5Fk2F65n98Eo45F8r95Ds0t3053y3194;a49F;!d0n4349s0;o12p38;!n0s508t1;!d0f37s0t20;a7A6eAi6o69u6F;i3E02l3B30;o108wE5;a159e1FBi6l44;a30FAk1o4F6t0u1D;t22DF;nBs919;e23i345F;r117A;i4D7;aCeAi4EEDo46u1Cy0;!l0pC6s0;!e1Bi59Fs1AFy0;r1226;!e4i6s0t0;g1D7i20;!g1n38;!e15i35B4l7o12s0;a405Db4375c45C6d2A0Be28E4f4DCAg2F37h3AB1i35CDj1D16k2833l2553m38D5nC5Do2791p2286q1A70r181DsC3Et2CDCu3F89v242Dw2EF9y32B9z4717;m5Ar7;!mCDs0;a5118e3020i335Bo4A52u14;mCDs0;n2AE4;n28DE;a3CF8;k2FDF;!e1209i6y0;a1EEe201;!e148i6s0y0;a4E37;!gBr25s0;g1z3;d333B;a0h2EF2i111o9;l44o72;i20o695;l1CFCn3r1662s43Bt3255x36B3;g291l4A94n37Dt1C8;r6CB;!aCeD22i31E4o1;r2585;e166f7l7n2t7;!t3BD1;!a421oA2r418;!e0n471s0t19;a461e9;a7EFe23h4E0i4A6Fu34;n373Ar13AAw0;!d80i6s0;f141;i19AEp4D6Bs89t18C8;iC00y0;!e15i3E4s1510y0;a20e1o285;!eBiA8Es0y0;e4C53;s83t61u168;c92l3o9;e1C78i199y0;e0i123o29;i2AAu464;!e4i2D5Ao29s0;a8CE;l147nCF;e5h3lBo9B;a4EC6e4F0Bi1E6Eo425Bu4361y475D;aEhE;a20c5083;a110Ao195;n34Ct10E;e1Bi6;e112i6;g44iDs1Ft2485uB;!a1D1e1l5Cn3DAAs0t1;a0g0;a13B3i2E3Bo43F9;e1Bl7n18At83;n4DBC;iA56;l60t3B0;b3E6fAE8l1C6E;l4799r15CA;!c9Eg2Ck48n89s0;h5Do167;!a24A3bFC9c35A0d3250e1400f119Dg37D7h286Fi3A4BkE4ClFA3o40DEp2936q30Dr3216s4CB4t2CE5u4F6Av4267;k0t11;!e1i18s0;hEFA;i21o1ED;l106;l3An8t56B;e3D26n0o9B;g19l1r234;i4773l44y67A;e5n1B8Es11;h16F;b3A1m38o936;a18Ed5Fi48A3o29;!h33AEl7Es0;hB12l5CEo25;aF65s0;d0m3r1s0;!d0m5Fs0;m2721p944;!a1De916i19BB;!a2560c30Ce45B4hC62i2099m29o39DrBt4C41u4DD3;a4AiBy0;gBi1EC4o230E;!s0zFD;b1g1B4k67Bl28p229;bB1c2092dBB0f16FCg24EDh28i50Al101Em1B64n2D7Ep3F23r137s1E60z3567;!e15i652s0y0;e2CD8u8C6;u3982;n1D8r1t1;!a1i9s0u5;d0n1A6;e0i288;v134E;!r1s0y0;c8Bs11AtD2;f1F33t2C03;!s0w28;a575e42u34;a185c0s19u14z19;!l1n6D7t3;i6A;n549;!d0l0r0s0;!e12n277Er4866s20Ft4807u515;i3Bn18;a3C73e4666o1BA;!aA2e153i2D1Do72s0;e1Bn2p1EsEt2A2;e1447;p3Bs52D;e69;b2Cl8D4o83u59;l3097n4;cB2e1n1EFBs27A8t2Cv50B;a47DBm340n1ED2s145t21D;n4637o3778rF;e883;e305o4EB;gBn1s169t61;r1t5B;!e3Ai110;e5s2Cz2C;!a0l7s0u14;!c18Cs0t8F6;!a4DD7e1138oC3Bs0u6;a4B1o7;rB53;!a4C8e4iFBDo433r30E1s0u2CB7;g6E5k38;t2405;a176e3D3Au3D;n61p89;!a75e4i17B4o6s0u14;!d33Fl0;g3BnFr0;!a4Be15i6s0w80;c1765e1;e1i1936rBBE;r464B;!a2AACe15fC2i21s0;e1BF;d88E;!d0o130r1s0;d0n8r1;e68lE3nFo29t1A;g2Cl1CFn4D4Ap4F1r3AF4s1F4Et3u3E6C;aDeEBi9;!e4i43lF4s1Fy0;b3AB8;a9e4ADi21n0t5130;f7o10t19;!i3071s0;!e31;p2C98;nFo10;h68F;h1A2s4CDtD2;t7y0;a50iE7m243;a30e30;!h14F;t210;s2A8;g58i27FBk1A60u40A;!c3017e4E25h5142i6l18Fs3715t4CF2;r47A2;!a0dA4e4i6s0;!a17DFe3E38f68Ei2164k14Fl206Dm1134o38C5pC7Fs31C7t3A92u3C28y0;k2BF4l3E45n3D18p90Dr2FAEs1E18t362v308z38E8;!i56uB6;e2ECCi323Fl62r1F6u126;a20i0o36u5;e989i20o29;a189El12FCn4DD6o4DCDs1F;p27sE;l3932m47EC;a3B8Ae26Ci293;a3711e24D7i2776o1BC6rFC5u8A8;!a2C27b6B6c3387d21Ee3D83g50C6i3416j1D13k437Al20C9m1AEBo25CDpB7Cq4CEAr22A3sBC1t1B89v170By363Dz1E7B;r25sEx1F;a32e46FCt717;p28r3C98s1FCtEA0;!a59;a4A16e3EAAi24E6o3D72u102B;a19F9;nEr39;a8De9F;g2F39;!c11gBl0s0t3;!l985r39;c181t0;n170p35;dBtB7;n1r28;!a6FAe2224uF0;!e24i6y0;l4574s5Et4E3E;iE7n0;!o1D3;!e1iADo8Cr1A9;l2C3s0;a234Be194i34u261D;c312i3B9Dl177Cn1571p257r4E32s2004t1C8;!n8r0t3;!a15DBb1791c1127d1B07e1D3Dg4DFFi3010k5Dl18Fm2674n42B6o1544p1D98r3089s14E2t43CFu703w91B;gE0;!n0s0t11;e15i43o93y0;l7CFn5;a0s100u14z3;c444kD4;u97;l2F76;h2E26;e115;aDAFe12i5Fl45CDw640;i8BA;i1F0Fp41;!s0u3;o132;!o31;!c1A0;a513i25;n2o427;c4BDDe2B0g2ABi86m1B97o10tE75;c296d0i12n4165r64t31F;aEc32;!c7e0l3An155t10E;f37o29;!e4i2165l832r19s0y0;d46F6fB0g2EEAl1m31An2755p131r460Ay28;n40;e8D;!l22nA9s0t48;!a511Ee11DEh4BBCi8EBk9Cl9Cm2Eo441Ap4FA3t48AEw4E10;!i977o35s0;lE7;!eEf37g0s0;!e24i6m2E;!g3B43;eEi28F9;!e4E43;!a43EAc15Fe1BA6g212i3F05o2310pA4s78u45y1DA4;b47Ck3E21;a28A;f46n1C2p233Ar320;c49r28Bt47B1;d175g4AtED;!a2F1Bc431Cd3031eAg1i13k1A4l76n2C07r350s0t2EB0wA8;r50C;d3AnF;!g1A;o5u1zC9;!e45B6i6w80;!eDl7n1s0;b1CiBA8n4729r2A7;!d0m2Er2Fs0t1;m39AC;s30B;e4E68;d7B5e0n0;!f38n2s0;a10e6E;a8n3;a301Ee3F3i6o12;aC4DdC9Ee3634i1922o16D7s3C97y2EFFz925;e0h3A;a59e17i65;!i21s0;o35B;i31p36t4A9y48;a3B18e13D5i1ADFo20CBu3AC3wB23y4343;e34FiE;!e1B2y0;!hD2p267s0;c19D;o41A;a51o1C;!b3E44f4246l22m5Fs1BC;!e769iCBl2Co1A8Dr22s0yEC;!g570w3EF;a323e1fCDm5Bo29;c3d276f19Al6C9m3F7p4EvB58;s677;cA2Bm2A51s49E8;!a6i20o1D;!a2000s0t3657;e6Ei4281;b7Be1;a34BeC5oBEyC;iCAo46;eFFi6l2C;a16A3e1i6CE;h1y0;n8r1t107;a2ADe1;l16r61t16;e3E;a1DF6e246EoE0Br4BE7;s1C5Dz19;e17o8A;e1A3Bi3C;!eAi1C3Bo471s0;d0r625t1;f7s65u12;eBlB;n1p7;!a1B5b7fB4i9o83Ds306t41v27;!e1B2i6n3u25D4;l1n87;e1s0t1CD;m88;a11Co29;u4207;c11s11;aE1s8u14;!b398c2369jFEl4AE2p33D1s4AFAt0wBF;l1n2;i2F84t22A;d2ECAk1l3103m28p12Ft1;!c9Es0t4F3;a2CF2e5Fi1E;c121m4725n331o1FEs3E8u5vA51;e201i6;mA1n65r34;o8F7;d1E90e0tADB;t210x66;i161j18;e4s11;aA2e76Fi1BB;b8E5c3A59d151Ee1DD1f108l3D0Em1n429Ep296Er4686s1D6Bt3F36v345x1A25z436F;!e6C8fB5l4CBn22;!a3AF1e1470o3Bs0v7A;a34iBy0;a30e23iCBy0;!l7n16r0s4A62;a7i9;n158s0;a32Di4E;h36D5;e4121;a3D5e323Bi2CDDo29CAy9AD;eB54;!bBBFl7Es0;a1e10B6f14C4m1Au111;l2514;!e14Ei43s0y0;cBd48Bn3937sC5t48;a69e11E;eEFFi96;a4De1DC2i2146y0;s2B9;a42e2695i127oBCCu19B1;!d39i6s0;i50s1F;e319i2FFAo3889u5;!t2E57;!a4Be4i6m2Es0;!d184g2Cs0;aCe24n2;a65i59u10;a33ABd3ABe4794l46B0p3F0Ar418w9;!e1i2Bl7s0y0;t19A1;!t10E;h2AA8;e1n16r0;l7Do10v3;!n22p3794s19F;j53;a6Ci6;!e23i6o6Eu3EBA;!a3597e12ECiCCl44o31E1rA4As0y0;!a10e56g4AFBh3BBCl309s0w3186;n1r38C;!eF9l7t7;!nE;eEi5;i6p2C;iC6l80o11B;!i8Ey0;e1i649m180EnEp55z49B;!b4321c1Ae1g7Eh1sDACt6D0u2B5vDD4;a1CD7c419De68g1D33m3805n4A10oA57s28EF;l25u69;d1Am64t291;p3618t99C;a143lE0;c3B0Ai35k2541t2Dz7;!a9DCd55Be200Di4B59l2BBo4ECAr145Fs0u7AC;i25r90t77;e17i8;e387i3C;lA58o29v3;l2015;e2573f2E30i4l44o2EF8;f2834i488mA84s45v3DF3;a3Ce162Bi15A7o20CD;!d0i6r0s3E;oA72yC;e25Bg2Cm31ArAA5s1FCCv3;d0e1l1r1;a4E1Ce50i6o43AC;i45A;g631i773m28t4BFDy0;kE5l39;e1Bk3l7nF;!a0i15El1Es0;!s0t152;!d8Ae7C1i31Bk4Cl1Er7s0t40;kC9r4E29;a40eAi43A8o8C;!i91n26BEs0y0;aF87eDFiE36o31u307Ey0;i25l1;a4157o1;!a397Ab42C5i1Al1C73n130r1As0u69Bw3004;t569;s11t3;b1Cg36C9n299Dr5DtB;b122n118;i48E7;r251;!bCAAd15FeAi189o2A8Fs0u108y0;!a260Db15EEd3F80e2392fB47h109i2F13n1E2o4A0s0w3E9y3F0E;a8Fi41D7;a50C4b2D64c2645d1697e1149f3B9Fh4E5Bi2599j20DAk100Cl35D4m34FDn19FCo42B0pF95q258Dr4027t2C8CuC44v44BCw2E99y10C9;rA4;gAF3n1x1F;!e79i18y0;!a4D9Ae4h109i24Eo503As0w236;!aEoE1Cs0;g0i0oE8u5;g19n205rE;a4509e68m1zA4;a237cBD2g4E21n2A9Co3C1sD1;r158;a1CDo1;!e1Bi154l7n22y0;!e15f37i36A7l7s1Fy0;l690;!m87nEt163;!e822;f0t0;!b519l219s0w136;!d1B7p48s0;o57u34;r28t88;b2049c2C72d113Ee193Ff6BBg1D06h3963i2A72j2266k3B52l1E38m3F06n39F1q12C4r4160s471Ft3FF5u2D82v3CE0w2DCFxAEy3F2Dz41AC;e2E8A;!a157m64r7As2B20t28;!e15i986l36Fs0y0;a47B0b430EcA7Fe2B0Fi2D11mE24o3A0Bp3817s0u2007y658;c1o9;d5CkB7ElA7m7ECn4D87p1s2C;a11i9;c226d0n3x1F;aEFe1280i3D7Ct3E4Au167F;a397Ce6EEi4750u72;!r4s0;!d0f37m2Er1s0;a4Be4i301y0;a10e4033;nC38;b5CgBm2Ds21A9t4A09;b39;e5l7t7;!l14;!d0l4Cs0;r0t4363;c5Cg25Fr47F5s44t44u61;b2BB;a4Bd1f7;c8E2d53Bi6EAn2ACr2D50s7t699;r1y1;o3DCE;c1CgB;i4204o46pB9u5;e0n24A;i36y16;y1BEA;!a12e2B65uB6;r12C8v187;a509Ce30A6h348i2DF5oD85r29DAu4DAAy2104;n81B;c1n3;u388;h4555;l3FDC;!a20b7g1A69o14D7s0u5E5;!bB1fB5g4B79l99Am2Es0;e1By0;e113y0;!a10c4461e41E5g64Ai3409m3914n1D82o3552p38A5q2FDEr111Bs255At10ECu4096;w98;s234t2D;r2B5;!a30e26Ai6o12s0;!aFD8b1DACeE33i2E8Bn48Eo1619s0u1638;a12k780o12;e6Eo10;f2D;i3BBFp206t44C5;e2145i10;!e4813h2Bi331Dk3E7Em29o1B39qD00r1746s0t27BCu1340y0;!eC1i8El19p4Cs0y0;a3E0Fe2FC1iB96w1AA;l1A2;l0s1AFz5EE;p1s5;s19A;!d0l1s0t1y0;rB7D;!b1e4s0y0;a4Ai56;t1F93;c232d1B55m48n1r32D8s239;a2A6Di227Eo3419;!e9i9s0;h1E5;i43C;l137Bn1;e5Fi4EE;a2F7e1oE8;t1D7;!e4i86s0;a4B00r3;n40CC;a1A2F;e4E09i3E8Dl57Ao4821r45BFu15DFy0;n114;!aCe33i1o1;!p5F;u28A5;!a51e5A3i86s0;a72e48C4i4378l3840o46F9rE83y369;e33i8;e0l48EDo0r483F;e5y34;e8D2i4612l1B6o72y0;!aDDEe5o29s0;aB8e17o6;!s63;s1DAt4Fz3;a1DBCb3EBc3C3e3D32i32F0oA6s2F7Ct2802u50D;a2FAe12o19E;u37C;e12i91y0;!s0v27;!e12i91y0;i305;d0rE6F;e1l2CoBA0;!r891s0;s2491;!d0n4A61r426Ds0;!d1227i1DFD;e17o36;w48;dCEt19;e2233rB9;!a74Fi55Ao1CBCs0;c1714;a400Ce2B1Ah3FFEi3C29o30F4r1F25u266Aw56Ay7E;d1C23m325;n211;e0oD;b1Ct1190;d24Ce571;a37D4o144;!a4654c333Ce4596h49ECi4DF0n3DE5o38CAp2F26t1B2Bu4415w2958;a1EDu51A;!a3FE4e3F57iF96l728n38o461Cs0u49w80y7C4;n83r1;s56;c9Et48;!a375s0t1uE;e15DiCCl2Cy0;r654;!aF5e4;l0tBD;a21Be148i2057l2Cr14Fy0;aCn3t7;!i143s0tF1;d400nB;l3Ar74;r3F4E;!a9b4EDEc2C16e506h1388i6l20A1n22s0t1873w38E;c3FE1s11;a42o2D61;m2Do10;a147Fe10F7i2863o34A9r15EBu3EAD;c7t297;c2C2n3;a2957d161De2FC7g1538h0i293Eu19A0;!a4ED3e688iDDs0;e4A6hB;!l32Bs0;a1i30F;l1Et0;c33EAf2F33p31B8r1460;!d0l22r1s0w98;a1863e4A92i2F96oC51y63;e1Bn2p1EsE;!d0l489n0r48s4A33t18C1wBF;b7Bg3;a34ABoE8B;i13t2D;!a396Ab32AEe3846f3F67i5F6m21Eo1907p1F03s0tB1;e4D07l1;e1Di2D1y0;!e4f37iCCl22s0y0;e557h5Ai480k17A3o3AB2p2BFs2E4u4E;!a2C0Bd11Fg45E4i1A10o2F47s0y0;!c4E7n1s0;!e0i0;c194Eg8CDn83ArB2As41B8t5F3;!e4i43l19s0y0;r4240s8;!aCB1b3259e408Cf28BEi1303s0u25E0;n39r1s8;lBo4;c4595d4D5g44k1n4290o255Bs56t19D8;!e8BFi1316oB73s0y63;a0uD;k3BnE41;!dE0i1DB;e42i2Bu6y0;n2x0;d2Fi4u5;!kA02n32B2s0;!e68f37i6;t1F62;s218t4A;e6Ci2256;d44BAr4E44t738wE4;!s35;!aBE6e822i21o11Ay38E1;n7r55;!d0m2Er1s0y16;a2Al5E7n142;g3u17;!s0t2296;e23gBi6o40r3B;!e85i6s0;a4De18Di6;a1371e2CA3i214Eo194Du3571yB02;a30e23i6o433;z115;zB;!z2B;s80;c1CE;c3A19g1Ei25AAn429Fp38r1Et43Bv1Ey17F;e5n2u5;a11CEe1B2i3C;lF4o3AA;!e0r17FC;!dA8eBEl58s0;e3E65i6;!c8iCr7s3Et3;b425;f7n3;g2Ci145;!e4f37i301s0y0;uAA1;!h1E2Cs0;cB2i45EB;r188t11;r3FFA;eAi3F;r229t11;a40F4u1C;e1Bf7l7n2t5DD;b65BgBl512Fm447Bp4EBCtBz7AE;nB3F;e2C61k3818l1Dn95Ap133Br4A32tB;!e12r7s0;!e1D17iBl3;d5Bi71n7DCrE0y0;e1i3B;b1505d2282fC3Dg2ABi49k20E9m2613n23CCp1552r2E27s17FDt5Ax1F;oA3;!c4D1s0;gBw80;e12f38rB;f1m28v1B6;a342;c160e68;n2s3;a4A5Cc1589e3BEBgC82k2F4Ct28u1271;n3EAF;i2D59o81y63;n28r0s8;g161;!c317e1333i1883j1308l44B5o4D9p469As3A4u3B64;n38r4C39;!n21C7s0;!a14DEc25A6d20D2e15i6E1j180o2FC3s0;i4286;s307B;d19pEs5;!l24Cr35Fs41A6;!a85Ec41D3e4BCEhE6Ak1AAFl309q11Dr2506s0;c126De2A85i2767o1EA0t1751u3E6E;!dCDp35;c1921k28t44C;t386E;!a34A3b3BCcA09g17C5l47D5m2A81n45B8pC04sD3Dt4854;a1B9FeE81i3FD0o469Cu28E1;f1110l28n2DpFF9r4170t2683;w89;e4D53i502F;s0v3;e1u54;c4B35k28;e1Bn2t394;!e92Bi3E4m19Dp8Bs0;a294Ah1k820t2DEA;c9Ee1Al48;!b58e4fB2Fi6k49EBm28n1C5Bp1DE8r75Fs2F4Bt1CD2v2B;i12ClBy0;r404A;c5F4r490Es1E6A;a48E5b162DdC80eA4f502Ag1AEEi56k2EABl4B10m5115n1698p2690r66Et184v2B;!s1Ft1;h878;eAi2C10y0;i4FB8;b1D9Ac3B9Eg4Al48E9n4829r4s202At1756v7A2x0;c4421d122f360t1D0;d2B;e5n125;!a4Be15h2A0i199o1D66s0y0;l1y1;!d0s0t39;r92;a1d4958e4714i4AC8l2B12o3FC9sD69t2455u4E;!e12i44As0y0;iDn407uC;!a1D1l1s0;i128l114;s8DE;!e68i6y0;kBp2993s1ECE;e539i6y0;c19d16e50;a96A;a4D5Ee13EFg39BCh4A22i4702o3417t11u2288y456C;!e85i756s0;!e6E4s0y0;a51e15i86;a39BAs239;!a0e79iCCr261y0;cBd2Cn118t399A;lA5o10rAA;!b450e15i21l1484r3910s4F7uBwA8;!e609i21s0;!a976e23i681s0;g48Fl2DB1r0;!b498eA47iD0Cl7n22s0uB9;eB91;!a1Dy0;a1A73i4o27C2r1AC4u49w1D5;e1Bg13Cn2t206;l19u36;d0n133r1;u16;d0n33B1sA8D;c8g0;!a316Bb16EDc4AA2dC55e3961f3685g24C1hEC0i3874j811l2B71m4B7Dn3A54o2786p1DB4qAE1r35C6s2CC9t1B8Av5031w105Cx49Dy2B6z1188;c293Fg15As0;a1B7Ec1492e3299g25C5l4FB9m6F4n1297o4784r16E5s4A37t21Dv89;!e1A8Fi472l84DoDBBs0y15E1;!e4iACs0t0y0;v19B;bB;e296Ci1FDu7BC;c14D;x234;e1i223o9;l152Br0;i4m1An1;a4C2r2C;e0i12Cy0;l16F0rB;!c415Ch1C7Fi3BB9p1386t63C;r4E6;t1FFB;r3Ds3;i94Eo67E;a3163e26Ei29C;r10B;p3B29;!c43A6gD12l1909m4EE8o231s41CD;a1545i458C;nEzFD;r359;p5Ay28;e33i5t1;e4i2932y0;a2BA7b3A96c31C6d39DAe448Af13B4g264Fk3956l2A5Am18FAn236Ao4F8Cp384Eq1D87r4530s37E7t2AF7v42F8x367Bz1A5;a0c0n2E1;b4F02e1n2s11;iCn3o2Ap1;e12g38;n12F;a4159i2Bo4BA1y0;a676i9;!d0i21s0;n4B3p2B44r41Fs327xC0;a990;!e765i6s0;i4510o26CB;!e1FBi21s859;e1B4;!n1s3E;l9Fr83t0;o256u6;u5126;e99i230o1078;!b3184d101BfE2l22m2Ep32E0r1s182Bt62CwC5E;a3D8Ce4CD6;wA8;!e15i21l2Cs0;n2D5F;!s0t18z1E;!d0t0;d19s445B;e4i970l37D;a1AB4bDCDc38A3d2144e27B5f20Bg3E6Bi2D4Dl11ABn4824o3435p2333r1521t24C8uDFEw5E;!a3701b41EEe3DF5i10k1EAl2Co4333rC52s0u487A;c1B49n2q468C;aB6i477o61A;!a12d1A4e1995g3BA0iA27kEE0m2328nA9oA57s0t28;!e15Di6s0;!p119s0;!r25AF;a31e4FF9i289o46y0;i1807;!pB;n2v53;m19Dn114s5E;e0k5At40D9;b2996c1069e24f287Bg169El3274m179En3CA2p3150r2A7Ds3F2t282Dv216;!n2977s0;i25n90;!i1p292Fs17BAt2F4DuF0;t2928u4E;!d0i6r366s3Ev3D;!a3;a3;!d0l22r48s0;c4C56;!i123;e0i238;!e0t95;!a4De15i21l22m64o12s0;!d0s0t163;lCs11;!r24C;!a4F3Fd1805e17A0iACk5Dl20FAo2CAs2E3;c19iEy1E;!a1D2Ed12Fe175Df99Dg2F2h3E68i3DEAo4482s15ADt4B75u1y137;!b4C;!a40i39E2o2D1Es0u5;eDs1A;!n22r1s8;e15i2D85y0;g792;!r0s8x29;b217m35nE;a1DD5b4FB0c44CAd1CB3e29FFf324Fg27E7h3342i2F90j4914k144Bl4A71m1B31n4EFDo3459p422Fr3B2FsEEEt26A1u3B75v30E8w511Fx118Dy1;n6Bo1;!b3C3e1178i289m2Eo4ECp113Cs0w236y4110;b1f108;d3Ag5Bn1sE;u20v47;b1Cd89l1t316;a0i96o67E;eAi311;!e1523h4E93i1ACEo4090s0;e57i47BF;a1CF6e1EAoD7t3B2;z56;c2F4rB;f7F9i1kA02p377Ds0t2E18;d3Ar1s0t394;a1e4000i1B60o12r62;a988e1DA0;h7i1F82o29;g5A5k67Bt248;!b4B9lB14;!e68i43l7y0;a3EAEe1B68f1i1C6n1679z3724;!a4BC5l44s0;r4Bt3;s5BA;d1AA;!d3558m140Bn2B30p32A9s0t2D;y4541;h27C4k48;l4r36y1;!i5DF;m141n48;t635;a30D4o4BD4r459Du410;t1F3;!e23g2Ci3FCAkB43l7En7As1695t38y0;e4i6o0y0;!s1E8;e215h20BoB6;a26EEe389Cy8AD;e79l7n2t0;s1D6tB;a363F;eAo10;!a0i55Ap440;a40i949;i3Fl1192mA4p4B0s200At60B;a4716e2838i257Do3FFDu42D6y1996;f3i10nEr14s19;l2B0Cn1;d4DD;!d186s0;i3B24y0;!i1p1AA;g94l16n4r1E;u11E;!i4D7l7;l4162n1Au473;t3y1;a35DuAA3;e7E3k2DD5oF6;l19nE;e1g1i3F;!e25F0i6m2Es0;aDDFi3693o1FB2;l9Dr466;tA39;e44CFi3Cy0;!a102Fb1D0Be2454i20l76m49A0oE8p11Fs19Fu291Cz396;!e365i6s0w62C;!a1F0Ab27Cc416Be33C1f597h3544i3C6Cl9A1o3BDBp45F0s3C19t244B;i28D;f44Ck259Dl48m28n1F32r48t0;e4306i2EA6u4E;!a4Dd0i3Cl24Fn22r1F5s1693;g19v21F;l1F2r0s0;!e4i2255s0y0;d4Bi1FDy3D;aC9iA5;!a2B1Fd42Fg47C7i6l13ECn3B2Br2B34s34FC;e30nA1;dEEAe2653gB6k1l46E2m2BFn3129o278Fr52s29FEzB;a1b17B9;c69E;a145;o4F6E;e1s526;a46CEe2813i337Co2BDFt4857u111;!g62l64n1s0;!i13F3p1315s1A1t1;a42FEi28C6o2029r17C;!eC1i6l9D8s0;a7F8d49o46C7s2C1CtECF;!a49Fe4i6s0;b145d0e14n1FCEr1;!w136;!lB39;!e7E5r7s0;n4DE5;c121l64s1F;!d0l2B98s0;!b7E9sF8E;o4AA;!b58Cd58f209Bg181h3DEi20k1l22m3E1Cn1877p1ABBr3FDs17EBt38w797y217;aC6oA0;lA98;cF4d27;c4EF;eB9i2B1o29;x4C;e4n1E;!f183i2CBn22r2A1s508yAFA;s3022;t36CD;!i3B16;h3F5;c0d0e0;a12e0iA52t29u3988;d22D7g11r3DA6;!l4978n0r28;g3976n2973s10C2t29AFxAE;e1o34;c3g2CnDFCp8vB5;c8F4r3D6A;!e24i8F3lB;k1B40;s1C7t2C0Eu5;a7Fe1CFD;m4CAs83;i1F46;d2A8h418;b16C0e1i11BCl217o46B;!i3Cl7s0;!e17i527s0;a3B91e128Ci27DFo4CBFu2764y0;e1B22i6o4D65z2E8F;n28r157;r3y5;a3CA1e12;!e0n0s0t2D;l3B5B;!eC1i44FCs0u34y0;a3F11eEi1075y63;!e3DBi6l7n22y0;l3At19;e23iAC;!d8Ai31B;c0sE;!a4DbFEe15f1B1i1ECs0y0;!a20D5b348Ce2E77i3886l2BBCo47D9s19Fu27C1w4FD;e6Er4FF5;a36ECe33i381u1A36y0;e42i4E;u854;d1s9A;e6Eh930r62;a16Ae8D;!e4i60Fs0y0;!b261;c8n1t0;e0i77;a42AFe220i11EAo72;p7B7s9E;a20e26Ei29C;oBCu1D;d35i25;j80;m306t70;l0n25CFr25s19;u2A;!a3862c19C1d3018e167Cf2EB7g4848h317i853k43EBm2En2671pE3s4694tEAEw2D0y0;!e4i6lBs52;e4A46n36F7;!e24i29Bs0;a228Dh568i4Do158Fr1C3u2C;!c47s0t2D;!e4h28i6l87s0;!aEFi493o10s0;e5i38B6;e0n0y0;a3E8BeFACi67u5Cy0;!a1De15i21s0;e2152i6;!r15F;hEn3A;c8r39tB;a1De180Ai3Du50y50;a2013e46Ai36BBo2D42r3A26u4A8Fy63;d4092;!a0e5;e60i2DE;d0r1s19B0;a0e1;c0e24s8;l1r19Cs5;e9FFh2626;!e1E0DtFE;!a4Be235i43s0y0;r3E25;!a104gB63l3819n22o4338r714s0;eDn213;l262rB;!e4i6l2Cs49D;!iBl7s0y0;!i2Bl7s0y0;!d38e15fC2i3F4s0;n4B5E;b1n490;e2CBi7AAo4EDC;cEDe1l1nF;f3756t4D91;e4F63;h4341;sD2;u32A;o10rAA;a29Ao1uE44;a412Be143h321o7F6u144;c9El118s405Bt28;!eC1i416Fl7s0;r65A;!r23C7z87;h41BE;m3FB9;a3311d349Ee3434i21l2C;i4r0s45D5u5;e5nFo10s19v3z19;l5C1;!a490Bb4879d1341e1C15i3560l2BB4m3617n1291o3513p36DDr1601s45B3tFDy0;c3Dl7r21A3;a2832e24C2i1440o1057r39DD;l2Dn1FB8x1ABy1;iDl10FBn1F6r46BAy146;!a1387e437Ei1BBAoF0s0u5C;a58BhA44;o2108;l50D6s3F73;!t60;d0l47F0s5;e2A95i2BE0o4657;b4DB0mE6s1;h2FD7;a8c6FEe1B03h484Bi43BFl320Cm3D1Co1FD2p4DECt29DEu1F2D;a49m957;e17C;m150;l544o411;!b390De915i4F2l76s0u4E;l10CEp4CF6v1831;d2AFD;a3FD5eBA4r43F;d4451eAg1B7i3E4jC8k1y0;m1C0;!g491Al24As0;i22AE;a1086r15F;e24n2o10s11;a2AAo55E;l4FE8n201B;!r3D59;a9c0s3z3;b7BpE;e3A8Fo57;i153;b40Fg62wA8;rE94;!i3Cs293;f3FCCiFDn114t28;c28EBl4A03s410E;!l7s0y0;e2CEC;i25BF;i25BE;e308Bk7;rDF;a10e194h20Bi4E8F;!e4i0l2C95u218y16F;c5FAh2EA2k0t3ED6;!e21Al7s0;c1s3t7z3;!e40iBo1p14Ds0y0;!a4De12i21l4DBn0s0t4A;e4C0Fm18oB6;!d0n528r1s0y0;!e329i21s0;d1r36;!e77Fi5091oB46wEAy0;b1Cn1;f443;u3855;!l777m1597n2s0xB;iBo72u72;a3D3FeFB7i3073l14B2o2D24r40EAu1BAEyB86;nBs1Ez1E;i401Ay0;i16;e0o9ED;l892u4CD5;a37D3c4549dF73e10f2475g4182h1CCCk372Bl3A07m4587n1D56o5062r43CDs1AD8t369Eu4EB6x1EACz23FC;a7FeAi6m480Bo128s280t267A;iB4n37D5;gA84;a3Ce5A3h92;c1D11eD55l505Bn493Co0r5AtB;!e1iDEDo1y56;e1Bt1;!d0m2Er1s0y0;!e5z672;!g5AiB8k1A;u315F;!e15h109iCCs0y0;!a1F00d11Fe2F73g2567i6j56kF3n3B31o12s371DuEzA1;!e12C1i6;e12h109;o1AC6;!a36n327r2C13s0;!l7n22t23DA;!fB5l1AAs0;a2CEdB5o6Er3Du8B0v7Aw9;e4i6o54;!e12Ef37l2Co0s0;e5Au28B5;i2095;n8t0;e34o3C62;e83i366Fl44o6A9;a4Be71Ci71y63;a38FEe88i17D6o1rD6zB4;s4Cz4C;i9D0;d45D;dE86;a81Fy0;u52;!u3;e0i91l3BAFm1o14t0w6Ay0;!b1Cd3Bi1Ds0;d418;!e15Di6o1s0u14;m64t31F;!e9iA7El22s0y0;aDt1;o586;e249nF;o12A8;!s66;!s71;cBgB;!a20e10Di3F0Bl7s0y0;r26E6;i42D7;!d0i6l1mB45n3775p14Fr28s0t38E7;!e1n22;eDl218Cr3;e1Di7D2;!e1Bi50l361t7;eC4rAA;a477;a12uAF;o32D;e228Cr313DuB6A;!e68f20DDi2624m2EoDu49;!i13l8E1m121s0;i4780l233y0;!e358Di6s0;a2E8o1DC;i1DDCy0;b4841d2Bl8r48BEs23Et0;!b62e1g1r60Cs0;!y95;m47B8;i3BC0m1n0;aCe2B0E;a41F;z137;r475F;c32Dk1;!h1s140;e12r379B;k46FDo5C;c3Dr34u59;c4994d0f2D5Dg34Fl1o1627s3182t58x5E;e33Ei652y0;!a147e17i5DFs0;!a1D7Ae3235h671i21s0;e1Bg8BnFo9;e18Di21l7;a1De5112m1;e2860o450E;b27e1Bn2;a0c44r1EE6t3C26;!e5r1s0;!h4B87s49Dt3548;e38F1i6k16;eAfCD1i6;!a1ED9b662c22A1dB4Ae15FAf17Bi12C0l17Dm3441o809p4C29r4A64s1DB1t4F89u5Dw20ECy42DF;a4Bo12r1A9;!k1Es0;e0t206;o2C1F;!b2F6Be4AF2;c1Ar1;i41B;d0n3s11;!e2EE2o4F4s0uB9;m65FsC0;!e15i6l2Cr4CD3s0;e2BFAi39D;!a0e0s0;!d16;e4B55g2512i4456;!a4De12i1524s0y63;r1C2;i32F2u144;e1k3;!a5087b1FCFe39Fi357Bm1946o2CFp2C1r15Fs0u4E;e23i2F0y0;!b2A0e235iACm2Er276s0t1DE;nD8;d404l3As2D;i2EA;a4766e1Dr1u12;c0o9s100t7z3;!f37l7;!a4Bi13m4FCs0;r17Bs1501t2D;!e4i1DB2lF4s0y0;a4A7Fb2375c664d28F6eCB4f3538g2853i3191l1E91m4C7Fn2E7Ap1130r2934s3088t3EACv0y4050zB66;a0o1E75;!a14A6e15i6s0;!c18Cd1n39s0v47;f0v2B;c32g137;f2814i2E2Do29;e30oC4;e5n2pF1;m1An23B9;a41F5e1EA9i3647;!e15f37i6s0t4371;!h1i950kFCs0;a34BeAi67o4E04y0;l1u32;eA47i885r217Ay0;e4AB0;g29D8k1Ct39;m62v4A8;e23i756t5D6;lA7s454t1AF;k0l16;!e120f37l22s0;h1A77;!e5o31A;!e23f37i6l7y0;t141;!t141;eEr198;a1iBB;!s39Et3;i31r25;u3520;!lBs1BC;r4E06;c5AE;!iD9n2Bs0yD9;a1e235i19D7y0;c95e12n2o10s11;n213r305D;eEEl7n2AD8;r16t1;c11n7t39;s1Fu5;!e538s0;c19t196;!lC56s0t10D9;e23h11Bi67uDy0;s7F2t1;rAE4;b1478;w2B76;l2BD1;mE6n47;e12r286B;m2BB5;m0n0;o10s16CtA7C;e220o1;n0r2F;d114;c106Ag623i3C94m5143s3789t2D23;aE4rF3;l4Cu5;r35t20;a22CCcBu14;n1r61t61;!e24gA4i5F2n0s0;f1DEp4E30;!d0i6m3DC5r4856s0t1;e2219;d48t0;a195l202;lA4C;r1112;e17l2B;b1Cd80;c0m197;l3m3;aCi31o46u4E;l4468;!d0m1r2Fs0;b1BDc247o10s11;a2103;n21Fo1;e1781;!d0l126Fn10D1r1s0;e3A1Cr3D;y6C;hA4;!a1DeD0i6s0;lBu59;r2E66t1;!a3F09b2149eF24fB5g28D3h3226i412Dl11F7m2Ep2C58r1CBs3A94;r3t1;f4678i1A;n8t665;n2s207;a20i7A9l41B7o2066u5;a7Fh779;oACE;i3u1F59y0;u3A6C;a3027;a0e0i0;i1FD;!i1FD;!h16Co6F;h29E8;a94F;i4022;eAi6nF3;n25r2C;i31o3C05;!c182f19DsC5t1A;!a5Cl7BDs0;l2FDBn569p116;a218d271Cn25s2A24t83;a1o617;!a2D55d212e15i21l4C3n0s0;!aF63e1635i414Co38B5s0;a3D53b1415c41D1d35FeA9Cf3912g4C2Bi6DDl44Bm26BFn9FAp460Br3EC5tFA6v2D71;aB67e5s27Bt1z19;c3d0s3;!b510Ee38E4i410rA5Ds0u10C7;g135;m20Bn22EF;s1Ft10E;l44oE;c388d1250g325lA7n3A2r20F1s4AB7w1;!d0l1F2n0r453Es0t3FD3;n62t4609;aCeDg0i0u5;d9F0;a27E;c3C96gAC9l1BD7m0n271;n4466rDAB;c48EBd489Ee15B3f4599g4671i375Dj1E0k3C5Al473Bm5151n2800o2D5Cp454Dr431Fs2533t1BADxAEz4C87;aCFp3DC;h129B;!a1A7Ec693f1D5Bk5Dl1269o7Cp5Ct4557;lABA;k1AzF7;s3F;!a50F2bFEe10Di86n22s0y0;!aCe142i13s0;i1Cy1C;a4Bl3;u2D9;!aCe15i21l87s0y0;!a4Be15i6s0t90;!b296Fc1F4r5Es0;i764;h30FBl8B8p3CECs2A1A;cBg1;a11Ce62o3480;!b1E8e3D8f2468h1D70i493Dm2Eo35BEs0y1C31;e1f108n2;l9AB;r2BC;d103l48;b3671g192Dt33F;b3BCg513Ci4lA7m3C90pCE8s325At4561;a1i27y0;s10DF;!eAh382Ai6p2BCBs0;!e12A5i6l5B6s3F3Cy98;h39E;a1iAE;r354;!a3A3c0n3s0;d0l48s0;g6A;!a4080d2F57e0g22E6h0i254Dk2B33l7En25DDr85Cs3A4t2E6Dy1A5;e23i6o4244;!d0e1F36r1;e5s27Bt3z19;a20c65Ed0e1i0o269t1u5;!a245g1Ei92Ao36s0;s251Dz3;a4A2Ee4EB1i1AB7o4618u45C7y0;f145l802r1832v7E;cEp1;c50B1g4CC7k386Cl1758r0;a40g400nF;!bBCFd0f278g3l7n22r0s3B4F;i720;!c3A38e3E2Al7o2A54y28FA;!a4e4i6s0;!a11e5;s9Az3;e32D3i6y0;e0lB9;a47C6e393Ci3AFCo2F9A;a7B4;c2Ax0;h1i4A7Ct3354;!a30e4iFAo12s0;!e3D81i215Fl7n22s0t40EF;e38A1h35;!aCE1e1357i113Ak5Dl22p118Cs0u1Dy0;n1r19D6;!h1713l149s66Et3E03;a0h6AFi27CBo606;r16sC0;a0t0;l1F6;!eB5Fi6;e22Ei6;oC6r87;!e1i18l7s0;!e4i6l1F15r58s0;l942;!e4iACl19s0;cB20nFo1s13At1091;!b33F6c39C2d0fB5g212i21jA8l7n2CD6r0s842t213Ew3A2Ay1;a4C3Ce2306o1E17u72;a0e30;e14i13;s38D3;a25EEb2F0Ad3EABe22Ef2C0Dg4FB1l37DEm3FE6n1C65o37FFp0r2340s11C2t4437u296Av24F2z4812;e1n125s11;!i27t90y0;!eDoDs0;n251;a53Dd979eBg4Ch4C8Ai3D5Cl308m2Dr50EB;a33E1eCD3i17C7y0;k3r8;c2F4d1;r649;d1Em1Er1E;a3D;a415Ad3438eDF4g334Ei1656l13D6m1074n14C3p23ECr1CFBt3347vA4w3821y0;e9AEi4219p29BA;!eAi21s0y0;!a8Fc131eAi6o9;r364Fs44;!n22w136;c3DsE;i3A6o29y0;t23AA;!a39E1b2E06eD87i1E2Bm20AEp4009s0;o427;g0o0;e1Bn294s27F;!d0r1s1Fy1;a0o9r1A;!o3E0s0;d2A1Ft4BC3;!e15iBAl87s0y0;!a3FA3e4B4i42B9o1294s0u4E;s3B;n3461;p64;b1m1r1;!b3588m7As0;e618f7s0;!a0e193i5F2o1s0;i167;!a4As0;!e60Ai4E;!a2E0Ec9Fe23h4954i6k76q11Ds3D34t4430;!l66Fr3s0t20;t1v3;i176;a185Ce4AEBi91o72y0;b468An25;i3B69o30y0;a18Ee8ACi3B22o29u2EDCy0;u339C;a222;aA3e1u14;s30C;gBk4C;a1931e1A00i3276l3801o3E83r4F59u3D1Dy29C1;eAi6m39;r46C;dC85e1r7;nFt21Dz2C;lE2r2BD;!a4De39Fi331Au376;e2A68i13;n1B4;!a25o67Es0;!g7Ai1Cm64o12r106s0;!a431Ae1m4FCu2AB4;e1k861;t2811;a9c0n2t7;y69;r4499;e269E;e8f6Bi10;i8Br91F;c0d19f7lBtB;e10Co1DC;r175;l5AEp2817r4E1A;!a2CFEe158Ei1655o34DBs0;e34Ei13Du164;!s0u788;c136g17F3t4D6;!e2DD2gEA2h2E4i21s235Fw4FD;!r28s0;b4471c2787l31Dp1s57t106Eu1FFw3BD8;!a42C9c110Be47E2h3173i31k38A6n1685o506Aq30Dr252As0t29E5u1D;f10A6g3F45l28n1990r0s295Ct4DFE;e1BnA6CsE;!a10h265i1l37Ds0;n2716t13C;!l4m2B8n1Er9w98;l8A;!eE1s0;aA8Bu42E;e25EAo1A4A;o70E;l1r18;!aA04e5t0;sA16;e1Dr3EB8;g44m3D60n111r20B3s163v1A99;b1Cn205r7v5A;a13FDd3Ae1Bn2u14;e1t23A;cEDe166r1180;!e4i21o29A7s0;a3EBDe33AFi35A2o29u5Cy4C5;e1i88o29;!a8e4i29Cs0;mE1;m9;i4C90;!eAi67s0y0;!nCA;nCA;a153D;e46ADi4B21;o1Ds84;cBt7;c7tB;a231;!a4B02b2B62g2625h3DEl35F5o21s0w44E;!a4D2b4CC0d82Ae4Ej9Fm655p3183s0;!e8Ci3Cs0y0;!a247Be1C64i4255o65By0;s3BtDB;!e712s0y0;aCt3D;e95l3;!l19m1n19r1s0;a8c7t3;e1t1E;b1Cr14Bt3394;n3t5E;!n3t5E;k0t3A;h1B1l4962n4D4;!b2124c2439e310Bg30DAi100AmC45n2C2Dp271Ds4ED0t12B5u189Fy2BFz511B;cAEAt179;a40i0u5;e153B;e1o12;l18m2F;!lFD9m17Bo1A7s1859t4DE0y98;e1m28;a7AA;g17D;!a2B64d2ECe5D4i15FCk1n325Bo1292s1BCt3D69u5Cy0;n263Ao41Bs13A;!e15i17As0;c388;!a4De1408h1515i21s0t5B;!d4FD3l177r1s0t1887;!a7Fe1D52i6n0s0;l4n4;s57;n2o29u34;c7d13Dt0;a2025n476o5Cu14;mB1C;i65t47;!cF6e0r1AE;!a28Ee26h282Ci4614l27o364Ar58s8C0u10;a391i32EDo46u3EC;a0e4A15s43D6u34x66;!b104AdA5h34l581n1s0;s2382;l2DD1n236Cr4E0Bs25E9;h27DAs0;bC9s1F;i7D2;i10n0;!a4925c1D01e3683h155Ai2552k1702lBBBo496Fr44E8s0tDE5u4C93yA33;!aF1FlF3;!a237e4F75g2EA4hAA6iE5Ek5DlBr26Fs0y34C1;a34BFd28e716i3770t2B6;bB27e12i5A9l39C6n489Fr694t1A33;g2432;c296;e25m250D;!a3E2e15i311o9s0;o29s0t7;a1e1B13i39Dp1F3u5FF;!e5k4C;a1c0dB;!a7De4115iFF7o12uF0;!a82Ce275Cf37h321i4196l2Co45A6r2ECDs0u344y3D0F;rA1t66D;!a499Fc1982k4BD1s0;i5n65;rBs36;!i6r182;s1At7;!e5i54Ao3By0;d0l4B44r0s8;a72e25;!i1D2;g46;!e68iBAl2Cy0;c38g21Bm64n118r1E24s36t2874;n1s5t1;d3t191;aAF0g343Dj3DB9l1E4r2531s3Ft36C1;g105;!d3Al6B7s156;l67Do2E44r281t437;p22B9;m605;a1d106e0;c1FEBm1B08;d7Ev3A0;m3375;!a36D3e4i6l1012s0;i220C;!c9Ed1B7k5s0z3EB9;!a384Bd185Ao2C43s2CCE;dBt1;uA82;!e4i6s156;!e2849i4320s0;d19nEt392;!e15i47D8s0;dD4i20C;a548g0i3F;d1f38g215Cl5nB9r2181s239t2525;a409Di2882o330E;b3e24v3;a59e17i6y0;cF1;a0h1A5Ci104Eu11E;o167;a3EEBi15EF;e3Dm0t70;a9DBoE;o1F98r95uF;e4675h389Ei20E5k2CCCo2871tDD8y0;a3F4B;f4863lBoBC;!d0l7r1s3Et16;a20o46u5;a4Bi35;e26i5D7y0;d1p1t16;e10D8i617o1F38;a52i9o36u5;eAiDDu12;!aC6Ee1A8Ei2E15uB1y0;c492Bd2489l5090mC4Cn302p5B5r3Bs1CB5t9Fz38;n52t3;!n3t3;a1i57;e36D0;!d0r1s0t0;a35B3l3978;!d0r1s0t5;!t9E9;n0t3D;o14r42E;a54o6D;e698;a589i1E28;e4i2By0;h11;!l3637;!e12Eo241s0;n16r0s6F2;e129h87;m39A7;!a7Fb1E8e4i986l22p47As0y0;a25CAk28m28p3BEr1574t28;t306;!t41;e1i238o5u5;c4BE5n2o10s102v3;n8A;e774o567;c19n19;!m1Ep1Es0;e509Eh5BE;!s0w9;!a14B9e349i7BCl7o2DCDu420;y9D;hC87;i3Fn19;o9u14;c1gBl440;e128;i806o126;!g3065i6s2B5E;o3Cu3Cy1;!e15fB47i6s0t0;!a1h1As0;pFC;i28Fo73;e15i43o0y0;!a275dD4eAg5Ci29Ck1443s0;!d3s0t3;d0s3t0;e9h1F;i30o64ByC6;eC18h45CFi414k12Fo3ED7t1D0;!i71t71Ay63;!a5e4s0y0;a185n3o29;r58t3u16D;!b1A0e15i6s0y0;e2243;a4D54l4AB6r24E1u4E;!n3DEDrC8s0t82u61;!e16A5i2BA2k5Dl7n22s0;!d0n375s0;eAg1;i6BDo1E06;g2BB0q32BvBD;a4949b1A05c42CAd27FCeF0Ef142Eg418Dh3A91i1105j1CA9k4F09l1851m1B83n4C2Do5123p4F27q12EFr3E43s1852t2A6Cu49EEv334Cw35A4xFB4y1B71z1F68;a1e1i3F;l3m1;n50Cs5;!l0m167;i1000;!cB9l62n1167s14;a104d1l8r40;a17o93;a3D7eC4l4898o49ACr17D;!c2633d30D7g2302i2D8l4F34m1218p21AEr4C42s0t4CDB;!s0w599;a275r19B;!e5l25nA1s0;e12i96;!d0e0;b7Bt13F;a29Au34;a20u34;eAi3F8;e39B;eEo10y0;!e4218m165;a59o1BF;e416;!i4A2s0;n1r0s8t2F;!d0r1s3Ex0;a2B9BbB1cB2g283i32F3l2A45n1A6p5EFr106Cs4154t41DBv4D9Fz1701;cBd34E6e276Di28DFl3B5Cm209Do4DA5p19BEt1B4;!a682e30D5h17Di21FDk44Fl4F6F;c3300nFs11;t5C1;!e12f37i6l59Bs0;a4BF8b47B5c2CC2d27BAh5035l29D0o46C3rF09s3F83t1084uBDFz45D;e33Ei67y0;c121dEB0s0;bFB0c13CBdE9Be3F74f32E9g2298h219Ai17E1jD2Ak4E9Bl37CDm4492n2A57p4701r20CEs32ABt39D6u4535v22B6w43A2x56y3EF3z3AD0;e2C6;g0k0;lE7n8;n44BDs8u5;!e2D13i90Cl7n22o31E;d0e9r19Ct16;a47A1;s8t3v3;c8i8B3;iBE;!a1Db4F92e9i2060k5Dl7m400Fn22o3A12p1637s0;!i1DBl7s0y0;e4060o284;hEn400;!z3A4;l2Cn89rE7t4F3C;!e4f37l22s0;e300Fi67y0;a36E;c85A;a1AB1e40Bi26B3o46;!a4C3Ec1DC9e1Df53Fh1957o31rF7Bs0t4931uAD0;!a4De249i45C2o27ADs3EyF6;n4s3A5;a2C88e10CFi4FC4o3F26u2CE;!a164e164f37i36Al7;!e4i18s0;o22BF;!a1De1Di1302o1677s0y63;n39B0;!a4C1e12i48DEo1DCs0y0;r15F9;e15i199l2Cy0;!a7FeAi6s0;a299t20;!l1137r36s7A9;!d1e4s0;!a3905d184f53Fi1C6Bl4733s0u27A1;nB56;!i27o6y0;a109B;a3145i1C86o12u403;!g9Fm1EBn3Bo47CCr9BCs0u6CD;d2543w3859;a1ABEe30FDi2C5o1DC;cB2t103z930;o42u447;!d0l7r441s0v3D;t37BE;bB1l1636n2F0Cr9C9;l45BAs508At4684;e1iB;!e15Dh1iCCk5Ds0y0;!e5iB;r2A2;d0e4;i238l3uD4A;eD9l6A;d1CsB;n0r1F5;rC8;!p3309s0t0;b631;e15Bo72;b1Ad28k28;!a4Bd0s0;eEBy0;!aB06e4D84i4550l24Fn22o28s0u4Ey0;i9B6l44;c47x4F69;e12h1ABr2D;e15i199l44o72y0;e40D3i37E9;!nF;a275n2r1;!tE2;!r133s0;cEt1x5D0;o247C;r25y1;h2AE;n8C2;!e23i6s0;e23i6s0;!e6D2i6s0;!aC11e1554i18DCl4A9Co3702r3EC9t67FuC35y63;!a1De4i34E9n38o128s0y0;c2B7p1B32t35A7;b4418;!e12Eh109m165s0w98;e4A28;!l7s0t1E;!a20bCD9cEBDd4F53fF2g3EFk5Dm1417nFo10p2A0s4E24u34v1413;!c1s0u11A;n195;e15i5D7y0;i1F5CoE9E;e4B99iCBy0;a40h0i10A;a12e23i2A4;i292Ey63;r70t27;!i88o36s0;l2A2;!d0r74Bs0t88v38;eA4;!n3F5Es0;!e7i3Cs0;!e8i1s0;l411o1;!c3D;!c160;b6B;m455Bo423t2AAF;o1A8C;c4As1275;hA73;a2685o51;e105l19o393;a10n2o10;p3CA9;e16Ai3320;b1872e34DFi6l1963t21D4;e1i314Fo29r18CAt3B;a2929b3547c2E6Ad45C0e3AA9f375g32ACh27A5k18Fl5127mCB5n4AC4o4F78p1B6Ar2A26s16D6t511DvDA7x2BFDz3B46;k4A5m28p28;!o35s0;r2F3A;lB4r10;b1Cg3n65;!a5As0u1;a34DCeCF8s2E3Et2081;!a4542c232e2897fB5h4E98i1DB6l38m2Eo41Es18E6t1429w4D37;c7t39E0;!pB48s0;h4DDB;a12F6e3CCFi2F5r22;l47t39;d52E;!c9Ek141r28s0;l1n27;a2F66e40i341E;a2FEi169o9;o558;r152D;e17E;a4Ae15i21;!bFEe4i6l22s0;a20i10o29;!a88g1Aj9Fs1A5Au34;a327;l3AtB7;p1A14;!a3242e43F6m8Bs0;h2751;a2A48;h356D;sB52t103;r3DE4t352;f0v23A5;k207y0;e1h28B8t2EEB;c9EzC8;aA04;l175;l1B70;c1F28g5FAl1E6Cn1609r35E3t46D8;a2311;!kA9s0;c19e5n125;!a471Dc3F2e2CD2h2F5Ak4CC5l19r4577s0u18A8;oCs179;!e0fC2h9FlA3Dm2Ep314s0w124;aB21;rA00s1F;a22B;i8DoF;a1bFCc36C7e3A65h4D29i303Ck448q11Ds2EB4t22D2u4284;i15A1n1237o3EA6;a0n1E0t103u14;!a543e4i311l22o3F91s0;a41E1o2343;c4633eDBt0;a17F1b21E1e1Df1796h1580i0k18E7l3A39m3363n3DD9o33FCp217Er2C01s1439tF80u409Bw27C5;d0t214;p54D;!p54D;eCF1i1606o33A3;!a4De3B8h28i3894n1E0s0;a72De15Di2BEl2Cu16Dy0;!l15Fn28o1A7r801s0;e164Eo4583;e40o6C;!h78y0;cEDr3;e2098iBEl1FD6o41F7r255Cu3AC9y52;!b151iBl22p165s0;h3Bt13F7;!r1s0t1;r3s9A;a61Fe1;m7sBD;!e4i1C5o0s0;!i6pE;!c32e5o715;f284Ft424B;a19B2e23i67o128y0;e406Fi2610;!r7s0y0;a9c0s8;!eFFi1C5s0;aD05;!e148i259s0y0;c19s5C4;m2B8u59;a272;!b4C6Ee1FEi100Dm3FE5p421Ds0;!d0r2FB5s0;!d0nEo1s0;l13E9;!e2CCi326s0;rFD;!e15i6C7s0y0;r39s0;a2C0o31;t770;o11C7;b422;c5071dAB5f275BlABn2B91s232t4B98;!e24i6u3D;a10oE;!a3CB4b1DA3c1E5e15f17Bg25Dh4ABi189l3ABCm3B7En2A8r2C3Bs3DF1w3598y0;m2En2B4o10;r16F;!o9y0;a1i77;e1i39C1;i3AE4;!a1966b238CeC9AgD6i4643m32C8p1s0uEy0;aA2e1f4E89iF0t8B;e40i27y0;a2D3A;!c17Bd0s50E;n37B8;!a3F86e3229i3F4l7m357En22o1p28r3EE6sA0Du3A6Ey0;!a0eDl7;d31E7;n48F4;n4B7;j1As3E35;gB28rFC;!n294;a20c3Du14;h1At1;!fC2l14C6m233Ep24C3s0wA8y98;!d0l22r28s0;t4506uEz3;c32dB;!e20Di26F2o37E0s0y0;r2A2y1;e3C00i71oB44y63;i2C08t1A6C;eFBi3D;d214;a5D1e35;dBs0;l5F9y0;u269;g7rE15;!m2Eo6Ft196;!h27s0tA9;e15iAC;b107;a1DnBA1t3;a844;y75;s291;fF2n10DC;h4161tC3F;!l1AC8s0;f89j0;n6Cu14;eDk3l7;g20;!e4i2F0s0y0;n62r83u6Ex2DFF;p28s6D1;e5g23D4l510Dn2;nFtB4;l76rA3Bu650;h1B3A;e1Bn416E;i110o8C;!a761i1s0v4F8E;c226;!d8As0;eBA4o272yC4;e1f38l396F;e0o31;!a4Be15i43s0y0;!b3263c26ECd4E23e374Fi1512l4D5m4C58n2B7Ao221Dp840r3Ds244Ct4A4x1Fz3E6A;!h1B4i2028s0t38;!e1i13r7s0;i55A;nB5;gA5o1Cp16;e5fF2nF;!bFEeC1i17Al7n22p674s0wBF;!a4Be15i43p4Cs0y0;i114Ay0;a13E5b21F3c442Ed38e3AFg2820l48A6m335Cn317Bp3B09s4A86t225E;!n65s0;!e3614i1947r4107;!d4FBe0i508Bl2CC6n1ABCr302Bs0;!b7Be112n2s0;i4o46;!d2080g1842k28n58s0t2D1C;a1oC4rAA;l2C4;a298Bl1n188ArBCs454tCAC;i663;!e4i13r7s0;a369i64o159r31BFu24AD;u298C;n8r1t3;e15i21l2C;!i4F0s0y63;a1c13Ae20C;i22E7o3487;i952;!a40i0s0u5;lA7n1o10p29s3CD1t4A35u5w1;k1El1E;!s0t7A;a0c0u14;c4Fe12t3A;u57y1FFD;a7B6e26Ai6;a4195e3DECg214i4642o35C4u1CD3;r5B7;o6CC;!a40AAcB2e5h4E5Ai17CAr1941s0tEF0u2FE0;!d0e0f37r1s0;s52t6A;!h478Ei54k5Dl129;aCiDDo433;e5Bi67Dy0;h49E5;!c0n0s14;!a2712b2780c626e0f8g3FB1m330AnD7ApD62r4EB3s0u4C96v5Dw2E85x4AF1;b52Fd3nE;a1e1o1;o8u8y0;c387Ef77CsE;a3E27b2A4Ee1o876;!a4Dn8r16s0;i30rEsEu12w27;!d8Ai96;e22C9o19E;g226x1F;d1i5F7;a3BD7bF5i1FBA;eF60i2C71;c133F;u6A;d3m7;o6DC;o4F9E;g1iBB;eA3o1;oCt161E;l1t29B5;s6A;!e5hF7;e1hF7;!s0u49;!e4i6s1BC;a3EB0e20FCh3578iF94l356Fo29ABr1BC0u2F82;a11A;a4E;c13At0;!i5A7s0;n304;e2495i21;!e6Ei2Bs1Fy0;a1EEe201i50C9o1811u4E;n3179o29;p263D;!e391g1s0;a36D6d155e163iAC4l42C3o41C8s49E4u26F6v4899;a40e279i10;a36eBiBoD7E;x122;d0n8uD;!e15m2Es0;g4An174;d0p1;!a170e4F07hFFAs0;!b29g3E01r1s0;h45D;eB9;rD64;d2B3t0;l1n4t3;d17BDe34f207Ag48D0i1A5l4C9Eo410pB;a5003eEiADo3899r57A;lCn3s11;i16B5y0;!d0l22m2Er1s0t1F4w183D;!b103l3F5m1B25p10Bs0;i4EEk53;n35CB;e15i21o72;c47i4;!c3E52d38e1g3A47i20k28l5Dn2539s0t28;a4227d11Fe3FBCi3094k692l4713o3681t358Ay3798;h2BD6;!a1FE0c46F7d1e201g44i3F3Bk1B88l212Cm1F8n37CCo7E2pBEBq858r141s0t4DCCy0;n13;!o938s0;c24C0i1Ck48AFn3F03o3EDBp2ECEq333Ds1CC1tF92u30D2;d3Ar625s5;!e15i6l19s1BC;m18n0;a13e5t7;s421w0;c2At1;!d0m4508s0;a5041b8E5c1783d7Fe4139g49DAjF3Al29A2n3EA7p11D1s369Bt3C08v353zE56;a4AFFb3496c30EFd1EBBe34CBf369Cg1C1Ek17C0l3AF8m30A7n4B40oF98p3086q458Er3590s4E50t4FBDu1616v1ECBx191Ez45E8;i31l4721;!d0s0u5B1;a2C0i36;d16l4B80r31C3t1E;n28p28s9E;d0e0s3;aCi2B1;l1o29tE5;c244t0;d188g133;e108;!e0h10D6i0s0;m82;!d8Al342As0;s3t3z3;a16A6b1A21cCBCd3C16e1ADAf1044g1BD1l1826m101Cn1A26o4C99p1483s2D0Dt12D8v3DC9yC8z1A;!g4875s0;a1d1CE0e3892g94l400Do1A1Bp21Cs4E81;h1083;!a1E00e3D12i43Al22o37A2p165s0;aBCe931i57;a10i5F;a75u28C;!d181Be0h4040i29E2l7n22;!e193l7s0;!a176d0l1r1s0;d1n25r195t890;!l3A98s0;v4;!pA5;!a981e3484i433Fs0u433E;h2FFCi5070;!e4iDDo12s0;!a4B58e5Di0oE8s0u5;d35E7e24;s8AwA1;!l7n324Er0s3E;d0s11;!oEs0tB;h3EC7l76;!a457Ee4i1ECn22s0y0;eFFi43y0;o1F21;e1Dn3B0F;e10i2CB8p22C0tC0u3F13;aDh0tB70;t8FAz1A;r1061;!i53;d75Cn62;d36E0e23i21;!e3EAi6s0;!e4i6kDFs0;f253Dt0;!a4DbC2EcD27e7F1fC2h0i6l22p5Dr315Ds1A07t3396;b1Cf361;o2EEr22A;!b1ChBmED9s0;e4238i6;l1Dr40;t37C0;a21F4bD46c4B0Cd1BB3e49F8f33DDg103Ah2CE9i38EFj27C6k199El4832m30BDn351Co2C80p4D4Er4865s37D6t327Eu40CEv5Dw19F4xC5y38BDz16AC;!a8e193oDs0;h35A;e1g2D2Cl3CD9r35C9y95F;o50At53C;c1FFE;!m0o10t0;!e15i2FE4o454Fs0u610w98;n642;f993p43DDr1A1s20v2D;aCc2900e23g48AAi46A4k4D9Bn812o4488p192Fr4B5At3827y0;!a45F1b184dE95e506f1DABh3CEi3C57k1l118Am495An12Fp4BB2r21D1s4DB5t36DEw3EFy0;p2FF2;z35DE;n430Fz47E1;e1C1;d1Al1At2318;a54e73i51;b62i83sB;d47n47r34t0x0;a2D0Fd58e3257i36AFl1066m1CB2n1F90s2415tFBFu4Ev2349y63;h27lF4;!t397;d2C1k36A9lFCr43A1;a1De1i29E9;a12e51F;a1A59e3E51g463Di4El3E60m18o4192r3705;a2F0F;!l1n0r1s0w80;p0w0;!b129c33BAe46B4fE0Fh30E5l3939n22p48FCs1969t12F0;t50E5;!a7EAe4i6s0;a29EEe17B2i33C3o3C77y143;e1n3C6F;e8CA;!c0i1;i4o213;t202E;!e24F6iA36lBsA1t2515y0;!a448Bb39C0c4423d5085e2947fE53gF78h3EE9i1B86j39C4l4B7Cm1185oE3Cp3462s3454t2CC0u1181v1DB5wA8z2B1D;t1068;e18Dh36E6i21k40C0t39EC;c7s7t2D;nFs19z19;!a12b43Dc4FD4d2A8g4948h3B44l55Cm17DCn1B3Cp2972q32Br40A3s1964t253Cw6A;eC31;a1e11y18;!e15i6l7s0;aF6Ad1g4803m1C6n148Dp27D4s11tDD0;b4B5Cc399Cd1186e507Bg49C0hD7Di129Dl4248m1E08nC01o2C6Fp835r1F80s4CA2t469Eu2A17v3C71w26A8x42E5y2CC5zEA7;aD5o40AE;d47iEr47;h460;a159d5BeAi21;g17C2m64;e12o81;s1Ft717;l1E31;!d0e319i6C7kA4s1567t1F2B;o4F6;e85i6;!a84BeB75u34;i8l3;a3E2eAi573o29u34;l0r8EA;h426Fk4605o0;!a9AEe4B1Bi6m1EBs0;o422;e26o6D;!e5kB;s3A69;a1165e86Di18DAl4FC3o4DE6r40E8u28AE;c2Ar9;!e15i186As0y0;e24nFo10s1F;h248Ai0o595u4E;a5E1;a0h2C3o0;!a215b5E8c9Fd0l3BBBm2Er34F2sECw3562;b45DCc1E9d1E2Ag317Fi447DjF37k13F9l4850m5E4n1A11o3EEFp840r30DCs0u1DD4wE05;a3DA3e28EDi553o2C5Du1F50;d0m0r1;!d9F6e1f17Bs0;!e1i1F3B;a7Fe2638i199y0;a1t3;d1B4t0;e762i6;m107t1F95;a3128e64BlA5o241yC4;oCu14;a44D;!l181s0;!eFFi21s0;c0f2D;!i25nD2p221Es20F;!c30Ck1970;dBr9;n3s106;u11FF;e15i43l8E3;fBFt810z1C2;g1AlA3BnDEEr2AD;!e6C2s0;h5D0;!a4De23i480;d1s11;a70Ae11AFi8E7y0z184;i2o2;aCeB9;!e176Ch3F6Fi46EFoE72t271Au2AA;eAi9s638;!e3AB5r2DDy0;e4Dl35o51AtC5;l47E6;dD35nD1;!e15i76Cs0;!e565i6;a290Ec8A1d65Fe4A59i10A3m3362n25D2qB6FrBs3EE4t2657;e23FBo4BD5;!aE19cB2d44C1e432Cf183i2888n1348o5010p2326r85Cs1E3Ft1171u3275z56;a1D1nF;!a3689i470o46s0;aCe1i18;h31B3lE3o3233rB3C;o99y0;a46D1i71y63;eD2Ei34l2D63n28o1833p1t3DE7;k3t52;a2778e27l2840;l106n3605;o24B;l0r78s3t3;!l0r7s0t3;o34sF7;!n3CB6;a4222u14;!i6r55;h0r0;!d1Ee15i6s0;!e12fB5oE4s0;e33m0t0;a2E4Ce54o8A;f37l4FCE;!a538d0n61s0w16;!a7Di4638s0;e384i4C05y0;tACA;e779;i77y0;d0l2C0Ar1s3E;t26CF;d87i163;!d0n0r2BA6;s5w10;l300;k1Et16;eE6l282E;!l41DDm1n18r4CEBs735;k53C;!g45C3h2C3Ci12s0u9F;r5100;p4911;a4De3B8i199y0;!s0w80;r137y4E70;e4i289y1639;!i3Cl2Cs0y0;e23i30F1t38y0;o4AB9;!a7Fc9EeAi1279k2CA2n3CEAs0t5;!bFCh283A;l1t0;!d0l1r211s0;a31o20y61;!a300Ab4840e15f34E1i21l2178m2ABBr261s17CFt16Cw25D;r64A;!d186e4i6s0;l276;dBl35;!h130Fi462o4629pA9Br35C8s0;n44q32B;e30Ei6;!e3196i6;h39BuA83;!e68iCCy0;!aCe5i2B0As0;eAi13o36;l269;s2D34;e1DFi6;a1e1o245C;!b151e1fC2h27i4D15s48F7t4A1BwB4C;e89F;!eEi26D3s0y0;dF2r118s45DFw38;g94k16n3C5Dt412E;p2762;!e4i3D1Fr35s0;iAA9;!aE9o29;aE9o29;!k4Ct39;g3x0;e1t18;l37FnFo1A7;c2896e1g240Ek2Cl2DC4p4440r4AC7s4A3CtBw2CF6z48E;h34;eA45i71k26E4y63;c2Cl30D1n13Er1EB2s169t36Dy28;r3F40;cC9Df492Eg2449i2C04n509Dp31Cq11Ds22C7t4620u1550y23FDz1A;!a22F1b27Ce15h5Ai4D99l7Em2Es2B6EwCD7y457;!c32e24i6s0;c261EeD4CgD33k21ECn12A;!k7;!e68gD8i6;!r3557;c8B;!i6s23B7w172;e15h37FDi67lBy0;a8m14C;sCE;g94mBn2;d5Fe68;!e5s3;!c2B26o414Au50C2;c53h3;!e9y0;!b2B9Cc37FAdEDBi6m2En25r3EF5s0t3B57z41;eAh460i6o4ECF;e9l2C;!l1r1s0t2940;c2DtB;!e12i6;!k5DnF3t58w2A0;!e27D0i1l1326mA17s0t1;r4C91s202B;a1AB8l19o60CuE2;e12i237B;a1n18;l14Co32u36;!l2C94n22s0;d43F5;n2s6DE;i43E4l36Et12FFu3DB1;m684;sEu14;!a269Di13o29s0;!d0s0tE42;e1u34;a49o2C0uC;i65o1DC;!jFEp314s0;h7i13;a1D2Be3FB7i2BC2o1C68u3EF8;r1D41;a213C;!iAFm1r3Bs0;!e0n3;!a4De12i6o130s0;t1zB;e1o10r1s5;a42i1566;i1B3u9CC;c3368;a0e4C9i4E;nBs0;!a18Ee3Di20s0;a1eB34i203Bo36;e5i4BEF;d27i2EF;eAi6s3At39;d1i10;e7i91;c0oB09;!e1i20A;d1Ce0;e349;a1EFDe4FFBi13D0o4FFEr7EBu14A5y18F7;!b1Ci4l1w0y1;h11Fo5DEp1CE;i566;!c11s0t27;!c124e8Co1B3Dr89s0;nB80;a4EE4;a338Ds1F;a45ED;!g1E8Bj424oEs912;!c36E5eAD6i381l6Bm2Ep730s46BDy0;oEA4;a25oDC;i35F9l3A0;i57oE;n1r3A5t1C8xAE;l4E35sEt2451;s125Ct1CD1;l216;a2672e0i402Bo12yC4A;i6BD;!e5i4A7Dn16BEs3E9;r39u12;!n30B1s8;nFr61Es11;a36i4751;!aCr7s0;a2971e1109h2E41i181Fo3992r493Au1338y2B19;o302;!e0m35r7;!a2E4Bc441d4351e1DFg33A0i4FC9j3C3Ck194Al35D2n3E53q30Ds2B48t2830x5C5y8Bz39C;a2EFBe3339l226Eo293Cr4091u1BF5;aCo0;!a4Be4i21l22s0u49y0;a20eA;l7t2D;o3377;e0i2BF1y0;w373;l2B;oB90;l115;r1A2;c1n1s34;d292l37B7s5092;w1C01;h38FDl1C20;d1n52;!e0g4E0s0;a1C8Ae31DBl3CB1o93u984;e1o1Ct1;r57;!aB1Be2CCi914s0;c135tD7;e2BDEi66Bu4E;a1D8D;e1BnFs52Dt3B;a3E34c0;f428E;!k28r4A01s15D6t2FB4;e2B36i21pA4;!e12i21lE3s0;eC43u4B74;n158;n1pD8;!b180e2CCh656i410Cl119Fs1Fy0;sF5zF5;!c324As0;!e15i43o9Bs0y0;!e129Ai6k95Ds0y0;!e113r38Ds0;a1DiB67;hAEt28;e204i42EAr24BEs0u7AC;u30A;e5ABi86y0;a3E2u34;e20Di6B5y0;c160e5sAF8z47;e26Ai6;!e7A5i6;a222DeB;u7D;d1nAECs1F;i2D8s3u5;e42ADgF2Ds83z44;!b228Ee15i21n0r1As0;h196;e6D5;i41y0;a120i123BoD7y0;e3F4Ci6;e4i6r2C67s0;eD08;!b2A18e5i56s10A7t0;!c2C4l78Bn288Er28BFt2DF0vB1;!a2215e33A5h38i1D85s0t2578;a3EFA;oEs408t2F9F;!dA8;a1BD4i36;!a163eAi6k2E5o1s0;h279C;o493;!a19CDc1FAd3FF2e3fA80g2334i154Cl2E13o4208s0t22C3u405y7E;eAi381y0;!d38l28s0;d3l4F;t2ED8;!e1EhA5;a3D92e1C25i3390l4869o3134rD6u9BF;!e68iCBk4C;e1i38;a3135e0i41FEo51Bu2C5;!e4Ch3A50i19D9s0;b3F7Ff1B0Dm13E4n1999p1F3t3DCDz2C;a2DE2;!e38i13s0;a23D3b1C63c15E7d2F9Ee1D4Ff1373g485Bh38D9i4C08j3979k4BC0l3566m2207n1E53p36F0q36B6r1E0Cs2F05t4A02u88Av160Dw50A7y12D7z135C;!i2DE;d0g47;!g350z3160;!e24i6m546o62p4C;i488l1n1At3;!b398As0;n2s5B;a1c121m82t445;eAn2;eC1i6;k191;c4C85;r3FF6;a51dBi45C1l435Fm5000r232Du12EDv3;!hEAl24F;e93o29s19;!c466Dk1As0;!l60tB;r0u1B2;i59Do3B;!i123s0;!e4fACCi6r320s0;oEp28r3s9E;a424;d0l4E5Dr1s4E;g1r1;a104eC4;a3972i3B59l1n6E8o3ADF;!g19s671t16;u17;!e17i2DCl7s0;u2342;!l2B4s0t1;a104eC4lA5oC4rAAyC4;!b21Fl1n2A2s0;a42i59o25BA;c4E4F;c0d3f7u14;a789e31ACi19o313Ay7E;f2Dl3;iBF0u5;g1F3;n25r1tB;e3286h1CC2l1E2;!b180e12m2Es0t38;a4Bc0e24tA2D;!a1132e199Ah1EDCi17B8n76o1F0s49E7t279Fy0;a4F76d1De20E7f1F1h2113i6k2C97l44FBmB9n1623o4C17r27C0s0;a135e470Ao3870;u2A9;a36e150Do1Cy1C;!u2A9;aA2iE;!a2E6Be4028i2210o301As0u15F7v21Ey7E;a394Be0o2EBEu14;e3162;!a41F1e68iEE5kF3l22m2EoD8p236u4Ew3F5;e16A4i86l47y0;e4i6o241;!a3DFe607i21m2Es0wA8;b1Cg15A;!d0m38Bn0r1F5s0;n34B1;l3n2o9v3;!g55;g55;!e12E2i6s0y0;o44D;e604o4835;!a1bBdA8e507Ef53Fh13EEi21oD17p2E4s3Ew37B;a8F5;gD6l161;a3696e4ABFi143o4CA6r709u4D5D;n1w90;r8A3t40;s3509;e385i43lBy0;a20e30;!n41Cs0;c463Ai15B0s76u3F34w2713y38;e48CAi6y0;u2DB;a14D8b9Fe28B6g8Bi3271m61Dn1o2Fr710s8u29D5z5A;a59D;g18A1i35;iBBu5y0;!g1i1As0;e28D2y237;!a3382c44A4d546f4FE4l3AC8m3238n27CDo18EFp169Dq4A68rB19s5066tE2Bv4EA9;m4CA1;!e1Bi3Cl7s0t7;gBnFr34;!g4E36s0uE7;i3F32;a0n2u14;a49EDe16F2i240Fo4BDEu47B7y440C;a54i51r1E1;a4C15eE64;!a4D9Ed2C8Ae29A5i1716n3B4Ao467Cr1AE4s1ED3t28A2zA86;m47t40A4;!i3920s0y0;c1Ed1Ez1E;a4C2eCFA;!a7Fe3DDh183iBAl1B18s78y0;cEDd176Bg4Ai5n598p1398r30A8s25E8t2CB6v1DCC;e12l2C;u20v19;d9Fm1A;n1tDA2;eBi396t3648;iD75;!p224Fs0;!d27g16;a2C69e1A9Fi15FFj89Cl4102oEFEr3704u4323y2031;!a1l7;f32C4;!d7Ag44s0;l1t90;aBEo16A;d3An4D1C;!n23A3;a1FFd158Ai127n637o198Ep31Cs1B43t102Au1D73v103w35A1y1;c2A2Ed1C4Dl2ED3t291v45B;!b498d212e15f1A0Bg3A8h2BBDi402j9DEl6F7n0o51Ap38Ds27AAy0z4CF;l27oA6;g38ACo10;l179;!e93Di21l76s0w136y0;e30Ei6o17;e701hB;s19t1E9F;a192c62;k3sEv3;i4E08oD;a1n3t3;e45EEoD;!a4FA1e1342g394Fi433Bl26C7m433Cn287FoEpDEsECu48E6;!a926d0e68Df87l22pAB4s3028yB;l1AE;e1i170;i1983;a7E8;!e24i505Dm2Ey0;a104e241;i1At10A;t33C8;d0r1s65;i1CA8y0;c160s102;g5A5m2F88nEp32D5s4D44t2D44;a2773b219Bc2410g3355m1C0p1r4275s44z1A37;e42i3AA0o72y0;h9Co54uE;a2C2d2710e5Fk1l1F8t196;c4F3Bi22BBr8FAy0;!e4f37i86l19s0y0;!eD0i4529s0y63;!t1x8D7;!b35AEl7n22s0;rB3C;h139Et3AAA;m5Fn18BBr8s13E;!a52eD1iEs0;i9o40;iA38y0;a0o1868;k187nF03o8t3D1u168;i10r14D;a3D6;m92o34t5B;!b41F4c4Ae0;a4223e1;!n205r1D2s0;a1155eADiE70uF21;a225i20o21CAu36DB;!e4i6l216s0;!b14Dc3F1d3FEg1CF3i4n364s0t1A56x116;bFC;!d836r35s0;a40u2D2;l40C7;!i13D;u1469;o11Eu791;o1C10r358u3E48;w8B;rA;n1s3z3;eAi91y0;aCD8i168m1;!e1FBfB5i189l309mB3Bo1s0w413Dy0;!a0o10s0u34;a4837b472Ee1699i248CmB1o28DDp2F74s452u3A4E;e0oBCE;!e15i6l119s0;!a5cBe15Cs0;t23Ay48;eDo9;a2AAe50E1o41C9;l63pCEy0;b516;b1Cx5E;n3F1Bt22A;!cE;s5Et35;m4F;l1AAt44C;r8A;a36Ee17i2DB0;e2BDBr20A6;b504d4FD8f4C43g857l35BCn2FE8r4220s444t12B2z2D33;u1F9;b121Fc3B3Dd1C07e3ACCg25C3h49B5i27D1j1ACCk2E1Cl2B4Fm35E4n4230o3752p1C9Dr2AE2s4630t4559u1A88v422BwCB0x29DFy1A51z22D5;!f1Cn1s0u34;a10oF3B;!b1D5c402Cd3Be4g63Ci91l489p5Ds0y0;eD0i31B;bC9;i19B;s11C;!n7As0t1A;e1D47i4F8y0;a2A0Do719;!e4g5Bi6n1p116s0;c0n16C8s7BF;nD2p404;a2041;a3A9Ee24E4i21;d16g224C;d226s0;!i21o16C4p4429s274A;!e9i91s0wEAy0;!r7s0t53;e1B8Bi24F8s3CFCu0;!e3B6Cg7Ah30AEl56o10r11B4s0;!a4DfC2iD6Es0t8E0u1;a40n8;o616;eF82i6;e9i9;c3DnF;r40AzCFD;a1CA2e560f0h17Di2B06l3B1Am4464o3298tF2Bv1727;c22Bs83;a442d1902g128l2Cn48DDs296t1;t19vB64;!d92i6k2Fl1p2D8Bs1DB7;o79Bs115u5;o8y0;e20g1o1739y34;!n70s0t7F3;l0n8t3;e4E7C;a42h3BF8i36;e8i0o1;!e4i32Fs0;e4i6l44;!e1Bi3Fl7s0;h39;oE8r197;u4BE;a20i3F8;i4B46;t3FF;t161;r90s3u1B2;k4202s1F;!eD0f37i8Es0t0y0;!iB8n4892s0;c4296g16A0;d2Ci2843n491Cp30DDs218;d0iEr1;a38C4e43C7i673o215;!a2679e1i71s0v1D44y63;n3BB4;r514D;!l0s0t2D;a46BCb4836d17Cf540k8C1m34B6o7B9p43B1;aCi4D30;aBEe4iBAo4BA4y0;!a428e12f37i67l22s0y0;a4DeAi6;!m0s0;mBn1Fr18;x4C0;h4B24;s2Cz2C;a1721;dA1nFt472A;n18F5;!d0s0y28;!c6Ad0fE2m2Es0w80y0;e4778;!i29Ao1s0;e21D5i5Fk42FBs56t0u49;f4761;n36BAy16;c232e30EDh11Fi42C4o28F0rAE4t3D70y0z11AA;!e5s0y0;z12D;c9Et5B;e2241i4EAC;s7t3;!e5s1F;!e4i1C5l321s0;e48A0;eDl7n2o1;t2BED;!e4i621s0y0;n2s27F;!e4i2BEs0y0;a46F4;h5BE;h19;a44AFc1FD5e2E20fBFo46E7s4E7x0;l2B40r8A5;!e4i20As0;h1Fi8DsB;!e24i29C;a57l24D;!a8ECe502Bh2A69l4436o615s0u4601;u197D;a59e17;e23i253;r7s0;c3d41;a1De24;c18s2A;!e4i6l2Cs591u4E;l13Cs13A;e3D3Ci7C;e1g8B7n12AuE;!fE2i91s0tBwAEFy0;a2C1A;rBs1F;s6C5;d2BCCmB;h4CF9;a3B66h3644o1;!a40i13o29s0;e1576i29B;d72Am4DBp48;x1F76;!c736d70g35p46FAr61s0x35;!e21Ai123l7u49;t8C1;i1709o46;n684;a4401;i223t56;r3A1;!b362Dc2D7BdB49e15f1774g9CDh75Ai383lD0Fm2En28p1BD5s2DBBt4156w3D80y0;!e68i652y0;!m4A3r1A94t3C61;a159e442t1EFAv3DC;a57i57;a406A;k3nF;e1l18;e799;e9DA;!e4i227Cl309s0wAEFy0;dBn1A;e575;!e40;!c0e1Bn3;!b5E8s0;d0r2Ft5DD;a10l54F;e4728o105y20;!d0k3Br1s0;r3F64;a39B2e9D;c3m1;a51r31;r2A5;a1D28b2E96c1C2Ed4BADe12f1k4826l3465m2270n3DACo753p1CDCr38ECsFDFt2B4Cv1Aw5A;e1Di123;n38F8;a474;a36e1;!a323o1s0t7;h229t3C1C;a5Cf3B26t474C;l16n1E;f28k6E8m1s4C5F;!aA59b1E8e4i1D90o127s0;!b2E0Dc636r1A;i3F92k5DlB5BpBr3A85s18EE;i81;!a4Dd7FAe15f37i21l6A8m198Bs0;o30EA;a18Ee5;a315s1F;cD1x55;!e4B4i6lF4s0;t56y56;rE00uE7;e1t88;a3123e345Ci33A6o22ABu2FFByB02;eCEC;a8F5o29;!b956e10s0;f2FBn2;!i71y63;c19e30lBnFtB4;!e15Di67l2D73s0y0;c18Bn3AA8r2EEEsE;d17Ce46E5gBh2100i341Ck28l28n382Ft3340;e4A2;t836;c1644z3478;l4E01mF6;i37C;i6o1806;cBf1l2A76vB;!c18C;l3DDD;!d0i6r2C7s266Fz1B6;c7g19;!i163Ds0tA9;eBi497Bo0;eDr1352;a30i2400o10;!h9Ci3;e5n3;!e23i6t1;a52o29;f1g29F1s8t21DvB;n0r3;n3r0;u584;i2C87;e2B0i67k3700y0;a16DEe26C8i1BFEl30F8o118Fr4AFCt2AE5uEy322C;!a650h76k4025o363s0;c1A0e5;e1q11D;a449e1r4C68;t11F;l3r82;a0c0d0;g5Bl70n2Ds1119;a9e9i31;!e15i621s0;n16v5F;c158d84l4997n749r642;!e0r78t3;b7BnF;a44BBi13o29;h87s2C;fEn14C;r48AD;eAi6t1;a0e5u14;o4B1C;dD2nBt2373;oAB8;l2E6n3BA1r314E;rBx1F;e4i6o1;a75o9u14;c776e1s102t58;l131Br3FA;t143F;o4800r53C;l3u5;l14C;!e15f37iCCl2D92m64s0y0;t141D;a20o935;!e1l7s0;d0f1r0s0v7ED;a3i41;l4CA0t1;aDCe4i6;!a4De3FE3f37i2529o5F1s0y3985;l12D;!e129;m2C3;!sB4Dt126E;!a19CAe2B89i378El4BB7o115FrA8s0u2612;c97;e2E53;b622;a0e0i1D6D;d28e113n28;i5A7;d1r36E3s8;e2D02i6;c3D13f240l3ECn2sE;a22De2CBoAE9y2DB4;a12u264;a18A9b21B7e498Ci3290m234Ao2691t35DuBE;i25l4263n1pD2B;!d0r1s18DEt790;!i32CBs0;a161;a1De319i4A0;nB48t0;o5072;!e5m2E;aCn2s1DAz3;a2759o36;e4i86l2Cy0;m116rA63;!e7C2i6p4C;c160n2;o2450;b3613c2A02d0f2B07g1067i41AAkBm4A31n4493p1248sD1t1C8u2504v3w150AyF1Cz89;e9i13;e4i199lDFDy0;!aA76i91s53At382Cy0;!a159e4i6s0;!m1n1;m1n1;eAi135Eo46;d28k9D7l28p2C7t3B5z3F51;!e24l7y0;!s401;h554;!d0e1l1F6s0;i10EE;e15i2F0y0;!e688i6s0;l2C70;n0s1DAz3;i483o291D;!a8B2n322Ar29BEs1591;g1i1392o46y0;e44C0oA2r84;i40AC;t112C;!a41CAe68i3EEDl22m2Eo3C86y7E;b7Bs3E63v4B5;c341g341;!e141Cy0;c7D4e4A7g58n2;b1Cn2u34;b2235dFCe3947i43EFm3628nFCs27E4;!e15i21l76s0t212;!e18DiDDs0;f7n2s3z3;a351eC1i505Fo1u4E94y3C49;!s293y1;t374;a10l77;!a39FFg343Fm22EEn38CEo4C52p2E0As48B0t281u164z1319;!a2469cB8Cd1BA5e4D96f49D4i320DkDEl4512s0t7B1v2DDF;!i422Cl7s0;aC03e17iB31o1y0;a13u5;!r1s5;!nEBs0;!k1En1Es0;oAFt3;gD6z198;r3BDA;e193;a3Bi352D;!t1555;i28EoA34;a7Fe49s118Bv8C6;mB97r106t395F;a4De32F9i21l37Ay0;!eB34i6rCAs0;!e68i542;m4Cp36t3;aCn2s11;a36Ao10;d0l39n16r3C4F;e1l1AAp1;!e486i6;k1l1r47D1;e18AA;d3An2;!e4i6s0t16;!eD14f37i21l22s0;e1i16CD;a0e0n7;!a3BBAb77Ac1F4d33E2e1228gBh3DEi4lB8Em2En22o3D48r4AC0s0w4984z3C9;aE9l1EoE8y0;a1A6Be451i22FsAA;t392;!b386c246d4201e3887f47A9g1EB6iB6Ck1A38n354Bs0;!e4i161s0;o29t1y16;aCi228;a6Ci959;e12i43y0;a2AcEl1D;s3CF7t11A;!e2D5Ei224n22s19Fy0;!b50A8c360De9C2i402l2BB3m1426n22r2EE9s3E99w45C9y5B3;b1Cl3n2o10t7v3;e3E8;l10B0r474;l2B3A;!g1o29s0;e15E6;a4ADCc1CA5d3DCBe330Ff11B6i1B20k3A8Al30B8m5013o1E37p14E4qBA3t2069u4706v504Cx1Fy4833z231C;b2F;!i41s0y0;d2ACs2C;e12i2By0;!b1Cc7m11Bs0t41EC;o16A8s1A5Fu31D;!b6Bs0;!a5E7e1s0;!a2292c615e1A27h1F9Bi13C4kFC0m837o1494q1938s2F31t1DD3;a111e2D88i6;a47A4e2BA8i24CBo28C0;z117;!a25F4s0;!a4De15h1i21s0;!k4Co1CpCE;aB16n3BCE;a1bB99d1C1FeEg39Cl3E08p7t2D54;e20DFi73o138u2;!s0w16;h12A0t4D6;i31o105;!a428b429e4CF0i21s0;!e9l18Fs0u14y0;!bA9k1l1AoE6s1F;e7D;!k0lBp4188s4E63t37B6;e30n245B;r22B7;!e24i6o285;k229p48r2C60s233tFCw321;!d0e0s0t0;c0n32Eo9v3;d0pErA43;!c2C90eAf1CDEg94i6j1E0l4C8En3EF4p28r1298s5061t3C3A;a1l18;i4EB;g3t1;t39v47;!c47e1i0s0t3Au5;a4BeD0i43y0;aAFlC;!a2CE0e565i20F9t5B5u49;c4E52l1FFm3869n434Er2AD1;e148iB98y0;e3EB1i6r5E2;!e4i6l47s0y0;h178i438F;i32C1;!d0r13Cs0;!c9EFs0;e5E;e5A;!b18A4c1E5e3E5g3FF7i189m2En0r261s0y0;h14D0;a1B0;!m7As1D35;o36B;a18D5m229t2694;i4606;!a2CEDe1776g76i1587o734s0u5;nB5t7;m0r1A;e1i22F;a0e74h1i123oE8u28C;a9BF;e4i3C;!d0i20As0;!e8BFi2274lBr76s0;a57oDF;lA7n23F3;!a4AEe3i6s0;i4CE6y0;!e1518i442Fs0y0;a3209e4680h1667i3A51l282Ao4D00r2083t1455u2094y2667;e1k11F;oEy3E0B;!e10Di21s0;!e5ABi21s0;i65u5;e0i166Bm2A47;!d0e1r1CA0s0;e2A1i3D23o36u14;!d318e1DAAg3C80l15Fs0;!aA2e4i21p364Bs0y0;c16Et0;i1AB0;!a176e4i43As0;nC5B;cA39e1Bf22F5n22s2584;!a270Ee4D0Ah14Di3F5Al26C3m2Eo41FCr44BFs0u940y0;!s1t16;!o4F4;o4328;b1BCDc2Ad3DAf21C8g1B02z8A9;s7y0;l631r3A0;e17o19B7y0;d1D;!g318h28F5r772s0;i28A;aCe32ECh50BBi1664o558;l36;r25C;!e7i91y0;e7i91y0;c39A0d3Ag4Ak28n0r2917t145E;u6F;n2C3s8;!n491Ds0;e4i2A20y0;a468r2677;l2BB;!y1;eBnE0;e391Ci50y0;a29CDc1FABe49FBf5F5g1CC7i39DBkAE5l4877m4AACoCB3r1DCBsB7AyAED;a74o31y20;r268;n12A;n2681;!n94Fs0;a2F8Ab1240e79Ap27ED;e4i547lF4oC7s0y0;e4n1Et4A;!e26s0u14;m4A3n2DrEE9t56B;a36CBe36FFr17B1;l0m2Cy9D1;!a133Di844l22o17F6p3CF3s24C6;s2B2;e4i298;eAg1D7i86y0;!c4C7d0l7m71Cn3B71r161s0u4E;m4138;r758;c2An2A;r1254;!f37n413s0;aB6b89d1F65g15AlBm1DECp21Ds1B9;!d22B4i3Cs0;!r2A7s0;s234;c49Al4624;!d8Ae754i9B0s0;!g2ECBs32Ct300;i16y3422;l4DA;n1o10u61;j1Am552;a174;d41t18;r45C8u1745;a34B9e28CBi2C28o35EEu3AFEy2319;e1F29iEF;!eCl3;!e10i26ADp5FFs0;!a4241b2508e1f440m325Dn3824o1372p1F35s2708;!e15DiBAs0w33Cy0;!e4i6r41Cs0;uDBD;!s0t12D;e8Ck5C;d1r1;a0f2A5tB00;a437b1e479Ci6lF3nF3p1;g1oAB8;f82;!e3Dl6Bs0;a3D61e1A1Fi1498k3174o2D1Ar128B;a298FiA94u5;d1A1tD2u3F60;!a2D4Ce23f37i6l22s0;dB4s5E;d0e61;i6nB;!e15i24F9l309m2Es3029w70D;!l19u9D;l1n6FD;c48D8d2CBFeAg28h2B7iAE0k1n3D4Dz12BC;e1t2EDE;a59i2D1y0;!e4268g453Bi1B8Cn19D4s0uB;aA6;!aCe37ECs0;!nFp1E;b16Dr11F8s8;!aE35bB1c507eF9f38h2795i3BEDl1682m34E2o47Er4FC6s0t2478u14EC;g281lA7m243sEt3A2;n13D;i1t7;oC5;s11tBD;a362F;l3838;i5105;aD1nADA;l1t91E;!n27BrE6;fCDnF;c2FA0;!bC84s0;r2076s1F;e4588o3EF0y5C;!e5n3t0;n34Dr48B8;e22Fh16Di13o3E26t38;n18AC;a11E6e24n2oEpA5s19u14v95z19;!a1AA1n494o734t3C11;fBE5;a2C0oDC;x3E;u50B5;l15C8;nBt3;e234Fi303oD;!a1AEAbFEe1910iBAl4CFFm273s0y0;m2B3Cn512DtC92;c1e5lBDDs14;!e609iCBs0y0;!hA0lF1;!g5051i6n4E2Do4rD2Cu3C76;h653;d458g2Ck48l379p324Cr1s3F2;c2Ae1Bl7n2;a26D1eE60u1031y34D9;d42Fl4F71r62;e1Bn7CEs11;a4Be24i6;b8F1p16;!a36e4h1AiBAm2Eo36r38Bs1BCwBFy0;c2Aw80;c5s0;a4806c3F54h4445kC96;i110F;h14;o5Du464;c29o83r50BCuBE;l651t16;!a1B53b2EDe4i6lBo4122s0;g2BB;a1BB5;!c444s0t31C0;t232B;a1e1Bn2;!a50A9c1530d1912e12E5h1051i3537m1C7En3o4F05p2967q49BFs4521t371A;b1c19d19;l3Bm1B3Bo1CC;!aA76e15i21mB3BsECu7C;iEo190;t3B2;b1Ct3;l24D6m4259oAFuE7;a4E1e402Fo10;s528;!e449Fi6o15Cs0;i18y18;a2209c4FF8fBFn430;iC8rB42;a1AC1;!e5DBi6k21F;e486D;!h1122tF8;aE54e4B91i1D46o2F51uEBE;a3D7Bb46D6c457Cd33C6eCBFf17F5g35D1h2FB8i1423j1D7k4598l407Dm40A7n3A55o4D60p4D32q3F5Fr2B74sC67t4F45u37EFv459Fw3554x710y4AA9z4C22;!e0i35o40;a28eAh182i33DpD4u4453;a417Ce2857i422Ao1CF4;c19d1E;c32h1i1C55n1255s2C63y71F;!e68f50F4iE50l22o1F0pE3t23ACu623y0;c2Ay0;!e154Ai3E80;!e4i86s0y0;n25t1;l281;u2DE5;a4533f7nFo29;c32k1l1;a0i13u14;r1036s0;e6Eh23Eo4206;aBEeE4;l1n0;l0n1;e1Di1604o964y0;!b29CFg25DCi1EBEk241Dm22n28p8Bs461AtD4;u194;!a2F18e12i118Ej5E2mB1o2DAs0v136y63;l4B83n248Dr7F4t12Fz2C;a1Dd47i4125nEp3CD4r2723t2EA;!aCd0s0;!cA09d7CFl87Bn39D9t19E8v1CD5;e113l7n22;!a2DBDe1Bi4B3Cl7n22;t4A84;!d4Fi4m3;!c2E4De2732h2FD6k1m2F79o10q11Ds35t4D6A;aCi5EBo46u5y0;c52t1;!aCc114d0i9n3F1o2FFDr1s0t114;a20eAi484o36;c1d1;y4B;i12n1;eA4i1D2;s4Fu5;i49oDC;e33s0;eA0F;a662oF;c25Ck18l475A;!eDn22r11BF;!aEe4lBs0y0;b4ACd2CB;d0uD;t24A;!tB7;u11C;eB8Bi6o17A5s84;e1E26i4Du438;!e4i6r41s0;e92A;h370;!a376e3684i596m2Es0y0;a4Be68o2991t61;e8Fi745;r39FB;w251;eB3l7n1432;h353p16Cr501vB;m1384;i27D;r0s8t7;!r0s8t7;e1i3Fu9D;!a34FEe26EDh2E7BiE8Dp50E8t1268uD10y0;!e4i86l643s0y0;e5f7;d0s7;!r53s0;!e15Cn39CFs4AEAt5B;u4DC6;a4DF6e1i5p1A1;!e12i4F0l2Co72s0y63;!i1E88l7s0;tA03;k0m1;!i15Eo29s0;!a4Dd1e15i21s156t248;!l56;c973l1450m84pBC2r1A6Es163w1C6;gAC9nE;e3Di2262o2E60;aB6Bh46EiBEo32D0r1F4;a4A8DiC76oF6u8;!e4f278i6s0;y38A;l452;l1F2tBDvFC;!a3CC9e20Df37iFFCl22o3B65s0;!eC1f37i86l7s0t1;!l24Fs0;i8Dy0;a21D8e242Ei157Fo1BAy7E;l460F;!d0r1s0t3;mCDr18;a10r1F4;r146A;m533;k8Bt3960;l35B6tB;e1Bf7n2o29;c0n0s0;a468i8Do285;a21e12;n0r3A13;e220o284;!d32A7m4A88;!e25Ai270;!g19r0t19;e1BnFtB;e5Bo1;d24DAn157t2C;e4i6o19A;nFt0;!a2A6e2935i2C78p2251r1520s0;e4h1E;!a488Fe3C83i3DFEo10s0y0;c0n32E;i491;a4De4CADi1BB;u59y3D;a4C94e3E7Di2BF3o4A54;i10o50;!l22nAB7s0;!a30b195De0m4F3o14BDp48s0;e3DBnF;e4l4F;a1DgC3s27F;!i279l7;!s0w3044;!d0i6mDEn28s0;!g60s0;!l1785s0;a0o3900;a524e1D1Bi6;c41DCl198Ar36F2;n4C9CtCA;c33ClA7;e230s11;h9C4l3F24n1t2205;!a52b22Ci4E8n22oAD2s0t39A6u4301w38E;b39A2e4E0Dp1312s23Eu6B3;!a36;a104eC4i305y305;!a428b9Fe15i6E1m16Cn54Do72s0;!i1Cl22s0;aCi250nEoE55;c58g6AFn15F3r3024t2E19y1A;o7Cr4893;a476C;n1DBA;a20e5i3D;a20i23CFo29;i3356o46u5;a3358e2D70;lECC;!eD0i21l10Fo50s0y98;bA1i4y1;!b1DDc1E5e85i6l22s0;eAi6t4E38;!aDAiEFm2Ep5D;e895i67y0;aCi4F6;a3FD6e1E3iD77;a49F1e299t1976;a4E14;!a646i6;a104e898l2806oC4r520;aEEDo2FB0u1E9D;r346;!b504c388dB7l4DEAn14F1s0t164Du8F;eD0i6y0;g5A;!b1DDe9A8i6;a18FBe31FCh962i25BDo1BDr1D3;!d0l7n5C0r1s3E;r31E9;u3E70;a34CFe3AD9i2C9Eu11B1;a192b4572d7FeCB9f1F1g2472k30F6l4C8Fm2413n1BEEo22F6p1F24r27B2sD54t4EF6u322Bv187w1355;eAo46;a32g1sB7tEDu411v5B;i228y0;!b3AB0l22n3DFCs371F;a26ACe24ABi1B4Fo2297u1F9Cy2D91;i8r4269;eDr24A7;o1Fu34;!e50s8;a28De8Fk448t486AuB9;!d3n0;c3Di15ErE5;i36o81;!aCi4BFC;c0e79s9A;l1D0;a0n1o9;a0n0;e15i20Ao1;!e14Ei21l5011s0;e1i10;n2t150;e5i1E6;!h2D90t103;aD7i17q87F;!a30e15i6s0;nD50;dA6Bg49l4811m72Bn4CA4t362v4D49;i13r7;g1n1;g14Fj9B3k36An1095rC8;c1EAk1E3Dn7BA;aDo29u14;!g4F3p178r1477s0;e799iD7;!a4934c31B4e5E3l345m1EBs0t2BBFy36B0;!e25Ap4C;e43FEl1F17;i56uB9;l1E41;d0rA1;a2B10u432BwD6;aCDDe0t11F;!e15f37i47F3s0y0;!n84s0u5;a36C4e4i21r15AE;c0l3026;a57o95;b1Cn3AE2t38E5;e194o5D;!a3FC4b184e1E9Ei2DA5o28E0s0y0;c124i18;e6C2;m38;n1A2;e5l7nFs11;nB5A;e47AE;l1AEr1t36C;!r4BCFs0;a0e17oE;sADFz19;!t6BF;a12e19A;n3F15s5Et107;iE2y0;a1e24f7o5056;!a392DbDD7c267Ee21A2fB5g130h318Di56k5Dl18Fm474n36D8s2A74t4F7Dw4FD;a20b4DC2oE8s0v62;h2A67;g0t0;!d1El22o1s0;!c33Cd1A1l1n3A09s15C4t28;!d0l22r0s0;a57i88o20u6;o3A9F;rEs1D6;!a0eAi9l7s0;!n6D4s36E1;!d3t3;d3t3;!aCi15Es0;o9DF;!i270s0;!dF6De49A4g2EC9i9F2s0u46A;e24sB2;e0k1n0t11;c2C4n49At2C;pE5;!a20i949o12r1A9s0u5;e148i6o1;a2777b2339c19F5d2BB1e1121f12E6g309Fh217Ci4CA9k1A35l1F14m3A86n50A2o2AFCp2903r1A17s27C3t42E0u31F0v4ACDw4EA6xCF7y4585z4A5E;c3C0nF;r1s2E9t1076;!a4CC2c325Ed25BCe1f1C7Bg4B52i56k1A4l57En2AC8o10s0t3BE6w136z200;a97Bo5C;a1C67d434e1h50BAk1900t3970;i4F24y0;c481i25;e4216;!c7i166Es0;e4DEi29C;!o15Cp84Ds0t0;d0n850r251;a75i13u14;o2FE9;l1nF;e159lB;c6BEr61x35;!hC5k48s0;!i4D7l7o12;!e15i6s572y0;h27t1A;b6Am980;!c2F4e4i6s0;!d8Ae10Di86s0;!a1059c11d12AAe4A6DfB13i3983k3633l40C4o385Ar3800s9B8t41B1v87;e539i8Ey0;g2F61o1;o1s3F7;n2t3B84;!c507k184Ap10BDr0t141v4C45z7;e0i3Fo29;a10o31;l4AE7p58;t4C54;l352;r2A1u6E;a2387i13o29;a0t7;a0d3343o9;m2ErE;n2t11;a31F9e3FEFh1EFFi3FA0lFF6n4DC0o2421r1D3Et3195uF04w34y3330z1ABA;e4k39;m821;d0g1i31nFC;r1CA;nFt2CvB;!r1CA;rA05;m1767;c8n2;d1n27;a875;!c16Fl107s0;aD8o104;e7A8i8;!e4i240Bs0;g128;!a51e906s0;e1Ei6;e4i67o2203u4Ey0;!g1r0s0;a72Dc476e18DiCCk627uFB6y0;bD73c414Fd2C50f239g39B4h1i27DCk3AAEl2F62m2FB2n3336p4D8Ar3AB6s3310tAA7u1BE2v17A4w3CADy1;b499De2748;!e73En4AEFo29s929;!e280Ei13r56s0u4Ev7D6;e1gAF;e1C30;d3A35g358Fl55Cn364t1FC4;o30y31;i105;a20e1i5FEy0;i1C24;a1i47B6k481Fo1;g2E3Dn3r7;b4C7Cc2ED6i36k1l12Am3n1148p4A3Br30B5;f487Fl2A7;i96lCDr4B61;!c2Am120Cn26DsFAFxE;!aCi10BAs0;g11m3F7n142;e5CFh2B96i21;sEt1;m3EBE;e0n2o46;t1x0;m1E2p19D;!a21Be4FA9h2A0i67s0y0;!d6Ag3h1s0;e5o46;!e5o46;a4422e3ADEnFs48A9t29B3;!a4063e3F18i21o16D1s0u27E5y1A5;i2Bp7y0;n49A;e31i4lE5oD0E;a4640e2125i48C1;e4A7g94rB9B;!a111b47F4c2CB0dFCe4670f5BDg308i1F20l3C99p1459r2BFs226At2E5u6B3v3DB6;c68Be1CF;a4B93t13BD;!aC88d4308eCFEg3502i3A6AkC91o3EA3s4BBAt1EE9u689y0;a343Eb1FC0c218Ff1m3EECn4186o2240r12As21Fv2Cy3165;eA4iA25;t9A2;hBk209E;!a2ABAeAi289s0y63;m27BF;!h3CC3s0;cE3n2s11;f4288t48;g7Ah1l12DCs156;g465m94B;a26C2b190CcDB5d1151e1962f474Bg1116jFCDk1D81l3C3Dm1295n2593o2D6Dp1768r1F19s38F7t5125v4E40yEF4z2945;a0iBB;a1A6;!e148i6l19s0;!b1E8d0i9m35C2o29r1D2s0;!a4A70e1i13s0u6B9;!e1F99i6s0;!c4FAE;a30m0;a1Dc44De24k38l12Am64s25ABt331E;nFu2CD;cF5;c0k0;l1As1F;!m0n0s0;!e555i5t6DB;e4i6l1B6;a275d27DDe0i2E1Dm2F3Bn2016o3D17r4525s4A77;!b2EDc423Ad52e4g1A4i6k1l1m4169p180r368Ds1344t16z1462;l39n39;h45A1;e4i6lB;a59o49;!d0e9l7s1;!e15i402s0y0;!a3DFe4i6n38r58s0;l9E4;eB3l7n2s11;cE43d2E02f2D0k9F8l33D0s1FAt2DEC;lBy137;h70;n6F8;l1m1;h1CE;a73i73o81;e14FEk0m17Cn3BDFr2118s84u2CE6v3;d1i2By0;a22A0b409Ce344Ci17D5lFCm4043n26F4o1D7Dp331CrFCs0;o6B2;!eAiCCl97Dm787n22s78y0;eDoD;!e15i1C5s0;oCs0;!oCs0;eAi21l1689y0;!a4Db498d212e15i6sB0C;!a1E6s0;a1ADEc4019dE78eC72f4CE4g342Dh38AFi1EDBj479Ak955l3622m27F2n48FFo2737p37C9qE67r42EEs155DtC32u1FDFv3E90w3930z13F8;a1e3632i3A40o2E2Fs0u1B0E;e12Er280;c5023d491Ee1g37FCi2360k2C8q3990r3FEDt25D1w2738y0;!h129l24D;e9F9;!a43BDb144Ee3966i449kA4r1A43s0;e6A0;lDE;eB3l7n139;a59o99;d0r731;a4A20e19B6iCBAo2706u17EDy3B33;b1CgBt1;r14y16;g4F;e1g5F;eAo1;e6Al7;aF49;d0n1ADr16;!e3F3i6;!i18o9Bt15F;!a10gA9s0;!d8Ae4i1707l2BAs0;!d0l5Cr1s0w49DF;o120r1A9u14;i8l44;!e4D5B;!a7Fd1e15i681m1s0t0;a4De557i189o9By0;i10l2C;a59e95;a2B72e2C12i1EAEo22A6u3616;lAB7t271;aCe290oD;a311C;rE1;d16e4ADi1DB9k48n78p4611;t61w16;!i2A84s0u4E;l214;!l4E0;gE4l36n4E84;a41FFe17i31o18DF;!a185oCs0;!aBCs0;!e1i6s0;!a45c4BC9e2F70s0t20E8;!s2E3tDE;!d38r58s0;a26B9b3055c2AA7dC78e39DCf1088g1E45h1i2480l1D97m170An2227p1939r24E0s13F1t110Dz17AB;a1o28;cD3n1725tE3F;kB9;e129oCF5;oFE0;i6EAr50;iAD7;e12D2;a10lF0n276Bo3DDB;a1D7Bu5;a124Ae1E0Fj2B14n473C;!e4i472n1D57s0;i61C;!a2C15i56u34y0;i3ACDs0;r83;o29r47;tCCF;c3e79n7Ds11;k9E4;!a20e31i13oC;s562;m5EnEs35;a2BEEi25l16Eo28A9u2D2;!a1i44EEs0;!c2BFCh10F1s0t4F9;t3D;g11Ds88Dz88D;!n4FrEs4249t82u59;r8D;d1t46D;a1E34e1724iA6o773u351;a75l1u14;n1055s1FF;!e8Ci21s0w1C3;!a135eB62i67s0wBFy0;t11B9;e42m200p30C2s0;a0e1o2F6u34;a40e82i1E64oFB;e12u32;w252;a1e6El44;a7A6e99;i6B4oB2Eu54;h1rD6;!a2EBBe37EEi4FE5l3CAFo5149r3360s0u5134;a9c35;i6t16;n1sE;!d0r60s0;e27E;a148EcFBBe4754f3BAg4428iDE7l2C57o2E91u2050;!d0e0r0;h4F;e4By1C;a1f2DnF;a1De15i6o12;cACBf2A2Bg19FFm4615n4EC8r47Fs3F82tFC1v4DA1;!a3C79d4E9De3852f47F6gA1i2457l33FEo3ACFp2F48s33FBu43B9v3965;!e31EEi224l7o1s406y0;!a4Be17Ei6s0;e1i1l3;e3D5Fk177;m0s8A;!a2722e1i4E27l4967m7Ap191Ds0;a38DD;hA22;p6A;h11Fr2018s584;!i77s0;!e36i2DCl7;a427Be48Fi3152o2604;l4886t28;!r12s0;!aA68e4s0;b8AEc15CEd1547e5g1B95i2BA9m395Bn21CDp4D36q18CBr4919s1FFFtAA7u1DF2v3B87w328Dx56y2D76;aD9Ab44ABe1A22h3F21i2F3DnC22o38D6pA81r2F11u3047y147Cz16FA;!d0n16r1s0;o421B;!a10o10s0;!e0s0t1w1;f3v2B;e34r47t202F;a1FC9bC81c41F0d501Ce3003f2F1Eg3E3Eh73Ci299Bj1533k2872l2594m2E56n28BAo16Bp1035q1430r17F9s459Ct33DEu4945vF2Fw12CEy15F6z19CE;b504;!a1096e83i1A3o72u511;i3B68y0;lA5r1;d648f42D5l22D6t1DE4v233;o104yC6;a1E54i450Co19BAy0;a1C3F;!e1Bi91s1AFy0;e1Bl7n430;i35u49;dBe5;i4s55;!i3C68l44s0;i29A;a40hB;i4FA6;e23A6i6s46C4;d16i1FDt0;a1o8;!e15i6l258s0;e3E5i5148l5B6;a1370b58e4C8Di3DA9m3460n26BAo604r1525t4Av457;a1EE;a646e381Ei31BoE;u50B0;!e12i253pC42s44A9;e8Ci3A9y0;s32F7;!a2FECe14C0o277Bs0u4439;c1DE6s14;b7Bt10E;d812;e20FE;c8EFn1A3;!pB9Ds0;a4FCFe2B0h3181i4504k35B0o1t1FACy0;h3Am0;e5i5C;!hFB8o1BD3s0;!e8Fh3A5Bi21E3k4BB1s0t49BCu689;g94rB;e4066i6o12;e305;!eFFi6l6Bs0;!a1615cB8Ai2FF4o4E4sF0;a44E3e81Fi2D72l2Co2E1E;dAAk28;o54F;!e0i20;e0i20;e3583iB;d0r6C0;c3E6Fd2E5Be222Eg4B9Bm3D91n44D0p2AF1r1EAAs3A46t2EE3;!aD5t0;!b43DhE0o31p3498r52Bt2435w3672;a54e25o95;e4D68i10DA;!i4EEs0;aCt0;i20m0t1;sBt3AA1;!a1i3FDDs0y0;!e4B4i13FAs0y0;p6EC;d0i6s0;!a4Be15f37i6s0t0;!a12d8Ae4hEAi1EC6o57s0y63;!e85i24Eo12r22s0;!aCe4A2i270s0;!a3D5Ae4i6s0;d1p3B;hB12l62;gD9i1FDn1A;cA67x0;l1626;nCDs19A;bA1d19r1A;!a12e4B70i6s0;c0e1s8;c0e5s8;e1i1Do2CB2;a4C25;!r3205s0;u5A;m242n1;kEBC;k1rD3;!e17o46s0;o10uA95;i4lA7s4CDu5;e29E6n2;c41D4s0t4FDF;c50C1nF;n3Ar32;!e14Ei87Cl22rFEs0;e1Bf7nF;d0e1r1t179u36;h3C7s7E;n2o9u14;a1Dy312;a4BDe9o50;e4i289y63;e1Bl1017n139;eAh2715i6;u1E4;e273Fo36EB;eAi3F30;e23i4D59;!e15h16i6s0;a315e15BBi3CFE;!e555m2E;a20e1D;fEw9;!k1C43s0;e1163h3B;a419E;a243Ce4F83hF8i48D;a69e4;a1519;b246Ac2Ad4F41g1CA6i30D8l3A8Dm2E47n3EB3p4844r1EA7s11F6t4F5Fy12FzA8C;l3D05;!e15f37i43s0y0;e5D8;l0r2Ft3;a1A9AiBy0;i11A;a4CE3b2EA8c19EDd1009e17f4FB7g440Di1FA2kBl1CB7m2779n2FADo2D79p4F80q4F13r127Es4DE3t1D7Fu35DDv2168w24FEx1Fy2597z471A;v333A;a1e1tD39;m671;l16r1E;l1Er16;aCe25Ai3D;e2198o2A9Au2F85;!bDFe30B3h58iCClBo1Fs0u4Ey0;d27tB;c44l438m1;!d3850s0;!e4i67l22n1s0y0;e299Es0;c1EAh74E;nEt23A;e2B0iCCy0;!a4Be15iACl47m2Es0;y96;a11Ae1iB40o422Eu416;a9C0i27lF1o645;i20uB;s1B9;!o1891;d0n0r1s8;m3DA5p116;oB51;e2AF4i6;e11BiB4o40;a12iEu54y20;!a1129s0;e5i4o46;s40B0t2Du5;c2Ad3;m7D;i6o6;t37E;aA68e5s14;l92Fn254;t116;l47n82;oA32;!e4f37i6l22s0y0;nAAC;!i727m38o2513p57Fs0u4906;s14u204;a0i3B9o7DBuE;!e4i6s4F7;a2F16b3Bc34EFd48BFe19C4i4372m3E29n5113o46E9p2B81r3C0Bs19Fu47BEw137;d27g10sE;!a20e1B8g0i6s0y0;!e15i6lBo28s0;n2t0vD6;a17ECe1A7h5FBiCD4o4F19u500C;!n1CBs0;l87r47D7;!h3D11i1s0t0;e45o45;!p2259s572;!a1D1l87rDEs0;!n0s0t3E41;p20E;g15ApD1t445z418;t1E0;!a4DeFBi6n0s0;!a4Be12i6s0;!a1e0i1AEs0y0;o128;!d2Bn1s0;a30e3CCDi2DF2u3D;!a47D2eF4Di1813p106Ds1Ft4DB1;g3D9;!dAC8e0i1711l1n25B5s830t2E34y1;i132o4D34;i2CF5;a0e5i13o272;!e24i6s1AE3;a1D2;aD80i285oED0;!e12i253s23Et220E;kA4Bp91Cs7;b3E6d2A25f1CFg45A5m1En3ABp4B31s5Bv41FD;p39w39;!s0t88;c50F7gBn28CCt235C;!a9s0v62;sF7;i73o300C;a2AA3r43F;b1Cg370;nFv47;e1n1277;f16l44E9n2A16s3A58t16C7v1C5Fw45B;lA7n3A2u59;e7D3;!a1C6e668f37h109i136Al22o2EB8s0y0;e3722;n175;eAi7FCo29y0;s19t0;!a6b1772i3BB7l6C1o2630s0u1A03y0;o9D6;!aDC8e3C15g3631i3C53u3BA2;!c190n70r3z49B;!e0t1;!i4r0s0u5;t79C;r98A;m1AD;n3o8t1;a127e1Dp1;o211u2A9;!h1s0tA9;e6Er14CB;t3E;g84i43C6r3B;e4i5;e1i4;!m2Et6A;r1895;d0l1r2F;h1786;!n95As0;c11k39v19B;e2BCEo3A11;n8r4AB;!a4Dd2A90e335Dg3CE7i39EFo7DBs0;a454Eh31FAo3CC2r84;l3748;!b202;eCi3CA3o12u49;!s1uD;a4Be11B;!m103p126s0;s4F6B;i10y0;!a29Ac2300d4D4De348Ag1551i17DAk2C5Fm639n3413o272Ds0t1E9Au54Cx0y1A5;a32d0e25;!m55n501s29;l909;b46EEc1E9f2986g72Ei2237k1FC5p3BD2r16F6s4B2Et2899z168C;o6EF;i2Bl19y0;y50;d28B9;dB68eAl1EFCm6BCn2719r7At1CF;!m2F34p15F0s1F;e1fF2;d2DFBe12s19;!e4o29s0;a40o10u69;l6Bn1;i260;mF8n1802;r2A7;m243;a4E6Ce1E5i49ABo419uB8y2DA;c3C56e1l1q11Dr1B2Fs182;g94t0;!a42e4i39A8o352Bs0;aD9b29f50ACu34v19D;a4p1;a10h3B93o10;!n1pA0s0;a673oED4;a2C4Db1C49e1gEC1i1E73k48l305AoCDAt3B2;aA45r292;d1173n2Ap627;s4D0t7;e2D87;c3r1t3;n3r3;n56;!a12e5i2By0;!a3045b3FC1c23CdBEEe268Ff0g5Ai3136k16F4m41A0n445Eo46CAp366Cr1F8Bs4CE8t2162u3503v3534y1B34;t1Aw1A;!d1e220g130Dl206Em5CCn4909r29F8s315At1073;!d8A;l6An365;c83r83;!b3BFDc429d8DFe4f151i67l22s0w25Dy0;i1u1;!bFE5f387r98E;!e4i3s0y0;!b3Bm3Bs0;!e40Ci2B42oE4s0;dD2t3;l17FBm64tBD;!e4i6l22s156;e148i2AECl16Ey0;a319iC5l1A1Es0u23E8;e1Bl7n18As35;n2434;e31E3i6;l422;!e1Bi47E9l7n22t4DDCw2A0;!e8C;!e26s0t0;!e4m1s0y0;gBn864;!a75c11C9e1i4E8s2AA6t5037;e85uDB;o663;!d0eDr7s0;a1eEiAFE;!a8Fe965i26A5s0u305C;n2o9t1;a21A5b6AmBnBA1o10p1Er349;a1s11;!e20Di6s42CC;a1EC2h1BFDi501Bt47D6y47A3;e33i27EFo1688u628;f240n2E7o196Ft3;a36h45Do3D7t2BC;!iBBs0y0;!e4i9s0;o12u36C3;a2332e4211i3110u14;p8CE;p24EC;a9s100z3;!a7EAe40Ci6s0;t3E78;s2B29u4DDD;e1z2D4;!c2Cn1814r4BCBs0tCE9;aCo12;!a4Cf37s0;!e61Ar280;!lA9s0;!a1D1e1r1s0;!k28l3792p3FEEs0;eAi1ECy0;e314Ci2247o3EEEu5022;a2923t174F;!d0mD2r1s0t2Dy16;e3EAiCCy0;c0s100z3;l0n47C8r1;i65n2;a2AFo8;b7BoE4sEt2008;k2C9Dl58m4390n14D9q4C4Er2078s4D58;b1r48FDs74A;!a323i10As0;!d0e10l3009m0s0;!a1e85i6s0;a0t3;a48CE;a8De1E3o22D;c13B5e1g2AE9r360t44u14;l2F;t127B;a7e0;lBo46;!o1;!e15g47i6s0;!e15i2A01o5Ds0;!e15iDDo12s0;c427E;i4n3sC0t2D;g39Ci8D4s3F9u22Dy48;lA7s0t2D;a2C14p141F;n4s3;u2;g10B4k42F7t2C7;l3o9;!a2F63lBo0sAC0;!e4i4277s0;e6A0i3C;!l45n46B8s0;s20Ft2D;s4CDt2D;a239b41E9c3B8Bk2DD8n2F5Eo36CArBs201Ct38C0uBA8w35F0;!s20Ft2D;!b4484c2090e315Ci86l7n22s138BtB46;!e4i6l379m1s0;!a4Be1114i1BBn0s0;a3B0o36;i3729l44u5C9y2B85;i59o54;!r3736s20Ft4A2Bv1A;!d0l1m2Es0;c3AFA;d0n71Ds0;!aCi1F04o46s0;!e0r7t19;bDEl4442o459A;kB9nB;a36e6Eh34BE;n2C2;n8s8;e15Di67o0y0;h831;!b7s0;!e4A00i21s0w172;i28A0;mD2n2D;e24CC;i20oE;d28p382r28;l39n16;c424A;b1AC;l1An1;!aCi13o1s0;!s0y98;n1558;!d0n4r1s0;f3144iF0t8B;!d0e9l22r1s0;a1f4A5;a7Di3F;d48t41BB;!e10Df37i6l7o29s0;t25E;l1tB;i373By0;o109D;e2DE4y0;e1u55;d3An1r1s0;g4ED4;e5Fh376F;e4i6l19y0;e30g1Cu20;!c55Fe3B8h1mA0As0;e3ABAi96o29E0r178u5;b43F0e1p3A82t41A9;!i31o1s0t19;h55;!a10b3D2e4f38Ei21o4385s0;c32d0r16;a1CDg0;e3ECBi4D67l7Ey0;cD9;e1i7Cu5;i71oFy0;t34CA;e1Do37F;!rD6s0;e2A4Ah1i204Fy0;o1458;!a197Fn130oE4p3797s0t88;d0lBDn333o4F4s115;x78;e3EAi621y0;a367i20Cl1EBAn25F8r19FBs94Ct1C8;a4567e4522i757l2A8Do1D92r2DDDu2535;i6oA0;s3F8B;l1AD;!nB7;nB7;!m87n2AF9;h1784;l5A2;c1Ce12g27s0;!b6F4c20E2d4266e1g179Fi185Ek3980l22m1E6Bn1B4Es4608t47CBu3C1v4470w5060x58y2FFz36A2;g1Es19;!d0o9r1s0;dBs36;!l0n8r7;!d0r1s156y0;e328;!eD0iBAl22s0y0;!a178Ae1500i3A30l10B1o257Ar21CBs0u1A68;m5An2;r2678;e1s14;e5s14;d0t13F;n1CBF;l290Bt48;!p19;p19;a3B3;d0r1t16uD;e5i1D;!e14B4f1i253k3F08l3E9Fm48FEn3AC1p1CF7s11A1t6E8;!a1De391Bn22s156;h5AE;l39DE;!e77Ei6l7Es0;l1n33ADr4DA;cEn1r1E7C;h66t27;e9Fi351uE;g339l476Bm0;b30C1;f0n2o9v3;a4F2By0;aBEy0;e5108i20B1;f7n0t150;t2DBF;!e4g0s0;n14Bs8;!e14Ei6s933;h57F;a93e12l47r6B;a4016e9D3o3F44;!r3080;c1Ce1Bf7l7nFs0;!m1B6Bp11EFs0wA8;l3C8r234tB7;d3m1;!a4FD2e3CF4i285Bo22AAs0uBv7Ay7E;a2ADi21;!l1Dn254rADs0t1;a245lB;!e5i115l124o34BBu1;a16Bb1F5Bc3BA6d5Ae1f3CCEg36FCh1251i4AF3j4A5Dk4867l4D6Cm3D96nCE5o19B4p2393r1800s3491t49D1u2FAv44C8w28y1140z2726;!a40F1b22Cc9Ed613e2E5Cg2BAEi1002j8Bk28l22n30C7o3541s0;r1C1;o5FFt38D7;d0n0r0t0;d0f37;!a1108e20A3m10C0p29s0;n1r35;cC3e1Bn2;!t4AD5;g25Fi1822l1CFu3AB;!a20e2867i3BF2o11Cs0;cC9Ce111l2172;!eB9h103l7o29s0u1F9;d8Al16;a38B0hA4i1E69m26Fo42p2260s20Ft4404;l1EnFs27Ft7;!c7s0t191;l307;q6AF;r31E5;!e17BEi6o0s0;o42u5;n3361;a41De1Di2B1o29;!d3Al7r0s0;tA78;n50C;e1o47A8;!d25;!h1l0n65s0t0;c13Ae23i38E3n1F8p49D6s3;!e5i20s35;h92;!a104i2Bs0y0;!e4i21k5Dl3E55o29Ds140y0;i17C;rDF2;e2F5Do9F1;v197;!s0tBA2;!a10e1B36g2BF2n1AA3o2912s0u8D;!e10;e1E6;c1BDdBt31F;!d3774g1DD8l22m1E4s0wBF;!c3803f1F1l7m1EBn22s0t381B;aFo8A;l1B94;eDBi35o40;!a4Ed3926e4708i1847s0;i64B;eA25;!b1A0m2Es0;d47e18DnF;i21F8;bBn1A9;iAE7l7En5B0o29r37E2t4CD8;e17i3D4o342Ey0;!eE4iBA7s0;c0n2s14t3;a4646g62;!l1As3758t111E;a3BF1c87e482Ci21p1A4r46Cs4D64u14D3;b1CtB4;c0n2o9s8;!e4i6s0uE;!c1789d0s0t1;o4D70;!b1680i25F3n114s4B29;!n1F8s0t16;a247Ee5l30BnF;s36CE;r276;!d0g9B1i3Fl298As0;a14A4o2A3;a30d0r0s8;!a724i12o4D76u12;!m16Bs0;d97Ey1;iAFEo1CBA;d38e2426f1l25B4m1p28t38;a52i0u5;!dBl76n2CC3r1s0x121;a2148u393;e1DFi1719m38p4CD7s56;!n6Bs0;!g2370s0;!e1BiA93l7n22p62r1F4By0;!e4i6s0u49;eAi6t16;!e24i6t16;i4B33;lCr0;dBr9DD;a6F1e1412g29i245Al2B09o12DEs2Cu2554vF70;a1t38;!a1D4Be23B1i3446m89p91Bs78C;t579;b1An20C7r5E;cEDnBr1;!a261Bs0t2071;l2BD;b1Ac5120g1397l2758n3D95r38EBs492t2675;!n3r4465;aFe73i73o138;l47D;a20e3Ai2DE;!n1s20C3;d997;lB85uB8;!b0cE3d2E28k448l4DACmF2En1Ar27D9s0;a1i18y0;g31A0;a12e17D4h2DD6i6k29D2o104Fy1A3;!e4i91s0y0;d44g25Fs497v53E;cF4t0z1A;a12i31;!a41A5c2AE1d162Ce10F0f99Dg5131i10k4820l22o56Fs4F7E;i4C9Ao256A;aCe3C2Bh45B2i563;a1F6Ae122Ai6;!d0i6l1CBp4F2Ar12Fs0;r39t3A;c1Ce1Al60nEt1E;c1ArB;a40DFe4283h3406i309AjC9l1B28n21BBo2861r3997u2FBEw200By2036;c2Am5ECp4F1;e198Di377;s2BCu5;b7Be1lBn2o73Ft2C9Av3;e52Fo10;m2563tBA2;!eAi6o1s0;tE6D;!e23i326;!aB69b11BBdBe46B7i21l4243s0t37DB;!a4C7Ee135Fi1E1Eo35F3s0;e113l7;!a22DAb55Be1343i472Cl410Bo358Bs0u5033vA5E;i3D9o16;r1DA;l319FnFt44D7;!a21C4i171oC4;a1h32D1;lB89t4EF;!l87s0t2FE3;a27B3e3040i3B74o1uDB7;r1375;a164eD7r56;!aF4Bd4917e11F1g21F7i4304k48l76n289As45FEt2521u4Ey0;iC4o1;r3929;a4e210Ei1BFo246By0;d43FFg3Bn76t2B2C;uE7;e1r7;!e5r7;eD7h378k58s53At127;a4De616r2618s1D0t3Dz98;!d0r10Bs3E;e50CF;!d42C0e134m1948n28p1EAr4250s0;!k28;!r114;n193C;c13Ed157t1C13;i3783;a3D09e4E77i381u4A97y0z1A5;!r722t3127;s3uB15;iD28o145D;!i2DCl7;!a7Fe43E1i6o32s0w1C3;iE3Eu5;a1F9;n19B;!e26iACs0y0;h0k0;b46f16n16;a1D4n107Bs2D35;!a73e12i6s0;!n2AD6r2C6Bs0;!i2466s0;!c232d38e0g2D9Di6CAj18n72Bo34ADsF3t3091;!a1257t0;!aA2e1i56o2B8Fu3B6w124;!eEh9Cm2E;r683;e6E4;iBBo29y0;lF0r1;l1CFr3D00;a18Ef2D;!c0d282e5s0;!b1E19c4D09e6C8hE9Di59Fl97Dn22s140t11C5w599y0;!o12s0;a4E9;!eC1i775oD8s0y0;a7Fe23iB2C;c1eB3n2;a18C9d482FiFFDl42F6oEE2s4DA3tA3Fu936w44E;a4Ce1AD9i13F2;e143A;n3p1Es11;!a4De4f37i67o0s0y0;e3C72o2698;!e12i2687o560p7Ar3964s0t361A;a2FDDd186e1p82t26DC;a3230;!a828e4i106Bs0y63;c1B63e5g62;!a40D8g10D2s0z1065;!p11;o29u34;d0r16s8;e41A;k90m39;d0z1E;n266;oAFw10;c19f459s7vB8D;!a1FE2e4i6s0;p140A;e4EpD4;a5o9y0;k7E;a3640i503;!a155FcB2eAi6k4A65l22o280Cs0t2277w27C;!b3B51c9FfB5h109i186l4E53m62n22pFEs0t28E7u4B5Fw4D8C;aB8Fe319A;p945;!e26iB0s0;t11B;k1As347;a2FA;!a4Db1D67d0l3D6Fr133s49A2y1;!a10g7As0u3EDD;a20i495o29;a25C;r14F6;!r1s0t114;!aDs0t161;b3DAD;c367Cm105;l3109s49C7;a17d0o10r234t16y1;aD4r377;a1Db450l8E3o4B08;a238i250uB79x1F;iB6C;!l2BFs0;!n118s0;f2636;l3An0;t7EB;c3B28n2o10;!a524e3Fn3E71r4C1Es2143v3;!a52b648d0f276l7n22r0s402Dt33CEw136;a101n1rBs35t3;a5Ce0o152;n1s9E;a32oEF;!f30E2i3Ct35D9x68A;!b1DDDd56fB5g2425l76s0;!a4Be10Di6l7s0w80;!i753l38s0;a0i4D3;a795e26Ai32F;a3A3Bb3E9Cc1D78d2FA7e195Ag4D5Ai33B9k3260l2Cm26F8n3BC6o1026p2A03q21B0r4D43s1DA1t28D4u1FB0v5045y451;i51o138;!d1s0t18C;!e20C2i206Fs0u1;l4BCn0;r50s1F;t32EF;!i22ECo2C2Fs0u48FB;f3B2D;!i1DoEs0;a2628e3FC7i61o1F72u14;c0n2s0;!a135e4iE7Ds0;l60t4E6D;n65r1s48CF;e1D75hAE;e1712i6o72s0;a150Fi503Du2C5;e17i43y0;!d0l1r1s0y0;!e10Di6l7s8E8;a0t1;a1t0;eB57r5A6;cFDAh423Ek1s2798tD88;lDEp2086;a31iA18;pD2;e12hA44k2A5;a1C08;e14D5o9B;d3i153n4p1r4y1;i813o40;!a375;!a18Ed0s0u5;!e0r19F0;u4185;a3FAi12;!g4BD2lA7r118s0;a449e2CCF;o52;g94s1E;e1Eo81;r58A;a3531r87;o5E;!e17Eg0i6s0y0;i1EECo2134r22u3A28;c55n116p55;a439e1E72u3;!f183n22p72Cs830;m107;cFD3i42Ek2Ct1Ev89;a1i1y0;eAD3i6;d1kB11mDEr33DCt2A55;n2E7Dr3316t28;eAiFAo8C;a5084e370Cl2D78m3n3341r3ECDs1A49t329Cu4B60y1;!a1AEDe4B14i6l10Fs0;!d3Ar1s0t20;k5An2;a2643u4E;e1C75;a12c1F1Fd1CCe1g131Fi35EFl1BAAm1509o3DA2r1E1At3282u4956w2F7Fx0y21EB;r84F;e1B2o1A7;a1B0eAi6;e895i6;!e15i21l679s0;g4A96i56t1C9A;a8w1;!e0n0t19;!o1C2s0;d1t3;!aC3Ae2842i4DBEs0u1164;eAiBB7l2B2Ft1E7;a1878eE89i4E39o586y63;a4C6Be428Fi17F0o2C8Br1F4;a21Be2C3Ai6o11E;e201o21;!c4796d2C7e38CCi0k5l29Fm2En2E55s0t1;n27D;i238u5;n21BEp131;i108Fy0;!h1Ei18m2Ey0;i18FDy3F58;!n8s0y28;!a4CC4i3C02l61Do139Cs0u2C4A;g5Bs3C0Ct2D;u62;!a2E10e10Di2DCCl7n22s0t11y0;b3D7EoC09p1634;!e4i1D9Bm2Es0w80y0;!i41l53s0;!a511c4966d30C9fDAg3596h530k68FlC1Am4A8Ap1466r1DEs153Et31C5x121;!a405Fb2C31c4FD9f5048i4973l1390mF9Dn4BFEo372Dp827rFF4s0t1EF0u62By0z4007;t20y16;rC6FuD;g16E;!a7FeD0i4782s1BC;g11F;a1ED7g3;!d499Ag14Fj14F;!f37l22rA5s493Bt32B7;e33i6r126;pBt84;!i495s0;g2Cs2Cv3;!d0n39r1s0;!e8Cs140;!g0h594k48A2l219n7E9s0;b1ACn8F2;iB77y0;n4p1;fEF9;b0d1;eAi8Ey0;aCr19s1F;!eAi8Ey0;!d0l3Fr21ABs0;r18tB;i77o29;!eCCAs0;c3A49x1F;a3AC5b1124d41FBe26EBg25D8i26B7j4809kBEAl275Fm4168n13CDo73Ar45E6s3F20t3E46v1804y0;s3t5B;i9n2B;t37Au1C6;a0e471Co3957;!i13l2Ds0;!e21Al7;h2ED0;a19A3e50E0o21D9;cEDh4884k1D3Bs3B47;!d0l1r1s0w80;l413;i871n1y63;l3782;!i1t1;e6Co81;i2A9;i2FFFl1;!d5AAe46EBi17CCs0;a3DDAe2459i180Du1C2;i4924;!e15f37i38AEl22r3425s0y0;r397;t1D;a7DeEBn2o4698u14;g38nE37;tE20;a32C3i1BB6l38E2u30E7;e1i3C;!fF2;o69;n1Ar1D40;aE9eAi1C5;!a1Di13s0;b3De1Bk4Cl7n2;cCBDh5059n89;aDeAoE8;o49B9;e1i110;c0f7s19z19;u1848;a7F5l23Co1C1r4F72;!k1l2Ds0;e2070i4E;!a351c2BBe24i6m2EnFs0wA8;i45FBn1F4DuC7;f0p1;lD2;!e4i6s0t35;!e2169i2F38s0;!e1F87m8Bs0u11A;d28s5A8t2881;!a7Fc44i25rE3s0;c408E;a146EcA4Eo10t5C;!m3FABs208Bt61wA8;!d3Al22r1s0;r4B23;m87n4F03;!m5Fy0;!d5Be1;a7A8e1o1u4E;!n4579s0t0;!e4s0tB7;!d0g80l6Br1s0t16;b41;e6A5;a2322d1k1l1n1BD8pA4;e1BnFs179u14;e506i196Bo582u2E6;!e12i3Cs0;!a4DeD0iACm81Do130r261s933w2D0y0;gBl1n1r303;p5B;eDl7n125;b23D8o1;!d3B34e5A0g6C3i1DBs0;!i29Br26F;e5o105;d3FAn118;c2Ci4n6A1y1B7;a3BE0e159Ei119Co3E75p0y319D;p10B;a6F1e2ABDiC40o2232;d39t1;!e1Bg6Ai200Cl4C80m1n22o1s0t1CB;r334;d0r270F;!a40e902h1ABi1265s0;!a9B2b1E8e4F1EiC5l4DBBm2Ep2979s0tB1D;d12D;e2F6o586;a20e12r996;e855;a2CADb4AAFc3728dF50e40B1gDCCi415Dk3543l3323m27A2n1B6Fo4FBCp3F6Cq3449rD68sCADt4D92u47BAv36B8w274By2D99z7B1;!a63Fe14D2iDF8o1t1u4A63;o3B0E;d1AsD1t26E0;hD7Fs1F;l21F;!t4B3D;p175v69D;aF54cEi86Bn25o36sEu5;a7Fd3Bl64;i4F4A;a1oD;!i6l0;aC2eDi2A78o1DC;!a423e2B02i6rBs0;!c1D3d0l7n39r0s3Ey1;!a48B3e3AF6i1FDCl22oCs0u3CCw172;c35n2o10v3;h17A7k4412;eC3;eB04i42Dy2D1B;c9Er3;c11n2s5EF;!c9EeAi6s0t1FC3;l64m2BC;!e3C12;u678;!e4h1650iCCl22s0y0;e1Bl7n2oEsAF3t7;!h3B20;nB4u36;!b1DDe15i43l198s0y0;!m4As0v1;l16v1E;a2079e8i168o3E95;!n3471s3EBB;c2Ae14B5l1FEAn3ED5rE4s2583u25C2;dD2i4m1Au5;n2F2;dBl1CnFo10;a5E6s0;aCc3A2Dd103e3069f11C6g4293k1E11l3E8Fn312Dr1BB8t4B26v1687;o159;i715;g1m1;d0s8t11;s147Az5EE;i871y0;a12F9e1EE4h120Fi33B7o3F1FuD99yF8B;!e3D8i2EE1l22sEC;e23i6l19y0;c16C3m2918n2o1FE;h2482;o269;c4Ag4Al28n5E0r1;l7oF6;d0r253B;!c5F;c5F;c3Bn2o10;p210;eAi90A;d3676e12n430sE;aCi1C;u7A2;rAD4;a4F60b2523e0l42F4m4727p3CBErE73t192Au1;dBm3500s11A;!a6D;e1i2DE;a4Ci3A21u6;!d1DDe257pA0s20Ft2D;o353;!l7n2693r0s3E;!e15i2D4Ao29s0wEAy0;n5E;c3F2l3A06tB93;a4De4093i383y0;e5n2t7;!d16e4i6s0;r8F8;eA14i32;i408;c2AnB;sF3;c1301s2E88;o9t445u5;aEFe97Cr1F92uC7;!c247n58;u277;a1g0o36;h40F;!aBCeAD5h7B2;l506BrB;c8i13u14yC;l22A;!b343s0;o2AAD;a40i284B;!e5h48E0s38B2;t1AA9;!d70g56l0n4C30p4CEDr320s0vB5D;e30k16;!c7gBl0r7t210;oEx66;a42h46E;r3ABs2B2A;e6EiB;e28F;!e538l7;m64z87;i25nB;!e0i0s0t1;!c1k1s0t1;l2BCy1;g49l1C;a69e23i6;a680h1ACBr27E3;!aD8i5DFs0;n4460p3737s1E7Ft310E;!e4h33Ai6l643s0;a341h0;i260l709;!d0fC2r1B4s0w1C3y1;e1i36E2oCu5y0;b17F2g25Fn44A1;c3Bn279o16B;d4FA4;a126d157nB04u969;a3F0Cb1A65c1ADCd35DBe97Cg2A2Cl3ED2m1B3Fn4128o10p34FFr3C35s1EA6t512Ev1F85;m3rB;!a1C2BcE96e24i6l22s294Cy0;!b1Cn155s0;!e4i6B5s0y0;!g373i86;!a4De23hAEi21o1359t1u49;e113i96l7sD38t4A;p90;a5103e2011i2DADl1428o465Dr34E5u2A19w4C2Ey41BD;!d5A8eB1Ff10E1i6l22s278Et38v4D19;!m343s0;gC3i25p1qE31;n354F;o9r1;!a1dC66e1581i6C7n3836pDEs115t137;e4150;a12gB;!s0t2D3;!r55;c13Ad38g1B7t68C;l2C3n1;l55n316Ar50s3DFDt20A5zFD;a2112e3B3Cn1A1Ds1AE5w0;a4Bd39;!aCe4i13s0u5;a37ACe14Ai4CC8o4176;l10F4s3t918;!cDFd0m2A21n163r1s859y51D;i2BE2;i1EE3;f108i10l3An1D8s20;a1eAE2;a10e2782iB;c2F8e7Ch2044k1p1892s345Bt4B6F;!a7Fe5B2i91s0y0;d1D7gBr14Dt206;g1m27n54E;!a2C5e21A4iB9s0;aEp19;aCA1i45F6o1E4Eu24B;!n21Fs0;e1Bg94nF;y28C9;!eEiEs0;gBs0y34;!c42D2d2615f2D56g308l265Cm66Cn44B3p91Cr1s5047z6FF;!a601i3272o43Cs0w29F;c44f108n49B3t3FC;c1A78iFC7l175Cm41B6n42F5s1914t4C86x16F;t1041;!e15i6s0t1E;s1Ft1D;e2DmCD;b7Bl80Bn8t4A9;!aCi2F2As0;y56;a1C3DiF25o356u3958;!h103s0t4F9;a2Dc11;a3e1o46;e5s102;e1Do35;a4E2Al1A0o2182r1133;h2DD;!a9l7s0;a3EFBeAi21o1056;d0r1t1y16;k3903n1;e1i2Bo16Ay0;bC8c961l66Em3767p10B;l0n1D8;!b121Dd21D6e4gB22h997i6k289Em3791n14Ar1B4s124Ft353Fz3BA8;!i42D8l1Eo974s0;e47ACi2964;p1r1D;r21D2;a303De0o3916;!e4i1C5s1411t13F;a2CD3c233CdEE1e1i4BCDl49BDm3A2Fn2E6Fo4F5p2D43r4ECDs11E4t4FCCv3ED1;g3n27D;!fC2iBAs0y0;a33B4;aDCo37A0;!a5t951;!a981e1DFh1F7Ci1A91lF5Fn22s3AA6t2FCDu438w396;i359C;hBi4CE;!e1487h18FiC24o9pA5Cr154Fs0t2E5wB1;h594;!i9s0t1;h4B84;!d0i6r1s0y0;!a1e15Cl1E04m1AFEo2EB5p8E9r200FsD24;a3AB7i2EBr2629;a3CAl2C;!d0f7n8s0;c2248dD2n46BFpC53s1Fx2E46;eFFBo1585r1994u460Dy52;t7Du82;n8s1B5;b1482d47BCe42f3289g3A5Fh134Bi3C58j2A28k2280l47FFm44F0n2A9Fp5095rFADs1E83t1389vF10x326C;a4c2An2o2Ar4u4;e0i91y0;!e93Di6o12s0;!a3D3e4D83h14Di24ElCEo56p165rF3s0;i33DF;uFD;c3AD7i1CFk5Bm2Cn4116p338r4AAs145u168xAE;!l4661s0;e23iFAo40;a3DFe249i59Fy0;e1i35o40;!a0i0o0s0;a142Co50;r86Bs20;g19i12n4r27Bt3y16;i128;s34;d521g1n48r95FtAB0;d1l1D;a2C39eA5Fh1454i4226l43D5o2540r3C34u922y3668;a0e5s14Bu14z3;!b163Fc1605e15i189l276En22sECy0;d1AE9l2002t1225z184;a9e9o20;i6B;!n295s4088;eB01h466l3867u5C;e0g1;f1F91;b481;v6C5;!a3CDe36E4i2367l4D82s0w1C3y0;a6E2e9;a43BA;!d0r3591s81E;!e5h4447s2Bt3456;!cB2h1F;d2De5s2B9;a49uE;!t7E0;f1642;n90F;e42i123;eAi24E;e0h0i7C3o29u164;!s0t121;a12o31;!e4i45D4s0y0;i0n2A7s0;f108l1A;!a51e15i2FC6o31As0y20B7;iA56l19y0;!t92F;k3093;e1u3;e0u5;aA2e24;d0l1F2r10Bt1;e0u1;!eC1i309Bs0y0;a2D10;a38F5;l2D2D;!a4FDCdA9e1f53Fg1B81i1l7EoF6r3C9s2876w38Ez925;!l4950;!b1Cd3AEe0r1w26F;s1FDE;n191;a1BFe93;!e4h16i6s0;m161;a42i11Ao8A;e73iE;e85u14;!e4i6oEs0;!m3s0;m3s0;aA2z1A5;v2Cz1A15;m0o12p1C;!d0l6Bn4C2As0;a171i0u5;eBiE;t0w80;i3B7l2FB;!eF9;!e0g0s0;b21C5c1FDBd2E79f48D2i30A4l350Bm30F7n3A53p414r2C3Ds312tB19u1v3662w17D1;m10Bn1;cD3l0n82;r137;t252;!e4i31Bs0;r3BBt16A1;l1F4u1D;eBE;!d0e1oDr1s0t1;a17AEo3A8;e12u12;m923p2DED;k1r1;a80Dl1D3u32A;aFEBe38FAh146Bi585z1F;!e4i43pCEs0y0;!d0n142r1s0;!bB1fF2l7n22r0s8;r12D;s414;a70o46;!iBoA6s0;y10A;g331t0;!e329i6s0;!eB62i6s0;e12i199lBoBy0;sAC7;a11Ce1BB2i4197o2BDCr26D5;e32E3;i995y0;!a2D67d386Be2194i4D4Fl135Ao326Dt256Dy1431;!e5l307r157;h4632;!d9Fg38s0;e2127i6;e33B0u805;e3810n1A24o2ACpF2rB9;bB1l417u329E;m53n8F0;o9t48;o1204;!w27;e2714i32A3l3y0;!s4407;!a4797c2968h2F1i79Eo1s0;!d0fC2l309n1E2r50F9s0;e17i21;h4E86t2D;b394De2639u36A;tB78;a136e17i6CEo18F9;!l7oD;!a4Dd0r2Fs0w847y0;!c7h3Bk2545o1s0t273;a3249e129;l318Es0;a4FF3eB9i157Co2337;r2Av3;c444;d14Cg94v3D;l8BmD09p68ErEA1s3AC6;eDr3u1;n2A9;r55tB;d42Fr1z431;l6Ar36v19;n2s19z19;f2FB7t48;iA5u50;eAoDu5;a578;e5s2C6;!e2D62m41F9s0z8CC;!c7l7s0;i73oA6;l24Cn8t316;i71o2CF3r227Ay0;e6Ds3;t1E1C;r3A6D;t1203;eAiBAA;!b6E9d0n15C7s4BB;a9D4e4i21;a1c1AkA4B;e1iADo46;!e4i6l22s0;!n8r0s0t3;!a1s0t318u2CDE;!d3C8;!d0s0x1F;b106rAF5s4744;h1A2C;!e2DEEi18D6o8Dr134Ds0;n3550;a150Ei904n2391o252Dp82;!e456hAEi6k271Bl76s48E1t4880;!a4Be15i6m2Es0w80;b0g0;!e2703i67y0;a44FD;!d17De1DFFi3C67p35Ar2C11s0;a48B9e2F2Eh2AB9iBAk4149oEr91Dt3AD1yA06;!d0nCDFr49CAs0t2ACBy1;i4152o2DB7;!e2CCo12s0;!s5;l1050;!e1iB8nF3s0z1A2A;g8EEx1F;l5Ar5A;b123Ec24F1d1E4CeD7l1E9r1s35Ax4897;e8FoC4;e12i6l19;p19s347;a3A24c1A12e4505s508;r4042;!e4D1Di1FDo311Bu2380y30A;d3C14g134Fk56l4r348s2027t21D;c1C45i195n359Ep39F9s11At2D7FwCx1A4;i206A;n2994;a40e23i6;c0dBn1s14t150u14;aAFsE;!c11d17Fl0r0s0wA8;e9E3;c6ABd4155e48Fl3AA5n364q4367t17B0u421x3BAA;b2799d4045eAf402Eg1264h3C1iE0Cl3DC1m32E8n3DEEo6E0pD90rF6Fs24DFt2955u3FCEv437Bw3BE8y3D15z47D0;aDAc13AdF86tC8;d18BFe33CCg1F13i3Co2CD7t4A;e2DC1f3624t21AC;!e415Eh14Di21l44s0;!bA9i5Cl3549s0;!k4076u9C7;h64;!e297Ci3D3Ds0y0;a2C35iB31o17;!l0n0;a35DAo1532;!a1CD9e27F1i24ElC0Bo324Bp58;!a1DCEc4CFBd50B2e0g3Bl4D2nBr1s2CC7t2023;!a7Fb429e15h776i1ECm2Es32C;!d0l175r1s0;!eC1i86l7s0y0;!c19e0i10n3p4Cr55s0z864;b1CgD4lB89n174;a24Bb32E6d34FBk44l367m2A4FnF7Do1AFDp2BBAu318Cv3w899y0;!b4E4Ei449Ar9CBs0;l638;!l191;i8m0;!g3k1F1C;!e63D;!a410Db3Ae4g42Bh6Bi90Aj6Bl19Cm2En3Ds0t371;e602o1A2;l60r16;nDFs763;h117t3083;s33BE;!e4FEDi86l7s0;d0r1tB25;n2010r2F3F;aCDBe2566iC6Ao1676u1CB1y148B;oEB;!e12i91s0y0;eB32i21;!m2En0s0;a45B9;e48B6;!b25B0c209fEA3hEAi1DBk5Dl219s3E9;!e1E8Fl7s0;!aA96e3E2Ci389Do1BDBs0u4Ey63;e1k4Cn2;d4;c2B7;p20B;!f37i6;e113n2t0;e1Bn2t0;b1CFcEd7Ai2D45l877m1En2CEs562u23BBz1E;!e27hABFs0;!d0s0t20;g1Cn1E;!a1A3e347Fi67o72s0y0;a3Ce129;i4A13;l3CF;!n122;b7Bl3n2o10;m7Et48;a59eA1oB;i8y1;!c4An111A;n2E97;n76u1;a1F7A;a4AE;t2Fv3;a1F7y6F;n5r152;c1C83d103e4F84g1473n2325q2295;c11d1;s392t49;k187l32;a2C2e5Fi2Bo46y0;n2s11t61;!e153l7s0;eB8i2FDA;d900f4B37p1C2s360;!f7o10t2B2;g47n4B;g2397jFC6k1l28n549t3F3A;r16u12;p1F8t48;!a4F51b26E5c20F0dDC9e4D48f377i3ED9l40E7n42DAr23ABs429At413Cu1Cv205C;c19l1D;i3A6m1Ao29y0;d0n588r1s0z2C;e4i86;!a13C7c4E69e46E6h302Fi42B1l3BF6m6D8o45AAp50DDt10F5u34w1993;!a3579e192Cl7n22s1705;o437C;e3B12iBAy0;a0c3D;i465A;e85i2C6E;d0r441s0;!i2DCl7s0;e2AF;e1362;a1Dc21E9oE;!m37C2s8C0w25D;c244n4003r4FDAs83;e1D0Ah109iB60y0;r2B8;i10BB;g5Fn2o10;e62D;i4616;k2760;l90B;u2A56;n0t5E;a26C;!e1Dt4745;i2ED4y0;!e4i34C5s0;!e4i6l0s0;e42E2;c363;d72Ak1l1849m1463n2F2p3F9r1042t116A;m1r47;r33A;l2C8n0s239;d0n175r16t0;!a1Dc771i9o10s0t37D1;!a1B21c4E97d13E3e1176f6Bi1850l82m397Bn446Eo35A8rE7Ct18DB;!e5l413;!e1Bi288l7;r173C;e3Fl29;d5A;h457Fs373E;l8ABn192u2602;aCe1AB6i1013o4CC;!e15i21s1BCw136;n65t16;h29A0;b1ED5i34C0mD01o87B;!e3o6Ds0;g1i1C4;n2s11t7;!eC1i6l7n22s23F;a495D;a8e73;j552n1;a127;t487;g2B82n514E;d188r0;i4l46B6t0y17F;l44r167B;!a4988e5iF8Ao29A8s0;l1077;l2FC2t145v3F5C;t39AF;!d227s0;a20eB;!eC1i6s0y0;!eF4Fi86l323Cs0u49;h1A32n1BC9r1F09;l349;i1FDl366D;!aCe1o4EA2s0;!e1C8Di230Bs0;vB6;!e15i21o1BDs0uBE;aDd3oE;a9C0e23i6u19;a3E50c248Ee1F11f1n352Eo29;gE5k1C;a18ABe3333g2F8Dh1378i4DF9l32B5m1An2E52o38ABrCEDu1923;g94r19s8t533;!d0r41D2s0;!d1Ae42s0;a13CAe1oEF;!i187Dm4D7Bs0t4F46;!b1E8c1E5d3Al36Fp10Cr1s0;l19BF;!d1B80i4044l52nEABr56Cs39Et9Fu8F;c3Be1Bl7m19nFt1C;a1Dd0e8g94;o143;a548i3Fo29;s852;i959;!l48A8s0;a1AF7;n3284;!a6F;!e1Do29s0u4E;a1c11e1i30F;l28n1r397Ds35t1;s2B;e473A;!s115;!s2B;s115;!a54e42h1E;a5Ch2C;l28n4A1s87;a4De1953i394El2B25o268Ar2AFEu34D3;e31D0i6;a84;!o29s0t20;l3An8;!d0r137s0y0;!e15i6o25Bs0;iE7;z98;g3m1y0;!aDCi6n0s0;aCb58e1o29;i701;s2E3F;e35i4ABAy0;h4B2k39;!e10A1i6s0y0;hBt1A;!i31m3F9Br4DB2sA1C;!i4EEoCs0;n65r3;i57Do1A98;!e2D27g7Ar4513s0;!a157b180eB95i1E50n22oB44y4C5;n23A9r241E;!d0i6k0s0;o1E3Ar2DsAAB;c160n2sE;r19Bs1F;c1C7u12;s5Bz187;!b7Bt1B9;a1eAh2BB9i6s4AF4t3E64;eDi6C;!e4E8A;s3153t1915;aDAe4E4;e5hAEi5s521;e1E5oDFu2E6;!n54Eo10s0;a3C52o4Eu73D;e600;i7BoC4;a4Be1;z182;!iAA9m1As2766t2Du5;h4E55;e4i2F0y0;!a282Bb4F21c3EEAd2DA4e2581f4970g11F9h3F2Ci21j502El393Am23A1n42BDp127Fr4F4Ds413Bt2EECv359Bw20B5;c2AE;!e15i6l4F77s0;n3t1;i171y0;f3F;m2CA;!cD3m4DBFs0t18B;!p343s0;l2898o2785;!a9CAr3Bs0uD1;!b1D7d0f37l522m64r1s0t11C;!iFFEo3654s0;aCi4oDu4E;!b227s0;a1B1eB8h1AE2;!a1e58B;e0oDu14;i903;a2B9;eA4h60i838y457;e32h5B5i3A95k2921;b7Bd3AEg19n8t1A;d5B7o29;eCF3i21l7E;i3944;b27C8c363d3627i367l3A4Fm45A2n118r41F8s2FCt1F02w4302;c29F6h436;iE7r9DDu59;e4DEi37ADs35;a1eEi2By0;i699;a3E1e5039i10B7o7u1EC7;i36l5F;eA31;n19p1;m45n4;iA15o54y0;!a4De15i43B6l22s0u5y0;!a1d6As0;b435cE90d8F4f4D3CgEB5p25FDr2E54t178Fv4D35;!a9d4DDn3;c4E9Ag4Ar289B;t270;r1BD6;n29AAv2Cw0;e12D;e433;a12E1e4F93i6n3oEr4664;!e769i2153o1980r22;d0e10r211;d0r1s1B5;!r1s1Fz1F;!d0r2Fs0t0;l4645n1281r372;aE1n2s9At7;a5De9z48FA;c145Bm6B0;s2At3;r5C0;!b3D9Ec406Be15f7C6g63Ch183i2407l832m4999o7E4p47Ar1DEs1D23w172yEC;r3EBF;e4A6;!e5l19;o8r3;!e0l0tB7;!e1FBfB5i426k5Ds0y0;e2C54h3Bo1;!d3Dm2Er7s0;a4Be3A78i6m90r45ECt39;n2Av3;n1D8t19;r0t19;!d0s0w4C14y0;d5124l269s0t302A;p21Dr1A3;c3DB3r203C;a1856d20AAe273Ci172Fl434Du1305;c32o34;g94n25;a5015e2548i3CF1l1CEBo11CB;n0s2C6t7;!lB20o1Ds0;g5Bi4lA7m3s5Et2D;a4817e22DCi191Al1420o143Cr3645s5D9t4Au50DF;!a1897c3F94dFE9e3D7FfC2g2686i1F2Am180Bn4552o4747s12A6t313Cz38;i31o36;!e4i6lABAn0s0;a1n37F;n49AE;o1263;a3D10i57;eCg3;d0n16r1s8;e146gBm24B0s4DD9;h1EEFu57;o9A;e0i6;d0n6B;!a4Db151c35Ee1D91f37g350i3B79p35As56Et1DEw41Cy0;!a49F6d4EA8e4F99f0i496l951n2378p1r58s349D;!aCiCAo29y6C;g2Cn1r1s187C;b1CgBr303;!a38Fe15i42E8s0;n5DD;a3A73c3615d3ED3e2F72f12DBg16BAi387Fk12E7l50E4m396Cn345Eo46DDp3DAEq1D94r2101s3D73t4F9Du2047w4DF2x427F;e50uC;o18AE;e0i246l1;!e33t1;e33t1;!a12e1Bl7n22;c23EEn2;!d0l9Dp68Bs0;e24f4FE2v3D;a1A3r5B7;!aC36o93s0;!e15f37i86l198s0;!e8i4s0;a2F8B;r17D;cA5e1Bf1n2v3;a1B9Ae5104i3C92o4A12r2B58u1594w2EE6;!a3DDFd2EC8e20ACg6FEi16B2n3C64s1DE9tEC9z18;i43C5;n55u61;e0i27;m414Dn35FC;!n153Fr48Bs115;!e927l7n22;r4E0;r214;!r1A;iA6A;e1r1E4;o3ED8;d17Ft0;!b8F6s0;!a7BBs0;e40BDi41A7;n3349;!eC1i77Dl7s0;b22BgE4l126nB1r275Dt2C;o4347;!aD96b4570e1AA8iCCl1F86n4030pB1s1DE0t1DEy0;a18F3c3FBe8C8oAD2;e5DA;a25B7e220o284;!a1h38l3D21n22sB24t1015;rB6s36;a481Eg28BB;!d0h203p424r4F5Ds0;a35D8eE0Ai194o93u670;!a1e1Bi31l7n22;i277;aCn2v3;g55x0;a2B2Db2517d33DAf28D5k3m3C1Dn1FFo1A19s4D3Et3227;!c291s0w10B;!e0n7A3s0t19;c38C1g2045m27CCn3EF6p841v38CB;!d0hEAn22r1s6F2;t4B6E;a4Et4653;r28t11;a245k3;!i7Cs0;a41A2b1A7c4965d230Fe450Ai3B35l47CFmF55n170Co31DEr3762s146Dt3D9Au34w50B3y4FBB;a3860iB8;m1CAA;r4070;g0t16;!e1i10o10s0;l1r16;!e3DDfC2h109i67lA3Ds0y0;p131sC0tB;z5BD;k1AnB;!a256iBs0;a702;e46A9;!g150l1s0;e50o8u1C;n89oE;!a30e0h38s0tA9;a4Et4298z0;c2B43h50D3;!e10Di6l7m2Es0;a2B0Bu9D;c18EAh11Fk28o558s5D;!aCe747i1332o1E09t0u5;o483A;t3D1;!c7e0t3;!a781c50F1e580i1881nDFo4353s884t42BAz3;e1Dg1E;a8AD;o4A7;!o5AF;l2E70u1;e5t3;e0iADD;a1e134i3F;e17l1A;a88e46Bo50;u5CB;i6FuC7;!a10d345e14AFnDEs4BAEt11FwBA9;!e15i6oD8s0;g19n170;e6Er354A;t1Av1A;a4921b210Ac29BBd25BBe15Cf436Dg4D4Bh1i4B9DjD58k4CC6l3AFFm28EAn159Do4133p349Ar4FE3s478Dt23E7u14D4vC41w4EF0x0y1C0z428C;d14Cg94t1z19;!l0r58s0t3E7Cv62;e1C37i1E30o2A6y32C5;!e142oCs0;!i995s0y0;!a7eAi21s0;!e10m11Fs0u4B1E;o1CCu47E;d0nFp27;!aDFFe155iAFDs0;s34t150;!e15h3B5i6l2Cs846;a2AAe17i168;!a333Ei77s0;g19p16;!a35D0b398e4i6l10Fm2Es0w10F;e1Bn173s11;a20e1Bo278Bu5;!eD3o10s0u34;c121e1Bg13C;!e15i67l37Ds0y0;!a7B6e3B8fB5i3735o256s0;k4764t5069;eA6l19r19t1;!d1D0m6Ar2524s0y2500;a25DFc41ABeF08h1997i1456k383Fl506Dm1D07n3o3F43q10E4r2BFEt2B27u2E40y49E9;r1E1;!e255;c13Ad10A9;a69A;!b352Fd212Ef106Fg14BEhDFk4B4Al1EBCnA91p4ECCr404Ds238Et393Ew4A75;o57s1FDDt3898;!i13oABs0;h2336;aCc1s14;!iEs0tE7E;!e4i6y0;m262F;n52s14;n3s14;a4AEo3EC;!e7s0;b2D;l371;h77;r3777s11;d3e146;a2ADFh38i1CBBo2F1Ft2042;k0m1t1;n8BA;n1oA43;!e1Bl7s0y0;aCiB9;u2C2;d16eAi6;nFt3;aCg0;c2BsE;d23EmB;e15i27lF4y0;eAh4853i6;a2E8Dh2F07i50EDo2B17;o2FBu11C;!i31s0y272;!b1CF0f465Eg4247l4A4Dm163Es889w1468;!h2B6s0tA9;l0s14;e1i4C3AoB;cB2e3EDt28;!a11D6e10DiCBn22o184Es0y0;!a51e12i6o0s0;a4De1F88i45F3oDrB;e0f14C9t44B;d4Bf2Dn2;!eFFf37i8Es0y0;c46B5g238AqEC6;t1A52;l1DD9r1A;!i1542;a538i3F;l238D;!kE5m2Es0;n5B8p3301;c35Fe1Bg94n2s27Ft3;e5n2u57;!r34s0;b669l4A3At1B9;a33Fi3Do0;a185i132oE8;i4F20;n1t2D;a186Ed0m49F3r2CF7w0;a59y0;a34B7e409FiAAAl4B6Ao4EB9r480A;aCe1i250o1;i458Do6EF;c248d1A;iAFC;i18CE;gA4;l43A4v58F;a9r460E;d0e5g94m38An311Dp338;b7BgA4nEt8A7;a4Ae4A;t2D5;s66zCCC;h1Fi4D;c2FCg268C;d1Am0;a4514d1080e40B9g6C3i38CFk2A99l3C1Fm2217p827r1DF3t362v18;c1n2t3u14;o1047;!e4f28i6s0;b2E78c3431d2C0Fe4AB1g144Al2290m39C5n37BDr3EA4s1E07t243Dz141E;eD0i189y0;aCd3e1s0;u719;a221Bi8;n304F;n8D1;!e6A;l27B8;!b1E70m64nB80s5135t1;d292n4F73;!i0l119s0u5;o274;e1Bf7l7n2t1;a311Ee3A3Dh2F2Di2DA0o4C65r3931u17E6y2D2;e31iA15;t2250;!e4p7s0y0;!e0t404F;!eA4DfC2i8E7r3FDw2F1y0;a30iADnEpE;n559;i13E1o0;e0t39;!cBDAl57sC5;a169F;nF6r48EEs2875;l1A2Es0;!c17Cf240i0o3D65s48F9u5;i10C;!a0e36B9;t492;a3D41b1543d2670e18FEg31D9i6kBl4ED1m2EBFnEFo4359p4472rEF5s2FF7t247;i4F68y0;eAh7F2i6;i3Fk16l16t39;t42;!a8i8;e1i270;a30e15i6;!d0l39r1s0;!a75lB;!i9C6s0y4EE3;t4D16;a4DA4e37C4o47FBu3D98;a1e3Ei0;!a4CA3eD63i4E4Co19CCr353s4F7uD7y4C5;!e486i8Ey0;a1i4l0nB;e4AD9i383y0;e1EFi224;a347e1;a59e17i3314y51D;!e15s0y0;i4s4705;k489D;a4C8e12i21l3o43E2;u909;!d0l76m2Er1s0;e1747i91y0;i3Cl3CF;cB9i46EA;l2532m88Cn2D19;h3720;r178;a101i16B4o1586;rE6;e477Ai174;u6B;!d0e10n1024s0;o46ACr1C93u45AB;a4DD1l34An158o21Cr1DCt443;g3281;a28B2;aA3fB1t20A0;a323i108C;!e5z4804;!b465c4547d0eED2gBn4E90oD1p235Dr1081s0t0;!e15i6l7s2261;aAAEc0s3B55;c1s14Bz3;!a49Fe24i6y0;a23A8e2E62i3033l11C3oC6Br2A73u2C82;a2C4Ce20B0i2894o1F1Av21E;!d0r7s0y0;l2C20t1C;!a51e15i6s1F;!e4AF8h1D0i21k3766m2EsEC;a7Fe4046iC8o856;o4r8;a8EDu69;!cC3d0l1qC3r1ADs0t1CD;!lF0n2s0;!o6E3;m8BpD4r11C8;a145Ce16Ai14EAlB;o88;!f37l22o49F2s0;hC;e59Dn2;d0eAi6;c0n4D85;!c3FFBd4F64fD83g80EkB6El7B8m28n276Cp31BCr2C45s3FA6t3A5Cv413E;e0h103;aE6iD7;s57vB;d0e5nFt3E17;h87;l4144;e9i3Bo231;!a54C;!l7n22r0s842y1;e25y0;!d23Er1s0t78;!a33EDc3Be45EFh0k89l1A0Ao432DrC6Cs0t2CDAu446C;a50i31o34;a6CeC;!i428Dj53l1n2EC2s0u8F;aBAEe4A74i508Co43EEy7E;!n7s0;d292iD52;oF0;a0e23i29FBk31BDl38CDm4CD0p3F69q11Ds4F35t4A6Bu0v285Dw9Fy0;g3DnCFr1FA1;!d0r0s0w80;i115;i1F;!e4i21k436s0;lCAm0;!e4i4111s0y0;!e4i4112s0y0;o120uE;u1E67;n2o9s14v3;c1s3t3z3;l53r3;e0h490FiB;o14p3;a2F5Be4i6;!b1p28rB08s0;i51A;a32FAe4FE9i1E6o254Cu388Dy0;!b5De15i885l7Es0y0;n21F;h12F5;!a1DeAi2A4t16;!a4BeC1i86p1DDs0;!e1nF;!e14Ef37i301s0y0;!d0l22r4647s0;b1Cm1s0t3EE7;d4828;!a1E0Ec13Ae580i42Cs0t188Bu14;b0p28;n8t56B;a128c13EiC;dBe3DFt1;!iEs0;e62;c92n2sEt5E;!f37n83r1sEC;l3Ar7;aCo29;l50A5;cEr1;o1r2C1;n6AD;a4E31f3811t0;a377C;!a215b1C9FcE3Ad3474f4C88gC19h2074i1FDk16D8l4E26m1194n171Dp1F5Er490Cs27ECt16DBv27w1B87y98;!aFEFb202e185Bi29B4k3B21l41FAr5FBs0t24F3v28y0;i86A;!a40FBb1D5g1F6i501Fl7Em242s0u1C2;b38pF31s280;e187Ai6;a20C1b4002c3373d4256e1694f4E1Fg23F0h1B05i2984j1553k212Al2EA1m42A8n3A4Co2D7Cp234Cq4D47r19F7s2CE3t1DDAu3141v116Ew3E91y633;c32p1w16;!a16e24i6s0w251;a438Ci389o51B;eAs0;aCeAy0;!c2CFDf1g3687k0l28n308r1s2136t58z4406;c1AlBu5;b1CgBx1F;!i1BBj1D5Cs0u1;l3005r298D;h3A62;e7DEfF2s0t5141;kC9;a1780c51FeF9CiA8Bl4EC3n3BFBtAC3w899x32DF;d0r252;c32w39;e6Eh1;c19d0r1;l2Cr89;i32FB;r1AB;h344D;e5B2;dE28n155sEt1;!e15Di6l1B6s0;n1888rB9t18Bu5;t2FBA;a192c13Eo13E;n13BF;a3D0;bC9l3B;e31EFi4DB8y0;c58l3B0Bt3AEB;uB5;r1AC;!r3B;a10e1D;!a1e4l7s0;i1Dn25t148F;e1896i3B37;b8F8d6A;!f37s0y0;a4B3e999n40FA;n667;a512Bo6;aCe39Fi21;r29FD;c3d1s3;a4C6Fe99i137Do69u210C;!a2A66e3EDi300Bl108Ds0u4055;lBr12A;a4De23i1BBuB6;!a12;a135oAF;!c1416g309Ek1n42Cs33EB;c2Cd4450s0;e17i774;!bE10e1Bi3Cl7n22pB;!a10e1g49DBi4E07l32AAo4C5Ds0w2F1y0;s1CA;s27;!n18r53s0;e148i6l2C;!e15i6oD8s0y0;hE2D;i4972;c6C6l1480r417;!i3348s0;a40FCe704i20o3A3u1803;a20i5E9o29;h1AB;l4uCwAB;aB59;a9DB;uB9;e456i21v58;a169o12;!a4De15i21m2Es0;a610;h1l1;a7E8h568l3AA3o32A5r5E2;!d0g2Ch1l22n8s0t0u15C;!a1DeC8i4BD3u5;l4EB5;e113g41nF;r4B1;t3CCA;!e4h798i6s0;g36C6h30CC;h30D9;c308Fd104Bg2F0Dl41E4m3078o45p352Cr457Bs2C9Ft3564z452;a25l4883;b622e5nFp16;!a7Fe15i6l7s0;o73u2DB;k8CF;a4Be68n2;r9F3;!b6DAm227p38s1F18;e2E0Fi123y0;!a15CCe1s0t50B;!eAiDDu49;a1D4i3Fl15B4;eAiDDu49;a6Eo1;l777;a292Cu46F;x56;e9iBl233y0;a2D22l3A63;!d0n37F4r1s401x0;e61;!e4i29Bs0;!e15i6l44o9Bs0u132C;!a10e1s0u49;e33Ei2A22kC9u14;i48D1;u2873;l192r376;n31DFr1BF0;n2E74;a120Ei6;l445Fo44D8rCuE;eBCi33A;b1c4114o3234s43Bt1F6;!eD11s0u1C;e4i5D3lB7;lBs3;l328s0;!bA40e1Bi6l7nB26;a4737e3969i503o166C;c437;i5A7y0;a10h5F;!a9i9;!aCoD;aCoD;c244;a15E;!a7Fc5046e14DCh282Fi1624l31EBo0p38Dr209s0u142Ay0;a12i7FD;!c2Cd1eE;!h1304s0u2D2;h19DF;eEi41DE;aD1eE;!e3Di1B76s0;!s0t2BCD;e9D4l2Cr177;a45Ee1;s45AE;a5036e0oE8;c33Cd3FEg3604r14EDs3F47w48z2EFE;l9Fn4EB0r39F8;!a1D43c83Ah38BEi56t4F15u88;e4736;!e15i21o29r7s0;a4F70e1649i33Do9BuD7;!b42ECs0;!a3942e418FhD29i6n1253o3625p1Es0u16D;a0i20o46;!e0l1;e5l3;e1l3;e0l1;!aA2e765i6s0;e689i7F8;!a16s0;e45A;d0l1EnE;c2E90;o4u5;c3B8Cd3DE3e3E9Bg30BFi403Es0t417Ay63;!a2065b4520e45E2i4783m1778p3C51s0w1C54;eCs0;lA7rFC;h3D90k1D27p103tB43;iBoC7;!aCi3C74s0;!e4i298s0y0;g4711;g93Cs1314u5;hB42;!d196fE88g3E82n111Fr667s0u1v3A9;b50F8c1B8Dd3761g64h14E1qB7Dr1C87t13Bu16D;n70B;n3Et3;s3t19;!n8t3;e40C9;e391;!a2846b11F5e5024i4ABEl76m1Eo454Bp175Fs20DEu5;k0t28;o4EF1;a462f3808n28E6o46u2202;!a32BCb4F5Ec1890d1278eFFf1731h411Ei21l511Am165oD8p3B06r2998s1ABFv260w326Fy98;oFD;e1oC9;e1o29;e5o29;k10F2u285A;c8i4;c226e5n336Aw3452;n3CDEt1C8x0;d0r1t1y1;!o10v3;k458;!f3DFBl0m1BF2nBr3s0t3C0;!p2E4s0;i3Fo327Ay1A3;!cB2d4C59e7f5008k3AE7l360Cn1pE8Cr4E8Cs22E1t121BvE4F;f195v48EA;!a0e30D3i21l2Cs0y0;h66s66;aDAt48;a275c149CeAfBFl2Cm2Cn3623r334BtD4;a14BCiD7;mF5D;!a4Db1244l10Fm2ErEF1s0;e0g3D9;b7Bn254t19;n364;s3t230z3;a7Fc18h3k28;!t1646;a663;a12i430B;eAi8El19y0;r233D;!b3884e15Di6n22s0;!e4i326l6Bs0;!d1El7s0;!l7Dn8t3;e329F;d1e12r7;e29E;a411Fe17;e10n142;!a159e39FAi6o10r4DDEs0;n1214;!i8EB;a4De235i21o4A0u532;a36A3i1DlB;i32A8lA6Dr19A9;h5At27;a2420;!a69e23i43o46AFs0y0;a2B8EcDEe2323i3858k3BCBlEFBo1600r42B3u4381;!e1Bi3Cn22;!m1As0x1F;e28E8h5D;v1B0;c1l1;!i13s0y34;p131;a2D52e1D50h3Bi13ADl426Bo3BC8u3682y2114;d1An1;e15iA93y0;!e4i6k227oE8s0u34;!i50B9o5s0u5;!e4i8k4Cs0;lF30n27;i4m18s3u5;eDn2o9v3;e15i19EEl44y63;a82Dh3EBl5CEr281;r3EFF;oAA2;e159Fi6;c7D5l1393;!d1CiA5s0;!c9D9pB9F;h1l0;gDB1i69lA7t1BD;i128y48;a185o5;!cB2eDi1748r62s0u41C7;e13Co17uB1;!e15f37i21s0;i413F;!s0w4CBD;f7n0t3;!n14Bt4F;c0d1n0;g1s5;b4DE9i374l2D94p3082q42A9s0w5CB;l71B;a108bACFcA62e1DFg0i1A83k1368l18Fn45D1r3025s624t2FA9;a8e24;c1FCd3DEBt0;d450B;!i3Fo29;g281n1;n368B;e432i8D6y0;t64C;!b911s0;!eEEl7n2s0;t375C;g79Cn27BBrC2A;e15i6lB;!e4f1F1g1D0Ei1BBk293l22m2272n2FsB24y3556;e4B9E;b16Fc2Ad44E1e1f2Cg26DDi34AAkBm4C21n3659p41E3s5t380DuD1Dv358Cw4ADBy48;a363;e1Bf1063n2;m294Fr346E;eAiFAo12;a2AE8eAi6oEF3u4E;!i4D3s0;b7Bl1;!b157Ac62Ad0g273i6k2Fp0s52z38;!e40i3Co1s0;a1D4e112fBF;!s1BC;l3E7r3106;m137;n18t3;!bA48c636s19F;!a4C8eFBi6s0;a3D2Fe17;e111gBl4DF;o1u14;d0f0l8r0;cFEDk56t5E;j469kBn6Bs189D;!e25Ay0;p83;d888n84;c1Cl1n32EsE;!d0h3Br1s0;!e15iACm2Es0y0;g25ADmB2Ar4A4Bu34;a13e12o43A7uD7;!a4FACe24iCCm62u1F6y0;a65l1n3039r36;!e902i6s0;y182;e30i1797o12;eDn2o9;r602;r4C6;e24f7nF;!n1s3C0E;!n84s0;!e1i484s0;c8r1;o104y34;a1Ce4052i5m1t2D;a1e0i3E15k28;!a2BE6b3B2Ed8CBe19D0i4D5FlBr2216s4BBy63;c0e0;!c0e0;e4B5Di6;cBF6d4382g94k0l12DDs232At24B4;a9u34;cD3l0;!o8;f0p0;!a524e15g1i21o29s0;e15iACl16E;!e24i67w1C3y0;d4B3Fm3680r2C25;!a4Ce17Ei31m2Es0w80y0;n0r2As5;e1nFqC3;a1A;b1Ct1A;e1Bn23D1;!e3DDh4768i6s33C5;!g116i96l1;l2E2;e1h2A3;e1m7D4o4Ey96D;a1191e2E73h308k1A7Fo1r1A0DtBD;c378;g137m178tB;n26FB;p76;p4AsC0x7;!e4i6s0v18;e249l7nFrBs11;!e235i970r77s0;a7Fe85i2A86o36u5;s8D9;hB94;!a51e68i6o1B0;n2As11;o760;c407F;!a123Cb151c4AB2e267Dh1F49iFCBl7n22o3157r4AE8s3A4t1F01uB36z38;a4AAd0e4l2D00n22B0tC5u46B9;e23i472;i5C3;n8ABr24C;pE2;r905u59;!a2750c232e177Fh597i44AAo207Dr2D03sE3Bt928u1336y2C23;i13o25B;a3F96b229Dc62Ad1AEFe427Cf1B0Ai4D56k163Cl3FCFm365Co1039p14Fs4CFEt1u1E43v2D38y45BC;a4335c5065d1199f784g3070k3E3n418Cp2A37vB58;a88e75Dg84i13o2497yB21;a4013e3661h7oC7;k1m82r4364s85Et2EA9;c19rEt1BEB;a185e1k5Dn500Eo29q7D1;r1t10E;l3090nCD5t257B;aCe33g0;a1AFAb75EeEBl35F2mFBAs3928;!l2Cs0uB;c29n7A3;v44;i51o95;a161Ao10r3016;b6B6e107D;!b180d0g632l4357o16B1r1s4CAFw982y0;i18D0;lDE1;a5136;o3C3Bu16D;l985n9B9;!a1eDs0;!d0r1s0t20;i18t0;c50FDkE4Eu72;s32C2t2C7;d80w80;e1i817;lEA;a0c160s2C6;!i1D2p3ACs0;k2C;s920;e420Fs19F;a12c8e2C5s4F10;!b9Fe3764i21CFm1B1oB03s52Cu2E6;m550;e1Do34;!d0e4DFBf1CE7l22r1s2F6Ct1A20w124x0;!e9iBs0;nBv3;n8z3;u2279;c3CDCx1F;!b1BAc4CCEd50F3f12Fk2C8l12Fn1s1C9Ev2C;!dC1Fo9Bs0;!a29D3e2D05i4839l1E4p1517r1582s19Fu1;e8i13oABu14;e1D5Dh46E8i13;e3E56i43rBy0;a14c22C6r158t1;a50C0b89e3DB0f6BBh10Cj143Dl112Fm21E2n183Eo3002r175Bs350Ft1E6Fu1A8w5040z357;a171Ce1i0o1;f4EEAt5A;r4049;a157;!h1060k0l76p28s2445t1A1A;a2C5e6Do2FF1;!d1F3l451En4AF0pD4sD13z44B6;a2D3Ee11CDi4767;i4FAD;!e9s0y0;a245e1oE8u393;a1e15i6l2Cy0;e4i6uD7;!g1EhEs0;l4o2A;c14Cf7n2;e191F;c92f7qC3;a12l2CC;i36sE;!h109i764l7n22o20Es0;e147;iBBt1;e8g0;s47t7z47;i2B1o20E;r2061;!a73e4CFCh9Ct206;!r23F4s0;eAi6t0;d0l1r2Fs0t2F;f6E5t1E;i7Co4D0t70;!i15Er1E;a2020e4FAl2669u14;c9Ed2137k3BD9m28s83tCC3;t1B1F;!a0e5i35ECoF9s0;l1383;i14o6D;!a1C1e205BiBA7s0u4199;d7A1l0t7A1;d1nF;e2595i67y0;g5Bs0;l3902m6FrE;a2B39e1h3AE3i261Cl201Fo4882r3059t39B9u143E;n19Bt47;!aCe4i20Ao29s0;a51i59o1475;b180c41BAiB7Br0;rED5;a3CoE6;i49D7o453u5;n2v197;!a2555e3407g62i1t37E;g1m4652;!e235i21s0;!d0r1s0t17A8;c13Eo0s4CD4u218;e24s11;a52i3F;l11E9s0;b4E1Ep48;!a2F8Ce5;r16s8;a30i3Fo29;a25d1ACm397v136w98;!b1CC9s0;b1Ce24n2s11;!a16D9b486Ec25C6d4A82e15C5h4F1Ai498Fk89l3B1Dn4264p3FF9r1A6Fs0tF14u378Cv1Aw23D9;k0o34;h2B9;n2B03r2C;!a4Dd0l24Fn22r1s3E;!c98e45D9f265i17Al3882n22oDFs0;eAi6m64;rA9F;e9AFu14C7y0;r105;a3CAe1z4D7D;a12eEi20Co3F0;b1c62F;c92l1CE;!e479s0;d70g35;!n0r0;d44rE4s3555;a54r713;tFC;aE6e27B9i33F8l1F3Do2F8Fr292u1202;d282nF;c2835gA42n247Fr40Au4DA2x122;a0g44B4;sEt7;nEp16r36;d292;o3688;c8r14;c47n16;nA78;i2Bo3B25y0;!i1Do12u1F9;i1o9;i9o1;l19DAt417F;a329Al319Co1FD8p2377w2854;i2B47;i30BA;!e3D8i91m395pB1s0y0;c27;e571u4E;!e399h1B06i38s184F;t331;b16e1;a17l381Cr136;f7n2t3;rB8;!e26o1s0;i412u14;!g2CEEh1i4E54s0;!e221i259l7s0;e5n505;gBl0n8r25tBD;e5l19nF;!a4A0Eb20D3cE3e2173i2D04m1819oE8p1B47s0u937y0;p178t3A7F;i164C;!d957n410As0t82v19;!t2B4D;cB2;a9c0e5;n1o2A;gC3n2s35;d35n9AC;h16Fo56;!a1D2b10Fe1B19fBFi2559o121As0tA9y24D3;i2Bl44y0;!a21e4393t15F;!i3D4y0;!i10Al7;a30F5;gDE;!c6As0;cB2g0k141;r656;!eD0i67s0wEAy0;!a1674m0n11AEo4F08s0;r62u3AE8;m5CD;a7Fe166F;!b1F3eCm14EFp3177s0;!c49E3e443Bh15C2p219Cs35ADt1285;d320tA6A;i89B;h4959;!e60Ai38FCr5ED;e1FF7rDB9;h570;i1433y0;a10c35n6C;!b2EDeA4Di383p2AE7w2AE6y0;a449eE;a1DC7;cEmD2;!a12c4D1eAD6h3CEi67l38n336s90Ew1E4y0;e1Do186;!e15i2910o56s0y0;r25t0;!b3675lA5Cs0;a1B5Bd4F90f1AACn3o4B73s26B0t3Dz2C;c0e1Bn337E;c34C9eB3l2B3mBnFs1F;!d8Ae36i1DA7lB7Fs0t7;c11d0;!c5044e4i6s0;n2t29;d1E0;!c507eAA6i15CoAEs0t45A4;e33n1;!f42DCi71s0y158B;b0e0s8;!sC9;!a4739eFFi1ECo3BEAs4A72w236y0;!a45FAb22F0cD8d340Af103Bg41lBC5m2En0p2BF9r4F65s2F24tE0u36wCE;k28n48;b1eA;!b1E8i5Cl22s0u31E0;nD6C;c181t1;a11e4i6;l3C6;!e6C2iB60s96Cy0;e1o28F;o29t7;e24B5;m1n1r48EC;!fEl1886n35E5r40BEs3u31BAw21BF;a403;e15i585;!a1Db3915d0m2FC5o29s8AF;a41Di0o541u5;!a4A89b35D5c3812d1B10e35FEfB5i29F2l1276nB26o21C9p4198r10F6s2473tF1u1E1Bw1136;a3740;a1e1i23D0y0;t1B9;c97lC;!e23i496p78Es0;a51Eo31;!e5f7n3s52z3;c2BCA;d0r49C;d0r47DC;eB9h3C7;!b1BAh124tF8;l4723s29EC;!d0e146l7n22r0s3E;!fC2g4C3Fs0w362C;b7Be1B2fCDnBt1;c845d4181;i0u4E;!b1AB3d0f3F99h3DEm2Ep22Cr1s0;e1Bs526;!e15i6l47s0;e3155i592r1DEy0;!l1Eo645s0;!e21h16C;a20l1;nA9Fu556;i4123;c0k1l3CC4n84s16B;rDE;o21Cr10E0;!e42iBs0y0;n8r1A1t2D5;d2D49;o1FF1;!a40dF9Fg1FCi254Fn2BF6o9Ds0tA9Eu30A;eAi6kB0Dt28;a2A4Bc312d0e2196iE4n8p38D1sE;!a4De2356i45DDs0y0;a4Be4i6l19;l3t1;!i5s0;u149;!a43E7i26ABo2EFAs0u51Fy0;!d1r0s0;d341Be4Eg357lD3o389;s65;!d0r5s0;lD74;a3FECs149;!e4789m307n2CB1tF8;e2FE1o474u4F50;l759;c0e5s27Bz19;!s1AEu5;e40Ci6l2C;a4EAFeFFi4ECBl16Ey0;b1D5e1Bf276n139s102t3B;d6ADrBs9Et9FE;l302n1;!aFC2c2355e4193h18Fi1B75o21EEt0u34;!e5z71;eCiCo9;a315e1i1A48;eFD;a4BeC;f38n18As874;!cA5;!aB78e4ADi4330o2D6Ap14ABt1F0Ey0;!a3C9De4ED2i3553oD7Cu1AF8w459B;!i36Ap8E0s0;l1r0;!e26r7s0t1y0;!l7u12;r4Bw10;!d3Ar263s0;d1F3e3BDg1334i3Ck28;n0u5;e0m16p1E;a4CDCe4FA2i1901o3CAAu27B4;a302o12D9;!e1FBBi50o29s0;!l1D99n0;a25B6;e1g6Au20;!d0fB5r1F5s0;b84;d3De4;a8e85B;aCe5o695;!iB8s0;!k5DtF8;n472Fs2At291;y53D;tE34;!e15i21l22s0;!iEmCEn1r36s0;c5D9d0f7CAl3806n1043s1E39t29AC;k4BEE;aCi3D;!cD4g44k5Ds0t14F;b84t4CDE;!e197Ci67y0z2B;t4462;d58lF0n320Ez3B;n37;aD7e879;e600i6z184;r4E33;a293Dm1;i317Cy0;!e4h16i6s0y16;!a3CeE4iBo72s0;a4Ce1;!e1596i6o46s0u9D;d1Ee4;!b376Di4FCAlB7o3130s9FC;a408Ab4E99c10A4d1A54e1113f11A0g1i39F0k5l2307m4CB3n1489p3BD0r3A56s33D5t1B67v89w2358x1Fy1D4A;eAi24Eo4C6Dr514;!e27F8;!eFFi3430s0y63;!cB2eAi6s0t3E79;e1DFi28A1k5C;cCF4sA5F;e28A;c1354n1C2;c1Ce12;e26i6l2C;!a4Db429c9Fe385g15Ai21lE3m2Er261s4DD8;!e9A8f37i6m2E;l3575;!c2D21f37m2DAr0s8;l1Dt1;l534r77u5;a132r346;!b3BCc1F8Ee28F2g3986i2D8k4El10CCm499Bn130Bp1010s44E2t1001z2C1;n46D;sCE0;i593;e47AoF0;!bD4s0;dF4sEz6A;aEFe321C;t9C3;b1Cn2;c0d0g5Bl1F6n1;t2FAB;i26C6;!aCe43Es0;o3D;d6AeB3n2;n2Dp55t3D;l18o4;!i2Bl2Co1BAs0u0y0;t2Dx324;!b95e153i44Al3s0y0;!a4410g314m30A5o12s0;i13Es2D;a176e1DFi6;!a124Ce1EADi4295l6C1o31CEp318r1DAEs103Ct3223u32B0y4023;aA1Ab4641c1ADBd3809e3714f42F9g22A4h297Ek653l2F10mF59n18E4o3252p1C57r4315s1C53t3FF8v3453x846z17D;c968e1g1i1BEDn2;!d5Be33i21;c87;m2A09t186;c3B6d89e28Al4E61m77n8E1r1021xAE;!l7n22r2DA3s1564;nErEtA6E;b31AAdD7l5Em437;b3AF7;g160C;r36t0;!e0l0r2F;n6A5;!a115Ce2AF3i2FE6y0;!a34e2CCi6s0;r3A33;!a24A6e235Ei449Dm2Eo72s1BCu87DyA89;!r3Bs0t1CE;!gA9s0;!c22F2l2F95m28AFn4487p31Cr1973t3923u49B2;i4AD7o2CE;a6EB;aEA8;e43C9;!e4fCEi6s0t295;aCbD8y1;b49c3BdAAq11Dr41C0s336Ew1;!e4iFAo8Cs0;!c34F4h2623t2DA1;e2CEBh1l3E93u4Ey5E5;y2DB;c4E3Fi6D6l1B4n28r1570;i3Bl29DD;!l258;e379E;!d66As27F6;o9B7;a2FEi4;a1e1g1o46;eDrBEC;c32w16;l14FoEpA5;!h1l463n4843rFABs2FD9;l994;e1D48i3Ft1C;!a41C3e1Bi6F6l728n22r62s0y0;!e15f37i6s0t27y0;l1C7t564;a12e383E;a41De12t7;e5t7;s3A8B;cEi10m19;!e1A42i298l7n22o3FC5s0;!b66Dh1r19Cs0;!l39s0t1;a21B3b2EDc3546e177Bg1Ai79El3036m4326s3tC8F;e12i21;e23i6t309D;u335;!aB72e565iDD2t0;!s1A;!fEAhEAi86;!a7Fb5E8e15f151i165El154Bm2A0o1C5Ap38Dr3713s1894w98y0;a10n213;a1De23i2F5;!e15i4ABBs0;h83F;c222p3521r1A5B;b634d44g2Cs497;!b124c94Ad215De12BFh924i86j22Cl4DBAm2Er2Cs20F6w1752;!i13s0u3;a46Af9F8i23FEo4BB8;!e15Di6m2EsEC;eDr0sEt1;c121d24Cn2238;!d25A0e17s0;g94k47t0v19;c1n0;c0n1;i34r47s37C;!a390Bd0i0o29r1s0u28CwA9A;l1m1t96E;e40EEi6;h2B7ElB;d19eEs5t1;!i6p2D3Cs2E9;!e17Ei20Al5B9s0;e123i365;c11dB5g1732n1D65r1AA4s340Ct2F93u1v2B;p3641t186;n3A1r1t38;!e4i6s0t1;!a387e4AC3i6l44s0y0;e399l44;a57o57;d48e3B63iE27l16Cy7E3;!e4i426l7n22s0y0;b1F37g3Bm33D3rB;i12w32;e1n294;!e21CEi27s0y0;!bF8d0l22r1s0w706;k8B;c3112g476Dn28p87s9F5t2BE1v25F6;c83;a1917o0u4E;l40A5;a4De4i6;r22;e4i13E8y63;eA50;e5t152;a1eD;l1nE;!a1A6Ae682i3913o19As0y2A49;c1Cd1g35nBr61;n3Ar1;a4Dc9Em28;n1r3A;n96Fr45;!a3Br821s0;!e1w136;!aCe2FAFk5Ds315Bt37AA;!d16e8EDn1Es0;e1Bn1;eAi6l4A7Bt47E3;nFs1F;nFs115;l1p536u3528;c13Ak42E4r141t48;o11A;!e6C;i1232;l46D;a0e3Au14;!a83e23i12A3l4490o1s0uB8y0;!e4B8i13s0;!o0s8C9;i45o49;a1904e2B6Ci31F8o156Et4362y41A;e42iB;c326E;pEBr9;a1i2B04;d267;c2Ag0k3lC;e23i480;r1u1A8;o839;g234;a7FFo44E5;eAi173Ay0;!d0r1CB6s0;a27D7c637dD06e15ACf4D63g169Cj5Al1402n3B03o23BEp32A6r2B3Dt5119u4BA9v4756w3802yF5;a1lB;d0nFr39;!e3D1Ah3760i48DBoD8r50A0s0;!m26F9s0;o29u661;t971;t0v3;!c11m133n0;e0iA5A;!n2C3;n2C3;a284;gA5;!e486i43y0;n1r1E1;o7E7;y1E;a57e42;c66AnA98;i110u5;e3E11iD9;!d0f37n8o10r7s0;i57By0;o21ED;n62D;b5079d4CBEe146g2447i3822m3393n31FBr43AEs25F9;a271;!d0r0s8;b5Cc469g42EDi20Cl46F0n4673p43A5s1556t1145x0;i3C8F;a3458d1E52o162As0;cCEe24;k0n233F;eB84;oFu31;aDeDr7s0;e1394;a475Cb4968c31F6d2CFBe491Ff2EE5g33FFh5i40D5j1AF6kD1Cl4562m2C6Dn3A90o2A41pC0Eq2AFFr4CD2s339Et4CA8u4CF7v11A7w1D02x4E9Cy420B;h47FEk896;m0r17F;b1Cg19;eEg1Eo8u9;!o104;r129;!c3A41d4742e48CCg4ACBi67k2DE1n435Bo1s2091t4467y0zB;!cAEAl7EpFEs0t4039;!l891s0;d479Ee1i894;a3B0iAD;!a3F22d12Fi563l227s0t1;a3844e41E6i6o44F7p20F8u1FF6y0;m1An1A;n111;eAi24A8o1452rF1;s14t1;o74y20E;e144iBF3o12r22u2B32;a3670eAi23D7;!n2s1E7;!s52t3A2;!oB1s0;c11m16;!e4l7n1s0;i17EFo1;a5i2Bo40y0;!r29;a6ED;i8Do13E0;!n3o29;!e15h109i67s0y0;e99o10;c11EDk19C2;!l38s0;!s11;s1E7;!s1E7;!e5ADl48s0;o4C8B;!e4i189l22s0y0;i44EC;a16A9l2587n3149p26F5r31;f4073;!eDr7s0;t12A;aD7h1;eDl7n2v3;l3C3;!k16r1Es0;e27E9;n296D;!b151e4iCCs0y0;a4w0;f108g19rEt19;t265D;a2D3Di3201o1D;e3A1Ei9FB;e12BB;c45A8e44CCi4517lC90m4Cn32EBs372Ct3332u2E7Cv18;c2D9;i2D3F;a20u5;oA6rAA;e486i43A;!a5C3b38Be12i17Al7n22;d19gBr25tA1;i19AF;e10n4402r40F6sExE;u397;a3397e10Co1C32uA60y32DC;!o46s0y0;n3E86s44A8u17E3;e491;!a1De4B66i3243o11Es0u4E;c2CnE;s2350;!e688i6s0v5A;m3Bz265A;!b395d0r13Cs0t1y0;v295;pCE;a411Db50F0gFi49m24C4n52Ao4FC8p1r272BsE7At33E4u1FFv44w1978x259Bz5F8;i8Fr158;!c5F4t38;l1F4A;!a12d9Fo12s0;s20EF;!b2F21e4056f377i4543m132Fs0y0;e23f28DBi6t1;r141;h4497;!a913e4i67lBs0y0;iCl4o2Ar3;h46Eo81;!a3A7e24i6;a4FA8;u697;o53u1EBD;aBEi57;d1EA;!a225iB8s0;r2032;!a14o14;!a4Dd0l7Er1s0;i9D3;!e85i67l44s0y0;sFA9;!e1A2Di2BEy0;b1Cr16;a1F74b510c13FBd3D8De4CA5i6k30B7l2B9Am284Dn1A4Eo3012s3200u450D;cE48p3117x1F;a1D29;r62E;!b1D5e1Bl7n22o1;n2479t2D;!e21Ah0i3Cl7s0;n2o3B9r2550s39E;c58l360m1t39F7;a5050b49e4573i2403m818o3A34u62By0;!e2B0D;e384i2F6Ay0;a7Ct1;i4C63;o24D1;a20i0o29u5;l1CE;!e4i6l7Es0;!pA9s0tBD;!l7n22o29r0s8;b35Al0r11DB;a266e4i4B50o2364y0;!e146i6l2FB3s0;c13En379Ft3A0;d0r1s5Ew0;a4D95r377;h70C;o3CFA;!c4300e1h0k4F4B;!h9Co6FtF1;d5C5k3DA8;!a168Fe306Fi6o93s0;!g364Ds0;!a4Be221i259l7s0t0y0;a1i18FFy369;dBi4lA7n1s23B2;eDDC;i34o7F7r514uC8;a1D3;i126n0t2C;a25C1o95uAAA;!a3D39e910g40B2h1A5i2331l3FDo4E2Fr2ACAs0u2F86;e3D01i6;!eA74i6;!s265;l3o2F;!e249i86l7n22s2E9;!b43Dt2505v9C5;a89Bs0;i9l3;!eC1fE2i6l7Es0;!a33D6b2EFCc3DC6d2030e3077fE4Dg1735i290Fk20D7lF3m4DA8n2592o22BAq11Dr1038s2265t2438w2F1y2120;a2C29g6C4i2570o3BBsB82y63;a4B82e1F3Fi4ACC;!c50B6r28E9s17B3t99Ex117;e6Do6Dy0;u2206;!dD48e0l7t486C;!a283Bl76s0;t1E7;a21eA4;d1Ae1C6i1C6oEF6uC26;d0e10n16r2F;!i527l7;eAi4DB7o2CA5s18;c248i10;l1F67;eFFi6F0y0;a1eAi6;!e1i1C5o10s0;!c58s0t122;!a2AEAe4EAi2316l92DoE8s0y0;lBB8r79B;!a3CFBd48i467El3C37o1030s0t1D7C;n17EAr3DAs368Et2E9;!m70t107;fF2r37Fs0t2D;!d8Ae21FFl7s0;a4De488Ai189y0;a0c0n0;!a145c13Ei36F5l8m12A4o15CFp2Cr905s3245u2605v38wE7;a587e439Fi41C6o3445u4E;!e551iACy0;r732;!a828eEi56s0;a88e4874iFA2;r28D1;a3C4Ee4C5Ai45CEo423u380B;!d0f37r1s0v4C;!a131Ed2B7Be4F25i13F6lED1m15Fn22o10w4C9F;o12p2055;e68n3;r42DB;l0t19;i18m1t1y0;t2BC;i4E78y0;i1Du34;!d208Ee4i6s0;m105;!e23i6m4BF2s293Bt15CDu4D;i69C;o17;e1CD4;!a16e24i6o16s0u718w16;e68iBAy0;d1n83;!e15i6j258lF4nA1pA5s0u57;!cDFd44DBf16B6g2Ci45E5l629p22Cr1As1DC1w44E;!a2D06dA08e47B9i29Cs0t48F2;!y18;l2CB4;!e10Di547pA5s0y0;c0d3n52t3;c0d3n3t3;g11n1;i4AC5;f1A;a0e4u14;h5BEo10;eAiACy0;i4m1;!a4De1592iBAl10Fr3D64y0;a162eBE9i20o44D9;a7e45;a12e12;!e104o3642;o7BB;!d0n23BDr1s0;b1Cl1652nEt533;e4A7l3B8Fr3xAE;c3e5f7;y39;n3C6Er324;d1AD;cD3s2B9;!e21AiBl7o0;!e1B29i4305s0y0;!b2068c117Cd452e376Eg2705l3079n4CCBp41EAr4791s1934t3C6Dx122;dBF1l2D2BrA61v467D;!r1Es0v19;i2F78;m70n2D;d1l4BCs1Ft2B2;e30g3Bt38C;!a30e23i6u49;e10n4BExE;r2AF2u12E;!a153Ce128Di21s0;e1h1Ai20k11FoAA3tBC8;nFtB;!g0k5B3nA9s64Ft48B;a9d0r1;i904;!d0r58s0y0;e0h0m0t0;!n1F7s0;t2170;o1844;v3C88;r81D;!e328Eh4D4k7CBo84s0u4E;nFu32;!o6FuCE;eDk3n2;aBEi74C;e1h7D8;a4C3De9;a727g62n83t1v106;c1d208r3EE1;!a0e26s0;!a20e15i3793o453s0;c3e8DB;!e1Bi1CAy0;!eB3i27y0;!e251EiB;!e23f151i4540s0tF64y0;!d0o29r4Cs0t1;e24B1;c4600;e42s0;n52t7D;e3F3i35D3;t3B5;eF8F;a88h19D1i46F3k370Bl1300o2EF4r39E5u4E18;tBF4;e421;d1eE;a13A2b23D2c273Dd4D28e43B8f4C1Ag365Fk1F64l3DBEm19C0n2EBDp2DF8r2805s24FBt3888z16D4;!d0n25Br1s0t4419;a12iEy20;!a75i18s0u14;!a72;a18Eg1;s2D9;n6F3;!u28D;!k27s0;h3At82;aA2i4F0y63;aCm1rB;l62oE;i33A2y0;!b82e4i6s0y0;a4Be3506o6F4u385F;!a1C7Ae2CF1i33BoAD8s0uB6y1A3;a16D3e2A5D;!e1DzAE;n28B;p27v8E8;l1r1E36;l4B;a4E87c53Ce30i3258k1C71o28FCqD41u628;m20BEt502;dB93t3C7B;i13o36;l2AAE;a9e99u10;i2D8l12D;b28n62;!pA5s0t458;n3F6E;o1F40;e4C2;!f183;e16DF;h82B;b3s8;i16F8o1;n1A9;a4Ce416Ai250Ak12Ao9Bs419t10By0;a3C4D;!i2Bt1E1y0;c7s19t121C;i9D0oC;!e4i6o3Bs0;l2980n0r20D9;i0s1F;kF58p1467r12F;c18eA3l7;a49CDeD1r4668u126;t2858;lE7n158p10BCsEt61u168;e1o104;r356;!e32CAs0;d38e1gB0Dt37E;a2DA;h76;bAEBl83m2Cp87r2E5D;!h24Di230t1;oBE;e18i0u5;o0s0;!e2BA3i2925l44o3C04s0y0;!p4E;!b2009l192r494E;n485;!b1Cg5FDn4E9t8A7;xF8;e385iBAy0;!m2Et380;a65eEi31;a40D6e1EA8i22D1o361Bu6y4454;!eDi91y0;i40DAo29y5AF;a51e1nFo10;y3BF;!e1Bt3A75;n2F5C;c2Am3;d0e384g0i19EFk48y0;!e0r3As0;d3FEiE7m15F4p2D08t2Dz1531;bB38d17Fg294Bl3AADn2CE8r4603s2F9Dt2FA3;iD7;v2D;a7e10;h0l33D8r2E89s1943;!l7n22s0;i77u5;d4793;l34Ar83;c19m252;!a2AA0eFBh28iBD0l38o2329s0t18BCu1;!m2Eo54s0;g0k1;e17u34;p39;!e68i21k9F;r377F;c13A4gBlF5sE5B;a101eAi311k28u4E;!e906l7n22;e1i9;!a9e3BB0i17Al7n22s0t11;p1r0;!a4613e23h0i42C1s0tC50y0;j18n53;o10vB;f20E6;d2FC0f1g4A9Dn28F1rC12w200;o6Fu4DAE;i4669o46;!e4f5F5i67m5Bo3A05s23Ft16Cy0;c1f7nBo1D;k2199;a2DFl19oEr95y20;i8Do72;a35A6b28e2A1Di2E68o39ADr4983u263E;e4s0;!e85s0;!m2Et9F;!a7FeAh0i6o1F0s2AF6t0;aE9i110;e1879i2By0;d2Ci3CC6mAEBn10D3r2B5u45F7v103;a4137i1453l1B12o3F87r212;d2AC;c7Ds3v3;b1BDe5oFDE;!aC21d3699e2379i21l18Fr831;!e4i6s0t58;a4Ai34;!r6C5s0;!e4l119s0;!d3F8e4s0;!aCe26iCBs0y0;z2BC;a1Di1;!a12s0;c55d58i11Am3C6n118p3DCr10C5tBx4823;gFE3;a0e342;a101e5;a1CFE;i2983;o3A16;a9d330n0r32E5;k22C1;!cB2h2Cs0t4DB;gBl0;a7Di31;g1s1Ft409z1F;g184h29A4;!n4D4C;eB3f7l7;e1Bf7l7;k14A7l1A;x116;p278;s512t2F29v19;!e24i6zAE;i5D5t107;c0s2Cu14z44;eA6r3;!l9D2s0;f1F5;a541;aB30i4F0u45y63;!a6AAeCE6i6o686s0;i43A9;a3F7E;a49F9i4DADo35;t14F;a3A81e40CiCCo72y0;o264uE;!i54o6F;aDe1i10AoD;!i33BlD3;e20C;!e20C;s2BB2;d239Eg2537s3353t320;eEs11;a583;n4C6;n25FC;o10t1;e1i15E;h0i50D1o105;!e4h1i6s0;g38Cl374C;p1r1;eAi6t39;!eDBs0;!oF41s0;aCn3266;o369;a4329;s4F;m1C0t1;hDD1p4D24;o15F1r6A8;!a9AAe3C8Bi1DCDl4ACEo34s0t1;!a2D4Be5014h1913i18AFo252Er1CC8tD4;u2C4E;!g7C7s0;cEDs11;!d0f1F1i6l135Ds0;f4A5t2F;!e4As0;!a38Fe1B96i21r2D0B;n1E2;t129;m3545s4A07t3993;e25C4o46r371;!a87Ee15i6l1D8Fs0t60;p7r1s5;l1Dm3BFAn15FEr17ADu50;l257;c11r1D;!dA87n75FrB6As0;!a4BBBc47FDd2561e427Af2460g49EAh0i1906k4B68l22n1224o4F81s1D64t11Fu2765;!a1C9Ch3E3Ci2293s0y16C6;e27F5;e5s3D1z3;!e4hEAi13D3l22n22s419F;d95;e12i903;!c0n3u14;i3Co16A;!a0d137iFD1o9s0u14z1A;!a88g7Ah3479i365s0;aEe15i1EB8;z281A;a9e79o9;n3137;!a4De15iBAl24Fs0y0;!e60Ci3Cs0;o3D7;c2Bl1Cn2x0;a1Dh3Du3D;k2111;!i27nD8s0t78y0;r1A9B;!e3828i2BC8u34;e5i5t2D;c22Bl0;!a4De1F69i21l4B51s725uFE4;!e15i147Eo130s0;e73i45o49r87;b357Ac1ECAd2399e1g72Ei1569k2Cl3469m5096n4929p2818s1FAtDD3v103Ew1y48;b3F76c3EC4d319Ef1g1A13k4BE4l1C74mD20n3881r2AA2s227Bt3BCDx4DF7;!a11dA9s0;n2230;r234;t152u5;i42D3;fB0nFv3;!e24f11DCm401Ds0;b1Cg38;e8C8i3530;l1tB23;r14y0;a38Ae49D2i443o1AD1;!d0l2Fn285sC2B;!e23i6p35C1s591;h398C;rA2D;e561i6;d0r1t46AA;!d48fB5i3Cs0t1;!a26FFe4DB6h1EE1i42EBo4C46r2AD2s0t1B27w3A57;i195o74;l3o10p1Ev3;!d1l1nB;e16Ai4E74;i9t2B;a45Ee1o36;i35o3DD3;e50i50;l35n35;h459o4F4;!aA2e14Ei67l44s0y0;g19t3;!a39CDd336eFE8h20E3i1FD7l1FEEo28D9r33BCs0u5y0;g1k1t4A;t332E;c178l211Fo12r126x1AB;p14C;u46F;!r7Ds0;d417i192m0s1B9x214y0z3B;e34B;e1o243ErAA;lD6;l4CAB;!e4iBAl233s0y0;a38A7b4A06c3185d4B81f242Ag10FCh4254k21ADl24EEm1D26n43D2o1808p1BECr3876s4B34t40D2v40ABw5Ex1827z4053;i13l9Dn4C6t4032;c4Ct3;e1h37B3zAE;b43C1c340Fd30D6f1CFFg4BD7h3F71iD8EjB33m3D2Dn23DBp4B3Es3142t155u4214v512Cw6E0y739;m324sC0t2D;a2ADB;r373;l1C9BtB82;l164Bm5Bs3B4B;l2088z200;!a176b87d379e12i17As2E3w98;n367D;l2E2BnDE;e4iAC;!i7Cr1A9s0tB;!c6FEe910h19Di69t27FF;a1c0s2C6;!n1A40s0;c32s1F;c0o10;!a4FAm2F52s0;d28k28;!t40;e5u14;i31yC6;!e15iA77s0y0;!n22t425;g9l39;!e15iCBo1sECy0;!e36i2FB9l7s0;a3A36u6D6;!s300D;l1E59;e653;!e15iDDl7o12s0;h492F;b130c19Dd2E8CmA90o250t403D;!a38EAl49A3o29s0t9F;k1Et1E;t796;e854o46;n3B5E;!d0l1A63r1C29s140y0;e1lF11;a14B8b20C0c40C5d1809e182Df495Fg176Eh4CEEk109Fl4228m1EDFn2DEBo1D0Cp4BBFr370Ds16ADt1B44u3008v35AAw8Bx1CBz4213;e299p490At1;eEi0;!n16r0;a14A9e17;k27n0sE;yB22;e17i32y32;d0s5Et70;cF1Ar1DC6u5;!a3B9eA4h2CE2i4234s0;a4d4BAi15B8k1CCn3B48o97p31Cr31E6t2ABC;!a3639e33E8hA0Ai14ACn22oDEBs15A8u226Cy3F2B;!aCe1i13s0;a11Co4C32u2DA;e0i123u164;!b3381d12E0h183i6l3463m2En22r1s1A8Bt2Fw9A3z3E3;e126Ai132o372F;eAi6n0rE0;!c58r42B5s0t4141;a4B48;a2600e47EoD57;b40F3d1f47EFg1D8Bi31Dl1E03m462Fn2246p38D8r234Et4987u3CC5vDEAw174Dz56;f38l87;!a4Dc17Be10Di21l7n22s0w172;!s52t0;s0t3;a1De26CiCA7o4229;!aDBe4i44As0y0;a3FD4;!i2Bo29s0y0;u5A6;c23D5;a12o4061s3u126;a10o41Eu10;l4180;!a7Fp165r1s0;a1A3e4i6;e30n2;lEn8p1ACt19;!a2BB6e4935fEBiC29l1oBF7p4D3Fs0t4072u4748v44;!e59;h308D;a22E0d0;aA2i36;e24l1Cn1;!e3698iBAt1y0;!eDs8;a239Dp1u1;b7Bn92Ct19;!e4i2AB7s0y34D0;r67C;c50Cn115sADFz19;h280;c1BAFi1442n2A65r1D34v1Ay615;oDAA;a8C2i104Do10u493y0;!d4F9h10Fs0;e6Cr732;eCA;!c18Cg3s0;t1B45;o2A12;o231;c244n1r285t2C;aD5e12i3Do69;a20E;!d24A5i6r1s0;g3Dl0n4y0;!b540e2C89g1E8Eh317i2Bl4491m2Er17Ds0y4E65;m9EF;sDA;e2CE;a26De1n61;a135h98C;eAi6l16;!e15i6o1A7s0y0;e0i27y0;m18r1CCt0;o3019;i2C4Bl1E;!i27s0y0;!c47FeAh425Di6o9A9pB00sBt38uB6;a37BCe21AAo6B2u64;h4731;h28E;e33i5;e33i1;n4340;a1C99e2D66i293Al3C4o21B1u470D;c268Ef27EEk3FA4l2F59p40BBtD7B;!aA12;a32d0;r1BC4;h8n1E;c5Cm122;!a0l82;a4De23i1C5;j0;aB9Ee9;a1C95e225Bi2017o1C4Ey0;d0n1r1t16;!a390b4E2eAi3395lBo175Es0u4AD8;!n0r90s0;l3C7D;h4352;a1DiADo12u49;i1C44y63;!e4i67s0w1C3y0;e194i13DC;o1C9;rE4;c11f1t61;c161e5o9s14Bz3;n2t5A;i36o54;a0iB;o10sE02;a1445l4;a2D65i4F9Ao12CF;n11D;!e1s1;d0e1y1;!a258Bc1097d42A0e20A9i67o1CECs0t3A7Ay75;c2Bn118x0;e1i365A;e3B4l38BFnDEo27CE;dBv9F;g283n4BACt3F1;!g3ACs0;!b38Bd7Ee29C7i67l36Fm2Es2CBDy0;!e7E6s0;a27B6e444Ai4D2Do490Du1EF5;!a3E66e4iB8o676s0u30A;i12t1;cE0e68t16;e4iAD;a54o6B2;e4l7y0;!i2Bo29r7s0y0;a0e9;a9e0;p4F1;r84s3E49;!b10Fd0fBFl708r4DAFs366y1;a1346iF47o34B5r4B1;!e153i43m5Fs0y0;b1E4d114m4B8En1511sB2t4A40;a578e1;k16m1En0t18C;a9i0u5;a162i3839l1A;!g4Al327s2Ct1x0;a3Ci97;f608;a6Ee6E;!b1A62e12s19Fw4822;nBAC;e15C;i4146o13DE;a1e1C5Ei1EEDoF6;!iEo0;d0r1s65C;!b311Af216Ch109l2F81mA9s0;d2Cn478A;e1Bn2o10;g4B2;!g19;i1198;!uD;!a32d1f1k373l3CCBm37DAn654s15BDz5B;!e68i1219pE3y0;i5o1B0;b2C00d3BA3e32g2ABk2Co377Ar194Bt2743u2FD8w231A;c41d45E3e1DFf1F1g18i381l3751t28y0;d3Ar1t39;!d0l7r41;!a2D6t27;e4i21l1B6;a4D23e3891;c16FEg94n4A85;e557i6;!c819f4E82n4FB5rAADs5052z100E;l3Ar7t10E;h2138o3656r20BFy369;b2C1;!c4636d1C77e1A72h123AlE1Eo2A6r3C9s4D71w35A9;a1270e5i3580o1216;s2816;a87E;n500;!e5i2E2A;k2C8F;eEi2By0;i18A0y0;c25AEh3A67iB01k4496lABBo2417tA7Cu393B;a1De23i2A4;dB68g59An4E6t28;a6Fe1754i65;o8BC;d53E;f2AC4o49t1u0;a1BB0eE61i42C8o215;d0r16y16;!a3854e2AB6h46B2i90Co1r244Fs0;!d0e9r1s0;!c248l0t602;a2F25e79Ah4F29k76r2B54;b46c1Eg1144m297;n0t11;d0r56t88;lA7mA1p967;a1iC46o29E7;l1CC;nF3t345;!aEd0l1m2Er23DEs2D25t2EA;n2o9vB;e26EiFA;eAl1;!a8Fe68i21;f2FBi6EAk44r4344s1Ft4B54;!a1De1DFf265i6s0tEA5z1F;!f183p5Dr1s0;o108;!t5CA;c2Cd308Ei4s9Et61w2B6y17F;m20Bs1F;a2C55e720h0o254B;e862;hAEtB;!e4l3s0y0;c27F4e7DEfF2gE3n31D5v2961x0;!e113p1Es0;t6A5;o10s0;a305Fc4F37h1Fl3DAFm10E5o18A2s2F54t22A9;i0o36u2B70;a75p0u34;i13E7y0;d0nEr39;k28t1079;!e5u57;e15Bi8;s102t7;!e4s0t3;!a10e431Bl219p35C5s0u4A6;!e15f37i6l7s0;!a3030b151c3CBAd2CCAe228Af1840g4444h75Ai205Fk21D3n1200oC5Cp4B0s0t3CA4xCEy0;i6DB;e8Fi27Au411A;h20B;!l24As0;!e15i574s0y0;v9F0;e241;wFC;!s0w1407;!eA31s0;a8t1y1;!i8Fm2En2Cr158s43B4t1C8;e5C9i9B6;i74Ar5A;d1212;e1Bn2t3;e201i6y0;!e4l1B99o1s0;e4i199y0;!s0t4EC5;!l177n22r1s1AF;e1o29y0;t815;!d8Ag14Ci241n1r0s0t2D;a3586l1C7s1Fu14;e194i25B2;l360r37F3xAE;!b2A0Ee90Bi29B2l26F0o50CCs0;!d0r10s0;g0t11;o29s1F;e146i21;!i17BFn0o46s0;a20i0u5;a1i71y3FA5;r7s5;m14F5s21EtBD5;d0l1r1t16;!lF26o231s0;!a38Fe12i21s0y0;!a4Ae4i6l3126o9s0;a49DCe4D7Ci7Co13B;!n25s0;a137Ce366Ai2676u14y63;!e8DCi54;!a0e4iFAo12s0;aA2o264Cr89;d0lBn1;g46n18;b7Bn2;n4BBD;n80F;!a101h190i56oFBu34;e712i43y0;!eC1i86l7s0;n8t2F8;e148i43y0;a30e380oC6;!s0u98;a11Ce1792i50Du6EB;e583i313Eo40A0y0;e68;e23;!e4t11;a8Fe462Bi429BlF27o44E0s0y10AC;!p3Bs0;!a4De2448i305Bl43A0m64o12sEC;!a20e24i43y0;!e4f37i27nD8s0y0;!a1B00cF6d8DDeEi174k406Dl1BABo8Ds0u491;!e68f37i67r131y0;e4278o2C26;e12r19;!e17i288l1Er7s0;e49A;e1g3510i344Bk4C5En2354s24A2t58;i3742;a156Di44EDu5;k19s3A5;s21F;a30e3121l145t24Aw28;a15C6b2D14c1490dBf3871g3830i10E3l112AmEA9n1F56p1106q11Dr2D7Ds3ECAt15B6x1B93y641;s3Dt3D;e15Bi1CB0;h3405;a101c0e1i0p1040s163t4AB3u4EzFC;t4677;!eAi6s0t40D0;r2Fy1;e4v5B;a3D7e9;k43E9;l351F;nCDr2D;!a25B8e3D9Di11D9m182n4F61o157Dy1034;a3599o2B63;g82D;i4BD8;e35Fi2851o2363p265uCE2;nB3A;!a61o108s0v1D6;d1AC;a57i58Du6;m60;g4Al26FEt48;!l6FCs0;b1AdD86f5030g2ABl3C7Fm1025nE8EpDF1r1659s2Ct43BBz168B;c11tE5;!d25B9lD02n47AFo1F0s0u22Dv46;!oEE4;sE0;n25r32D;!a7Fe4AAEi3411l10Fs23Fy98;!a195e15i21l202s0;!a2E2eB8Bi33Do32Cs0;!e4iBAs0y0;a12DAi3043m412C;u6EB;u2A46;cC8l4r14;d89l1Am1235n84r3;i3ADo56t38;p16F;o14B;!i7C;i2B1o695;!c636h4772l4B88n3215o19E0p655s1A61t35CC;a4Ai1DE1n212;f259C;n350;!a61Fe4i43l6Bo10s0;o12r149u12w127;d1h1;a143lFEo22Dr209;c2B1Co128s2DB2t10B;e19F6i6;h46E3;z4408;!i2B79s0;!a3A48e3321k4F9Bn396;l2075n4C47;l3D0;e4i109Ay0;e19oA6Fu439E;!e42o40s0w151;a104yC4;!a0e12o46;!e5i21n3;lA7sC0t2D;c2Ar1;e127i3269o95Bu5;c35BB;a1CDbFCe1i3C23;c0dBn3s24B2z2C;a24F7c4981e65n2oCs3B3E;!a1653i1A53o17E4rE76;a7D0i310CoD93;a10bCDCcDC1eEE6g3AA7i4o11E1p138As341At42F2u431Dv1B14w332Dy4;a16EEc271Ee1E9f155g1i2F64m1821n4A4p243r2B4Bu237v1F9Fw28;!e2D15h109l4200n22;!eBi224l317DsA07y0;!a4Bd8AhEAi3Cl219s140;!e1E4AiCBs0y0;!l76s0;!aCe0s0;r25v3y1;e48F5;b1495c403Bd1195f3CD0g2ABk2C9Cm4FFAn23C2p1C0Fr4722s3t40CB;e0i13o46;a159c247e4n2D47r68DxAE;e9l2Cu45;e9F2;!c4476e0tB7;e53;!a2614c1CnBo40F5s102;aEe3D3oE;d3BC7f1l32BEn111t23B0;!aCe4i13s0y0;g48k2EC;e1Di49DDy0;!a10b22Ce9g2A60hEAn130sC20t9FDwCF0;s3473z47;e1425i86y0;d1u2327;!c771e23g4B7FiBAn240s0y5B3;a1DCAe4B05o16D;!dA9lF6o3Bp8Bs0;s19t7z19;f37;a174i3C;e3AAu1D;d38g44k5t4B77;!a1m56t3;!b151e3607fB5i2510m2Es0y0;c65E;k47sE;eDf7n2t3;e12f27;u2F6;g15EAn503B;cD59lEm23E1r7;a9e8DA;k4F;d2Cm82Ep5As497v28B;t1v47;!e23i21o1Cs0;n116;!h1r58s0;e478i2A4;f1l48Ao7BEv513A;eDu5;a2C0;i849u264;hF81;k187r2A;e4D45i49C4;r2D93;f7C7oB09t28;a2Ad0e4;a4C7De1i44F8mBo886u12;i226B;e1i57B;!i69k9Cl9Cm2E;aE23c24D2e1B50g4BB5j3222k120l2FA2o2789r2B59t1FCBu164x1AA7;a3CmA1p16;!e2E03i6z2D4F;a4085i1FE;l3B6;rE2;!n487;nD2;!e10l16E;a10oB8;!c41s0;e47B3i3665y0;i13l0;a48BCb1D62cC93d2906e17DBg26B8h353Ci2DC3k4720l1998n3B36oD16s4ED5t19FAu3897vDAx21B4y3B50;a1E9C;iC9;e1t92;b7Bm214Bs9BDt3779;b19oE;!a29F9e2850gDEiB;!b1Cc58i9l1496s0w1y1A;r16F1;c7FE;n4A90r2640;!a4985b1A16e1004f691i274Dl76o122Cp30F2sE5Cu4A23;d1k0;c2Be1n1x0;r3F;lE65;!n0s0t2D;n47B4r54C;e14Ei38B1y0;b1BDc24C;e4DB3l2AD5o16D;dDEg107;f361;i9k1E;e4B16i6;kA4n1F5o2As5;t291;i27o42uCF;g3BADsBD;e1Bl7n2s36;!e146l34Ar3B01;tD7;!d1EF6e1f37i42C2l7n22s156y0;u6EC;c32r47;!i1F22s0;aAB4o27DB;n54E;t42F0;!i27l6Bs0y0;e310r23BuE;eAi6t5D6;c0d3A01fF2lD3t3;b2B3Be1FEh124mCEEp1D72;!e4iACl4952m5Fo40Es0w321;!a4Dd0l6A8r1s0;e5fF2n2zA4;!c3021h1Fk3FC3o405Eq30Ds21B5t4571u10;!g15As0t445;!e12y0;e2B05i43y0;!e15i301Fl7m28C8o1F53r1B1s0w98;!iB4n19DEr1Es0;i2Bl47y0;n3s5Et2D;a4A1Ed37E3i35ABk1C3El4D2C;mB9n3523o45uBE;e2FF9;!a2C79cF05e4368fC2hE03i3E36l32CDm2Eo43C8s38D4t22E4;a0o10;!a0o10;c41t3;lE7r303;c1i5Cp3280v38;r37CF;a2B2Ee2C4F;c2Ak3nA29s11t3;a23De1i1A3Ao29y0;d1En7;eDA1i33CAl2Co105Ay63;i948;a20i71y0;a11Ce10Co3C6uD4;!e15i107Fs0y0;!b398e2A5Ei21l2433s0y0;g1Ak482D;!a0c1e1s0;!d0n4443s0;e1Bn5ACt3;a1i1793l3;l48A;!b1D7fBFgBs0t3D66;!b4D98d4F6Dm4847p246s10BE;oEy0;!e41AEg4C2k5Dl5C2o10t3442y0;e15i496;a1CDe21E0i5E9o1;t1B11;a20oE;!a101e23i5016;h1E0z1AF5;e13FFoA5;e1147i6o4947;a53D;c32g1;iC4;!lA99;a4Bd1AAi58Bs0t9EA;d1f14CCl58v2324;k35;a2EFs180F;e340B;r15A0sB85;!c1252dF07e1C3CfB2BgD9Ch3904i3F55k4E4Dl381Dm1E4n3DD0r26E3s1B84t16DAv1CEDy1D7E;e3Fq4D9D;r2B83;rF8;n50F;t446F;!e1f7i96s0;!m1s0w236;a34E;h28;aBEi1F8Fo31AyA89;a42i36;!e1Bl361s0t7;o2FF6u14;!e4FDBh37B1i3A99o1F0t3973y0;!g19n34D6r1s0;!d125Fg177;!d0e9f37r1s0;aA2iB8l6A1;i1B38y0;a158Dc3692e20E0h4B9FiBEFn1At3AAFuD5Fw14Fy2AF5;d208k1l3508n4B39s0t38B8;!b2A88e509f265i2476m2Ev260y0;o10u2D9;c6D0k8B;!a4Dd0l177n5C0r1s0w33AA;!d0l679o29r1s0;!i54p42B;!e0n3r7s0t3;!e1l2Co6C0y0;!i31o10;p2A58;!e1D71i21l21Fn24Do231;g17D3;c0e5s14Bz3;!k0s0;a4AB;k3115;a1Dr3415;!m2E5s0;b44ADc826d4626e22E9m43D0n4628p29ADs122Dt9B5;a51o51;g5B6;bA7Bl877o33ACp31Cr2BACt5F3u4910zA8C;!e3C7Eo2335s0u147;l15A2sB;l1t107;c0eB3l7;!l4A0As0;!e6DAi285El2Cs0;a11e1F9A;h37B5;f2Dn3x3A;i3C36lC97t28;a245e4;!a293k3s0;e19C5;i27C9;h2B6B;!e15A9i36AAl219s0y0;o4C26;!b540k1CD0r1s3753;a4726b208e1AFCf0g1C6Fi2C5Ck1m105Fn2F2o4FFFr204Ds22EDu1F2Ev5By12D0;e0o29;m18ECt2D;g1zFD;d4Bs0;!e15i43l19s0y0;i10Ao46;b43E5p348D;r16B9;a720;bA7Bc1211d1EB0e1g2278h0i3630m4700n2A1Er302Ds1968t4294uB1Cw44Ey1z306C;!a1De4iDDs0u49;a1C9e1;!d3253g2F2n21Es0t28;d0n60r1;!a79Fe9Fi25o3D93s0y52;hA4o10;cB2d2DD7f12Fm2C8n1629t2F04v2C;a480Fe3457i48B4l9FAo4449r363B;i48B5y0;c0d1e5s3z3;n1F6o29;!a2864e2660l76n129o1;!a4Dd8Ae4g901i1A09l10Fs50Ey0;u2184;!aB25n49C;a421C;l1Ao127;e3F9Ey3908;aC9b275Ec26D9d501Ee9DAfFD6g30ECk47C2l42A3m32D2n2D5Bp19B9r4E42s2F28t406Cv23CBx30DBz13C6;d0r3A8C;m4Ds55;eF61iCBl16Eu1Dy0;eA3i18;a26BBb2DD0c4299d1D58e1D69f4B12g26B1h1E20i3FBBk13CFl1014m2D09n3DCCoDB6p268Bq1710r2C96s41CBt355EuD40v13B9w4D8ExD71y387Dz2C;b3BCc4900d21DBf23D6g4EA0l13C2m1678n1EABp1B9Es11B3t3C17z33D2;h2989;c2665d36DCg1885k3B5Fl4BA0m407Bn4EDBoD3Ap18C4r1BB4s336Ct384CxB9C;!g267hEs0;!a14s0t0;i5Fo29;a176e1i0u5;!d0lB0;v12D;!e2E72i10;e23i6o54;i408l118r208w38;aC8;!a69e4i6s0y0;!a28A7e4i6s0;s874;!a299d0f183l1B1Am2Ep165s0wA8;c0n2t7;s370F;e23i6p5C;a36o49;d0n26Do29r60;e16B;!d58s0;b2C65c435Ad1A4f74Dg14A0iFkBm1CE2n3490p4D81rBs41D0t200Eu26Cv2458w2F50y3472z25E6;e4C1;b40FwA8;d0n1r2Fs8;!k90l19s0;b1B9Cc4907d29DBeAC4g3486i299AkBl2D07m3114n4B8CpE29r10FFs3AE9t20F3uBABv3B3Aw3CE4y4B49z2771;!cE0i6;!n27s0;zA4;h349;u165B;a10d9Bn156Cs0;e3CBC;h3AEC;!bF8e2B37gB1h798i21l36Fm2Es1AD6w399F;e1i0o0;m10n36r1;a2B9Fe146n8w0;r497AsF1E;g5Bi4nBrCD;b3C09e21E5i6o240A;c4757d3206fD2Fg43ABi45BEk1l25A8n139Dq30Dr503Cs16Et2EC4z1B85;s50D0t40;e3B3;!c245Dd399Bg1Al137Fm23FAn12B9q11Dr28s3EtAB0;b1t0;aCt1;!aCbB1d1C97eF52iB05s0y63;!a93b1DDc98e5099i681l22m20B;i25l64Dr4873;e166n22;i12F3o4ECy0;bB0Bc5D9d2659fBFn3pE22s483E;d3r8;a46e49A9iEo43E;n3s100t7z3;t1972;!a31b386e1F2Fh109i30B2o28DpAFBs491Bu4Ey0;!a47FAe3437f37i49F4l22o4C4Fr3F65s0y22FF;nBr16u12;e1D4;!n76pA9s0t62C;i6o2A3;a355De41F2i4A60;!iAC6s0u5;!aCe12s0;a2226n405o3F0sD1;f10F3t78D;c32o127w9;k1s2C4t420A;h263;h322F;e12r3C95;a4EEE;a38DBe4586i37A7o1E4B;e3706;!r2A5s0;!c9Es0;i383Du412F;!d0l22r1s0t11C;a3712eA6Bi132l87;d46n7;!e4E4gA9Bs0;t1u32;!aC9e385f3A83i21l182Cm286Dr276s4C1Fw83C;!s0t1D61u1;e5mA4nB;f707;r510B;r8A3sBt4A;y253F;t17AA;e255i1A;c1369d2Cg30C6s37AtCC5x284;!c89d4A83eAg3F97iAE0k48l22nA9s1182;!e5i71y0;c3f7nFsE;a12B6e3C31h8Bi2BDDo24A1u2673y2234;i1r86F;!c2752i6r48s0t88F;n2rE7;a465Cb37E5c4B18d2396e4861fC63g46FEhC8i222Ck4CCCl1EEBm48C6n23CDo4920p23F2r3A93s446Dt334Fu360AvDA6w2BBy44EBz17C3;c2352d114e24fF2n3o29;!c1FAdA1Ee4i33Dl331FnC74p28rF56s52t4420;o4E92;e12o428B;a12r54F;e1Dl2Cu20;o1r28;h4B3A;e1Bl1nF;!d0m64r2Fs0;!e5n2D;a4DeDo5150rB71;a1e2D89i2498o46;eD82i4F87m12Ao21p2BFBu117EyF0A;l16n3BF;a4BB0o33CBu2F30;e4377h3175i67n89p4DD0y0;r1099;!eBEh24DlA5o10p1C3;a30eE;e23i21m64;u4EB8;d0l6AEr141;n263u12;a4DCBe2F1Ci507Do2FA8y1B5A;!e4i6o9Br276s0;a16;!d0e0s0;a25B;m666;a2AFAe164lB;a4e4;o4EB;d0k0;!a516eAi6p227s0y0;a42i6;d0r2963;d0r211;g0i0o0;a1E7e15i6u57;!dA8e4i21s0t14C1;l1p6B1;!aCe4f8A2i21s0;a4De1F44i21s0;a29C3;a2E9Ci36;a13c0s100z3;!a4242b2213e4D75h14Fi21l200m18F0n4BE1p3006r49B7s436y0;!i352l1CBs0;t69D;!e50s144C;!a42B2c266Ee25E1g1299h27i2BADl1o1BD0s0t16E7u2140;d0n175;!eFFi43l47s0y0;dE0m19;!c2362n3977;a4Be201i33CDoDr1;o3E4C;e1BnFv27;g47r16;!e12i54Al7Ey0;a4EC4b32DDe2208i253k2496n4191s196Ct45A0v1EFE;u1C7;!c249CgBk0nBs0tBx0z35;e20E4;eAi86y0;iFF0;l299F;i69Cp9FtF8;m1C6r385D;m84r339Du12;g2F77i0lA7s0;c32t61;!aB9Ee9i91k5Ds0y0;e5i5t1;b1126c27F0d24E2fD9Eg74l4755m188En48C9p2E21r4B0Es3F2t2E9;a3E18o50;!a41AiBs0;m0n2rC;c446;!e15i6o29s0y0;a7Di0u5;!a7B0e2F01i1D6Fl27r7s0;e182o11A6s9C5;n0r90;i85A;!h24Dl2Ct28;!e3940l1s0;n405Cs0;f7n2s9A;!h2D41lBs0;a20F7i1598;a4Ce15B;dC9;!d0rE2s0;c19Dn29C6t150;a9e9o49;e1325i1BC5;i28F;!a20i1A5E;!a4Bp1Es0;!c32d0m62p131r28s0;t341;e2Fi8FCy0;!a12A7c3D2Ad4FC1eBg3EFEiABk3FF1m3254nDEo3551p4153r43ADs41EBt1D0u4E;!h1AD5p50A3s2B84;!a4D0Fb22Ce2C68i21m2Eo4D9s0w70D;a4113e455Ai2AB2l1562o4F2Fr49FAu126B;r3E76;!a1e15i32Fs0;lA7m1;!a6AAs0;c2Bx0;a1l19;l39t39;gC3n65;r36Bu4E;bD7r87s4C0;a28De9Fh4888i156Bo241Ar4065u4AB8y7E;g0i20;n2428s9E;!a54hA5;t4C6;i4E0A;!e26s0t1;!iAFs0;l1B4;e0i1Do10;!e166f37i6;a4Co57;lFB5;!i3Cl7n22r0s8t58;!a4DeB75h1Fi4F2sB4Et0;l37D;!i977;b3r157u1CF;i2E14;l29o2D2;e4EF5i1A66l2Bo4F98rD5D;i3Co74;t947;a3466e4AA5iEo535r3F1E;e3246;!a2C99eA14i302Eo455Fr1568;!c0e24;d1FCg3207n33Ap46s83;n2E7s11;!a11Ee20DhB1i2A4s0;sAE;s2C;!s23E;u27E;e29Di2E43;!e15i6l216s0;l42A6n2A9Do23ADs151Dt3C9F;!e2191g25F5h124i189n13Cs0y0;n16r16;!e15i6l7s0u49;!a20eCFi2878oE8s0;!aCi35u4E;a42e10uB;s5Fz5F;!i24;g0k38A9;f2FBtBv3;n53u5;c1Ah13E6k2FF;a451eAi32F;a0c4485e0o9sD1;l3o10v3;a7E5;n7B4;b202eAi6n28;!b37E6;!n1ACr438s0;!d0j6Bs0;!h10m2Es0t41E8;aA54i14u14;!i20o453s0y0;a20e0;e270;l0t665;e4l8;a0c1;d2C38e257l1213m2E94o10;l64s1F;h1Et1E;!r1Es0;i875l0;c3iC;!eEEn3s3;!e4i6pA5s0y0;a49CCe1D03i4707l4274o4933r3E19u4FEB;!a21A7e5h317o3D0D;e186;yFC;!d177e134i280Bs0y0;!h66t355;!d0n7Fs0;!a23DFeFi2A5Bo54s0;n18o3032;a3A20e52o2DF3;!aCo29s0;lCm3s8;a3C22b56cBd38C6eC54fAFFg4D78h2783i469Bj75Ck3781n153As2772t347Au4ExDEy0z15FB;!g928h7A0m1EBo1s0u3BCFw44E;!e0i4697s0y0;m57t1;!nA0Cr1A0Et738;a30A3;c4E7;d7m1E;!a3A7e17i3Ds0y0;aCe23i311y0;e7i2B;a10e4iACy0;uB0;!e15i6m2Es0w80;a176e68o29r56s318A;p7DC;d292m6B0n1s919tD2;!a1C6e4i24F4o1s0y63;a43C;i5EB;h377B;a341Fi3E0Co473Ev21E;a87e934h242i9E0l47CEt3C7Au403;!c1FAd3BE5eAg7i37B4k12Fr7s0;u5B1;e4g1E;eDD6i21t16u5;r2877;c444f1g4An150Bp22E3s44t1AA;a30o8;cB6n4C36r1s16C5t1u30;p295;!e15i32Fs0;e166nFt365D;e4DBDiBAy0;a51e4i43l19y0;h18D1;!c2338h37EAi4E8k58mAFFo423s26B4t3B6A;m1r8;t4A3F;eEi6o6y0;l18B7;!e21Ai224l7s0;d613e5g493Fi43DEo1s376At29A6v180;r195;s6C0;a27Ad0r16;e80Al22;a3A2Ec30Ce45DEi1F94l29D1m1EC8o479Dr270Dt4E79u32DEw1Ay4860;cCA;!i10Al1Es0;c32i4r47y1;c0fCDn19t3u14;h7B;l16t27;c0d3;e5o3B9B;d8Ai1DB;!d8Ai1DB;!a3CDc13An22;!a4s0;w35E;o50B8;aCi2By0;!e4i6o28s0;d1Ct7;e0i14;e0n304t3FCy0;b7Bn304;e187;d23F1n188C;!a2DE0b22Cc2EE7e4392i16F5l1B91p4C07s0t4078w2C84;a40e451i9E2o503E;c2Bd349s1F;!e6Es0;!a1FFCb4CE1c2171d1548e43CCf35D6g37D8h1EBi22E2j811k428Al1CD8m3F2Fn3D22p4463r4327s4602t1928u34w4565z2E3C;!d0f37l36A8m64r1s0;e5s1DAu14z3;c30Ce1266i72oB2Eu3DB5;r60s8;a1117e17E9i1B5Fo30EEu231E;l66F;l25E;!g4AD3s0;a32Ae12;!b27E2cD8e6D9i6l2BAw80;eABh1Fi21t2C5E;f44;a1e30;cEg47;a237;!i0u5;m9Fn1A;!a2A38e4f1F1i6l22o582p16Cs0;!e2F71s0;!e25s0t20;!a1F8Dc18F8e291Ei3D38r4E73s0t196Au3468;a1272;c4396dC9f37C1g3337m395oB8pD04r36Bs452Ft3085v3788xAE;aADu69;r2CC1;a16e40i18E5y0;!f6B8;lA7n58;e93r4BBE;r2Ds1F;n125s11;!a34u34;e33A9i1B09y0;!e12CCi6m5114o1825r1E8Cs0t2024y3D;aE6b2F36l217oE6;h49B4;e4224iBAy0;a37F8c11B0eBC7h3436i1184o3B4Ep28C4s1BE9tDF3u48BD;!a123Fe12Ei3C5Co0;c6ABd1D0m2A32;a741;a4D0e31C9o49F0r714yC4;!g7Ao10s0;sAA8u5;!c1FAd3A27n13AEs0t0;i264k187;c961iC4j17Dm58p21FE;a27Ec247e3EBCi6l4CCFn48r4145s458t0;a10C3i31D3oF1B;!i42Ds0y6A2;a529e2F6o372;u36v47;i4881oCyC;e12l263n2;e3C93;a5BCe15i67l44r3522y0;!d77;dA75;n1FA6r65;r157;cBi56t37E;!aAF5b386g4B53h28s0;a20i9o74;r2F8;a1Ci1C1;e1C84i1C22;dF2iCl5032r118s346Cu59w1306;!d0p5Fr1s0;r510;hB4lA5;!a9A1e1B2f183p72Cs2BBBt112D;e17j5A;fBFg470Fl67C;a3A3;!a20e3CE5i311l22m546o56Ds0;!e2DFDg29A3i6oF35s0t357;d8Af16;b1Cd70r41F;aCe26o9;a31Db1f8iEkA4m8AAn498At38uE;!f37i6l22mA9s0;d38g44k48;c0nAC2s19z19;r4E4Bu12E;e24n2s11;r713;a49C8c3E81e4660i1C7Dm76n441Do3F75r1320t1395u4A25v3364;nD9t3CE2;!m28Fs0;c837s0;e333i28D8oAAD;g39Cm176n296r296sCA3t1;c1k1r8;h1l3;a315e560w3BA;r61t2D;m21Ct3;!d0n39s0;!c130Ed0e2493g25Ei752k579o48C5;e1Bo241;u237;x2A2;n441F;l213F;g47i132t1;!d0f37r1s0t0y1;aA2l216;i40;!b26F;c7l1t3;e85i35;d19lE0n25;gBi185u6C;a182Fe1i33Bu4E;a6Eb2D2Ec2F8Ed2A04eD43g15D8l1Dm4EC7n2F0Eo3F77q30DsDB3t1D55;!e4i4E95l44s0;!n1Ap1r2361s0;!b4689e22Fl2911r5146s0w172;c1eDn2;m1AnE7F;a1CCf1DEEt12F;!a4127bFEeFECf4322i21l2F2n0s52;a8c2A;fE3;!a384Dd244De22CDf42A1i237Am4DDAn20EBo2A2As0t2D9Fu922v3F1Cy63;i479w0y1;l203Dr10B;!c362s0t3559;!l6Bs0y1;e1965i1EB4o4F9Fu3833;p3049;n5E3;!a9e206Ci2530o1s0z2C9;!a30e24i577;!a17DDd29BCe1gC3i2C5Bn1991o5128s261At1654u4B11y63;o1E6;!eAf37i6l22s156;nB7F;n127;a3470;n3995t1;a1540eB81i553o2F83u8D;c33Cd3FEl84n70t186;eDl7s11;l4BC;g15AlA7;a3C0Fe11F0i50ADv310D;!l7nD8s0;e4DF4m5DEnFo2B4Ap16E3u1E33;!l1E;l251;e36;a4Ae193i6;t2847;f36A5;a34EBb2492c1094d3D62f29B9g3113h1Di43DCk30CEl16AEm1345n2A87oFF1p3A0Fr2A1Bs1366t39B6x8Ay34EAz1876;uBD3;!m314s0;a3ECCi4CC3y0;eFA5i2966;eAi6n6B;i7By20;!b29c1AF1d5C6g396Eh33ClAD1m36ACn452Ep1B30s156t3B1E;i176A;!a154Eh1As0;d3F2Ae1v3D;d46D;!a299l152r35s1;a88i14FFv27;c52;a4BD6i25o26FCr2A27u984y52;a4BFe32DB;b1Cl0n8;e1Bk3;d0r2Fs3Eu5;aD5i73;a2252e19E4h478Fi4BDBl4417n1BC7o442Dp351Dr4B04s4AC6t31FEy4712;a4E1e0o1FADs4C;!e1o1;!nF3s0;n3BB;n165s1D8C;!e54Bi91y0;aE6e1Dl19u43AA;l2B5o16BCr4B19u966;a4Be15i6l19;a135e23i6;!a1FE9b383Be1857hEAi178Eo595s0;n12Ds102;a327o4CB5;a4569e4E0Ei42FAo149E;o28r32CCu5019;h30E9;!e12i21n76s204A;a4A0B;a2586c40E6e2214hEE8i4B67o10EAsEt1y1503;h6E7;hCD;m351A;r520u21F1;d18s27D;o125B;!d4C62s0;!d1BFAlA6Dm22Ap2A7Es0t3D2;!iF53s0;!e24i496;!e2CA8h169Ai4C12l34F8mE3o199Fs38t4CB1z1A;iAE7;e456i6t0;n194r2BF7;cEDnFr25;d1s14;!eDECi259l479Bn22o1s0;!eD0i21l22s0;a112EeBCAi409Ao4189u705;e5f1920;!a4Be4iDDm2Es0;r44;b1Cc58r375As4BAFt2B6F;m0t2F;i3C2;h2A9B;!e0m30ADr2C4;e463n10A5p642q1238rA12s5A4;e1i13o120;!b7Bs0t392;a2730iCo1D1F;eDi6Cy0;i128l27F7r2B5t3A03v3;c4235r78;!o6Ds0;a59e95i70FoA92;!cB2h1633s0tA9;n1396t1;a351i30F;d0eAi6u20v47;l3492;!e2DA7iBAl22sECw236y0;a9u9;mBt163;o14AE;aCe24;!aCe24;l5ErB;i2193t7;!p2BDs0;r16C;nF99;e1y718;!d3Bs0;!i31o974s0;i71o2CA6y0;aCd14E3;a1CDu2E6;!d0f37g1Am64s0;!i1FFk211An8D1r375Bs11t61v3y1;e26i0o1;l10E6;a1D09e4DD4i474Eo1E0Bu46CF;e1828nF;n1E22;aCi10A;a43F1e148i3A7Cl36A6y0;!f5F5h24Dm2E;sC0t1DC0;!e23i6o3D47p318s0;p2950;!d1331g320Bk5Dm8Bo9Bs0;n20r16;a7F5f419Bm1Ao5C7pE57r3380;a23Dt7;a176e23i6n28;!a10f1n84s0u14;a2565i3759o7A4tAFA;a4DiBF2;e24BoF69r13B;r394;n1578;!a38Fb180e15i6m2Es0w172;i82;e1DFi914;!e1Bi229Al7n22;k76;a1e387l216o1;!b4BC6c4D1d0fC2g917h924i6l1CCEp639s1C1Dw597;a10B5e3A3Ei4AE6l87o19BDr47FCu126;i4319;d210mB;!e15i6k5Ds0;!n36FDs0;d0l1F2r28;g3D;!e14Ef37i6s0;!c1C7e4i6r3CD6s0t0;a36EFc4A7Eh11Fr22FEt1D84;bBpA1;k19lADy16;b130dA8eB3l7n139s3EE;l336z87;a4785b1d0e2C66mB5n17D2s2793t992w213D;i9u9;r5ED;a35B;a2DD9s102;f3E4Bg2ABi1738l4763m1C00n258Co4135p2B6Ar3D54t2082u2B5Dw3568;m364E;d0o10;!b398e40i91l10FsB0Cy0;a3122e8DiBy4A05;g19n1;s511;e18i18;l3EE5s0;!a2C7Fb58e482i4732o480Cr2385s0t40C8uED6;!a1F1Dg3A71lC57m2Eo2204s0uB;t39u20v47;a869c155e374Dg2641n2Cq11Ds9Et0v2920;l1D89;e220i1166o1;m31AFs43BtB7z431;t1FF2;a6n115;k0l382;!aCe17s0;!a9s38;!d1f893i3EB4k32CEm171En1p4486s24BAt35DC;!a1C0Dc2FD5eB9f38EhDE9i22AFm2Eo10s829t1BF6u4B4Ey3159;a12h48;a1D4b164k1Al1m11F2rA0Es1F;!d13Be513Fh19F2i6k76p2C8t3213;!aD9e6A4i130Ao3825;!a88iBE0o3E9Ds0u51F;o6BDuE;c1Ee50m1Es35z1E;k39qC3r7;a11Ce1;n1612;m3B5p10B;!a211n2s3D1B;l1BE4;eAC1m159C;a2CFAe2866o1F0yC;eDi13;!e7C1f37iDDs0y0;!b1Cs0tBD;r5EA;l1s5t1;l32Bm31An2A9;i461Bo31B1y0;!k24Ao29s0;!e8i8;a149De17o15B9u14;!d203i3Co1y0;!d1EgF4s0;a63Bu703;!g19r1Es0;!a9b27CcF8d0gA8l2692r17Fs0y1;b40F;g14C;l34AF;e186o10z12A;!g0i31Dl583n1E9rEt4C0Ew1;!e19E2h508Dl44p7As0;e6Cy0;a1F6Eb2931c1A29d45BDe127Dg1B6Di2824n12Fo1794p246r27B0t135Bu5;i11E5o215y63;d19n2DAAp1C;!c24E3d3FB3r1241s525;i1CC;!e4i21l22s0y0;!r0s8t1;aFl44o1;l1C4s400E;m4A5;d0n1r0s8t1;d0n1r1s3Et1;e1l4E9Fn26F;u3600;sB5D;c9D9i5o1C1t3AFB;r1D7;!h24D;a1Di332o10;aCo29u3D;t19E7;a20e5;!d0s0t1x0;!lF3m2C76p17Fs0;a2D48c1830d5025e2368g16Bl3643u36w1;!a3161bB99c1FAe261Fi11A2l3816m4CE9o677s0t2EAE;e28D0;c1E9gA41k23E6lEC8o13B8r270Ct438Au2EEDwE;d1EC3g348s42A5t43FA;a40FE;eF6B;a4A4Ee9o50;lCn2;d3n1AB;!g44Fs0;!nAsA29x0;i2F44o11ErF3y0;!b38Be15i6l22s0;b1CfBFl2844n2o10;a3CeBi1;!s0t150;m4C98n84;!b1r227s0t28;!s0tCA;!z3;n48r2B93t3A2u12;e23i6o12;a2BD0c83i230lCE7m4Dn158r36Et1FDA;!a8FeC1i6l7n22s0y0;!d0o48Dr28s0w10Fy98;gBn82;f7n2s11;n0s14;!e12i6l47s0;r6F3;!a660e4905i91o783s0u4AE0y0;t6AB;!aCd1DB8eAi3A17j8FEr3248s8;p48s3C7;!i13o1s0;c47fCDs47;o3C50;!l2C7r1B3Es0t5C;d157;!e133Ai263Bo3CABs0;!l1170o1r346s0;d17C;y7FE;!e5076i2DCBo1s0;i5m0t1;a3B1Ce2281;!e153i394Cm2Es0y0;r41D6;!f37i2AC7l22s0u3D;!e14EiFAs0;e3A42u4E2E;e93v1D96;f37FBt1;aDAe3893i3584u2C;d5Bi2A30u5y0;m356t4A;e6;e392Ci1D15o2520t0;l1n8r7t10E;!e1Bi5110l7n22s0y0;c3eAg0;l65Er3A89t0;c32r7w90;!g1k1E;b56d743gD51l273n82r14FsBt21B;t6F5;l70nA1s3Du5;iB4o8A;e4FB4fB5;b1Cn4r2EDF;cBt12F7;m27n1;e5D4;aCi2DB3o1;r30C0;!s5129;u173B;!l0x0;i10Ao0;!a0oDA;a164e456i6;e3E1i2ECFoAE3;i36n5A;m6BFs5E;g44l182;!e1i7C;!s3A23tB6;nCF9p1A5t1A5;!aC2Dd1D22e2FBCi2052l834o1F0r1BCAs0u62B;e699;l3s18u5;n1ADt0;aEn25;!e4FEEi86l7m2E;c9Ft2827;i500B;t4414;c1eDf7n2s3E;n4s8;c0e112nFs11;!e1Bl1AAn1C6Ds0;!a1CCe20B9iBAl2Cm14Fs4356y0;mA70sC0t2D;n4s11;d90;h0k576t188;!e6Co1FE;!d114l1n3CC1;t3052;!b5De15iCCl22m2Es0y0;t32D6;aA3e155;eFFi21;i120;u368;t5FB;m64n82;k9D7;mCAnE;cEm116r133;o2647;r257;a9m3w1;aDm4D;!a7B0e915i6l52Bo3861s0wA8;!b314s0;!aDe20Di2BE5o29s0u1D;l5s525t2D;!a51eEE;l5A9s8B;d0s8;e15i8F3;s117t43B7;!cB2s0u1;o28Au1D;h50F;c18Cn1s280z177;e8Bu15A4;n2A1Cp1A4;!b1Cn70s0;!g1546lA7;!e4i21s0w136;a19B8eC5i1A86;nFs102;f158n32;!y1C;aEcEi10AnEr30C5v27;e5n3o9;d2D4Ee9EBt68C;!n6BsE;o18E;e1790i199y0;!d0n15F8s0;a1704b32BDc15D2d2409eDEFf10D4g2E33h35BDj2DA2k1F34l4399m4DABo9p1671r1AE6s25FEt4DD5w398D;!mA9s0;r5B;e31i31;d0s0w1;!dFCEl42FDn1B4Ar172A;a456EeAD9;b40E4cEC5d47CDf1508g4DFAi4017k2ClC10m1B77n3880p4FE1r1419s2905t172Bu26Cv2Cw28y2A43;!aDcA4Ee30Eg64i86k3EF1l22nA9s0t1E3Bu17C8x3F;n361;o3E73;a3D5e99oD8;t40B4;a3EDAb386c2C0Cd510Ce2E82f2C2Cg2253i41C5k29l1E2Fn7Ar2019s4A2CtCFFu4Ew4834y1C0E;e466Bi6l2C;!aA2eC1i86n22s0y0;!l3AEs0;a2F6r4C11sBD;a1054e1150iE0Er77B;iA92;!i1Dl3Ar3FDBs0;!hE0i69m2Et27;!d0rEs0;iB77o81y0;m3F02n2121;a2033d46EDe11ACf4F39g28i3A15k1n18o128Fy5z41;g38n56oB;r245F;h83;!e1m165s8;g273;!c11;rB4;t113D;h2E00;l4r9;c160s47Bz19;e94Di2By0;o18BDu5;e50m16C2;!a4F6i5Fk27s0;a2B6De45DBo42EFu10;a630i1A6;l169BnCC4;!a245i9k1ElBs0;k53m0;u3664;b2DE8c2D68d33BFe4818f1871g10FAh19D2i4D25j552k4C18l16E0m4C38n139Bp14CFr4DC7s254EtE58u3D9Cv4376w152Ax4E20y3210z24C9;a7CDb1Cf4F5A;!a32FDe2C21i7BEoB03r71As0;o2C6;t2102;!n2s1898tBz19;!a12d1A4i290Co11F3s0u304Bw3602;!b38d1557e7f47F8g422Di91l4681n4190p20C4r2C1s4830;d58;n4BtB;!e1g60s0;lB87;aCe23i6y0;n52t150;l357F;eAD9;i8t13F;c3FB;!e1i96;g3s5B;aEw39;d0eBi2BC3o1046t38;!a46C6c2437d4BDCe4424f1F1g2C1Dh2064i304Aj22Ck3391l39F4n34F3o477Cp4AD2r1EC9s3DF0t1177u4FBFy4913;aB1B;!e5s18;a10e8B1o30A1;a5BCe4i67l44y0;r13Ct1967;e230;e500F;lA1;i27o9By0;!a351Bd0e4E8Df216Bi952l215Bn6Bo4B2Bp362s32Ct0;!e466Ci21m165s0w98;!a3CDe15i21r22sEC;eAi13oD;e2D29;r361;b1Cn65;e2F1Di3C;nFsEt3518;c9Ed3AB;h25ED;!pD66s0;!a3291b7eAi577o876s0u37CAy0;e1u96D;gBm1;!b648e1FBiBAl7Es0y0;i4oDA;b5Cd0l2BFn28s4086;!e0g19l0s0t5B9;a9e0k1;bA5;!c1CoE8s0;aCe5h239i3B54k3938u2B18;!a7;b36Dc312i83m38An27E6p21Cr3;a3F9;e4C3B;m1n1u5;n39t39;o3754;!hEAi224s0y0;c32e0i215l2B7Fm168En4BCCr1t4E66w893;b145c64e25n433Aw0x117;x1AE;e5CFi43y0;e2B0i43y0;nAB6;!a4777e31o10D5r713s0;!d0i6m2En22r0s3E;a0e1o9u14;a4C4Ci3F4;!l1As0;e4i3F35u32;g34Fn1FFs220D;e1Bt7;b1Cn26Bt10E;d0s0v3;a1E14d18e506i21k28o46u3F7C;aEi223;!e2CBoDAs0;i25o29;e3Ai96u69;!e0l3As0t19;!e1g3A8s0t9EA;a5063e17iAB6oF;i1DzD4;!g352s0;a124BeC39i2938rC79t3D33u115A;iCw0;!a475Ee4i2ADAl1DBFp4B0s0y0;e4EBAh1i4C4Ay0;!b177e33BDi123s0;!cB2d1AAk44B9l1m141s115;r32FFu1EC1;a41Di123;!c50EEe1032i21l22m1F4o2394s78t4117u22F8;!bBs0;a1C61d0e590i2724l33C9;t53Eu159;!e5i5F;!h1i9n335s0;n2r7;aDAe321Di4Eo5E;t438E;!a2E17e16B8h46CCi4C5Bo5CrD84s0t50By3EDE;!e4iA64l5B9s0;!a1274cD8e518i259l7s0y0;!c4D1d13Be4fB5hEAi6k1B2Dl14B7p3959s140wEA;e1nFs4F52;d0n4979r1s8;r3s9B;!m29;h1n1;t33E0;r2603;!a70Ab398d336e15f265i21m2En22BCo7E4s0;a20eAi4D06;aC1Ce13C3i6oC9u35D;e1C47r714;e22FrAAC;a2EFe1t1;!aBA5d0l4CBn2412r0s3E;a97e36D9o535r28B4;i110y0;!aD7eAi6s0;e704p2768;!n2s0;!e509i43u49y0;a20oE8;!o10p3619s0;nFs18C;!e4i5D2lB4r25s0u30v27;!e1f77Cn1s0;k1ECDrEB1t1CAB;d70sEt2D;k0t1;g7D;k1l1;rEu40;!b184m3611p9A4s78;e356h117k5Ds104Ct1A4;a31D4b15ECc3A18d1837e47C3f35E6g3DB4h2BB7i4A1Cj16E4k224ElD2Dm3B11n2D95o39EEp1D1Cq3FD9r3F4Fs2C53tFA8u4005v30D0w3519x316Dy2DE7z44D2;"

---@type integer
DawgStart = 20820
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

CHEAT_ENABLE_CODE = 'nthgthdgdcrtdtrk'
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

