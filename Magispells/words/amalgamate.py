import os
import sys

# reads a word list from stdin. breaks on non-word. Remove words which are
# too long, too short, duplicates, or which contain non-ascii characters.
# non-ascii words are written to stderr for separate processing

MIN_LENGTH = 3
MAX_LENGTH = 8


words = set()
for word in sys.stdin:
    if type(word) != str: break
    word = word.strip()

    if len(word) < MIN_LENGTH: continue
    if len(word) > MAX_LENGTH: continue
    if not word.isascii():
        print(word, file=sys.stderr)
        continue

    words.add(word)

wordlist = list(words)
wordlist.sort()

for word in wordlist:
    print(word)
