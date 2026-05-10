import sys 
import typing

# generate a DAWG, a directed acyclic word graph, to compress the wordlist.
# the wordlist will be read from stdin, one word per line
# inspired by "Incremental Construction of Minimal Acyclic Finite-State 
# Automata" by Daciuk, Mihov, Watson, and Watson. 
# Link: https://aclanthology.org/J00-1002.pdf

# the input dictionary must be sorted for the following reason:
# we only need to add to the last state along the common prefix of the next
# word. once we move to a higher-up word in the ordering, we can safely merge
# earlier prefixes without introducing new words to the language.
# we can maintain the invariant that the dafsa starting with every state other
# than those along the current prefix-path has been fully and finally minimized.

state_count = 0

class State:
    children: list[tuple[str, 'State']]
    freq: int # number of inbound transitions
    id: int 
    final: bool 

    def __init__(self: 'State') -> None:
        global state_count

        self.children = list()
        self.freq = 0
        self.final = False
        self.id = state_count

        state_count += 1

    def has_children(self: 'State') -> bool:
        return len(self.children) > 0
    
    #def add_child(self: State, letter: str, val: State):
    #    ind = bisect.insort_left(self.children, (letter, val), key=(lambda k: k[0]))
    
    def last_child(self: 'State') -> tuple[str, 'State']:
        assert len(self.children) > 0
        return self.children[-1]
    
    # the hash of a state is based on the hashes of the outbound transitions
    # combined with the hash of their destinations
    def __hash__(self) -> int:
        hashes: set[int] = set()
        for t, d in self.children:
            hashes.add(hash(t))
            hashes.add(hash(d))

        return hash(frozenset(hashes))

    def __eq__(self: 'State', other: object) -> bool:
        return self.equiv(typing.cast(State, other))
    
    def equiv(self: 'State', other: 'State') -> bool:
        if len(self.children) != len(other.children): return False
        if self.final != other.final: return False
        
        for ((k1, v1), (k2, v2)) in zip(self.children, other.children):
            if k1 != k2: return False 
            if v1.id != v2.id: return False 
        
        return True  


    def add_suffix(self: 'State', suffix: str) -> None:
        if suffix == "":
            self.final = True 
            return

        trans_char = suffix[0]
        st = State()
        st.freq = 1
        self.children.append((trans_char, st))
        st.add_suffix(suffix[1:])

    def common_prefix_and_last_state(self: 'State', word: str) -> tuple[str, 'State']:
        if word == "": return ("", self) 

        next_char = word[0]

        if len(self.children) == 0 or self.last_child()[0] != next_char:
            return ("", self)

        remaining = word[1:]
        (remaining_prefix, last_state) =\
            self.last_child()[1].common_prefix_and_last_state(remaining)

        return (next_char + remaining_prefix, last_state)

    def dfs(self: 'State', visited: set['State'] = set()) -> set['State']:
        visited.add(self)
        
        for _, other in self.children:
            if other not in visited:
                other.dfs(visited)        

        return visited
    
    def regex(self) -> str:
        if not self.has_children(): return "#" if self.final else ""
        if len(self.children) == 1: 
            return self.children[0][0] + self.children[0][1].regex()

        child_strs = []
        for k, v in self.children:
            child_strs.append(k + v.regex())

        return '(' + '|'.join(child_strs) + ')'
    
    def serialize(self):
        f = '!' if self.final else ''

        if not self.has_children(): return f # + str(self.id)
        
        child_strs = []
        for k, v in self.children:
            child_strs.append(k)
            child_strs.append(hex(v.id)[2:].upper())
        
        return f + "".join(child_strs)



# generate a dawg and return its start state
def gen_dawg(words: list[str]) -> State:
    register: dict[State, State] = {}
    start: State = State()

    for word in words:
        (common_prefix, last_state) = start.common_prefix_and_last_state(word)
        current_suffix = word[len(common_prefix):]
        if last_state.has_children():
            replace_or_register(register, last_state)
        last_state.add_suffix(current_suffix)
    
    replace_or_register(register, start)
    
    return start

# use a dict[State, State] as the register.
# originally, the register was a list. this was too slow (quadratic time)
# set[State] doesn't work because we can't dereference the specific state to be
# replaced with. dict[id, State] isn't ideal because the hashcode isn't
# guaranteed to be unique, and I'd have to check twice. while strange, 
# dict[State, State] meets the requirements well
def replace_or_register(register: dict[State, State], state: State) -> None:
    last_key, child = state.last_child()


    if child.has_children():
        replace_or_register(register, child)

    # search register for identical state to child 
    # (could be sped up by making states hashable or ordered) 
    if child in register:
        equiv = register[child]
        state.children[-1] = (last_key, equiv)
        equiv.freq += 1
    else:
        register[child] = child

words = list(map(lambda s: s.strip(), sys.stdin))
words.sort()
start = gen_dawg(words)

states = list(start.dfs())
states_by_id: dict[int, State] = {s.id : s for s in states}
states.sort(key=lambda s: -s.freq)

for new_id, state in enumerate(states):
    state.id = new_id

serialized = []
for state in states:
    serialized.append(state.serialize())
    #print(state.freq, state.serialize())
    #print(state.serialize())
print(''.join(map(lambda s: s + ';', serialized)))
print('start = ', start.id)
print('in lua:', start.id + 1)

def find_in_children(children: list[tuple[str, State]], which: str) -> State | None:
    res = [child for child in children if child[0] == which]
    if res: return res[0][1]
    return None

def print_all_words(state: State, prefix: str = '') -> None:
    if state.final:
        print(prefix)
    
    for [letter, child] in state.children:
        print_all_words(child, prefix + letter)
    
# print_all_words(start)
# print(start.serialize())

# print_all_words(start)