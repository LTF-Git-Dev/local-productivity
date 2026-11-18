#!/bin/zsh
# Lists the signing teams this Mac can sign with, to use as LP_TEAM_ID:
#
#   LP_TEAM_ID=ABCDE12345 Scripts/build.sh
#   LP_TEAM_ID=ABCDE12345 Scripts/deploy.sh 1.2.0
#
# A free Apple ID works: Xcode → Settings → Accounts → + → Apple ID. LP needs a team only so
# that its widgets can read what the app shares with them.

dir=$(mktemp -d)
trap 'rm -rf "$dir"' EXIT
# One file per certificate; each names its team in the subject's OU.
security find-certificate -a -c "Apple Development" -p 2>/dev/null \
  | awk -v dir="$dir" '/BEGIN CERTIFICATE/{n++} n{print > (dir "/cert" n ".pem")}'

teams=()
for cert in "$dir"/cert*.pem(N); do
  subject=$(openssl x509 -in "$cert" -noout -subject -nameopt multiline 2>/dev/null)
  team=$(echo "$subject" | awk -F'= ' '/organizationalUnitName/{print $2; exit}')
  name=$(echo "$subject" | awk -F'= ' '/commonName/{print $2; exit}')
  [[ -n "$team" ]] && teams+=("$team  $name")
done

if (( ${#teams} )); then
  printf '%s\n' "${(u)teams[@]}"
else
  echo "No signing team found."
  echo "Add your Apple ID in Xcode → Settings → Accounts, open the project once and choose your"
  echo "team under Signing & Capabilities for both targets (Local Productivity and"
  echo "LPWidgetsExtension), then run this again."
  exit 1
fi
