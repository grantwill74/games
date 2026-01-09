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
(local button-height tile-h-px)
(local button-w-side-extra 3)

(local board-w-t 30)
(local board-h-t 17)
(local screens-per-map-w 8)
(local screen-w-t 30)
(local screen-h-t 17)

(local spr-marble 71)
(local spr-marble-in-hole 87)
(local spr-marble-ghost 55)
(local spr-marble-option 88)

(local spr-button-l 5)
(local spr-button-m 6)
(local spr-button-r 7)

(local anim-time-ms 333)
(local anim-height-px 8)

(local max-solve-depth-normal 16)
(local max-solve-depth-english 6)
(local forward-reachable-depth 8)

(global game {})

(fn sfx-select [] 
	(sfx 16 "C-4" 16 0 3))
(fn sfx-deselect [] 
	(sfx 17 "C-4" 16 0 3))
(fn sfx-jump []
	(sfx 18 "C-5" 64 0 3))
(local sfx-undo sfx-deselect)
 
(local board-names [
	"10-peg Triangle"
	"15-peg Triangle"
	"16-peg Diamond"
	"33-peg English Cross"
])

(local starting-states [
	0x2ff ; temporary
	0x3fff	; temporary
	0xbfff ; temporary
	0x1fffeffff
])

	(local english-cross-board-id 3)
	(local english-cross-holes 33)

; left middle right down 
(var last-mouse-state [false false false])

; only true if mouse went down this frame
(var mouse-click-down [false false false])

(fn poll-mouse []
	(let [ 
			[last-l last-m last-r] last-mouse-state
			[_ _ l m r] (pack (mouse))
			just-l (and l (not last-l))
			just-m (and m (not last-m))
			just-r (and r (not last-r))
		]
		(set mouse-click-down [just-l just-m just-r])
		(set last-mouse-state [l m r]))
)

(local mouse-l 1)
(local mouse-m 2)
(local mouse-r 3)

; for flickering graphics, keep track
; of the last flash
(var last-flash (time))
(var flash-duty-ms 200)
(var flash-state false)

(fn update-flash []
	(local now (time))
	(local time-since (- now last-flash))
	(when (> time-since flash-duty-ms)
		(set flash-state (not flash-state))
		(set last-flash now)
	)
)

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

(lambda point-inside [pt-x pt-y x y w h]
	"returns whether the given pt-x,pt-y  
	 coordinates are inside the given 
		half-open range."
	(and 
		(>= pt-x x)
		(>= pt-y y)
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
			(set result w.name)))
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
	(for [x -1 board-w-t]
		(push coords-to-holes []))
	; start at -1 to include left out of 
	; bounds column and first column.

 ; initialize both maps 
	(for [y tl-y br-y]
		(for [x tl-x br-x]
			(local sprite (mget x y))
			(local is-hole 
				(fget sprite bit-is-hole))
			(local off-x (- x tl-x))
			(local off-y (- y tl-y))

			(when is-hole 
				(push holes-to-coords [off-x off-y])
				(local hole-id (length holes-to-coords))
				(tset coords-to-holes off-x off-y hole-id))))

	(local holes [])
	; go back through every hole and 
	; determine its neighbors. build the 
	; hole structure 
	(each [id [x y] (ipairs holes-to-coords)]
		(local jump-overs [])
		(local sprite (mget (+ tl-x x) (+ tl-y y)))

		(local nw
			(. coords-to-holes (- x 1) (- y 1)))
		(local ne 
			(. coords-to-holes (+ x 1) (- y 1)))
		(local e
			(. coords-to-holes (+ x 2) y))
		(local se
			(. coords-to-holes (+ x 1) (+ y 1)))
		(local sw 
			(. coords-to-holes (- x 1) (+ y 1)))
		(local w 
			(. coords-to-holes (- x 2) y))

		; check for nw <-> se jumpability
		(when
			(and
				(fget sprite bit-dir-nw)
				(fget sprite bit-dir-se)
			)
			
			(push jump-overs [nw se])
			(push jump-overs [se nw])
		)

		; check for ne <-> sw jumpability 
		(when
			(and 
				(fget sprite bit-dir-ne)
				(fget sprite bit-dir-sw)
			)
			
			(push jump-overs [ne sw])
			(push jump-overs [sw ne])
		)

		; check for w <-> e jumpability  
		(when 
			(and 
				(fget sprite bit-dir-w)
				(fget sprite bit-dir-e)
			)
			
			(push jump-overs [e w])
			(push jump-overs [w e])
		)

		(local hole 
			{: id : x : y : jump-overs
			 : nw : ne : e : se : sw : w})
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

	(local result [])
	(var hole 1)
	(while (<= hole n-holes)
		(local mask (lshift 1 (- hole 1)))
		(local res (band mask state))
		(when (= res 0)
			(push result hole))
		(inc! hole))

	result
)

