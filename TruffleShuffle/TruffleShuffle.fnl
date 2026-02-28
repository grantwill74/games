;; title:   Truffle Shuffle 
;; author:  Grant Williams
;; desc:    A game inspired by mine-sweeper
;; site:    grantwilliams.info/games
;; license: MIT License (change this to your license of choice)
;; version: 0.1
;; script:  fennel
;; strict:  true
;; saveid: swinesweeper
;; input: gamepad

; bug todos
; TODO fix screen tearing on fall

; refactor todos
; TODO refactor anims and tile transitions into GameMap

; feature todos 
; TODO add thump on fall
; TODO add square highlight
; TODO add lives
; TODO add gameover state
; TODO add next level state
; TODO add congratulations state



; common aliases
(local push table.insert)
(local pop table.remove)
(local pack table.pack)
(local unpack table.unpack)
(local str_join #(table.concat $1 " "))
(local strf string.format)

; utilities
(macro inc! [x] `(set ,x (+ 1 ,x)))
(macro dec! [x] `(set ,x (- ,x 1)))

(fn clamp [x lo hi] (if (<= x lo) lo (>= x hi) hi x))
(fn empty? [list] (= (length list) 0))
(fn not_empty? [list] (> (length list) 0))

(fn to_str [thing]
    (case (type thing)
        :table 
        (if (~= nil (. thing 1)) 
            (.. "[" (str_join
                (icollect [_ v (ipairs thing)] 
                    (to_str v))) "]")
            
            ;else
            (.. "{" (str_join
                (icollect [k v (pairs thing)] 
                    (.. (to_str k) " " (to_str v)))) "}"))

        :string (.. "\"" thing "\"")

        other (tostring thing))
)

; constants
(local [DIR_N DIR_E DIR_S DIR_W] [1 2 3 4])
(local DIR_NAMES [:n :e :s :w])

(local [MAP_W MAP_H] [30 17])

(local [TILE_W_PX TILE_H_PX] [8 8])

; half of a tile offsets, used when drawing characters centered
(local H_TILE_W_PX_OFF (- (/ TILE_W_PX 2)))

(local [FIELD_X_T FIELD_Y_T] [11 1]) ; gamefield top left x and y coords 
(local [FIELD_W_T FIELD_H_T] [18 15])
(local EPS (/ 1 1024)) 

(local [BTN_UP BTN_DOWN BTN_LEFT BTN_RIGHT] [1 2 3 4])
(local [BTN_A BTN_B BTN_X BTN_Y] [5 6 7 8])

(local TICS_PER_SEC 60)
(local TICS_PER_MS (/ TICS_PER_SEC 1000))
(local MS_PER_TIC (/ 1 TICS_PER_MS))

; coordinates to draw truffles
(local SIDE_W_T 10) ; the side bar is this wide in tiles

(local [TRUFFLE_DISPLAY_PX TRUFFLE_DISPLAY_PY] [0 32])
(local [FLAG_DISPLAY_PX FLAG_DISPLAY_PY] [0 24])
(local [LEVEL_DISPLAY_PX LEVEL_DISPLAY_PY] [2 48])
(local [STATUS_DISPLAY_PX STATUS_DISPLAY_PY] [2 56])

(local [KEYS_DISPLAY_PX KEYS_DISPLAY_PY] [2 72])
(local [KEYS_DIG_DISPLAY_PX KEYS_DIG_DISPLAY_PY] [4 80])
(local [KEYS_FLAG_DISPLAY_PX KEYS_FLAG_DISPLAY_PY] [4 88])

(local [PAD_DISPLAY_PX PAD_DISPLAY_PY] [2 96])
(local [PAD_DIG_DISPLAY_PX PAD_DIG_DISPLAY_PY] [4 104])
(local [PAD_FLAG_DISPLAY_PX PAD_FLAG_DISPLAY_PY] [4 112])

; in tiles per second
(local MOVE_SPEED_TPS 6)

; in tiles per tic
(local MOVE_SPEED (/ MOVE_SPEED_TPS TICS_PER_SEC))


; default animation frame delay in millis
(local DEF_DELAY_MS 100)

; time between auto-dig generations (i.e., concentric rings of digging that 
; are triggered by finding a hole with no hazards next to it)
(local AUTO_DIG_GEN_TIME_MS 200)

; special anim time for highlight animation beneath pig
(local HILITE_DELAY_MS 500)

; how long to stand in the air like wile e. coyote
(local FALL_DELAY_MS 1000)
(local FALL_TIME_MS 3000)
(local FALL_SPEED_PX_SEC 16)
(local FALL_SPEED_PX_TIC (/ FALL_SPEED_PX_SEC TICS_PER_SEC))
(local STATUS_TIME 2000)

(local DIGITS [128 129 130 131 132 133 134 135])
(local IS_DIGIT (collect [_ v (ipairs DIGITS)] v true))

; map tile types
(local DIRT_TILE 108)
(local HOLE_TILE 136)
(local TRUFFLE_TILE 137)

(local FLAG_SPRITE 148)
(local FLAG_TILE 149)

(local EMPTY 0)
(local HOLE -1)
(local TRUFFLE -2)
(local FLAG -3)

(local SFX_TRUFFLE 32)
(local SFX_DIG 33)
(local SFX_AUTODIG 34)
(local SFX_SAD 35)
(local SFX_GOODFLAG 36)
(local SFX_FALL 37)

(local SFX_AUTODIG_CHANNEL 2)
(local SFX_FALL_CHANNEL 0)

(local SPR_HAPPY_PIG 2)
(local SPR_SAD_PIG 4)




(local AppState {:mt {}})
(fn AppState.new []
    (local ev {
        :pad_just_pressed [false false false false false false false false]
        :pad_state [false false false false false false false false]

        :time (time)
        :dtime 0 ; time since last frame in millis
    })
    (setmetatable ev {
        :__index AppState.mt
        :__tostring to_str
    })
    ev 
)

(lambda AppState.mt.poll [self]
    (set self.pad_just_pressed [
        (btnp 0) (btnp 1) (btnp 2) (btnp 3)
        (btnp 4) (btnp 5) (btnp 6) (btnp 7)
    ])

    (set self.pad_state [
        (btn 0) (btn 1) (btn 2) (btn 3)
        (btn 4) (btn 5) (btn 6) (btn 7)
    ])

    (local old_time self.time)
    (set self.time (time))
    (set self.dtime (- self.time old_time))
)

(fn AppState.mt.action_button_down [self]
    (or 
        (. self.pad_state BTN_A)
        (. self.pad_state BTN_B)
        (. self.pad_state BTN_X)
        (. self.pad_state BTN_Y))
)

(fn AppState.mt.dig_button_pressed [self]
    (or 
        (. self.pad_just_pressed BTN_A)
        (. self.pad_just_pressed BTN_X))
)

(fn AppState.mt.flag_button_pressed [self]
    (or 
        (. self.pad_just_pressed BTN_B)
        (. self.pad_just_pressed BTN_Y))
)

; Animation related things ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(local Anim {:mt {}})
(fn Anim.frame [tile_no delay x_off y_off]
    (local delay (or delay DEF_DELAY_MS))
    (local x_off (or x_off 0))
    (local y_off (or y_off 0))

    (assert (> delay 0))
    
    { : tile_no : delay : x_off : y_off }
)

(fn Anim.from_frame_nos [frames]
    (Anim.from_frame_nos_delay DEF_DELAY_MS frames)
)

(fn Anim.from_frame_nos_delay [delay frames]
    (icollect [_ frame_no (ipairs frames)]
        (Anim.frame frame_no delay))
)

(local ANIMS {
    :player_head {
        :n (Anim.from_frame_nos [40 41])
        :e (Anim.from_frame_nos [36 37])
        :s (Anim.from_frame_nos [32 33])
        :w (Anim.from_frame_nos [44 45])
    }

    :player_body {
        :n (Anim.from_frame_nos [56 57 58 59])
        :e (Anim.from_frame_nos [52 53 54 55])
        :s (Anim.from_frame_nos [48 49 50 51])
        :w (Anim.from_frame_nos [60 61 62 63])
    }

    :dig (Anim.from_frame_nos [160 161 162 163])
})

(set Anim.State {:mt {}})
(lambda Anim.state [frames loop] 
    (local state {
        :current_frame_no 1
        :progress 0
        :n_frames (length frames)
        : frames
        : loop
        :finished false
    })
    (setmetatable state {
        :__index Anim.State.mt
        :__tostring to_str
    })
    state
)

(lambda Anim.State.mt.tick [self amount]
    (set self.progress (+ self.progress amount))
    
    (while (>= self.progress (self:delay))
        (inc! self.current_frame_no)
        (when (> self.current_frame_no self.n_frames)
            (if self.loop (set self.current_frame_no 1)
                
                ;else 
                (set self.finished true)
            )
            
            (set self.current_frame_no 
                (if self.loop 1 self.n_frames)))
        
        (set self.progress (- self.progress (self:delay))))
)


(lambda Anim.states_tick [states amount] 
    (each [_ state (pairs states)]
        (state:tick amount))
)

(fn Anim.State.mt.current_frame [self]
    (. self.frames self.current_frame_no)
)

(fn Anim.State.mt.delay [self] 
    "total time to spend on the current frame"
    (. (self:current_frame) :delay)
)

(fn Anim.State.mt.draw [self xpx ypx]
    "draw the current frame at a given position"
    (local x (+ xpx (. (self:current_frame) :x_off)))
    (local y (+ ypx (. (self:current_frame) :y_off)))
    (spr (. (self:current_frame) :tile_no) x y 0)
)

(fn Anim.State.mt.reset [self] 
    "start idling (reset to first frame, zero progress)"
    (set self.current_frame_no 1)
    (set self.progress 0)
)
; ~Animations ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; GameMap ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(local GameMap {:mt {}})
(fn GameMap.gen [seed n_truffles n_holes]
    (math.randomseed seed)
    (local map [])

    (local max_row (- FIELD_H_T 2))
    (local max_col (- FIELD_W_T 2))

    (for [r 1 max_row]
        (local row [])
        (for [c 1 max_col]
            (push row 0))
        (push map row))

    ; really don't want more than half of the tiles to be filled for
    ; the sake of having the mapgen be completable given its non-determinism
    (local total_tiles (* max_row max_col))
    (assert (< (+ n_truffles n_holes) (/ total_tiles 2))
        "too many objects in field. limit: truffles + holes < total_tiles / 2")

    (var truffles 0)
    (while (< truffles n_truffles)
        (local row (math.random 1 max_row))
        (local col (math.random 1 max_col))
        (when (= (. map row col) EMPTY)
            (tset map row col TRUFFLE)
            (inc! truffles)))

    (var holes 0)
    (while (< holes n_holes)
        (local row (math.random 1 max_row))
        (local col (math.random 1 max_col))
        (when (= (. map row col) EMPTY)
            (tset map row col HOLE)
            (inc! holes)))

    (setmetatable map {
        :__index GameMap.mt
        :__tostring to_str
    })
    map 
)

(fn GameMap.mt.at [self x y]
    "Gets the map cell at position x y or nil if it is out of bounds"
    (-?> (. self y) (. x))
)

(fn GameMap.clamp_to_bounds [tx ty]
    (local tx (clamp tx 1 (- FIELD_W_T 1)))
    (local ty (clamp ty 1 (- FIELD_H_T 1)))
    [tx ty]
)

(fn field_coords_to_map_coords [tx ty]
    [(+ FIELD_X_T tx) (+ FIELD_Y_T ty)]
)

(fn field_coords_to_pixels [tx ty]
    [
        (* (+ FIELD_X_T tx) TILE_W_PX)
        (* (+ FIELD_Y_T ty) TILE_H_PX)
    ]
)

(fn dug? [tx ty]
    (local [mx my] (field_coords_to_map_coords tx ty))
    (local val (mget mx my))
    (or (= val DIRT_TILE) 
        (= val TRUFFLE_TILE)
        (. IS_DIGIT val))
)

(fn flagged? [tx ty]
    (local [mx my] (field_coords_to_map_coords tx ty))
    (local val (mget mx my))
    (= val FLAG_TILE)
)

(fn GameMap.mt.neighbors [self x y]
    "Returns an array of the in-bound neighbors of tile x,t"
    (local potential [
        [(- x 1) (- y 1)]
        [x (- y 1)]
        [(+ x 1) (- y 1)]

        [(- x 1) y]
        [(+ x 1) y]

        [(- x 1) (+ y 1)]
        [x (+ y 1)]
        [(+ x 1) (+ y 1)]
    ])

    (icollect [_ [x y] (ipairs potential)]
        (when (self:at x y) [x y]))
)

(fn GameMap.mt.vicinity_count [self x y]
    "returns the number of [truffles holes] that are adjacent to [x y]"
    (var truffles 0)
    (var holes 0)
    (fn count_elem [x y] 
        (match (self:at x y)
            TRUFFLE (inc! truffles)
            HOLE (inc! holes))
    )

    (each [_ [nx ny] (ipairs (self:neighbors x y))]
        (count_elem nx ny)
    )

    [truffles holes]
)
; ~ GameMap ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;

; Actor; ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(local Actor {:mt {}})
(fn Actor.new [x y]
    "create a new actor with given world (field) coordinates"
    (local actor {
        :dir :s
        : x : y
        :anim_state {
            :head (Anim.state ANIMS.player_head.s true)
            :body (Anim.state ANIMS.player_body.s true)
        }
    })

    (setmetatable actor {
        :__index Actor.mt
        :__tostring to_str
    })
)

(fn Actor.mt.face [self dir]
    (local head (. ANIMS.player_head dir))
    (local body (. ANIMS.player_body dir))

    (set self.anim_state.head (Anim.state head true))
    (set self.anim_state.body (Anim.state body true))

    (set self.dir dir)
)

(fn Actor.mt.idle [self]
    (self.anim_state.head:reset)
    (self.anim_state.body:reset)
)

(fn Actor.mt.translate [self tx ty]
    (set self.x (+ self.x tx))
    (set self.y (+ self.y ty))
)

(fn Actor.mt.warp [self tx ty]
    (set self.x tx)
    (set self.y ty)
)

(fn Actor.mt.move [self tx ty]
    "move in a direction and update facing"
    (local dir1 (if (> tx 0) :e (< tx 0) :w))
    (local dir2 (if (> ty 0) :s (< ty 0) :n))

    ; keep dir the same as long as it matches one of the directions being
    ; pressed. otherwise change it with preference to north/south
    (local new_dir (if
        (or (= self.dir dir1) (= self.dir dir2)) self.dir
        dir1 dir1
        dir2 dir2
        self.dir))

    (when (~= self.dir new_dir)
        (self:face new_dir))

    (self:translate tx ty)
)

(fn Actor.mt.field_coords [self]
    [(math.floor self.x) (math.floor self.y)]
)

(fn Actor.mt.map_coords [self]
    (field_coords_to_map_coords self.x self.y)
)

(fn Actor.mt.base_pixel_coords [self]
    (field_coords_to_pixels self.x self.y)
)

(fn Actor.mt.tick [self]
    (Anim.states_tick self.anim_state MS_PER_TIC)
)

(fn Actor.mt.body_pixel_coords [self]
    (local [bx by] (self:base_pixel_coords))
    (local body_x (+ bx H_TILE_W_PX_OFF))
    (local body_y (- by TILE_H_PX))
    [body_x body_y]
)

(fn Actor.mt.draw [self]
    (local [bodyx bodyy] (self:body_pixel_coords))

    ; the head is one tile above the body
    (local heady (- bodyy TILE_H_PX))

    (self.anim_state.head:draw bodyx heady)
    (self.anim_state.body:draw bodyx bodyy)

    ; debugging: draw the true coordinates
    ; (local [base_x base_y] (self:base_pixel_coords))
    ; (spr 24 base_x base_y 0)
)
;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;


; GameState ;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;;
(local GameState {:mt {}})
(fn GameState.new [level seed] 
    ; for each tile we store an animation state
    ; each row is an empty table that will be filled when tiles are digged 
    (local dig_anims [])
    (for [row 1 (- FIELD_W_T 1)]
        (push dig_anims {})
    )
    
    
    (local state {
        :pig (Actor.new 1 1)
        :map (GameMap.gen seed 3 10)
        
        : dig_anims

        ; when a dig triggers other digs automatically because there are no 
        ; holes in the area
        :auto_digs [] ; stores [anim_state x y] for auto-dug tiles

        :first_dig true ; is it the first dig? (hole converted to truffle)
        :last_dig_time 0 ; time of last dig

        :truffles_gotten 0
        :n_flags 3
        :lives_remaining 3

        ; if falling, this will be the time it started 
        :falling_start nil

        ; if falling, this will be the [map map] where the hole was 
        :falling_pos nil 

        ; status display as a [message, time_left] tuple
        :status nil 

        : level
    })

    (setmetatable state {
        :__index GameState.mt
        :__tostring to_str
    })

    state
)

(fn GameState.mt.post_status [self message time_left]
    (set self.status [message (or time_left STATUS_TIME)])
)

(fn gen_auto_digs [map start_time tx ty]
    "find all the cells from tx ty that can be auto dug.
     returns [time x y] triples in an array for all the diggable tiels."    

    (local result [])

    (local searched {})
    (fn searched? [x y] (. searched (+ (lshift y 32) x)))
    (fn searched! [x y] (tset searched (+ (lshift y 32) x) true))

    ; goofy queue: just use an index to the first element which only
    ; increases. fine if our size is limited and we free all at once.
    (local frontier [[start_time tx ty]])
    (var i 1)
    (var front_size 1)

    (while (> front_size 0)
        (local [time fx fy] (. frontier i))
        (inc! i)
        (dec! front_size)

        (when (not (searched? fx fy))
            (searched! fx fy)
            (local next_time (+ time AUTO_DIG_GEN_TIME_MS))
            (local [_ holes_next_to] (map:vicinity_count fx fy))
            (push result [time fx fy])
            (local safe (= holes_next_to 0))

            (when safe 
                (local neighbors (map:neighbors fx fy))
                (each [_ [nx ny] (ipairs neighbors)]
                    (when (not (searched? nx ny))
                        (push frontier [next_time nx ny])
                        (inc! front_size)
                    )
                )
            )
        )
    )

    result
)

(fn GameState.mt.truffle_get [self tx ty appstate]
    (inc! self.truffles_gotten)
    (tset self :map ty tx EMPTY)
    (sfx SFX_TRUFFLE "C-5" 64)
)

(fn draw_repeated_sprite [count sprite px_left py transparent_idx]
    (var px px_left)

    (for [which_one 0 (- count 1)]
        (spr sprite px py transparent_idx)
        (set px (+ px TILE_W_PX)))
)

(fn GameState.mt.draw_truffles [self]
    (draw_repeated_sprite self.truffles_gotten TRUFFLE_TILE 
        TRUFFLE_DISPLAY_PX TRUFFLE_DISPLAY_PY 0)
)

(fn GameState.mt.draw_flags [self]
    (draw_repeated_sprite self.n_flags FLAG_SPRITE
        FLAG_DISPLAY_PX FLAG_DISPLAY_PY 0)
)

(fn GameState.mt.tick_dig_anims [self dtime]
    (for [row 2 (- FIELD_H_T 1)]
        (for [col 2 (- FIELD_W_T 1)]
            (local state (. self.dig_anims row col))
            (when state 
                (local [px py] (field_coords_to_map_coords col row))
                (state:tick dtime)
            )
        )
    )
)

(fn GameState.mt.draw_dig_anims [self]
    (for [row 2 (- FIELD_H_T 1)]
        (for [col 2 (- FIELD_W_T 1)]
            (local state (. self.dig_anims row col))
            (when (and state (not state.finished))
                (local [px py] (field_coords_to_pixels col row))
                (state:draw px py)
            )
        )
    )
)

(fn GameState.mt.add_dig_anim [self xt yt]
    (local anim (Anim.state ANIMS.dig))
    (tset self.dig_anims yt xt anim)
)

(fn GameState.mt.tick_auto_digs [self time command]
    (local auto_digs_to_keep [])
    
    (each [_ [anim_state start_time x y] (ipairs self.auto_digs)]
        (when (not anim_state.finished)
            (when (>= time start_time)
                ; on the first tick, set the command
                (when (= anim_state.current_frame_no 1)
                    (push command.auto_digs [x y]))
                (anim_state:tick MS_PER_TIC)
            )
            (push auto_digs_to_keep [anim_state start_time x y])
        )
    )

    (set self.auto_digs auto_digs_to_keep)
)

(fn GameState.mt.draw_auto_digs [self time]
    (each [_ [anim_state start_time x y] (ipairs self.auto_digs)]
        (when (>= time start_time)
            (local px (* TILE_W_PX (+ FIELD_X_T x)))
            (local py (* TILE_H_PX (+ FIELD_Y_T y)))
            (anim_state:draw px py)
        )
    )
)

(fn GameState.mt.tick_status [self]
    (when self.status
        (local [msg time_left] self.status)
        (tset self :status 2 (- time_left MS_PER_TIC))
        (when (< (. self :status 2) 0)
            (set self.status nil)
        )
    )
)

(fn GameState.mt.draw_status [self]
    (when self.status
        (local [msg _] self.status)
        (print msg STATUS_DISPLAY_PX STATUS_DISPLAY_PY 12)
    )
)

(fn GameState.mt.move [self dx dy]
    (self.pig:move dx dy)
    (local [posx posy] [self.pig.x self.pig.y])
    (local [posx posy] (GameMap.clamp_to_bounds posx posy))
    (self.pig:warp posx posy)
)

(fn GameState.mt.draw [self time]
    (map) ; draw the map to clear the screen no matter what
    (self:draw_truffles)
    (self:draw_flags)
    (self:draw_status)
    (print (strf "Level %d" self.level) LEVEL_DISPLAY_PX LEVEL_DISPLAY_PY 12)
    (print "Keyboard:" KEYS_DISPLAY_PX KEYS_DISPLAY_PY 12)
    (print "Dig: z" KEYS_DIG_DISPLAY_PX KEYS_DIG_DISPLAY_PY 12)
    (print "Flag: x" KEYS_FLAG_DISPLAY_PX KEYS_FLAG_DISPLAY_PY 12)
    (print "Gamepad: " PAD_DISPLAY_PX PAD_DISPLAY_PY 12)
    (print "Dig: a" PAD_DIG_DISPLAY_PX PAD_DIG_DISPLAY_PY 12)
    (print "Flag: b" PAD_FLAG_DISPLAY_PX PAD_FLAG_DISPLAY_PY 12)


    ; draw the part of the map before player
    (local [_ py] (self.pig:map_coords))
    (local py (math.ceil py))

    (if (not self.falling_start)
        (do (self.pig:draw)
            (self:draw_auto_digs time)
            (self:draw_dig_anims)
        )

        ; else, falling
        (do (local [mapx mapy] self.falling_pos)
            (self.pig:draw)
            ; draw with colorkey 0 = trans
            (local map_height (+ 1 (- MAP_H mapy)))
            (map 0 mapy MAP_W map_height 
                0 (* mapy TILE_H_PX) 0)
        )
    )
)

; We don't want the gamestate to ever be mutated mid-frame. Instead, store a
; set of changes to make on frame-end. 
(local GameCommand {})
(fn GameCommand.new [] {
    :movehoriz 0    ; amount to move horizontally in pixels
    :movevert 0     ; amount to move vertically in pixels
    :dig false      ; replace with true to dig under the player
    :flag false 
    :auto_digs []   ; [x y] list of auto-dig tiles
})

(fn poll_buttons [appstate com]
    "update the command to reflect what the buttons say to do"
    (set com.dig (appstate:dig_button_pressed))
    (set com.flag (appstate:flag_button_pressed))

    (let [
        west_speed (if (. appstate.pad_state BTN_LEFT) -1 0)
        east_speed (if (. appstate.pad_state BTN_RIGHT) 1 0)
        horiz_speed (* MOVE_SPEED (+ west_speed east_speed))

        north_speed (if (. appstate.pad_state BTN_UP) -1 0)
        south_speed (if (. appstate.pad_state BTN_DOWN) 1 0)
        vert_speed (* MOVE_SPEED (+ north_speed south_speed))
    ]
        (set com.movehoriz horiz_speed)
        (set com.movevert vert_speed)
    )
)

(fn apply_command [command gamestate appstate]
    (local xt command.movehoriz)
    (local yt command.movevert)
    (local st gamestate)

    ; we're idling
    (when (and (= xt 0) (= yt 0))
        (st.pig:idle)
    )

    ; can't dig and flag at the same time. prefer digging.
    (when (and command.dig command.flag) (set command.flag false))

    (local [tx ty] (gamestate.pig:field_coords))

    (fn dig [tx ty]
        (local [mapx mapy] [(+ FIELD_X_T tx) (+ FIELD_Y_T ty)])
        (local [truffles holes] (gamestate.map:vicinity_count tx ty))
        (local val (gamestate.map:at tx ty))

        (local tile 
            (if (= val HOLE)    HOLE_TILE
                (= val TRUFFLE) TRUFFLE_TILE
                (= holes 0)     DIRT_TILE
                (> holes 0)     (. DIGITS holes)))
        
        (when (not (dug? tx ty))
            (mset mapx mapy tile))

        (when (= val TRUFFLE)
            (gamestate:truffle_get tx ty appstate))
    )

    ; time to dig
    (when command.dig
        (local val (gamestate.map:at tx ty))

        ; when the first tile we dig is a hole, it becomes a truffle
        (when (or (and (= val HOLE) gamestate.first_dig))
            (gamestate:truffle_get tx ty appstate)
            ; play sfx
        )

        (when (not (dug? tx ty))
            (dig tx ty)

            ; hide value in case we dug a hole first try
            (local val (gamestate.map:at tx ty))

            ; add autodigs: if the tile had no neighbors, we also search all the
            ; reachable tiles that also have no neighbors
            (local auto_digs (gen_auto_digs gamestate.map appstate.time tx ty))
            
            (set gamestate.first_dig false)
            (set gamestate.last_dig_time appstate.time)
            (tset gamestate.dig_anims ty tx (Anim.state ANIMS.dig false))
            
            (sfx SFX_DIG "C-3" 32)

            (if (= val HOLE)
                (do
                    (set gamestate.falling_start appstate.time)
                    (set gamestate.falling_pos (gamestate.pig:map_coords))
                    
                    ; snap pig coordinates
                    (local [sx sy] (gamestate.pig:field_coords))
                    (gamestate.pig:warp sx sy)
                    (gamestate.pig:face :s)
                    (sfx SFX_FALL "C-6" 64 SFX_FALL_CHANNEL)
                    (sfx -1 -1 -1 SFX_AUTODIG_CHANNEL)
                    (gamestate:post_status "Oh no!" 5000)
                )

                ; else 
                (do 
                    (each [_ [time x y] (ipairs auto_digs)]
                        (push gamestate.auto_digs 
                            [(Anim.state ANIMS.dig false) time x y])
                    )

                    (when (> (length auto_digs) 1)
                        (sfx SFX_AUTODIG "C-4" -1 SFX_AUTODIG_CHANNEL))
                )
            )

        )
    )

    (when command.flag
        (local val (gamestate.map:at tx ty))
        (local [mapx mapy] [(+ FIELD_X_T tx) (+ FIELD_Y_T ty)])
        (local allowed_to_plant_a_flag (and 
            (> gamestate.n_flags 0)
            (not (dug? tx ty))))

        (if allowed_to_plant_a_flag
            (if (= val HOLE) 
                (do (mset mapx mapy FLAG_TILE)
                    (sfx SFX_GOODFLAG "C-4" 32)
                )

                ; else 
                (do (sfx SFX_SAD "C-3" 32)
                    (gamestate:post_status "Wasn't a hole!")
                    (dec! gamestate.n_flags))
            )

            ; else
            (do (gamestate:post_status "Already dug!") 
                (sfx SFX_SAD "C-3" 32)
            )
        )
    )


    (each [_ [x y] (ipairs command.auto_digs)]
        (local val (gamestate.map:at x y))
        (when (not (dug? x y))
            (dig x y))
    )

    (when (empty? gamestate.auto_digs) 
        (sfx -1 -1 -1 SFX_AUTODIG_CHANNEL))

    (gamestate:move command.movehoriz command.movevert)
)


(fn _G.BOOT []
    (global appstate (AppState.new))
    (global gamestate (GameState.new 1 1 1))   
)

(fn GameState.mt.tick [self appstate]
    ;(Anim.states_tick self.player_anim_states MS_PER_TIC)
    (self.pig:tick)

    (local command (GameCommand.new))
    (poll_buttons appstate command)
    (self:tick_auto_digs appstate.time command)
    (self:tick_status)
    (self:tick_dig_anims appstate.dtime)

    (when (not gamestate.falling_start)
        (apply_command command gamestate appstate)
    )
)

(fn _G.TIC []
    (appstate:poll)

    (gamestate:tick appstate)

    (gamestate:draw appstate.time)

    (when gamestate.falling_start
        (if (<= (- appstate.time gamestate.falling_start) FALL_DELAY_MS)
            ; coyote time, just stare straight ahead
            (do)

            ; else: actually falling
            (gamestate.pig:translate 0 FALL_SPEED_PX_TIC)
        )
    )

)

;; <TILES>
;; 002:032000003320222243222222030222220222222202222cc20222cc990222cc99
;; 003:0044400023330400223303002223330022cc2000229c2000229c2000229c2300
;; 004:0320000033202222432222220302222202222222022220020222220002222220
;; 005:0044400023330400223303002223330022022000220220002200200022222300
;; 006:0ccccccccccccccccccccccccccccccccccccccccccccccccccccccccc000000
;; 007:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc
;; 008:0000c000000cc00000c8c0000080c0000000c0000000c00000cccc0000888800
;; 009:000cc00000c88c0000800c000000c800000c800000c8000000cccc0000888800
;; 010:00ccc00000888c0000000c000000c80000008c0000000c0000ccc80000888000
;; 011:0000c000000cc00000c8c0000c80c0000ccccc000888c8000000c00000008000
;; 012:00cccc0000c8880000ccc00000888c0000000c0000000c0000ccc80000888000
;; 013:000cc00000c88c0000c0080000ccc00000c88c0000c00c00008cc80000088000
;; 014:00cccc0000888c0000000c000000c8000000c000000c8000000c000000080000
;; 015:000cc00000c88c0000c00c00008cc80000c88c0000c00c00008cc80000088000
;; 018:0222cc9902222ccc022222220222222202222220002222200002222200000000
;; 019:22c2321022322132222212322222120222221010022211000022200000000000
;; 020:0222222002222222022222220222222202222222002222220002222000000000
;; 021:2222321022222132222212322222120222221010022211002022200000000000
;; 022:cc0000ccc000000c00000000000000000000000000000000c000000ccc0000cc
;; 023:000000000cc00cc00c0000c000000000000000000c0000c00cc00cc000000000
;; 024:cc000000c0000000000000000000000000000000000000000000000000000000
;; 032:00000000332222333322223322c22c222c9229c22c9229c22233332202333320
;; 033:332222333322223322c22c222c9229c22c9229c2222222222233332202333320
;; 036:0000000003332230233322202232c220222c9220222c92232222222302220223
;; 037:03332230233322202232c220222c9220222c9223222222230222022302222000
;; 040:0000000033222233332222333222222322222222222222222222222202222220
;; 041:3322223333222233322222232222222222222222222222222222222202222220
;; 044:000000000322333002223332022c23220229c2223229c2223222222232202220
;; 045:0322333002223332022c23220229c2223229c222322222223220222000022220
;; 048:0072270002777720227777223377773333677633022662200220022002300320
;; 049:0277772022777772337777723367762302200220022002200330000000000000
;; 050:0072270002777720227777223377773333677633022662200220022002300320
;; 051:0277772027777722277777333267763302200220022002200000033000000000
;; 052:0007770000772700007227702072277002733770006336000002200000033300
;; 053:0022770002227770232777700337777000877600002661130322013000330300
;; 054:0007770000772700007227702072277002733770006336000002200000033300
;; 055:0072270000722370207733700277777000677600001662230311023000330300
;; 056:0022220002777720077777702777777237772773376776730776677002200220
;; 057:0077770002777720077777720772777307677673077667700220022000000220
;; 058:0022220002777720077777702777777237772773376776730776677002200220
;; 059:0077770002777720277777703772777037677670077667700220022002200000
;; 060:0077770000727700077227000772270207733720006336000002200000333000
;; 061:0077220007772220077772320777733000677800311662000310223000303300
;; 062:0077770000727700077227000772270207733720006336000002200000333000
;; 063:0072270007322700073377020777772000677600322661000320113000303300
;; 064:000322200033c9200002c9330002223300002220000000000000000000000000
;; 080:0000000000000500000065660056656600656566006666660066666600666666
;; 081:0000000000500000665666666656665666666656666666666666666666666666
;; 082:0000000000050000665605006656500066665600666666006666660066666600
;; 084:6666666666666666666666666666666666666666666666666666666666666666
;; 085:6666666666666666666666666666666666666666666666666666666666666666
;; 086:6666666666666666666666666666666666666666666666666666666666666666
;; 088:0000000000000000000066660006666600666666006666660066666600666666
;; 089:0000000000000000616161611212121225252525323232322121212112121212
;; 090:0000000000000000666600006666600066666600666666006666660066666600
;; 096:0566666600566666056666660056666600566666006666660066666600666666
;; 097:6666666666656665666566656565656565656566656665666666666666666666
;; 098:6666665066666500666666006666665066666500666665006666660066666600
;; 100:6666666666666666666666666666666666666666666666666666666666666666
;; 101:6666666666666666666666666666666666666666666666666666666666666666
;; 102:6666666666666666666666666666666666666666666666666666666666666666
;; 104:0012521200612321001252120061232100125212006123210012521200612321
;; 105:2125212512321232212521251232123221252125123212322125212512321232
;; 106:2125210012321600212521001232160021252100123216002125210012321600
;; 108:6611116661111116111111111111111111111111111111116111111666111166
;; 112:0066666600666566055665660065666600056666000565660000050000000000
;; 113:6666666666666666666665566656656666566566665666660000000000000000
;; 114:6666660066666650666665006666650066656000666650000000000000000000
;; 116:6666666666666666666666666666666666666666666666666666666666666666
;; 117:6666666666666666666666666666666666666666666666666666666666666666
;; 118:6666666666666666666666666666666666666666666666666666666666666666
;; 120:0066666600666666006666660066666600066666000066660000000000000000
;; 121:6666666666666666666666666666666666666666666666660000000000000000
;; 122:6666660066666600666666006666660066666000666600000000000000000000
;; 128:6611c166611cc11611c8c1111181c1111111c1111111c11161cccc1666888866
;; 129:6619916661988916118119111111981111198111119811116199991666888866
;; 130:6644416661888416111114111111481111118411111114116144481666888166
;; 131:6611316661133116113831111381311113333311188838116111311666118166
;; 132:66bbbb6661b8881611bbb11111888b1111111b1111111b1161bbb81666888166
;; 133:661aa16661a88a1611a1181111aaa11111a88a1111a11a11618aa81666188166
;; 134:6655556661888516111115111111581111115111111581116115111666181166
;; 135:661dd16661d88d1611d11d11118dd81111d88d1111d11d11618dd81666188166
;; 136:6600006660000006000000000000000000000000000000006000000666000066
;; 137:0000000000440000044440000434340000444400000434400000440000000000
;; 144:6666666666666666666666666661166666611666666666666666666666666666
;; 145:6666666666666666666116666611116666111166666116666666666666666666
;; 146:6666666666611666661111666111111661111116661111666661166666666666
;; 147:6611116661111116111111111111111111111111111111116111111666111166
;; 148:0001444000014444000144400001440000010000000000000000000000000000
;; 149:6661444666614444666144466661446666616666666666666666666666666666
;; 160:0000000000000000000000000000000000300300030000300000000000000000
;; 161:0000000000000000003003000300003000300300030000300000000000000000
;; 162:0000000003000030003003000000000003000030003003000000000000000000
;; 163:0000000000000000300000030000000000000000300000030000000000000000
;; </TILES>

;; <MAP>
;; 001:000000000000000000000005151515151515151515151515151515152500000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 002:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 003:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 004:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 005:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 006:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 007:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 008:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 009:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 010:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 011:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 012:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 013:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 014:000000000000000000000006565656565656565656565656565656562600000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; 015:000000000000000000000007171717171717171717171717171717172700000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; </MAP>

;; <WAVES>
;; 000:00000000ffffffff00000000ffffffff
;; 001:0123456789abcdeffedcba9876543210
;; 002:0123456789abcdef0123456789abcdef
;; </WAVES>

;; <SFX>
;; 000:1000300040004000500050006000700070008000800080009000900090009000a000a000a000a000a000a000a000a000a000a000a000a000b000b000300000000000
;; 032:10001000200030004020402050205020504060406040704070c070c080c080c080c090c090c090c0a0c0a0c0b0c0c0c0d0c0d0c0e0c0f0c0f0c0f0c0400000000000
;; 033:002100431075109610b710e710f6101420122030304e306d408b50aa50d8601860487069808d90b190e590f6a007b027b047c065d081e0bee0dbf0f9200000000000
;; 034:03e013a023801340d310435043e053b0a39053d073706340e320f310736083d093c093a0a3705350b3a0c310c3e0d3e093b0e3a0e380f360c340f3102000000e0e00
;; 035:0000001010202040306040804080508060806080708070808080808090809080a080b080b080c090c090d090d090e090e090e090f090f090f080f080380000000000
;; 036:10001000200030004020402050205020502060206020702070407040804080408040904090409040a040a040b040c040d040d040e040f040f040f040400000000000
;; 037:0100111021203130313031404150416051705180619061a061b071c071d081e091f091f091f0a1f0a1f0b1f0b1f0c1f0c1f0d1f0d1f0d1f0e1f0f1f05f0000000000
;; </SFX>

;; <PATTERNS>
;; 000:400006000000b00004000000400006000000800006000000400006000000800006000000600006000000400006000000600006000000b00006000000000000000000000000000000c00006000000700006000000c00006000000e00006000000900006000000e00006000000400008000000000000000000000000000000000000000000100000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000
;; </PATTERNS>

;; <TRACKS>
;; 000:1000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000000ff
;; </TRACKS>

;; <PALETTE>
;; 000:1a1c2c5d275db13e53ef7d57ffcd75a7f07038b76425717929366f3b5dc941a6f673eff7f4f4f494b0c2566c86333c57
;; </PALETTE>

