# os            Arch Linux (ID or ID_LIKE arch in /etc/os-release) or macOS; on any other OS
#               it fails and no tool is checked.
# shellcheck shell=bash
# shellcheck disable=SC2034 # os, for the later checks

kernel=$(uname -s)
case $kernel in
  Darwin)
    os=macos
    report os PASS macOS
    ;;
  Linux)
    name=$(os_release PRETTY_NAME)
    name=${name:-$(os_release ID)}
    name=${name:-Linux}
    if [[ $(os_release ID) == arch ]]; then
      os=arch
      report os PASS "$name"
    elif [[ " $(os_release ID_LIKE) " == *" arch "* ]]; then
      os=arch
      report os PASS "$name, an Arch Linux"
    else
      report os FAIL "$name is neither Arch Linux nor macOS, so no tool is checked" "run the team on Arch Linux or macOS"
    fi
    ;;
  *) report os FAIL "$kernel is neither Arch Linux nor macOS, so no tool is checked" "run the team on Arch Linux or macOS" ;;
esac
