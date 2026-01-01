;; title:   Jump Solitaire
;; author:  Grant Williams
;; desc:    A simple peg-jumping solitaire game
;; site:    grantwilliams.info/games
;; license: MIT License
;; version: 0.1
;; script:  fennel
;; strict:  true
;; input: mouse

(macro inc! [x] `(set ,x (+ ,x 1)))

(var to-str nil)
(var t-to-str nil)
(var a-to-str nil)

(local push table.insert)
(local pop table.remove)
(local pack table.pack)
(local unpack table.unpack)
(local strf string.format)
(local floor math.floor)

;; Sprite flag bit interpretation for 
;; peg holes:
;;  0: is a hole at all
;;		1: has a northwest neighbor
;;		2: has a northeast neighbor
;;		3: has an east neighbor
;;		4: has a southeast neighbor
;;		5: has a southwest neighbor
;;		6: has a west neighbor
(local
	[bit-is-hole
	 bit-dir-nw bit-dir-ne bit-dir-e
	 bit-dir-se bit-dir-sw bit-dir-w]
	[0 1 2 3 4 5 6])

(local tile-w-px 8)
(local tile-h-px 8)

(local board-w-t 30)
(local board-h-t 17)
(local screens-per-map-w 8)
(local screen-w-t 30)
(local screen-h-t 17)

(local peg-w-px 8)
(local peg-h-px 8)

(local board-names [
	"tiny triangle"
])

; my own to-string for debugging.
; fennel has one in a library but it
; doesn't seem to be available.
(set to-str (fn [val]
 (if (= (type val) :nil) :nil
 		  (= (type val) :table)
     	(if (not (. val 1))
      		(t-to-str val)
        (a-to-str val))
   		(tostring val)))
)

(set t-to-str (fn [tab]
 (local strs [])
 (each [k v (pairs tab)]
 	(table.insert strs (to-str k))
  (table.insert strs (to-str v)))
 (.. "{" 
 	(table.concat strs " ") "}"))
)
  
(set a-to-str (fn [arr]
	(local strs [])
	(each [_ v (ipairs arr)]
		(table.insert strs (to-str v)))
	(.. "[" 
		(table.concat strs " ") "]"))
)
		
(lambda clone [val]
	(if (= (type val) :table)
		(do
			(local cloned {})
			(each [k v (pairs val)]
				(tset cloned k (clone v)))
			cloned)
		val)
)

(fn make-set [array]
	"convert a list of values into a
	 set--a table in which the values
		become keys that map to 'true'."
	(local result {})
	(each [_ v (pairs array)]
		(tset result v true))
	result
)

(fn point-inside [pt-x pt-y x y w h]
	"returns whether the given pt-x,pt-y  
	 coordinates are inside the given 
		half-open range."
	(and (>= pt-x x) (>= pt-y y)
		(< pt-x (+ x w))
		(< pt-y (+ y h)))
)

;; A widget is a box that has an 
;; identity and can meaningfully
;; be interacted with using the mouse.
(local Widget {})
(fn Widget.new 
	[name off-x-px off-y-px w-px h-px]
	(local the-widget {
		:name name
		:off-x-px off-x-px
		:off-y-px off-y-px
		:w-px w-px
		:h-px h-px
	})
	(setmetatable 
		the-widget {
			:__index Widget
			:__tostring t-to-str
		})
	the-widget
)

(fn which-over [x y widgets]
	"given an array of widgets, return the
	 first one in which the x y coords 
		are inside its half-open range. or
		return nil if the mouse isn't over one."
	(var result nil)
	(each [_ w (ipairs widgets) 
			&until result
		]
		(when 
			(point-inside x y 
				w.off-x-px w.off-y-px
				w.w-px w.h-px)
			(set result w)))
	result
)

(local Board {:mt {}})
(fn Board.coords [board-no]
	"static: get the x y coordinates of the
	 given board index. assumes one board
		per full screen on the world map."
	(local screen-row 
		(math.floor 
			(/ board-no screens-per-map-w)))
	(local screen-col
		(math.floor
			(% board-no screens-per-map-w)))
	 
	[(* screen-col board-w-t)
		(* screen-row board-h-t)]
)


(fn Board.load [board-no]
	(local [tl-x tl-y] 
		(Board.coords board-no))
	(local [br-x br-y]
	 [(- (+ tl-x board-w-t) 1) 
			(- (+ tl-y board-h-t) 1)])

	; stores an array of coordinates 
	; for each hole  
	; hole-id -> [x y]
	(local holes-to-coords [])

	; 2d maps a coordinate to a hole id
	; col -> row -> hole-id  
	(local coords-to-holes [])
	(for [x 1 board-w-t]
		(push coords-to-holes []))

 ; initialize both maps 
	(for [y tl-y br-y]
		(for [x tl-x br-x]
			(local sprite (mget x y))
			(local is-hole 
				(fget sprite bit-is-hole))
			(when is-hole 
				(push holes-to-coords [x y])
				(local hole-id (length holes-to-coords))
				(tset coords-to-holes x y hole-id))))

	(local holes [])
	; go back through every hole and 
	; determine its neighbors. build the 
	; hole structure 
	(each [id [x y] (ipairs holes-to-coords)]
		(local jump-overs [])
		(local sprite (mget x y))
		
		; check for nw <-> se jumpability
		(when
			(and
				(fget sprite bit-dir-nw)
				(fget sprite bit-dir-se)
			)
			(local nw-hole 
				(. coords-to-holes (- x 1) (- y 1)))
			(local se-hole
				(. coords-to-holes (+ x 1) (+ y 1)))
			(push jump-overs [nw-hole se-hole])
			(push jump-overs [se-hole nw-hole])
		)

		; check for ne <-> sw jumpability 
		(when
			(and 
				(fget sprite bit-dir-ne)
				(fget sprite bit-dir-sw)
			)
			(local ne-hole
				(. coords-to-holes (+ x 1) (- y 1)))
			(local sw-hole
				(. coords-to-holes (- x 1) (+ y 1)))
			(push jump-overs [ne-hole sw-hole])
			(push jump-overs [sw-hole ne-hole])
		)

		; check for w <-> e jumpability  
		(when 
			(and 
				(fget sprite bit-dir-w)
				(fget sprite bit-dir-e)
			)
			(local e-hole 
				(. coords-to-holes (+ x 2) y))
			(local w-hole 
				(. coords-to-holes (- x 2) y))
			(push jump-overs [e-hole w-hole])
			(push jump-overs [w-hole e-hole])
		)

		(local hole 
			{: id : x : y : jump-overs})
		(push holes hole)
	)

	(assert (<= (length holes) 64) 
		"no more than 64 holes permitted")

	(local board {
		: board-no
		: tl-x : tl-y : br-x : br-y
		: holes 
		:n-holes (length holes)
		: coords-to-holes
	})

	(setmetatable board 
		{:__tostring t-to-str
		 :__index Board.mt})

	board 
)

(fn unpack-empty-holes [state n-holes]
	"take a state bitmap and return an
	 array of holes that are empty."
	
	(assert (> n-holes 0))

	(local state-inv (bnot state))
	(local result [])
	(var hole 1)
	(while (<= hole n-holes)
		(local mask (lshift 1 (- hole 1)))
		(local res (band mask state-inv))
		(when (~= res 0)
			(push result hole)
		)
		(inc! hole)
	)

	result
)

(fn hole-filled-in-state? [hole state]
	(local mask (lshift 1 (- hole 1)))
	(~= 0 (band mask state))
)

(fn jump-holes [a b c state]
	(let [
			state1 (bxor state (lshift 1 (- a 1)))
		 state2 (bxor state1 (lshift 1 (- b 1)))
			state3 (bxor state2 (lshift 1 (- c 1)))
		]
		state3)
)



(fn Board.mt.solve [self]
	"compute solutions based on valid 
	 end-states. return the [dp count] in 
		the form dp :: state-bits -> moves-left"
	; map Bits -> MovesLeft 
	(local dp {})
	; [state moves-left]
	(local frontier [])

	(local max-mask 
		(lshift 1 (- self.n-holes 1)))
	(var count 0)

	(var hole-bit 1)
	(while (<= hole-bit max-mask)
		; (tset dp hole-bit 0)
		(push frontier [hole-bit 0])
		(set hole-bit (lshift hole-bit 1))
		(inc! count)
	)

	(while (> (length frontier) 0)
		(local [pattern left] (pop frontier))
		(inc! count)
		; TODO: replace with shorter left?
		(when (not (. dp pattern))
			(tset dp pattern left)
			(local holes 
				(unpack-empty-holes 
					pattern self.n-holes))
			(each [_ hole (ipairs holes)]
				(local jump-overs (. self :holes hole :jump-overs))
				(each [_ [a b] (ipairs jump-overs)]
					(when 
						(and a b 
							(hole-filled-in-state? a pattern)
							(not (hole-filled-in-state? hole pattern))
							(not (hole-filled-in-state? b pattern))
						)
						(local new-pattern 
							(jump-holes a hole b pattern))
						(when (not (. dp new-pattern))
							(push frontier [new-pattern (+ left 1)])
							))))
		)
	)
	[dp count] 
)

(fn Board.mt.px-to-tile [self px py]
	"convert pixel to tile coordinates"
	(local [screen-col screen-row]
		(Board.coords self.board-no))
	(local off-t-x 
		(* screen-col board-w-t))
	(local off-t-y
		(* screen-row board-h-t))
	(local this-screen-t-x
		(floor (/ px tile-w-px)))
	(local this-screen-t-y
		(floor (/ py tile-h-px)))
	[(+ off-t-x this-screen-t-x)
		(+ off-t-y this-screen-t-y)]
)




(local Game {:mt {}})


(fn Game.new [board-no]
	(local board (Board.load board-no))
	;; game state 
 (local state {
		: board-no
		: board 
		:n-moves 0 :undos 0 :hints 0
	})
	(setmetatable 
		state {
			:__index Game.mt
			:__tostring t-to-str
		})



	state 
)
	



(fn _G.BOOT []
	(global board (Board.load 0))
	(global [dp solcount] (board:solve))
	
)

(fn _G.TIC []
	(map 0 0)
	
	(var y 0)
	(print (.. "" solcount))
	
	; make cursor be the hand
	;(poke 0x3ffb 129)
	
	(let [[msx msy] (pack (mouse))]
		(print (strf "mouse: %d, %d" msx msy)
			0 128 12)) 
)


;; <TILES>
;; 001:eccccccccc888888caaaaaaaca888888cacccccccacc0ccccacc0ccccacc0ccc
;; 002:ccccceee8888cceeaaaa0cee888a0ceeccca0ccc0cca0c0c0cca0c0c0cca0c0c
;; 003:eccccccccc888888caaaaaaaca888888cacccccccacccccccacc0ccccacc0ccc
;; 004:ccccceee8888cceeaaaa0cee888a0ceeccca0cccccca0c0c0cca0c0c0cca0c0c
;; 017:cacccccccaaaaaaacaaacaaacaaaaccccaaaaaaac8888888cc000cccecccccec
;; 018:ccca00ccaaaa0ccecaaa0ceeaaaa0ceeaaaa0cee8888ccee000cceeecccceeee
;; 019:cacccccccaaaaaaacaaacaaacaaaaccccaaaaaaac8888888cc000cccecccccec
;; 020:ccca00ccaaaa0ccecaaa0ceeaaaa0ceeaaaa0cee8888ccee000cceeecccceeee
;; 049:0000000000000000000000000000000000033000003333000333333033333333
;; 064:0000000300000033000003330000333300003333000023330000223300002223
;; 065:3333333333333333333333333333333333333333333333333333333333333333
;; 066:3000000033000000333000003333000033330000333100003311000031110000
;; 067:0000000300000033000003330000333300002222000022220000222200002222
;; 068:3333333333333333333333333333333322222222222222222222222222222222
;; 069:3000000033000000333000003333000022220000222200002222000022220000
;; 070:0000000000000000000000000000000005666770056667700057770000566700
;; 071:3333333333999933399999833999998139999981399998813399881133331113
;; 080:0000222200000222000000220000000200000000000000000000000000000000
;; 081:3333333323333331223333112223311122221111022211100022110000021000
;; 082:1111000011100000110000001000000000000000000000000000000000000000
;; 083:0000000300000033000003330000333300033333003333330333333333333333
;; 084:3000000033000000333000003333000033333000333333003333333033333333
;; 085:3333333333333333333003333300003333000033333003333333333333333333
;; 086:0056670000566700005667000056670000566700005667000000000000000000
;; 096:3333333333333333333003333300003333000033333003333133333313333333
;; 097:3333333133333313333003333300003333000033333003333133333313333333
;; 098:3333333133333313333003333300003333000033333003333333333333333333
;; 099:3333333133333313333003333300003333000031333003333333333333333333
;; 100:3333333333333333333333333333333311111111333333333333333333333333
;; 101:1333333331333333333003333300003313000033333003333333333333333333
;; 102:1333333131333313333003333300003313000031333003333133331313333331
;; 103:1333333331333333333003333300003333000033333003333133331313333331
;; 112:3333333333333333333003333300003333000033333003333333331333333331
;; 113:1333333331333333333003333300003333000033333003333333331333333331
;; 114:1333333331333333333003333300003333000033333003333333333333333333
;; 115:3333333333333333333003333300003333000033333003333133331313333331
;; 116:3333333333333333333003333300003313000031333003333333333333333333
;; 117:1333333131333313333003333300003313000031333003333333333333333333
;; 118:1333333331333333333003333300003311000033333003333133331313333331
;; 119:3333333133333313333003333300003333000033333003333133331313333331
;; 128:3333333133333313333003333300003333000011333003333133331313333331
;; </TILES>

;; <MAP>
;; 003:000000000000000000000000000000000000000000001300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 004:000000000000000000000000000000000000000000353745000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 005:000000000000000000000000000000000000000035771476450000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 006:000000000000000000000000000000000000003508466646764500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 007:000000000000000000000000000000000000353646574657465645000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 008:000000000000000000000000000000000034444444444444444444540000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; </MAP>

;; <WAVES>
;; 000:00000000ffffffff00000000ffffffff
;; 001:0123456789abcdeffedcba9876543210
;; 002:0123456789abcdef0123456789abcdef
;; </WAVES>

;; <SFX>
;; 000:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000304000000000
;; </SFX>

;; <TRACKS>
;; 000:100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; </TRACKS>

;; <FLAGS>
;; 000:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000010000000000000000000000000001000000000000000000000125250d00034ff3300000000000000001131301394f437530000000000000000d300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; </FLAGS>

;; <PALETTE>
;; 000:1a1c2c5d275db13e53ef7d57ffcd75a7f07038b76425717929366f3b5dc941a6f673eff7f4f4f494b0c2566c86333c57
;; </PALETTE>

