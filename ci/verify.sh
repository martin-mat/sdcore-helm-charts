#!/bin/bash
# For each network function: scale its Deployment to zero (SIGTERM through the
# kubelet, no replacement registers meanwhile), record exit code, time to exit,
# panics and the shutdown log lines, and ask the NRF whether the function's
# instance is still registered before and after. Then scale it back.
set -u
ns=sdcore
nrfq() { # list NF instances of a type, as the NRF reports them
  kubectl exec -n $ns nrfq -- curl -sk --http2 --max-time 10 "https://nrf:29510/nnrf-nfm/v1/nf-instances?nf-type=$1&limit=50" 2>&1 \
    | python3 -c 'import sys,json
raw=sys.stdin.read()
try:
  d=json.loads(raw); items=d.get("_links",{}).get("items",[]) or d.get("_links",{}).get("item",[])
  print(len(items), [i.get("href","").rsplit("/",1)[-1][:8] for i in items])
except Exception: print("raw:", raw[:160].replace("\n"," "))' 2>/dev/null || echo "query failed"
}
declare -A TYPE=( [ausf]=AUSF [nssf]=NSSF [pcf]=PCF [smf]=SMF [udm]=UDM [udr]=UDR [amf]=AMF )
order="ausf nssf pcf smf udm udr amf upf-adapter webui metricfunc sctplb simapp nrf"
for d in $order; do
  kubectl get deploy -n $ns $d >/dev/null 2>&1 || { echo "### $d: not deployed"; continue; }
  kubectl rollout status -n $ns deploy/$d --timeout=300s >/dev/null 2>&1
  pod=$(kubectl get pods -n $ns -o name | sed 's#pod/##' | grep "^$d-" | head -1)
  c=$(kubectl get pod -n $ns $pod -o jsonpath='{.spec.containers[0].name}')
  echo "### $d (pod $pod, PID 1: $(kubectl exec -n $ns $pod -c $c -- cat /proc/1/comm 2>/dev/null))"
  t=${TYPE[$d]:-}; [ -n "$t" ] && echo "    NRF before: $(nrfq $t)"
  kubectl logs -f -n $ns $pod -c $c > /tmp/logs/$d.log 2>&1 & lp=$!
  kubectl get pod -n $ns $pod -w -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode} {.status.containerStatuses[0].state.terminated.reason}{"\n"}' > /tmp/$d.watch 2>/dev/null & wp=$!
  nrfmark=$(date -u +%Y-%m-%dT%H:%M:%S)
  sleep 2; t0=$(date +%s.%N)
  kubectl scale -n $ns deploy/$d --replicas=0 >/dev/null
  kubectl wait -n $ns --for=delete pod/$pod --timeout=60s >/dev/null 2>&1
  t1=$(date +%s.%N); sleep 1; kill $lp $wp 2>/dev/null
  term=$(grep -E '^[0-9]+ ' /tmp/$d.watch | tail -1)
  echo "    exit after $(echo "$t1 - $t0" | bc | cut -c1-5) s: code ${term%% *} (${term#* })"
  echo "    panic: $(grep -c -iE 'panic|fatal error|SIGSEGV' /tmp/logs/$d.log)"
  grep -aiE 'terminat|deregist' /tmp/logs/$d.log | tr '\t' ' ' | sed -E 's/\{"component.*//' | cut -c1-150 | sed 's/^/    log: /' | tail -4
  [ -n "$t" ] && { sleep 2; echo "    NRF after:  $(nrfq $t)"; }
  [ -n "$t" ] && kubectl logs -n $ns deploy/nrf --since-time=$nrfmark 2>/dev/null | grep -a "NFDeregisterRequest" | tr '\t' ' ' | cut -c1-90 | sed 's/^/    NRF log: /' | head -2
  kubectl scale -n $ns deploy/$d --replicas=1 >/dev/null
done
