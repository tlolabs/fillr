#!/bin/zsh
cd -- "${0:A:h}"
python3 script/monitor_downloads.py
result=$?
if (( result != 0 )); then
  echo
  echo "The monitor exited with an error. Press Enter to close this window."
  read
fi
exit $result
