#!/bin/bash
# Delete each network function's pod once, with its peers running, and record
# how it shuts down: time from the delete to the end of the pod, the exit code,
# and the last lines of its log (panics in particular).
set -u
ns=sdcore
order="ausf nssf pcf smf udm udr webui upf-adapter metricfunc sctplb simapp amf nrf"
printf "%-12s %-6s %-8s %-10s %s\n" FUNCTION SECS EXIT REASON "LOG (panic / last line)"
for d in $order; do
  kubectl get deploy -n $ns $d >/dev/null 2>&1 || { echo "$d: not deployed"; continue; }
  kubectl rollout status -n $ns deploy/$d --timeout=240s >/dev/null 2>&1
  pod=$(kubectl get pods -n $ns -l app=$d -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
  [ -z "$pod" ] && pod=$(kubectl get pods -n $ns -o name | sed 's#pod/##' | grep "^$d-" | head -1)
  c=$(kubectl get pod -n $ns $pod -o jsonpath='{.spec.containers[0].name}')
  pid1=$(kubectl exec -n $ns $pod -c $c -- cat /proc/1/comm 2>/dev/null)
  kubectl logs -f -n $ns $pod -c $c > /tmp/$d.log 2>&1 &
  lp=$!
  kubectl get pod -n $ns $pod -w -o jsonpath='{.status.containerStatuses[0].state.terminated.exitCode} {.status.containerStatuses[0].state.terminated.reason}{"\n"}' > /tmp/$d.watch 2>/dev/null &
  wp=$!
  sleep 2
  t0=$(date +%s.%N)
  kubectl delete pod -n $ns $pod --wait=true >/dev/null 2>&1
  t1=$(date +%s.%N)
  sleep 1; kill $lp $wp 2>/dev/null
  term=$(grep -E '^[0-9]+ ' /tmp/$d.watch | tail -1)
  panic=$(grep -m1 -iE 'panic|fatal error|SIGSEGV' /tmp/$d.log | tr '\t' ' ' | cut -c1-110)
  last=$(grep -v '^\s*$' /tmp/$d.log | tail -1 | tr '\t' ' ' | cut -c1-110)
  printf "%-12s %-6s %-8s %-10s pid1=%s | %s\n" $d "$(echo "$t1 - $t0" | bc | cut -c1-5)" "${term%% *}" "${term#* }" "$pid1" "${panic:-$last}"
  cp /tmp/$d.log /tmp/shutdown-logs/ 2>/dev/null
done
