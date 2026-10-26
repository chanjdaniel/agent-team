# 1password     Warns while op (the tool op line) or the 1Password app is missing, both found
#               without asking the vault: without them, team-secrets restore can only ask for
#               each secret to be pasted.
# shellcheck shell=bash
# shellcheck disable=SC2154 # os, from the os check

# op as its tool line found it, and the app by its path.
app=/opt/1Password/1password
app_fix="install the native 1password package from the AUR (not the Snap or Flatpak), then turn on its Settings > Developer > Integrate with 1Password CLI"
if [[ $os == macos ]]; then
  app=/Applications/1Password.app
  app_fix="brew install --cask 1password, then turn on its Settings > Developer > Integrate with 1Password CLI"
fi
app=${TEAM_1PASSWORD_APP:-$app}
missing=() fixes=()
[[ -n ${installed[op]:-} ]] || { missing+=("op is not installed"); fixes+=("the tool op line's fix"); }
[[ -e $app ]] || { missing+=("the 1Password app is not at $app"); fixes+=("$app_fix"); }
if ((${#missing[@]} == 0)); then
  report 1password PASS "op and the 1Password app are installed (the vault is not asked)"
else
  report 1password WARN "$(printf '%s and ' "${missing[@]}" | sed 's/ and $//'), so team-secrets restore can only ask for each secret to be pasted" \
    "$(printf '%s; ' "${fixes[@]}" | sed 's/; $//')"
fi
