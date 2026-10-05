#!/bin/zsh
# Smoke test only: makes clips with macOS's built-in text-to-speech so Bench can run
# before you record yourself. Synthetic voices are much easier than real speech —
# don't pick an engine from these numbers.
set -euo pipefail
cd "$(dirname "$0")/.."
out=TestClips/synthetic
mkdir -p "$out"
voice=${1:-Samantha}
i=0
grep -v '^#' prompts.txt | grep -v '^[[:space:]]*$' | while IFS= read -r line; do
  i=$((i + 1))
  name=$(printf "tts_%03d" $i)
  say -v "$voice" -o "$out/$name.wav" --data-format=LEI16@16000 "$line"
  print -r -- "$line" > "$out/$name.txt"
done
echo "Wrote $(ls "$out"/*.wav | wc -l | tr -d ' ') clips to $out using voice '$voice'"
