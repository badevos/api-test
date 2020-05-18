#!/bin/bash
set -o pipefail

RED=$(tput setaf 1)
GREEN=$(tput setaf 2)
BOLD=$(tput bold)
RESET=$(tput sgr 0)

ACTION=""

FILE=""

VERBOSE=0

COMMAND_NAME="api-test"

ACCESS_TOKEN=""
ID_TOKEN=""
URL=""

SHOW_HEADER=0
HEADER_ONLY=0
SILENT=0

echo_v() {
  if [ $VERBOSE -eq 1 ]; then
    echo $1
  fi
}

bytes_to_human() {
  b=${1:-0}
  d=''
  s=0
  S=(Bytes {K,M,G,T,E,P,Y,Z}B)
  while ((b > 1024)); do
    d="$(printf ".%02d" $((b % 1024 * 100 / 1024)))"
    b=$((b / 1024))
    let s++
  done
  echo "$b$d ${S[$s]}"
}

run() {
  for arg in "$@"; do
    case $arg in
    -i | --include)
      SHOW_HEADER=1
      shift
      ;;
    -I | --header-only)
      HEADER_ONLY=1
      shift
      ;;
    -s | --silent)
      SILENT=1
      shift
      ;;
    esac
  done

  case $1 in
  all)
    api_factory "$(jq -r '.testCases | keys[]' $FILE)"
    ;;
  *)
    api_factory $@
    ;;
  esac
}

api_factory() {
  for TEST_CASE in $@; do
    echo "${BOLD}Running Case:${RESET} $TEST_CASE"
    echo_v "${BOLD}Description: ${RESET}$(jq -r ".testCases.$TEST_CASE.description" $FILE)"
    echo_v "${BOLD}Action: ${RESET}$(jq -r ".testCases.$TEST_CASE.method //\"GET\" | ascii_upcase" $FILE) $(jq -r ".testCases.$TEST_CASE.path" $FILE)"
    call_api $TEST_CASE
    display_results
  done
}

display_results() {
  local res=$(jq -r '.http_status + " " + .http_message ' <<<"$HEADER")
  local status=$(jq -r '.http_status' <<<"$HEADER")
  echo "Response:"
  echo "${BOLD}$(color_response $status)$res${RESET}"
  if [[ $HEADER_ONLY == 1 ]]; then
    echo "HEADER:"
    echo "$HEADER" | jq -C
  else
    if [[ $SHOW_HEADER == 1 ]]; then
      echo "HEADER:"
      echo "$HEADER" | jq -C
    fi
    if [[ $SILENT == 0 ]]; then
      echo "BODY:"
      echo "$BODY" | jq -C
    fi

  fi
  echo "META:"
  echo "$META" | jq -C
  echo ""
  echo ""
}

color_response() {
  case $1 in
  2[0-9][0-9]) echo $GREEN ;;
  [45][0-9][0-9]) echo $RED ;;
  *) ;;
  esac
}

call_api() {
  ROUTE=$(jq -r ".testCases.$1.path" $FILE)
  BODY="$(jq -r ".testCases.$1.body" $FILE)"
  QUERY_PARAMS=$(cat $FILE | jq -r ".testCases.$1 | select(.query != null) | .query  | to_entries | map(\"\(.key)=\(.value|tostring)\") | join(\"&\") | \"?\" + . ")
  REQUEST_HEADER=$(cat $FILE | jq -r ".testCases.$1 | .header | if  . != null then . else {} end   | to_entries | map(\"\(.key): \(.value|tostring)\") | join(\"\n\") | if ( . | length) != 0 then \"-H\" + .  else \"-H \" end")
  METHOD="$(jq -r ".testCases.$1.method //\"GET\" | ascii_upcase" $FILE)"
  # curl -ivs --request $METHOD "$URL$ROUTE$QUERY_PARAMS" \
  #   --data "$BODY" \
  #   "$COMMON_HEADER" \
  #   "$REQUEST_HEADER" \
  #   -w '\n{ "ResponseTime": "%{time_total}s" }\n'
  local raw_output=$(curl -is --request $METHOD "$URL$ROUTE$QUERY_PARAMS" \
    --data "$BODY" \
    "$COMMON_HEADER" \
    "$REQUEST_HEADER" \
    -w '\n{ "ResponseTime": "%{time_total}s", "Size": %{size_download} }' || echo "AUTO_API_ERROR")

  if [[ $raw_output == *"AUTO_API_ERROR"* ]]; then
    echo "Problem connecting to $URL"
    return 1
  fi
  local header="$(awk -v bl=1 'bl{bl=0; h=($0 ~ /HTTP\//)} /^\r?$/{bl=1} {if(h)print $0 }' <<<"$raw_output")"
  local json=$(jq -c -R -r '. as $line | try fromjson' <<<"$raw_output")
  BODY=$(sed -n 1p <<<"$json")
  META=$(sed 1d <<<"$json")
  META=$(jq -r ".Size = \"$(bytes_to_human $(jq -r '.Size' <<<"$META"))\"" <<<"$META")
  parse_header "$header"
}

function parse_header() {
  local RESPONSE=($(echo "$header" | tr '\r' ' ' | sed -n 1p))
  local header=$(echo "$header" | sed '1d;$d' | sed 's/: /" : "/' | sed 's/^/"/' | tr '\r' ' ' | sed 's/ $/",/' | sed '1 s/^/{/' | sed '$ s/,$/}/' | jq)
  HEADER=$(echo "$header" "{ \"http_version\": \"${RESPONSE[0]}\", 
           \"http_status\": \"${RESPONSE[1]}\",
           \"http_message\": \"${RESPONSE[@]:2}\",
           \"http_response\": \"${RESPONSE[@]:0}\" }" | jq -s add)
}

# Show usage
function usage() {
  echo "USAGE: $COMMAND_NAME [-hv] [-f file_name] [CMD] [ARGS]"
  echo ""
  echo "OPTIONS:"
  echo "  -h (--help)       print this message"
  echo "  -h (--help)       print this message"
  echo "  -v (--verbose)    verbose logging"
  echo "  -f (--file)       file to test"
  echo ""
  echo "COMMANDS:"
  echo "  run               Run test cases specified in the test file."
  echo "                    Example: 'api-test -f test.json run test_case_1 test_case_2', 'api-test -f test.json run all'"
  exit
}

for arg in "$@"; do
  case $arg in
  run | test)
    ACTION="$1"
    shift
    break
    ;;
  -f | --file)
    FILE="$2"
    shift
    ;;
  -h | --help)
    usage
    exit
    ;;
  -v | --verbose)
    VERBOSE=1
    shift
    ;;
  *)
    shift
    ;;
  esac
done

if [ ! -f "$FILE" ]; then
  echo "Please provide an existing file."
  exit 1
fi

cat $FILE | jq empty
if [ $? -ne 0 ]; then
  echo "Empty file"
  exit
fi
URL=$(jq -r '.url' $FILE)
ACCESS_TOKEN=$(jq -r '.accessToken' $FILE)
ID_TOKEN=$(jq -r '.idToken' $FILE)
COMMON_HEADER=$(cat $FILE | jq -r -c ". | .header | if  . != null then . else {} end   | to_entries | map(\"\(.key): \(.value|tostring)\") | join(\"\n\") | if ( . | length) != 0 then \"-H\" + .  else \"-H \" end")

case $ACTION in
run)
  run $@
  ;;
test) ;;
*)
  usage
  ;;
esac