(fn unpack-filled-holes [state n-holes]
	"take a state bitmap and return an
	 array of holes that are filled."

		(assert (> n-holes 0))

		(local result [])
		(var hole 1)
		(while (<= hole n-holes)
			(local mask (lshift 1 (- hole 1)))
			(local res (band mask state))
			(when (~= res 0)
				(push result hole))
			(inc! hole))

			result
)

(fn hole-filled-in-state? [hole state]
	(local mask (lshift 1 (- hole 1)))
	(~= 0 (band mask state))
)

(fn jump [a b c state]
	(let [
			state1 (bxor state (lshift 1 (- a 1)))
		 state2 (bxor state1 (lshift 1 (- b 1)))
			state3 (bxor state2 (lshift 1 (- c 1)))
		]
		state3)
)


(fn complete-starting-frontier [n-holes]
	"build a frontier assuming any peg
	 remaining is okay."

		(local frontier [])
		(var max 0)

		(local max-mask 
			(lshift 1 (- n-holes 1)))

		(var hole-bit 1)
		(while (<= hole-bit max-mask)
			; (tset dp hole-bit 0)
			(push frontier [hole-bit 0])
			(set hole-bit (lshift hole-bit 1))
		)

		frontier
	)

(fn english-cross-frontier []
	"build a simpler frontier specifically
	 for the english cross board."

	; finishing marble can be in these holes:
	; 3, 6, 17, 28, and 31
	; so the lshift is 2, 5, 16, 27, and 30
	; because lua makes us count from 1
	(local frontier [
		[(lshift 1 2) 0]
		[(lshift 1 5) 0]
		[(lshift 1 16) 0]
		[(lshift 1 27) 0]
		[(lshift 1 30) 0]
	])

	frontier 
)


;; old version: too slow for english 
;; cross.
(fn Board.mt.solve [self max-depth]
	"generic solving function. 
		compute solutions based on valid 
	 end-states. return the [dp count max] 
		the form dp :: state-bits -> moves-left.
		count is the number of dp entries.
		max is the longest number of moves, which
		is used to locate valid starting states.
		max will always be <= max-depth"
	; map Bits -> MovesLeft 
	(local dp {})
	; [state moves-left]
	
	(var max 0)
	(var count 0)

	(local frontier
		(if (= self.board-no 3)
			(english-cross-frontier)
			(complete-starting-frontier
				self.n-holes)))

	(while (> (length frontier) 0)
		(local [pattern left] (pop frontier))
		(inc! count)

		(when (and 
				(not (. dp pattern))
				(< left max-depth)
			)

			(tset dp pattern left)
			(set max (math.max max left))
			(local marbles 
				(unpack-filled-holes 
					pattern self.n-holes))
			(local holes 
				(make-set
					(unpack-empty-holes 
						pattern self.n-holes)))
						
			(each [_ marble (ipairs marbles)]
				(local hole (. self.holes marble))
				(local dirs [:nw :ne :e :se :sw :w])
				(each [_ dir (ipairs dirs)]
					(local neigh 
						(when (. hole dir) 
							(. self.holes (. hole dir))))
					(local over-neigh 
						(when neigh
							(. self.holes (. neigh dir))))
					(when (and 
							neigh over-neigh
							(. holes neigh.id)
							(. holes over-neigh.id)
						) 
						(push frontier [
							(jump hole.id neigh.id
								over-neigh.id pattern)
							(+ left 1)
							]))
				))))
				
	(trace (strf "count is %d" count))

	[dp count max] 
)

