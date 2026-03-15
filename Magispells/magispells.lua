-- title:   Magispells
-- author:  Grant Williams
-- desc:    A word-spelling puzzle game. Inspired by Bookworm.
-- site:    grantwilliams.info/games
-- license: AGPL-3.0-or-later
-- version: 0.1
-- script:  lua
-- input: mouse

t=0
x=96
y=24

function TIC()

	if btn(0) then y=y-1 end
	if btn(1) then y=y+1 end
	if btn(2) then x=x-1 end
	if btn(3) then x=x+1 end

	cls(13)
	spr(1+t%60//30*2,x,y,14,3,0,0,2,2)
	print("HELLO WORLD!",84,84)
	t=t+1
end

-- font loosely inspired by this blackletter typeface: 
-- https://en.wikipedia.org/wiki/File:Old_English_typeface.svg
-- by Darkevil, public domain 

-- <TILES>
-- 001:eccccccccc888888caaaaaaaca888888cacccccccacc0ccccacc0ccccacc0ccc
-- 002:ccccceee8888cceeaaaa0cee888a0ceeccca0ccc0cca0c0c0cca0c0c0cca0c0c
-- 003:eccccccccc888888caaaaaaaca888888cacccccccacccccccacc0ccccacc0ccc
-- 004:ccccceee8888cceeaaaa0cee888a0ceeccca0cccccca0c0c0cca0c0c0cca0c0c
-- 017:cacccccccaaaaaaacaaacaaacaaaaccccaaaaaaac8888888cc000cccecccccec
-- 018:ccca00ccaaaa0ccecaaa0ceeaaaa0ceeaaaa0cee8888ccee000cceeecccceeee
-- 019:cacccccccaaaaaaacaaacaaacaaaaccccaaaaaaac8888888cc000cccecccccec
-- 020:ccca00ccaaaa0ccecaaa0ceeaaaa0ceeaaaa0cee8888ccee000cceeecccceeee
-- </TILES>

-- <SPRITES>
-- 128:cccccccccccc0000ccc00000cc0cccccc0ccccccc0ccccccc0ccccc0c0cccc00
-- 129:cccccccc00cccccc0000c0cccc000cccc0c00ccc0cc00cccccc00ccc00000ccc
-- 130:cccccccccc00cc00c0cc000cccc0000ccccc000cccc0000ccc00000ccc0c0000
-- 131:cccccccc0000cccccc000cccccc00cccccc00cccccc0cccccc0ccccc0000cccc
-- 132:ccccccccccc0cc00cc0cc000c0cc00c0c0c00cc0c0c00cc0c0c00cc0c0c00cc0
-- 133:cccccccc0000cccc00000cccccc00ccccccccccccccccccccccccccccccccccc
-- 134:ccccccccc0000000cc00ccccccc00c0ccccc0c0cccc00c0cccc00c0cccc00c0c
-- 135:cccccccc000ccccc0000ccccccc00cccccc00cccccc00cccccc00cccccc00ccc
-- 136:cccccccccccc0000ccc00000cc0cc0cccc00c0cccc00c0cccc00c0c0cc00c000
-- 137:cccccccc000ccccc00000ccccc0cccccc0cccccc0ccccccccccccccc000ccccc
-- 138:cccccccccccccc00ccccc000cc0000ccccc0cc00ccc0cc00cc00cc00c0c0cc00
-- 139:cccccccccccc0ccc00000ccc0000cccccccccccccccccccc00000ccc0000cccc
-- 140:cccccccccccc0000ccc00000cc0cc0cccc00c0cccc00c0cccc00c0c0cc00c000
-- 141:cccccccc000ccccc0000cccccccc0ccccccccccc0000cccc00cccccc0000cccc
-- 142:cccccccccc00cc00c0cc000cccc0000ccccc000cccc0000ccc00000ccc0c0000
-- 143:cccccccc0000ccccccc0cccccccccccccccccccccc000ccc00000ccc00c00ccc
-- 144:cc0cc000cccc0000ccc0cccccc00000cc0cc0000cc0ccccccccccccccccccccc
-- 145:00000ccc00000cccccc00ccccc000ccc00c000cccccc0ccccccccccccccccccc
-- 146:cc0c000ccc0c000ccc0c000ccc0c000ccc000000ccccc000cccccccccccccccc
-- 147:cccc0ccccccc0ccccccc0cccccc00ccc0000cccc00cccccccccccccccccccccc
-- 148:c0c00cc0c0c00cc0c0000cc0cc00ccc0ccc00000cccc0000cccccccccccccccc
-- 149:cccccccccccccccccccc0cccccc00ccc0000cccc000ccccccccccccccccccccc
-- 150:cc000c0cc0c00c0cccc00c0ccc000c0cc0000000cc0cc000cccccccccccccccc
-- 151:ccc00cccccc00cccccc00ccccc000ccc0000cccc000ccccccccccccccccccccc
-- 152:cc00c000cc00c0cccc00c0cccc00c0ccccc00000cccc0000cccccccccccccccc
-- 153:00ccccccccccccccccccccccccc00ccc0000cccc000ccccccccccccccccccccc
-- 154:ccc0cc00ccc0cc00ccc0cc00c000cc00cc00cc00ccc0000ccccccccccccccccc
-- 155:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
-- 156:cc00c000cc00c0cccc00c0cccc00c0ccccc00000cccc0000cccccccccccccccc
-- 157:ccc00cccccc00cccccc00ccccc000ccc0000cccc000ccccccccccccccccccccc
-- 158:cc0c0000cc0c000ccc0c000ccc0c000ccc000000ccccc000cccccccccccccccc
-- 159:ccc00cccccc00cccccc00cccccc00cccccc00cccccc0cccccc0ccccccccccccc
-- 238:0444444444444444444444444444444444444444444444444444444444444444
-- 239:4444440044444440444444434444444344444443444444434444444344444443
-- 254:4444444444444444444444444444444444444444444444440444444403333333
-- 255:4444444344444443444444434444444344444443444444434444443333333330
-- </SPRITES>

-- <WAVES>
-- 000:00000000ffffffff00000000ffffffff
-- 001:0123456789abcdeffedcba9876543210
-- 002:0123456789abcdef0123456789abcdef
-- </WAVES>

-- <SFX>
-- 000:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000304000000000
-- </SFX>

-- <TRACKS>
-- 000:100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
-- </TRACKS>

-- <PALETTE>
-- 000:1a1c2c5d275db13e53ef7d57ffcd75a7f07038b76425717929366f3b5dc941a6f673eff7f4f4f494b0c2566c86333c57
-- </PALETTE>

