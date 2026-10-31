#!/usr/bin/env bash
# Restricted packet/path model, not a kernel emulator. Models UFW's built-in
# hooks installed BEFORE iptables-restore -n appends before.rules chains/rules.
set -euo pipefail
case $1 in
 load)
  root=$2; family=$3; [[ $family == v4 || $family == v6 ]]
  before=$root/etc/ufw/before.rules; prefix=ufw
  if [[ $family == v6 ]]; then before=$root/etc/ufw/before6.rules; prefix=ufw6; fi
  if [[ $family == v6 ]] && ! grep -qx 'IPV6=yes' "$root/etc/default/ufw"; then
   printf '*filter\n:INPUT DROP [0:0]\n:OUTPUT DROP [0:0]\nCOMMIT\n' > "$root/fixture/$family"; exit
  fi
  {
   {
   printf '*filter\n:INPUT DROP [0:0]\n:OUTPUT DROP [0:0]\n:FORWARD DROP [0:0]\n:ufw-before-logging-input - [0:0]\n:ufw-before-logging-output - [0:0]\n:ufw-before-input - [0:0]\n:ufw-before-output - [0:0]\n:ufw-user-input - [0:0]\n:ufw-user-output - [0:0]\n'
   printf -- '-A INPUT -j ufw-before-logging-input\n-A INPUT -j ufw-before-input\n-A INPUT -j ufw-user-input\n-A INPUT -j REJECT\n-A OUTPUT -j ufw-before-logging-output\n-A OUTPUT -j ufw-before-output\n-A OUTPUT -j ufw-user-output\n-A OUTPUT -j REJECT\n'
   } | sed "s/ufw-/$prefix-/g"
   sed '/^\*/d;/^COMMIT$/d' "$before"
   printf -- '-A %s-user-input -p tcp --dport 2299 -j REJECT\n-A %s-user-output -j REJECT\nCOMMIT\n' "$prefix" "$prefix"
  } > "$root/fixture/$family";;
 verdict)
  awk -v start="$3" -v port="$4" -v state="$5" '
   /^:/ {chain=substr($1,2); policy[chain]=$2}
   /^-A / {rules[$2,++count[$2]]=$0}
   function visit(chain,depth, i,n,a,j,target,matched,result) {
    if(depth>16) {print "cycle" > "/dev/stderr"; exit 2}
    for(i=1;i<=count[chain];i++) {
     n=split(rules[chain,i],a," "); matched=1; target=""
     for(j=3;j<=n;j++) {
      if(a[j]=="--dport" && a[j+1]!=port)matched=0
      if(a[j]=="--ctstate" && index("," a[j+1] ",","," state ",")==0)matched=0
      if(a[j]=="-j")target=a[j+1]
     }
     if(!matched)continue
     if(target=="ACCEPT"||target=="DROP"||target=="REJECT"||target=="RETURN")return target
     if(!(target in count))continue
     result=visit(target,depth+1); if(result!="RETURN")return result
    }
    return (policy[chain]=="DROP"||policy[chain]=="ACCEPT") ? policy[chain] : "RETURN"
   }
   END {print visit(start,0)}
  ' "$2";;
 *) exit 2;;
esac
