#!/bin/zsh
cd -- "${0:A:h}"
export PATH="/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin:$PATH"
python3 script/transcode_downloads.py "$@"
result=$?
if (( result != 0 )); then
  echo
  echo "The monitor exited with an error. Press Enter to close this window."
  read
fi
exit $result
