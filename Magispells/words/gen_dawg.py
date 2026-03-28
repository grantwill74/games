import sys 
import bisect

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
    children: list[tuple[str, State]]
    freq: int # number of inbound transitions
    id: int 
    final: bool 

    def __init__(self: State) -> None:
        global state_count

        self.children = list()
        self.freq = 0
        self.final = False
        self.id = state_count

        state_count += 1

    def has_children(self: State) -> bool:
        return len(self.children) > 0
    
    #def add_child(self: State, letter: str, val: State):
    #    ind = bisect.insort_left(self.children, (letter, val), key=(lambda k: k[0]))
    
    def last_child(self: State) -> tuple[str, State]:
        assert len(self.children) > 0
        return self.children[-1]
    
    def equiv(self: State, other: State) -> bool:
        if len(self.children) != len(other.children): return False

        for ((k1, v1), (k2, v2)) in zip(self.children, other.children):
            if k1 != k2: return False 
            if v1 is not v2: return False 

        return True  


    def add_suffix(self: State, suffix: str) -> None:
        if suffix == "":
            self.final = True 
            return

        trans_char = suffix[0]
        st = State()
        st.freq = 1
        self.children.append((trans_char, st))
        st.add_suffix(suffix[1:])

    def common_prefix_and_last_state(self: State, word: str) -> tuple[str, State]:
        if word == "": return ("", self) 

        next_char = word[0]

        if len(self.children) == 0 or self.last_child()[0] != next_char:
            return ("", self)

        remaining = word[1:]
        (remaining_prefix, last_state) =\
            self.last_child()[1].common_prefix_and_last_state(remaining)

        return (next_char + remaining_prefix, last_state)

    def dfs(self: State, visited: set[State] = set()) -> set[State]:
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
        if not self.has_children(): return str(self.id)
        
        child_strs = []
        for k, v in self.children:
            child_strs.append(k)
            child_strs.append(hex(v.id)[2:])
        
        return "".join(child_strs)



# generate a dawg and return its start state
def gen_dawg(words: list[str]) -> State:
    register = []
    start = State()

    for word in words:
        (common_prefix, last_state) = start.common_prefix_and_last_state(word)
        current_suffix = word[len(common_prefix):]
        if last_state.has_children():
            replace_or_register(register, last_state)
        last_state.add_suffix(current_suffix)
    
    replace_or_register(register, start)
    
    return start

def replace_or_register(register: list[State], state: State) -> None:
    last_key, child = state.last_child()

    if child.has_children():
        replace_or_register(register, child)

    # search register for identical state to child 
    # (could be sped up by making states hashable or ordered) 
    for reg_state in register:
        if reg_state.equiv(child):
            state.children[-1] = (last_key, reg_state)
            break
        else:
            register.append(child)

words = list(map(lambda s: s.strip(), sys.stdin))
start = gen_dawg(words)

print(start.regex())