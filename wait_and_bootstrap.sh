#!/bin/bash

hash -r

wait_for_ssh(){
  local hostname="$1"
  local min=${2:-1} max=${3:-10}

  if [ -z "${hostname}" ] ; then return 1 ; fi
  exec 3>&2
  exec 2>/dev/null
  while true ; do
    if echo > /dev/tcp/${hostname}/22 ; then
      return 0
    fi
    sleep $(( $RANDOM % $max + $min ))
  done
  exec 2>&3
  exec 3>&-
}

setup_headnodes(){
  local out_tail="$(bootstrap_head bcpc-vm1.local.lan 10.0.100.11 | tee /dev/tty | tail -2)"
  local err_msg=
  read _ _ err_msg <<EoS
  ${out_tail}
EoS
  # TODO: don't call grep here...
  # Note that err_msg may have line delimiting characters at end, i.e , no anchor
  if echo "${err_msg}" | grep '^ERROR: 403 "Forbidden"' ; then
     :
  else
    return 1
  fi

  local keyfile=~/.ssh/id_rsa.root
  if [ ! -r "${keyfile}" ] ; then
      ./install_root_key
  fi
  ssh -i "${keyfile}" -lroot 10.0.100.11 chef-client
}

bootstrap_head(){
  local nodename="$1"
  local ip="$2"
  if [ -z "${ip}" ] ; then return 1 ; fi
  time -p wait_for_ssh "${ip}"
  echo "Configuring temporary hosts entry for chef server"
  read -d %% ent <<EoF
# Added by ${0##*/}
10.0.100.3 bcpc-bootstrap
%%
EoF
  echo $ent
  ssh -ostricthostkeychecking=no -i "${keyfile}" -lroot "${ip}" <<EoF
  if ! getent ahosts bcpc-bootstrap &> /dev/null ; then
  cat <<EoS >> /etc/hosts
$ent
EoS
  fi
  getent hosts bcpc-bootstrap
EoF
  knife bootstrap --bootstrap-no-proxy "${chef_server_host}" ${bootstrap_proxy_args} \
    -i "${keyfile}" -x root --node-ssl-verify-mode=none \
    --bootstrap-wget-options "--no-check-certificate" \
    -r 'role[BCPC-Headnode]' -E Test-Laptop "${ip}"
    knife actor map >&2
    knife group add actor admins "${nodename}" >&2
}

# TODO: This and above name together are confusing!
bootstrap_worker(){
  local ip="$1"
  if [ -z "${ip}" ] ; then return 1 ; fi
  time -p wait_for_ssh "${ip}"
  knife bootstrap --bootstrap-no-proxy "${chef_server_host}" ${bootstrap_proxy_args} \
    -i "${keyfile}" -x root \
    --bootstrap-wget-options "--no-check-certificate" \
    -r 'role[BCPC-Worknode]' -E Test-Laptop "$ip"
}

configure_proxy(){
  if [[ -f ./proxy_setup.sh ]]; then
    . ./proxy_setup.sh
    export -n http{,s}_proxy  # do not interfere with subsequent calls to knife
  fi
  if [[ -n "${https_proxy}" ]] ; then
    bootstrap_proxy_args="--bootstrap-proxy ${https_proxy}"
  else
    bootstrap_proxy_args=""
  fi
}

chef_server_host=bcpc-bootstrap
keyfile=~/.ssh/id_rsa.bcpc

set -e
configure_proxy
setup_headnodes

echo "Waiting to bootstrap workers"
set -x
for ip in 10.0.100.{12..13} ; do eval "bootstrap_worker ${ip} &" ; done
wait
