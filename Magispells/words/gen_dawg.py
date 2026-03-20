import typing
import sys 

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



class State:
    ins: list[tuple[str, State]]
    outs: dict[str, State]
    freq: int # number of inbound transitions
    final: bool 

    def __init__(self: State) -> None:
        self.ins = list()
        self.outs = dict()
        self.freq = 0
        self.final = False

    def has_children(self: State) -> bool:
        return len(self.outs.items()) > 0
    
    def last_child(self: State) -> tuple[str, State]:
        assert len(self.outs) > 0
        last_key = max(self.outs.keys())
        return (last_key, self.outs[last_key])
    
    def equiv(self: State, other: State) -> bool:
        if len(self.outs) != len(other.outs): return False

        for k, v in self.outs.items():
            if k not in other.outs: return False
            if other.outs[k] is not v: return False

        return True  


    def add_suffix(self: State, suffix: str) -> None:
        if suffix == "":
            self.final = True 
            return

        trans_char = suffix[0]
        st = State()
        st.freq = 1
        st.ins.append((trans_char, self))
        self.outs[trans_char] = st
        st.add_suffix(suffix[1:])

    def common_prefix_and_last_state(self: State, word: str) -> tuple[str, State]:
        if word == "": return ("", self) 

        next_char = word[0]

        if next_char not in self.outs.keys():
            return ("", self)

        remaining = word[1:]
        (remaining_prefix, last_state) =\
            self.outs[next_char].common_prefix_and_last_state(remaining)

        return (next_char + remaining_prefix, last_state)

    def dfs(self: State, visited: set[State] = set()) -> set[State]:
        visited.add(self)
        
        for _, other in self.outs.items():
            if other not in visited:
                other.dfs(visited)        

        return visited
    
    def __str__(self) -> str:
        if not self.has_children(): return ""
        child_strs = []
        for k, v in self.outs.items():
            child_strs.append(k + str(v))

        if len(child_strs) == 1: return child_strs[0]

        return '(' + '|'.join(child_strs) + ')'

# generate a dawg and return its start state
def gen_dawg(words: list[str]) -> State:
    register = []
    start = State()

    for word in words:
        (common_prefix, last_state) = start.common_prefix_and_last_state(word)
        current_suffix = word[len(common_prefix) + 1:]
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
            state.outs[last_key] = reg_state
            break
        else:
            register.append(child)

words = list(map(lambda s: s.strip(), sys.stdin))
start = gen_dawg(words)

print(str(start))