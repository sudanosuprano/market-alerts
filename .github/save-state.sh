#!/usr/bin/env bash
# Commits whatever the job changed in data/, docs/ and reports/ and pushes it.
set -e
git config user.name "github-actions[bot]"
git config user.email "41898283+github-actions[bot]@users.noreply.github.com"
git add -A data docs reports 2>/dev/null || true
if git diff --cached --quiet; then echo "Nothing changed"; exit 0; fi
git commit -q -m "$1 [$(TZ=Australia/Sydney date '+%a %d %b %H:%M')]"
for i in 1 2 3; do
  git push -q && exit 0
  git pull -q --rebase -X theirs || true
done
echo "Push failed after 3 tries"; exit 1
