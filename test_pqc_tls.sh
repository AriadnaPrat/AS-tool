#!/usr/bin/env bash
# Test cases for OpenSSL (>= 3.5) hybrid PQC key exchange groups in TLS 1.3.
# Usage: ./test_pqc_tls.sh            -> runs TC-01..TC-08 and saves results.csv
#        ./test_pqc_tls.sh --bench    -> also measures performance (openssl speed / s_time)
set -u
export MSYS_NO_PATHCONV=1          # Git Bash on Windows: don't turn "/CN=..." into a path

OPENSSL=${OPENSSL:-openssl}
PORT=${PORT:-4433}
PKI=pki
OUT=results.csv

# --- 0. Check version -----------------------------------------------------
$OPENSSL version
$OPENSSL list -tls-groups -tls1_3 | tr ':' '\n' | grep -q X25519MLKEM768 \
  || { echo "ERROR: this OpenSSL build does not support X25519MLKEM768 (>= 3.5 required)"; exit 1; }

# --- 1. Certificates ------------------------------------------------------
mkdir -p "$PKI"
[ -f $PKI/ec.crt ] || $OPENSSL req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
  -keyout $PKI/ec.key -out $PKI/ec.crt -days 365 -subj "/CN=localhost" 2>/dev/null
[ -f $PKI/mldsa65.crt ] || $OPENSSL req -x509 -newkey mldsa65 -nodes \
  -keyout $PKI/mldsa65.key -out $PKI/mldsa65.crt -days 365 -subj "/CN=localhost" 2>/dev/null

# --- 2. Run one case ------------------------------------------------------
# Stop the server. In Git Bash, `kill` doesn't always end openssl.exe, so use taskkill.
stop_server() {
  if [ -r /proc/$1/winpid ]; then taskkill //F //PID "$(cat /proc/$1/winpid)" >/dev/null 2>&1; fi
  kill "$1" 2>/dev/null; wait "$1" 2>/dev/null
  PORT=$((PORT + 1))   # new port for every server: never connect to a previous one
}

# run_case ID SERVER_GROUPS CLIENT_GROUPS CERT EXPECTED
run_case() {
  local id=$1 sgroups=$2 cgroups=$3 cert=$4 expected=$5
  # -www: the server doesn't read stdin (required on Windows)
  $OPENSSL s_server -accept "$PORT" -cert $PKI/$cert.crt -key $PKI/$cert.key \
    -tls1_3 -groups "$sgroups" -www -quiet >/dev/null 2>&1 &
  local spid=$!
  sleep 1
  local log
  log=$($OPENSSL s_client -connect 127.0.0.1:"$PORT" -tls1_3 -groups "$cgroups" -trace </dev/null 2>&1)
  stop_server "$spid"

  local group sig ch_count ch_len cks sks result
  group=$(sed -n 's/^Negotiated TLS1\.3 group: //p' <<<"$log")
  # classic groups: OpenSSL prints "Peer Temp Key: X25519, 253 bits" instead
  [ -z "$group" ] && group=$(sed -n 's/^Peer Temp Key: \([^,]*\),.*/\1/p' <<<"$log")
  sig=$(sed -n 's/^Peer signature type: //p' <<<"$log")
  ch_count=$(grep -c '^    ClientHello, Length=' <<<"$log")
  ch_len=$(sed -n 's/^    ClientHello, Length=//p' <<<"$log" | tail -1)
  # key_share length sent by the client (last ClientHello) and by the server
  cks=$(awk '/^    ClientHello/{c=1;s=0} /^    ServerHello/{c=0;s=1} c&&/key_exchange:/{match($0,/len=[0-9]+/);v=substr($0,RSTART+4,RLENGTH-4)} END{print v}' <<<"$log")
  sks=$(awk '/^    ServerHello/{s=1} /^    (EncryptedExtensions|ClientHello)/{s=0} s&&/key_exchange:/{match($0,/len=[0-9]+/);v=substr($0,RSTART+4,RLENGTH-4)} END{print v}' <<<"$log")
  local hrr=no; [ "$ch_count" -gt 1 ] && hrr=yes

  if [ "$expected" = FAIL ]; then
    [ "$group" = "<NULL>" ] && result=PASS || result=FAIL
  else
    [ "$group" = "$expected" ] && result=PASS || result=FAIL
  fi
  printf '%-6s %-20s %-6s %-5s %-6s %-6s %-22s %s\n' "$id" "$group" "$ch_len" "$hrr" "$cks" "$sks" "${sig:--}" "$result"
  echo "$id,$sgroups,$cgroups,$cert,$expected,$group,$ch_len,$hrr,$cks,$sks,$sig,$result" >>"$OUT"
}

echo "id,server_groups,client_groups,cert,expected,negotiated,clienthello_len,hrr,client_keyshare_len,server_keyshare_len,peer_sig,result" >"$OUT"
printf '\n%-6s %-20s %-6s %-5s %-6s %-6s %-22s %s\n' ID GROUP CH_LEN HRR KS_CLI KS_SRV SIGNATURE RESULT
run_case TC-01 X25519MLKEM768        X25519MLKEM768        ec      X25519MLKEM768
run_case TC-02 SecP256r1MLKEM768     SecP256r1MLKEM768     ec      SecP256r1MLKEM768
run_case TC-03 SecP384r1MLKEM1024    SecP384r1MLKEM1024    ec      SecP384r1MLKEM1024
run_case TC-04 X25519                X25519                ec      X25519
run_case TC-05 X25519MLKEM768:X25519 X25519                ec      X25519
run_case TC-06 X25519MLKEM768        X25519:X25519MLKEM768 ec      X25519MLKEM768
run_case TC-07 X25519MLKEM768        X25519                ec      FAIL
run_case TC-08 X25519MLKEM768        X25519MLKEM768        mldsa65 X25519MLKEM768
echo; echo "Results saved to $OUT"

# --- 3. Performance (optional) --------------------------------------------
if [ "${1:-}" = "--bench" ]; then
  echo; echo "== openssl speed (KEM) =="
  $OPENSSL speed -seconds 3 X25519 ML-KEM-768 X25519MLKEM768 SecP256r1MLKEM768 SecP384r1MLKEM1024 2>/dev/null | grep -E 'keygen|X25519|MLKEM'
  for g in X25519 X25519MLKEM768 SecP256r1MLKEM768 SecP384r1MLKEM1024; do
    $OPENSSL s_server -accept "$PORT" -cert $PKI/ec.crt -key $PKI/ec.key -tls1_3 -groups $g -www -quiet >/dev/null 2>&1 &
    spid=$!; sleep 1
    # s_time has no -groups option: set the client group with a temporary openssl.cnf
    printf 'openssl_conf = i\n[i]\nssl_conf = s\n[s]\nsystem_default = d\n[d]\nGroups = %s\n' "$g" > groups.cnf
    echo; echo "== s_time $g =="
    OPENSSL_CONF=groups.cnf $OPENSSL s_time -connect 127.0.0.1:"$PORT" -new -time 5 2>/dev/null | grep -E 'connections in .*user sec'
    stop_server "$spid"
  done
  rm -f groups.cnf
fi