(fn get-starting-states [moves-left dp]
	"scan through the DP array to find
	 those with the correct number of 
		moves-left, which are eligible to be
		starting states. results are sorted
		by state bitmap so that they will
		be deterministic."
	(local result [])
	(each [state left (pairs dp)]
		(when (= left moves-left)
			(push result state)))

	(table.sort result)
	result
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
;(fn Widget.new 
;	[name off-x-px off-y-px w-px h-px]
(fn Game.make-widget-for-hole 
	[board hole-no]
	"return a single widget whose name
	 will be the integer hole-no, and 
		with a little extra client area."

	(local hole-px-off -2)
	(local hole-px-dim-extra 
		(* 2 (math.abs hole-px-off)))

	(let [
			hole (. board :holes hole-no)
			tx (. hole :x)
			ty (. hole :y)
			px (+ (* tx tile-w-px) hole-px-off)
			py (+ (* ty tile-h-px) hole-px-off)
			w (+ tile-w-px hole-px-dim-extra) 
			h (+ tile-h-px hole-px-dim-extra)
		]
		(Widget.new hole-no px py w h))
)


(fn Game.make-widgets-for-holes [board]
	(icollect [hole-no _ (ipairs board.holes)]
		(Game.make-widget-for-hole board hole-no))
)

(fn all-full-state [n-holes]
	(local comp (- 64 n-holes))
	(lshift 0xFFFFFFFFFFFFFFFF comp)
)

(fn Game.new [board-no]
	(local board (Board.load board-no))

	(local solution-depth
		(if (< board-no 3)
			max-solve-depth-normal
			max-solve-depth-english))

	(local [dp solcount max-moves] 
		(board:solve solution-depth))
	;(local max-moves
	;	(- (length board.holes) 2))

	;(local dp nil) ; TODO solve

	;(local starting-states
	;	(get-starting-states max-moves dp))
	; now only one starting state per
	; board for performance
	;(local starting-state
	;	(. starting-states (+ 1 board-no)))
	
	(local starting-state 
		(. starting-states (+ 1 board-no)))

	(local hole-widgets
		(Game.make-widgets-for-holes board))

	;; game state 
 (local state {
		: board-no
		: board : dp : max-moves
		: starting-state
		: hole-widgets
		: solution-depth
		: forward-reachable-depth 
		:marble-in-hand nil 
		:state starting-state
		:n-moves 0 :undos 0 :hints 0
		:history []
	})
	(setmetatable 
		state {
			:__index Game.mt
			:__tostring t-to-str
		})
	state 
)

; board structure
; board {
;		: board-no
;		: tl-x : tl-y : br-x : br-y
;		: holes 
;		:n-holes (length holes)
;		: coords-to-holes
;	})

(fn Game.mt.get-hole [self hole-id]
	(. self :board :holes hole-id)
)

(fn Game.mt.draw-filled-pegs [self]
 "draw filled in pegs except for the one
	 in your hand or that we're animating to
		if any."
	(let [
			state (. self :state)
			board (. self :board)
			except-hand (. self :marble-in-hand)
			except-anim (-?> 
				self (. :anim) (. :to-hole))
			filled 
				(unpack-filled-holes 
					state (. board :n-holes))
		]
		(each [_ hole-id (ipairs filled)]
			(let [
					hole (self:get-hole hole-id)
					hole-x (. hole :x)
					hole-y (. hole :y)
				]
				(when 
					(and 
						(~= hole-id except-anim)
						(or (~= hole-id except-hand) 
							flash-state))
							
					(spr spr-marble-in-hole 
						(* hole-x tile-w-px)
						(* hole-y tile-h-px) 0))))
		) 
)


(fn Game.mt.draw [self]
	(map 
		(. self :board :tl-x)
		(. self :board :tl-y) 
		board-w-t board-h-t)

	(self:draw-filled-pegs)
)

(fn Game.mt.hole-under-pix [self px py]
	(which-over px py self.hole-widgets)
)

(fn Game.mt.reset-marble [self]
	(sfx-deselect)
	(tset self :marble-in-hand nil)
)

(fn Game.mt.grab-marble [self hole-no]
	(when
		self.marble-in-hand 
		(self:reset-marble))

	(sfx-select)
	(set self.marble-in-hand hole-no)
)


(fn potential-jump-destinations 
	[from-hole holes]
	"compute all the pegs we could jump into
	 if their destinations were free and there
		were a peg in the way. not all these
		moves are valid. result is a list of 
		{:from :to :over}."
	(local moves [])
	(each [_ {: id : jump-overs} (ipairs holes)]
		(each [_ [a b] (ipairs jump-overs)]
			(when (= a from-hole)
				(push moves {
					:from a :to b :over id
				}))))
	moves
)

(fn Game.mt.toggle-marble-in-hole 
	[self hole-no]

	(local bit (- hole-no 1))
	(set self.state
		(bxor self.state (lshift 1 bit)))
)

(fn Game.mt.marble-in-hole? [self hole]
	(local bit (- hole 1))
	(~= 0 (band self.state (lshift 1 bit)))
)


(fn Game.mt.valid-moves-from [self hole]
	(local potential	
		(potential-jump-destinations
			hole self.board.holes))

	(local moves
		(icollect [_ move (ipairs potential)]
			(when 
				(and 
					(self:marble-in-hole? move.over)
					(not 
						(self:marble-in-hole? move.to)))
				move)))
	
	moves 
)

(fn Game.mt.start-anim [self from to]
	(let [
			from-tx (. self.board.holes from :x)
			from-ty (. self.board.holes from :y)
			from-px (* from-tx tile-w-px)
			from-py (* from-ty tile-h-px)

			to-tx (. self.board.holes to :x)
			to-ty (. self.board.holes to :y)
			to-px (* to-tx tile-w-px)
			to-py (* to-ty tile-h-px)
		]
		(tset self :anim {
			: from-px : from-py : to-px : to-py
			:to-hole to 
			:start-time (time)
		}))
)

(fn Game.mt.stop-anim [self]
	(set self.anim nil)
)


(fn Game.mt.update-and-draw-anim [self]
	(local dtime 
		(math.min 
			anim-time-ms
			(- (time) self.anim.start-time)))

	(if 
		(= dtime anim-time-ms)
		(self:stop-anim)

		; the anim path is a parabola minus
		; the from-to line 
		; h(t) = at^2 + bt + c
		; h(0) = 0 => 0 = c
		; h(1) = 0 => a + b = 0 => b = -a
		; h(t) = at^2 - at
		; h(t) = -at(t - 1) = at(1 - t) 
		; h(0.5) = max-height
		; a(0.5)(1 - 0.5) = max-height 
		; a(0.5 - 0.25) = a*0.25 = max-height
		; a = 4 * max-height
		; h(t) = (4 * max-height) * t * (1 - t)

		(let [
				anim self.anim
				t (/ dtime anim-time-ms)
				anim-w (- anim.to-px anim.from-px)
				lirp-x (+ (* t anim-w) anim.from-px)
				
				anim-h (- anim.to-py anim.from-py)
				lirp-y (+ (* t anim-h) anim.from-py)

				y-off (* 4 anim-height-px t (- 1 t))
				y (- lirp-y y-off) ; +y goes down 
				; in pixel coords, our math assumed
				; that max-heigh was up, so we negate
			]
			(spr spr-marble lirp-x y 0))
	)
)

(fn Game.mt.try-make-move [self from to]
	"make a move if it's legal. do nothing
		except play a grumpy sound if not."
	(local moves 
		(self:valid-moves-from from))
	
	; find the move that goes from-to 
	(local over (. 
		(icollect [_ move (ipairs moves)]

			(when (and 
				(= move.from from)
				(= move.to to))
				move.over)
		) 1)) ; get first (and only if exists)

	(if
		over 
		(do
			(self:toggle-marble-in-hole to)
			(self:toggle-marble-in-hole from)
			(self:toggle-marble-in-hole over)
			(push self.history {
				: to : from : over
			})
			
			(self:start-anim from to)

			(local more-moves 
				(self:valid-moves-from to))

			(set self.marble-in-hand 
				(if 
					(>= (length more-moves) 1) 
						to

					; else 
					nil))

			(sfx-jump)

		))
)


(fn Game.mt.undo-move-if-exists [self]
	(when 
		(and
			self.history
			(> (length self.history) 0))

		(local {: from : to : over} 
			(pop self.history))
		(self:toggle-marble-in-hole to)
		(self:toggle-marble-in-hole from)
		(self:toggle-marble-in-hole over)
		(sfx-undo)

		(tset self :solution-unreachable
				(game.board:solution-unreachable 
			 	game.dp game.state
					game.forward-reachable-depth
					game.solution-depth))
	)
)

	; replace the directional hole numbers
	; with the actual hole structures
	;(local dirs [:nw :ne :e :se :sw :w])
	;(each [_ hole (ipairs holes)]
	;	(each [_ dir (ipairs dirs)]
	;		(tset hole dir (. holes (. hole dir)))))

; there's a refactoring opportunity. 
; maybe enumerating all possible moves
; so that in try-make-move we use that
; to determine if a move is valid. 
; replace valid-moves-from-marble, etc.
; this code is duplicated in solve.
; the difference is that this code moves
; forwards instead of backwards, but 
; since i xor the marble states it shouldn't
; matter.
(fn Board.mt.all-moves-from-state 
	[self state]

	(local marbles
		(unpack-filled-holes
			state self.n-holes))
	(local marbles-set (make-set marbles))
	(local moves [])
	(local holes (make-set self.holes))
	
	(each [_ marble (ipairs marbles)]
		(local hole (. self.holes marble))
		(local dirs [:nw :ne :e :se :sw :w])
		(each [_ dir (ipairs dirs)]
			(local neigh 
				(when (. hole dir) 
					(. self.holes (. hole dir))))
			(local over-neigh 
				(when neigh
					(. self.holes (. neigh dir))))
			(when (and 
					neigh over-neigh
					(. marbles-set neigh.id)
					(not (. marbles-set over-neigh.id)))
					(push moves {
						:over neigh.id
						:to over-neigh.id
						:from marble
					}))))
					
	moves
)

(fn Board.mt.solution-unreachable
	[self dp state move-depth solve-depth]
	"return whether we know for certain
	that no solution can be reached in the
	given move depth. nil if we don't know."

	(trace (strf "checking unreach: %d %d" move-depth solve-depth))

	(local n-moves-left (-
		(length (unpack-filled-holes
			state self.n-holes)) 1))

	(if 
		(<= move-depth 0) nil 

		(. dp state) false

		(<= (- n-moves-left move-depth) 
			solve-depth)
		(do 
			(local the-moves 
				(self:all-moves-from-state state))
			(var unreachable true)
			(trace (to-str the-moves))
			(each 
				[_ {: to : from : over} 
					(ipairs the-moves) &until 
					(not unreachable)]
				(local new-state 
					(jump to from over state))
				(set unreachable 
					(and unreachable 
						(self:solution-unreachable dp
							new-state (- move-depth 1) 
								solve-depth))))	
	  unreachable)

			nil	
		)
)


(fn do-button-click 
	[current-game button-id]
	(case button-id
			:undo
				(current-game:undo-move-if-exists)

			; these change the global game
			:peg10 (set game (Game.new 0))
			:peg15 (set game (Game.new 1))
			:diamond (set game (Game.new 2))
			:cross (set game (Game.new 3))
	)
)

(fn do-l-click [game msx msy buttons]
	(local hole 
		(game:hole-under-pix msx msy))

	(local btn-id (which-over msx msy buttons))
	
	(if 
		btn-id (do-button-click game btn-id)

		(not hole) (game:reset-marble)

		(and 
			hole 
			(not (game:marble-in-hole? hole)) 
			game.marble-in-hand)

		(do
			(game:try-make-move 
				game.marble-in-hand hole)
			(tset game :solution-unreachable
				(game.board:solution-unreachable 
			 	game.dp game.state
					game.forward-reachable-depth
					game.solution-depth)))


		(and 
			hole 
			(game:marble-in-hole? hole))

			(game:grab-marble hole))
)

(fn do-r-click [game _ _]
	(game:reset-marble)
)

(fn do-input [game buttons]
 (poll-mouse)
	(local [msx msy] (pack (mouse)))
	(local [l-down _ r-down] mouse-click-down)

	(if 
		l-down (do-l-click game msx msy buttons)
		r-down (do-r-click game)
	)
)

(fn draw-move-options [game]
		(local holes game.board.holes)
		(local moves 
			(game:valid-moves-from  
				game.marble-in-hand))

		(each [_ move (ipairs moves)]
			(local {: x : y} (. holes move.to))
			(local px (* x tile-w-px))
			(local py (* y tile-h-px))

			(when flash-state
				(spr spr-marble-option px py 0)))
)

(local Button {:mt {}})
(fn Button.new [x y w text id]
	(local the-button {
		: x : y 
		: text
		:widget 
			(Widget.new id
				(- x button-w-side-extra) y 
				(+ w (* 2 button-w-side-extra)) 
				button-height)
	})

	(setmetatable the-button {
		:__index Button.mt
		:__tostring to-str 
	})
)

(fn Button.mt.draw [self]
	(var x (- self.x tile-w-px))
	(local y self.y)

	(spr spr-button-l x y)
	(set x (+ tile-w-px))
	
	(local start-x x)
	(local max-x (+ x self.widget.w-px))
	(while (< x max-x)
		(spr spr-button-m x y)
		(set x (+ x tile-w-px))
	)

	(spr spr-button-r x y)

	(print self.text
		(+ start-x self.widget.off-x-px)
		(+ 1 self.widget.off-y-px) 12)
)


(fn draw-buttons [buttons]
	(each [_ btn (ipairs buttons)]
		(btn:draw))
)

(fn _G.BOOT []
	(set game (Game.new 0))

	(local btn-undo 
		(Button.new 8 64 24 "Undo" :undo ))

	(local btn-peg10
		(Button.new 8 96 36 
			"10 peg" :peg10))
	(local btn-peg15 
		(Button.new 8 104 36 
			"15 peg" :peg15))
	(local btn-diamond
		(Button.new 8 112 36
			"Diamond" :diamond))
	(local btn-cross
		(Button.new 8 120 36
			"Cross" :cross))

	(global global-buttons [
		btn-undo
		btn-peg10
		btn-peg15 
		btn-diamond
		btn-cross
	])

	(global global-widgets
		(icollect
			[_ btn (ipairs global-buttons)]
			btn.widget))

)


(fn _G.TIC []
	(do-input game global-widgets)
	(game:draw)
	(when game.anim
		(game:update-and-draw-anim))

	(draw-buttons global-buttons)

	(update-flash)

	(when game.marble-in-hand
		(draw-move-options game)
		; make cursor be the hand
	 (poke 0x3ffb 129)
	)

	(when game.solution-unreachable
		(print "Unwinnable" 0 40 12))

	; debug
	(let 
		[hole (game:hole-under-pix (mouse))]
		(when hole
			(print 
				(strf "hole %d" hole) 100 120 12)))
)


;; <TILES>
;; 001:eccccccccc888888caaaaaaaca8888808cacccccccacc0ccccacc0ccccacc0cc
;; 002:ccccceee8888cceeaaaa0cee888a0ceeccca0ccc0cca0c0c0cca0c0c0cca0c0c
;; 003:eccccccccc888888caaaaaaaca888888cacccccccacccccccacc0ccccacc0ccc
;; 004:ccccceee8888cceeaaaa0cee888a0ceeccca0cccccca0c0c0cca0c0c0cca0c0c
;; 005:0000000500000057000005770000067700000677000006770000008700000008
;; 006:6666666677777777777777777777777777777777777777777777777788888888
;; 007:6000000077000000777000007770000077700000778000007800000080000000
;; 017:cacccccccaaaaaaacaaacaaacaaaaccccaaaaaaac8888888cc000cccecccccec
;; 018:ccca00ccaaaa0ccecaaa0ceeaaaa0ceeaaaa0cee8888ccee000cceeecccceeee
;; 019:cacccccccaaaaaaacaaacaaacaaaaccccaaaaaaac8888888cc000cccecccccec
;; 020:ccca00ccaaaa0ccecaaa0ceeaaaa0ceeaaaa0cee8888ccee000cceeecccceeee
;; 038:3333333133333311333331113333111133333111333333103333333033333333
;; 048:1111222211100222110000221000000200000000000000000000000000000000
;; 049:0000000000000000000000000000000000033000003333000333333033333333
;; 050:3333333333333333333333333333333333312333331122333111222311112222
;; 051:2333333322333333222333332222333322222333022222330022222300022222
;; 052:3333333133333311333331113333111133311111331111103111110011111000
;; 053:3000000333000033333003333333333333333333333333333333333333333333
;; 054:2333333322333333222333332222333322233333023333330333333333333333
;; 055:0000000000989800098989800898989009898980089898900089890000000000
;; 064:0000000300000033000003330000333300002333000022330000222300002222
;; 065:3333333333333333333333333333333333333333333333333333333333333333
;; 066:3000000033000000333000003333000033310000331100003111000011110000
;; 067:0000000300000033000003330000333300002222000022220000222200002222
;; 068:3333333333333333333333333333333322222222222222222222222222222222
;; 069:3000000033000000333000003333000022220000222200002222000022220000
;; 070:0000000000000000000000000000000005666770056667700057770000566700
;; 071:0000000000999900099999900999999009999990099999900099990000000000
;; 080:0000222200000222000000220000000200000000000000000000000000000000
;; 081:2333333122333311222331112222111122221111022211100022110000021000
;; 082:1111000011100000110000001000000000000000000000000000000000000000
;; 083:0000000300000033000003330000333300033333003333330333333333333333
;; 084:3000000033000000333000003333000033333000333333003333333033333333
;; 085:3333333333333333333003333300003333000033333003333333333333333333
;; 086:0056670000566700005667000056670000566700005667000000000000000000
;; 087:0000000000999900099999800999998109999981009998110001111000000000
;; 088:0000000000222200022222100222221702222217002221770007777000000000
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
;; 129:3333333333333333333003333300003333000033333003333333333333333333
;; 130:1333333131333313333003333300003333000011333003333333331333333331
;; 131:1333333131333313333003333300003311000033333003333133333313333333
;; 132:1333333131333313333003333300003333000033333003333333333333333333
;; 133:3333333133333313333003333300003333000011333003333333331333333331
;; 134:1333333331333333333003333300003311000033333003333133333313333333
;; 135:1333333331333333333003333300003333000033333003333133333313333333
;; 144:1333333131333313333003333300003333000033333003333133333313333333
;; 145:1333333131333313333003333300003333000033333003333133331313333331
;; 146:1333333331333333333003333300003333000033333003333133331313333331
;; 147:1333333131333313333003333300003333000033333003333333333333333333
;; 148:1333333131333313333003333300003333000033333003333333331333333331
;; 149:1333333331333333333003333300003333000033333003333133333313333333
;; 150:3333333133333313333003333300003333000033333003333333331333333331
;; 151:1333333131333313333003333300003333000033333003333333331333333331
;; </TILES>

;; <MAP>
;; 002:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000130000000000000000000000000000000000000000000000000000000000130000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 003:000000000000000000000000000000000000000000001300000000000000000000000000000000000000000000000000000035374500000000000000000000000000000000000000000000000000000035374500000000000000000000000000000000000000000000000000130000001300000000000000000000000000000000000000000000000000130000001300000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 004:000000000000000000000000000000000000000000353745000000000000000000000000000000000000000000000000003577467645000000000000000000000000000000000000000000000000003577467645000000000000000000000000000000000000000000000035374500353745000000000000000000000000000000000000000000000035374500353745000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 005:000000000000000000000000000000000000000035774676450000000000000000000000000000000000000000000000350846664676450000000000000000000000000000000000000000000000350846664676450000000000000000000000000000000000000000003577142953771476450000000000000000000000000000000000000000003577142953771476450000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 006:000000000000000000000000000000000000003508466646764500000000000000000000000000000000000000000035084666466646764500000000000000000000000000000000000000000004584666466646682400000000000000000000000000000000000000046914191419141914782400000000000000000000000000000000000000046914191419141914782400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 007:000000000000000000000000000000000000353646574657465645000000000000000000000000000000000000003536465746574657465645000000000000000000000000000000000000000005332846664638432500000000000000000000000000000000000000053379141914191409432500000000000000000000000000000000000000053379141914191409432500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 008:000000000000000000000000000000000034444444444444444444540000000000000000000000000000000000344444444444444444444444540000000000000000000000000000000000000000053328463843250000000000000000000000000000000000000000000563191419141962250000000000000000000000000000000000000000000563791419141962250000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 009:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000533484325000000000000000000000000000000000000000000003577141914191429450000000000000000000000000000000000000000003514147914191429450000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 010:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005152500000000000000000000000000000000000000000000046914191419141914782400000000000000000000000000000000000000041414141479141914782400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 011:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000053349140923491409432500000000000000000000000000000000000000053314141423491409432500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 012:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000533484303333943250000000000000000000000000000000000000000000533144303333943250000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 013:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000005152500051525000000000000000000000000000000000000000000000005152500051525000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; </MAP>

;; <WAVES>
;; 000:00000000ffffffff00000000ffffffff
;; 001:0123456789abcdeffedcba9876543210
;; 002:0123456789abcdef0123456789abcdef
;; </WAVES>

;; <SFX>
;; 000:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000304000000000
;; 016:00000000000000400040004000c000c000c000c000c000c000c000c000c000c000000000000000000000000000000000000000000000000000000000300000000000
;; 017:00c000c000c0004000400040000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000400000000000
;; 018:00002000302040206000700080009000a000b000c000d000e000e000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000f000460000000000
;; 028:000000000040004000700070004000400000000000000000000000000000000000000000000000000000000000000000000000000000000000000000340000000000
;; </SFX>

;; <TRACKS>
;; 000:100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; </TRACKS>

;; <FLAGS>
;; 000:000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000001000101000000000000000125250d00034ff3300000000000000001131301394f437530000000000000000d310f17670d13632000000000000000072733370713251710000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; </FLAGS>

;; <PALETTE>
;; 000:1a1c2c5d275db13e53ef7d57ffcd75a7f07038b76425717929366f3b5dc941a6f673eff7f4f4f494b0c2566c86333c57
;; </PALETTE>

