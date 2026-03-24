# read a list of input words up to 8 characters long each and delta compress
# them such that there is a digit at the start of a word that represents 
# the number of chars to copy from the previous word

# (this approach didn't end up doing better than the DAWG)

import sys 

last_word: str = ""

for word in sys.stdin:
    if type(word) != str: break 
    word: str = word.strip()
    
    assert len(word) <= 8, "word '" + word + "' unexpectedly long"
    assert len(word) >= 3, "word '" + word + "' unexpectedly short"

    prefix_length: int = 0
    for c1, c2 in zip(last_word, word):
        if c1 != c2: break 
        prefix_length += 1

    final = str(prefix_length) if prefix_length > 0 else ""
    final += word[prefix_length:]
    print(final)

    last_word = word     